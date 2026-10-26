// 卸载判定与清理建议(计划 §5.4)。
//
// 输入:目录证据(CatalogSnapshot)+ 当前规则(RuleSettings)+ 可注入时钟与位置探针。
// 输出:清理动作;绝不直接改 RuleStore——由 CleanupExecutor 落地
// (§5.3:AppRuleReconciler 不直接绕过 RuleStore 删除数据)。
//
// 证据模型(对抗式审查修订后):
// - 缺失的正面证据只有一种:该覆盖条目的每一个已知位置都被探针判 .absent
//   (父目录可读且包不在)。目录里"查不到"(entry == nil)本身不是证据——
//   Spotlight 索引抖动、卷离线都会造成;必须回探 RuleStore 里记录的位置。
// - 任一位置 .unknown(父目录不可读/卷离线)→ 一票否决,计时不动。
// - Spotlight 来源失败 → 全部缺失推进暂停(它是"复查其他位置/注册信息"的代理,
//   §5.4 条件 3;目录根失败不再全局否决——其影响已由位置级探针按条目表达)。
//
// 五个删除前置条件在本判定中的落点:
// 1. 无可用副本且无运行进程:所有已知位置 .absent 且 runningPIDs 空。
// 2. 卷在线、可访问、扫描未被取消或报错:.unknown 一票否决;Spotlight 失败暂停。
// 3. 复查其他已知位置与可用系统注册:目录按 Bundle ID 跨来源合并;同身份在任何
//    来源重新出现 → entry.present / 探针 .exists → 取消候选。
// 4. 宽限期后的第二次成功复核:markMissing →(24h)→ confirmStillMissing →
//    (下一次评估,仍缺失)→ proposeRemove。两次复核是两个不同的评估时点。
// 5. 删除前再查:CleanupExecutor 落地时用探针重新核验所有位置并做原子版本守卫。

import Foundation

enum CleanupAction: Equatable {
    /// 应用在场:刷新已知位置,清除缺失状态(重新出现取消候选)。
    case recordLocations(bundleID: String, locations: [String])
    case markMissing(bundleID: String, firstMissingAt: Date)
    case confirmStillMissing(bundleID: String, verifiedAt: Date)
    case cancelMissing(bundleID: String)
    /// 满足全部条件,建议删除覆盖。携带 firstMissingAt:执行器落地前原子核对
    /// 缺失起点未变(用户编辑会重置计时,见 RuleStore.setOverride)。
    case proposeRemoveOverride(bundleID: String, firstMissingAt: Date)
}

enum AppRuleReconciler {
    /// 首版宽限期(§5.4 建议 24 小时,可注入时钟测试)。
    static let defaultGrace: TimeInterval = 24 * 3600

    /// 纯判定:给定目录证据与规则,产出动作列表(顺序稳定,按 Bundle ID 排序)。
    static func evaluate(
        catalog: CatalogSnapshot,
        rules: RuleSettings,
        now: Date,
        grace: TimeInterval = AppRuleReconciler.defaultGrace,
        probePath: AppCatalog.PathProber = AppCatalog.defaultPathProber()
    ) -> [CleanupAction] {
        var actions: [CleanupAction] = []
        // Spotlight 是"复查其他位置/注册信息"的代理:它失败时缺失推进暂停。
        let spotlightFailed = catalog.sourceStates.contains { state in
            if case .failed(let reason) = state, reason.contains("Spotlight") { return true }
            return false
        }

        for (bundleID, entryData) in rules.overrides.sorted(by: { $0.key < $1.key }) {
            let entry = catalog.entry(bundleID: bundleID)
            let recordedLocations = entryData.locations ?? []

            // 已知位置全集:本轮目录条目位置 + 历史记录位置(去重)。
            var locations = entry?.appPaths ?? []
            for recorded in recordedLocations where !locations.contains(recorded) {
                locations.append(recorded)
            }
            locations.sort()

            // 无任何可核验点(目录没条目、也没记录过位置):不推进,不把未知当缺失。
            if entry == nil, locations.isEmpty { continue }

            // 条件 1(正面部分)+ 条件 3:在场 → 记录位置;重新出现 → 取消候选。
            if let entry, entry.presence == .present {
                if entryData.missingSince != nil {
                    actions.append(.cancelMissing(bundleID: bundleID))
                }
                if locations != entryData.locations {
                    actions.append(.recordLocations(bundleID: bundleID, locations: locations))
                }
                continue
            }

            // 观察不完整(卷离线/位置不可核验):一票否决,计时不动(§5.4 表)。
            if let entry, case .unavailable = entry.presence { continue }

            // 运行中(包删了进程还在):保留,退出后复核(§5.4 表第 4 行)。
            if let entry, !entry.runningPIDs.isEmpty { continue }

            // 缺失证据:逐个回探所有已知位置。entry == nil(目录查不到)时
            // 这一步是唯一证据来源——"查不到"本身不是缺失(索引抖动/卷离线)。
            var existingPaths: [String] = []
            var hasUnknown = false
            for location in locations {
                switch probePath(location) {
                case .exists:
                    existingPaths.append(location)
                case .unknown:
                    hasUnknown = true
                case .absent:
                    continue
                }
            }

            if !existingPaths.isEmpty {
                // 目录没看到但包在(索引没覆盖的自定义位置等):按在场处理。
                if entryData.missingSince != nil {
                    actions.append(.cancelMissing(bundleID: bundleID))
                }
                if existingPaths != entryData.locations {
                    actions.append(.recordLocations(bundleID: bundleID, locations: existingPaths))
                }
                continue
            }
            if hasUnknown { continue } // 位置不可核验 → 一票否决,计时不动

            // 全部位置可证缺失:先把证据点(位置全集)落进元数据——后续轮次与
            // 执行器的删除守卫都依赖它;再进入宽限链。
            if locations != entryData.locations {
                actions.append(.recordLocations(bundleID: bundleID, locations: locations))
            }

            // Spotlight 失败时缺失推进暂停(条件 3:它是"复查其他位置"的代理)。
            if spotlightFailed { continue }

            if entryData.missingSince == nil {
                actions.append(.markMissing(bundleID: bundleID, firstMissingAt: now))
                continue
            }
            guard let missingSince = entryData.missingSince else { continue }
            let elapsed = now.timeIntervalSince(missingSince)
            if elapsed < grace {
                continue // 宽限期内:暂缓判断
            }
            if entryData.lastVerifiedMissing == nil {
                // 宽限期满的第一次成功复核:记录,删除留给下一次评估(两次复核)。
                actions.append(.confirmStillMissing(bundleID: bundleID, verifiedAt: now))
                continue
            }
            guard let verifiedAt = entryData.lastVerifiedMissing else { continue }
            if verifiedAt <= missingSince {
                // 时间戳异常(比如手工改过文件):重置重新计时,不删除。
                actions.append(.markMissing(bundleID: bundleID, firstMissingAt: now))
                continue
            }
            actions.append(.proposeRemoveOverride(bundleID: bundleID, firstMissingAt: missingSince))
        }
        return actions
    }
}

/// 把判定动作落地:删除前做条件 5(探针重验 + 原子版本守卫);同步处理书签与缓存。
final class CleanupExecutor {
    private let store: RuleStore
    private let manualApps: ManualAppStore?
    private let icons: IconProviding?
    private let probePath: AppCatalog.PathProber

    init(store: RuleStore, manualApps: ManualAppStore? = nil, icons: IconProviding? = nil,
         probePath: @escaping AppCatalog.PathProber = AppCatalog.defaultPathProber()) {
        self.store = store
        self.manualApps = manualApps
        self.icons = icons
        self.probePath = probePath
    }

    /// 应用一轮动作;返回被删除覆盖的 Bundle ID 列表。
    @discardableResult
    func apply(_ actions: [CleanupAction], catalog: CatalogSnapshot) -> [String] {
        var removed: [String] = []
        for action in actions {
            switch action {
            case .recordLocations(let bundleID, let locations):
                _ = try? store.updateOverrideMetadata(bundleID: bundleID) { entry in
                    entry.locations = locations
                    entry.missingSince = nil
                    entry.lastVerifiedMissing = nil
                }
            case .markMissing(let bundleID, let at):
                _ = try? store.updateOverrideMetadata(bundleID: bundleID) { entry in
                    entry.missingSince = at
                    entry.lastVerifiedMissing = nil
                }
            case .confirmStillMissing(let bundleID, let verifiedAt):
                _ = try? store.updateOverrideMetadata(bundleID: bundleID) { entry in
                    entry.lastVerifiedMissing = verifiedAt
                }
            case .cancelMissing(let bundleID):
                _ = try? store.updateOverrideMetadata(bundleID: bundleID) { entry in
                    entry.missingSince = nil
                    entry.lastVerifiedMissing = nil
                }
            case .proposeRemoveOverride(let bundleID, let firstMissingAt):
                // 条件 5 之一(新鲜证据):删除瞬间重探全部已知位置,
                // 应用在扫描与删除之间回来(安装器落盘/Spotlight 滞留纠正)即中止。
                var paths = catalog.entry(bundleID: bundleID)?.appPaths
                    ?? store.settings?.overrides[bundleID]?.locations
                    ?? []
                if let recorded = store.settings?.overrides[bundleID]?.locations {
                    for location in recorded where !paths.contains(location) {
                        paths.append(location)
                    }
                }
                guard !paths.isEmpty else { continue }
                var allAbsent = true
                for path in paths {
                    switch probePath(path) {
                    case .exists, .unknown:
                        allAbsent = false
                    case .absent:
                        continue
                    }
                    if !allAbsent { break }
                }
                guard allAbsent else { continue }

                // 条件 5 之二(用户编辑守卫,原子):一次锁内取 {缺失起点, 版本},
                // 随后 removeOverride 用同一版本——编辑插在任意两步之间都会被拒。
                guard let guardState = store.deletionGuardState(bundleID: bundleID),
                      guardState.missingSince == firstMissingAt else { continue }
                let deleted = (try? store.removeOverride(bundleID: bundleID, expectedRevision: guardState.revision)) ?? false
                if deleted {
                    removed.append(bundleID)
                    // 同步清理附属记录(§5.4):书签与图标缓存。
                    _ = try? manualApps?.remove(bundleID: bundleID)
                    paths.forEach { icons?.evict(appPath: $0) }
                }
            }
        }
        return removed
    }
}
