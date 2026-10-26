// Spotlight 来源(计划 §5.1 来源 2):应用元数据的初次收集。
// S0 实测:沙盒内 NSMetadataQuery 可用(381 项)。
// Spotlight 不能单独证明完整清单或卸载事实(§5.1 引用):它只补录目录扫不到的
// 自定义位置;索引缺失/未完成必须能失败,而不是静默空结果。
//
// 运行要求(对抗式审查实证):NSMetadataQuery 必须在带 run loop 的线程上 start,
// 通知才会投递——GCD worker 线程没有 run loop,在目录队列上直接 start 会永远
// 等不到 gathering 完成。这里把 start/stop 派回主队列执行。

import Foundation

final class SpotlightScanner {
    /// 查询超时:正常收集在 1s 内;超时按失败处理(来源状态可见)。
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 2.0) {
        self.timeout = timeout
    }

    /// 同步执行一次应用查询;应在后台队列调用(start/stop 内部派发到主队列)。
    func queryApplications() throws -> [FoundApp] {
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(
            format: "kMDItemContentType == %@", "com.apple.application-bundle"
        )
        query.searchScopes = [NSMetadataQueryLocalComputerScope]

        var apps: [FoundApp] = []
        let done = DispatchSemaphore(value: 0)
        var observerTokens: [NSObjectProtocol] = []

        let center = NotificationCenter.default
        observerTokens.append(center.addObserver(
            forName: .NSMetadataQueryDidFinishGathering, object: query, queue: nil
        ) { _ in
            done.signal()
        })

        var started = false
        DispatchQueue.main.sync { started = query.start() }
        guard started else {
            observerTokens.forEach(center.removeObserver)
            throw SpotlightError.queryUnavailable("Spotlight 查询未能启动")
        }

        let waitResult = done.wait(timeout: .now() + timeout)
        DispatchQueue.main.sync {
            query.disableUpdates()
            if waitResult == .success {
                for index in 0..<query.resultCount {
                    guard let item = query.result(at: index) as? NSMetadataItem else { continue }
                    guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                          path.hasSuffix(".app") else { continue }
                    guard let bundleID = item.value(forAttribute: "kMDItemCFBundleIdentifier") as? String,
                          !bundleID.isEmpty else { continue }
                    let name = (item.value(forAttribute: NSMetadataItemDisplayNameKey) as? String)
                        ?? (path as NSString).lastPathComponent
                    apps.append(FoundApp(bundleID: bundleID, displayName: name, appPath: path, source: .spotlight))
                }
            }
            query.enableUpdates()
            query.stop()
        }
        observerTokens.forEach(center.removeObserver)

        guard waitResult == .success else {
            throw SpotlightError.queryUnavailable("Spotlight 查询超时(\(timeout)s)")
        }
        return apps.filter { SpotlightScanner.isListable($0.appPath) }
    }

    enum SpotlightError: Error, CustomStringConvertible {
        case queryUnavailable(String)
        var description: String {
            switch self {
            case .queryUnavailable(let reason): return "Spotlight 查询失败:\(reason)"
            }
        }
    }

    /// Spotlight 侧垃圾过滤(§5.1;对抗式审查补漏——目录侧过滤之前只覆盖目录来源):
    /// - 嵌在别的 .app 包里的 helper/loginitem(路径含 "/X.app/Contents/")不是独立应用;
    /// - 垃圾桶里的副本不算安装。
    /// 安装镜像(DMG)挂载中的副本暂不过滤:外置盘上真实安装的用户应用必须允许补录
    /// (§5.1 末段),按卷属性区分留待实机样本,当前记录为已知边界。
    static func isListable(_ path: String) -> Bool {
        if path.contains("/.Trash/") || path.contains("/.Trashes/") { return false }
        let components = path.split(separator: "/")
        // 任一中间组件以 .app 结尾(最后那个除外)= 包内嵌套
        for component in components.dropLast() where component.hasSuffix(".app") {
            return false
        }
        return true
    }
}
