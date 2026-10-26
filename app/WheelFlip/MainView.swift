import SwiftUI

/// 面板需要的宿主动作(AppDelegate 注入;UI fixture 注入替身)。
struct PanelActions {
    let openManagement: () -> Void
    let quit: () -> Void
    let showAbout: () -> Void
    let openAccessibilitySettings: () -> Void
    let openLoginItemSettings: () -> Void
    let revealSelfInFinder: () -> Void
    let revealRulesBackup: () -> Void
    let relaunchForPermissionCheck: () -> Void
}

/// 菜单栏面板(UX §4.1/§4.2)。
/// 容器负责面板内路由:规则(默认)/ 选择应用 / 授权 / 使用说明 / 修复设置;
/// Esc 或"返回"回到规则视图,不叠加第二层悬浮窗(§4.3)。
/// 编辑对象在 popover.show 前由 AppDelegate 调 pinPanelTarget() 固定,
/// 展示期间不随新滚动事件跳变——只固定编辑对象,不固定引擎的事件路由。
struct MainView: View {
    enum Route: Equatable {
        case rules
        case picker
        case authorization
        case help
        case repair
    }

    @ObservedObject var appState: AppState
    let icons: IconProviding?
    let actions: PanelActions
    @State private var route: Route = .rules

    var body: some View {
        Group {
            switch route {
            case .rules:
                PanelRulesView(appState: appState, icons: icons, actions: actions) { navigate(to: $0) }
            case .picker:
                AppPickerView(appState: appState, icons: icons,
                              onPick: { bundleID in
                                  appState.selectPanelTarget(bundleID: bundleID)
                                  navigate(to: .rules)
                              },
                              onBack: { navigate(to: .rules) })
            case .authorization:
                AuthorizationView(appState: appState, actions: actions, onBack: { navigate(to: .rules) })
            case .help:
                HelpView(onBack: { navigate(to: .rules) })
            case .repair:
                RepairRulesView(appState: appState, actions: actions, onBack: { navigate(to: .rules) })
            }
        }
        .onExitCommand {
            if route != .rules { navigate(to: .rules) }
        }
    }

    private func navigate(to newRoute: Route) {
        route = newRoute
    }
}

/// 面板主视图(§4.1 线框):顶部服务状态 → 设置应用 → 其他应用(默认方向) → 管理入口与更多。
/// 核心按钮单语完整显示(F06);"运行中"等进程徽标不出现在快捷面板(F07);
/// 服务状态与规则结果使用同一份 ServicePresentation/RulePresentation 派生(F02/F03)。
struct PanelRulesView: View {
    @ObservedObject var appState: AppState
    let icons: IconProviding?
    let actions: PanelActions
    let navigate: (MainView.Route) -> Void

    private var presentation: ServicePresentation {
        ServicePresentation.present(appState.phase)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if appState.legacyCLIDetected {
                legacyCLIBanner
            }
            header
            Divider()
            notices
            appSection
            Divider()
            defaultSection
            Divider()
            footer
        }
        .frame(width: 380)
        .padding(.vertical, 12)
        .background(.background) // 稳定的原生表面,透明材料与背景混合时仍可读(F18)
    }

    // MARK: 顶部服务状态(§4.1:状态与暂停/恢复在固定位置)

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("WheelFlip").font(.headline)
                Spacer()
                primaryAction
            }
            HStack(spacing: 6) {
                Image(systemName: presentation.symbolName)
                    .foregroundStyle(statusColor)
                    .font(.subheadline.weight(.medium))
                Text(presentation.title)
                    .font(.subheadline.weight(.medium))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(presentation.statusDescription))

            if let detail = presentation.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var primaryAction: some View {
        // 唯一的下一步操作(§5.1 表);按钮文案为动作,单语完整显示(F06)。
        switch presentation.primaryAction {
        case .pauseAll:
            Button("暂停全部") { appState.pauseAll() }
        case .resumeAll:
            Button("恢复全部") { appState.resumeRules() }
        case .openAuthorization:
            Button("前往授权…") { navigate(.authorization) }
        case .retryStart:
            Button("重试启动") { appState.retryEngineStart() }
        case .repairRules:
            Button("修复设置…") { navigate(.repair) }
        case nil:
            EmptyView()
        }
    }

    private var statusColor: Color {
        switch appState.phase {
        case .running: return .green
        case .paused, .onboarding, .needsPermission: return .orange
        case .engineFailed, .rulesFailed: return .red
        }
    }

    // MARK: 提示区(登录项/权限检查结论;只在存在时占位)

    @ViewBuilder
    private var notices: some View {
        if let notice = appState.loginItemNotice {
            HStack(alignment: .top, spacing: 8) {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("打开系统设置") { actions.openLoginItemSettings() }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    // MARK: 设置应用(§4.1:对象与来源明确,提供选择入口)

    private var appSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("设置应用").font(.subheadline.weight(.semibold))
                Spacer()
                Button("选择应用…") { navigate(.picker) }
            }

            if let context = appState.panelTarget {
                targetRow(context)
                if presentation.rulesEditable {
                    RuleModeSegmentedPicker(
                        current: appState.overrideMode(forBundle: context.bundleID),
                        objectName: displayName(for: context),
                        editable: true,
                        onSelect: { appState.setOverride(bundleID: context.bundleID, mode: $0) }
                    )
                    effectLine(for: context)
                    SaveFeedbackLine(saveState: appState.saveState,
                                     target: .appRule(bundleID: context.bundleID))
                } else {
                    Text("规则无法读取,修复设置后才能编辑此应用的方向。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                // 空态(§4.3 表):不要求用户靠滚动触发识别
                VStack(alignment: .leading, spacing: 4) {
                    Text("选择一个应用,为它设置滚轮方向;默认方向也可以直接设置。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if appState.lastDiscreteFailureAt != nil {
                        Text("最近一次滚轮操作未识别应用。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// 目标行:应用名占主体,来源与相对时间说明"我在改谁、依据是什么"(F04/F08);
    /// 相对时间由 TimelineView 低频刷新,不逐秒播报(§7.3)。
    private func targetRow(_ context: PanelTargetContext) -> some View {
        let entry = appState.catalogSnapshot?.entry(bundleID: context.bundleID)
        let presenceCaption = Self.presenceCaption(entry: entry)
        return HStack(alignment: .top, spacing: 8) {
            AppIconView(icons: icons, appPath: entry?.appPaths.first)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName(for: context))
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                TimelineView(.periodic(from: .now, by: 30)) { timeline in
                    Text(RulePresentation.sourceLine(for: context, now: timeline.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if appState.lastDiscreteFailureAt != nil,
                   case .recentScroll = context.source {
                    Text("最近一次滚轮操作未识别应用;仍在编辑这个应用。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let caption = presenceCaption {
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// 生效说明(§4.1):前缀来自服务状态,方向与来源来自规则呈现(F02:条件式表达)。
    @ViewBuilder
    private func effectLine(for context: PanelTargetContext) -> some View {
        if let prefix = presentation.resultPrefix {
            Text(prefix + RulePresentation.effectText(
                defaultFlip: appState.defaultFlip,
                mode: appState.overrideMode(forBundle: context.bundleID)
            ))
            .font(.footnote)
            .foregroundStyle(.secondary)
        } else {
            Text("规则无法读取,暂无法计算生效结果。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func displayName(for context: PanelTargetContext) -> String {
        if let entry = appState.catalogSnapshot?.entry(bundleID: context.bundleID),
           !entry.displayName.isEmpty {
            return entry.displayName
        }
        return context.bundleID
    }

    /// 位置状态说明(§4.3 表最后两行):已确认缺失/位置待确认,保留设置并可改回默认。
    static func presenceCaption(entry: CatalogEntry?) -> String? {
        guard let entry else { return String(localized: "位置待确认 · 设置保留") }
        switch entry.presence {
        case .present: return nil
        case .unavailable: return String(localized: "位置待确认 · 设置保留")
        case .missing: return String(localized: "未找到此应用 · 设置保留")
        }
    }

    // MARK: 其他应用(默认方向,§4.1:两项选择)

    private var defaultSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("其他应用").font(.subheadline.weight(.semibold))
            HStack {
                Text("默认方向")
                Spacer()
                DefaultDirectionPicker(
                    defaultFlip: appState.defaultFlip,
                    editable: presentation.rulesEditable,
                    onSelect: { appState.setDefaultFlip($0) }
                )
            }
            Text("只影响“跟随默认”的应用;单独设置的应用不受影响。")
                .font(.caption)
                .foregroundStyle(.secondary)
            SaveFeedbackLine(saveState: appState.saveState, target: .defaultDirection)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: 底部(§4.1:管理入口 + 更多菜单)

    private var footer: some View {
        HStack {
            Button("所有应用规则…") { actions.openManagement() }
            Spacer()
            Menu {
                Button("使用说明…") { navigate(.help) }
                Button("关于 WheelFlip") { actions.showAbout() }
                // 退出项与常用项之间有分隔;说明现有约定:退出会注销登录项(F17)。
                Section("退出后不再随登录自动启动") {
                    Button("退出 WheelFlip") { actions.quit() }
                }
            } label: {
                Text("更多")
            }
            .fixedSize()
            .accessibilityLabel(Text("更多操作"))
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private var legacyCLIBanner: some View {
        Text("检测到旧版命令行 wheelflip 仍在运行,可能导致滚轮方向被翻转两次,建议先卸载旧版。")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
    }
}
