// 引擎:S0 选定的 annotated 位置(计划 §7.2),按事件目标 App 应用规则(§7.4)。
//
// 迁移与保留的硬约束(证据见 docs/PER_APP_SCROLL_PLAN.md §12 S0 记录):
// 1. 六个滚动字段先全部读取、再统一写回(ScrollFlip 纯函数,ScrollFlipTests 兜底)。
// 2. continuous 事件放行,不做目标解析。
// 3. stop() 三步清理:tapEnable(false) → 移除 runloop source → invalidate port。
// 4. 单 tap 原则:进程内只创建一个 active tap;S0 冻结事故(S+A 双 tap+无退避重挂)
//    的硬要求——重挂必须带退避,连续超时达上限后放弃并上报 failed,不再打扰系统。
// 5. tap 实例必须被显式持有(见下"状态与锁"),refcon 用 passUnretained,
//    对象释放即 SIGSEGV(S0 事故实证);deinit 兜底 invalidate 作为最后防线。
// 6. annotated 在 session 下游:同机若存在旧 session 引擎会双重翻转,切换期必须
//    保证同一时刻只有一个修改事件的引擎(见 S6 切换说明)。
//
// 状态与锁(对抗式审查修订):全部可变状态(_isRunning/_tapPort/_runLoopSource/
// _installedRunLoop/_generation/_reenablePolicy/_pruneTimer)只在 stateLock 内触碰;
// 慢速 CF 调用在锁外的快照上进行。stop() 先在锁内"认领"(置 _isRunning=false、清引用、
// 前进 generation),再在锁外做三步清理,因此并发双 stop 只有一方执行清理,同一
// CFMachPort 不会被 invalidate 两次;give-up 的队列侧 stop 携带 generation 复核,
// 不会误杀 stop→start 之后新建的 tap。
//
// 其余已知坑(继承自旧引擎,见 docs/APP_PLAN.md §0):
// - AXIsProcessTrusted() 结果进程内缓存,授权后需重启进程才能读到新值。
// - 回调内无磁盘 I/O、无锁竞争文件写入:规则经 RuleSnapshotBox(内存原子快照)。

import ApplicationServices
import CoreGraphics
import Dispatch
import Foundation

/// 启动失败分型(UX 计划 §9.1):权限问题与引擎不可用必须区分,
/// 状态层据此进入 needsPermission(去授权)或 engineFailed(可重试),
/// 不再把一切启动失败统称为权限丢失。
enum EngineStartFailure: Equatable, CustomStringConvertible {
    /// 无辅助功能权限。
    case notTrusted
    /// tap 创建/挂载失败(沙盒或系统资源原因);重试可能恢复。
    case tapUnavailable(String)

    var description: String {
        switch self {
        case .notTrusted: return String(localized: "无辅助功能权限")
        case .tapUnavailable(let reason): return reason
        }
    }
}

/// tap 被禁用后的重挂策略(纯逻辑,可单测)。
/// timeout:连续发生且期间没有任何成功处理的事件 → 指数退避;超过上限放弃
/// (保护系统,避免 S0 冻结事故重演)。userInput(安全输入):用户主动行为,
/// 同样退避但永不放弃,封顶间隔持续重试。
struct ReenablePolicy: Equatable {
    enum DisableReason: Equatable {
        case timeout
        case userInput
    }

    static let timeoutSchedule: [TimeInterval] = [0, 0.1, 0.25, 0.5, 1, 2, 5, 5, 5, 5]
    static let userInputSchedule: [TimeInterval] = [0, 0.5, 2, 5, 5, 5, 5, 5, 5, 5]

    private(set) var consecutiveTimeouts = 0
    private(set) var consecutiveUserInputDisables = 0

    /// nil = 放弃重挂(仅 timeout 会发生)。
    mutating func nextDelay(for reason: DisableReason) -> TimeInterval? {
        switch reason {
        case .timeout:
            consecutiveTimeouts += 1
            guard consecutiveTimeouts <= Self.timeoutSchedule.count else { return nil }
            return Self.timeoutSchedule[consecutiveTimeouts - 1]
        case .userInput:
            consecutiveUserInputDisables = min(consecutiveUserInputDisables + 1, Self.userInputSchedule.count)
            return Self.userInputSchedule[consecutiveUserInputDisables - 1]
        }
    }

    /// 成功处理了一条滚动事件 → 系统健康,清零退避。
    mutating func noteProcessedEvent() {
        consecutiveTimeouts = 0
        consecutiveUserInputDisables = 0
    }
}

final class FlipEngine {
    struct EventOutcome: Equatable {
        let flipped: Bool
        let bundleID: String?
        /// nil = 规则不可用(未载入/恢复模式)而放行。
        let source: FlipDecisionSource?
    }

    // MARK: 回调与依赖

    var onEvent: ((EventOutcome) -> Void)?
    /// 重挂放弃等致命故障;回调后引擎已完成清场,状态层应进入 failed。
    var onFailure: ((String) -> Void)?
    let diagnostics = EngineDiagnostics()

    private let resolver: ScrollTargetResolving
    private let rules: ScrollRuleProviding
    private let queue = DispatchQueue(label: "com.jonywu.WheelFlip.engine")
    /// 延迟重挂共用这条串行队列(与 give-up 清场互斥);测试经 init 注入替代调度。
    private static let reenableQueue = DispatchQueue(label: "com.jonywu.WheelFlip.reenable")
    /// 延迟重挂的调度缝:测试注入录制器,生产用重挂串行队列 asyncAfter。
    private let scheduleAfter: (TimeInterval, @escaping () -> Void) -> Void

    // MARK: 状态(全部只在 stateLock 内触碰)

    private let stateLock = NSLock()
    private var _isRunning = false
    private var _tapPort: CFMachPort?
    private var _runLoopSource: CFRunLoopSource?
    /// start 时记录挂载 tap 的 run loop;stop 可能从引擎队列调用,不能临时取 current。
    private var _installedRunLoop: CFRunLoop?
    /// 每次 stop/start 前进;延迟重挂与 give-up 清场携带旧代次即作废。
    private var _generation = 0
    private var _reenablePolicy = ReenablePolicy()
    private var _pruneTimer: DispatchSourceTimer?

    init(
        resolver: ScrollTargetResolving = AppIdentityResolver(),
        rules: ScrollRuleProviding,
        scheduleAfter: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, action in
            FlipEngine.reenableQueue.asyncAfter(deadline: .now() + delay, execute: action)
        }
    ) {
        self.resolver = resolver
        self.rules = rules
        self.scheduleAfter = scheduleAfter
    }

    deinit {
        // 保底:tap 仍存活时对象即将释放,refcon 会悬挂——立即作废端口。
        // (生产装配引擎活过进程生命周期,这里是防御层。)
        stateLock.lock()
        let tap = _tapPort
        let timer = _pruneTimer
        _tapPort = nil
        _pruneTimer = nil
        stateLock.unlock()
        timer?.cancel()
        if let tap {
            CFMachPortInvalidate(tap)
        }
    }

    var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _isRunning
    }

    static func isTrusted(prompt: Bool) -> Bool {
        if !prompt { return AXIsProcessTrusted() }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: 启停

    /// 只应在挂载目标 run loop 的线程(主线程)调用;状态发布全程持锁。
    /// 返回 nil 表示成功启动;否则返回分型失败供状态层映射(UX §9.1)。
    func start() -> EngineStartFailure? {
        stateLock.lock()
        let alreadyRunning = _isRunning
        stateLock.unlock()
        if alreadyRunning { return nil }
        guard FlipEngine.isTrusted(prompt: false) else {
            return .notTrusted
        }

        let selfBox = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap, // S0 选定路线:目标 PID 指向鼠标所在窗口的 App
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: 1 << CGEventType.scrollWheel.rawValue,
            callback: { proxy, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let engine = Unmanaged<FlipEngine>.fromOpaque(refcon).takeUnretainedValue()
                return engine.handle(type: type, event: event)
            },
            userInfo: selfBox
        ) else {
            return .tapUnavailable("CGEvent.tapCreate 失败(通常是沙盒或权限阻止了 active tap)")
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return .tapUnavailable("CFMachPortCreateRunLoopSource 失败")
        }
        let runLoop = CFRunLoopGetCurrent()

        stateLock.lock()
        if _isRunning {
            // 并发 start 竞争败者:丢弃自己创建的资源。
            stateLock.unlock()
            CFMachPortInvalidate(tap)
            return nil
        }
        _generation += 1
        _reenablePolicy = ReenablePolicy()
        _tapPort = tap
        _runLoopSource = source
        _installedRunLoop = runLoop
        _isRunning = true
        stateLock.unlock()

        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        startPruneTimer()
        return nil
    }

    /// 线程安全且幂等:锁内认领后,锁外对快照做三步清理。
    func stop() {
        stateLock.lock()
        guard _isRunning else {
            stateLock.unlock()
            return
        }
        let snapshot = claimStopLocked()
        stateLock.unlock()
        performCleanup(snapshot)
    }

    /// give-up 专用:队列侧清场前复核代次,防止旧闭包误杀 stop→start 后的新 tap。
    private func stopIfCurrentGeneration(_ expected: Int) {
        stateLock.lock()
        guard _isRunning, _generation == expected else {
            stateLock.unlock()
            return
        }
        let snapshot = claimStopLocked()
        stateLock.unlock()
        performCleanup(snapshot)
    }

    /// 锁内认领:必须已持 stateLock 且 _isRunning==true。
    private func claimStopLocked() -> (tap: CFMachPort, source: CFRunLoopSource, runLoop: CFRunLoop, timer: DispatchSourceTimer?) {
        let tap = _tapPort!
        let source = _runLoopSource!
        let runLoop = _installedRunLoop ?? CFRunLoopGetMain()!
        let timer = _pruneTimer
        _generation += 1 // 作废所有在途延迟重挂
        _tapPort = nil
        _runLoopSource = nil
        _installedRunLoop = nil
        _pruneTimer = nil
        _isRunning = false
        return (tap, source, runLoop, timer)
    }

    /// 三步清理(坑 3):tapEnable(false) → 移除 runloop source → invalidate port。
    private func performCleanup(_ s: (tap: CFMachPort, source: CFRunLoopSource, runLoop: CFRunLoop, timer: DispatchSourceTimer?)) {
        s.timer?.cancel()
        CGEvent.tapEnable(tap: s.tap, enable: false)
        CFRunLoopRemoveSource(s.runLoop, s.source, .commonModes)
        CFMachPortInvalidate(s.tap)
    }

    // MARK: 事件处理(回调线程 = 挂载 tap 的 run loop 线程)

    /// 回调入口;internal 供单元测试用合成 CGEvent 直接驱动(不创建真实 tap)。
    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout:
            diagnostics.noteTapTimeout()
            handleDisabled(reason: .timeout)
            return Unmanaged.passUnretained(event)
        case .tapDisabledByUserInput:
            diagnostics.noteTapUserInput()
            handleDisabled(reason: .userInput)
            return Unmanaged.passUnretained(event)
        default:
            break
        }
        guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }

        // 健康流量清零退避:超时后恢复正常滚动 → 下次超时从头退避。
        stateLock.lock()
        _reenablePolicy.noteProcessedEvent()
        stateLock.unlock()

        // 先读全部字段(坑 1),continuous 判定在翻转决策之前。
        let fields = ScrollFields(
            isContinuous: event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
            deltaAxis1: event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
            deltaAxis2: event.getIntegerValueField(.scrollWheelEventDeltaAxis2),
            pointDeltaAxis1: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
            pointDeltaAxis2: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2),
            fixedPtDeltaAxis1: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
            fixedPtDeltaAxis2: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        )

        if fields.isContinuous {
            diagnostics.noteContinuous()
            onEvent?(EventOutcome(flipped: false, bundleID: nil, source: .continuousPassthrough))
            return Unmanaged.passUnretained(event)
        }

        // 目标解析:annotated 位置的 eventTargetUnixProcessID(S0 实测 = 鼠标所在窗口 App)。
        let started = DispatchTime.now()
        let targetPID = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
        let resolution = resolver.resolve(targetPID: targetPID)
        let resolveMicros = Int((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1000)

        let bundleID: String?
        switch resolution {
        case .identified(let identity):
            bundleID = identity.bundleID
        case .unresolvable(let reason):
            bundleID = nil
            if reason == "target-pid-missing" {
                diagnostics.noteMissingTargetPID()
            } else {
                diagnostics.noteUnresolvableTarget()
            }
        }

        // 规则决策:nil = 规则不可用 → 放行(§3.2 优先级第一条);绝不借用上一 App。
        guard let decision = rules.decision(forBundle: bundleID, eventKind: .discrete) else {
            diagnostics.noteDiscrete(bundleID: bundleID, flipped: false, source: nil, resolveMicros: resolveMicros)
            diagnostics.noteNoRulesPassthrough()
            onEvent?(EventOutcome(flipped: false, bundleID: bundleID, source: nil))
            return Unmanaged.passUnretained(event)
        }

        if decision.flips, let flipped = ScrollFlip.flipped(fields) {
            // 需要翻转才写,且先读全部(上面)后写全部(这里)。
            event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: flipped.deltaAxis1)
            event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: flipped.deltaAxis2)
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: flipped.pointDeltaAxis1)
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: flipped.pointDeltaAxis2)
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: flipped.fixedPtDeltaAxis1)
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: flipped.fixedPtDeltaAxis2)
        }
        diagnostics.noteDiscrete(bundleID: bundleID, flipped: decision.flips, source: decision.source, resolveMicros: resolveMicros)
        onEvent?(EventOutcome(flipped: decision.flips, bundleID: bundleID, source: decision.source))
        return Unmanaged.passUnretained(event)
    }

    // MARK: - 重挂(带退避,S0 冻结事故硬要求)

    private func handleDisabled(reason: ReenablePolicy.DisableReason) {
        stateLock.lock()
        let delay = _reenablePolicy.nextDelay(for: reason)
        let generationAtSchedule = _generation
        stateLock.unlock()

        guard let delay else {
            // 连续超时超上限:放弃重挂;同步上报,清场投回引擎队列(不在回调线程动 run loop)。
            diagnostics.noteReenableGaveUp()
            onFailure?("滚轮 tap 连续 \(ReenablePolicy.timeoutSchedule.count) 次超时被系统禁用,已停止重试")
            queue.async { [weak self] in
                guard let self else { return }
                self.stopIfCurrentGeneration(generationAtSchedule)
            }
            return
        }

        if delay == 0 {
            reenableNow()
            return
        }
        scheduleAfter(delay) { [weak self] in
            guard let self else { return }
            self.reenableIfCurrentGeneration(generationAtSchedule)
        }
    }

    private func reenableNow() {
        stateLock.lock()
        let running = _isRunning
        let tap = _tapPort
        stateLock.unlock()
        guard running, let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        diagnostics.noteReenable()
    }

    private func reenableIfCurrentGeneration(_ expected: Int) {
        stateLock.lock()
        let current = _isRunning && _generation == expected
        let tap = _tapPort
        stateLock.unlock()
        guard current, let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        diagnostics.noteReenable()
    }

    // MARK: - 低频兜底(§7.4:退出通知丢失/PID 复用残留)

    private func startPruneTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in
            self?.resolver.pruneDeadPIDs()
        }
        timer.resume()
        stateLock.lock()
        if _isRunning {
            _pruneTimer?.cancel()
            _pruneTimer = timer
            stateLock.unlock()
        } else {
            // stop 已在锁内认领(会取消自己拿到的 timer),这个迟到的新 timer 直接丢弃。
            stateLock.unlock()
            timer.cancel()
        }
    }
}
