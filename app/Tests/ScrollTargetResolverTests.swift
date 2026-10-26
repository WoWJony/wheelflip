import XCTest
@testable import WheelFlip

/// §3.3 目标边界 + §7.4 有界快速路线:PID→身份、helper 归属、缓存与失效。
final class ScrollTargetResolverTests: XCTestCase {
    private var pathCalls = 0
    private var bundleReads: [String: Int] = [:]

    private func makeResolver(
        paths: [pid_t: String] = [:],
        bundleIDs: [String: String] = [:],
        seeds: [AppIdentityResolver.RunningAppSeed] = []
    ) -> AppIdentityResolver {
        pathCalls = 0
        bundleReads = [:]
        return AppIdentityResolver(
            pathForPID: { [paths] pid in
                self.pathCalls += 1
                return paths[pid]
            },
            bundleIDForAppPath: { [bundleIDs] path in
                self.bundleReads[path, default: 0] += 1
                return bundleIDs[path]
            },
            seeds: seeds,
            observeTerminations: false
        )
    }

    // MARK: 身份解析

    func testDirectAppProcessResolvesToHostBundle() {
        let resolver = makeResolver(
            paths: [100: "/Applications/Warp.app/Contents/MacOS/Warp"],
            bundleIDs: ["/Applications/Warp.app": "dev.warp.Warp-Stable"]
        )
        XCTAssertEqual(
            resolver.resolve(targetPID: 100),
            .identified(AppIdentity(bundleID: "dev.warp.Warp-Stable",
                                    appPath: "/Applications/Warp.app",
                                    viaHelper: false))
        )
    }

    func testAppexHelperAttributedToHostApp() {
        // S0 实测样本形态:System Settings 的 GeneralSettings.appex
        let resolver = makeResolver(
            paths: [200: "/System/Applications/System Settings.app/Contents/PlugIns/GeneralSettings.appex/Contents/MacOS/GeneralSettings"],
            bundleIDs: ["/System/Applications/System Settings.app": "com.apple.systempreferences"]
        )
        let result = resolver.resolve(targetPID: 200)
        guard case .identified(let identity) = result else {
            return XCTFail("应识别为宿主 App,实际 \(result)")
        }
        XCTAssertEqual(identity.bundleID, "com.apple.systempreferences")
        XCTAssertTrue(identity.viaHelper, "appex helper 应标记归属宿主")
    }

    func testFrameworkHelperAttributedToHostApp() {
        let resolver = makeResolver(
            paths: [300: "/Applications/Rhino.app/Contents/Frameworks/RhinoCore.framework/Versions/A/Helpers/worker"],
            bundleIDs: ["/Applications/Rhino.app": "com.mcneel.rhinoceros.8"]
        )
        let result = resolver.resolve(targetPID: 300)
        guard case .identified(let identity) = result else {
            return XCTFail("framework 内 helper 应归属宿主,实际 \(result)")
        }
        XCTAssertEqual(identity.bundleID, "com.mcneel.rhinoceros.8")
        XCTAssertTrue(identity.viaHelper)
    }

    func testOutermostAppWinsOverNestedAppBundle() {
        // .app 内再嵌 .app:归最外层(同一安装副本一条规则)
        let resolver = makeResolver(
            paths: [400: "/Applications/Outer.app/Contents/Library/Inner.app/Contents/MacOS/inner"],
            bundleIDs: ["/Applications/Outer.app": "com.example.outer"]
        )
        guard case .identified(let identity) = resolver.resolve(targetPID: 400) else {
            return XCTFail("应识别最外层 .app")
        }
        XCTAssertEqual(identity.appPath, "/Applications/Outer.app")
    }

    func testCommandLineProcessWithoutAppBundleIsUnresolvable() {
        let resolver = makeResolver(paths: [500: "/usr/bin/python3"])
        XCTAssertEqual(resolver.resolve(targetPID: 500), .unresolvable("no-app-bundle"))
    }

    func testDeadPIDIsUnresolvable() {
        let resolver = makeResolver(paths: [:]) // pathForPID → nil
        XCTAssertEqual(resolver.resolve(targetPID: 600), .unresolvable("pid-path-unavailable"))
    }

    func testNonPositivePIDIsUnresolvable() {
        let resolver = makeResolver()
        XCTAssertEqual(resolver.resolve(targetPID: 0), .unresolvable("target-pid-missing"))
        XCTAssertEqual(resolver.resolve(targetPID: -5), .unresolvable("target-pid-missing"))
    }

    func testEmptyBundleIDFromReaderIsUnresolvable() {
        let resolver = makeResolver(
            paths: [700: "/Applications/Weird.app/Contents/MacOS/Weird"],
            bundleIDs: ["/Applications/Weird.app": ""]
        )
        XCTAssertEqual(resolver.resolve(targetPID: 700), .unresolvable("no-bundle-id"))
    }

    // MARK: 缓存与失效

    func testCacheHitAvoidsRepeatedLookups() {
        let resolver = makeResolver(
            paths: [100: "/Applications/Warp.app/Contents/MacOS/Warp"],
            bundleIDs: ["/Applications/Warp.app": "dev.warp.Warp-Stable"]
        )
        _ = resolver.resolve(targetPID: 100)
        _ = resolver.resolve(targetPID: 100)
        _ = resolver.resolve(targetPID: 100)
        XCTAssertEqual(pathCalls, 1, "缓存命中不应重复 proc_pidpath")
        XCTAssertEqual(bundleReads["/Applications/Warp.app"], 1, "Bundle 信息只读一次")
    }

    /// 瞬时读失败的自愈路径:失败按 appPath 负缓存(不逐事件重读),
    /// 但 prune 每 60s 复核一次,恢复可读后自动解除负缓存。
    func testBundleIDReadFailureRecoversViaPrune() {
        var bundleIDs: [String: String] = ["/Applications/Warp.app": "dev.warp.Warp-Stable"]
        pathCalls = 0
        let resolver = AppIdentityResolver(
            pathForPID: { _ in
                self.pathCalls += 1
                return "/Applications/Warp.app/Contents/MacOS/Warp"
            },
            bundleIDForAppPath: { path in
                bundleIDs[path] // 先空(模拟瞬时失败)后成功
            },
            seeds: [],
            observeTerminations: false
        )
        bundleIDs.removeAll()
        XCTAssertEqual(resolver.resolve(targetPID: 100), .unresolvable("no-bundle-id"))
        bundleIDs = ["/Applications/Warp.app": "dev.warp.Warp-Stable"]
        XCTAssertEqual(resolver.resolve(targetPID: 100), .unresolvable("no-bundle-id"),
                       "负缓存期间不逐事件重读")

        resolver.pruneDeadPIDs() // 复核发现可读 → 解除负缓存
        XCTAssertEqual(resolver.resolve(targetPID: 100), .identified(
            AppIdentity(bundleID: "dev.warp.Warp-Stable", appPath: "/Applications/Warp.app", viaHelper: false)
        ))
    }

    func testBundlePathCacheSharedAcrossPIDsOfSameApp() {
        let resolver = makeResolver(
            paths: [
                100: "/Applications/Warp.app/Contents/MacOS/Warp",
                101: "/Applications/Warp.app/Contents/MacOS/Warp"
            ],
            bundleIDs: ["/Applications/Warp.app": "dev.warp.Warp-Stable"]
        )
        _ = resolver.resolve(targetPID: 100)
        _ = resolver.resolve(targetPID: 101)
        XCTAssertEqual(bundleReads["/Applications/Warp.app"], 1, "同 .app 的多个 PID 共享 Bundle 信息缓存")
    }

    func testInvalidatePIDForcesReResolution() {
        let resolver = makeResolver(
            paths: [100: "/Applications/Warp.app/Contents/MacOS/Warp"],
            bundleIDs: ["/Applications/Warp.app": "dev.warp.Warp-Stable"]
        )
        _ = resolver.resolve(targetPID: 100)
        XCTAssertEqual(pathCalls, 1)
        resolver.invalidatePID(100)
        _ = resolver.resolve(targetPID: 100)
        XCTAssertEqual(pathCalls, 2, "进程退出失效后必须重新解析")
    }

    func testPruneRemovesDeadPIDs() {
        var paths: [pid_t: String] = [
            100: "/Applications/Warp.app/Contents/MacOS/Warp",
            200: "/Applications/Rhino.app/Contents/MacOS/Rhino"
        ]
        pathCalls = 0
        let resolver = AppIdentityResolver(
            pathForPID: { pid in
                self.pathCalls += 1
                return paths[pid]
            },
            bundleIDForAppPath: { _ in "com.example.any" },
            seeds: [],
            observeTerminations: false
        )
        _ = resolver.resolve(targetPID: 100)
        _ = resolver.resolve(targetPID: 200)
        XCTAssertEqual(pathCalls, 2)

        paths.removeValue(forKey: 100) // 100 退出(且退出通知丢失)
        resolver.pruneDeadPIDs()
        // 200 仍缓存命中(不查路径);100 已被清走 → 重新查路径
        pathCalls = 0
        _ = resolver.resolve(targetPID: 200)
        XCTAssertEqual(pathCalls, 0, "存活 PID 不受 prune 影响")
        _ = resolver.resolve(targetPID: 100)
        XCTAssertEqual(pathCalls, 1, "被 prune 的死 PID 不再有缓存")
    }

    /// §9.1「目标」行:PID 复用。退出通知丢失 + PID 被新 App 复用时,
    /// prune 比对缓存路径与当前可执行文件路径,发现不一致即作废旧身份。
    func testPruneDetectsPIDReuseByChangedExecutable() {
        var paths: [pid_t: String] = [
            100: "/Applications/Old.app/Contents/MacOS/Old",
        ]
        var bundleIDs: [String: String] = [
            "/Applications/Old.app": "com.example.old",
            "/Applications/New.app": "com.example.new",
        ]
        pathCalls = 0
        let resolver = AppIdentityResolver(
            pathForPID: { pid in
                self.pathCalls += 1
                return paths[pid]
            },
            bundleIDForAppPath: { path in
                self.bundleReads[path, default: 0] += 1
                return bundleIDs[path]
            },
            seeds: [],
            observeTerminations: false
        )
        guard case .identified(let first) = resolver.resolve(targetPID: 100) else {
            return XCTFail("首次解析应成功")
        }
        XCTAssertEqual(first.bundleID, "com.example.old")

        // PID 100 被另一个 App 复用(退出通知丢失)
        paths[100] = "/Applications/New.app/Contents/MacOS/New"
        resolver.pruneDeadPIDs()

        guard case .identified(let second) = resolver.resolve(targetPID: 100) else {
            return XCTFail("复用后应重新解析")
        }
        XCTAssertEqual(second.bundleID, "com.example.new", "不得沿用复用前的旧身份")
    }

    func testPruneDetectsReuseByCommandLineExecutable() {
        var paths: [pid_t: String] = [
            100: "/Applications/Old.app/Contents/MacOS/Old",
        ]
        pathCalls = 0
        let resolver = AppIdentityResolver(
            pathForPID: { pid in
                self.pathCalls += 1
                return paths[pid]
            },
            bundleIDForAppPath: { _ in "com.example.old" },
            seeds: [],
            observeTerminations: false
        )
        _ = resolver.resolve(targetPID: 100)

        paths[100] = "/usr/local/bin/node" // PID 复用为命令行进程
        resolver.pruneDeadPIDs()
        XCTAssertEqual(resolver.resolve(targetPID: 100), .unresolvable("no-app-bundle"),
                       "旧 App 身份必须作废,按新进程重新判定为命令行")
    }

    /// 负缓存:命令行进程(确定性 no-app-bundle)不逐事件重复 syscall。
    func testCommandLinePIDFailureIsCached() {
        let resolver = makeResolver(paths: [500: "/usr/bin/python3"])
        XCTAssertEqual(resolver.resolve(targetPID: 500), .unresolvable("no-app-bundle"))
        _ = resolver.resolve(targetPID: 500)
        _ = resolver.resolve(targetPID: 500)
        XCTAssertEqual(pathCalls, 1, "确定性 no-app-bundle 应负缓存,不逐事件重复查路径")

        resolver.invalidatePID(500)
        XCTAssertEqual(resolver.resolve(targetPID: 500), .unresolvable("no-app-bundle"))
        XCTAssertEqual(pathCalls, 2, "失效后允许重查")
    }

    /// 负缓存:沙盒不可读 .app 的 Bundle 读取失败按路径缓存,同因不重读。
    func testBundleIDFailureCachedByAppPath() {
        let resolver = makeResolver(
            paths: [
                100: "/Applications/Secret.app/Contents/MacOS/Secret",
                101: "/Applications/Secret.app/Contents/MacOS/Secret",
            ],
            bundleIDs: [:] // 全部读失败
        )
        XCTAssertEqual(resolver.resolve(targetPID: 100), .unresolvable("no-bundle-id"))
        XCTAssertEqual(resolver.resolve(targetPID: 101), .unresolvable("no-bundle-id"))
        XCTAssertEqual(bundleReads["/Applications/Secret.app"], 1, "同一路径读失败只读一次")
    }

    func testSeededRunningAppsResolveWithoutSyscall() {
        let resolver = makeResolver(seeds: [
            .init(pid: 900, bundleID: "dev.warp.Warp-Stable", appPath: "/Applications/Warp.app")
        ])
        XCTAssertEqual(
            resolver.resolve(targetPID: 900),
            .identified(AppIdentity(bundleID: "dev.warp.Warp-Stable",
                                    appPath: "/Applications/Warp.app",
                                    viaHelper: false))
        )
        XCTAssertEqual(pathCalls, 0, "NSRunningApplication 预热后首条滚动无需 syscall")
    }

    func testPIDCacheLimitClearsAll() {
        var paths: [pid_t: String] = [:]
        var bundleIDs: [String: String] = [:]
        for pid in pid_t(1)...pid_t(520) {
            let appPath = "/Applications/App\(pid).app"
            paths[pid] = appPath + "/Contents/MacOS/App\(pid)"
            bundleIDs[appPath] = "com.example.app\(pid)"
        }
        let resolver = makeResolver(paths: paths, bundleIDs: bundleIDs)
        _ = resolver.resolve(targetPID: 1)
        for pid in pid_t(2)...pid_t(520) {
            _ = resolver.resolve(targetPID: pid)
        }
        let before = pathCalls
        _ = resolver.resolve(targetPID: 1)
        XCTAssertEqual(pathCalls, before + 1, "缓存超限整体清空后,旧 PID 需重新解析")
    }

    // MARK: 纯函数:最外层 .app 回溯

    func testOutermostAppBundlePureCases() {
        XCTAssertEqual(
            AppIdentityResolver.outermostAppBundle(containing: "/Applications/Foo.app/Contents/MacOS/Foo"),
            "/Applications/Foo.app"
        )
        XCTAssertEqual(
            AppIdentityResolver.outermostAppBundle(containing: "/System/Applications/System Settings.app/Contents/PlugIns/G.appex/Contents/MacOS/G"),
            "/System/Applications/System Settings.app"
        )
        XCTAssertEqual(
            AppIdentityResolver.outermostAppBundle(containing: "/Applications/F.app/Contents/Frameworks/X.framework/Versions/A/Helpers/h"),
            "/Applications/F.app"
        )
        XCTAssertEqual(
            AppIdentityResolver.outermostAppBundle(containing: "/Applications/F.app/Contents/Library/Inner.app/Contents/MacOS/i"),
            "/Applications/F.app"
        )
        XCTAssertNil(AppIdentityResolver.outermostAppBundle(containing: "/usr/local/bin/node"))
        XCTAssertNil(AppIdentityResolver.outermostAppBundle(containing: "/Applications/NotAnApp/Contents/MacOS/x"))
        XCTAssertEqual(
            AppIdentityResolver.outermostAppBundle(containing: "/Root.app/Contents/MacOS/r"),
            "/Root.app"
        )
    }
}
