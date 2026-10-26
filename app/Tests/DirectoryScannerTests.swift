import XCTest
@testable import WheelFlip

/// §5.1 目录遍历:临时 .app 包模拟;含 S3 任务"安装、移动、重复副本"的目录层。
final class DirectoryScannerTests: XCTestCase {
    var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wheelflip-scan-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    @discardableResult
    private func makeApp(_ path: String, bundleID: String? = nil, name: String? = nil) throws -> URL {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true
        )
        let id = bundleID ?? "com.test." + url.deletingPathExtension().lastPathComponent
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>\(id)</string>
        <key>CFBundleName</key><string>\(name ?? id)</string>
        </dict></plist>
        """
        try plist.write(to: url.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
        return url
    }

    func testFindsTopLevelAndSubdirectoryApps() throws {
        try makeApp(root.appendingPathComponent("Warp.app").path)
        try makeApp(root.appendingPathComponent("Design/Vector.app").path) // 深度 1
        try makeApp(root.appendingPathComponent("Nested/Deep/Tool.app").path) // 深度 2

        let apps = try DirectoryScanner.scan(root: root.path)
        XCTAssertEqual(Set(apps.map(\.appPath)),
                       [root.appendingPathComponent("Warp.app").path,
                        root.appendingPathComponent("Design/Vector.app").path,
                        root.appendingPathComponent("Nested/Deep/Tool.app").path])
        XCTAssertEqual(apps.first { $0.bundleID == "com.test.Warp" }?.displayName,
                       "com.test.Warp", "名称来自 CFBundleName")
    }

    func testStopsAtAppBundleNoHelpersListed() throws {
        try makeApp(root.appendingPathComponent("Big.app").path, bundleID: "com.test.big")
        // 包内 helper/plugin(§5.1 过滤:包内 helper 不是独立条目)
        try makeApp(root.appendingPathComponent("Big.app/Contents/PlugIns/Helper.appex").path, bundleID: "com.test.helper")
        try makeApp(root.appendingPathComponent("Big.app/Contents/Frameworks/Inner.app").path, bundleID: "com.test.inner")

        let apps = try DirectoryScanner.scan(root: root.path)
        XCTAssertEqual(apps.map(\.bundleID), ["com.test.big"])
    }

    func testDepthLimitIsBounded() throws {
        try makeApp(root.appendingPathComponent("a/b/c/Deep.app").path) // 深度 3:超出上限

        let apps = try DirectoryScanner.scan(root: root.path)
        XCTAssertTrue(apps.isEmpty, "超过递归上限的目录不遍历(§5.2 不定时不整盘)")
    }

    func testTrashAndHiddenDirectoriesExcluded() throws {
        try makeApp(root.appendingPathComponent(".Hidden/App.app").path)
        try makeApp(root.appendingPathComponent(".Trash/Deleted.app").path)
        try makeApp(root.appendingPathComponent("Normal.app").path)

        let apps = try DirectoryScanner.scan(root: root.path)
        XCTAssertEqual(apps.map(\.bundleID), ["com.test.Normal"])
    }

    func testBrokenBundleWithoutIDIsSkipped() throws {
        // 无 Info.plist 的 .app(损坏包)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Broken.app/Contents/MacOS"),
            withIntermediateDirectories: true
        )
        try makeApp(root.appendingPathComponent("Good.app").path)

        let apps = try DirectoryScanner.scan(root: root.path)
        XCTAssertEqual(apps.map(\.bundleID), ["com.test.Good"],
                       "读不出 Bundle ID 的包不建条目(§5.3,不按显示名建规则)")
    }

    func testUnreadableRootThrowsNotEmpty() throws {
        let locked = root.appendingPathComponent("Locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try makeApp(locked.appendingPathComponent("X.app").path)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        XCTAssertThrowsError(try DirectoryScanner.scan(root: locked.path),
                             "无权限必须抛错,让来源记 failed(不是空)")
    }

    func testMissingRootIsEmptyNotError() throws {
        let apps = try DirectoryScanner.scan(root: root.appendingPathComponent("Nope").path)
        XCTAssertTrue(apps.isEmpty, "可选根不存在(如未创建的 ~/Applications)= 空结果")
    }

    /// §5.4 表"同一身份多副本":两份拷贝都列出,身份同一条(合并层在 AppCatalog)。
    func testDuplicateCopiesListedIndependently() throws {
        try makeApp(root.appendingPathComponent("Original.app").path, bundleID: "com.test.dup")
        try makeApp(root.appendingPathComponent("Copy.app").path, bundleID: "com.test.dup")

        let apps = try DirectoryScanner.scan(root: root.path)
        XCTAssertEqual(apps.count, 2)
        XCTAssertEqual(Set(apps.map(\.bundleID)), ["com.test.dup"])
    }
}
