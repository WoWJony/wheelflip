import XCTest
@testable import WheelFlip

final class FakeEngine: FlipEngineControlling {
    var isRunning = false
    var startResult: EngineStartFailure?
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    func start() -> EngineStartFailure? {
        startCallCount += 1
        if let startResult { return startResult }
        isRunning = true
        return nil
    }

    func stop() {
        stopCallCount += 1
        isRunning = false
    }
}

final class FakeLoginItems: LoginItemManaging {
    var registerResult: String?
    var unregisterResult: String?
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0

    func register() -> String? {
        registerCallCount += 1
        return registerResult
    }

    func unregister() -> String? {
        unregisterCallCount += 1
        return unregisterResult
    }
}

/// 可控时钟 + 调度缝(测试注入同步/记录实现)。
/// now 闭包强捕获时钟(闭包会逃逸进 AppState,时钟对象不能先于它释放)。
final class TestClock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
    var now: () -> Date { { [clock = self] in clock.date } }
    func advance(_ seconds: TimeInterval) { date.addTimeInterval(seconds) }
}

/// S2 服务语义 + UX 改版 U1:状态分型、暂停/恢复呈现一致性、保存反馈绑定、面板上下文。
final class AppStateTests: RuleStoreTestBase {
    private func makeState(
        engine: FakeEngine = FakeEngine(),
        loginItems: FakeLoginItems = FakeLoginItems(),
        trusted: Bool = true,
        clock: TestClock = TestClock()
    ) -> (AppState, FakeEngine, FakeLoginItems, RuleSnapshotBox) {
        let rules = RuleSnapshotBox()
        let store = RuleStore(settingsURL: settingsURL, legacyDefaults: legacyDefaults)
        let state = AppState(
            engine: engine,
            rules: rules,
            store: store,
            isTrusted: { trusted },
            loginItems: loginItems,
            now: clock.now,
            scheduleAsync: { $0() },          // 登录项确认同步执行(F01 调度缝)
            scheduleAfter: { _, _ in }        // 成功提示不自动清除,由测试手动驱动
        )
        return (state, engine, loginItems, rules)
    }

    // MARK: 启动语义与错误分型(§9.1/T02)

    func testNoPermissionStartsInOnboardingAndEngineIdle() {
        let (state, engine, loginItems, _) = makeState(trusted: false)
        XCTAssertEqual(state.phase, .onboarding)
        XCTAssertEqual(engine.startCallCount, 0)
        XCTAssertEqual(loginItems.registerCallCount, 0)
    }

    func testTrustedFreshInstallRunsServiceAndRegistersLoginItem() {
        let (state, engine, loginItems, _) = makeState()
        XCTAssertEqual(state.phase, .running)
        XCTAssertEqual(engine.startCallCount, 1)
        XCTAssertEqual(loginItems.registerCallCount, 1, "登录项注册不再以默认翻转为条件(§3.2)")
        XCTAssertEqual(state.defaultFlip, true, "全新安装默认翻转")
    }

    func testLegacyDisabledStillRunsService() {
        legacyDefaults.set(false, forKey: RuleStore.legacyEnabledKey)
        let (state, engine, loginItems, _) = makeState()
        XCTAssertEqual(state.phase, .running)
        XCTAssertEqual(state.defaultFlip, false)
        XCTAssertEqual(engine.startCallCount, 1, "默认关不停止服务")
        XCTAssertEqual(loginItems.registerCallCount, 1)
    }

    func testCorruptRulesPreventServiceStart() {
        try? Data("garbage {{{".utf8).write(to: settingsURL)
        let (state, engine, loginItems, _) = makeState()
        XCTAssertEqual(state.phase, .rulesFailed(reason: state.phase.errorReason ?? ""),
                       "规则损坏进入 rulesFailed(独立于引擎故障)")
        XCTAssertEqual(engine.startCallCount, 0, "损坏时不修改任何事件")
        XCTAssertEqual(loginItems.registerCallCount, 0)
    }

    func testTapCreateFailureGoesToEngineFailedNotPermissionLost() {
        // T02:启动错误分型——tap 不可用 ≠ 权限丢失
        let engine = FakeEngine()
        engine.startResult = .tapUnavailable("CGEvent.tapCreate 失败")
        let (state, _, loginItems, _) = makeState(engine: engine)
        guard case .engineFailed(let reason) = state.phase else {
            return XCTFail("tap 失败应进入 engineFailed,实际 \(state.phase)")
        }
        XCTAssertTrue(reason.contains("tapCreate"))
        XCTAssertEqual(loginItems.registerCallCount, 0)
        let presentation = ServicePresentation.present(state.phase)
        XCTAssertEqual(presentation.primaryAction, .retryStart)
        XCTAssertEqual(presentation.title, "暂时无法运行")
    }

    func testResumeTapFailureGoesToEngineFailedWithRetryPath() {
        // T02:恢复时 tap 失败 → 按原因进入对应状态;重试成功后恢复
        let engine = FakeEngine()
        let (state, _, loginItems, _) = makeState(engine: engine)
        state.pauseAll()

        engine.startResult = .tapUnavailable("tap 创建失败")
        state.resumeRules()
        XCTAssertEqual(state.phase, .engineFailed(reason: "tap 创建失败"))
        XCTAssertEqual(loginItems.registerCallCount, 1, "启动失败不追加登录项确认")

        engine.startResult = nil
        state.retryEngineStart()
        XCTAssertEqual(state.phase, .running, "重试启动可恢复")
        XCTAssertEqual(engine.startCallCount, 3)
    }

    // MARK: 默认值与覆盖(引擎不启停)

    func testSetDefaultFlipPersistsAndKeepsEngineRunning() throws {
        let (state, engine, _, rules) = makeState()
        XCTAssertEqual(state.phase, .running)

        state.setDefaultFlip(false)
        XCTAssertEqual(state.defaultFlip, false)
        XCTAssertEqual(engine.stopCallCount, 0, "改默认值绝不停引擎")
        XCTAssertEqual(engine.isRunning, true)
        XCTAssertEqual(rules.current?.defaultFlip, false, "快照盒同步新值")

        state.setDefaultFlip(true)
        XCTAssertEqual(state.defaultFlip, true)

        let reloaded = RuleStore(settingsURL: settingsURL, legacyDefaults: legacyDefaults)
        XCTAssertEqual(reloaded.load(), .loaded)
        XCTAssertEqual(reloaded.settings?.defaultFlip, true)
    }

    func testSetDefaultFlipFailureSurfacesErrorAndKeepsOldValue() throws {
        let (state, engine, _, rules) = makeState()
        state.setDefaultFlip(false)
        XCTAssertEqual(state.defaultFlip, false)

        // 破坏写入路径:父目录换成普通文件(数据先挪到目录外,防止连坐删除)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("wheelflip-saved-\(UUID().uuidString).json")
        try FileManager.default.moveItem(at: settingsURL, to: outside)
        try FileManager.default.removeItem(at: tmpDir)
        try Data("x".utf8).write(to: tmpDir)
        defer {
            try? FileManager.default.removeItem(at: outside)
            try? FileManager.default.removeItem(at: tmpDir)
            try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        }

        state.setDefaultFlip(true)
        guard let saveState = state.saveState, case .defaultDirection = saveState.target, !saveState.succeeded else {
            return XCTFail("保存失败必须以绑定对象的失败反馈可见")
        }
        XCTAssertEqual(state.defaultFlip, false, "失败后 UI 值回退为旧值")
        XCTAssertEqual(rules.current?.defaultFlip, false, "快照盒保持旧规则")
        XCTAssertEqual(engine.stopCallCount, 0)

        // 恢复路径后可再次保存
        try FileManager.default.removeItem(at: tmpDir)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: outside, to: settingsURL)
        state.setDefaultFlip(true)
        XCTAssertEqual(state.saveState?.succeeded, true)
        XCTAssertEqual(state.defaultFlip, true)
    }

    func testSetOverridePublishesSnapshotAndPersists() throws {
        let (state, engine, _, rules) = makeState()
        state.setDefaultFlip(false)
        state.setOverride(bundleID: "dev.warp.Warp-Stable", mode: .forceOn)

        XCTAssertEqual(rules.decision(forBundle: "dev.warp.Warp-Stable", eventKind: .discrete)?.flips, true,
                       "默认关 + forceOn 生效")
        XCTAssertEqual(engine.stopCallCount, 0)
        guard case .appRule(let bundleID) = state.saveState?.target else {
            return XCTFail("保存反馈绑定到应用对象")
        }
        XCTAssertEqual(bundleID, "dev.warp.Warp-Stable")

        let reloaded = RuleStore(settingsURL: settingsURL, legacyDefaults: legacyDefaults)
        XCTAssertEqual(reloaded.load(), .loaded)
        XCTAssertEqual(reloaded.settings?.overrides["dev.warp.Warp-Stable"], RuleOverrideEntry(mode: .forceOn))
    }

    // MARK: 保存反馈文案(§5.3)

    func testSaveSuccessMessageReflectsServicePhase() {
        let (state, _, _, _) = makeState()
        state.setOverride(bundleID: "com.ex.a", mode: .forceOn)
        XCTAssertEqual(state.saveState?.succeeded, true)
        XCTAssertEqual(state.saveState?.message, "已保存,下一次滚轮操作生效")

        state.pauseAll()
        state.setOverride(bundleID: "com.ex.b", mode: .forceOff)
        XCTAssertEqual(state.saveState?.message, "已保存,恢复后生效")
    }

    func testDefaultDirectionSaveMessageIncludesScopeNote() {
        let (state, _, _, _) = makeState()
        state.setOverride(bundleID: "com.ex.a", mode: .forceOn)
        state.setDefaultFlip(false)
        XCTAssertEqual(state.saveState?.message,
                       "已保存,下一次滚轮操作生效;仅影响跟随默认的应用,1 个应用保留单独设置")
    }

    func testSaveFailurePersistsUntilSameTargetSucceeds() throws {
        // T08:失败绑定正确对象,错误不自动消失;同对象后续成功清除
        let (state, _, _, _) = makeState()
        state.setOverride(bundleID: "com.ex.warp", mode: .forceOff) // 合法保存

        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("wheelflip-saved-\(UUID().uuidString).json")
        try FileManager.default.moveItem(at: settingsURL, to: outside)
        try FileManager.default.removeItem(at: tmpDir)
        try Data("x".utf8).write(to: tmpDir)
        defer {
            try? FileManager.default.removeItem(at: outside)
            try? FileManager.default.removeItem(at: tmpDir)
            try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        }

        state.setOverride(bundleID: "com.ex.warp", mode: .forceOn)
        XCTAssertFalse(state.saveState?.succeeded ?? true, "失败反馈可见")
        // 其他对象的失败不覆盖(T08 防旧错误覆盖新结果由代次保证)
        state.setOverride(bundleID: "com.ex.other", mode: .forceOn)
        guard case .appRule(let target) = state.saveState?.target else { return XCTFail() }
        XCTAssertEqual(target, "com.ex.other", "最新反馈对应最新操作对象")

        try FileManager.default.removeItem(at: tmpDir)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: outside, to: settingsURL)
        state.setOverride(bundleID: "com.ex.warp", mode: .forceOn)
        XCTAssertEqual(state.saveState?.succeeded, true, "同对象成功覆盖旧错误")
    }

    func testSaveSuccessAutoClearFiresOnlyForCurrentGeneration() {
        // §5.3:成功短暂显示后清除;旧代次的清除不得抹掉新结果
        var pending: [(TimeInterval, () -> Void)] = []
        let rules = RuleSnapshotBox()
        let store = RuleStore(settingsURL: settingsURL, legacyDefaults: legacyDefaults)
        let state = AppState(
            engine: FakeEngine(), rules: rules, store: store,
            isTrusted: { true }, loginItems: FakeLoginItems(),
            now: TestClock().now,
            scheduleAsync: { $0() },
            scheduleAfter: { delay, action in pending.append((delay, action)) }
        )
        state.setOverride(bundleID: "com.ex.a", mode: .forceOn)
        state.setOverride(bundleID: "com.ex.b", mode: .forceOn) // 产生更新的代次
        let firstClear = pending[0].1
        firstClear() // 旧代次的清除闭包:不得清除当前(第 2 次)成功反馈
        XCTAssertEqual(state.saveState?.target, .appRule(bundleID: "com.ex.b"))
        pending[1].1() // 当前代次清除
        XCTAssertNil(state.saveState)
    }

    // MARK: 暂停/恢复呈现一致性(T01)

    func testPauseResumeMatrixKeepsTitleActionAndPrefixConsistent() {
        // T01:running → paused → running;标题、按钮动作、结果前缀与引擎生命周期一致,不重置规则
        let (state, engine, loginItems, rules) = makeState()
        state.setOverride(bundleID: "com.ex.rhino", mode: .forceOff)

        func expect(_ phase: AppPhase, title: String, action: ServicePresentation.Action, prefix: String) {
            let p = ServicePresentation.present(phase)
            XCTAssertEqual(p.title, title)
            XCTAssertEqual(p.primaryAction, action)
            XCTAssertEqual(p.resultPrefix, prefix)
            XCTAssertEqual(p.rulesEditable, true)
        }

        expect(state.phase, title: "已启用", action: .pauseAll, prefix: "按当前规则：")
        state.pauseAll()
        XCTAssertEqual(engine.isRunning, false, "暂停 = 完整 stop")
        XCTAssertEqual(state.phase, .paused)
        expect(state.phase, title: "已暂停", action: .resumeAll, prefix: "恢复后：")
        XCTAssertEqual(loginItems.unregisterCallCount, 0, "暂停保留登录项")
        XCTAssertEqual(state.store.settings?.overrides["com.ex.rhino"]?.mode, .forceOff, "暂停不动持久规则")

        state.resumeRules()
        XCTAssertEqual(state.phase, .running)
        XCTAssertEqual(engine.isRunning, true)
        expect(state.phase, title: "已启用", action: .pauseAll, prefix: "按当前规则：")
        XCTAssertEqual(engine.startCallCount, 2)
        XCTAssertEqual(loginItems.registerCallCount, 2, "恢复时确认注册状态")
        XCTAssertEqual(state.store.settings?.overrides["com.ex.rhino"]?.mode, .forceOff, "恢复不重置规则")

        _ = rules
    }

    func testPauseIsNoOpWhenNotRunning() {
        let (state, engine, _, _) = makeState(trusted: false)
        state.pauseAll()
        XCTAssertEqual(state.phase, .onboarding)
        XCTAssertEqual(engine.stopCallCount, 0)
    }

    func testResumeWithoutPermissionGoesToNeedsPermissionThenRecovers() {
        var trusted = true
        let rules = RuleSnapshotBox()
        let store = RuleStore(settingsURL: settingsURL, legacyDefaults: legacyDefaults)
        let engine = FakeEngine()
        let loginItems = FakeLoginItems()
        let state = AppState(engine: engine, rules: rules, store: store,
                             isTrusted: { trusted }, loginItems: loginItems,
                             now: TestClock().now, scheduleAsync: { $0() }, scheduleAfter: { _, _ in })
        state.pauseAll()

        trusted = false
        state.resumeRules()
        XCTAssertEqual(state.phase, .needsPermission(reason: "无辅助功能权限"))
        XCTAssertEqual(ServicePresentation.present(state.phase).primaryAction, .openAuthorization)

        trusted = true
        XCTAssertTrue(state.refreshPermission(), "重授权后可恢复服务")
        XCTAssertEqual(state.phase, .running)
    }

    func testPauseIntentNotCancelledByPermissionRefresh() {
        var trusted = false
        let rules = RuleSnapshotBox()
        let store = RuleStore(settingsURL: settingsURL, legacyDefaults: legacyDefaults)
        let engine = FakeEngine()
        let state = AppState(engine: engine, rules: rules, store: store,
                             isTrusted: { trusted }, loginItems: FakeLoginItems(),
                             now: TestClock().now, scheduleAsync: { $0() }, scheduleAfter: { _, _ in })
        XCTAssertEqual(state.phase, .onboarding)

        trusted = true
        XCTAssertTrue(state.refreshPermission())
        XCTAssertEqual(state.phase, .running)

        state.pauseAll()
        XCTAssertTrue(state.refreshPermission()) // 暂停期间的权限刷新
        XCTAssertEqual(state.phase, .paused, "暂停意图不被权限恢复取消")
        XCTAssertEqual(engine.startCallCount, 1)
    }

    func testRefreshPermissionReturnsFalseWhenStillDenied() {
        // F10:无权限的重新检查必须给出可见结论,不静默返回
        let (state, _, _, _) = makeState(trusted: false)
        XCTAssertFalse(state.refreshPermission())
        state.notePermissionRecheckStillDenied()
        XCTAssertNotNil(state.permissionNotice)
        XCTAssertTrue(state.permissionNotice?.contains("仍未检测到权限") ?? false)
    }

    // MARK: 引擎故障与修复

    func testEngineFailureReportSetsEngineFailedPhase() {
        let (state, _, _, _) = makeState()
        XCTAssertEqual(state.phase, .running)
        state.noteEngineFailure("滚轮 tap 连续超时已停用")
        XCTAssertEqual(state.phase, .engineFailed(reason: "滚轮 tap 连续超时已停用"))
        XCTAssertEqual(ServicePresentation.present(state.phase).primaryAction, .retryStart)
        XCTAssertEqual(ServicePresentation.present(state.phase).resultPrefix, "恢复运行后：")
    }

    func testFailedIsTerminalUntilQuitOrRepair() {
        let (state, engine, loginItems, _) = makeState()
        state.noteEngineFailure("滚轮 tap 连续超时")
        XCTAssertEqual(ServicePresentation.present(state.phase).rulesEditable, true,
                       "引擎故障仍可编辑规则(恢复运行后生效)")

        state.quit()
        XCTAssertEqual(engine.stopCallCount, 1, "FakeEngine 仍在跑,退出兜底 stop")
        XCTAssertEqual(loginItems.unregisterCallCount, 1)
    }

    func testRepairReloadRulesRecoversService() throws {
        try Data("garbage".utf8).write(to: settingsURL)
        let (state, engine, _, rules) = makeState()
        guard case .rulesFailed = state.phase else { return XCTFail("应进入 rulesFailed") }
        XCTAssertEqual(ServicePresentation.present(state.phase).rulesEditable, false,
                       "规则读取失败禁用规则编辑")
        XCTAssertNil(ServicePresentation.present(state.phase).resultPrefix,
                     "规则读取失败不展示猜测的默认方向(§5.1)")

        // 修复文件后重新读取 → 服务恢复
        let fresh = RuleSettings(defaultFlip: true)
        let encoder = JSONEncoder()
        try encoder.encode(fresh).write(to: settingsURL)
        XCTAssertNil(state.repairReloadRules())
        XCTAssertEqual(state.phase, .running)
        XCTAssertEqual(engine.startCallCount, 1)
        XCTAssertNotNil(rules.current, "修复后重新发布快照")
    }

    func testRepairResetRulesWritesFreshDefaults() throws {
        try Data("garbage".utf8).write(to: settingsURL)
        let (state, _, _, rules) = makeState()
        guard case .rulesFailed = state.phase else { return XCTFail() }

        XCTAssertNil(state.repairResetRules())
        XCTAssertEqual(state.phase, .running)
        XCTAssertEqual(state.defaultFlip, true)
        XCTAssertEqual(rules.current?.overrides, [:], "重置后无覆盖")
        let reloaded = RuleStore(settingsURL: settingsURL, legacyDefaults: legacyDefaults)
        XCTAssertEqual(reloaded.load(), .loaded)
    }

    // MARK: 事件上下文(§4.3/T05/T07)

    func testNoteEngineEventUpdatesLastIdentified() {
        let (state, _, _, _) = makeState()
        XCTAssertNil(state.lastIdentifiedTarget)
        state.noteEngineEvent(.init(flipped: true, bundleID: "dev.warp.Warp-Stable", source: .appOverride(.forceOn)))
        XCTAssertEqual(state.lastIdentifiedTarget?.bundleID, "dev.warp.Warp-Stable")
    }

    /// §7.4「异步合并」+ §9.1 节流:面板上下文只含身份与时间;
    /// 同一 App 的重复事件(结果是否变化)不逐次发布,身份变化必须发布。
    /// 规则结果的呈现变化由 saveState/规则发布驱动,不依赖事件流。
    func testNoteEngineEventCoalescesSameAppEvents() {
        let (state, _, _, _) = makeState()
        var publishCount = 0
        let cancellable = state.objectWillChange.sink { _ in publishCount += 1 }
        defer { cancellable.cancel() }

        let outcome = FlipEngine.EventOutcome(flipped: true, bundleID: "dev.warp.Warp-Stable", source: .globalDefault)
        state.noteEngineEvent(outcome)
        state.noteEngineEvent(outcome)
        state.noteEngineEvent(outcome)
        XCTAssertEqual(publishCount, 1, "同一 App 的重复事件只发布一次(时钟未走)")

        // 结果变化但身份未变:面板上下文(身份+时间)不变,不因事件流重绘
        state.noteEngineEvent(.init(flipped: false, bundleID: "dev.warp.Warp-Stable", source: .appOverride(.forceOff)))
        XCTAssertEqual(publishCount, 1)

        // 身份变化必须发布
        state.noteEngineEvent(.init(flipped: false, bundleID: "com.ex.rhino", source: .globalDefault))
        XCTAssertEqual(publishCount, 2)
    }

    func testContinuousEventsNeitherReplaceTargetNorMarkFailure() {
        // T07:连续事件不替换普通滚轮目标,也不伪造识别失败
        let (state, _, _, _) = makeState()
        state.noteEngineEvent(.init(flipped: true, bundleID: "com.ex.warp", source: .globalDefault))
        state.noteEngineEvent(.init(flipped: false, bundleID: nil, source: .continuousPassthrough))
        XCTAssertEqual(state.lastIdentifiedTarget?.bundleID, "com.ex.warp")
        XCTAssertNil(state.lastDiscreteFailureAt, "连续事件不算识别失败")
    }

    func testUnresolvableDiscreteEventMarksFailureButKeepsOldTarget() {
        // T07:识别失败的普通滚轮事件 → 记录失败时间;旧有效目标保留
        let clock = TestClock()
        let (state, _, _, _) = makeState(clock: clock)
        state.noteEngineEvent(.init(flipped: true, bundleID: "com.ex.warp", source: .globalDefault))
        state.noteEngineEvent(.init(flipped: true, bundleID: nil, source: .globalDefault))
        XCTAssertEqual(state.lastIdentifiedTarget?.bundleID, "com.ex.warp", "旧目标保留")
        XCTAssertNotNil(state.lastDiscreteFailureAt, "识别失败被记录")
    }

    func testIdentifiedEventClearsPriorFailure() {
        let (state, _, _, _) = makeState()
        state.noteEngineEvent(.init(flipped: true, bundleID: nil, source: .globalDefault))
        XCTAssertNotNil(state.lastDiscreteFailureAt)
        state.noteEngineEvent(.init(flipped: true, bundleID: "com.ex.warp", source: .globalDefault))
        XCTAssertNil(state.lastDiscreteFailureAt, "后续成功识别使失败提示过期")
    }

    // MARK: 面板编辑对象(§4.3/T05/T06)

    func testPanelTargetPinnedAtPopoverShowAndFrozenWhileShown() {
        let (state, _, _, _) = makeState()
        XCTAssertNil(state.panelTarget)

        state.noteEngineEvent(.init(flipped: true, bundleID: "com.ex.warp", source: .globalDefault))
        state.pinPanelTarget()
        XCTAssertEqual(state.panelTarget?.bundleID, "com.ex.warp")

        // 展示期间新事件不改变固定对象(T05:编辑对象不跳)
        state.noteEngineEvent(.init(flipped: false, bundleID: "com.ex.rhino", source: .appOverride(.forceOff)))
        XCTAssertEqual(state.panelTarget?.bundleID, "com.ex.warp")
        XCTAssertEqual(state.lastIdentifiedTarget?.bundleID, "com.ex.rhino", "引擎上下文照常更新")
    }

    func testManualPickStickyWhenNoNewerExternalEvent() {
        // T06:手选 → 关闭 → 重开,期间没有新的有效外部事件 → 继续编辑手选应用
        let clock = TestClock()
        let (state, _, _, _) = makeState(clock: clock)
        state.noteEngineEvent(.init(flipped: true, bundleID: "com.ex.warp", source: .globalDefault))
        state.selectPanelTarget(bundleID: "com.ex.rhino")
        guard case .manualPick = state.panelTarget?.source else { return XCTFail("手选来源") }

        clock.advance(10)
        state.pinPanelTarget() // 关闭再打开
        XCTAssertEqual(state.panelTarget?.bundleID, "com.ex.rhino", "无更新事件时手选粘滞")
        guard case .manualPick = state.panelTarget?.source else { return XCTFail() }
    }

    func testNewerExternalEventReplacesStaleManualPick() {
        // T06:关闭期间出现比手选更新的有效外部事件 → 下次打开推荐最新识别应用
        let clock = TestClock()
        let (state, _, _, _) = makeState(clock: clock)
        state.noteEngineEvent(.init(flipped: true, bundleID: "com.ex.warp", source: .globalDefault))
        state.selectPanelTarget(bundleID: "com.ex.rhino")

        clock.advance(30)
        state.noteEngineEvent(.init(flipped: false, bundleID: "com.ex.tool", source: .globalDefault))
        state.pinPanelTarget()
        XCTAssertEqual(state.panelTarget?.bundleID, "com.ex.tool", "推荐最新识别应用")
        guard case .recentScroll = state.panelTarget?.source else { return XCTFail("来源如实切换为最近识别") }
    }

    func testSameAppRepeatedScrollRefreshesTimeFactWithoutPublishing() {
        // §9.1:同一 App 连续滚动仍刷新"最近"的事实,但只在有限频率发布
        let clock = TestClock()
        let (state, _, _, _) = makeState(clock: clock)
        state.noteEngineEvent(.init(flipped: true, bundleID: "com.ex.warp", source: .globalDefault))
        let firstSeen = state.lastIdentifiedTarget?.lastSeenAt

        var publishCount = 0
        let cancellable = state.objectWillChange.sink { _ in publishCount += 1 }
        defer { cancellable.cancel() }

        clock.advance(1)
        state.noteEngineEvent(.init(flipped: true, bundleID: "com.ex.warp", source: .globalDefault))
        XCTAssertNotEqual(firstSeen, state.lastIdentifiedTarget?.lastSeenAt, "时间事实已刷新")
        XCTAssertEqual(publishCount, 0, "1 秒内的纯时间刷新不发布")

        clock.advance(2)
        state.noteEngineEvent(.init(flipped: true, bundleID: "com.ex.warp", source: .globalDefault))
        XCTAssertEqual(publishCount, 1, "超过节流窗口的时间刷新发布一次")
    }

    func testSelectPanelTargetWorksWhilePausedOrUntrusted() {
        // F08:暂停、缺权限时手动选择可用
        let (state, _, _, _) = makeState()
        state.pauseAll()
        state.selectPanelTarget(bundleID: "com.ex.rhino")
        XCTAssertEqual(state.panelTarget?.bundleID, "com.ex.rhino")

        let (state2, _, _, _) = makeState(trusted: false)
        state2.selectPanelTarget(bundleID: "com.ex.rhino")
        XCTAssertEqual(state2.panelTarget?.bundleID, "com.ex.rhino")
    }

    /// §3.3:WheelFlip 自己的窗口按默认处理,且不替换"上次滚动的外部 App"上下文。
    func testOwnWindowEventsDoNotReplaceTarget() {
        let rules = RuleSnapshotBox()
        let state = AppState(
            engine: FakeEngine(), rules: rules,
            store: RuleStore(settingsURL: settingsURL, legacyDefaults: legacyDefaults),
            isTrusted: { true }, loginItems: FakeLoginItems(),
            ownBundleID: "com.jonywu.WheelFlip",
            now: TestClock().now, scheduleAsync: { $0() }, scheduleAfter: { _, _ in }
        )
        state.noteEngineEvent(.init(flipped: true, bundleID: "com.ex.warp", source: .globalDefault))
        state.noteEngineEvent(.init(flipped: true, bundleID: "com.jonywu.WheelFlip", source: .globalDefault))
        XCTAssertEqual(state.lastIdentifiedTarget?.bundleID, "com.ex.warp",
                       "自己窗口的事件不得替换上次滚动的外部 App")
    }

    /// 空 Bundle ID 的覆盖必须被拒(纵深防御)。
    func testEmptyBundleIDOverrideRejected() {
        let (state, _, _, _) = makeState()
        state.setOverride(bundleID: "", mode: .forceOn)
        XCTAssertFalse(state.saveState?.succeeded ?? true, "空 Bundle ID 必须报错")
        XCTAssertNil(state.store.settings?.overrides[""])
    }

    // MARK: 退出

    func testQuitWhileRunningStopsEngineAndUnregistersLoginItem() {
        let (state, engine, loginItems, _) = makeState()
        XCTAssertEqual(state.phase, .running)
        state.quit()
        XCTAssertEqual(engine.stopCallCount, 1)
        XCTAssertEqual(loginItems.unregisterCallCount, 1)
    }

    func testQuitFromPausedUnregistersWithoutExtraStop() {
        let (state, engine, loginItems, _) = makeState()
        state.pauseAll()
        XCTAssertEqual(engine.stopCallCount, 1)
        state.quit()
        XCTAssertEqual(engine.stopCallCount, 1, "暂停时已停,退出不再重复 stop")
        XCTAssertEqual(loginItems.unregisterCallCount, 1, "退出无论如何都清登录项")
    }

    func testActivateSurfacesLoginItemNotice() {
        let loginItems = FakeLoginItems()
        loginItems.registerResult = "登录自动启动待确认:请在 系统设置 → 登录项 里批准"
        let (state, _, _, _) = makeState(loginItems: loginItems)
        XCTAssertEqual(state.loginItemNotice, "登录自动启动待确认:请在 系统设置 → 登录项 里批准")
    }

    func testLegacyCLIDetectedFlagIsExposedAsGiven() {
        let rules = RuleSnapshotBox()
        let store = RuleStore(settingsURL: settingsURL, legacyDefaults: legacyDefaults)
        let state = AppState(engine: FakeEngine(), rules: rules, store: store,
                             isTrusted: { true }, loginItems: FakeLoginItems(),
                             legacyCLIDetected: true,
                             now: TestClock().now, scheduleAsync: { $0() }, scheduleAfter: { _, _ in })
        XCTAssertTrue(state.legacyCLIDetected)
    }
}

// MARK: - 测试辅助

extension AppPhase {
    /// 关联值原因(测试断言用)。
    var errorReason: String? {
        switch self {
        case .onboarding, .running, .paused: return nil
        case .needsPermission(let reason), .engineFailed(let reason), .rulesFailed(let reason):
            return reason
        }
    }
}
