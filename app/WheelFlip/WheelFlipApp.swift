import SwiftUI

// 纯菜单栏 App(LSUIElement=true,见 Resources/Info.plist),没有 WindowGroup 主窗口。
// 状态机/图标/popover/onboarding 窗口全由 AppDelegate 手动管理(见 AppDelegate.swift)。
struct WheelFlipSpikeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
