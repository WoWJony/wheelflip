import Foundation

// 抽象出 FlipEngine 的可控制面,方便单元测试注入假实现,不必依赖真实辅助功能权限。
protocol FlipEngineControlling: AnyObject {
    var isRunning: Bool { get }
    func start() -> EngineStartFailure?
    func stop()
}

extension FlipEngine: FlipEngineControlling {}

// 抽象出登录项注册,方便单元测试注入假实现,不必真的调用 SMAppService。
protocol LoginItemManaging: AnyObject {
    func register() -> String?
    func unregister() -> String?
}

// 服务状态(UX 计划 §5.1 显示契约的数据源;文案统一在 ServicePresentation 生成):
// onboarding        从未获得辅助功能权限
// running           规则服务运行(tap 存在;与 defaultFlip 无关,默认关也允许 forceOn 生效)
// paused            用户暂停:完整 stop,保留登录项;只到进程结束,不跨启动保存
// needsPermission   授权缺失,或恢复/重试时发现无权限(重授权参考 README)
// engineFailed      引擎暂时无法运行(tap 创建失败、重挂放弃);可重试启动
// rulesFailed       规则无法读取(损坏/版本不支持);禁用规则编辑,提供修复入口
enum AppPhase: Equatable {
    case onboarding
    case running
    case paused
    case needsPermission(reason: String)
    case engineFailed(reason: String)
    case rulesFailed(reason: String)
}

/// 面板编辑对象上下文(UX §4.3):身份 + 来源 + 选择时刻。
/// 打开面板期间冻结;用户手动选择可明确替换。
struct PanelTargetContext: Equatable {
    enum Source: Equatable {
        /// 最近一次成功识别的外部普通滚轮目标。
        case recentScroll(at: Date)
        /// 用户经"选择应用…"手动选择。
        case manualPick(at: Date)
    }
    let bundleID: String
    let source: Source
}

/// 最近识别事实(仅内存,不落盘;时间始终刷新,发布有节流,§9.1)。
struct IdentifiedTarget: Equatable {
    let bundleID: String
    var lastSeenAt: Date
}

/// 保存反馈(UX §5.3):绑定对象与代次;成功短显约 2 秒,失败持久,
/// 同一对象后续成功自动覆盖旧错误,两处界面共用这一份状态。
struct SaveState: Equatable {
    enum Target: Equatable {
        case defaultDirection
        case appRule(bundleID: String)
    }
    let target: Target
    let succeeded: Bool
    let message: String
    /// 提交代次;只清除仍是当前代次的成功提示,防止旧闭包抹掉新结果。
    let generation: Int
}

final class AppState: ObservableObject {
    @Published private(set) var phase: AppPhase
    @Published private(set) var loginItemNotice: String?
    /// 授权检查的用户可见结论(F10:不得静默返回;如"重新打开后仍未检测到权限")。
    @Published private(set) var permissionNotice: String?
    @Published private(set) var saveState: SaveState?
    @Published private(set) var defaultFlip: Bool
    /// 面板编辑对象(popover.show 前固定或手选替换;展示期间不随事件跳变,§4.3)。
    @Published private(set) var panelTarget: PanelTargetContext?
    /// 目录快照的展示副本(主线程喂入;仅 UI 消费,服务逻辑不读它)。
    @Published private(set) var catalogSnapshot: CatalogSnapshot?
    let legacyCLIDetected: Bool

    /// 最近识别目标与最近一次普通滚轮识别失败(节流发布;时间事实始终刷新,§9.1)。
    /// 连续事件(触控板/Magic Mouse)既不替换目标也不算失败(UX §4.3 表)。
    private(set) var lastIdentifiedTarget: IdentifiedTarget?
    private(set) var lastDiscreteFailureAt: Date?
    private var lastContextPublishAt = Date.distantPast

    let store: RuleStore
    private let rules: RuleSnapshotBox
    private let engine: FlipEngineControlling
    private let isTrusted: () -> Bool
    private let loginItems: LoginItemManaging
    private let ownBundleID: String?
    private let now: () -> Date
    /// 登录项确认的调度缝(F01:phase 先发布、确认后置,点击→渲染不被 XPC 阻塞;测试注入同步)。
    private let scheduleAsync: (@escaping () -> Void) -> Void
    /// 成功反馈定时清除的调度缝(测试注入同步或空实现)。
    private let scheduleAfter: (TimeInterval, @escaping () -> Void) -> Void
    /// 暂停意图(§3.2:权限重新获得不得擅自取消同一会话内的暂停)。
    private var pauseIntent = false
    private var saveGeneration = 0

    init(
        engine: FlipEngineControlling,
        rules: RuleSnapshotBox,
        store: RuleStore,
        isTrusted: @escaping () -> Bool,
        loginItems: LoginItemManaging,
        legacyCLIDetected: Bool = false,
        ownBundleID: String? = Bundle.main.bundleIdentifier,
        now: @escaping () -> Date = { Date() },
        scheduleAsync: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
        scheduleAfter: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, action in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        }
    ) {
        self.engine = engine
        self.rules = rules
        self.store = store
        self.isTrusted = isTrusted
        self.loginItems = loginItems
        self.legacyCLIDetected = legacyCLIDetected
        self.ownBundleID = ownBundleID
        self.now = now
        self.scheduleAsync = scheduleAsync
        self.scheduleAfter = scheduleAfter

        // 先载入规则(含 §6.2 迁移);损坏 → 不启动服务、不修改事件,提供修复入口。
        let outcome = store.load()
        rules.publish(store.settings)
        defaultFlip = store.settings?.defaultFlip ?? true

        if case .needsRecovery(let reason) = outcome {
            phase = .rulesFailed(reason: reason)
            return
        }
        guard isTrusted() else {
            phase = .onboarding
            return
        }
        phase = Self.phaseAfterStart(engine.start())
        if case .running = phase { confirmLoginItem() }
    }

    // MARK: 权限

    /// 授权后尝试前进(onboarding/needsPermission)。返回 false = 进程内仍读不到权限
    /// (结果被系统缓存,授权后需重开进程;F10 不得静默)。
    @discardableResult
    func refreshPermission() -> Bool {
        switch phase {
        case .onboarding, .needsPermission:
            guard isTrusted() else { return false }
            // 暂停意图不被权限恢复取消(§3.2);用户主动 resume 才清。
            if pauseIntent {
                phase = .paused
            } else {
                phase = Self.phaseAfterStart(engine.start())
                if case .running = phase { confirmLoginItem() }
            }
            permissionNotice = nil
            return true
        case .running, .paused, .engineFailed, .rulesFailed:
            return true
        }
    }

    /// 重开检查仍无权限时的结论文案(由 AppDelegate 在 --permission-recheck 启动时喂入)。
    func notePermissionRecheckStillDenied() {
        permissionNotice = String(localized: "重新打开后仍未检测到权限;请在辅助功能列表里选中正在运行的这一份并打开开关,然后再次重新打开。")
    }

    /// 重开流程自身失败(无法派生子进程等)时的结论文案(F10:不允许静默失败)。
    func noteRelaunchUnavailable(_ reason: String) {
        permissionNotice = String(format: String(localized: "无法自动重新打开(%@);请手动退出后重新打开 WheelFlip。"), reason)
    }

    // MARK: 规则编辑(只改持久层,绝不启停引擎)

    /// 默认方向:只影响继承默认的 App(UX §3.2 用词)。
    func setDefaultFlip(_ value: Bool) {
        commit(target: .defaultDirection) { store in
            try store.setDefaultFlip(value)
        }
    }

    /// 三态快捷设置(inherit 删除覆盖)。
    func setOverride(bundleID: String, mode: ScrollRuleMode) {
        commit(target: .appRule(bundleID: bundleID)) { store in
            try store.setOverride(bundleID: bundleID, mode: mode)
        }
    }

    // MARK: 暂停/恢复(§3.2 表)

    /// 暂停全部:完整 stop;登录项与持久规则保留。
    func pauseAll() {
        guard phase == .running else { return }
        pauseIntent = true
        if engine.isRunning {
            engine.stop()
        }
        phase = .paused
    }

    /// 恢复全部:重新 start 并确认登录项。phase 在引擎启动后立即发布,
    /// 登录项确认后置异步(F01:恢复按钮的可感知延迟不再包含 SMAppService XPC)。
    /// 权限是状态层的关切,先显式检查再进引擎(引擎内部的检查是纵深防御)。
    func resumeRules() {
        guard phase == .paused else { return }
        pauseIntent = false
        guard isTrusted() else {
            phase = .needsPermission(reason: "无辅助功能权限")
            return
        }
        phase = Self.phaseAfterStart(engine.start())
        if case .running = phase { confirmLoginItem() }
    }

    /// 引擎暂时无法运行时的"重试启动"(UX §5.1)。
    func retryEngineStart() {
        guard case .engineFailed = phase else { return }
        guard isTrusted() else {
            phase = .needsPermission(reason: "无辅助功能权限")
            return
        }
        phase = Self.phaseAfterStart(engine.start())
        if case .running = phase { confirmLoginItem() }
    }

    // MARK: 事件上下文(内存,不记录历史)

    /// 引擎事件回调 → 最近目标摘要。
    /// · 自己窗口的事件不替换"上次滚动的外部 App"上下文(§3.3);
    /// · 成功识别的离散事件刷新目标与时间(时间事实始终刷新,发布按 2 秒节流,§9.1);
    /// · 识别失败的普通滚轮事件记录时间供"最近一次滚轮操作未识别应用"提示;
    /// · 连续事件(触控板/Magic Mouse)完全忽略:不替换、不算失败(UX §4.3 表)。
    func noteEngineEvent(_ outcome: FlipEngine.EventOutcome) {
        if let own = ownBundleID, outcome.bundleID == own { return }
        if let bundleID = outcome.bundleID, !bundleID.isEmpty {
            let date = now()
            let bundleChanged = lastIdentifiedTarget?.bundleID != bundleID
            if bundleChanged {
                lastIdentifiedTarget = IdentifiedTarget(bundleID: bundleID, lastSeenAt: date)
            } else {
                lastIdentifiedTarget?.lastSeenAt = date
            }
            lastDiscreteFailureAt = nil
            publishContextIfNeeded(bundleChanged: bundleChanged)
        } else if outcome.source != .continuousPassthrough {
            lastDiscreteFailureAt = now()
            publishContextIfNeeded(bundleChanged: false)
        }
    }

    /// popover.show 前调用:按 §4.3 规则固定面板编辑对象。
    /// · 手选粘滞:关闭期间没有更新的有效外部事件 → 继续编辑手选应用;
    /// · 有比手选更新的有效事件 → 改推最新识别应用(来源如实展示);
    /// · 非手选(或首次)→ 固定最近识别目标(如有)。
    func pinPanelTarget() {
        if case .manualPick(let pickedAt)? = panelTarget?.source {
            if let recent = lastIdentifiedTarget, recent.lastSeenAt > pickedAt {
                panelTarget = PanelTargetContext(bundleID: recent.bundleID, source: .recentScroll(at: recent.lastSeenAt))
            }
            return
        }
        if let recent = lastIdentifiedTarget {
            panelTarget = PanelTargetContext(bundleID: recent.bundleID, source: .recentScroll(at: recent.lastSeenAt))
        }
    }

    /// "选择应用…"选定:立刻切换编辑对象,来源改为手动选择(§4.3)。
    /// 暂停、缺权限或服务故障时同样可用(空态不要求滚动触发识别,F08)。
    func selectPanelTarget(bundleID: String) {
        guard !bundleID.isEmpty else { return }
        panelTarget = PanelTargetContext(bundleID: bundleID, source: .manualPick(at: now()))
    }

    /// 目录刷新回调(主线程):更新展示副本。
    func noteCatalogSnapshot(_ snapshot: CatalogSnapshot) {
        catalogSnapshot = snapshot
    }

    /// 测试/fixture 注入口:直接覆盖最近识别事实(时间旅行、离线构造场景)。
    /// 生产代码不得调用。
    func setLastIdentifiedTargetForTesting(_ target: IdentifiedTarget?) {
        lastIdentifiedTarget = target
        objectWillChange.send()
    }

    /// 面板/管理窗口共用的当前覆盖查询。
    func overrideMode(forBundle bundleID: String) -> ScrollRuleMode {
        store.settings?.overrides[bundleID]?.mode ?? .inherit
    }

    // MARK: 故障与修复

    /// 引擎放弃重挂等致命故障上报:引擎侧已清场;状态分型为可重试的引擎故障。
    func noteEngineFailure(_ reason: String) {
        phase = .engineFailed(reason: reason)
    }

    /// 修复流程:重新读取规则。返回 nil = 成功并已按当前权限/意图启动服务。
    func repairReloadRules() -> String? {
        let outcome = store.load()
        rules.publish(store.settings)
        defaultFlip = store.settings?.defaultFlip ?? defaultFlip
        guard case .needsRecovery(let reason) = outcome else {
            if isTrusted() {
                if pauseIntent {
                    phase = .paused
                } else {
                    phase = Self.phaseAfterStart(engine.start())
                    if case .running = phase { confirmLoginItem() }
                }
            } else {
                phase = .onboarding
            }
            return nil
        }
        return reason
    }

    /// 修复流程:重置全部规则(用户在修复视图中明确确认后调用)。
    /// 返回 nil = 成功;否则为失败原因。
    func repairResetRules() -> String? {
        do {
            try store.resetAfterRecovery()
        } catch {
            return "重置失败:\((error as? RuleStoreError).map(Self.describe) ?? error.localizedDescription)"
        }
        rules.publish(store.settings)
        defaultFlip = store.settings?.defaultFlip ?? true
        if isTrusted() {
            phase = Self.phaseAfterStart(engine.start())
            if case .running = phase { confirmLoginItem() }
        } else {
            phase = .onboarding
        }
        return nil
    }

    /// 「退出」:无论当前态都清场——停 tap + 注销登录项;持久规则保留(AGENTS.md 约定)。
    func quit() {
        if engine.isRunning {
            engine.stop()
        }
        _ = loginItems.unregister()
    }

    // MARK: 内部

    /// 启动结果 → 状态分型(§9.1:权限与引擎不可用分开)。
    private static func phaseAfterStart(_ failure: EngineStartFailure?) -> AppPhase {
        guard let failure else { return .running }
        switch failure {
        case .notTrusted: return .needsPermission(reason: failure.description)
        case .tapUnavailable: return .engineFailed(reason: failure.description)
        }
    }

    /// 成功保存才生效(§6.1):落盘成功后发布新快照并同步 UI;失败保留旧值并显示错误。
    private func commit(target: SaveState.Target, _ change: (RuleStore) throws -> Void) {
        saveGeneration += 1
        let generation = saveGeneration
        do {
            try change(store)
        } catch {
            saveState = SaveState(
                target: target,
                succeeded: false,
                message: (error as? RuleStoreError).map(Self.describe) ?? "保存失败:\(error.localizedDescription)",
                generation: generation
            )
            rules.publish(store.settings) // 失败路径重发布,兜底防御任何旁路状态
            return
        }
        saveState = SaveState(
            target: target,
            succeeded: true,
            message: Self.successMessage(for: target, phase: phase, overrideCount: store.settings?.overrides.count ?? 0),
            generation: generation
        )
        rules.publish(store.settings)
        defaultFlip = store.settings?.defaultFlip ?? defaultFlip
        // 成功反馈约 2 秒后让位给稳定的结果说明(§5.3);错误不因定时器消失。
        scheduleAfter(2) { [weak self] in
            guard let self, self.saveState?.generation == generation, self.saveState?.succeeded == true else { return }
            self.saveState = nil
        }
    }

    /// 成功文案按服务状态区分生效条件(§5.3)。
    private static func successMessage(for target: SaveState.Target, phase: AppPhase, overrideCount: Int) -> String {
        let condition: String
        switch phase {
        case .running: condition = String(localized: "已保存,下一次滚轮操作生效")
        case .paused: condition = String(localized: "已保存,恢复后生效")
        case .onboarding, .needsPermission: condition = String(localized: "已保存,授权并重新打开后生效")
        case .engineFailed: condition = String(localized: "已保存,恢复运行后生效")
        case .rulesFailed: condition = String(localized: "已保存")
        }
        guard case .defaultDirection = target else { return condition }
        // 批量影响默认方向时附影响范围说明(§5.3),无需确认弹窗。
        if overrideCount > 0 {
            return condition + String(format: String(localized: ";仅影响跟随默认的应用,%ld 个应用保留单独设置"), overrideCount)
        }
        return condition + String(localized: ";仅影响跟随默认的应用")
    }

    private static func describe(_ error: RuleStoreError) -> String {
        switch error {
        case .saveFailed(let reason): return "保存失败,设置未更改:\(reason)"
        case .verificationFailed: return "保存后校验不一致,已回滚,设置未更改"
        case .notLoaded: return "规则未载入,无法保存"
        case .revisionMismatch: return "设置已被其他操作更新,请重试"
        case .needsRecovery(let reason): return "规则处于恢复模式:\(reason)"
        case .invalidInput(let reason): return "无效操作:\(reason)"
        }
    }

    /// 登录项注册/确认:在 phase 已发布之后异步执行(F01 根因处置:
    /// SMAppService XPC 不再插在"点击恢复"与"按钮重绘"之间)。
    private func confirmLoginItem() {
        let loginItems = self.loginItems
        scheduleAsync { [weak self] in
            self?.loginItemNotice = loginItems.register()
        }
    }

    /// 最近上下文的节流发布:身份变化立即发布;纯时间刷新至多每 2 秒一次。
    private func publishContextIfNeeded(bundleChanged: Bool) {
        let date = now()
        guard bundleChanged || date.timeIntervalSince(lastContextPublishAt) >= 2 else { return }
        lastContextPublishAt = date
        objectWillChange.send()
    }
}
