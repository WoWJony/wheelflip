import Foundation

// 检测旧 CLI 版 LaunchAgent 是否还在,提示用户会双重翻转(见 docs/APP_PLAN.md §1.2)。
enum LegacyCLIDetector {
    static var defaultPlistPath: String {
        (("~/Library/LaunchAgents/com.jonywu.wheelflip.plist") as NSString).expandingTildeInPath
    }

    static func isPresent(path: String = LegacyCLIDetector.defaultPlistPath, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: path)
    }
}
