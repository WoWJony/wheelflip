// 按应用规则的版本化持久存储(计划 §6)。
//
// 设计要点(全部有对应测试):
// - 小型版本化 Codable 文档,存在应用自己的 Application Support(沙盒内即容器)。
// - 原子替换写入 + 写后回读验证;成功保存才是用户操作的生效边界,失败保留旧规则并抛错。
// - 不可变快照(RuleSettings 值类型)+ NSLock 串行化所有读写;滚轮回调里只读快照,不碰本类。
// - revision 随每次成功保存递增;异步清理建议必须携带 expectedRevision,过期即拒绝,
//   防止旧清理任务删掉用户刚编辑的设置。
// - 损坏或版本超出支持范围:保留一份固定备份后进入 needsRecovery,不自动覆盖、不静默重迁移。
// - 迁移(§6.2):新格式有效直接读;缺新格式且旧键存在 → 旧 true/false 映射 defaultFlip;
//   都缺 → 全新安装 defaultFlip=true。旧键保留供回退;成功保存时同步旧键为当前默认值,
//   绝不把某个 App 的覆盖值写回旧键。

import Foundation

/// 持久化的覆盖条目。
/// mode 之外是清理与授权信息(计划 §5.3):仅为需要卸载判定/手工访问的条目维护,
/// 全部可选、向后兼容(schemaVersion 保持 1;旧文件缺这些键解码为 nil)。
struct RuleOverrideEntry: Codable, Equatable {
    var mode: ScrollRuleMode
    /// 已知安装位置(.app 根路径)。卸载判定与重装区分依赖它,不是规则身份。
    /// (对抗式审查修订:不再存卷挂载点——离线判定由位置级三分探测承担,
    ///  持久化无人消费的字段违反 §5.3"保存最少"。)
    var locations: [String]?
    /// 首次确认缺失时间(宽限期 24h 的起点,可注入时钟)。
    var missingSince: Date?
    /// 最近一次"成功复核仍缺失"的时间(第二次复核证据)。
    var lastVerifiedMissing: Date?

    init(mode: ScrollRuleMode, locations: [String]? = nil,
         missingSince: Date? = nil, lastVerifiedMissing: Date? = nil) {
        self.mode = mode
        self.locations = locations
        self.missingSince = missingSince
        self.lastVerifiedMissing = lastVerifiedMissing
    }
}

/// 设置文档本体;以值类型整体发布,等价于不可变快照。
struct RuleSettings: Codable, Equatable {
    static let supportedSchemaVersion = 1

    var schemaVersion: Int
    /// 每次成功保存递增;异步清理用它做版本检查。
    var revision: Int
    var defaultFlip: Bool
    /// 键为 Bundle ID;inherit 不落盘(见 RuleStore.setOverride)。
    var overrides: [String: RuleOverrideEntry]

    init(schemaVersion: Int = RuleSettings.supportedSchemaVersion,
         revision: Int = 0,
         defaultFlip: Bool,
         overrides: [String: RuleOverrideEntry] = [:]) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.defaultFlip = defaultFlip
        self.overrides = overrides
    }
}

enum RuleStoreError: Error, Equatable {
    /// I/O 失败(目录不可建、写入失败等),附简要原因。
    case saveFailed(String)
    /// 非法输入(如空 Bundle ID);纵深防御,UI 层不应让它可达。
    case invalidInput(String)
    /// 写入后回读验证不一致;内存保持旧设置,操作未生效。
    case verificationFailed
    /// load 未完成或处于恢复模式时尝试修改。
    case notLoaded
    /// 异步清理携带的 expectedRevision 过期;什么都没改。
    case revisionMismatch
    /// 设置损坏/版本超出支持范围/初始写入失败;需要用户介入,附原因。
    case needsRecovery(String)
}

final class RuleStore {
    /// 旧版全局开关键,归 App 容器域所有(AppState.enabledKey 同源;迁移期保留供回退)。
    static let legacyEnabledKey = "wheelflip.enabled"

    enum LoadOutcome: Equatable {
        case loaded
        case migrated
        case freshInstall
        case needsRecovery(String)
    }

    private let settingsURL: URL
    /// 损坏备份位置(修复视图里"在 Finder 中显示备份"用)。
    var backupURL: URL { settingsURL.deletingLastPathComponent()
        .appendingPathComponent(settingsURL.deletingPathExtension().lastPathComponent + "-corrupt-backup.json") }
    private let legacyDefaults: UserDefaults
    private let lock = NSLock()
    private var current: RuleSettings?

    /// 当前不可变快照;未成功 load 或恢复模式下为 nil(引擎据此走放行+诊断,见 §3.2)。
    var settings: RuleSettings? {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    var recoveryReason: String? {
        lock.lock(); defer { lock.unlock() }
        guard current == nil else { return nil }
        return recoveryReasonValue
    }

    private var recoveryReasonValue: String?

    init(settingsURL: URL, legacyDefaults: UserDefaults) {
        self.settingsURL = settingsURL
        self.legacyDefaults = legacyDefaults
    }

    /// 生产环境路径:Application Support/WheelFlip/rules.json(沙盒内即容器路径)。
    static func defaultSettingsURL() -> URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent("WheelFlip", isDirectory: true)
            .appendingPathComponent("rules.json")
    }

    // MARK: - 载入与迁移(§6.2 顺序)

    @discardableResult
    func load() -> LoadOutcome {
        lock.lock(); defer { lock.unlock() }

        if FileManager.default.fileExists(atPath: settingsURL.path) {
            switch Self.decode(fileAt: settingsURL) {
            case .success(let loaded):
                current = loaded
                recoveryReasonValue = nil
                // 验证稳定后移除损坏备份(§6.2);失败忽略——陈旧备份只是旧隐患,不阻塞运行
                if FileManager.default.fileExists(atPath: backupURL.path) {
                    try? FileManager.default.removeItem(at: backupURL)
                }
                return .loaded
            case .failure(.needsRecovery(let reason)):
                return .needsRecovery(enterRecovery(reason: reason))
            case .failure:
                return .needsRecovery(enterRecovery(reason: "未知解析错误"))
            }
        }

        // 新格式不存在:区分旧键"没有值"与显式 false(§6.2 明令,不能用 bool(forKey:) 判新用户)。
        let settings: RuleSettings
        let outcome: LoadOutcome
        if legacyDefaults.object(forKey: Self.legacyEnabledKey) != nil {
            settings = RuleSettings(defaultFlip: legacyDefaults.bool(forKey: Self.legacyEnabledKey))
            outcome = .migrated
        } else {
            settings = RuleSettings(defaultFlip: true) // 全新安装默认翻转(§1.2)
            outcome = .freshInstall
        }

        do {
            try persist(settings)
            current = settings
            recoveryReasonValue = nil
            return outcome
        } catch {
            let reason = "无法写入初始设置:\(errorDescription(error))"
            recoveryReasonValue = reason
            return .needsRecovery(reason)
        }
    }

    /// 修复流程的重置(UX §5.4:用户明确确认损失后调用):
    /// 当前损坏内容已由 load→enterRecovery 备份;这里写入全新默认并退出恢复模式。
    func resetAfterRecovery(defaultFlip: Bool = true) throws {
        lock.lock(); defer { lock.unlock() }
        let fresh = RuleSettings(defaultFlip: defaultFlip)
        do {
            try persist(fresh)
        } catch {
            throw RuleStoreError.saveFailed(errorDescription(error))
        }
        current = fresh
        recoveryReasonValue = nil
    }

    // MARK: - 修改(成功保存才生效;失败保留旧状态)

    func setDefaultFlip(_ flips: Bool) throws {
        try mutate { settings in
            settings.defaultFlip = flips
        }
    }

    /// forceOn/forceOff 即使与当前默认值同效果也必须持久保存(§3.1 重要约束);
    /// inherit 表示删除覆盖条目(连同位置/候选状态/书签引用,§5.4)。
    /// 用户改 mode 时保留位置元数据,但重置缺失计时——重新设置规则即重新确认意图。
    func setOverride(bundleID: String, mode: ScrollRuleMode) throws {
        guard !bundleID.isEmpty else { throw RuleStoreError.invalidInput("缺少应用标识") }
        try mutate { settings in
            switch mode {
            case .forceOn, .forceOff:
                var entry = settings.overrides[bundleID] ?? RuleOverrideEntry(mode: mode)
                entry.mode = mode
                // 用户对"缺失中的 App"重新设置规则 = 重新确认意图:缺失计时重来
                // (§6.1:用户刚编辑的应用不被旧清理任务删除)。
                entry.missingSince = nil
                entry.lastVerifiedMissing = nil
                settings.overrides[bundleID] = entry
            case .inherit:
                settings.overrides[bundleID] = nil
            }
        }
    }

    /// 目录清理专用(§5.4):更新覆盖条目的位置/缺失状态元数据。
    /// 条目已不存在(用户改回默认)返回 false 且不抛错——对清理器这就是取消信号;
    /// expectedRevision 过期同样返回 false,防止旧清理任务覆盖用户刚编辑的元数据。
    @discardableResult
    func updateOverrideMetadata(
        bundleID: String,
        expectedRevision: Int? = nil,
        _ update: (inout RuleOverrideEntry) -> Void
    ) throws -> Bool {
        var applied = false
        do {
            try mutate { settings in
                if let expectedRevision, settings.revision != expectedRevision {
                    throw RuleStoreError.revisionMismatch
                }
                guard var entry = settings.overrides[bundleID] else { return }
                update(&entry)
                settings.overrides[bundleID] = entry
                applied = true
            }
        } catch RuleStoreError.revisionMismatch {
            return false
        }
        return applied
    }

    /// 删除覆盖。expectedRevision 用于异步清理:传入保存时拿到的 revision,
    /// 过期(期间发生过其他保存)返回 false 且不做任何修改,防止删掉用户刚编辑的设置。
    /// 版本不匹配是正常拒绝路径,返回 false 而非抛错;真正的存储失败才抛。
    @discardableResult
    func removeOverride(bundleID: String, expectedRevision: Int?) throws -> Bool {
        var applied = false
        do {
            try mutate { settings in
                if let expectedRevision, settings.revision != expectedRevision {
                    throw RuleStoreError.revisionMismatch
                }
                applied = settings.overrides.removeValue(forKey: bundleID) != nil
            }
        } catch RuleStoreError.revisionMismatch {
            return false
        }
        return applied
    }

    /// 便捷入口:按目标 App 解析决策。settings 缺失(未载入/恢复中)返回 nil,调用方按放行处理。
    func decision(forBundle bundleID: String?, eventKind: ScrollEventKind) -> FlipDecision? {
        lock.lock(); defer { lock.unlock() }
        guard let current else { return nil }
        let override = bundleID.flatMap { current.overrides[$0]?.mode }
        return FlipPolicy.decide(defaultFlip: current.defaultFlip, override: override, eventKind: eventKind)
    }

    /// 删除守卫的原子快照:一次锁内同时取缺失起点与规则版本,
    /// 消除"守卫核对与版本读取之间插入用户编辑"的窗口(对抗式审查证实)。
    func deletionGuardState(bundleID: String) -> (missingSince: Date?, revision: Int)? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = current?.overrides[bundleID] else { return nil }
        return (entry.missingSince, current?.revision ?? 0)
    }

    // MARK: - 内部

    private func mutate(_ change: (inout RuleSettings) throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard var settings = current else { throw RuleStoreError.notLoaded }

        try change(&settings)
        settings.revision += 1

        do {
            try persist(settings)
        } catch {
            throw RuleStoreError.saveFailed(errorDescription(error))
        }
        current = settings
    }

    /// 原子写入 + 回读验证;通过后同步旧键为当前默认值(仅默认值,永不写 App 值,§6.2)。
    /// 写入发生在验证之前,因此验证失败时必须尽力把旧内容写回磁盘,
    /// 否则"被拒绝的修改"会在下次启动时静默生效。
    private func persist(_ settings: RuleSettings) throws {
        let dir = settingsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        let previousData = try? Data(contentsOf: settingsURL)

        try data.write(to: settingsURL, options: .atomic)

        guard Self.decode(fileAt: settingsURL) == .success(settings) else {
            if let previousData {
                try? previousData.write(to: settingsURL, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: settingsURL)
            }
            throw RuleStoreError.verificationFailed
        }
        legacyDefaults.set(settings.defaultFlip, forKey: Self.legacyEnabledKey)
    }

    /// 进入恢复模式:清旧快照、把当前损坏内容刷新为唯一的固定备份(总是覆盖,
    /// 保证备份对应最近一次事故),并返回说了真话的恢复原因(备份成败不同措辞)。
    private func enterRecovery(reason: String) -> String {
        // 必须清掉旧快照:二次 load 发现文件损坏时,不能让陈旧设置继续生效或遮住恢复状态
        current = nil
        if FileManager.default.fileExists(atPath: backupURL.path) {
            try? FileManager.default.removeItem(at: backupURL)
        }
        let backedUp: Bool
        do {
            try FileManager.default.copyItem(at: settingsURL, to: backupURL)
            backedUp = true
        } catch {
            backedUp = false
        }
        let fullReason = backedUp
            ? reason + ";损坏内容已备份为 \(backupURL.lastPathComponent),修复或删除设置文件后重启即可"
            : reason + ";警告:备份创建失败,请立即手动复制一份设置文件再进行处理"
        recoveryReasonValue = fullReason
        return fullReason
    }

    private static func decode(fileAt url: URL) -> Result<RuleSettings, RuleStoreError> {
        do {
            let data = try Data(contentsOf: url)
            let settings = try JSONDecoder().decode(RuleSettings.self, from: data)
            guard settings.schemaVersion == RuleSettings.supportedSchemaVersion else {
                return .failure(.needsRecovery("设置版本不支持(文件 schemaVersion=\(settings.schemaVersion),"
                    + "支持 \(RuleSettings.supportedSchemaVersion))"))
            }
            return .success(settings)
        } catch {
            return .failure(.needsRecovery("设置文件损坏或无法解析(\(error.localizedDescription))"))
        }
    }

    private func errorDescription(_ error: Error) -> String {
        if let ruleError = error as? RuleStoreError {
            return String(describing: ruleError)
        }
        return (error as NSError).localizedDescription
    }

    /// 供 UI 描述错误(含 invalidInput)。
    static func describeForUI(_ error: RuleStoreError) -> String {
        switch error {
        case .invalidInput(let reason): return "无效操作:\(reason)"
        default: return String(describing: error)
        }
    }
}
