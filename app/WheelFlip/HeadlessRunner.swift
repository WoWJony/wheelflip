// Headless 测试驱动模式,专供开发期自动化闭环测试用,不面向最终用户。
// 用法(直接执行 .app 内二进制,不经 `open`,才能继承 stdout 给调用方看日志):
//   WheelFlip --headless-authcheck        一次性检查 AXIsProcessTrusted,打印 TRUSTED/UNTRUSTED,exit 0/1
//   WheelFlip --headless-authprompt       触发一次 AXIsProcessTrustedWithOptions(prompt:true)
//   WheelFlip --headless-run [--settings <path>|--use-default-settings]
//                                        启动 annotated 引擎常驻;SIGUSR1 切换 start/stop,
//                                        SIGTERM 清理后退出。默认使用临时规则(不触碰日常
//                                        配置,S2 任务要求);--settings 指定临时文件,
//                                        --use-default-settings 显式使用日常配置。
// 之所以不用 stdin 命令行协议: Bash 工具每次调用是独立 shell,不方便维持长连接管道;
// 信号是无状态的,每次 `kill -SIGNAL <pid>` 都是独立可脚本化的操作。

import Dispatch
import Foundation

enum HeadlessRunner {
    static func runAuthCheck() -> Never {
        let trusted = FlipEngine.isTrusted(prompt: false)
        print(trusted ? "TRUSTED" : "UNTRUSTED")
        exit(trusted ? 0 : 1)
    }

    static func runAuthPrompt() -> Never {
        _ = FlipEngine.isTrusted(prompt: true)
        let trusted = FlipEngine.isTrusted(prompt: false)
        print(trusted ? "TRUSTED" : "UNTRUSTED")
        exit(0)
    }

    /// headless 规则来源(对抗式审查修订:默认绝不触碰日常配置):
    /// - `--settings <path>`:显式临时文件 + scratch defaults(迁移判定从空开始);
    /// - `--use-default-settings`:显式要求真实日常配置(需要时才用);
    /// - 默认:scratch 临时文件(临时目录内,内容为全新安装默认值)。
    static func makeStore(arguments: [String] = CommandLine.arguments) -> (store: RuleStore, scope: String)? {
        let scratchSuiteName = "com.jonywu.WheelFlip.headless-scratch"
        func makeScratch(url: URL) -> RuleStore {
            let scratch = UserDefaults(suiteName: scratchSuiteName)!
            scratch.removePersistentDomain(forName: scratchSuiteName)
            return RuleStore(settingsURL: url, legacyDefaults: scratch)
        }
        if let index = arguments.firstIndex(of: "--settings"), index + 1 < arguments.count {
            return (makeScratch(url: URL(fileURLWithPath: arguments[index + 1])), "settings:" + arguments[index + 1])
        }
        if arguments.contains("--use-default-settings") {
            guard let defaultURL = RuleStore.defaultSettingsURL() else { return nil }
            return (RuleStore(settingsURL: defaultURL, legacyDefaults: .standard), "default")
        }
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wheelflip-headless-rules.json")
        return (makeScratch(url: tempURL), "temp")
    }

    static func run() -> Never {
        guard let (store, scope) = makeStore() else {
            print("START_FAIL: 无法定位默认设置路径")
            exit(1)
        }

        let rules = RuleSnapshotBox()
        let outcome = store.load()
        rules.publish(store.settings)
        print("SETTINGS: \(scope)")
        print("RULES: \(outcome)")

        let engine = FlipEngine(resolver: AppIdentityResolver(), rules: rules)
        engine.onEvent = { outcome in
            let source = outcome.source.map(describe) ?? "noRules"
            print("EVT flips=\(outcome.flipped ? 1 : 0) src=\(source) bundle=\(outcome.bundleID ?? "-")")
            fflush(stdout)
        }
        engine.onFailure = { reason in
            print("ENGINE_FAIL: \(reason)")
            fflush(stdout)
        }

        func status(_ tag: String) {
            let d = engine.diagnostics.snapshot()
            print("[\(tag)] pid=\(ProcessInfo.processInfo.processIdentifier) running=\(engine.isRunning) "
                + "discrete=\(d.discreteSeen) flipped=\(d.discreteFlipped) cont=\(d.continuousSeen) "
                + "override=\(d.appOverrideDecisions) default=\(d.globalDefaultDecisions) noRules=\(d.noRulesPassthrough) "
                + "unresolvable=\(d.unresolvableTargets) missingPID=\(d.missingTargetPIDs) "
                + "resolveMax=\(d.maxResolveMicros)µs avg=\(d.averageResolveMicros)µs "
                + "tapDisable=\(d.tapTimeoutDisables)t+\(d.tapUserInputDisables)u reenable=\(d.reenables) gaveUp=\(d.reenableGaveUps) "
                + "last=\(d.lastDiscrete.map { "\($0.bundleID ?? "-")/\($0.flipped ? "flip" : "pass")/\($0.resolveMicros)µs" } ?? "-")")
            fflush(stdout)
        }

        guard FlipEngine.isTrusted(prompt: false) else {
            print("UNTRUSTED")
            exit(1)
        }

        if let failure = engine.start() {
            print("START_FAIL: \(failure)")
            exit(1)
        }
        status("started")

        // DispatchSourceSignal 要求先把默认信号处理设为忽略,否则进程会被信号直接杀掉。
        signal(SIGUSR1, SIG_IGN)
        let toggleSource = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        toggleSource.setEventHandler {
            if engine.isRunning {
                engine.stop()
                status("stopped")
            } else {
                if let failure = engine.start() {
                    print("START_FAIL: \(failure)")
                } else {
                    status("restarted")
                }
            }
        }
        toggleSource.resume()

        signal(SIGTERM, SIG_IGN)
        let quitSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        quitSource.setEventHandler {
            engine.stop()
            status("quitting")
            exit(0)
        }
        quitSource.resume()

        RunLoop.main.run()
        fatalError("unreachable")
    }

    private static func describe(_ source: FlipDecisionSource) -> String {
        switch source {
        case .appOverride(.forceOn): return "overrideOn"
        case .appOverride(.forceOff): return "overrideOff"
        case .appOverride(.inherit): return "inherit"
        case .globalDefault: return "default"
        case .continuousPassthrough: return "continuous"
        }
    }
}
