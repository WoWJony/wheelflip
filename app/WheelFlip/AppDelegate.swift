import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// XCTest 以本 App 为宿主(project.yml 的 TEST_HOST)时注入该环境键。
    /// 存在即说明当前进程只是测试载体:不组装 AppState/引擎/登录项,
    /// 避免测试宿主启动第二个翻转 tap 或触碰日常配置。
    static let isXCTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var appState: AppState!
    private var engine: FlipEngine!
    private var cancellable: AnyCancellable?
    // S3:应用目录与清理(§5);观察者在 applicationWillTerminate 移除。
    private var catalog: AppCatalog?
    private var manualApps: ManualAppStore?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var directoryWatchers: [DispatchSourceFileSystemObject] = []
    private var refreshDebounce: DispatchWorkItem?
    private var iconProvider: IconProvider?
    private var rulesBox: RuleSnapshotBox?
    // S4:管理窗口(单实例复用,§4.2)与其模型
    private var managementWindow: NSWindow?
    private var managementModel: AppManagementModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isXCTestHost else { return }
        NSApp.setActivationPolicy(.accessory) // 双保险,Info.plist 已设 LSUIElement

        // S2 装配:规则存储 → 内存快照盒 → 引擎(annotated tap + 目标解析)。
        // 引擎读快照盒而非 RuleStore,避免回调与文件保存竞争同一把锁(见 RuleSnapshotBox)。
        let store = RuleStore(
            settingsURL: RuleStore.defaultSettingsURL()
                ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("wheelflip-fallback-rules.json"),
            legacyDefaults: .standard
        )
        let rules = RuleSnapshotBox()
        engine = FlipEngine(resolver: AppIdentityResolver(), rules: rules)

        appState = AppState(
            engine: engine,
            rules: rules,
            store: store,
            isTrusted: { FlipEngine.isTrusted(prompt: false) },
            loginItems: LoginItemManager(),
            legacyCLIDetected: LegacyCLIDetector.isPresent()
        )
        // 事件回调与故障上报在 tap 的 run loop(主线程)上,可直接喂给 @Published。
        engine.onEvent = { [weak self] outcome in
            self?.appState.noteEngineEvent(outcome)
        }
        engine.onFailure = { [weak self] reason in
            self?.appState.noteEngineFailure(reason)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)

        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MainView(appState: appState, icons: nil, actions: makePanelActions())
        )

        cancellable = appState.$phase.sink { [weak self] phase in
            self?.syncUI(for: phase)
        }
        syncUI(for: appState.phase)

        setupCatalog(rules: rules)

        // F10:重开检查的结论回显——重开后仍无权限时给出明确结果,并重新打开面板。
        if CommandLine.arguments.contains("--permission-recheck"),
           appState.phase == .onboarding {
            appState.notePermissionRecheckStillDenied()
            DispatchQueue.main.async { [weak self] in
                self?.togglePopover()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !Self.isXCTestHost else { return }
        // 观察者注册在 NSWorkspace 的通知中心,必须从同一个中心移除
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers.removeAll()
        refreshDebounce?.cancel()
        directoryWatchers.forEach { $0.cancel() } // 释放文件描述符(§5.2)
        directoryWatchers.removeAll()
        managementWindow?.orderOut(nil)
        catalog = nil // 后台队列由 ARC 收尾;观察者已移除,无新刷新
    }

    // MARK: 面板动作装配

    private func makePanelActions() -> PanelActions {
        PanelActions(
            openManagement: { [weak self] in
                self?.popover.performClose(nil)
                self?.showManagementWindow()
            },
            quit: { [weak self] in self?.quit() },
            showAbout: { [weak self] in self?.showAbout() },
            openAccessibilitySettings: { [weak self] in self?.openAccessibilitySettings() },
            openLoginItemSettings: { [weak self] in self?.openLoginItemSettings() },
            revealSelfInFinder: { [weak self] in self?.revealSelfInFinder() },
            revealRulesBackup: { [weak self] in self?.revealRulesBackup() },
            relaunchForPermissionCheck: { [weak self] in self?.relaunchForPermissionCheck() }
        )
    }

    // MARK: 应用目录(S3)

    /// 装配多来源目录并接上运行/挂载/唤醒事件(§5.1 来源 3/5)。
    /// 首轮在后台完成,不阻塞已知目标的规则匹配(§5.2)。
    private func setupCatalog(rules box: RuleSnapshotBox) {
        let manualURL = ManualAppStore.defaultFileURL()
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("wheelflip-manual-apps.json")
        let manualStore = ManualAppStore(fileURL: manualURL)
        manualApps = manualStore

        var roots: [(root: String, lister: AppCatalog.DirectoryLister)] = [
            ("/Applications", DirectoryScanner.scan),
            ("/System/Applications", DirectoryScanner.scan),
        ]
        if let home = Self.realHomeDirectory() {
            // 真实用户主目录(S0:getpwuid 可得;urls(.applicationDirectory) 在沙盒解析到容器,不可用)。
            // 真实 ~/Applications 沙盒内不可读 → 来源记 failed(不可确认),不是空。
            roots.append((home + "/Applications", DirectoryScanner.scan))
        }

        let iconProvider = IconProvider()
        self.iconProvider = iconProvider
        self.rulesBox = box

        // S4:管理窗口模型(目录快照在主线程喂入;请求重扫走防抖入口)
        let model = AppManagementModel(
            appState: appState, manualApps: manualStore, icons: iconProvider,
            requestCatalogRefresh: { [weak self] in self?.scheduleCatalogRefresh() }
        )
        managementModel = model
        if let hosting = popover.contentViewController as? NSHostingController<MainView> {
            hosting.rootView = MainView(appState: appState, icons: iconProvider, actions: makePanelActions())
        }

        // 手工项路径的探测包在安全作用域内(书签授权),其余走默认探针。
        let baseProbe = AppCatalog.defaultPathProber()
        let scopedProbe: AppCatalog.PathProber = { path in
            if let entry = manualStore.entryForPath(path) {
                return manualStore.withAccess(for: entry) { _ in baseProbe(path) }
            }
            return baseProbe(path)
        }

        let newCatalog = AppCatalog(
            directoryRoots: roots,
            spotlightProvider: SpotlightScanner().queryApplications,
            runningAppsProvider: {
                NSWorkspace.shared.runningApplications.compactMap { app in
                    guard let bundleID = app.bundleIdentifier,
                          let url = app.bundleURL,
                          app.activationPolicy != .prohibited else { return nil }
                    return FoundApp(bundleID: bundleID,
                                    displayName: app.localizedName ?? url.deletingPathExtension().lastPathComponent,
                                    appPath: url.path,
                                    source: .runningApps,
                                    pid: app.processIdentifier)
                }
            },
            manualAppsProvider: {
                manualStore.entries.map {
                    let name = URL(fileURLWithPath: $0.appPath).deletingPathExtension().lastPathComponent
                    return FoundApp(bundleID: $0.bundleID, displayName: name,
                                    appPath: $0.appPath, source: .manual)
                }
            },
            probePath: scopedProbe
        )
        catalog = newCatalog

        // 每轮刷新后的卸载判定;清理改动落盘后必须重发布内存快照盒,
        // 否则引擎继续按已删除的覆盖翻转(对抗式审查证实)。
        let store = appState.store
        let executor = CleanupExecutor(store: store, manualApps: manualStore, icons: iconProvider)
        newCatalog.onRefresh = { [weak self] snapshot in
            guard let self else { return }
            guard let currentRules = store.settings else {
                self.publishSnapshotToUI(snapshot)
                return
            }
            let actions = AppRuleReconciler.evaluate(catalog: snapshot, rules: currentRules, now: Date())
            _ = executor.apply(actions, catalog: snapshot)
            self.rulesBox?.publish(store.settings)
            self.publishSnapshotToUI(snapshot)
        }

        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier, let url = app.bundleURL else { return }
            self?.catalog?.addRunningApp(FoundApp(
                bundleID: bundleID,
                displayName: app.localizedName ?? url.deletingPathExtension().lastPathComponent,
                appPath: url.path, source: .runningApps, pid: app.processIdentifier
            ))
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.catalog?.removeRunningPID(app.processIdentifier)
        })
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didWakeNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.scheduleCatalogRefresh()
            })
        }

        // §5.2:可访问目录使用文件变化通知,合并短时间的变化后重扫。
        // vnode 监听只覆盖根目录本身(非递归);深层子目录的变化由挂载/唤醒/
        // 运行补录兜底——记录为已知边界。
        for (root, _) in roots {
            let watcher = Self.makeDirectoryWatcher(path: root) { [weak self] in
                self?.scheduleCatalogRefresh()
            }
            if let watcher {
                directoryWatchers.append(watcher)
            }
        }

        newCatalog.refresh()
    }

    /// 目录快照分发到 UI(主线程):面板展示副本 + 管理窗口模型。
    private func publishSnapshotToUI(_ snapshot: CatalogSnapshot) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.appState.noteCatalogSnapshot(snapshot)
            self.managementModel?.reload(from: snapshot)
        }
    }

    /// 打开(或复用)唯一的应用规则窗口(§6.1:即时保存,Cmd+W/关闭按钮关闭)。
    private func showManagementWindow() {
        popover.performClose(nil)
        guard let model = managementModel else { return }
        if let window = managementWindow {
            window.makeKeyAndOrderFront(nil)
        } else {
            let hosting = NSHostingController(rootView: AppManagementView(model: model))
            let window = NSWindow(contentViewController: hosting)
            window.title = "WheelFlip · 应用规则"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false // 复用,不销毁
            window.contentMinSize = NSSize(width: 680, height: 420)
            window.setContentSize(NSSize(width: 760, height: 520))
            window.center()
            managementWindow = window
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        scheduleCatalogRefresh() // 打开管理窗口触发补充复核(§5.1 来源 5)
    }

    /// 合并 2 秒内的目录变化/挂载/唤醒触发,再做一轮全来源重扫(§5.2)。
    private func scheduleCatalogRefresh() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshDebounce?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.catalog?.refresh()
            }
            self.refreshDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
        }
    }

    /// 根目录 vnode 监听:目录内容变化(增删改条目)时触发一次防抖重扫。
    private static func makeDirectoryWatcher(path: String, onChange: @escaping () -> Void) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .attrib], queue: DispatchQueue.main
        )
        source.setEventHandler { onChange() }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    /// getpwuid 拿真实主目录;失败返回 nil(该来源干脆不注册)。
    static func realHomeDirectory() -> String? {
        guard let pw = getpwuid(getuid()) else { return nil }
        return String(cString: pw.pointee.pw_dir)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !Self.isXCTestHost else { return true }
        // F09:所有状态都进入同一个面板;权限引导由面板内入口打开。
        togglePopover()
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    // MARK: 状态栏图标(§4.4:图标+tooltip+无障碍名称同步完整状态)

    private func syncUI(for phase: AppPhase) {
        let presentation = ServicePresentation.present(phase)
        let image = NSImage(systemSymbolName: presentation.symbolName,
                            accessibilityDescription: presentation.statusDescription)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = presentation.statusDescription
    }

    @objc private func statusItemClicked() {
        // F09:点击始终打开同一种面板;图标不再因状态变成另一种导航方式(§4.4)。
        togglePopover()
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // §4.1:在 show 与 activate 前固定最近一次外部滚动目标(只固定编辑对象)
            appState.pinPanelTarget()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: 系统入口与重开流程(§5.4)

    private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    private func openLoginItemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    /// 定位正在运行的这一份副本(F10/E9:多副本授权问题的应对入口)。
    private func revealSelfInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    /// 修复流程:在 Finder 中显示损坏备份文件。
    private func revealRulesBackup() {
        NSWorkspace.shared.activateFileViewerSelecting([appState.store.backupURL])
    }

    /// 重新打开并检查(§5.4 第 3 步):旧进程退出后由子 shell 拉起新实例,
    /// --permission-recheck 让新实例回显检查结论。沙盒内派生系统 shell 可行;
    /// 失败时给出手动指引(F10:不允许无反馈的静默失败)。
    private func relaunchForPermissionCheck() {
        do {
            let process = PermissionRelauncher.makeProcess(
                bundleURL: Bundle.main.bundleURL,
                parentPID: ProcessInfo.processInfo.processIdentifier
            )
            try process.run()
        } catch {
            appState.noteRelaunchUnavailable(error.localizedDescription)
            return
        }
        popover.performClose(nil)
        NSApp.terminate(nil)
    }

    private func showAbout() {
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    private func quit() {
        appState.quit()
        NSApp.terminate(nil)
    }
}
