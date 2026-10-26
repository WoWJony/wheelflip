import XCTest
@testable import WheelFlip

/// 手工添加(§5.1 来源 4):JSON 持久化、书签注入、删除清理。
/// 沙盒内书签跨启动的真实授权行为是 S0 遗留的实机项(记录于 S3 执行记录),
/// 此处锁定存储语义与注入 seam。
final class ManualAppStoreTests: XCTestCase {
    var tmpDir: URL!
    private var bookmarks: [String: Data] = [:]

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wheelflip-manual-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        bookmarks = [:]
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    private var storeURL: URL { tmpDir.appendingPathComponent("manual-apps.json") }

    private func makeStore() -> ManualAppStore {
        ManualAppStore(
            fileURL: storeURL,
            createBookmark: { [bookmarks] url in bookmarks[url.path] },
            resolveBookmark: { [bookmarks] data in
                for (_, known) in bookmarks where known == data {
                    return URL(fileURLWithPath: "/resolved")
                }
                return nil
            }
        )
    }

    func testAddPersistsAcrossInstances() throws {
        bookmarks = ["/Custom/App.app": Data([9, 9])]
        let store = makeStore()
        let entry = try store.addOrUpdate(bundleID: "com.ex.app", appPath: "/Custom/App.app")
        XCTAssertEqual(entry.bookmark, Data([9, 9]))

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.entry(bundleID: "com.ex.app"), entry, "跨实例持久")
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))
    }

    func testRemoveDeletesEntryAndPersists() throws {
        let store = makeStore()
        try store.addOrUpdate(bundleID: "com.ex.app", appPath: "/Custom/App.app")
        XCTAssertTrue(try store.remove(bundleID: "com.ex.app"))
        XCTAssertNil(store.entry(bundleID: "com.ex.app"))

        let reloaded = makeStore()
        XCTAssertNil(reloaded.entry(bundleID: "com.ex.app"), "删除持久")
        XCTAssertFalse(try store.remove(bundleID: "com.ex.app"), "重复删除返回 false")
    }

    func testNilBookmarkFallsBackToPath() throws {
        let store = makeStore() // createBookmark 返回 nil
        let entry = try store.addOrUpdate(bundleID: "com.ex.app", appPath: "/Custom/App.app")
        XCTAssertNil(entry.bookmark)
        XCTAssertEqual(store.resolvableURL(for: entry)?.path, "/Custom/App.app",
                       "无书签时退化为路径")
    }

    func testStaleBookmarkResolutionFallsBackToPath() throws {
        bookmarks = ["/Custom/App.app": Data([1, 2, 3])]
        let store = makeStore()
        let entry = try store.addOrUpdate(bundleID: "com.ex.app", appPath: "/Custom/App.app")

        bookmarks.removeAll() // 模拟书签过期:解析失败
        let reloaded = makeStore()
        let reloadedEntry = try XCTUnwrap(reloaded.entry(bundleID: "com.ex.app"))
        XCTAssertEqual(reloaded.resolvableURL(for: reloadedEntry)?.path, "/Custom/App.app",
                       "解析失败退化为记录路径,不崩溃")
        _ = entry
    }

    func testCorruptFileStartsEmpty() throws {
        try Data("not json".utf8).write(to: storeURL)
        let store = makeStore()
        XCTAssertTrue(store.entries.isEmpty, "损坏的手工清单从空开始,不拖垮主流程")
    }
}
