// 目录与持久规则的并集列表(UX §6.2 / F12)。
//
// "列表不显示"不能充当"用户规则已删除"的替代实现:某条覆盖仍在存储中,
// 即使该应用本轮未被任何来源发现,也必须在"单独设置"里保留一行、可查看可改回默认。
// 名称仅用于展示(优先目录名称,其次历史位置推导,实在未知显示 Bundle ID);
// 规则继续按 Bundle ID 匹配。

import Foundation

struct AppRuleRow: Identifiable, Equatable {
    enum Presence: Equatable {
        case present
        /// 目录无条目或位置不可核验:保留可见规则,标"位置待确认"(§6.2 表第 3 行)。
        case unconfirmed
        /// 已确认位置缺失、尚在清理宽限期:"未找到此应用"(§6.2 表第 4 行)。
        case missing
    }

    let bundleID: String
    let displayName: String
    let appPaths: [String]
    let isSystem: Bool
    let sources: Set<AppCatalog.Source>
    let presence: Presence
    let mode: ScrollRuleMode
    let hasOverride: Bool

    var id: String { bundleID }

    /// 行内状态说明(§6.2):presence 附带解释;来源不可见不等于已卸载。
    var presenceCaption: String? {
        switch presence {
        case .present: return nil
        case .unconfirmed: return "位置待确认 · 设置保留"
        case .missing: return "未找到此应用 · 确认清理前保留设置"
        }
    }
}

enum AppRuleListBuilder {
    /// 构建"发现的应用 ∪ 已保存覆盖"行,按本地化名称稳定排序(重名以 Bundle ID 决胜)。
    static func rows(catalog: CatalogSnapshot?, overrides: [String: RuleOverrideEntry]) -> [AppRuleRow] {
        var byID: [String: AppRuleRow] = [:]
        for entry in (catalog?.entries ?? []) {
            byID[entry.bundleID] = AppRuleRow(
                bundleID: entry.bundleID,
                displayName: entry.displayName.isEmpty ? entry.bundleID : entry.displayName,
                appPaths: entry.appPaths,
                isSystem: entry.isSystem,
                sources: entry.sources,
                presence: presence(from: entry),
                mode: overrides[entry.bundleID]?.mode ?? .inherit,
                hasOverride: overrides[entry.bundleID] != nil
            )
        }
        for (bundleID, data) in overrides where byID[bundleID] == nil {
            let paths = data.locations ?? []
            let derivedName = paths.last
                .map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
            byID[bundleID] = AppRuleRow(
                bundleID: bundleID,
                displayName: (derivedName?.isEmpty == false) ? derivedName! : bundleID,
                appPaths: paths,
                isSystem: false,
                sources: [],
                presence: data.missingSince != nil ? .missing : .unconfirmed,
                mode: data.mode,
                hasOverride: true
            )
        }
        return byID.values.sorted { lhs, rhs in
            let order = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.bundleID < rhs.bundleID
        }
    }

    private static func presence(from entry: CatalogEntry) -> AppRuleRow.Presence {
        switch entry.presence {
        case .present: return .present
        case .unavailable: return .unconfirmed
        case .missing: return .missing
        }
    }
}
