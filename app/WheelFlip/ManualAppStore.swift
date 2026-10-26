// 手工添加的应用(计划 §5.1 来源 4):用户经系统选择器添加的 .app。
// 跨启动访问依赖 app-scope 安全作用域书签(entitlements 已含
// files.user-selected.read-only + files.bookmarks.app-scope,S0 记录的最小集)。
//
// 存储:独立 JSON(manual-apps.json,与 rules.json 同目录);原子写;
// 仅存 Bundle ID → {路径, 卷, 书签}。改回"跟随默认"且应用可正常发现时,
// 由清理执行器移除条目并释放书签(§5.4)。

import Foundation

struct ManualAppEntry: Codable, Equatable {
    let bundleID: String
    let appPath: String
    /// app-scope 书签数据;创建失败(极端)时为 nil,退化为仅记录路径。
    /// (对抗式审查修订:不再存卷挂载点——无人消费,违反 §5.3"保存最少";
    ///  旧文件里的 volumeID 键解码时被忽略,向后兼容。)
    let bookmark: Data?
}

final class ManualAppStore {
    struct Document: Codable, Equatable {
        var version: Int = 1
        var apps: [String: ManualAppEntry] = [:] // key = bundleID
    }

    // MARK: 注入点

    typealias BookmarkCreator = (_ url: URL) -> Data?
    /// 解析书签 → URL(生产实现会 start/stop 安全作用域访问,由调用方包住存在性检查)。
    typealias BookmarkResolver = (_ data: Data) -> URL?

    private let fileURL: URL
    private let createBookmark: BookmarkCreator
    private let resolveBookmark: BookmarkResolver
    private let lock = NSLock()
    private var cache: Document

    init(
        fileURL: URL,
        createBookmark: @escaping BookmarkCreator = { url in
            try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        },
        resolveBookmark: @escaping BookmarkResolver = { data in
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) else { return nil }
            return stale ? nil : url // 过期书签解析不出可靠结果,按失败处理触发重添
        }
    ) {
        self.fileURL = fileURL
        self.createBookmark = createBookmark
        self.resolveBookmark = resolveBookmark
        if let data = try? Data(contentsOf: fileURL),
           let doc = try? JSONDecoder().decode(Document.self, from: data) {
            cache = doc
        } else {
            cache = Document()
        }
    }

    static func defaultFileURL() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent("WheelFlip", isDirectory: true)
            .appendingPathComponent("manual-apps.json")
    }

    // MARK: 查询

    var entries: [ManualAppEntry] {
        lock.lock(); defer { lock.unlock() }
        return Array(cache.apps.values)
    }

    func entry(bundleID: String) -> ManualAppEntry? {
        lock.lock(); defer { lock.unlock() }
        return cache.apps[bundleID]
    }

    // MARK: 修改(原子落盘;失败抛错且内存不变)

    @discardableResult
    func addOrUpdate(bundleID: String, appPath: String) throws -> ManualAppEntry {
        let bookmark = createBookmark(URL(fileURLWithPath: appPath))
        let entry = ManualAppEntry(bundleID: bundleID, appPath: appPath, bookmark: bookmark)
        try mutate { doc in
            doc.apps[bundleID] = entry
        }
        return entry
    }

    /// 删除手工项(应用卸载或改回跟随默认且无需授权):书签随条目一并消失。
    @discardableResult
    func remove(bundleID: String) throws -> Bool {
        var removed = false
        try mutate { doc in
            removed = doc.apps.removeValue(forKey: bundleID) != nil
        }
        return removed
    }

    /// 解析书签拿回可访问的 URL;无书签/解析失败退化为记录路径。
    func resolvableURL(for entry: ManualAppEntry) -> URL? {
        guard let bookmark = entry.bookmark else { return URL(fileURLWithPath: entry.appPath) }
        return resolveBookmark(bookmark) ?? URL(fileURLWithPath: entry.appPath)
    }

    /// 按路径找手工项(探测包装用)。
    func entryForPath(_ appPath: String) -> ManualAppEntry? {
        lock.lock(); defer { lock.unlock() }
        return cache.apps.values.first { $0.appPath == appPath }
    }

    /// 安全作用域配对访问(§5.2"安全作用域访问有明确的释放路径"):
    /// start/stop 严格成对,异常路径也经 defer 释放;沙盒内对手工项位置的
    /// 存在性核验必须包在此作用域内,否则会被误判为不可核验。
    func withAccess<T>(for entry: ManualAppEntry, _ body: (URL) -> T) -> T {
        guard let url = resolvableURL(for: entry) else { return body(URL(fileURLWithPath: entry.appPath)) }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return body(url)
    }

    // MARK: 内部

    private func mutate(_ change: (inout Document) -> Void) throws {
        lock.lock()
        var doc = cache
        change(&doc)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(doc)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            lock.unlock()
            throw error
        }
        cache = doc
        lock.unlock()
    }

}
