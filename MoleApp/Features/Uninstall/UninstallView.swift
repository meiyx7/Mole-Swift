import SwiftUI

@MainActor
final class UninstallViewModel: ObservableObject {
    @Published var apps: [AppListEntry] = []
    @Published var searchText = ""
    @Published var sortField: SortField = .size
    @Published var sortAscending = false
    @Published var isLoading = false
    @Published var error: String?

    private let service = MoleService()

    enum SortField: String, CaseIterable, Identifiable {
        case size, date, name
        var id: String { rawValue }

        var label: String {
            switch self {
            case .size: return "大小"
            case .date: return "日期"
            case .name: return "名称"
            }
        }

        var enLabel: String {
            switch self {
            case .size: return "Size"
            case .date: return "Date"
            case .name: return "Name"
            }
        }

        var icon: String {
            switch self {
            case .size: return "internaldrive"
            case .date: return "calendar"
            case .name: return "textformat"
            }
        }
    }

    /// Search-filtered and sorted view of the scanned apps.
    var displayed: [AppListEntry] {
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = text.isEmpty
            ? apps
            : apps.filter {
                $0.name.lowercased().contains(text) || $0.bundleId.lowercased().contains(text)
            }
        return filtered.sorted { lhs, rhs in
            let ordered: Bool
            switch sortField {
            case .size:
                ordered = lhs.effectiveSizeKB < rhs.effectiveSizeKB
            case .date:
                ordered = lhs.lastUsedEpoch < rhs.lastUsedEpoch
            case .name:
                ordered = lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return sortAscending ? ordered : !ordered
        }
    }

    func load() async {
        isLoading = true
        error = nil
        do {
            apps = try await service.listApps()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func removeEntry(_ entry: AppListEntry) {
        apps.removeAll { $0.id == entry.id }
    }
}

struct UninstallView: View {
    @EnvironmentObject private var service: MoleService
    @EnvironmentObject private var loc: Localization
    @StateObject private var vm = UninstallViewModel()
    @StateObject private var runner = CommandRunner()
    @State private var permanent = false
    @State private var pendingDeletion: AppListEntry?
    @State private var showConfirm = false
    @State private var feedback: FeedbackMessage?
    @State private var uninstallingPath: String?
    @State private var feedbackTask: Task<Void, Never>?

    private struct FeedbackMessage: Identifiable {
        let id = UUID()
        let isSuccess: Bool
        let text: String
    }

    var body: some View {
        if !service.isInstalled {
            CLIUnavailableView()
        } else {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header
                        if let feedback {
                            feedbackBanner(feedback)
                        }
                        if let error = vm.error {
                            EmptyStateView(systemImage: "exclamationmark.triangle",
                                           title: loc.t("无法列出应用", "Couldn't list apps"),
                                           message: error,
                                           action: (loc.t("重试", "Retry"), { Task { await vm.load() } }))
                        } else if vm.apps.isEmpty && vm.isLoading {
                            LoadingView(title: loc.t("正在扫描应用…", "Scanning applications…"))
                        } else if vm.apps.isEmpty {
                            EmptyStateView(systemImage: "app.dashed",
                                           title: loc.t("未找到应用", "No applications found"),
                                           message: loc.t("Mole 未找到可卸载的应用。", "Mole couldn't find any apps to uninstall."))
                        } else {
                            searchBar
                            listCard
                            if runner.hasOutput || runner.isRunning { consoleCard }
                        }
                    }
                }
            }
            .featurePadding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await vm.load() } } label: { Image(systemName: "arrow.clockwise") }
                        .help(loc.t("重新扫描应用", "Rescan apps"))
                }
            }
            .alert(loc.t("卸载该应用？", "Uninstall this app?"),
                   isPresented: $showConfirm,
                   presenting: pendingDeletion) { entry in
                Button(loc.t("取消", "Cancel"), role: .cancel) { pendingDeletion = nil }
                Button(loc.t("卸载", "Uninstall"), role: .destructive) {
                    runUninstall(entry)
                }
            } message: { entry in
                Text(permanent
                     ? loc.t("永久模式将立即删除\"\(entry.name)\"及其所有关联文件。此操作不可撤销。",
                             "Permanent mode removes \"\(entry.name)\" and all associated files immediately. This cannot be undone.")
                     : loc.t("Mole 将把\"\(entry.name)\"移至废纸篓并删除其支持文件。此操作不可撤销。",
                             "Mole will move \"\(entry.name)\" to Trash and remove its support files. This cannot be undone."))
            }
            .task { if vm.apps.isEmpty { await vm.load() } }
            .onReceive(NotificationCenter.default.publisher(for: .moleRefresh)) { _ in
                Task { await vm.load() }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        FeatureHeader(
            title: loc.t("卸载应用", "Uninstall Apps"),
            subtitle: loc.t("点击应用右侧的删除按钮即可卸载，支持搜索与排序。", "Click the trash button next to an app to uninstall. Search and sort supported."),
            systemImage: "trash.slash",
            trailing: AnyView(
                Toggle(loc.t("永久删除", "Permanent"), isOn: $permanent)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(.red)
                    .help(loc.t("跳过废纸篓并立即删除", "Bypass Trash and delete immediately"))
            )
        )
    }

    // MARK: - Search + Sort bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                TextField(loc.t("搜索应用", "Search apps"), text: $vm.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                if !vm.searchText.isEmpty {
                    Button { vm.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 0.5)
            )

            HStack(spacing: 4) {
                ForEach(UninstallViewModel.SortField.allCases) { field in
                    sortChip(field)
                }
            }

            Button {
                vm.sortAscending.toggle()
            } label: {
                Image(systemName: vm.sortAscending ? "arrow.up" : "arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(vm.sortAscending
                  ? loc.t("升序", "Ascending")
                  : loc.t("降序", "Descending"))
        }
    }

    private func sortChip(_ field: UninstallViewModel.SortField) -> some View {
        let isSelected = vm.sortField == field
        return Button {
            vm.sortField = field
        } label: {
            HStack(spacing: 4) {
                Image(systemName: field.icon)
                    .font(.system(size: 9))
                Text(loc.t(field.label, field.enLabel))
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(
                isSelected
                    ? Theme.accent.opacity(0.15)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .foregroundColor(isSelected ? Theme.accent : .secondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - List

    private var listCard: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                HStack {
                    Text(loc.t("\(vm.displayed.count) / \(vm.apps.count) 应用", "\(vm.displayed.count) / \(vm.apps.count) apps"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 8)

                ForEach(Array(vm.displayed.enumerated()), id: \.element.id) { index, entry in
                    row(entry)
                    if index < vm.displayed.count - 1 {
                        Divider().padding(.leading, 52)
                    }
                }
            }
        }
    }

    private func row(_ entry: AppListEntry) -> some View {
        let isUninstalling = uninstallingPath == entry.path
        return HStack(spacing: 12) {
            appIcon(for: entry)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if entry.isHomebrew {
                        Text("brew")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.15), in: Capsule())
                            .foregroundColor(.orange)
                    }
                }
                Text(entry.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color.gray.opacity(0.55))
                    .lineLimit(1).truncationMode(.middle)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 1) {
                Text(entry.size)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(entry.effectiveSizeKB > 0 ? .primary : .secondary)
                Text(lastUsedText(entry))
                    .font(.system(size: 10, design: .rounded))
                    .foregroundColor(Color.gray.opacity(0.6))
            }
            .frame(minWidth: 70, alignment: .trailing)

            if isUninstalling {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 26, height: 26)
            } else {
                Button {
                    guard !runner.isRunning else { return }
                    pendingDeletion = entry
                    showConfirm = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.red.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
                .help(loc.t("卸载\"\(entry.name)\"", "Uninstall \"\(entry.name)\""))
                .disabled(runner.isRunning)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(
            isUninstalling
                ? Theme.accent.opacity(0.04)
                : Color.clear
        )
        .contentShape(Rectangle())
    }

    // MARK: - Helpers

    private func appIcon(for entry: AppListEntry) -> some View {
        let icon = NSWorkspace.shared.icon(forFile: entry.path.isEmpty ? "/" : entry.path)
        return Image(nsImage: icon)
            .resizable()
            .frame(width: 30, height: 30)
    }

    private func lastUsedText(_ entry: AppListEntry) -> String {
        guard entry.lastUsedEpoch > 0 else { return loc.t("未知", "Unknown") }
        let date = Date(timeIntervalSince1970: TimeInterval(entry.lastUsedEpoch))
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Feedback

    private func feedbackBanner(_ msg: FeedbackMessage) -> some View {
        HStack(spacing: 8) {
            Image(systemName: msg.isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(msg.isSuccess ? .green : .red)
            Text(msg.text)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(2)
            Spacer()
            Button {
                dismissFeedback()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(
            (msg.isSuccess ? Color.green : Color.red).opacity(0.10),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .onAppear {
            if msg.isSuccess {
                feedbackTask?.cancel()
                feedbackTask = Task {
                    try? await Task.sleep(nanoseconds: 3_500_000_000)
                    if !Task.isCancelled {
                        await MainActor.run { dismissFeedback() }
                    }
                }
            }
        }
    }

    private func dismissFeedback() {
        feedbackTask?.cancel()
        feedback = nil
    }

    // MARK: - Console

    private var consoleCard: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(runner.isRunning ? loc.t("正在卸载…", "Uninstalling…") : loc.t("输出", "Output"), systemImage: "terminal")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if let code = runner.exitCode {
                        Text(code == 0 ? loc.t("✓ 完成", "✓ done") : "exit \(code)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(code == 0 ? .green : .red)
                    }
                }
                ConsoleOutputView(lines: runner.lines)
                    .frame(minHeight: 140, maxHeight: 260)
            }
        }
    }

    // MARK: - Actions

    private func runUninstall(_ entry: AppListEntry) {
        let names = [entry.uninstallName]
        let mode = permanent ? "permanent" : "trash"
        DebugLog.append("""
        [UNINSTALL] target=\(entry.name) uninstall_name=\(entry.uninstallName) \
        bundle_id=\(entry.bundleId) path=\(entry.path) mode=\(mode)
        """)
        uninstallingPath = entry.path
        Task {
            let code = await runner.runAwaited { onLine in
                try await service.uninstall(apps: names, permanent: permanent, onLine: onLine)
            }
            uninstallingPath = nil
            let tail = runner.lines.suffix(8).map { $0.text }.joined(separator: "\n")
            DebugLog.append("""
            [UNINSTALL RESULT] target=\(entry.name) exit_code=\(code) \
            line_count=\(runner.lines.count)
            --- tail ---
            \(tail)
            """)

            if runner.succeeded {
                vm.removeEntry(entry)
                feedback = FeedbackMessage(
                    isSuccess: true,
                    text: loc.t("已卸载\"\(entry.name)\"。", "Uninstalled \"\(entry.name)\".")
                )
            } else {
                let detail = runner.error ?? (code == 0
                    ? loc.t("未输出错误信息，请查看日志。", "No error output; see log for details.")
                    : loc.t("卸载失败（exit \(code)）。", "Uninstall failed (exit \(code))."))
                feedback = FeedbackMessage(isSuccess: false, text: detail)
            }
        }
    }
}
