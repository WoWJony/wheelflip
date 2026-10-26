import XCTest
@testable import WheelFlip

/// §6.2 迁移矩阵:旧 true / 旧 false / 键不存在 / 新格式已存在 / 中断重试 / 损坏与未来版本。
final class SettingsMigrationTests: RuleStoreTestBase {
    func testFreshInstallDefaultsToFlipOn() {
        legacyDefaults.removeObject(forKey: RuleStore.legacyEnabledKey)
        let store = RuleStore(settingsURL: settingsURL, legacyDefaults: legacyDefaults)
        XCTAssertEqual(store.load(), .freshInstall)
        XCTAssertEqual(store.settings?.defaultFlip, true, "全新安装默认翻转(§1.2)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: settingsURL.path), "首次运行即落盘")
    }

    func testLegacyTrueMigratesToDefaultFlipTrue() {
        legacyDefaults.set(true, forKey: RuleStore.legacyEnabledKey)
        let store = RuleStore(settingsURL: settingsURL, legacyDefaults: legacyDefaults)
        XCTAssertEqual(store.load(), .migrated)
        XCTAssertEqual(store.settings?.defaultFlip, true)
    }

    func testLegacyFalseMigratesToDefaultFlipFalse() {
        // 关键回归:不能把旧版明确关闭的翻转让迁移意外打开
        legacyDefaults.set(false, forKey: RuleStore.legacyEnabledKey)
        let store = RuleStore(settingsURL: settingsURL, legacyDefaults: legacyDefaults)
        XCTAssertEqual(store.load(), .migrated)
        XCTAssertEqual(store.settings?.defaultFlip, false)
    }

    func testMissingLegacyKeyIsNotTreatedAsFalse() {
        // object(forKey:) 区分"没有值"与显式 false:没有旧键 = 全新安装 = true
        XCTAssertNil(legacyDefaults.object(forKey: RuleStore.legacyEnabledKey))
        let store = RuleStore(settingsURL: settingsURL, legacyDefaults: legacyDefaults)
        XCTAssertEqual(store.load(), .freshInstall)
        XCTAssertEqual(store.settings?.defaultFlip, true)
    }

    func testLegacyKeySurvivesMigrationForRollback() {
        legacyDefaults.set(false, forKey: RuleStore.legacyEnabledKey)
        let store = RuleStore(settingsURL: settingsURL, legacyDefaults: legacyDefaults)
        store.load()
        XCTAssertEqual(legacyDefaults.object(forKey: RuleStore.legacyEnabledKey) as? Bool, false,
                       "迁移保留旧键供回退(§6.2)")
    }

    func testExistingSettingsWinOverLegacyKey() throws {
        legacyDefaults.set(true, forKey: RuleStore.legacyEnabledKey)
        let first = RuleStore(settingsURL: settingsURL, legacyDefaults: legacyDefaults)
        first.load()
        try first.setDefaultFlip(false)

        let second = RuleStore(settingsURL: settingsURL, legacyDefaults: legacyDefaults)
        // setDefaultFlip 已合法地把旧键同步为最后保存的默认值;load 读路径不得再动它
        let legacyBeforeLoad = legacyDefaults.object(forKey: RuleStore.legacyEnabledKey) as? Bool
        XCTAssertEqual(second.load(), .loaded, "有效新格式存在时直接读,不做迁移")
        XCTAssertEqual(second.settings?.defaultFlip, false, "新格式优先于旧键")
        XCTAssertEqual(legacyDefaults.object(forKey: RuleStore.legacyEnabledKey) as? Bool,
                       legacyBeforeLoad, "读路径不得动旧键")
    }

    func testMigrationIsIdempotentAfterInterruption() throws {
        legacyDefaults.set(true, forKey: RuleStore.legacyEnabledKey)
        let store = RuleStore(settingsURL: settingsURL, legacyDefaults: legacyDefaults)
        XCTAssertEqual(store.load(), .migrated)
        try store.setOverride(bundleID: "com.example.app", mode: .forceOff)

        // 模拟中断:设置文件被删(比如写入途中机器掉电后文件不完整再被清理)
        try FileManager.default.removeItem(at: settingsURL)
        let retry = RuleStore(settingsURL: settingsURL, legacyDefaults: legacyDefaults)
        XCTAssertEqual(retry.load(), .migrated, "重新迁移可重入,不报错不重复")
        XCTAssertEqual(retry.settings?.defaultFlip, true)
        XCTAssertTrue(retry.settings?.overrides.isEmpty ?? false, "迁移结果覆盖必须为空(§6.2)")
    }

    func testCorruptFileNeedsRecoveryAndKeepsSingleBackup() throws {
        let garbage = Data("这不是 JSON {{{".utf8)
        try garbage.write(to: settingsURL)
        let store = RuleStore(settingsURL: settingsURL, legacyDefaults: legacyDefaults)

        if case .needsRecovery(let reason) = store.load() {
            XCTAssertTrue(reason.contains("rules-corrupt-backup.json"), "恢复原因应说明真实备份状态:\(reason)")
        } else {
            XCTFail("损坏文件应进入恢复模式")
        }
        XCTAssertNil(store.settings, "恢复模式下不发布快照")
        XCTAssertNil(store.decision(forBundle: "any", eventKind: .discrete))
        let backupURL = settingsURL.deletingLastPathComponent()
            .appendingPathComponent("rules-corrupt-backup.json")
        XCTAssertEqual(try Data(contentsOf: backupURL), garbage, "损坏内容应有固定备份")

        // 第二次事故:备份必须刷新为最新损坏内容(旧内容已无意义,不能让陈旧备份冒充)
        let garbage2 = Data("second corruption".utf8)
        try garbage2.write(to: settingsURL)
        store.load()
        XCTAssertEqual(try Data(contentsOf: backupURL), garbage2, "固定备份始终对应最近一次事故")

        // 修复文件并成功载入 → 验证稳定,备份移除(§6.2)
        let repaired = RuleSettings(defaultFlip: true)
        try JSONEncoder().encode(repaired).write(to: settingsURL)
        let healed = RuleStore(settingsURL: settingsURL, legacyDefaults: legacyDefaults)
        XCTAssertEqual(healed.load(), .loaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path),
                       "验证稳定后应移除损坏备份,不积累")
    }

    func testRecoveryReasonTellsTruthWhenBackupCopyFails() throws {
        try Data("corrupt".utf8).write(to: settingsURL)
        // 目录只读 → 备份复制必败;恢复原因不得谎称"已保留备份"
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: tmpDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmpDir.path) }

        let store = RuleStore(settingsURL: settingsURL, legacyDefaults: legacyDefaults)
        if case .needsRecovery(let reason) = store.load() {
            XCTAssertFalse(reason.contains("已备份为"), "备份失败时不得声称已备份:\(reason)")
            XCTAssertTrue(reason.contains("备份创建失败"), "应明确警告备份失败:\(reason)")
        } else {
            XCTFail("损坏文件应进入恢复模式")
        }
    }

    func testFutureSchemaVersionNeedsRecovery() throws {
        let future = RuleSettings(schemaVersion: 99, revision: 0, defaultFlip: true)
        let encoder = JSONEncoder()
        try encoder.encode(future).write(to: settingsURL)
        legacyDefaults.set(true, forKey: RuleStore.legacyEnabledKey)

        let store = RuleStore(settingsURL: settingsURL, legacyDefaults: legacyDefaults)
        if case .needsRecovery = store.load() {
            // 预期:不静默重迁移、不覆盖
        } else {
            XCTFail("未来版本应进入恢复模式,实际 \(store.load())")
        }
        XCTAssertNil(store.settings)
        // 旧键未被消费,文件未被覆盖
        XCTAssertEqual(legacyDefaults.object(forKey: RuleStore.legacyEnabledKey) as? Bool, true)
    }
}
