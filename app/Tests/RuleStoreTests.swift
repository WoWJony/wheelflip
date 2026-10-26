import XCTest
@testable import WheelFlip

/// RuleStore 测试公共夹具:临时目录 + 固定名 defaults suite(先清后用,不留堆积)。
class RuleStoreTestBase: XCTestCase {
    static let defaultsSuiteName = "com.jonywu.WheelFlip.RuleStoreTests"

    var tmpDir: URL!
    var legacyDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wheelflip-rulestore-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        UserDefaults.standard.removePersistentDomain(forName: Self.defaultsSuiteName)
        legacyDefaults = UserDefaults(suiteName: Self.defaultsSuiteName)!
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: Self.defaultsSuiteName)
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    var settingsURL: URL { tmpDir.appendingPathComponent("rules.json") }

    func makeLoadedStore() -> RuleStore {
        let store = RuleStore(settingsURL: settingsURL, legacyDefaults: legacyDefaults)
        store.load()
        return store
    }
}

final class RuleStoreTests: RuleStoreTestBase {
    func testSavePersistsAndReloadsAcrossInstances() throws {
        let store = makeLoadedStore()
        try store.setOverride(bundleID: "dev.warp.Warp-Stable", mode: .forceOff)
        try store.setDefaultFlip(false)

        let reloaded = RuleStore(settingsURL: settingsURL, legacyDefaults: legacyDefaults)
        XCTAssertEqual(reloaded.load(), .loaded)
        let snapshot = try XCTUnwrap(reloaded.settings)
        XCTAssertFalse(snapshot.defaultFlip)
        XCTAssertEqual(snapshot.overrides["dev.warp.Warp-Stable"], RuleOverrideEntry(mode: .forceOff))
    }

    func testSameEffectOverrideIsStillPersisted() throws {
        // §3.1:forceOn 与当前默认值相同,也必须持久保存;以后改默认值不能改变这条明确选择
        let store = makeLoadedStore()
        XCTAssertTrue(store.settings?.defaultFlip ?? false)
        try store.setOverride(bundleID: "com.example.app", mode: .forceOn)
        XCTAssertEqual(store.settings?.overrides["com.example.app"], RuleOverrideEntry(mode: .forceOn))

        try store.setDefaultFlip(false)
        XCTAssertEqual(store.settings?.overrides["com.example.app"], RuleOverrideEntry(mode: .forceOn),
                       "改默认值不能动显式覆盖")

        let reloaded = RuleStore(settingsURL: settingsURL, legacyDefaults: legacyDefaults)
        reloaded.load()
        XCTAssertEqual(reloaded.settings?.overrides["com.example.app"], RuleOverrideEntry(mode: .forceOn))
    }

    func testInheritRemovesOverrideEntry() throws {
        let store = makeLoadedStore()
        try store.setOverride(bundleID: "com.example.app", mode: .forceOff)
        XCTAssertNotNil(store.settings?.overrides["com.example.app"])
        try store.setOverride(bundleID: "com.example.app", mode: .inherit)
        XCTAssertNil(store.settings?.overrides["com.example.app"],
                     "inherit 表示没有覆盖,应删除条目而非保存 inherit")

        // 落盘侧:新实例重读,删除必须持久;文档中永不出现 inherit 条目
        let reloaded = RuleStore(settingsURL: settingsURL, legacyDefaults: legacyDefaults)
        reloaded.load()
        XCTAssertNil(reloaded.settings?.overrides["com.example.app"])
        let raw = try String(contentsOf: settingsURL, encoding: .utf8)
        XCTAssertFalse(raw.contains("inherit"), "inherit 不得作为覆盖值落盘")
    }

    func testDefaultFlipChangeKeepsOverrides() throws {
        let store = makeLoadedStore()
        try store.setOverride(bundleID: "a", mode: .forceOff)
        try store.setOverride(bundleID: "b", mode: .forceOn)
        try store.setDefaultFlip(false)
        XCTAssertEqual(store.settings?.overrides.count, 2)
        XCTAssertEqual(store.settings?.overrides["a"], RuleOverrideEntry(mode: .forceOff))
        XCTAssertEqual(store.settings?.overrides["b"], RuleOverrideEntry(mode: .forceOn))
    }

    func testRevisionIncrementsOnEachSuccessfulSave() throws {
        let store = makeLoadedStore()
        let initial = try XCTUnwrap(store.settings).revision
        try store.setDefaultFlip(false)
        XCTAssertGreaterThan(store.settings?.revision ?? Int.min, initial,
                             "每次成功保存 revision 必须前进(版本检查依赖它)")
        try store.setOverride(bundleID: "a", mode: .forceOn)
        XCTAssertGreaterThan(store.settings?.revision ?? Int.min, initial + 1)
    }

    func testMutationsBeforeLoadAreRejected() {
        let store = RuleStore(settingsURL: settingsURL, legacyDefaults: legacyDefaults)
        XCTAssertThrowsError(try store.setDefaultFlip(true)) { error in
            guard case RuleStoreError.notLoaded = error else {
                return XCTFail("未载入时的修改应抛 notLoaded,实际 \(error)")
            }
        }
        XCTAssertThrowsError(try store.setOverride(bundleID: "a", mode: .forceOn)) { error in
            guard case RuleStoreError.notLoaded = error else {
                return XCTFail("未载入时的修改应抛 notLoaded,实际 \(error)")
            }
        }
    }

    /// §9.1「并发编辑顺序」:多线程并发修改必须串行化,最终内存与磁盘一致,
    /// 且任何线程观察到的快照都是某次成功保存后的完整状态(不会半写)。
    func testConcurrentMutationsSerializeToConsistentState() throws {
        let store = makeLoadedStore()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "test-concurrent-edits", attributes: .concurrent)

        for i in 0..<20 {
            group.enter()
            queue.async {
                defer { group.leave() }
                if i % 4 == 3 {
                    _ = try? store.removeOverride(bundleID: "app\(i % 8)", expectedRevision: nil)
                } else {
                    try? store.setOverride(bundleID: "app\(i % 8)",
                                           mode: i % 2 == 0 ? .forceOn : .forceOff)
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)

        let final = try XCTUnwrap(store.settings)
        let reloaded = RuleStore(settingsURL: settingsURL, legacyDefaults: legacyDefaults)
        reloaded.load()
        XCTAssertEqual(reloaded.settings, final,
                       "并发结束后磁盘必须与内存快照一致(写入被串行化,无丢失更新)")
        for (bundleID, _) in final.overrides {
            XCTAssertTrue(bundleID.hasPrefix("app"), "快照不应出现半写或未知条目")
        }
    }

    func testSaveFailureKeepsOldStateAndThrows() throws {
        let store = makeLoadedStore()
        try store.setOverride(bundleID: "keep", mode: .forceOn)
        let before = store.settings

        // 已载入后让写入必败:把 settingsURL 的父目录换成普通文件 → 建目录失败
        let savedFile = tmpDir.appendingPathComponent("saved-rules.json")
        try FileManager.default.moveItem(at: settingsURL, to: savedFile)
        try FileManager.default.removeItem(at: tmpDir)
        try Data("x".utf8).write(to: tmpDir)
        defer {
            try? FileManager.default.removeItem(at: tmpDir)
            try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        }

        XCTAssertThrowsError(try store.setOverride(bundleID: "lost", mode: .forceOff)) { error in
            guard case RuleStoreError.saveFailed = error else {
                return XCTFail("应为 saveFailed,实际 \(error)")
            }
        }
        XCTAssertEqual(store.settings, before, "保存失败必须保留旧规则")

        // 另一形态:初始 load 就写不进去 → 恢复模式,不能静默继续
        let broken = RuleStore(settingsURL: tmpDir.appendingPathComponent("sub/rules.json"),
                               legacyDefaults: legacyDefaults)
        if case .needsRecovery = broken.load() {
            XCTAssertNotNil(broken.recoveryReason)
            XCTAssertNil(broken.settings)
        } else {
            XCTFail("初始写入失败应进入恢复模式")
        }
    }

    func testRemoveOverrideRejectsStaleRevision() throws {
        let store = makeLoadedStore()
        try store.setOverride(bundleID: "com.example.app", mode: .forceOff)
        let staleRevision = store.settings!.revision
        try store.setDefaultFlip(true) // 期间发生了一次保存,revision 前进

        let removed = try store.removeOverride(bundleID: "com.example.app", expectedRevision: staleRevision)
        XCTAssertFalse(removed, "过期 revision 的清理请求必须被拒绝")
        XCTAssertEqual(store.settings?.overrides["com.example.app"], RuleOverrideEntry(mode: .forceOff),
                       "被拒绝的清理不得改动设置")

        let ok = try store.removeOverride(bundleID: "com.example.app",
                                          expectedRevision: store.settings!.revision)
        XCTAssertTrue(ok)
        XCTAssertNil(store.settings?.overrides["com.example.app"])
    }

    func testRemoveOverrideWithoutRevisionAlwaysAllowed() throws {
        let store = makeLoadedStore()
        try store.setOverride(bundleID: "com.example.app", mode: .forceOff)
        XCTAssertTrue(try store.removeOverride(bundleID: "com.example.app", expectedRevision: nil))
        // 用户界面删除不携带版本要求
        try store.setOverride(bundleID: "com.example.app", mode: .forceOn)
        XCTAssertTrue(try store.removeOverride(bundleID: "com.example.app", expectedRevision: nil))
    }

    func testDecisionForUnknownBundleUsesGlobalDefault() throws {
        let store = makeLoadedStore()
        try store.setOverride(bundleID: "known", mode: .forceOn)
        XCTAssertEqual(store.decision(forBundle: "known", eventKind: .discrete)?.flips, true)
        XCTAssertEqual(store.decision(forBundle: "unknown", eventKind: .discrete)?.flips,
                       store.settings?.defaultFlip)
        // 未知目标不得借用上一个 App 的覆盖(nil → 默认路径)
        XCTAssertEqual(store.decision(forBundle: nil, eventKind: .discrete)?.source, .globalDefault)
        XCTAssertEqual(store.decision(forBundle: nil, eventKind: .continuous)?.flips, false)
    }

    func testDecisionNilBeforeLoadOrInRecovery() {
        let store = RuleStore(settingsURL: settingsURL, legacyDefaults: legacyDefaults)
        XCTAssertNil(store.decision(forBundle: "any", eventKind: .discrete),
                     "未载入设置时不能给决策,调用方按放行+诊断处理")
    }

    func testSaveSyncsLegacyKeyWithDefaultOnly() throws {
        legacyDefaults.set(true, forKey: RuleStore.legacyEnabledKey)
        let store = makeLoadedStore()
        try store.setOverride(bundleID: "com.example.app", mode: .forceOff) // App 值不得写入旧键
        XCTAssertTrue(legacyDefaults.bool(forKey: RuleStore.legacyEnabledKey))
        try store.setDefaultFlip(false)
        XCTAssertFalse(legacyDefaults.bool(forKey: RuleStore.legacyEnabledKey),
                       "成功保存后旧键应同步为当前默认值(供回退使用)")
    }

    // MARK: S3 清理元数据

    func testSetOverridePreservesLocationsButResetsMissingTimer() throws {
        let store = makeLoadedStore()
        try store.setOverride(bundleID: "com.ex.app", mode: .forceOff) // 元数据只挂在已有条目上
        try store.updateOverrideMetadata(bundleID: "com.ex.app") { entry in
            entry.locations = ["/Applications/App.app"]
            entry.missingSince = Date(timeIntervalSince1970: 100)
            entry.lastVerifiedMissing = Date(timeIntervalSince1970: 200)
        }
        // 用户重新设置规则 = 重新确认意图:计时重来,位置保留
        try store.setOverride(bundleID: "com.ex.app", mode: .forceOn)
        let entry = store.settings?.overrides["com.ex.app"]
        XCTAssertEqual(entry?.mode, .forceOn)
        XCTAssertEqual(entry?.locations, ["/Applications/App.app"], "位置元数据跨用户编辑保留")
        XCTAssertNil(entry?.missingSince, "用户编辑重置缺失计时(§6.1)")
        XCTAssertNil(entry?.lastVerifiedMissing)
    }

    func testUpdateOverrideMetadataAppliesPersistsAndGuards() throws {
        let store = makeLoadedStore()
        try store.setOverride(bundleID: "com.ex.app", mode: .forceOff)

        let stamp = Date(timeIntervalSince1970: 999)
        XCTAssertTrue(try store.updateOverrideMetadata(bundleID: "com.ex.app") { $0.missingSince = stamp })
        XCTAssertEqual(store.settings?.overrides["com.ex.app"]?.missingSince, stamp)

        // 持久化
        let reloaded = RuleStore(settingsURL: settingsURL, legacyDefaults: legacyDefaults)
        reloaded.load()
        XCTAssertEqual(reloaded.settings?.overrides["com.ex.app"]?.missingSince, stamp)

        // 条目不存在(用户改回默认):false,不抛
        XCTAssertFalse(try store.updateOverrideMetadata(bundleID: "com.ex.missing") { $0.missingSince = stamp })

        // revision 过期:false 且不改动
        let stale = store.settings!.revision
        try store.setDefaultFlip(false) // revision 前进
        XCTAssertFalse(try store.updateOverrideMetadata(bundleID: "com.ex.app", expectedRevision: stale) {
            $0.missingSince = Date(timeIntervalSince1970: 123)
        })
        XCTAssertEqual(store.settings?.overrides["com.ex.app"]?.missingSince, stamp, "过期请求不得改动")
    }

    func testLegacyDocumentWithoutMetadataFieldsStillDecodes() throws {
        // schemaVersion 1 的旧文档(S2 期产物)没有 locations/missingSince 等键
        let legacy = """
        {
          "schemaVersion": 1,
          "revision": 3,
          "defaultFlip": true,
          "overrides": { "com.ex.old": { "mode": "forceOff" } }
        }
        """
        try legacy.data(using: .utf8)!.write(to: settingsURL)
        let store = RuleStore(settingsURL: settingsURL, legacyDefaults: legacyDefaults)
        XCTAssertEqual(store.load(), .loaded)
        XCTAssertEqual(store.settings?.overrides["com.ex.old"],
                       RuleOverrideEntry(mode: .forceOff))
    }
}
