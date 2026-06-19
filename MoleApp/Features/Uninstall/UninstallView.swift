import SwiftUI

@MainActor
final class UninstallViewModel: ObservableObject {
    @Published var apps: [AppListEntry] = []
    @Published var selected: Set<String> = []
    @Published var searchText = ""
    @Published var isLoading = false
    @Published var error: String?

    private let service = MoleService()

    var filtered: [AppListEntry] {
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return apps }
        return apps.filter {
            $0.name.lowercased().contains(text) || $0.bundleId.lowercased().contains(text)
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

    func toggle(_ entry: AppListEntry) {
        if selected.contains(entry.id) { selected.remove(entry.id) }
        else { selected.insert(entry.id) }
    }

    func selectAll() {
        selected = Set(filtered.map { $0.id })
    }

    func clearSelection() {
        selected.removeAll()
    }
}

struct UninstallView: View {
    @EnvironmentObject private var service: MoleService
    @EnvironmentObject private var loc: Localization
    @StateObject private var vm = UninstallViewModel()
    @StateObject private var runner = CommandRunner()
    @State private var permanent = false
    @State private var showConfirm = false

    var body: some View {
        if !service.isInstalled {
            CLIUnavailableView()
        } else {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
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
            .alert(loc.t("卸载 \(vm.selected.count) 个应用？", "Uninstall \(vm.selected.count) app\(vm.selected.count == 1 ? "" : "s")?"), isPresented: $showConfirm) {
                Button(loc.t("取消", "Cancel"), role: .cancel) {}
                Button(loc.t("卸载", "Uninstall"), role: .destructive) { runUninstall() }
            } message: {
                Text(permanent
                     ? loc.t("永久模式将立即删除应用及其所有关联文件。此操作不可撤销。", "Permanent mode removes apps and all associated files immediately. This cannot be undone.")
                     : loc.t("Mole 将把所选应用移至废纸篓并删除其支持文件。此操作不可撤销。", "Mole will move the selected apps to Trash and remove their support files. This cannot be undone."))
            }
            .task { if vm.apps.isEmpty { await vm.load() } }
            .onReceive(NotificationCenter.default.publisher(for: .moleRefresh)) { _ in
                Task { await vm.load() }
            }
        }
    }

    private var header: some View {
        FeatureHeader(
            title: loc.t("卸载应用", "Uninstall Apps"),
            subtitle: loc.t("彻底移除应用程序，包括残留的支持文件。", "Remove applications completely, including leftover support files."),
            systemImage: "trash.slash",
            trailing: AnyView(
                HStack(spacing: 8) {
                    Toggle(loc.t("永久删除", "Permanent"), isOn: $permanent)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .help(loc.t("跳过废纸篓并立即删除", "Bypass Trash and delete immediately"))
                    Button {
                        showConfirm = true
                    } label: {
                        Label(loc.t("卸载", "Uninstall"), systemImage: "trash")
                    }
                    .buttonStyle(PrimaryButtonStyle(tint: .red))
                    .disabled(vm.selected.isEmpty || runner.isRunning)
                }
            )
        )
    }

    private var listCard: some View {
        Card(padding: 8) {
            VStack(spacing: 0) {
                HStack {
                    Text(loc.t("\(vm.apps.count) 应用 · \(vm.selected.count) 已选", "\(vm.apps.count) apps · \(vm.selected.count) selected"))
                        .font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                    Spacer()
                    Button(loc.t("全选", "Select All")) { vm.selectAll() }.buttonStyle(.borderless).font(.system(size: 11))
                    Button(loc.t("清空", "Clear")) { vm.clearSelection() }.buttonStyle(.borderless).font(.system(size: 11))
                }
                .padding(.horizontal, 8).padding(.vertical, 8)

                Divider()

                ForEach(vm.filtered) { entry in
                    row(entry)
                    if entry.id != vm.filtered.last?.id { Divider() }
                }
            }
        }
    }

    private func row(_ entry: AppListEntry) -> some View {
        let isSelected = vm.selected.contains(entry.id)
        return Button { vm.toggle(entry) } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? Theme.accent : .secondary)
                    .font(.system(size: 16))
                appIcon(for: entry)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        if entry.isHomebrew {
                            Text(loc.t("Homebrew", "Homebrew"))
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.orange.opacity(0.18), in: Capsule())
                                .foregroundColor(.orange)
                        }
                    }
                    Text(entry.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color.gray.opacity(0.5))
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text(entry.size)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func appIcon(for entry: AppListEntry) -> some View {
        let url = URL(fileURLWithPath: entry.path)
        let icon = NSWorkspace.shared.icon(forFile: entry.path.isEmpty ? "/" : entry.path)
        return Image(nsImage: icon)
            .resizable()
            .frame(width: 28, height: 28)
            .help(url.lastPathComponent)
    }

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
                    .frame(minHeight: 160, maxHeight: 280)
            }
        }
    }

    private func runUninstall() {
        let names = vm.apps.filter { vm.selected.contains($0.id) }.map { $0.uninstallName }
        Task {
            await runner.run { onLine in
                try await service.uninstall(apps: names, permanent: permanent, onLine: onLine)
            }
            vm.selected.removeAll()
            await vm.load()
        }
    }
}
