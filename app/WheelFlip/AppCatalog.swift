// 应用目录(计划 §5):多来源合并的运行时 App 清单。
//
// 职责边界(§5.3):
// - 目录信息(名称/路径/运行 PID/presence)是可重新发现的运行时状态,内存为主;
// - 用户规则仍在 RuleStore;清理建议由 AppRuleReconciler 产出,本类只提供证据;
// - 手工添加与书签归 ManualAppStore。
//
// 来源与状态建模(§5.1/§5.4):
// - 每个来源独立记录 completed/failed(权限错误);"扫描完成且确实没有"与"扫描不到"
//   是两种状态,绝不把扫描不到包装成不存在。
// - Presence 只描述本次观察证据:present / unavailable(原因) / missing。
//   带日期的 missingCandidate 状态由 AppRuleReconciler 结合 RuleStore 元数据维护
//   (宽限时间需要跨重启持久,目录快照不承担)。
//
// 合并规则:同一 Bundle ID 的多副本/多来源合并为一条(§3.3);名称按来源优先级
// (运行中 > 目录 > 手工 > Spotlight)取最优;系统 App 按路径前缀标记。

import Foundation

/// 单个来源发现的一个 App 副本。runningApps 来源携带 PID(其余来源为 nil)。
struct FoundApp: Equatable {
    let bundleID: String
    let displayName: String
    let appPath: String
    let source: AppCatalog.Source
    let pid: pid_t?

    init(bundleID: String, displayName: String, appPath: String,
         source: AppCatalog.Source, pid: pid_t? = nil) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.appPath = appPath
        self.source = source
        self.pid = pid
    }
}

/// 目录条目(值类型快照成员)。
struct CatalogEntry: Equatable, Identifiable {
    let bundleID: String
    var displayName: String
    /// 该名称来自哪个来源(合并优先级判定用)。
    var displayNameSource: AppCatalog.Source
    /// 所有已知副本位置(.app 根),去重、稳定排序。
    var appPaths: [String]
    var isSystem: Bool
    var runningPIDs: Set<pid_t>
    var sources: Set<AppCatalog.Source>
    var presence: AppCatalog.Presence

    var id: String { bundleID }
}

/// 目录快照(不可变值,UI/清理器消费)。
struct CatalogSnapshot: Equatable {
    var entries: [CatalogEntry]
    var sourceStates: [AppCatalog.SourceState]
    var generatedAt: Date

    /// 本地化名称稳定排序,重名以 Bundle ID 决胜(§4.2)。
    func sortedByName() -> [CatalogEntry] {
        entries.sorted { lhs, rhs in
            let order = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.bundleID < rhs.bundleID
        }
    }

    func entry(bundleID: String) -> CatalogEntry? {
        entries.first { $0.bundleID == bundleID }
    }
}

/// 多来源应用目录。刷新在后台串行队列进行,产出不可变快照。
final class AppCatalog {
    enum Source: Hashable, Codable, CustomStringConvertible {
        case directory
        case spotlight
        case runningApps
        case manual

        var description: String {
            switch self {
            case .directory: return "directory"
            case .spotlight: return "spotlight"
            case .runningApps: return "running"
            case .manual: return "manual"
            }
        }

        /// 名称优先级(高者胜,同来源不覆盖:先到先得,稳定)。
        var namePriority: Int {
            switch self {
            case .runningApps: return 4
            case .directory: return 3
            case .manual: return 2
            case .spotlight: return 1
            }
        }
    }

    enum Presence: Equatable, CustomStringConvertible {
        case present
        /// 观察不完整(卷离线/读取被拒/来源失败):清理必须停(§5.4 第 2 条)。
        case unavailable(String)
        /// 本次观察内所有已知位置都被证实不存在(正面缺失证据,交清理器判定)。
        case missing

        var description: String {
            switch self {
            case .present: return "present"
            case .unavailable(let reason): return "unavailable(\(reason))"
            case .missing: return "missing"
            }
        }
    }

    enum SourceState: Equatable {
        case completed(found: Int)
        case failed(String)

        var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    // MARK: 注入点(全部可替换,单元测试不碰真实文件系统/Spotlight/NSWorkspace)

    /// 列一个目录下的 .app 副本;权限/IO 失败必须抛错(而不是返回空)。
    typealias DirectoryLister = (_ root: String) throws -> [FoundApp]
    typealias SpotlightProvider = () throws -> [FoundApp]
    typealias RunningAppsProvider = () -> [FoundApp]
    /// 位置核验三分证据:沙盒里 fileExists==false 区分不了"不在"和"看不了"。
    enum PathEvidence: Equatable {
        case exists
        case absent   // 父目录可读且无此条:可证缺失
        case unknown  // 父目录不可读(卷离线/无权限):缺失不可确认
    }
    typealias PathProber = (_ appPath: String) -> PathEvidence

    /// 生产探针:fileExists → exists;父目录可读 → absent;否则 unknown。
    static func defaultPathProber() -> PathProber {
        { path in
            if FileManager.default.fileExists(atPath: path) { return .exists }
            let parent = (path as NSString).deletingLastPathComponent
            if FileManager.default.isReadableFile(atPath: parent) { return .absent }
            return .unknown
        }
    }

    private let directoryRoots: [(root: String, lister: DirectoryLister)]
    private let spotlightProvider: SpotlightProvider?
    private let runningAppsProvider: RunningAppsProvider
    private let manualAppsProvider: () -> [FoundApp]
    private let probePath: PathProber
    private let now: () -> Date

    private let queue = DispatchQueue(label: "com.jonywu.WheelFlip.catalog", qos: .utility)
    private let lock = NSLock()
    private var _snapshot: CatalogSnapshot?
    private var refreshGeneration = 0

    /// 最新快照;首次刷新完成前为 nil。
    var snapshot: CatalogSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return _snapshot
    }

    /// 刷新完成回调(后台队列发出;UI 层自行切主线程)。
    var onRefresh: ((CatalogSnapshot) -> Void)?

    init(
        directoryRoots: [(root: String, lister: DirectoryLister)],
        spotlightProvider: SpotlightProvider?,
        runningAppsProvider: @escaping RunningAppsProvider,
        manualAppsProvider: @escaping () -> [FoundApp] = { [] },
        probePath: @escaping PathProber = AppCatalog.defaultPathProber(),
        now: @escaping () -> Date = { Date() }
    ) {
        self.directoryRoots = directoryRoots
        self.spotlightProvider = spotlightProvider
        self.runningAppsProvider = runningAppsProvider
        self.manualAppsProvider = manualAppsProvider
        self.probePath = probePath
        self.now = now
    }

    // MARK: 刷新与增量

    /// 触发一次全来源刷新。并发调用按代次合并:旧一轮收集途中发现已有更新一轮即丢弃。
    func refresh() {
        lock.lock()
        refreshGeneration += 1
        let generation = refreshGeneration
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            guard let result = self.collect(generation: generation) else { return }
            self.lock.lock()
            self._snapshot = result
            self.lock.unlock()
            self.onRefresh?(result)
        }
    }

    /// 运行 App 补录(§5.1 来源 3):启动通知到达时增量并入,不整轮重扫。
    /// 新路径存在性即时探测一次,避免"PID 在跑但条目仍显示 missing"的自相矛盾。
    func addRunningApp(_ found: FoundApp) {
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard var snapshot = self._snapshot else {
                self.lock.unlock()
                return // 首轮未完成:等全量刷新带上它
            }
            snapshot = AppCatalog.merge(found, into: snapshot, at: self.now())
            if let index = snapshot.entries.firstIndex(where: { $0.bundleID == found.bundleID }),
               case .missing = snapshot.entries[index].presence,
               self.probePath(found.appPath) == .exists {
                snapshot.entries[index].presence = .present
            }
            self._snapshot = snapshot
            self.lock.unlock()
            self.onRefresh?(snapshot)
        }
    }

    /// 进程退出:只清运行 PID;presence/位置保持,交由下一轮复核(§5.4"运行中删除")。
    /// F15:退出事件同样发布快照,UI 的进程相关展示不陈旧。
    func removeRunningPID(_ pid: pid_t) {
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard var snapshot = self._snapshot else {
                self.lock.unlock()
                return
            }
            for index in snapshot.entries.indices {
                snapshot.entries[index].runningPIDs.remove(pid)
            }
            self._snapshot = snapshot
            self.lock.unlock()
            self.onRefresh?(snapshot)
        }
    }

    // MARK: 收集(后台队列)

    private func collect(generation: Int) -> CatalogSnapshot? {
        var states: [SourceState] = []
        var found: [FoundApp] = []

        for (root, lister) in directoryRoots {
            do {
                let apps = try lister(root)
                guard isCurrent(generation) else { return nil }
                states.append(.completed(found: apps.count))
                found.append(contentsOf: apps)
            } catch {
                guard isCurrent(generation) else { return nil }
                states.append(.failed("目录 \(root) 不可读:\(error.localizedDescription)"))
            }
        }

        if let spotlightProvider {
            do {
                let apps = try spotlightProvider()
                guard isCurrent(generation) else { return nil }
                states.append(.completed(found: apps.count))
                found.append(contentsOf: apps)
            } catch {
                guard isCurrent(generation) else { return nil }
                states.append(.failed("Spotlight 查询失败:\(error.localizedDescription)"))
            }
        }

        let running = runningAppsProvider()
        found.append(contentsOf: running)
        states.append(.completed(found: running.count))

        let manual = manualAppsProvider()
        found.append(contentsOf: manual)
        states.append(.completed(found: manual.count))

        var snapshot = AppCatalog.snapshot(from: found, states: states, at: now())
        AppCatalog.refinePresence(&snapshot, probePath: probePath)
        guard isCurrent(generation) else { return nil }
        return snapshot
    }

    private func isCurrent(_ generation: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return refreshGeneration == generation
    }

    // MARK: 合并(静态纯函数,单测直达)

    /// 把发现列表合并为快照。
    static func snapshot(from found: [FoundApp], states: [SourceState], at date: Date) -> CatalogSnapshot {
        var merged: [String: CatalogEntry] = [:]
        for app in found where !app.bundleID.isEmpty {
            var entry = merged[app.bundleID] ?? CatalogEntry(
                bundleID: app.bundleID,
                displayName: "",
                displayNameSource: app.source,
                appPaths: [],
                isSystem: app.appPath.hasPrefix("/System/"),
                runningPIDs: [],
                sources: [],
                presence: .present
            )
            if app.source.namePriority > entry.displayNameSource.namePriority || entry.displayName.isEmpty {
                entry.displayName = app.displayName
                entry.displayNameSource = app.source
            }
            if !entry.appPaths.contains(app.appPath) {
                entry.appPaths.append(app.appPath)
            }
            entry.sources.insert(app.source)
            if let pid = app.pid, app.source == .runningApps {
                entry.runningPIDs.insert(pid)
            }
            if app.appPath.hasPrefix("/System/") {
                entry.isSystem = true
            }
            merged[app.bundleID] = entry
        }
        return CatalogSnapshot(
            entries: merged.values.map { entry in
                var e = entry
                e.appPaths.sort()
                return e
            }.sorted { $0.bundleID < $1.bundleID },
            sourceStates: states,
            generatedAt: date
        )
    }

    /// 单条增量合并(运行 App 补录)。
    static func merge(_ app: FoundApp, into snapshot: CatalogSnapshot, at date: Date) -> CatalogSnapshot {
        var result = snapshot
        result.generatedAt = date
        if let index = result.entries.firstIndex(where: { $0.bundleID == app.bundleID }) {
            if !result.entries[index].appPaths.contains(app.appPath) {
                result.entries[index].appPaths.append(app.appPath)
                result.entries[index].appPaths.sort()
            }
            if app.source.namePriority > result.entries[index].displayNameSource.namePriority
                || result.entries[index].displayName.isEmpty {
                result.entries[index].displayName = app.displayName
                result.entries[index].displayNameSource = app.source
            }
            result.entries[index].sources.insert(app.source)
            if let pid = app.pid, app.source == .runningApps {
                result.entries[index].runningPIDs.insert(pid)
            }
        } else {
            result.entries.append(CatalogEntry(
                bundleID: app.bundleID,
                displayName: app.displayName,
                displayNameSource: app.source,
                appPaths: [app.appPath],
                isSystem: app.appPath.hasPrefix("/System/"),
                runningPIDs: [],
                sources: [app.source],
                presence: .present
            ))
            result.entries.sort { $0.bundleID < $1.bundleID }
        }
        return result
    }

    /// presence 精化(对抗式审查修订:只看位置级三分证据,不做全局来源否决——
    /// 全局否决会让一个永久不可读的根关闭整机清理,而位置探测已按条目给出准确结论)。
    /// 任一路径存在 → present;任一路径不可核验 → unavailable;全部可证缺失 → missing。
    static func refinePresence(_ snapshot: inout CatalogSnapshot, probePath: PathProber) {
        for index in snapshot.entries.indices {
            let evidence = snapshot.entries[index].appPaths.map(probePath)
            if evidence.contains(.exists) {
                snapshot.entries[index].presence = .present
            } else if evidence.contains(.unknown) {
                snapshot.entries[index].presence = .unavailable("位置不可核验")
            } else {
                snapshot.entries[index].presence = .missing
            }
        }
    }
}
