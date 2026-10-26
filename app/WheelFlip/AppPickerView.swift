import SwiftUI

/// 面板内应用选择(§4.3):同一个面板切换到选择视图,不叠加第二层悬浮窗。
/// 提供搜索、最近识别目标和应用列表(目录 ∪ 已保存覆盖,复用 AppRuleListBuilder)。
/// 手动选择在暂停、缺权限或服务故障时同样可用(空态不要求滚动触发识别,F08);
/// 选择后回到规则视图并显示新名称;返回保留原编辑对象。
struct AppPickerView: View {
    @ObservedObject var appState: AppState
    let icons: IconProviding?
    let onPick: (String) -> Void
    let onBack: () -> Void

    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    private var allRows: [AppRuleRow] {
        AppRuleListBuilder.rows(
            catalog: appState.catalogSnapshot,
            overrides: appState.store.settings?.overrides ?? [:]
        )
    }

    private var filteredRows: [AppRuleRow] {
        let search = searchText.trimmingCharacters(in: .whitespaces)
        guard !search.isEmpty else { return allRows }
        return allRows.filter {
            $0.displayName.localizedCaseInsensitiveContains(search)
                || $0.bundleID.localizedCaseInsensitiveContains(search)
        }
    }

    /// 同名应用:展示位置信息加以区分(§7.2/F16)。
    private var duplicateNames: Set<String> {
        var counts: [String: Int] = [:]
        for row in allRows { counts[row.displayName, default: 0] += 1 }
        return Set(counts.filter { $0.value > 1 }.keys)
    }

    private var recentTarget: IdentifiedTarget? {
        guard let recent = appState.lastIdentifiedTarget else { return nil }
        let search = searchText.trimmingCharacters(in: .whitespaces)
        guard !search.isEmpty else { return recent }
        guard let row = allRows.first(where: { $0.bundleID == recent.bundleID }) else { return nil }
        let hit = row.displayName.localizedCaseInsensitiveContains(search)
            || row.bundleID.localizedCaseInsensitiveContains(search)
        return hit ? recent : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            pickerHeader
            searchField
            if let recent = recentTarget {
                recentRow(recent)
                Divider()
            }
            listContent
        }
        .frame(width: 380, height: 380)
        .background(.background)
    }

    private var pickerHeader: some View {
        HStack {
            Button {
                onBack()
            } label: {
                Label("返回", systemImage: "chevron.backward")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("返回规则设置"))
            Spacer()
            Text("选择应用").font(.headline)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索应用", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .accessibilityLabel(Text("搜索应用"))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .onAppear { searchFocused = true }
    }

    /// 最近识别目标行(§4.3:历史线索,不假装实时鼠标位置)。
    private func recentRow(_ recent: IdentifiedTarget) -> some View {
        Button {
            onPick(recent.bundleID)
        } label: {
            HStack(spacing: 8) {
                AppIconView(icons: icons,
                            appPath: appState.catalogSnapshot?.entry(bundleID: recent.bundleID)?.appPaths.first)
                VStack(alignment: .leading, spacing: 1) {
                    Text(displayName(recent.bundleID)).lineLimit(1)
                    Text("最近识别")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .accessibilityLabel(Text(String(format: String(localized: "选择最近识别的应用 %@"), displayName(recent.bundleID))))
    }

    @ViewBuilder
    private var listContent: some View {
        if filteredRows.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.title2).foregroundStyle(.secondary)
                Text(searchText.isEmpty
                        ? String(localized: "尚未发现任何应用")
                        : String(format: String(localized: "没有找到“%@”"), searchText))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredRows) { row in
                        pickRow(row)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func pickRow(_ row: AppRuleRow) -> some View {
        Button {
            onPick(row.bundleID)
        } label: {
            HStack(spacing: 8) {
                AppIconView(icons: icons, appPath: row.appPaths.first)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.displayName).lineLimit(1)
                    if duplicateNames.contains(row.displayName) {
                        Text(row.appPaths.first ?? row.bundleID)
                            .font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer()
                if let caption = row.presenceCaption {
                    Text(caption).font(.caption2).foregroundStyle(.orange)
                } else if row.hasOverride {
                    // 有单独设置的 应用标注,帮助识别"改过谁"(F16 的非技术表达)
                    Text("单独设置").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .accessibilityLabel(Text(String(format: String(localized: "选择应用 %@"), row.displayName)))
    }

    private func displayName(_ bundleID: String) -> String {
        if let entry = appState.catalogSnapshot?.entry(bundleID: bundleID),
           !entry.displayName.isEmpty {
            return entry.displayName
        }
        if let row = allRows.first(where: { $0.bundleID == bundleID }) {
            return row.displayName
        }
        return bundleID
    }
}
