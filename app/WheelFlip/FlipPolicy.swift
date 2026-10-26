// 按应用翻转的纯规则逻辑(计划 §3.1 真值表 / §7.1 模块表)。
// 不依赖系统权限、磁盘或 UI;输入全局默认值、目标 App 的三态覆盖与事件类型,
// 输出是否翻转及决策来源。服务"暂停/不可用 → 原样通过"由引擎在调用前处理,不属于本层。

import Foundation

/// 单个 App 的三态规则。inherit 表示"跟随默认",即没有覆盖条目,不落盘。
enum ScrollRuleMode: String, Codable, Equatable {
    case inherit
    case forceOn
    case forceOff
}

/// 滚轮事件大类;continuous(触控板 / Magic Mouse)一律放行,不做任何规则判断。
enum ScrollEventKind: Equatable {
    case discrete
    case continuous
}

/// 决策来源,供面板"生效说明"与诊断输出使用。
enum FlipDecisionSource: Equatable {
    case continuousPassthrough
    case appOverride(ScrollRuleMode)
    case globalDefault
}

struct FlipDecision: Equatable {
    let flips: Bool
    let source: FlipDecisionSource
}

enum FlipPolicy {
    /// §3.1 优先级:continuous 放行 → App 覆盖优先(inherit 视为无覆盖)→ 全局默认。
    /// "不翻转"表示不修改事件,不承诺某个 App 内部的自然方向。
    static func decide(defaultFlip: Bool, override: ScrollRuleMode?, eventKind: ScrollEventKind) -> FlipDecision {
        switch eventKind {
        case .continuous:
            return FlipDecision(flips: false, source: .continuousPassthrough)
        case .discrete:
            if let override, override != .inherit {
                return FlipDecision(flips: override == .forceOn, source: .appOverride(override))
            }
            return FlipDecision(flips: defaultFlip, source: .globalDefault)
        }
    }
}
