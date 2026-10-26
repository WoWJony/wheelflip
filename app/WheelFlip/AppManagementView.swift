import AppKit
import Combine
import SwiftUI

/// 应用规则窗口的视图模型(UX §6)。
/// · 列表 = 目录 ∪ 已保存覆盖(F12/T09),经 AppRuleListBuilder 构建;
/// · 保存反馈统一走 appState.saveState(F11),本模型不再复制错误字符串;
/// · 添加应用后立即定位并提示(F13/T10),当前筛选会隐藏时转到可见列表;
/// · 搜索/筛选状态属于视图模型,快照更新不重置;模型活在会话里,跨窗口打开保留。
final class AppManagementModel: ObservableObject {
    enum Filter: Hashable {
        case all
        case customized
    }

    @Published private(set) var snapshot: CatalogSnapshot?
    @Published var searchText: String = ""
    @Published var filter: Filter
    /// 添加成功的定位与提示(F13);additionTarget 为要选中的 Bundle ID。
    @Published private(set) var additionNotice: String?
    @Published private(set) var additionTarget: String?
    /// 行内动作失败(取消手动添加等)可见,不吞错(F13/T10)。
    @Published private(set) var rowActionError: String?

    private let appState: AppState
    private let manualApps: ManualAppStore
    private let icons: IconProviding?
    private let requestCatalogRefresh: () -> Void
    private var cancellable: Any?

    init(appState: AppState, manualApps: ManualAppStore,
         icons: IconProviding?, requestCatalogRefresh: @escaping () -> Void) {
        self.appState = appState
        self.manualApps = manualApps
        self.icons = icons
        self.requestCatalogRefresh = requestCatalogRefresh
        // 首次打开:已有覆盖默认"单独设置",没有覆盖默认"全部应用"(§6.1);
        // 模型活在会话里,之后保留用户上次筛选和搜索。
        filter = (appState.store.settings?.overrides.isEmpty == false) ? .customized : .all
        // 面板改默认值/服务状态变化 → 本窗口的"结果"列与提示即时跟随
        // (对抗式审查:只观察自身会停在旧值)。
        cancellable = appState.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var iconsProvider: IconProviding? { icons }
    var appStatePhase: AppPhase { appState.phase }
    var appStateDefaultFlip: Bool { appState.defaultFlip }
    private var presentation: ServicePresentation { ServicePresentation.present(appStatePhase) }

    /// 主线程喂入新快照(列表异步更新;不重置搜索/筛选,不抢焦点,§6.2)。
    func reload(from snapshot: CatalogSnapshot) {
        self.snapshot = snapshot
    }

    // MARK: 行(目录 ∪ 覆盖)

    /// 并集全量行(未过滤)。
    var unfilteredRows: [AppRuleRow] {
        AppRuleListBuilder.rows(
            catalog: snapshot,
            overrides: appState.store.settings?.overrides ?? [:]
        )
    }

    var rows: [AppRuleRow] {
        let search = searchText.trimmingCharacters(in: .whitespaces)
        return unfilteredRows.filter { row in
            switch filter {
            case .all: break
            case .customized: guard row.hasOverride else { return false }
            }
            guard !search.isEmpty else { return true }
            return row.displayName.localizedCaseInsensitiveContains(search)
                || row.bundleID.localizedCaseInsensitiveContains(search)
        }
    }

    var customizedCount: Int { unfilteredRows.filter(\.hasOverride).count }
    var totalCount: Int { unfilteredRows.count }

    /// 同名应用:名称下加位置区分(§6.2 表最后一行/F16)。
    var duplicateNames: Set<String> {
        var counts: [String: Int] = [:]
        for row in unfilteredRows { counts[row.displayName, default: 0] += 1 }
        return Set(counts.filter { $0.value > 1 }.keys)
    }

    // MARK: 服务状态对结果列的影响(§6.1:条件式表达)

    var resultColumnTitle: String {
        switch appStatePhase {
        case .running: return String(localized: "按规则执行")
        case .paused: return String(localized: "恢复后执行")
        case .onboarding, .needsPermission: return String(localized: "授权后执行")
        case .engineFailed: return String(localized: "恢复运行后执行")
        case .rulesFailed: return String(localized: "按规则执行")
        }
    }

    var rulesEditable: Bool { presentation.rulesEditable }

    /// 每行结果(§6.1):规则读取失败时不展示猜测的默认方向(§5.1)。
    func effectText(for row: AppRuleRow) -> String {
        guard presentation.resultPrefix != nil else { return String(localized: "无法计算") }
        return RulePresentation.effectText(defaultFlip: appState.defaultFlip, mode: row.mode)
    }

    /// 紧邻失败控件的行内错误(F11):只显示绑定到该应用的失败反馈。
    func saveErrorText(forBundle bundleID: String) -> String? {
        guard case .appRule(let id) = appState.saveState?.target,
              id == bundleID,
              appState.saveState?.succeeded == false else { return nil }
        return appState.saveState?.message
    }

    var defaultDirectionSaveState: SaveState? {
        guard case .defaultDirection = appState.saveState?.target else { return nil }
        return appState.saveState
    }

    // MARK: 编辑

    func setDefaultFlip(_ value: Bool) {
        appState.setDefaultFlip(value)
    }

    func setOverride(bundleID: String, mode: ScrollRuleMode) {
        appState.setOverride(bundleID: bundleID, mode: mode)
    }

    // MARK: 添加与移除(§6.3)

    /// 文件选择器添加 .app:写入手工清单并触发目录重扫。
    /// 成功后立即定位(F13):先本地并入最小条目保证行立刻出现,再选中并提示;
    /// 当前筛选会隐藏该项时转到可见列表。失败返回错误文案供 UI 展示。
    @discardableResult
    func addManualApp(url: URL) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue, url.pathExtension == "app" else {
            rowActionError = String(localized: "请选择一个 .app 应用包")
            return rowActionError
        }
        // 选择器授予了本次访问;读 Bundle 身份只取元信息,不执行任何二进制(§5.2)
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier, !bundleID.isEmpty else {
            rowActionError = String(localized: "无法读取该应用的标识(损坏或不受支持的包)")
            return rowActionError
        }
        let alreadyListed = manualApps.entry(bundleID: bundleID) != nil
            || snapshot?.entry(bundleID: bundleID) != nil
            || appState.store.settings?.overrides[bundleID] != nil
        do {
            _ = try manualApps.addOrUpdate(bundleID: bundleID, appPath: url.path)
        } catch {
            rowActionError = String(format: String(localized: "添加失败:%@"), error.localizedDescription)
            return rowActionError
        }
        rowActionError = nil
        mergeManualEntry(bundleID: bundleID, path: url.path)
        requestCatalogRefresh()
        // 定位与可见性(F13):被当前筛选隐藏时转到可见列表
        let willHide = filter == .customized && appState.store.settings?.overrides[bundleID] == nil
        if willHide { filter = .all }
        additionTarget = bundleID
        additionNotice = alreadyListed
            ? String(localized: "此应用已在列表中,已定位到它")
            : String(localized: "已添加,可设置方向")
        return nil
    }

    /// 取消手动添加(§6.3):移除手动记录,保留方向规则;失败必须返回错误。
    @discardableResult
    func removeManualApp(bundleID: String) -> String? {
        do {
            guard try manualApps.remove(bundleID: bundleID) else {
                rowActionError = String(localized: "没有找到手动添加记录")
                return rowActionError
            }
        } catch {
            rowActionError = String(format: String(localized: "移除失败:%@"), error.localizedDescription)
            return rowActionError
        }
        rowActionError = nil
        requestCatalogRefresh()
        return nil
    }

    /// 添加提示短暂显示后清除(定位选择保留)。
    func clearAdditionNotice() {
        additionNotice = nil
    }

    func isManual(bundleID: String) -> Bool {
        manualApps.entry(bundleID: bundleID) != nil
    }

    /// 部分来源不可用的轻量提示(§5.4"应用目录不完整"):已有结果可用,引导手动添加。
    var sourceNotice: String? {
        guard let states = snapshot?.sourceStates else { return nil }
        let failures = states.filter(\.isFailure)
        guard !failures.isEmpty else { return nil }
        return String(localized: "部分来源不可见,清单可能不完整(如个人应用目录受限)")
    }

    /// 首轮扫描尚未完成且没有已保存覆盖可先展示(§6.3"首次扫描中")。
    var isInitialScanning: Bool {
        snapshot == nil && unfilteredRows.isEmpty
    }

    private func mergeManualEntry(bundleID: String, path: String) {
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let found = FoundApp(bundleID: bundleID, displayName: name, appPath: path, source: .manual)
        let base = snapshot ?? CatalogSnapshot(entries: [], sourceStates: [], generatedAt: Date())
        snapshot = AppCatalog.merge(found, into: base, at: Date())
    }
}

/// 应用规则窗口(§6.1):默认方向 + 搜索/筛选/添加 + 三列表格。
/// 即时保存,无"完成"按钮(关闭窗口或 Cmd+W 关闭,不影响服务)。
struct AppManagementView: View {
    @ObservedObject var model: AppManagementModel
    @State private var selection: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            toolbar
            Divider()
            additionBanner
            listContent
            Divider()
            footer
        }
        .frame(minWidth: 680, minHeight: 420)
        .background(.background)
        .onChange(of: model.additionTarget) { target in
            guard let target else { return }
            selection = [target]
        }
        .task(id: model.additionNotice) {
            guard model.additionNotice != nil else { return }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled {
                model.clearAdditionNotice()
            }
        }
    }

    // MARK: 默认方向 + 服务状态(§6.1)

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                DefaultDirectionPicker(
                    defaultFlip: model.appStateDefaultFlip,
                    editable: model.rulesEditable,
                    onSelect: { model.setDefaultFlip($0) }
                )
                Text("仅影响跟随默认的应用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                serviceChip
            }
            SaveFeedbackLine(saveState: model.defaultDirectionSaveState, target: .defaultDirection)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var serviceChip: some View {
        let presentation = ServicePresentation.present(model.appStatePhase)
        if presentation.primaryAction != .pauseAll {
            HStack(spacing: 5) {
                Image(systemName: presentation.symbolName)
                Text(presentation.title)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(chipColor)
            .help(presentation.statusDescription)
        }
    }

    private var chipColor: Color {
        switch model.appStatePhase {
        case .paused, .onboarding, .needsPermission: return .orange
        case .engineFailed, .rulesFailed: return .red
        case .running: return .secondary
        }
    }

    // MARK: 工具栏(§6.1/F14:搜索、筛选分层,不再竖排)

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索应用…", text: $model.searchText)
                .textFieldStyle(.plain)
                .accessibilityLabel(Text("搜索应用"))
            Picker("筛选", selection: $model.filter) {
                Text(String(format: String(localized: "单独设置 %ld"), model.customizedCount)).tag(AppManagementModel.Filter.customized)
                Text(String(format: String(localized: "全部应用 %ld"), model.totalCount)).tag(AppManagementModel.Filter.all)
            }
            .pickerStyle(.segmented)
            .frame(width: 240)
            .accessibilityLabel(Text("筛选单独设置或全部应用"))
            Button("添加应用…") { addAppPanel() }
                .accessibilityLabel(Text("通过文件选择器添加应用"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var additionBanner: some View {
        if let notice = model.additionNotice {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle").foregroundStyle(.green)
                Text(notice).font(.caption)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.4))
        }
    }

    // MARK: 列表与空态(§6.3:各空态分别处理)

    @ViewBuilder
    private var listContent: some View {
        if model.isInitialScanning {
            emptyState(icon: "arrow.triangle.2.circlepath", text: "正在查找应用…")
        } else if model.unfilteredRows.isEmpty {
            VStack(spacing: 8) {
                Text("没有发现任何应用").font(.footnote).foregroundStyle(.secondary)
                Button("手动添加…") { addAppPanel() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.rows.isEmpty {
            if model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                // 单独设置为空:所有应用都跟随默认(§6.3)
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").font(.title).foregroundStyle(.secondary)
                    Text("所有应用都跟随默认方向").font(.footnote).foregroundStyle(.secondary)
                    Button("查看全部应用") { model.filter = .all }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.title).foregroundStyle(.secondary)
                    Text(String(format: String(localized: "没有找到“%@”"), model.searchText)).font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        Button("清空搜索") { model.searchText = "" }
                        Button("添加应用…") { addAppPanel() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            table
        }
    }

    private var table: some View {
        Table(model.rows, selection: $selection) {
            TableColumn("应用") { row in
                appCell(row)
            }
            TableColumn("方向规则") { row in
                VStack(alignment: .leading, spacing: 2) {
                    RuleModeMenuPicker(
                        current: row.mode,
                        objectName: row.displayName,
                        editable: model.rulesEditable,
                        onSelect: { model.setOverride(bundleID: row.bundleID, mode: $0) }
                    )
                    if let error = model.saveErrorText(forBundle: row.bundleID) {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .help(error)
                    }
                }
            }
            .width(min: 160, ideal: 170)
            TableColumn(model.resultColumnTitle) { row in
                Text(model.effectText(for: row))
                    .font(.footnote)
                    .foregroundStyle(model.rulesEditable ? .primary : .secondary)
            }
            .width(min: 140, ideal: 150)
        }
    }

    private func appCell(_ row: AppRuleRow) -> some View {
        HStack(spacing: 8) {
            AppIconView(icons: model.iconsProvider, appPath: row.appPaths.first)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.displayName).lineLimit(1)
                if let subtitle = rowSubtitle(row) {
                    Text(subtitle)
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .help(detailTooltip(row))
        .contextMenu {
            if row.hasOverride {
                Button("改回跟随默认") {
                    model.setOverride(bundleID: row.bundleID, mode: .inherit)
                }
            }
            if model.isManual(bundleID: row.bundleID) {
                Divider()
                Button("取消手动添加…") {
                    _ = model.removeManualApp(bundleID: row.bundleID)
                }
            }
            Divider()
            Text("Bundle ID:\(row.bundleID)")
        }
    }

    /// 行副标题(§6.2/F16):重名加位置;缺失/待确认给状态;默认不再常驻 Bundle ID。
    private func rowSubtitle(_ row: AppRuleRow) -> String? {
        if let caption = row.presenceCaption { return caption }
        if model.duplicateNames.contains(row.displayName) {
            return row.appPaths.first ?? row.bundleID
        }
        return nil
    }

    /// 技术信息放可展开详情(F16):tooltip 呈现完整 Bundle ID、位置与来源。
    private func detailTooltip(_ row: AppRuleRow) -> String {
        var lines = ["Bundle ID:\(row.bundleID)"]
        if !row.appPaths.isEmpty {
            lines.append("位置:\n" + row.appPaths.joined(separator: "\n"))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 12) {
            if let notice = model.sourceNotice {
                Text(notice).font(.caption2).foregroundStyle(.orange).lineLimit(2)
            }
            if let error = model.rowActionError {
                Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2)
            }
            Spacer()
            if model.snapshot != nil {
                Text(String(format: String(localized: "共 %ld 个应用"), model.totalCount))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            ProgressView()
            Text(text).font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func addAppPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择要添加的 .app 应用包"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = model.addManualApp(url: url)
    }
}
