import AppKit
import XCTest
@testable import WheelFlip

/// §5.4 卸载判定与 §9.1「清理」行:宽限复核、运行中保留、不可用一票否决、
/// 用户编辑保护、重装跟随默认。全部注入时钟与位置探针(不碰真实文件系统)。
final class AppRuleReconcilerTests: RuleStoreTestBase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let grace: TimeInterval = 24 * 3600
    private var evidence: [String: AppCatalog.PathEvidence] = [:]

    override func setUp() {
        super.setUp()
        evidence = [:]
    }

    // MARK: 工具

    private var prober: AppCatalog.PathProber {
        { self.evidence[$0] ?? .unknown }
    }

    private func snapshot(entries: [CatalogEntry],
                          spotlightFailed: Bool = false,
                          otherFailed: Bool = false) -> CatalogSnapshot {
        var states: [AppCatalog.SourceState] = [.completed(found: entries.count)]
        if spotlightFailed {
            states.append(.failed("Spotlight 查询失败:超时"))
        }
        if otherFailed {
            states.append(.failed("目录 /Users/x/Applications 不可读"))
        }
        return CatalogSnapshot(entries: entries, sourceStates: states, generatedAt: t0)
    }

    private func entry(_ bundleID: String, paths: [String], presence: AppCatalog.Presence = .present,
                       pids: Set<pid_t> = []) -> CatalogEntry {
        CatalogEntry(bundleID: bundleID, displayName: bundleID, displayNameSource: .directory,
                     appPaths: paths, isSystem: false, runningPIDs: pids,
                     sources: [.directory], presence: presence)
    }

    private func rules(overrides: [String: RuleOverrideEntry], defaultFlip: Bool = true) -> RuleSettings {
        RuleSettings(defaultFlip: defaultFlip, overrides: overrides)
    }

    private func evaluate(_ catalog: CatalogSnapshot, _ rules: RuleSettings, at now: Date) -> [CleanupAction] {
        AppRuleReconciler.evaluate(catalog: catalog, rules: rules, now: now,
                                   grace: grace, probePath: prober)
    }

    // MARK: 在场/记录位置

    func testPresentAppRecordsMergedLocations() {
        // warp:目录条目在场、位置未记录 → 记录
        let actions = evaluate(snapshot(entries: [entry("com.ex.warp", paths: ["/Applications/Warp.app"])]),
                               rules(overrides: ["com.ex.warp": RuleOverrideEntry(mode: .forceOff)]),
                               at: t0)
        XCTAssertEqual(actions, [.recordLocations(bundleID: "com.ex.warp", locations: ["/Applications/Warp.app"])])

        // gone:目录查不到,但历史位置探得在场且此前在缺失计时中 → 取消(位置已记录,不重复写)
        evidence = ["/Applications/Gone.app": .exists]
        let goneEntry = RuleOverrideEntry(mode: .forceOn, locations: ["/Applications/Gone.app"], missingSince: t0)
        let goneActions = evaluate(snapshot(entries: []),
                                   rules(overrides: ["com.ex.gone": goneEntry]), at: t0)
        XCTAssertEqual(goneActions, [.cancelMissing(bundleID: "com.ex.gone")],
                       "目录查不到 ≠ 不在:探得在场即取消候选")
    }

    func testNoActionWithoutOverrideOrEvidencePoint() {
        // 无覆盖:目录里 300 个 App 也不产生任何清理动作(§5.3 首次列出 300 个不写 300 条)
        let catalog = snapshot(entries: (0..<300).map { entry("com.ex.app\($0)", paths: ["/x/\($0).app"]) })
        XCTAssertTrue(evaluate(catalog, rules(overrides: [:]), at: t0).isEmpty)

        // 有覆盖但无条目也无历史位置:没有任何可核验点,不推进(不把未知当缺失)
        let rules2 = self.rules(overrides: ["com.ex.ghost": RuleOverrideEntry(mode: .forceOn)])
        XCTAssertTrue(evaluate(snapshot(entries: []), rules2, at: t0).isEmpty)
    }

    // MARK: 缺失证据 = 位置级探测

    func testNewMissingRecordsLocationsThenMarksTimestamp() {
        evidence = ["/Applications/Gone.app": .absent]
        let rulesEntry = RuleOverrideEntry(mode: .forceOff)
        let catalog = snapshot(entries: [entry("com.ex.gone", paths: ["/Applications/Gone.app"], presence: .missing)])
        // 首次缺失:先落证据点(位置全集),再开钟——后续轮次与删除守卫都依赖它
        XCTAssertEqual(evaluate(catalog, rules(overrides: ["com.ex.gone": rulesEntry]), at: t0),
                       [.recordLocations(bundleID: "com.ex.gone", locations: ["/Applications/Gone.app"]),
                        .markMissing(bundleID: "com.ex.gone", firstMissingAt: t0)])
    }

    /// entry==nil(目录查不到)时,判定回探 RuleStore 记录的位置——这是唯一证据来源;
    /// 连记录都没有时不推进(没有可核验点)。
    func testEntryAbsentFromCatalogProbesRecordedLocations() {
        // 无条目也无记录:不推进(不把未知当缺失)
        evidence = ["/Custom/App.app": .exists]
        var actions = evaluate(snapshot(entries: []),
                               rules(overrides: ["com.ex.app": RuleOverrideEntry(mode: .forceOff)]), at: t0)
        XCTAssertTrue(actions.isEmpty, "没有任何可核验点")

        let recorded = RuleOverrideEntry(mode: .forceOff, locations: ["/Custom/App.app"], missingSince: t0)

        // 位置仍在(索引没覆盖的自定义位置):取消候选,不重复记录
        evidence = ["/Custom/App.app": .exists]
        actions = evaluate(snapshot(entries: []), rules(overrides: ["com.ex.app": recorded]), at: t0)
        XCTAssertEqual(actions, [.cancelMissing(bundleID: "com.ex.app")])

        // 位置不可核验(卷离线):一票否决
        evidence = ["/Custom/App.app": .unknown]
        actions = evaluate(snapshot(entries: []), rules(overrides: ["com.ex.app": recorded]), at: t0)
        XCTAssertTrue(actions.isEmpty, "不可核验不得推进")

        // 位置可证缺失:记录在案的空档不动,计时继续(宽限内无动作)
        evidence = ["/Custom/App.app": .absent]
        actions = evaluate(snapshot(entries: []), rules(overrides: ["com.ex.app": recorded]), at: t0.addingTimeInterval(60))
        XCTAssertTrue(actions.isEmpty, "宽限期内暂缓")

        // 首轮缺失(位置来自目录条目而非历史记录):先落证据点再开钟
        evidence = ["/Applications/Gone.app": .absent]
        actions = evaluate(snapshot(entries: [entry("com.ex.gone", paths: ["/Applications/Gone.app"], presence: .missing)]),
                           rules(overrides: ["com.ex.gone": RuleOverrideEntry(mode: .forceOn)]), at: t0)
        XCTAssertEqual(actions, [.recordLocations(bundleID: "com.ex.gone", locations: ["/Applications/Gone.app"]),
                                  .markMissing(bundleID: "com.ex.gone", firstMissingAt: t0)])
    }

    /// Spotlight 失败 = "复查其他位置/注册信息"不可用 → 缺失推进暂停(§5.4 条件 3)。
    /// 目录根失败(如沙盒内 ~/Applications 永久不可读)不再全局否决——位置级探针
    /// 已按条目给出准确结论(对抗式审查修订)。
    func testSpotlightFailurePausesMissingProgression() {
        evidence = ["/Applications/Gone.app": .absent]
        // 已过宽限 + 已复核:若无 Spotlight 失败本应 proposeRemove
        let rulesEntry = RuleOverrideEntry(mode: .forceOff, locations: ["/Applications/Gone.app"],
                                           missingSince: t0,
                                           lastVerifiedMissing: t0.addingTimeInterval(grace + 60))
        let catalog = snapshot(entries: [], spotlightFailed: true, otherFailed: true)

        XCTAssertTrue(evaluate(catalog, rules(overrides: ["com.ex.gone": rulesEntry]),
                               at: t0.addingTimeInterval(grace * 3)).isEmpty,
                      "Spotlight 失败时缺失推进暂停")
    }

    func testWithinGraceNoProgress() {
        evidence = ["/Applications/Gone.app": .absent]
        let rulesEntry = RuleOverrideEntry(mode: .forceOff, locations: ["/Applications/Gone.app"], missingSince: t0)
        let catalog = snapshot(entries: [])
        XCTAssertTrue(evaluate(catalog, rules(overrides: ["com.ex.gone": rulesEntry]), at: t0.addingTimeInterval(grace - 1)).isEmpty,
                      "宽限期内暂缓判断")
    }

    func testGraceElapsedFirstRecheckConfirmsSecondProposes() {
        evidence = ["/Applications/Gone.app": .absent]
        let catalog = snapshot(entries: [])
        let afterGrace = t0.addingTimeInterval(grace + 60)

        var rulesEntry = RuleOverrideEntry(mode: .forceOff, locations: ["/Applications/Gone.app"], missingSince: t0)
        rulesEntry.lastVerifiedMissing = nil
        XCTAssertEqual(evaluate(catalog, rules(overrides: ["com.ex.gone": rulesEntry]), at: afterGrace),
                       [.confirmStillMissing(bundleID: "com.ex.gone", verifiedAt: afterGrace)])

        rulesEntry.lastVerifiedMissing = afterGrace
        XCTAssertEqual(evaluate(catalog, rules(overrides: ["com.ex.gone": rulesEntry]), at: afterGrace.addingTimeInterval(3600)),
                       [.proposeRemoveOverride(bundleID: "com.ex.gone", firstMissingAt: t0)])
    }

    func testReappearanceCancelsCandidate() {
        evidence = ["/Applications/Gone.app": .exists]
        let rulesEntry = RuleOverrideEntry(mode: .forceOff, locations: ["/Applications/Gone.app"],
                                           missingSince: t0, lastVerifiedMissing: t0)
        let actions = evaluate(snapshot(entries: []), rules(overrides: ["com.ex.gone": rulesEntry]),
                               at: t0.addingTimeInterval(grace * 2))
        XCTAssertEqual(actions, [.cancelMissing(bundleID: "com.ex.gone")], "重新出现取消缺失候选")
    }

    func testRunningProcessBlocksDeletion() {
        // 包删了进程还在:保留,退出后复核(§5.4 表)——在场判定先于运行判定,
        // presence .missing + PID 在跑
        evidence = ["/Applications/Z.app": .absent]
        let rulesEntry = RuleOverrideEntry(mode: .forceOff, locations: ["/Applications/Z.app"],
                                           missingSince: t0,
                                           lastVerifiedMissing: t0.addingTimeInterval(grace + 60))
        let catalog = snapshot(entries: [entry("com.ex.zombie", paths: ["/Applications/Z.app"],
                                               presence: .missing, pids: [999])])
        XCTAssertTrue(evaluate(catalog, rules(overrides: ["com.ex.zombie": rulesEntry]),
                               at: t0.addingTimeInterval(grace * 3)).isEmpty)
    }

    func testCorruptedTimestampsRestartGrace() {
        evidence = ["/Applications/Odd.app": .absent]
        let rulesEntry = RuleOverrideEntry(mode: .forceOff, locations: ["/Applications/Odd.app"],
                                           missingSince: t0,
                                           lastVerifiedMissing: t0.addingTimeInterval(-100))
        let catalog = snapshot(entries: [])
        XCTAssertEqual(evaluate(catalog, rules(overrides: ["com.ex.odd": rulesEntry]), at: t0.addingTimeInterval(grace * 2)),
                       [.markMissing(bundleID: "com.ex.odd", firstMissingAt: t0.addingTimeInterval(grace * 2))])
    }

    // MARK: 执行器(条件 5:新鲜探测 + 原子守卫;附属记录清理)

    private func makeExecutor(store: RuleStore, manual: ManualAppStore? = nil,
                              icons: IconProviding? = nil) -> CleanupExecutor {
        CleanupExecutor(store: store, manualApps: manual, icons: icons, probePath: prober)
    }

    /// 先经一轮"在场"记录位置,再走"开钟 → 宽限后第一次复核"两个时点。
    private func stageMissing(_ store: RuleStore, executor: CleanupExecutor, paths: [String]) throws {
        try store.setOverride(bundleID: "com.ex.app", mode: .forceOff)

        // 在场轮:记录位置
        evidence = Dictionary(uniqueKeysWithValues: paths.map { ($0, AppCatalog.PathEvidence.exists) })
        let presentCatalog = snapshot(entries: paths.map { entry("com.ex.app", paths: [$0]) })
        try executor.apply(evaluate(presentCatalog, try XCTUnwrap(store.settings), at: t0), catalog: presentCatalog)

        // 缺失轮:开钟 → 宽限后第一次复核
        evidence = Dictionary(uniqueKeysWithValues: paths.map { ($0, AppCatalog.PathEvidence.absent) })
        try executor.apply(evaluate(snapshot(entries: []), try XCTUnwrap(store.settings), at: t0.addingTimeInterval(3600)),
                           catalog: snapshot(entries: []))
        try executor.apply(evaluate(snapshot(entries: []), try XCTUnwrap(store.settings),
                                    at: t0.addingTimeInterval(3600 + grace)), catalog: snapshot(entries: []))
    }

    func testExecutorFullLifecycleDeletesAfterTwoRechecks() throws {
        let store = makeLoadedStore()
        let executor = makeExecutor(store: store)
        try stageMissing(store, executor: executor, paths: ["/Applications/App.app"])
        XCTAssertNotNil(store.settings?.overrides["com.ex.app"]?.lastVerifiedMissing)

        // 第二次评估仍缺失 → 删除;重装后没有覆盖 → 跟随默认(§5.4 表末行)
        let removed = executor.apply(
            evaluate(snapshot(entries: []), try XCTUnwrap(store.settings), at: t0.addingTimeInterval(3600 + grace + 60)),
            catalog: snapshot(entries: [])
        )
        XCTAssertEqual(removed, ["com.ex.app"])
        XCTAssertNil(store.settings?.overrides["com.ex.app"], "清理后覆盖删除")

        let rulesAfter = try XCTUnwrap(store.settings)
        XCTAssertNil(rulesAfter.overrides["com.ex.app"])
        XCTAssertEqual(
            FlipPolicy.decide(defaultFlip: rulesAfter.defaultFlip, override: nil, eventKind: .discrete).source,
            .globalDefault, "清理完成后的重新安装按默认处理"
        )
    }

    /// 对抗式审查证实:应用在评估与落地之间回来(安装器落盘)必须中止删除。
    func testExecutorRefusesWhenAppReappearedBeforeDelete() throws {
        let store = makeLoadedStore()
        let executor = makeExecutor(store: store)
        try stageMissing(store, executor: executor, paths: ["/Applications/App.app"])

        evidence = ["/Applications/App.app": .exists] // 落地瞬间:应用回来了
        let removed = executor.apply(
            evaluate(snapshot(entries: []), try XCTUnwrap(store.settings), at: t0.addingTimeInterval(3600 + grace + 60)),
            catalog: snapshot(entries: [])
        )
        // evaluate 本轮看到 .exists 会先 cancel/record,不会产出删除;
        // 即使直接塞一条旧删除建议,执行器的新鲜探测也要拒绝:
        XCTAssertTrue(removed.isEmpty)
        XCTAssertNotNil(store.settings?.overrides["com.ex.app"], "删除前重验失败不得删除")

        evidence = ["/Applications/App.app": .unknown] // 不可核验同样拒绝
        let staleProposal = executor.apply(
            [.proposeRemoveOverride(bundleID: "com.ex.app", firstMissingAt: t0.addingTimeInterval(3600))],
            catalog: snapshot(entries: [])
        )
        XCTAssertTrue(staleProposal.isEmpty)
    }

    func testExecutorRefusesWhenUserEditedDuringGrace() throws {
        let store = makeLoadedStore()
        let executor = makeExecutor(store: store)
        try stageMissing(store, executor: executor, paths: ["/Applications/App.app"])

        // 用户在删除窗口内重新编辑该 App 的规则 → 计时被重置 → 旧删除任务作废
        try store.setOverride(bundleID: "com.ex.app", mode: .forceOn)

        let staleProposal = executor.apply(
            [.proposeRemoveOverride(bundleID: "com.ex.app", firstMissingAt: t0)],
            catalog: snapshot(entries: [])
        )
        XCTAssertTrue(staleProposal.isEmpty, "用户刚编辑的 App 不得被旧清理任务删除(§6.1)")
        XCTAssertEqual(store.settings?.overrides["com.ex.app"], RuleOverrideEntry(
            mode: .forceOn, locations: ["/Applications/App.app"]))
    }

    func testExecutorCleansManualBookmarkAndIconsOnDelete() throws {
        let store = makeLoadedStore()
        let executor = makeExecutor(store: store)
        try stageMissing(store, executor: executor, paths: ["/Applications/App.app"])

        let manual = ManualAppStore(fileURL: tmpDir.appendingPathComponent("manual.json"),
                                    createBookmark: { _ in Data([1, 2, 3]) },
                                    resolveBookmark: { _ in nil })
        try manual.addOrUpdate(bundleID: "com.ex.app", appPath: "/Applications/App.app")
        XCTAssertNotNil(manual.entry(bundleID: "com.ex.app"))

        var evicted: [String] = []
        let icons = RecordingIconProvider(onEvict: { evicted.append($0) })
        let executorWithCleanup = CleanupExecutor(store: store, manualApps: manual, icons: icons,
                                                  probePath: prober)

        let removed = executorWithCleanup.apply(
            [.proposeRemoveOverride(bundleID: "com.ex.app",
                                    firstMissingAt: store.settings!.overrides["com.ex.app"]!.missingSince!)],
            catalog: snapshot(entries: [])
        )
        XCTAssertEqual(removed, ["com.ex.app"])
        XCTAssertNil(manual.entry(bundleID: "com.ex.app"), "书签随覆盖删除(§5.4)")
        XCTAssertEqual(evicted, ["/Applications/App.app"], "图标缓存逐出")
    }
}

/// 记录逐出事件的图标提供者假件。
private final class RecordingIconProvider: IconProviding {
    private let onEvict: (String) -> Void
    init(onEvict: @escaping (String) -> Void) { self.onEvict = onEvict }
    func icon(forAppPath appPath: String) -> NSImage? { nil }
    func evict(appPath: String) { onEvict(appPath) }
}
