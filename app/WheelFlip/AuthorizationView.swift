import SwiftUI

/// 面板内授权引导(UX §5.4 三步说明,替代旧独立 onboarding 窗口)。
/// · 定位正在运行的这一份副本(多副本授权问题的入口,F09/E9);
/// · "重新打开并检查"走完整重开流程,重开后回显检查结论(F10:没有无反馈按钮);
/// · "稍后设置"返回规则视图——授权期间仍可浏览已载入的规则和退出应用。
struct AuthorizationView: View {
    @ObservedObject var appState: AppState
    let actions: PanelActions
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button {
                    onBack()
                } label: {
                    Label("返回", systemImage: "chevron.backward")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("稍后设置,返回规则设置"))
                Spacer()
                Text("需要辅助功能权限").font(.headline)
            }

            Text("WheelFlip 需要辅助功能权限才能修改鼠标滚轮事件,触控板不受影响。沙盒应用不会自动弹出授权对话框,需要手动添加一次。")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            if case .needsPermission(let reason) = appState.phase {
                Text(String(format: String(localized: "上次尝试:%@"), reason))
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                step(1,
                     text: "在 系统设置 → 隐私与安全性 → 辅助功能 中,点「+」添加 WheelFlip。",
                     buttonTitle: "打开系统设置…",
                     action: actions.openAccessibilitySettings)
                step(2,
                     text: "打开它的开关。列表里可能出现多个同名 WheelFlip,用下面的按钮在 Finder 中定位正在运行的这一份。",
                     buttonTitle: "在 Finder 中显示此应用",
                     action: actions.revealSelfInFinder)
                step(3,
                     text: "系统会缓存权限查询结果,需要重新打开 WheelFlip 才能读到新授权。",
                     buttonTitle: "重新打开并检查",
                     action: reopenAndCheck)
            }

            if let notice = appState.permissionNotice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("稍后设置") { onBack() }
            }
        }
        .padding(16)
        .frame(width: 380)
        .background(.background)
    }

    /// 先做一次进程内检查(极少数立即生效的情况),否则走重开流程;
    /// 重开后的检查结论由新实例经 --permission-recheck 回显(F10)。
    private func reopenAndCheck() {
        if appState.refreshPermission() {
            onBack()
        } else {
            actions.relaunchForPermissionCheck()
        }
    }

    private func step(_ number: Int, text: LocalizedStringKey, buttonTitle: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "\(number).circle")
                .font(.title3)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Button(buttonTitle, action: action)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
