import XCTest
@testable import WheelFlip

/// Spotlight 来源的真机回归:对抗式审查实证"NSMetadataQuery 在无 run loop 的 GCD
/// 队列上 start,通知永不投递 → 每轮 2s 超时"。修复后 start/stop 派回主队列。
/// 本测试从后台队列调用(复现生产调用点),断言不再超时抛错。
final class SpotlightScannerTests: XCTestCase {
    func testQueryFromBackgroundQueueCompletesWithoutTimeout() {
        let done = expectation(description: "spotlight query")
        var result: Result<[FoundApp], Error>?
        let box = NSLock()
        DispatchQueue(label: "spotlight-test", qos: .utility).async {
            let scanner = SpotlightScanner(timeout: 5)
            do {
                let apps = try scanner.queryApplications()
                box.lock(); result = .success(apps); box.unlock()
            } catch {
                box.lock(); result = .failure(error); box.unlock()
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 15)

        switch result {
        case .success(let apps):
            XCTAssertTrue(apps.allSatisfy { SpotlightScanner.isListable($0.appPath) },
                          "Spotlight 侧过滤(嵌套 helper/垃圾桶)生效")
        case .failure(let error):
            XCTFail("Spotlight 查询不得超时失败(run loop 修复回归):\(error)")
        case nil:
            XCTFail("查询未完成")
        }
    }

    func testIsListableFilters() {
        XCTAssertTrue(SpotlightScanner.isListable("/Applications/Warp.app"))
        XCTAssertTrue(SpotlightScanner.isListable("/Volumes/Ext/User Tool.app")) // 外置盘真装应用允许补录
        XCTAssertFalse(SpotlightScanner.isListable("/Applications/Big.app/Contents/Helpers/Inner.app"),
                       "包内嵌套 .app 不是独立应用")
        XCTAssertFalse(SpotlightScanner.isListable("/Users/x/.Trash/Deleted.app"))
        XCTAssertFalse(SpotlightScanner.isListable("/Volumes/DMG/.Trashes/1/Installer.app"))
    }
}
