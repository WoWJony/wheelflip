// 手写入口(不用 @main),以便在 SwiftUI App 启动前分流到 headless/UI fixture 测试模式。

let args = CommandLine.arguments
if args.contains("--headless-authcheck") {
    HeadlessRunner.runAuthCheck()
} else if args.contains("--headless-authprompt") {
    HeadlessRunner.runAuthPrompt()
} else if args.contains("--headless-run") {
    HeadlessRunner.run()
} else if args.contains("--ui-fixture") {
    let scenario = args.enumerated().first { $0.element == "--scenario" && args.indices.contains($0.offset + 1) }
        .map { args[$0.offset + 1] } ?? "running"
    FixtureRunner.run(scenario: scenario)
} else {
    WheelFlipSpikeApp.main()
}
