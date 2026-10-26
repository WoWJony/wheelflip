// 目录来源扫描(计划 §5.1 来源 1):/Applications、/System/Applications 等可读根。
// S0 实测:真实 ~/Applications 与外置卷在沙盒内不可读——这类根会以 SourceState.failed
// 呈现(不可确认),绝不当作"没有应用"。
//
// 遍历纪律(§5.1/§5.2):遇到 .app 包停止向内递归(包内 helper/appex 不是独立条目);
// 不整盘遍历;不执行任何应用二进制;读取 Bundle 元信息只用 Bundle(url:)。

import Foundation

enum DirectoryScanner {
    /// 子目录递归上限:/Applications 下再分目录的场景足够,防止异常深层结构拖垮扫描。
    static let maxDepth = 2

    /// 扫描一个根目录,返回其中所有 .app 副本。
    static func scan(root: String) throws -> [FoundApp] {
        var results: [FoundApp] = []
        try walk(directory: root, depth: 0, into: &results)
        return results
    }

    private static func walk(directory: String, depth: Int, into results: inout [FoundApp]) throws {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(atPath: directory) else {
            // contentsOfDirectory 双态:目录不存在 vs 无权限。区分它们:
            if fm.fileExists(atPath: directory) {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
                              userInfo: [NSFilePathErrorKey: directory])
            }
            return // 根本身不存在:空结果(比如可选的 ~/Applications 尚未创建)
        }
        for child in children.sorted() {
            let path = directory + "/" + child
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }
            if isExcluded(path: path, name: child) { continue }
            if child.hasSuffix(".app") {
                if let app = makeFoundApp(appPath: path) {
                    results.append(app)
                }
                // 遇 .app 停止向内递归(§5.1:包内 helper 不属于目录层)
            } else if depth < maxDepth {
                try walk(directory: path, depth: depth + 1, into: &results)
            }
        }
    }

    /// 过滤垃圾桶与隐藏目录(§5.1);安装镜像挂载默认不在扫描根内。
    private static func isExcluded(path: String, name: String) -> Bool {
        if name.hasPrefix(".") { return true }              // .Trash 与隐藏目录
        if path.contains("/.Trash/") { return true }
        if path.contains("/.DocumentRevisions-V100/") { return true } // 版本库备份副本
        return false
    }

    /// 从 .app 包读身份与名称;读不出 Bundle ID 的包(损坏/异常)跳过,
    /// 不按显示名建规则(§5.3"无法稳定标识的应用只按默认运行")。
    static func makeFoundApp(appPath: String) -> FoundApp? {
        guard let bundle = Bundle(url: URL(fileURLWithPath: appPath)),
              let bundleID = bundle.bundleIdentifier, !bundleID.isEmpty else {
            return nil
        }
        let name = bundle.localizedAppName
        return FoundApp(bundleID: bundleID, displayName: name, appPath: appPath, source: .directory)
    }
}

extension Bundle {
    /// 展示名优先级:本地化显示名 > CFBundleName > 包名去掉 .app。
    var localizedAppName: String {
        if let display = object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, !display.isEmpty {
            return display
        }
        if let name = object(forInfoDictionaryKey: "CFBundleName") as? String, !name.isEmpty {
            return name
        }
        return bundleURL.deletingPathExtension().lastPathComponent
    }
}
