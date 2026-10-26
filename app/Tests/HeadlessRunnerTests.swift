import XCTest
@testable import WheelFlip

/// S2 任务「诊断支持临时设置位置,不改动日常用户配置」的装配级锁定(对抗式审查修订):
/// 默认与 --settings 都走 scratch 迁移基线;只有显式 --use-default-settings 才碰日常配置。
/// RuleStore 不暴露 settingsURL,断言以行为(load 结果、文件落点)为准。
final class HeadlessRunnerTests: XCTestCase {
    private var dailyURLExisted: Bool = false

    override func setUp() {
        super.setUp()
        dailyURLExisted = RuleStore.defaultSettingsURL().map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? false
    }

    override func tearDown() {
        // 任何测试都不应创建/改写日常规则文件
        if let url = RuleStore.defaultSettingsURL() {
            XCTAssertEqual(FileManager.default.fileExists(atPath: url.path), dailyURLExisted,
                           "headless 装配不得触碰日常规则文件")
        }
        super.tearDown()
    }

    func testDefaultRunUsesTempScratchFreshInstall() throws {
        // 清掉上一次运行留下的临时规则,保证 freshInstall 语义可重复验证
        let tempRules = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wheelflip-headless-rules.json")
        try? FileManager.default.removeItem(at: tempRules)
        let (store, scope) = try XCTUnwrap(HeadlessRunner.makeStore(arguments: ["WheelFlip", "--headless-run"]))
        XCTAssertEqual(scope, "temp")
        XCTAssertEqual(store.load(), .freshInstall, "默认走临时文件,scratch 迁移基线为空")
        XCTAssertEqual(store.settings?.defaultFlip, true)
    }

    func testSettingsFlagUsesGivenPath() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("wheelflip-headless-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temp) }
        let (store, scope) = try XCTUnwrap(
            HeadlessRunner.makeStore(arguments: ["WheelFlip", "--headless-run", "--settings", temp.path])
        )
        XCTAssertTrue(scope.hasPrefix("settings:"), scope)
        XCTAssertEqual(store.load(), .freshInstall)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.path), "规则落在传入路径")
    }

    func testUseDefaultSettingsFlagIsExplicitOptIn() throws {
        let (_, scope) = try XCTUnwrap(
            HeadlessRunner.makeStore(arguments: ["WheelFlip", "--headless-run", "--use-default-settings"])
        )
        XCTAssertEqual(scope, "default")
        // 不执行 load:显式 opt-in 的语义由 scope 标识,测试本身绝不写日常文件
    }
}
