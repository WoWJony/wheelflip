// UI fixture:--ui-fixture 启动的界面验证模式。
//
// 注入假引擎、临时规则、假登录项和固定目录;不创建状态栏图标、不触碰日常配置、
// 不注册登录项;窗口标题明确标注"UI 验证"。
// 场景由 --scenario <name> 指定,覆盖七类面板与 20 轮暂停/恢复压测。
//
// 用法(直接执行二进制,stdout 可被脚本捕获):
//   WheelFlip --ui-fixture --scenario running|paused|permission|engine-failed|
//             rules-corrupt|save-failure|no-target|stress

import AppKit
import SwiftUI

enum FixtureScenario: String {
    case running
    case paused
    case permission
    case engineFailed = "engine-failed"
    case rulesCorrupt = "rules-corrupt"
    case saveFailure = "save-failure"
    case noTarget = "no-target"
    case stress
}

final class FixtureEngine: FlipEngineControlling {
    var isRunning = false
    var startFailure: EngineStartFailure?
    func start() -> EngineStartFailure? {
        if let startFailure { return startFailure }
        isRunning = true
        return nil
    }
    func stop() { isRunning = false }
}

final class FixtureLoginItems: LoginItemManaging {
    func register() -> String? { nil }
    func unregister() -> String? { nil }
}

final class FixtureController: NSObject, NSApplicationDelegate {
    let scenario: FixtureScenario
    let engine = FixtureEngine()
    private var trusted = true
    private(set) var appState: AppState!
    private var panelWindow: NSWindow?
    private var managementWindow: NSWindow?
    private var workDir: URL!
    private var exitCode = 0

    // MARK: 装配

    init(scenario: FixtureScenario) {
        self.scenario = scenario
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // --appearance dark|light:深浅色截图验收(应用级外观,不动系统设置)
        if let appearance = Self.argumentValue("--appearance") {
            NSApp.appearance = appearance == "dark"
                ? NSAppearance(named: .darkAqua)
                : NSAppearance(named: .aqua)
        }

        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wheelflip-ui-fixture-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let settingsURL = workDir.appendingPathComponent("rules.json")
        if scenario == .rulesCorrupt {
            try? Data("garbage {{{ fixture".utf8).write(to: settingsURL)
        }
        let suiteName = "com.jonywu.WheelFlip.ui-fixture-\(UUID().uuidString)"
        let legacy = UserDefaults(suiteName: suiteName)!
        legacy.removePersistentDomain(forName: suiteName)

        if scenario == .engineFailed {
            engine.startFailure = .tapUnavailable("CGEvent.tapCreate 失败(fixture 演示)")
        }
        if scenario == .permission {
            trusted = false
        }

        appState = AppState(
            engine: engine,
            rules: RuleSnapshotBox(),
            store: RuleStore(settingsURL: settingsURL, legacyDefaults: legacy),
            isTrusted: { [weak self] in self?.trusted ?? true },
            loginItems: FixtureLoginItems(),
            ownBundleID: "com.jonywu.WheelFlip" // 与生产一致:自己窗口不替换目标
        )

        seedRules()
        seedCatalog()
        seedPanelContext()

        if scenario == .paused {
            appState.pauseAll()
        }
        if scenario == .saveFailure {
            prepareSaveFailure()
        }

        print("FIXTURE scenario=\(scenario.rawValue) phase=\(describe(appState.phase)) target=\(appState.panelTarget?.bundleID ?? "-")")
        fflush(stdout)

        showPanelWindow()
        if scenario == .stress {
            runStress()
        }
        scheduleShots()
    }

    // MARK: 截图导出(cacheDisplay 自渲染,不依赖屏幕录制权限)

    private static func argumentValue(_ flag: String) -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }

    /// --shot <path> 面板截图;--shot-management <path> 追加管理窗口截图。
    /// 完成后自动退出(exit 0),供脚本串联全部场景。
    private func scheduleShots() {
        let panelShot = Self.argumentValue("--shot")
        let managementShot = Self.argumentValue("--shot-management")
        guard panelShot != nil || managementShot != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            if let panelShot {
                self.saveShot(of: self.panelWindow, to: panelShot)
            }
            if let managementShot {
                self.showManagementWindow()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    guard let self else { return }
                    self.saveShot(of: self.managementWindow, to: managementShot)
                    self.terminate(exitCode: 0)
                }
            } else {
                self.terminate(exitCode: 0)
            }
        }
    }

    private func saveShot(of window: NSWindow?, to path: String) {
        guard let window, let content = window.contentView else {
            print("SHOT_FAIL no window for \(path)")
            fflush(stdout)
            return
        }
        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            print("SHOT_FAIL no rep for \(path)")
            fflush(stdout)
            return
        }
        content.cacheDisplay(in: content.bounds, to: rep)
        let png = rep.representation(using: .png, properties: [:])
        do {
            try png?.write(to: URL(fileURLWithPath: path))
            print("SHOT \(path)")
            fflush(stdout)
        } catch {
            print("SHOT_FAIL \(path): \(error)")
            fflush(stdout)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: 种子数据

    private func seedRules() {
        guard appState.store.settings != nil else { return } // rules-corrupt 场景跳过
        appState.setOverride(bundleID: "com.apple.Preview", mode: .forceOff)
        appState.setOverride(bundleID: "com.apple.Terminal", mode: .forceOn)
        guard scenario != .running else { return }
        // 并集演示:有覆盖但目录里没有的 应用(名称由历史位置推导)
        appState.setOverride(bundleID: "com.ex.hidden", mode: .forceOn)
        try? appState.store.updateOverrideMetadata(bundleID: "com.ex.hidden") { entry in
            entry.locations = ["/Volumes/Extra/Hidden.app"]
        }
        // 已确认缺失(宽限期内)的覆盖
        appState.setOverride(bundleID: "com.ex.gone", mode: .forceOff)
        try? appState.store.updateOverrideMetadata(bundleID: "com.ex.gone") { entry in
            entry.missingSince = Date(timeIntervalSinceNow: -3600)
        }
    }

    private func seedCatalog() {
        func entry(_ bundleID: String, _ name: String, path: String? = nil,
                   presence: AppCatalog.Presence = .present,
                   pids: Set<pid_t> = []) -> CatalogEntry {
            CatalogEntry(bundleID: bundleID, displayName: name, displayNameSource: .directory,
                         appPaths: [path ?? "/Applications/\(name).app"], isSystem: false,
                         runningPIDs: pids, sources: [.directory], presence: presence)
        }
        let snapshot = CatalogSnapshot(entries: [
            entry("com.apple.TextEdit", "TextEdit", path: "/System/Applications/TextEdit.app", pids: [4242]),
            entry("com.apple.Preview", "Preview", path: "/System/Applications/Preview.app"),
            entry("com.apple.Terminal", "Terminal", path: "/System/Applications/Utilities/Terminal.app"),
            entry("com.ex.toolA", "Tool", path: "/Applications/Tool.app"),
            entry("com.ex.toolB", "Tool", path: "~/Applications/Tool.app"),
            entry("com.ex.gone", "GoneApp", presence: .missing),
            entry("com.ex.offline", "OfflineApp", presence: .unavailable("卷离线")),
        ], sourceStates: [
            .completed(found: 6),
            .failed("目录 /Users/fixture/Applications 不可读:fixture 演示"),
        ], generatedAt: Date())
        appState.noteCatalogSnapshot(snapshot)
    }

    private func seedPanelContext() {
        guard scenario != .noTarget else { return }
        let targetBundleID = "com.apple.TextEdit"
        switch scenario {
        case .paused, .permission, .engineFailed, .saveFailure, .rulesCorrupt, .stress:
            // 上次识别在几分钟前(演示"上次识别到 · N 分钟前"与 5 分钟阈值)
            appState.noteEngineEvent(.init(flipped: true, bundleID: targetBundleID, source: .globalDefault))
            appState.setLastIdentifiedTargetForTesting(
                IdentifiedTarget(bundleID: targetBundleID,
                                 lastSeenAt: Date(timeIntervalSinceNow: -3 * 60))
            )
        case .running, .noTarget:
            appState.noteEngineEvent(.init(flipped: true, bundleID: targetBundleID, source: .globalDefault))
        }
        appState.pinPanelTarget()
    }

    /// 破坏保存路径(与单元测试同法):父目录换成普通文件,触发真实保存失败。
    private func prepareSaveFailure() {
        let settingsURL = workDir.appendingPathComponent("rules.json")
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("wheelflip-fixture-moved-\(UUID().uuidString).json")
        try? FileManager.default.moveItem(at: settingsURL, to: outside)
        try? FileManager.default.removeItem(at: workDir)
        try? Data("x".utf8).write(to: workDir)
        // 触发一次真实失败,让面板呈现"错误紧邻控件"的状态
        appState.setOverride(bundleID: "com.apple.TextEdit", mode: .forceOn)
        print("FIXTURE save-failure: saveState=\(String(describing: appState.saveState))")
        fflush(stdout)
    }

    // MARK: 窗口

    private func showPanelWindow() {
        let hosting = NSHostingController(rootView: MainView(appState: appState, icons: IconProvider(), actions: makeActions()))
        let window = NSWindow(contentViewController: hosting)
        window.title = "WheelFlip 面板 · UI 验证(fixture)"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        let fitting = hosting.view.fittingSize
        window.setContentSize(NSSize(width: fitting.width, height: fitting.height))
        window.center()
        // 后台 shell 拉起的进程不一定能 activate;强制置前保证可截屏
        window.level = .floating
        panelWindow = window
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        print("PANEL_WINDOW \(window.windowNumber)")
        fflush(stdout)
    }

    private func showManagementWindow() {
        if let window = managementWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let manualURL = workDir.appendingPathComponent("manual-apps.json")
        let model = AppManagementModel(
            appState: appState,
            manualApps: ManualAppStore(fileURL: manualURL, createBookmark: { _ in nil }, resolveBookmark: { _ in nil }),
            icons: IconProvider(),
            requestCatalogRefresh: {}
        )
        if let snapshot = appState.catalogSnapshot {
            model.reload(from: snapshot)
        }
        let hosting = NSHostingController(rootView: AppManagementView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "WheelFlip · 应用规则 · UI 验证(fixture)"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 680, height: 420)
        window.setContentSize(NSSize(width: 760, height: 520))
        window.center()
        window.level = .floating
        managementWindow = window
        window.orderFrontRegardless()
        print("MANAGEMENT_WINDOW \(window.windowNumber)")
        fflush(stdout)
    }

    private func makeActions() -> PanelActions {
        PanelActions(
            openManagement: { [weak self] in self?.showManagementWindow() },
            quit: { [weak self] in self?.terminate(exitCode: 0) },
            showAbout: { NSApp.orderFrontStandardAboutPanel(nil) },
            openAccessibilitySettings: {},
            openLoginItemSettings: {},
            revealSelfInFinder: {},
            revealRulesBackup: {},
            relaunchForPermissionCheck: { [weak self] in
                self?.appState.notePermissionRecheckStillDenied()
            }
        )
    }

    // MARK: 20 轮暂停/恢复压测

    /// 真实 GUI 实例上的受控验证:每轮记录 phase、presentation 主操作与结果前缀,
    /// 断言三者一致且不依赖重开面板;结论打印到 stdout(STRESS RESULT: PASS/FAIL)。
    private func runStress() {
        let rounds = 20
        let interval: TimeInterval = 0.35
        print("STRESS begin rounds=\(rounds)")
        fflush(stdout)
        var failures = 0

        func step(_ index: Int) {
            guard index <= rounds else {
                let verdict = failures == 0 ? "PASS" : "FAIL"
                print("STRESS RESULT: \(verdict) rounds=\(rounds) failures=\(failures)")
                fflush(stdout)
                terminate(exitCode: failures == 0 ? 0 : 1)
                return
            }
            appState.pauseAll()
            var ok = assertRound(tag: "pause", index: index, expectedPhase: "paused",
                                 expectedAction: "恢复全部", expectedPrefix: "恢复后：")
            appState.resumeRules()
            ok = assertRound(tag: "resume", index: index, expectedPhase: "running",
                             expectedAction: "暂停全部", expectedPrefix: "按当前规则：") && ok
            if !ok { failures += 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
                step(index + 1)
            }
        }
        step(1)
    }

    /// 单轮断言:同一面板内,状态标题、主操作按钮与结果前缀必须一致变化。
    private func assertRound(tag: String, index: Int, expectedPhase: String,
                             expectedAction: String, expectedPrefix: String) -> Bool {
        let phase = describe(appState.phase)
        let presentation = ServicePresentation.present(appState.phase)
        let actionTitle = presentation.primaryAction?.title ?? "-"
        let prefix = presentation.resultPrefix ?? "-"
        let engineRunning = engine.isRunning
        let ok = phase == expectedPhase && actionTitle == expectedAction && prefix == expectedPrefix
        let mark = ok ? "✓" : "✗"
        print("STRESS round=\(index < 10 ? "0\(index)" : "\(index)") \(tag) \(mark) phase=\(phase) action=\(actionTitle) prefix=\(prefix) engine=\(engineRunning)")
        if !ok {
            print("STRESS   expected phase=\(expectedPhase) action=\(expectedAction) prefix=\(expectedPrefix)")
        }
        fflush(stdout)
        return ok
    }

    private func describe(_ phase: AppPhase) -> String {
        switch phase {
        case .onboarding: return "onboarding"
        case .running: return "running"
        case .paused: return "paused"
        case .needsPermission(let reason): return "needsPermission(\(reason))"
        case .engineFailed(let reason): return "engineFailed(\(reason))"
        case .rulesFailed(let reason): return "rulesFailed(\(reason.prefix(40)))"
        }
    }

    private func terminate(exitCode code: Int) {
        exitCode = code
        NSApp.terminate(nil)
    }

    var fixtureExitCode: Int { exitCode }
}

enum FixtureRunner {
    static func run(scenario rawValue: String) -> Never {
        let scenario = FixtureScenario(rawValue: rawValue) ?? .running
        let app = NSApplication.shared
        let controller = FixtureController(scenario: scenario)
        app.delegate = controller
        app.setActivationPolicy(.accessory)
        app.run()
        exit(Int32(controller.fixtureExitCode))
    }
}
