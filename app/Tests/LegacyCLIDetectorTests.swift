import XCTest
@testable import WheelFlip

final class LegacyCLIDetectorTests: XCTestCase {
    func testDetectsPresentFile() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".plist")
        FileManager.default.createFile(atPath: tmp.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: tmp) }

        XCTAssertTrue(LegacyCLIDetector.isPresent(path: tmp.path))
    }

    func testAbsentFileReturnsFalse() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".plist").path
        XCTAssertFalse(LegacyCLIDetector.isPresent(path: missing))
    }
}
