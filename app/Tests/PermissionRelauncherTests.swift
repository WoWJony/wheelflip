import Foundation
import XCTest
@testable import WheelFlip

final class PermissionRelauncherTests: XCTestCase {
    func testBundlePathIsPassedLiterallyWithoutExecutingShellSyntax() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wheelflip-relaunch-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("must-not-exist")
        let paths = [
            "/Applications/WheelFlip.app",
            "/Applications/空格 ' \" ; `echo unexpected` %s \\ newline\n.app",
            "/Applications/WheelFlip-$(touch \(marker.path)).app",
        ]

        for path in paths {
            let output = Pipe()
            let process = PermissionRelauncher.makeProcess(
                bundleURL: URL(fileURLWithPath: path),
                parentPID: Int32.max,
                launchCommand: ["/usr/bin/printf", "%s\\0"]
            )
            process.standardOutput = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            XCTAssertEqual(process.terminationStatus, 0)
            let arguments = String(decoding: data, as: UTF8.self)
                .split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
            XCTAssertEqual(arguments, [path, "--args", "--permission-recheck"])
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
    }
}
