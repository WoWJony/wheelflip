import CoreGraphics
import XCTest
@testable import WheelFlip

/// 引擎决策流(§7.4)与重挂退避(S0 冻结事故硬要求)。
/// 用合成 CGEvent 直接驱动 handle(不创建真实 tap),注入假解析器与快照盒。
final class FlipEngineFlowTests: XCTestCase {
    private final class FakeResolver: ScrollTargetResolving {
        var identities: [pid_t: AppIdentity] = [:]
        private(set) var resolveCallCount = 0
        func resolve(targetPID: pid_t) -> TargetResolution {
            resolveCallCount += 1
            if let identity = identities[targetPID] {
                return .identified(identity)
            }
            return targetPID > 0 ? .unresolvable("no-app-bundle") : .unresolvable("target-pid-missing")
        }
        func invalidatePID(_ pid: pid_t) {}
        func pruneDeadPIDs() {}
    }

    private var resolver: FakeResolver!
    private var rules: RuleSnapshotBox!

    override func setUp() {
        super.setUp()
        resolver = FakeResolver()
        rules = RuleSnapshotBox()
        resolver.identities[100] = AppIdentity(
            bundleID: "dev.warp.Warp-Stable",
            appPath: "/Applications/Warp.app",
            viaHelper: false
        )
        resolver.identities[200] = AppIdentity(
            bundleID: "com.mcneel.rhinoceros.8",
            appPath: "/Applications/Rhino.app",
            viaHelper: false
        )
    }

    private func makeEngine(scheduler: ((TimeInterval, @escaping () -> Void) -> Void)? = nil) -> FlipEngine {
        if let scheduler {
            return FlipEngine(resolver: resolver, rules: rules, scheduleAfter: scheduler)
        }
        return FlipEngine(resolver: resolver, rules: rules)
    }

    /// 六字段全置非零值的离散事件(模拟鼠标滚轮),目标 PID 可注入。
    /// fixedPt 刻意取非比例值(3.25/-1.75):CGEvent 写线级 delta 会自动同步像素/固定
    /// 字段,若引擎写序错误被自动同步掩盖,比例输入发现不了(对抗式审查修订)。
    private func makeDiscreteEvent(targetPID: Int64) -> CGEvent {
        let event = CGEvent(
            scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
            wheel1: 3, wheel2: 0, wheel3: 0
        )!
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 3)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -2)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 30)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: -20)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 3.25)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -1.75)
        event.setIntegerValueField(.eventTargetUnixProcessID, value: targetPID)
        return event
    }

    private func makeContinuousEvent() -> CGEvent {
        let event = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
            wheel1: 12, wheel2: 0, wheel3: 0
        )!
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        return event
    }

    private struct Fields {
        let d1: Int64; let d2: Int64
        let pd1: Int64; let pd2: Int64
        let fd1: Double; let fd2: Double
        init(_ event: CGEvent) {
            d1 = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            d2 = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
            pd1 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
            pd2 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
            fd1 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
            fd2 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        }
    }

    // MARK: 真值表通过引擎全链路(S2 验收:不同身份应用相反规则)

    func testDefaultOnFlipsAllSixFields() {
        rules.publish(RuleSettings(defaultFlip: true))
        let engine = makeEngine()
        let event = makeDiscreteEvent(targetPID: 100)
        _ = engine.handle(type: .scrollWheel, event: event)

        let f = Fields(event)
        XCTAssertEqual(f.d1, -3); XCTAssertEqual(f.d2, 2)
        XCTAssertEqual(f.pd1, -30); XCTAssertEqual(f.pd2, 20)
        XCTAssertEqual(f.fd1, -3.25, accuracy: 0.0001)
        XCTAssertEqual(f.fd2, 1.75, accuracy: 0.0001)
    }

    /// §9.1「事件」行:零值离散事件(空滚轮格)——按决策翻转但值保持 0,不崩溃不异变。
    func testZeroDeltaDiscreteEventStaysZero() {
        rules.publish(RuleSettings(defaultFlip: true))
        let engine = makeEngine()
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                            wheel1: 0, wheel2: 0, wheel3: 0)!
        event.setIntegerValueField(.eventTargetUnixProcessID, value: 100)
        var outcomes: [FlipEngine.EventOutcome] = []
        engine.onEvent = { outcomes.append($0) }
        _ = engine.handle(type: .scrollWheel, event: event)

        let f = Fields(event)
        XCTAssertEqual(f.d1, 0); XCTAssertEqual(f.d2, 0)
        XCTAssertEqual(f.pd1, 0); XCTAssertEqual(f.pd2, 0)
        XCTAssertEqual(f.fd1, 0.0, accuracy: 0.0001); XCTAssertEqual(f.fd2, 0.0, accuracy: 0.0001)
        XCTAssertEqual(outcomes.last?.flipped, true)
    }

    func testDefaultOffStillFlipsForceOnApp() {
        // S2 核心语义:默认关不等于服务关,forceOn 必须生效
        rules.publish(RuleSettings(defaultFlip: false,
                                   overrides: ["dev.warp.Warp-Stable": RuleOverrideEntry(mode: .forceOn)]))
        let engine = makeEngine()

        let warp = makeDiscreteEvent(targetPID: 100)
        _ = engine.handle(type: .scrollWheel, event: warp)
        XCTAssertEqual(Fields(warp).d1, -3, "默认关下 forceOn App 仍翻转")

        let rhino = makeDiscreteEvent(targetPID: 200) // 无覆盖 → 继承默认(关)→ 原样
        _ = engine.handle(type: .scrollWheel, event: rhino)
        XCTAssertEqual(Fields(rhino).d1, 3, "无覆盖 App 跟随默认(关)→ 不动")
    }

    func testDefaultOnWithForceOffPassesThrough() {
        rules.publish(RuleSettings(defaultFlip: true,
                                   overrides: ["com.mcneel.rhinoceros.8": RuleOverrideEntry(mode: .forceOff)]))
        let engine = makeEngine()
        let rhino = makeDiscreteEvent(targetPID: 200)
        _ = engine.handle(type: .scrollWheel, event: rhino)
        let f = Fields(rhino)
        XCTAssertEqual(f.d1, 3); XCTAssertEqual(f.pd1, 30); XCTAssertEqual(f.fd1, 3.25, accuracy: 0.0001)
    }

    func testTwoAppsWithOppositeRules() {
        // 计划验收句的自动化对应:同一引擎、两个身份、相反规则
        rules.publish(RuleSettings(defaultFlip: false, overrides: [
            "dev.warp.Warp-Stable": RuleOverrideEntry(mode: .forceOn),
            "com.mcneel.rhinoceros.8": RuleOverrideEntry(mode: .forceOff),
        ]))
        let engine = makeEngine()
        let warp = makeDiscreteEvent(targetPID: 100)
        let rhino = makeDiscreteEvent(targetPID: 200)
        _ = engine.handle(type: .scrollWheel, event: warp)
        _ = engine.handle(type: .scrollWheel, event: rhino)
        XCTAssertEqual(Fields(warp).d1, -3, "Warp 规则=始终翻转")
        XCTAssertEqual(Fields(rhino).d1, 3, "Rhino 规则=不翻转")
    }

    // MARK: 目标解析边界(§3.3)

    func testUnknownTargetFallsBackToGlobalDefault() {
        rules.publish(RuleSettings(defaultFlip: true))
        let engine = makeEngine()
        var outcomes: [FlipEngine.EventOutcome] = []
        engine.onEvent = { outcomes.append($0) }

        let unknown = makeDiscreteEvent(targetPID: 999) // 解析器不认识 → no-app-bundle
        _ = engine.handle(type: .scrollWheel, event: unknown)
        XCTAssertEqual(Fields(unknown).d1, -3, "未知目标用全局默认,不借用上一个 App")
        XCTAssertEqual(outcomes.last?.bundleID, nil)
        XCTAssertEqual(engine.diagnostics.snapshot().unresolvableTargets, 1)

        // 随后一个 forceOff App:上一条未解析事件不得污染这条
        rules.publish(RuleSettings(defaultFlip: true,
                                   overrides: ["com.mcneel.rhinoceros.8": RuleOverrideEntry(mode: .forceOff)]))
        let rhino = makeDiscreteEvent(targetPID: 200)
        _ = engine.handle(type: .scrollWheel, event: rhino)
        XCTAssertEqual(Fields(rhino).d1, 3)
    }

    func testMissingTargetPIDUsesDefaultAndCounts() {
        rules.publish(RuleSettings(defaultFlip: true))
        let engine = makeEngine()
        let event = makeDiscreteEvent(targetPID: 0)
        _ = engine.handle(type: .scrollWheel, event: event)
        XCTAssertEqual(Fields(event).d1, -3, "无目标 PID 按默认处理")
        XCTAssertEqual(engine.diagnostics.snapshot().missingTargetPIDs, 1)
        XCTAssertEqual(engine.diagnostics.snapshot().unresolvableTargets, 0)
    }

    func testNoRulesPassesEverythingThrough() {
        // 快照盒为空(未载入/恢复模式):一律放行(§3.2 优先级第一条)
        let engine = makeEngine()
        let warp = makeDiscreteEvent(targetPID: 100)
        let outcomeBox = LockedBox<FlipEngine.EventOutcome?>(nil)
        engine.onEvent = { outcomeBox.value = $0 }
        _ = engine.handle(type: .scrollWheel, event: warp)
        XCTAssertEqual(Fields(warp).d1, 3, "规则不可用时不得修改事件")
        XCTAssertNil(outcomeBox.value?.source)
        XCTAssertEqual(engine.diagnostics.snapshot().noRulesPassthrough, 1)
    }

    func testContinuousPassesThroughWithoutResolution() {
        rules.publish(RuleSettings(defaultFlip: true))
        let engine = makeEngine()
        let event = makeContinuousEvent()
        // §9.1:continuous 所有字段不变——逐项断言,不止 pointDelta。
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 12)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -5)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 120)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: -50)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 12.0)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -5.0)
        _ = engine.handle(type: .scrollWheel, event: event)
        let f = Fields(event)
        XCTAssertEqual(f.d1, 12); XCTAssertEqual(f.d2, -5)
        XCTAssertEqual(f.pd1, 120); XCTAssertEqual(f.pd2, -50)
        XCTAssertEqual(f.fd1, 12.0, accuracy: 0.0001); XCTAssertEqual(f.fd2, -5.0, accuracy: 0.0001)
        XCTAssertEqual(resolver.resolveCallCount, 0, "continuous 不做目标解析")
        XCTAssertEqual(engine.diagnostics.snapshot().continuousSeen, 1)
    }

    /// §9.1「事件」行:离散↔连续交替;每条离散独立决策,连续不解析。
    func testDiscreteContinuousAlternation() {
        rules.publish(RuleSettings(defaultFlip: true,
                                   overrides: ["dev.warp.Warp-Stable": RuleOverrideEntry(mode: .forceOff)]))
        let engine = makeEngine()
        let first = makeDiscreteEvent(targetPID: 100)
        let continuous = makeContinuousEvent()
        let second = makeDiscreteEvent(targetPID: 100)
        _ = engine.handle(type: .scrollWheel, event: first)
        _ = engine.handle(type: .scrollWheel, event: continuous)
        _ = engine.handle(type: .scrollWheel, event: second)

        XCTAssertEqual(Fields(first).d1, 3, "Warp forceOff → 不动")
        XCTAssertEqual(continuous.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 12)
        XCTAssertEqual(Fields(second).d1, 3, "连续事件之后离散决策不受影响")
        XCTAssertEqual(resolver.resolveCallCount, 2, "仅两条离散做了解析")
        let diag = engine.diagnostics.snapshot()
        XCTAssertEqual(diag.discreteSeen, 2)
        XCTAssertEqual(diag.continuousSeen, 1)
    }

    func testOnEventCarriesOverrideSource() {
        rules.publish(RuleSettings(defaultFlip: false,
                                   overrides: ["dev.warp.Warp-Stable": RuleOverrideEntry(mode: .forceOn)]))
        let engine = makeEngine()
        var outcomes: [FlipEngine.EventOutcome] = []
        engine.onEvent = { outcomes.append($0) }
        _ = engine.handle(type: .scrollWheel, event: makeDiscreteEvent(targetPID: 100))
        XCTAssertEqual(outcomes.last?.source, .appOverride(.forceOn))
        XCTAssertEqual(outcomes.last?.bundleID, "dev.warp.Warp-Stable")
        XCTAssertEqual(outcomes.last?.flipped, true)
    }

    // MARK: 重挂退避(S0 冻结事故硬要求)

    func testTimeoutStormGivesUpAndReportsFailure() {
        rules.publish(RuleSettings(defaultFlip: true))
        let engine = makeEngine()
        let failureBox = LockedBox<String?>(nil)
        engine.onFailure = { failureBox.value = $0 }

        let probe = makeDiscreteEvent(targetPID: 100)
        for _ in 0...ReenablePolicy.timeoutSchedule.count { // 超过上限一次
            _ = engine.handle(type: .tapDisabledByTimeout, event: probe)
        }
        XCTAssertNotNil(failureBox.value, "连续超时超上限必须放弃并上报,不得无限重挂打扰系统")
        XCTAssertEqual(engine.diagnostics.snapshot().reenableGaveUps, 1)
        XCTAssertEqual(engine.diagnostics.snapshot().tapTimeoutDisables, ReenablePolicy.timeoutSchedule.count + 1)
    }

    func testHealthyTrafficResetsBackoffCounter() {
        rules.publish(RuleSettings(defaultFlip: true))
        let engine = makeEngine()
        let failureBox = LockedBox<String?>(nil)
        engine.onFailure = { failureBox.value = $0 }

        let probe = makeDiscreteEvent(targetPID: 100)
        for _ in 0..<ReenablePolicy.timeoutSchedule.count { // 恰好未超上限
            _ = engine.handle(type: .tapDisabledByTimeout, event: probe)
        }
        _ = engine.handle(type: .scrollWheel, event: probe) // 健康事件清零
        for _ in 0..<ReenablePolicy.timeoutSchedule.count { // 再来一轮仍未超
            _ = engine.handle(type: .tapDisabledByTimeout, event: probe)
        }
        XCTAssertNil(failureBox.value, "有健康流量穿插时不应累计到放弃")
    }

    func testUserInputDisablesNeverGiveUp() {
        // 安全输入是用户主动行为:退避但持续重试
        rules.publish(RuleSettings(defaultFlip: true))
        let engine = makeEngine()
        let failureBox = LockedBox<String?>(nil)
        engine.onFailure = { failureBox.value = $0 }

        let probe = makeDiscreteEvent(targetPID: 100)
        for _ in 0..<40 {
            _ = engine.handle(type: .tapDisabledByUserInput, event: probe)
        }
        XCTAssertNil(failureBox.value)
        XCTAssertEqual(engine.diagnostics.snapshot().tapUserInputDisables, 40)
    }

    // MARK: 纯策略

    /// 调度缝验证(对抗式审查修订):退避延迟按策略表逐级放大;
    /// 迟到的重挂闭包在引擎停跑后必须 no-op(代次/运行态守卫)。
    func testDelayedReenableSchedulingAndStaleClosureNoOp() {
        rules.publish(RuleSettings(defaultFlip: true))
        var scheduled: [(delay: TimeInterval, action: () -> Void)] = []
        let engine = makeEngine(scheduler: { delay, action in
            scheduled.append((delay, action))
        })
        let failureBox = LockedBox<String?>(nil)
        engine.onFailure = { failureBox.value = $0 }

        let probe = makeDiscreteEvent(targetPID: 100)
        _ = engine.handle(type: .tapDisabledByTimeout, event: probe) // delay 0 → 立即分支
        _ = engine.handle(type: .tapDisabledByTimeout, event: probe) // 0.1
        _ = engine.handle(type: .tapDisabledByTimeout, event: probe) // 0.25
        XCTAssertEqual(scheduled.map(\.delay), [0.1, 0.25], "第 1 次立即重挂,之后进入退避表")

        // 模拟闭包迟到(引擎已停/未跑):执行历史闭包不得重挂、不得崩溃、不得触发失败
        for (_, action) in scheduled { action() }
        XCTAssertEqual(engine.diagnostics.snapshot().reenables, 0, "无 tap 时重挂守卫应跳过")
        XCTAssertNil(failureBox.value)
    }

    func testReenablePolicySchedules() {
        var policy = ReenablePolicy()
        XCTAssertEqual(policy.nextDelay(for: .timeout), 0)
        XCTAssertEqual(policy.nextDelay(for: .timeout), 0.1)
        policy.noteProcessedEvent()
        XCTAssertEqual(policy.nextDelay(for: .timeout), 0, "健康事件后从头退避")
        for _ in 0..<(ReenablePolicy.timeoutSchedule.count - 1) { // 已消耗 1 次
            XCTAssertNotNil(policy.nextDelay(for: .timeout))
        }
        XCTAssertNil(policy.nextDelay(for: .timeout), "连续超时超上限 → 放弃")

        var userInput = ReenablePolicy()
        for _ in 0..<50 {
            XCTAssertNotNil(userInput.nextDelay(for: .userInput), "安全输入永不放弃")
        }
    }
}

/// 测试线程与引擎回调闭包之间的最小同步盒。
private final class LockedBox<T> {
    private let lock = NSLock()
    private var stored: T
    init(_ initial: T) { stored = initial }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}
