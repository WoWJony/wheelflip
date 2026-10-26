import XCTest
@testable import WheelFlip

/// UX §6 应用规则窗口模型:并集列表(F12/T09)、条件结果、保存反馈绑定(F11)、
/// 添加定位与失败可见(F13/T10)、空态与筛选(§6.3)、面板编辑对象(§4.1/§4.3)。
final class AppManagementModelTests: RuleStoreTestBase {
    private var manualURL: URL { tmpDir.appendingPathComponent("manual.json") }

    private func makeModel(state: AppState? = nil) -> (AppManagementModel, AppState, ManualAppStore) {
        let manual = ManualAppStore(fileURL: manualURL,
                                    createBookmark: { _ in nil }, resolveBookmark: { _ in nil })
        let appState = state ?? AppState(
            engine: FakeEngine(), rules: RuleSnapshotBox(),
            store: RuleStore(settingsURL: settingsURL, legacyDefaults: legacyDefaults),
            isTrusted: { true }, loginItems: FakeLoginItems(), ownBundleID: nil,
            now: TestClock().now, scheduleAsync: { $0() }, scheduleAfter: { _, _ in }
        )
        let model = AppManagementModel(appState: appState, manualApps: manual, icons: nil,
                                       requestCatalogRefresh: {})
        return (model, appState, manual)
    }

    private func snapshot(entries: [CatalogEntry]) -> CatalogSnapshot {
        CatalogSnapshot(entries: entries, sourceStates: [.completed(found: entries.count)],
                        generatedAt: Date(timeIntervalSince1970: 0))
    }

    private func entry(_ bundleID: String, name: String,
                       presence: AppCatalog.Presence = .present) -> CatalogEntry {
        CatalogEntry(bundleID: bundleID, displayName: name, displayNameSource: .directory,
                     appPaths: ["/Applications/\(name).app"], isSystem: false, runningPIDs: [],
                     sources: [.directory], presence: presence)
    }

    // MARK: 列表/搜索/筛选

    func testRowsSortedWithSearchAndCustomizedFilter() throws {
        let (model, appState, _) = makeModel()
        try appState.setOverride(bundleID: "com.ex.rhino", mode: .forceOff)
        model.reload(from: snapshot(entries: [
            entry("com.ex.warp", name: "Warp"),
            entry("com.ex.rhino", name: "Rhino"),
            entry("com.ex.tool", name: "Tool"),
        ]))

        XCTAssertEqual(model.rows.map(\.displayName), ["Rhino", "Tool", "Warp"],
                       "默认按本地化名称稳定排序")
        XCTAssertEqual(model.rows.filter(\.hasOverride).map(\.displayName), ["Rhino"])

        model.filter = .customized
        XCTAssertEqual(model.rows.map(\.displayName), ["Rhino"], "单独设置 = 有覆盖,与默认值无关")

        model.filter = .all
        model.searchText = "warp"
        XCTAssertEqual(model.rows.map(\.displayName), ["Warp"], "搜索名称")
        model.searchText = "com.ex.tool"
        XCTAssertEqual(model.rows.map(\.displayName), ["Tool"], "搜索 Bundle ID")
        model.searchText = "不存在"
        XCTAssertTrue(model.rows.isEmpty)
    }

    /// §4.2:"单独设置"不取决于与默认值是否相同——同值覆盖也显示为已自定义。
    func testSameEffectOverrideCountsAsCustomized() throws {
        let (model, appState, _) = makeModel()
        try appState.setOverride(bundleID: "com.ex.warp", mode: .forceOn) // 与默认(true)同效果
        model.reload(from: snapshot(entries: [entry("com.ex.warp", name: "Warp")]))
        model.filter = .customized
        XCTAssertEqual(model.rows.count, 1, "同值覆盖也是明确保存的覆盖")
        XCTAssertEqual(model.rows[0].mode, .forceOn)
    }

    /// 首次打开默认筛选(§6.1):已有覆盖 → 单独设置;没有 → 全部应用。
    func testInitialFilterDefaultsByOverridePresence() {
        let (model, _, _) = makeModel()
        XCTAssertEqual(model.filter, .all, "无覆盖默认全部应用")

        let manual = ManualAppStore(fileURL: manualURL, createBookmark: { _ in nil }, resolveBookmark: { _ in nil })
        let state = AppState(
            engine: FakeEngine(), rules: RuleSnapshotBox(),
            store: RuleStore(settingsURL: settingsURL, legacyDefaults: legacyDefaults),
            isTrusted: { true }, loginItems: FakeLoginItems(), ownBundleID: nil,
            now: TestClock().now, scheduleAsync: { $0() }, scheduleAfter: { _, _ in }
        )
        state.setOverride(bundleID: "com.ex.a", mode: .forceOn)
        let model2 = AppManagementModel(appState: state, manualApps: manual, icons: nil,
                                        requestCatalogRefresh: {})
        XCTAssertEqual(model2.filter, .customized, "已有覆盖默认单独设置")
    }

    // MARK: 并集列表(F12/T09)

    func testOverrideWithoutCatalogEntryStaysVisible() throws {
        // T09:覆盖存在、目录无条目 → 在单独设置列表仍可见,可改回默认
        let (model, appState, _) = makeModel()
        try appState.setOverride(bundleID: "com.ex.ghost", mode: .forceOn)
        model.reload(from: snapshot(entries: [entry("com.ex.warp", name: "Warp")]))

        model.filter = .customized
        XCTAssertEqual(model.rows.map(\.bundleID), ["com.ex.ghost"])
        XCTAssertEqual(model.rows[0].presence, .unconfirmed, "位置待确认,不是已卸载")
        XCTAssertEqual(model.rows[0].presenceCaption, "位置待确认 · 设置保留")

        // 未知位置:名称退回 Bundle ID;有历史位置则由位置推导
        XCTAssertEqual(model.rows[0].displayName, "com.ex.ghost")
    }

    func testOverrideNameDerivedFromRecordedLocation() throws {
        let (model, appState, _) = makeModel()
        try appState.setOverride(bundleID: "com.ex.hidden", mode: .forceOn)
        try appState.store.updateOverrideMetadata(bundleID: "com.ex.hidden") { entry in
            entry.locations = ["/Volumes/Extra/Hidden.app"]
        }
        model.reload(from: snapshot(entries: []))
        XCTAssertEqual(model.rows.first?.displayName, "Hidden", "名称由历史位置推导")
        XCTAssertEqual(model.rows.first?.presence, .unconfirmed)
    }

    func testMissingOverrideMarkedNotFoundButKept() throws {
        // §6.2 表第 4 行:已确认位置缺失、宽限期内 → 未找到此应用,规则保留
        let (model, appState, _) = makeModel()
        try appState.setOverride(bundleID: "com.ex.gone", mode: .forceOff)
        try appState.store.updateOverrideMetadata(bundleID: "com.ex.gone") { entry in
            entry.missingSince = Date(timeIntervalSinceNow: -3600)
        }
        model.reload(from: snapshot(entries: [entry("com.ex.gone", name: "GoneApp", presence: .missing)]))
        XCTAssertEqual(model.rows[0].presence, .missing)
        XCTAssertEqual(model.rows[0].presenceCaption, "未找到此应用 · 确认清理前保留设置")
        XCTAssertEqual(model.rows[0].mode, .forceOff, "规则仍可查看与改回默认")
    }

    // MARK: 即时生效结果(条件式表达)

    func testEffectTextReflectsDefaultAndOverride() throws {
        let (model, appState, _) = makeModel()
        try appState.setDefaultFlip(false)
        try appState.setOverride(bundleID: "com.ex.warp", mode: .forceOn)
        model.reload(from: snapshot(entries: [
            entry("com.ex.warp", name: "Warp"),
            entry("com.ex.rhino", name: "Rhino"),
        ]))

        let warp = model.rows.first { $0.bundleID == "com.ex.warp" }!
        let rhino = model.rows.first { $0.bundleID == "com.ex.rhino" }!
        XCTAssertEqual(model.effectText(for: warp), "反转 · 单独设置")
        XCTAssertEqual(model.effectText(for: rhino), "保持原方向 · 跟随默认")

        try appState.setDefaultFlip(true) // 改默认只影响继承项
        XCTAssertEqual(model.effectText(for: rhino), "反转 · 跟随默认")
        XCTAssertEqual(model.effectText(for: warp), "反转 · 单独设置")
    }

    /// §6.1/§5.1:暂停/缺权限/故障下结果列为条件式;规则读取失败不展示猜测默认值。
    func testResultColumnTitleAndEffectFollowServicePhase() throws {
        let (model, appState, _) = makeModel()
        try appState.setOverride(bundleID: "com.ex.warp", mode: .forceOn)
        model.reload(from: snapshot(entries: [entry("com.ex.warp", name: "Warp")]))

        XCTAssertEqual(model.resultColumnTitle, "按规则执行")
        appState.pauseAll()
        XCTAssertEqual(model.resultColumnTitle, "恢复后执行")
        appState.resumeRules()
        XCTAssertEqual(model.resultColumnTitle, "按规则执行")

        appState.noteEngineFailure("tap 放弃")
        XCTAssertEqual(model.resultColumnTitle, "恢复运行后执行")
        XCTAssertEqual(model.rulesEditable, true, "引擎故障仍可编辑")
    }

    func testRulesFailedDisablesEditingAndHidesComputedEffect() throws {
        try Data("garbage".utf8).write(to: settingsURL)
        let (model, _, _) = makeModel()
        model.reload(from: snapshot(entries: [entry("com.ex.warp", name: "Warp")]))
        XCTAssertEqual(model.rulesEditable, false, "规则读取失败禁用编辑")
        XCTAssertEqual(model.effectText(for: model.rows[0]), "无法计算", "不展示猜测的默认方向")
    }

    // MARK: 保存反馈绑定(F11/T08)

    func testSetOverrideFailureSurfacesBoundErrorAndKeepsOldMode() throws {
        let (model, appState, _) = makeModel()
        try appState.setOverride(bundleID: "com.ex.warp", mode: .forceOff)
        model.reload(from: snapshot(entries: [entry("com.ex.warp", name: "Warp")]))

        // 破坏写入路径:父目录换成普通文件
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

        // 真实 UI 入口驱动失败的保存
        model.setOverride(bundleID: "com.ex.warp", mode: .forceOn)
        XCTAssertEqual(model.saveErrorText(forBundle: "com.ex.warp"), appState.saveState?.message,
                       "行内错误紧邻失败控件")
        XCTAssertNil(model.saveErrorText(forBundle: "com.ex.other"), "错误不波及其他对象")
        XCTAssertEqual(appState.overrideMode(forBundle: "com.ex.warp"), .forceOff,
                       "RuleStore 未变,UI 回读旧选择")

        // 恢复路径后可再次保存,错误清除(同一份状态,两处界面一起清除)
        try FileManager.default.removeItem(at: tmpDir)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: outside, to: settingsURL)
        model.setOverride(bundleID: "com.ex.warp", mode: .forceOn)
        XCTAssertNil(model.saveErrorText(forBundle: "com.ex.warp"))
        XCTAssertEqual(appState.overrideMode(forBundle: "com.ex.warp"), .forceOn)
    }

    // MARK: 面板固定编辑对象(§4.1/§4.3)

    func testPanelTargetPinnedAtPopoverShow() {
        let (_, appState, _) = makeModel()
        XCTAssertNil(appState.panelTarget)

        appState.noteEngineEvent(.init(flipped: true, bundleID: "com.ex.warp", source: .globalDefault))
        appState.pinPanelTarget()
        XCTAssertEqual(appState.panelTarget?.bundleID, "com.ex.warp")
    }

    /// §4.1:只固定"成功识别"的目标;触控板/解析失败(nil bundleID)不得占据面板上下文。
    func testNilBundleIDEventsDoNotOccupyPanelTarget() {
        let (_, appState, _) = makeModel()
        appState.noteEngineEvent(.init(flipped: true, bundleID: "com.ex.warp", source: .globalDefault))
        appState.noteEngineEvent(.init(flipped: false, bundleID: nil, source: .continuousPassthrough))
        appState.noteEngineEvent(.init(flipped: true, bundleID: nil, source: .globalDefault))
        appState.pinPanelTarget()
        XCTAssertEqual(appState.panelTarget?.bundleID, "com.ex.warp",
                       "无身份事件不得替换上次成功识别的外部目标")
    }

    // MARK: 手工添加与移除(§6.3/T10)

    private func makeAppBundle(named name: String, bundleID: String) throws -> URL {
        let app = tmpDir.appendingPathComponent("\(name).app")
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("Contents/Macos"), withIntermediateDirectories: true)
        let plist = """
        <plist version="1.0"><dict><key>CFBundleIdentifier</key><string>\(bundleID)</string></dict></plist>
        """
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
        return app
    }

    func testAddManualAppValidatesAndRecords() throws {
        let (model, _, manual) = makeModel()

        // 非 .app 路径拒绝
        XCTAssertNotNil(model.addManualApp(url: URL(fileURLWithPath: "/etc/hosts")))

        let app = try makeAppBundle(named: "Custom", bundleID: "com.ex.custom")
        XCTAssertNil(model.addManualApp(url: app))
        XCTAssertNotNil(manual.entry(bundleID: "com.ex.custom"))
        XCTAssertTrue(model.isManual(bundleID: "com.ex.custom"))
    }

    func testAddManualAppLocatesRowAndSwitchesHidingFilter() throws {
        // F13/T10:添加成功即定位;当前筛选会隐藏该项时转到可见列表
        let (model, appState, _) = makeModel()
        try appState.setOverride(bundleID: "com.ex.rhino", mode: .forceOff)
        model.reload(from: snapshot(entries: [entry("com.ex.rhino", name: "Rhino")]))
        model.filter = .customized // 模拟"单独设置"视图下添加一个新应用

        let app = try makeAppBundle(named: "Custom", bundleID: "com.ex.custom")
        XCTAssertNil(model.addManualApp(url: app))
        XCTAssertEqual(model.additionTarget, "com.ex.custom", "新条目被定位")
        XCTAssertEqual(model.filter, .all, "被筛选隐藏时转到可见列表")
        XCTAssertNotNil(model.additionNotice, "添加提示可见")
        XCTAssertTrue(model.rows.contains { $0.bundleID == "com.ex.custom" }, "新增后立即可见,不等扫描")
    }

    func testAddDuplicateManualAppLocatesExistingWithoutNewRule() throws {
        // T10:同一身份不重复创建规则,定位已有条目
        let (model, appState, _) = makeModel()
        try appState.setOverride(bundleID: "com.ex.custom", mode: .forceOff)
        model.reload(from: snapshot(entries: []))

        let app = try makeAppBundle(named: "Custom", bundleID: "com.ex.custom")
        XCTAssertNil(model.addManualApp(url: app))
        XCTAssertTrue(model.additionNotice?.contains("已在列表中") ?? false)
        XCTAssertEqual(appState.store.settings?.overrides.count, 1, "不重复创建规则")
        let matching = model.rows.filter { $0.bundleID == "com.ex.custom" }
        XCTAssertEqual(matching.count, 1, "列表中只有一行")
    }

    func testRemoveManualAppClearsRecordKeepsOverrideAndSurfacesFailure() throws {
        // T10:取消手动添加 → 移除记录、保留规则;失败不吞掉
        let (model, appState, manual) = makeModel()
        let app = try makeAppBundle(named: "Custom", bundleID: "com.ex.custom")
        XCTAssertNil(model.addManualApp(url: app))
        try appState.setOverride(bundleID: "com.ex.custom", mode: .forceOff)

        XCTAssertNil(model.removeManualApp(bundleID: "com.ex.custom"))
        XCTAssertFalse(model.isManual(bundleID: "com.ex.custom"), "补录记录移除")
        XCTAssertNil(manual.entry(bundleID: "com.ex.custom"), "书签清除")
        XCTAssertEqual(appState.overrideMode(forBundle: "com.ex.custom"), .forceOff,
                       "覆盖规则独立于补录记录保留")

        // 移除不存在的记录:错误可见,不是静默成功
        XCTAssertNotNil(model.removeManualApp(bundleID: "com.ex.absent"))
        XCTAssertNotNil(model.rowActionError)
    }

    // MARK: 空态与来源提示(§6.3)

    func testSourceNoticeOnlyWhenAnySourceFailed() {
        let (model, _, _) = makeModel()
        model.reload(from: CatalogSnapshot(entries: [], sourceStates: [.completed(found: 0)],
                                           generatedAt: Date()))
        XCTAssertNil(model.sourceNotice)
        model.reload(from: CatalogSnapshot(
            entries: [],
            sourceStates: [.completed(found: 0), .failed("目录 /Users/x/Applications 不可读")],
            generatedAt: Date()
        ))
        XCTAssertNotNil(model.sourceNotice, "来源受限可见提示")
    }

    func testInitialScanningOnlyWhenNoSnapshotAndNoOverrides() throws {
        let (model, appState, _) = makeModel()
        XCTAssertTrue(model.isInitialScanning, "无快照且无覆盖 → 首轮扫描中")

        try appState.setOverride(bundleID: "com.ex.ghost", mode: .forceOn)
        XCTAssertFalse(model.isInitialScanning, "已保存规则可以先展示,不整窗空等")
    }

    /// §4.2:缺权限时允许浏览与编辑(授权后生效提示可见)。
    func testOnboardingStillAllowsEditingAndShowsNotice() throws {
        let manual = ManualAppStore(fileURL: manualURL, createBookmark: { _ in nil }, resolveBookmark: { _ in nil })
        let state = AppState(
            engine: FakeEngine(), rules: RuleSnapshotBox(),
            store: RuleStore(settingsURL: settingsURL, legacyDefaults: legacyDefaults),
            isTrusted: { false }, loginItems: FakeLoginItems(), ownBundleID: nil,
            now: TestClock().now, scheduleAsync: { $0() }, scheduleAfter: { _, _ in }
        )
        XCTAssertEqual(state.phase, .onboarding)
        let model = AppManagementModel(appState: state, manualApps: manual, icons: nil, requestCatalogRefresh: {})

        state.setOverride(bundleID: "com.ex.warp", mode: .forceOff) // 无权限也可编辑并落盘
        XCTAssertFalse(state.saveState?.succeeded == false)
        XCTAssertEqual(state.store.settings?.overrides["com.ex.warp"], RuleOverrideEntry(mode: .forceOff))
        XCTAssertEqual(model.resultColumnTitle, "授权后执行", "条件式表达")
    }

    /// T11:目录更新不重置搜索与筛选。
    func testReloadKeepsSearchAndFilter() {
        let (model, _, _) = makeModel()
        model.reload(from: snapshot(entries: [entry("com.ex.warp", name: "Warp")]))
        model.searchText = "warp"
        model.filter = .customized
        model.reload(from: snapshot(entries: [
            entry("com.ex.warp", name: "Warp"),
            entry("com.ex.rhino", name: "Rhino"),
        ]))
        XCTAssertEqual(model.searchText, "warp", "搜索保留")
        XCTAssertEqual(model.filter, .customized, "筛选保留")
    }

    /// F16:同名应用有区分信息。
    func testDuplicateNamesGetDisambiguation() {
        let (model, _, _) = makeModel()
        let toolA = CatalogEntry(bundleID: "com.ex.toolA", displayName: "Tool",
                                 displayNameSource: .directory, appPaths: ["/Applications/Tool.app"],
                                 isSystem: false, runningPIDs: [], sources: [.directory], presence: .present)
        let toolB = CatalogEntry(bundleID: "com.ex.toolB", displayName: "Tool",
                                 displayNameSource: .directory, appPaths: ["/Users/fix/Downloads/Tool.app"],
                                 isSystem: false, runningPIDs: [], sources: [.directory], presence: .present)
        model.reload(from: snapshot(entries: [toolA, toolB, entry("com.ex.warp", name: "Warp")]))
        XCTAssertEqual(model.duplicateNames, ["Tool"])
        let rows = model.rows.filter { $0.displayName == "Tool" }
        XCTAssertEqual(rows.count, 2)
        XCTAssertNotEqual(rows[0].appPaths.first, rows[1].appPaths.first, "位置可用于区分")
    }
}
