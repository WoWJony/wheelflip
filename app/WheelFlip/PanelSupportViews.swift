import SwiftUI

/// 使用说明(§4.1"更多"菜单入口):集中解释三个概念与滚动行为,一次讲清(§3.1/§3.2)。
struct HelpView: View {
    let onBack: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Button {
                        onBack()
                    } label: {
                        Label("返回", systemImage: "chevron.backward")
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                    Text("使用说明").font(.headline)
                }

                HelpSection(title: "服务状态",
                            text: "顶部显示 WheelFlip 是否在工作。“暂停全部”会临时停止修改滚轮,所有滚动原样通过;“恢复全部”继续执行规则。暂停只到本次运行为止,重新打开应用后会自动恢复。")
                HelpSection(title: "应用规则",
                            text: "每个应用可以单独设置“跟随默认 / 反转 / 保持原方向”。“设置应用”区域显示当前正在编辑的应用及其来源;点“选择应用…”可以手动挑选任何已安装的应用,不需要先打开或滚动它。滚轮事件归属于实际接收它的窗口所属的应用,即使该应用不在前台。")
                HelpSection(title: "默认方向",
                            text: "“其他应用”的默认方向只影响没有单独设置的应用;已单独设置的应用不受默认值变化影响。关闭默认方向不会停止服务。")
                HelpSection(title: "触控板与其他设备",
                            text: "触控板和 Magic Mouse 的连续滚动不受任何影响,始终按系统设置的方向工作。鼠标滚轮方向“反转”是相对当前系统产生的方向而言。")
                HelpSection(title: "退出",
                            text: "“退出 WheelFlip”会停止滚轮修改,并注销登录自启;下次想使用时需手动打开。")
            }
            .padding(16)
        }
        .frame(width: 380, height: 420)
        .background(.background)
    }
}

private struct HelpSection: View {
    let title: LocalizedStringKey
    let text: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 修复设置(§5.4"规则损坏"路径):显示真实原因,提供重新读取、查看备份、
/// 明确列出损失并确认后的重置;绝不自动抹掉规则。
struct RepairRulesView: View {
    @ObservedObject var appState: AppState
    let actions: PanelActions
    let onBack: () -> Void

    @State private var localError: String?
    @State private var confirmReset = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Button {
                        onBack()
                    } label: {
                        Label("返回", systemImage: "chevron.backward")
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                    Text("修复设置").font(.headline)
                }

                if case .rulesFailed(let reason) = appState.phase {
                    Text(reason)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                Text("规则文件无法读取时,WheelFlip 不会修改任何滚轮事件。如果在文件外部修复了它,可以重新读取;也可以查看备份,或在确认损失后重置。")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 10) {
                    Button("重新读取") { reload() }
                    Button("在 Finder 中显示备份") { actions.revealRulesBackup() }
                }

                Divider()

                Text("重置会删除所有按应用规则和默认方向,恢复为全新默认(默认方向 = 反转)。此操作不可撤销。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("重置全部规则…", role: .destructive) { confirmReset = true }
                    .foregroundStyle(.red)

                if let localError {
                    Text(localError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
        }
        .frame(width: 380, height: 420)
        .background(.background)
        .confirmationDialog(
            "重置全部规则?",
            isPresented: $confirmReset,
            titleVisibility: .visible
        ) {
            Button("删除全部规则并重置", role: .destructive) { reset() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除所有按应用规则与默认方向设置,恢复为全新默认。此操作不可撤销。")
        }
    }

    private func reload() {
        if let error = appState.repairReloadRules() {
            localError = error
        } else {
            onBack()
        }
    }

    private func reset() {
        if let error = appState.repairResetRules() {
            localError = error
        } else {
            onBack()
        }
    }
}
