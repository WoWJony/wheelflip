import SwiftUI

// 面板与应用规则窗口共用的小控件(UX §7.1 布局规格:原生常规尺寸、完整点击区,
// 不通过缩小字体解决拥挤;动作名称不截断)。

/// 按需加载的应用图标(内存缓存;失败用占位)。
struct AppIconView: View {
    let icons: IconProviding?
    let appPath: String?

    var body: some View {
        Group {
            if let appPath, let image = icons?.icon(forAppPath: appPath) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "app.dashed")
                    .resizable().scaledToFit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true) // 名称文字承担语义
    }
}

/// 默认方向选择(§3.2/§4.1):两项选择,与"服务状态"在视觉与语义上都区分开。
struct DefaultDirectionPicker: View {
    let defaultFlip: Bool
    let editable: Bool
    let onSelect: (Bool) -> Void

    var body: some View {
        Picker("默认方向", selection: Binding(
            get: { defaultFlip },
            set: { onSelect($0) }
        )) {
            Text("反转").tag(true)
            Text("保持原方向").tag(false)
        }
        .pickerStyle(.segmented)
        .labelsHidden() // 行首已有可见"默认方向"标签;picker 标签只留给无障碍
        .frame(width: 190)
        .disabled(!editable)
        .accessibilityLabel(Text("默认方向(其他应用)"))
        .accessibilityValue(Text(defaultFlip ? String(localized: "反转") : String(localized: "保持原方向")))
    }
}

/// 面板三态分段选择器(§4.1 线框):跟随默认 / 反转 / 保持原方向。
struct RuleModeSegmentedPicker: View {
    let current: ScrollRuleMode
    let objectName: String
    let editable: Bool
    let onSelect: (ScrollRuleMode) -> Void

    var body: some View {
        Picker("滚轮方向", selection: Binding(
            get: { current },
            set: { onSelect($0) }
        )) {
            ForEach([ScrollRuleMode.inherit, .forceOn, .forceOff], id: \.self) { mode in
                Text(RulePresentation.modeLabel(mode)).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(!editable)
        .accessibilityLabel(Text(String(format: String(localized: "%@ 的滚轮方向"), objectName)))
        .accessibilityValue(Text(RulePresentation.modeLabel(current)))
    }
}

/// 管理窗口表格用的弹窗式三态选择器(§6.1:不再每行铺三个按钮)。
struct RuleModeMenuPicker: View {
    let current: ScrollRuleMode
    let objectName: String
    let editable: Bool
    let onSelect: (ScrollRuleMode) -> Void

    var body: some View {
        Picker("方向规则", selection: Binding(
            get: { current },
            set: { onSelect($0) }
        )) {
            ForEach([ScrollRuleMode.inherit, .forceOn, .forceOff], id: \.self) { mode in
                Text(RulePresentation.modeLabel(mode)).tag(mode)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .disabled(!editable)
        .accessibilityLabel(Text(String(format: String(localized: "%@ 的滚轮方向规则"), objectName)))
        .accessibilityValue(Text(RulePresentation.modeLabel(current)))
    }
}

/// 保存反馈行(§5.3):成功短暂显示约 2 秒(AppState 定时清除),失败持久显示
/// 且紧邻失败控件;只显示与当前对象匹配的反馈(F11:错误绑定操作对象)。
struct SaveFeedbackLine: View {
    let saveState: SaveState?
    let target: SaveState.Target

    var body: some View {
        if let state = saveState, state.target == target {
            HStack(alignment: .top, spacing: 4) {
                Image(systemName: state.succeeded ? "checkmark.circle" : "exclamationmark.triangle.fill")
                    .font(.caption2)
                Text(state.message)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(state.succeeded ? Color.secondary : Color.red)
            .accessibilityElement(children: .combine)
        }
    }
}
