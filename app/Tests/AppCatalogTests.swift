import XCTest
@testable import WheelFlip

/// §5.1 多来源合并、§9.1「目录」行:合并/去重/排序/过滤与来源状态建模。
final class AppCatalogTests: XCTestCase {
    private func found(_ bundleID: String, _ name: String, _ path: String,
                       _ source: AppCatalog.Source = .directory) -> FoundApp {
        FoundApp(bundleID: bundleID, displayName: name, appPath: path, source: source)
    }

    // MARK: 合并与去重

    func testSameBundleMergesAcrossSourcesAndCopies() {
        let snapshot = AppCatalog.snapshot(from: [
            found("com.ex.warp", "Warp", "/Applications/Warp.app", .directory),
            found("com.ex.warp", "Warp", "/System/Volumes/Data/Apps/Warp.app", .spotlight),
            found("com.ex.warp", "Warp 2", "/Applications/Warp.app", .manual),
        ], states: [], at: Date(timeIntervalSince1970: 100))

        XCTAssertEqual(snapshot.entries.count, 1, "同 Bundle ID 合并为一条(§3.3)")
        let entry = snapshot.entries[0]
        XCTAssertEqual(entry.appPaths, ["/Applications/Warp.app", "/System/Volumes/Data/Apps/Warp.app"],
                       "多副本位置去重合并")
        XCTAssertEqual(entry.sources, [.directory, .spotlight, .manual])
    }

    func testDisplayNamePriorityRunningBeatsSpotlight() {
        let snapshot = AppCatalog.snapshot(from: [
            found("com.ex.rhino", "Rhino 8", "/Applications/Rhino.app", .spotlight),
            found("com.ex.rhino", "Rhinoceros", "/Applications/Rhino.app", .runningApps),
        ], states: [], at: Date())
        XCTAssertEqual(snapshot.entries[0].displayName, "Rhinoceros", "运行中名称优先")

        let reversed = AppCatalog.snapshot(from: [
            found("com.ex.rhino", "Rhinoceros", "/Applications/Rhino.app", .runningApps),
            found("com.ex.rhino", "Rhino 8", "/Applications/Rhino.app", .spotlight),
        ], states: [], at: Date())
        XCTAssertEqual(reversed.entries[0].displayName, "Rhinoceros", "顺序无关,低优先来源不覆盖")
    }

    func testSystemAppMarking() {
        let snapshot = AppCatalog.snapshot(from: [
            found("com.apple.mail", "Mail", "/System/Applications/Mail.app", .directory),
            found("com.ex.warp", "Warp", "/Applications/Warp.app", .directory),
        ], states: [], at: Date())
        XCTAssertTrue(snapshot.entry(bundleID: "com.apple.mail")?.isSystem ?? false)
        XCTAssertFalse(snapshot.entry(bundleID: "com.ex.warp")?.isSystem ?? true)
    }

    func testEmptyAndWhitespaceBundleIDsAreSkipped() {
        let snapshot = AppCatalog.snapshot(from: [
            found("", "NoID", "/Applications/NoID.app"),
        ], states: [], at: Date())
        XCTAssertTrue(snapshot.entries.isEmpty, "读不出 Bundle ID 的包不建条目(§5.3)")
    }

    func testSortedByNameIsStableWithBundleTiebreak() {
        let snapshot = AppCatalog.snapshot(from: [
            found("com.z.zed", "App", "/x/Z.app"),
            found("com.a.two", "app", "/x/A2.app"),
            found("com.a.one", "App", "/x/A1.app"),
        ], states: [], at: Date())
        let ordered = snapshot.sortedByName().map(\.bundleID)
        XCTAssertEqual(ordered, ["com.a.one", "com.a.two", "com.z.zed"],
                       "名称不区分大小写稳定排序,重名按 Bundle ID 决胜(§4.2)")
    }

    // MARK: presence 精化(三分证据)

    private var probeMap: [String: AppCatalog.PathEvidence] = [:]
    private func refine(_ snapshot: CatalogSnapshot) -> CatalogSnapshot {
        var copy = snapshot
        AppCatalog.refinePresence(&copy, probePath: { self.probeMap[$0] ?? .unknown })
        return copy
    }

    func testPresencePresentWhenAnyPathExists() {
        probeMap = ["/Applications/Warp.app": .exists]
        let snapshot = refine(AppCatalog.snapshot(from: [
            found("com.ex.warp", "Warp", "/Applications/Warp.app"),
            found("com.ex.warp", "Warp", "/Volumes/Old/Warp.app"),
        ], states: [], at: Date()))
        XCTAssertEqual(snapshot.entries[0].presence, .present, "任一副本在场即 present")
    }

    func testPresenceUnavailableWhenPathNotVerifiable() {
        // 卷离线/无权限:缺失不可确认,绝不冒充 missing(§5.4 第 2 条)
        probeMap = ["/Volumes/Ext/App.app": .unknown]
        let snapshot = refine(AppCatalog.snapshot(from: [
            found("com.ex.ext", "Ext", "/Volumes/Ext/App.app", .spotlight),
        ], states: [], at: Date()))
        XCTAssertEqual(snapshot.entries[0].presence, .unavailable("位置不可核验"))
    }

    /// 对抗式审查修订:来源失败不再全局制造 unavailable——位置级三分证据说了算
    /// (某根永久不可读不应关闭整机缺失判定)。otherFailed 只进 sourceStates 供 UI 呈现。
    func testPresenceFollowsPathEvidenceEvenWithOtherSourceFailure() {
        probeMap = ["/Users/x/Applications/Personal.app": .absent]
        var snapshot = AppCatalog.snapshot(from: [
            found("com.ex.personal", "Personal", "/Users/x/Applications/Personal.app", .spotlight),
        ], states: [.failed("目录 /Users/x/Applications 不可读")], at: Date())
        AppCatalog.refinePresence(&snapshot, probePath: { self.probeMap[$0] ?? .unknown })
        XCTAssertEqual(snapshot.entries[0].presence, .missing,
                       "路径可证缺失时按缺失处理;来源失败不冒充不可确认")
    }

    func testPresenceMissingOnlyWithPositiveAbsenceEvidence() {
        probeMap = ["/Applications/Gone.app": .absent]
        let snapshot = refine(AppCatalog.snapshot(from: [
            found("com.ex.gone", "Gone", "/Applications/Gone.app", .spotlight),
        ], states: [], at: Date()))
        XCTAssertEqual(snapshot.entries[0].presence, .missing, "可证缺失才是 missing")
    }

    // MARK: 刷新(注入假来源,后台合并)

    func testRefreshCollectsAndMergesAllSources() {
        let listerCalls = LockedCount()
        let catalog = AppCatalog(
            directoryRoots: [
                ("/Applications", { _ in
                    listerCalls.increment()
                    return [self.found("com.ex.warp", "Warp", "/Applications/Warp.app")]
                }),
                ("/System/Applications", { _ in
                    [self.found("com.apple.mail", "Mail", "/System/Applications/Mail.app")]
                }),
            ],
            spotlightProvider: { [self.found("com.ex.personal", "Personal", "/Users/x/Apps/Personal.app", .spotlight)] },
            runningAppsProvider: { [self.found("com.ex.warp", "Warp", "/Applications/Warp.app", .runningApps)] },
            probePath: { _ in .exists }
        )
        let done = expectation(description: "refresh")
        catalog.onRefresh = { snapshot in
            XCTAssertEqual(snapshot.entries.count, 3)
            XCTAssertEqual(snapshot.entry(bundleID: "com.ex.warp")?.sources, [.directory, .runningApps])
            XCTAssertEqual(listerCalls.value, 1)
            done.fulfill()
        }
        catalog.refresh()
        wait(for: [done], timeout: 5)
        XCTAssertNotNil(catalog.snapshot)
    }

    func testRefreshRecordsFailureInsteadOfEmpty() {
        let catalog = AppCatalog(
            directoryRoots: [("/nope", { _ in
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
            })],
            spotlightProvider: nil,
            runningAppsProvider: { [] },
            probePath: { _ in .exists }
        )
        let done = expectation(description: "refresh")
        catalog.onRefresh = { snapshot in
            XCTAssertTrue(snapshot.sourceStates.contains { $0.isFailure },
                          "权限失败必须记为 failed,不得包装成空结果")
            done.fulfill()
        }
        catalog.refresh()
        wait(for: [done], timeout: 5)
    }

    // MARK: 增量补录

    func testAddRunningAppMergesIncrementally() {
        probeMap = [:]
        let catalog = AppCatalog(
            directoryRoots: [],
            spotlightProvider: nil,
            runningAppsProvider: { [] },
            probePath: { _ in .exists }
        )
        let done = expectation(description: "refresh")
        catalog.onRefresh = { _ in done.fulfill() }
        catalog.refresh()
        wait(for: [done], timeout: 5)

        let updated = expectation(description: "addRunningApp")
        catalog.onRefresh = { snapshot in
            if snapshot.entry(bundleID: "com.ex.new") != nil {
                updated.fulfill()
            }
        }
        catalog.addRunningApp(found("com.ex.new", "NewApp", "/Custom/NewApp.app", .runningApps))
        wait(for: [updated], timeout: 5)
        XCTAssertEqual(catalog.snapshot?.entry(bundleID: "com.ex.new")?.displayName, "NewApp")
    }

    func testRemoveRunningPIDKeepsEntryAndPublishes() {
        probeMap = [:]
        let pid: pid_t = 4242
        let catalog = AppCatalog(
            directoryRoots: [],
            spotlightProvider: nil,
            runningAppsProvider: { [FoundApp(bundleID: "com.ex.warp", displayName: "Warp",
                                             appPath: "/Applications/Warp.app",
                                             source: .runningApps, pid: pid)] },
            probePath: { _ in .exists }
        )
        let refreshed = expectation(description: "refresh")
        catalog.onRefresh = { _ in refreshed.fulfill() }
        catalog.refresh()
        wait(for: [refreshed], timeout: 5)

        // F15:进程退出也发布快照,UI 的进程相关展示不陈旧
        let published = expectation(description: "pid-removal-publishes")
        catalog.onRefresh = { snapshot in
            if snapshot.entry(bundleID: "com.ex.warp")?.runningPIDs.isEmpty == true {
                published.fulfill()
            }
        }
        catalog.removeRunningPID(pid)
        wait(for: [published], timeout: 5)
        XCTAssertNotNil(catalog.snapshot?.entry(bundleID: "com.ex.warp"),
                        "进程退出不删除条目,交由下一轮复核")
    }
}

private final class LockedCount {
    private let lock = NSLock()
    private var n = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return n
    }
    func increment() {
        lock.lock(); n += 1; lock.unlock()
    }
}
