// 图标按需加载(计划 §5.2):内存缓存设上限;首版不复制图标到磁盘、不预加载。
// 缓存条目数上限而非字节(NSImage 无可靠字节口径);淘汰走 NSCache 自动回收。

import AppKit

protocol IconProviding: AnyObject {
    /// 返回 nil 表示无图标(UI 用占位);同步、只做内存/轻量文件读取。
    func icon(forAppPath appPath: String) -> NSImage?
    /// 应用卸载/条目删除时逐出缓存(§5.4)。
    func evict(appPath: String)
}

final class IconProvider: IconProviding {
    private let cache = NSCache<NSString, NSImage>()
    private let loadIcon: (String) -> NSImage?

    init(maxCount: Int = 200, loadIcon: @escaping (String) -> NSImage = { path in
        NSWorkspace.shared.icon(forFile: path)
    }) {
        cache.countLimit = maxCount
        self.loadIcon = loadIcon
    }

    func icon(forAppPath appPath: String) -> NSImage? {
        let key = appPath as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let image = loadIcon(appPath)
        if let image {
            cache.setObject(image, forKey: key)
        }
        return image
    }

    /// 应用卸载/条目删除时逐出(§5.4:清理同步处理缓存)。
    func evict(appPath: String) {
        cache.removeObject(forKey: appPath as NSString)
    }
}
