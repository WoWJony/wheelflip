import XCTest
@testable import WheelFlip

/// S0 隔离要求:测试宿主必须能识别自己,保证 AppDelegate 不在宿主里组装真实引擎/登录项。
final class TestHostIsolationTests: XCTestCase {
    func testXCTestHostIsDetected() {
        XCTAssertTrue(AppDelegate.isXCTestHost, "测试宿主进程必须被识别,否则宿主会启动真实 tap 与登录项")
    }
}
