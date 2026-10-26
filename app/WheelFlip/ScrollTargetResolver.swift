// S0 选定路线落地:annotated tap 的 eventTargetUnixProcessID → App 身份(计划 §3.3、§7.2)。
//
// 职责与边界:
// - 只做"PID → Bundle ID"的运行时定位,不做目录发现、不落盘(目录归 S3 AppCatalog)。
// - helper/XPC/渲染进程按"可执行文件所在的最外层 .app 包"归属宿主(S0 实测:
//   System Settings 的 GeneralSettings.appex 目标 PID 路径回溯到宿主 .app)。
// - 回调内使用:缓存命中 O(1);未命中走有界快速路线(proc_pidpath + 目录回溯 +
//   一次 Info.plist 读取),失败立即返回 unresolvable,不抛不挂(§7.4)。
// - PID 失效:NSWorkspace 退出通知 + 定期 prune(处理通知丢失与 PID 复用残留)。
//   通知间隙内的 PID 复用是已知残留窗口,由 prune 兜底,记录于 S2 执行记录。

import AppKit
import Foundation

/// 成功识别的 App 身份。
struct AppIdentity: Equatable {
    let bundleID: String
    /// 最外层 .app 包路径(运行时定位用,不作为规则键)。
    let appPath: String
    /// 目标进程是否为包内 helper(归属宿主)。
    let viaHelper: Bool
}

enum TargetResolution: Equatable {
    case identified(AppIdentity)
    /// 附带原因供诊断计数;调用方按全局默认放行,绝不借用上一个 App 的覆盖(§3.3)。
    case unresolvable(String)
}

protocol ScrollTargetResolving: AnyObject {
    /// 事件回调内的快速路径;必须有界返回。
    func resolve(targetPID: pid_t) -> TargetResolution
    /// 进程退出等失效通知入口。
    func invalidatePID(_ pid: pid_t)
    /// 兜底清理:通知丢失/PID 复用残留;由引擎低频定时调用。
    func pruneDeadPIDs()
}

/// 运行 App 身份解析:PID 缓存 + NSRunningApplications 预热 + .app 包回溯。
/// 路径获取与 Bundle 元信息读取均为注入点,单元测试不依赖真实进程。
final class AppIdentityResolver: ScrollTargetResolving {
    /// NSRunningApplication 里可用的最小信息。
    struct RunningAppSeed: Equatable {
        let pid: pid_t
        let bundleID: String
        let appPath: String
    }

    /// 缓存上限:到达即整体清空重建(有界且实现最小;命中损失只影响首次解析耗时)。
    private static let pidCacheLimit = 512

    private let pathForPID: (pid_t) -> String?
    private let bundleIDForAppPath: (String) -> String?
    private let lock = NSLock()
    private var pidCache: [pid_t: AppIdentity] = [:]
    private var bundleIDCache: [String: String] = [:]
    /// 确定性失败的负缓存(对抗式审查修订):
    /// - noAppBundlePIDs:进程可执行文件不在任何 .app 内(命令行进程,路径稳定);
    /// - bundleIDFailures:某 .app 路径读不出 Bundle ID(沙盒不可读位置,同样确定)。
    /// 不缓存瞬时的 pid-path-unavailable(进程退出瞬间 proc_pidpath 竞态,可能自愈)。
    /// 负结果若不缓存,长期 unresolvable 的目标会让每条滚动事件都重复 syscall+读盘。
    private var noAppBundlePIDs: Set<pid_t> = []
    private var bundleIDFailures: Set<String> = []
    private var terminationObserver: NSObjectProtocol?

    init(
        pathForPID: @escaping (pid_t) -> String? = AppIdentityResolver.procPIDPath,
        bundleIDForAppPath: @escaping (String) -> String? = AppIdentityResolver.readBundleID,
        seeds: [RunningAppSeed] = AppIdentityResolver.workspaceSeeds(),
        observeTerminations: Bool = true
    ) {
        self.pathForPID = pathForPID
        self.bundleIDForAppPath = bundleIDForAppPath
        for seed in seeds where !seed.bundleID.isEmpty && !seed.appPath.isEmpty {
            let identity = AppIdentity(bundleID: seed.bundleID, appPath: seed.appPath, viaHelper: false)
            pidCache[seed.pid] = identity
            bundleIDCache[seed.appPath] = seed.bundleID
        }
        if observeTerminations {
            terminationObserver = NotificationCenter.default.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: nil
            ) { [weak self] note in
                guard let pid = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                else { return }
                self?.invalidatePID(pid.processIdentifier)
            }
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    func resolve(targetPID: pid_t) -> TargetResolution {
        guard targetPID > 0 else { return .unresolvable("target-pid-missing") }

        lock.lock()
        if let cached = pidCache[targetPID] {
            lock.unlock()
            return .identified(cached)
        }
        let cliPID = noAppBundlePIDs.contains(targetPID)
        lock.unlock()
        if cliPID { return .unresolvable("no-app-bundle") }

        // 未命中的有界快速路线:一次 syscall + 目录回溯 +(必要时)一次 Info.plist 读。
        guard let exePath = pathForPID(targetPID), !exePath.isEmpty else {
            return .unresolvable("pid-path-unavailable") // 瞬时竞态,不缓存
        }
        guard let appPath = AppIdentityResolver.outermostAppBundle(containing: exePath) else {
            // 命令行进程:确定性结果,负缓存防止逐事件重复 syscall(对抗式审查修订)。
            lock.lock()
            if pidCache.count >= Self.pidCacheLimit {
                pidCache.removeAll()
                noAppBundlePIDs.removeAll()
            }
            noAppBundlePIDs.insert(targetPID)
            lock.unlock()
            return .unresolvable("no-app-bundle")
        }

        lock.lock()
        let cachedID = bundleIDCache[appPath]
        let appPathFailed = bundleIDFailures.contains(appPath)
        lock.unlock()
        if let cachedID {
            return cacheAndReturn(pid: targetPID, exePath: exePath, appPath: appPath, bundleID: cachedID)
        }
        if appPathFailed {
            // 沙盒不可读位置:读失败是确定性的,按路径负缓存(同因不重读)。
            return .unresolvable("no-bundle-id")
        }
        guard let bundleID = bundleIDForAppPath(appPath), !bundleID.isEmpty else {
            lock.lock()
            bundleIDFailures.insert(appPath)
            lock.unlock()
            return .unresolvable("no-bundle-id")
        }
        return cacheAndReturn(pid: targetPID, exePath: exePath, appPath: appPath, bundleID: bundleID)
    }

    func invalidatePID(_ pid: pid_t) {
        lock.lock()
        pidCache.removeValue(forKey: pid)
        noAppBundlePIDs.remove(pid)
        lock.unlock()
    }

    func pruneDeadPIDs() {
        lock.lock()
        let pids = Array(pidCache.keys)
        lock.unlock()
        for pid in pids {
            // proc_pidpath 对不存在的 PID 返回 0 → 判死并移除(通知丢失的兜底)。
            guard let exePath = pathForPID(pid), !exePath.isEmpty else {
                invalidatePID(pid)
                continue
            }
            // PID 复用检测(对抗式审查修订):PID 活着但可执行文件已换 → 旧身份过期。
            // 复用常伴随退出通知,但通知可能丢失;prune 是最后防线。
            if let appPath = AppIdentityResolver.outermostAppBundle(containing: exePath) {
                lock.lock()
                let cachedPath = pidCache[pid]?.appPath
                lock.unlock()
                if let cachedPath, cachedPath != appPath {
                    invalidatePID(pid)
                }
            } else {
                // 进程换成了无 .app 的命令行 → 旧身份同样过期。
                invalidatePID(pid)
            }
        }

        // 负缓存的 .app 路径低频复核:瞬时读失败(更新替换中等)可自愈,
        // 每条滚动事件仍不重复读盘。
        lock.lock()
        let failedPaths = Array(bundleIDFailures)
        lock.unlock()
        for path in failedPaths where bundleIDForAppPath(path) != nil {
            lock.lock()
            bundleIDFailures.remove(path)
            lock.unlock()
        }
    }

    private func cacheAndReturn(pid: pid_t, exePath: String, appPath: String, bundleID: String) -> TargetResolution {
        // helper 判定仅供诊断展示;主二进制在 .app/Contents/MacOS/ 下,其余(appex/
        // framework/XPC 内)均视为归属宿主的 helper。
        let viaHelper = !exePath.hasPrefix(appPath + "/Contents/MacOS/")
        let identity = AppIdentity(bundleID: bundleID, appPath: appPath, viaHelper: viaHelper)
        lock.lock()
        if pidCache.count >= Self.pidCacheLimit {
            pidCache.removeAll()
            noAppBundlePIDs.removeAll()
            bundleIDCache.removeAll()
            bundleIDFailures.removeAll()
        }
        pidCache[pid] = identity
        bundleIDCache[appPath] = bundleID
        lock.unlock()
        return .identified(identity)
    }

    /// 找包含该可执行文件的最外层 .app 包(如 …/Foo.app/Contents/PlugIns/X.appex/… → Foo.app)。
    /// 找不到(命令行进程、裸二进制)返回 nil。
    static func outermostAppBundle(containing exePath: String) -> String? {
        let components = exePath.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return nil }
        for (index, component) in components.enumerated() where component.hasSuffix(".app") {
            return "/" + components[0...index].joined(separator: "/")
        }
        return nil
    }

    // MARK: - 默认注入实现

    static func procPIDPath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) + 1)
        let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard count > 0 else { return nil }
        buffer[Int(count)] = 0
        return String(cString: buffer)
    }

    /// 只读 Info.plist,不执行任何应用二进制(§5.2)。失败返回 nil(不缓存)。
    static func readBundleID(_ appPath: String) -> String? {
        Bundle(url: URL(fileURLWithPath: appPath))?.bundleIdentifier
    }

    private static func workspaceSeeds() -> [RunningAppSeed] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.processIdentifier > 0,
                  let bundleID = app.bundleIdentifier, !bundleID.isEmpty,
                  let bundleURL = app.bundleURL else { return nil }
            return RunningAppSeed(pid: app.processIdentifier, bundleID: bundleID, appPath: bundleURL.path)
        }
    }
}
