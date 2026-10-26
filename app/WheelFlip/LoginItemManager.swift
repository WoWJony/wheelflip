import ServiceManagement

// SMAppService.mainApp: 单进程方案专用,App 自己注册自己为登录项,不需要独立 helper bundle。
// 只查一次 status(F01:登录项确认不再阻塞恢复按钮的重绘,也不做冗余 XPC)。
final class LoginItemManager: LoginItemManaging {
    func register() -> String? {
        let service = SMAppService.mainApp
        let before = service.status
        if before != .enabled {
            do {
                try service.register()
            } catch {
                return error.localizedDescription
            }
        }
        switch service.status {
        case .enabled:
            return nil
        case .requiresApproval:
            // UX §5.4:待批准不是故障,给系统设置入口而非报错口吻。
            return String(localized: "登录自动启动待确认:请在 系统设置 → 登录项 里批准")
        case .notFound, .notRegistered:
            return String(localized: "登录项注册未生效")
        @unknown default:
            return nil
        }
    }

    func unregister() -> String? {
        do {
            try SMAppService.mainApp.unregister()
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
