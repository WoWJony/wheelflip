// 统一呈现模型(UX 计划 §3.2 用词、§5.1 显示契约、§9.1「服务呈现/规则呈现」)。
//
// 面板、应用选择器、应用规则窗口与菜单栏图标共用这里的派生结果;
// 任何视图不得自行解释 AppPhase 或拼凑生效文案——那正是本轮改版要消除的问题
// (F02:结果呈现必须同时考虑服务状态和规则;F03:故障原因必须可见)。
//
// 文案键即中文字符串(开发语言 zh-Hans),英文经 Localizable.xcstrings 提供。

import Foundation

/// 服务状态呈现(§5.1 表的完整落地)。
struct ServicePresentation: Equatable {
    enum Action: Equatable {
        case pauseAll
        case resumeAll
        case openAuthorization
        case retryStart
        case repairRules

        var title: String {
            switch self {
            case .pauseAll: return String(localized: "暂停全部")
            case .resumeAll: return String(localized: "恢复全部")
            case .openAuthorization: return String(localized: "前往授权…")
            case .retryStart: return String(localized: "重试启动")
            case .repairRules: return String(localized: "修复设置…")
            }
        }
    }

    /// 顶部状态标题(§3.2 对外用词)。
    let title: String
    /// 状态符号(菜单栏图标与面板状态行共用,§4.4)。
    let symbolName: String
    /// 唯一的下一步操作;nil 表示没有可执行动作(理论不可达,防御)。
    let primaryAction: Action?
    /// 规则结果的条件前缀;nil = 规则无法读取,不得展示猜测的默认方向(§5.1)。
    let resultPrefix: String?
    /// 规则是否可编辑(规则读取失败时禁用编辑,保留管理与退出入口)。
    let rulesEditable: Bool
    /// 状态附加说明(如暂停语义、故障原因)。
    let detail: String?

    /// 完整状态描述,用于菜单栏 tooltip 与无障碍(§4.4:"WheelFlip:已暂停")。
    var statusDescription: String {
        String(format: String(localized: "WheelFlip：%@"), title)
    }

    /// 需要用户注意的状态(orange)/ 失败(red);运行与暂停均为常规语义色之外的符号+文字表达。
    var isFailure: Bool {
        switch primaryAction {
        case .retryStart, .repairRules: return true
        default: return false
        }
    }

    static func present(_ phase: AppPhase) -> ServicePresentation {
        switch phase {
        case .running:
            return ServicePresentation(
                title: String(localized: "已启用"),
                symbolName: "computermouse.fill",
                primaryAction: .pauseAll,
                resultPrefix: String(localized: "按当前规则："),
                rulesEditable: true,
                detail: nil
            )
        case .paused:
            return ServicePresentation(
                title: String(localized: "已暂停"),
                symbolName: "pause.circle.fill",
                primaryAction: .resumeAll,
                resultPrefix: String(localized: "恢复后："),
                rulesEditable: true,
                detail: String(localized: "所有规则暂不执行；重新打开应用后会恢复。")
            )
        case .onboarding:
            return ServicePresentation(
                title: String(localized: "需要辅助功能权限"),
                symbolName: "exclamationmark.triangle.fill",
                primaryAction: .openAuthorization,
                resultPrefix: String(localized: "授权并重新打开后："),
                rulesEditable: true,
                detail: String(localized: "授权前滚轮方向不会被修改。")
            )
        case .needsPermission(let reason):
            return ServicePresentation(
                title: String(localized: "需要辅助功能权限"),
                symbolName: "exclamationmark.triangle.fill",
                primaryAction: .openAuthorization,
                resultPrefix: String(localized: "授权并重新打开后："),
                rulesEditable: true,
                detail: reason
            )
        case .engineFailed(let reason):
            return ServicePresentation(
                title: String(localized: "暂时无法运行"),
                symbolName: "exclamationmark.octagon.fill",
                primaryAction: .retryStart,
                resultPrefix: String(localized: "恢复运行后："),
                rulesEditable: true,
                detail: reason
            )
        case .rulesFailed(let reason):
            return ServicePresentation(
                title: String(localized: "无法读取规则"),
                symbolName: "wrench.and.screwdriver.fill",
                primaryAction: .repairRules,
                resultPrefix: nil,
                rulesEditable: false,
                detail: reason
            )
        }
    }
}

/// 规则效果呈现(§3.2 用词;面板与管理窗口同源)。
enum RulePresentation {
    /// 方向词:"反转"相对于当前系统产生的滚动方向;"保持原方向"不承诺应用内部缩放含义。
    static func directionWord(_ flips: Bool) -> String {
        flips ? String(localized: "反转") : String(localized: "保持原方向")
    }

    /// 规则效果的稳定文案,如"反转 · 跟随默认"、"保持原方向 · 单独设置"。
    /// 与 FlipPolicy 同一决策路径,展示不另立逻辑(F02)。
    static func effectText(defaultFlip: Bool, mode: ScrollRuleMode) -> String {
        let decision = FlipPolicy.decide(
            defaultFlip: defaultFlip,
            override: mode == .inherit ? nil : mode,
            eventKind: .discrete
        )
        switch decision.source {
        case .appOverride:
            return "\(directionWord(decision.flips)) · \(String(localized: "单独设置"))"
        case .globalDefault:
            return "\(directionWord(decision.flips)) · \(String(localized: "跟随默认"))"
        case .continuousPassthrough:
            return String(localized: "触控板放行")
        }
    }

    /// 三态选择器的选项文案(§3.2:跟随默认 / 反转 / 保持原方向)。
    static func modeLabel(_ mode: ScrollRuleMode) -> String {
        switch mode {
        case .inherit: return String(localized: "跟随默认")
        case .forceOn: return String(localized: "反转")
        case .forceOff: return String(localized: "保持原方向")
        }
    }

    /// 面板来源行(UX §4.1/§4.3):"最近识别到 · 20 秒前"、"手动选择"、"上次识别到 · 3 分钟前"。
    /// 5 分钟是文案阈值,不是身份或规则有效期(§4.3)。
    static func sourceLine(for context: PanelTargetContext, now: Date) -> String {
        switch context.source {
        case .manualPick:
            return String(localized: "手动选择")
        case .recentScroll(let at):
            let prefix = now.timeIntervalSince(at) < 5 * 60
                ? String(localized: "最近识别到")
                : String(localized: "上次识别到")
            return "\(prefix) · \(relativeTime(from: at, to: now))"
        }
    }

    /// 相对时间:"刚刚" / "N 秒前" / "N 分钟前" / "N 小时前"。
    static func relativeTime(from date: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 15 { return String(localized: "刚刚") }
        if seconds < 60 { return String(format: String(localized: "%d 秒前"), seconds) }
        let minutes = seconds / 60
        if minutes < 60 { return String(format: String(localized: "%d 分钟前"), minutes) }
        return String(format: String(localized: "%d 小时前"), minutes / 60)
    }
}
