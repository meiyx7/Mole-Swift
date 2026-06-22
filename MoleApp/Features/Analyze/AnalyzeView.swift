import SwiftUI

@MainActor
final class AnalyzeViewModel: ObservableObject {
    @Published var result: AnalyzeResult?
    /// Stack of (displayName, fullPath) tuples for breadcrumb navigation.
    /// Each entry is a level the user has drilled into.
    @Published var pathStack: [(name: String, path: String)] = []
    @Published var isLoading = false
    @Published var error: String?

    /// Multi-select state for ad hoc Trash cleanup. Mirrors the TUI's
    /// `multiSelected` map in cmd/analyze/model.go. Selection is scoped to
    /// the currently displayed entries; drilling into a subdir clears it.
    @Published var selectedPaths: Set<String> = []
    @Published var largeSelectedPaths: Set<String> = []

    /// Filter text for the breakdown list. Mirrors the TUI's `/` filter.
    @Published var entryFilter: String = ""

    /// Active tab: breakdown / large files.
    enum Tab: String, CaseIterable, Identifiable {
        case breakdown
        case largeFiles
        var id: String { rawValue }
    }
    @Published var tab: Tab = .breakdown

    /// Delete flow state.
    @Published var deleteInProgress = false
    @Published var deleteDone = 0
    @Published var deleteTotal = 0
    @Published var deleteResult: DeleteSummary?
    @Published var showDeleteConfirm = false

    /// Scan progress state. The CLI's JSON mode is one-shot (no streaming
    /// progress), so we surface a lightweight in-flight indicator with the
    /// current path being scanned and a cancel affordance. The cancel
    /// terminates the underlying `mo analyze` process via CLIBridge.
    @Published var scanPath: String = ""

    /// Reference to localization for error messages.
    var loc: Localization?

    /// Currently in-flight scan task, retained so we can cancel it.
    private var scanTask: Task<Void, Never>?

    var currentPath: String { pathStack.last?.path ?? "" }
    var isOverview: Bool { pathStack.isEmpty }

    struct DeleteSummary: Identifiable {
        let id = UUID()
        let success: Bool
        let message: String
        let deletedCount: Int
        let freedBytes: Int64
    }

    func loadOverview(service: MoleService) async {
        pathStack.removeAll()
        await fetch(service: service, path: nil)
    }

    func drill(service: MoleService, into path: String, name: String) async {
        // Prevent drilling while a scan is already running (avoids race
        // conditions where rapid clicks pile up breadcrumb entries).
        guard !isLoading else { return }
        // Prevent drilling into the same path (avoids duplicate breadcrumb entries).
        guard path != currentPath else { return }
        clearSelection()
        pathStack.append((name: name, path: path))
        await fetch(service: service, path: path)
    }

    func goBack(service: MoleService) async {
        if !pathStack.isEmpty {
            clearSelection()
            pathStack.removeLast()
            await fetch(service: service, path: pathStack.isEmpty ? nil : currentPath)
        }
    }

    /// Navigate to a specific level in the path stack (0 = overview).
    /// Removes everything after the given index.
    func navigate(service: MoleService, toLevel level: Int) async {
        guard !isLoading else { return }
        if level >= pathStack.count { return }
        clearSelection()
        if level == 0 {
            await loadOverview(service: service)
        } else {
            pathStack = Array(pathStack.prefix(level))
            await fetch(service: service, path: currentPath)
        }
    }

    func refresh(service: MoleService) async {
        clearSelection()
        await fetch(service: service, path: isOverview ? nil : currentPath)
    }

    /// Cancel any in-flight scan. Mirrors the TUI's Esc-to-cancel behaviour.
    func cancelScan() {
        scanTask?.cancel()
    }

    private func clearSelection() {
        selectedPaths.removeAll()
        largeSelectedPaths.removeAll()
        entryFilter = ""
        tab = .breakdown
    }

    private func fetch(service: MoleService, path: String?) async {
        // Cancel any prior scan before starting a new one. This keeps at
        // most one `mo analyze` process in flight, matching the TUI's
        // single-scan-at-a-time invariant.
        scanTask?.cancel()

        isLoading = true
        error = nil
        scanPath = path ?? (loc?.t("主目录", "Home") ?? "Home")

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let scanned: AnalyzeResult
                if let path {
                    scanned = try await service.analyze(path: path)
                } else {
                    scanned = try await service.analyzeOverview()
                }
                // If a newer scan was started while this one was in flight,
                // discard the stale result.
                if Task.isCancelled { return }
                self.result = scanned
            } catch is CancellationError {
                // User cancelled; keep the previous result visible if any.
                if self.result == nil {
                    self.error = self.loc?.t("已取消扫描", "Scan cancelled")
                        ?? "Scan cancelled"
                }
            } catch {
                // Provide a user-friendly message for timeout errors
                let nsError = error as NSError
                if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(SIGTERM) {
                    self.error = self.loc?.t("扫描超时，该目录可能过大。请尝试扫描更小的子目录。",
                                             "Scan timed out. The directory may be too large. Try scanning a smaller subdirectory.")
                        ?? "Scan timed out. The directory may be too large."
                } else {
                    self.error = error.localizedDescription
                }
                // Roll back the breadcrumb so the user isn't trapped in a
                // level that failed to load.
                if path != nil && !self.pathStack.isEmpty {
                    self.pathStack.removeLast()
                }
            }
            self.isLoading = false
            self.scanPath = ""
        }
        scanTask = task
        await task.value
    }

    // MARK: - Selection helpers

    /// Total size of currently selected entries (breakdown + large files).
    func selectedTotalSize() -> Int64 {
        var total: Int64 = 0
        if let entries = result?.entries {
            for e in entries where selectedPaths.contains(e.path) {
                total += e.size
            }
        }
        if let large = result?.largeFiles {
            for f in large where largeSelectedPaths.contains(f.path) {
                total += f.size
            }
        }
        return total
    }

    func selectedCount() -> Int {
        selectedPaths.count + largeSelectedPaths.count
    }

    // MARK: - Delete (P0)

    /// Move all selected paths to Trash. Mirrors the TUI's `deleteMultiplePathsCmd`
    /// in cmd/analyze/delete.go: deeper paths first, Trash routing, protected
    /// path rejection, operation log.
    func deleteSelected() {
        guard let result else { return }
        var sizes: [String: Int64] = [:]
        var paths: [String] = []
        for e in result.entries where selectedPaths.contains(e.path) {
            sizes[e.path] = e.size
            paths.append(e.path)
        }
        for f in result.largeFiles ?? [] where largeSelectedPaths.contains(f.path) {
            sizes[f.path] = f.size
            paths.append(f.path)
        }
        guard !paths.isEmpty else { return }

        deleteInProgress = true
        deleteDone = 0
        deleteTotal = paths.count
        deleteResult = nil

        let outcomes = AnalyzeDeleter.trashPaths(paths, sizes: sizes) { [weak self] done in
            self?.deleteDone = done
        }

        var deletedCount = 0
        var freedBytes: Int64 = 0
        var errors: [String] = []
        var failedPaths: Set<String> = []

        for outcome in outcomes {
            if outcome.success {
                deletedCount += 1
                freedBytes += outcome.size
            } else {
                failedPaths.insert(outcome.path)
                errors.append("\(outcome.name): \(outcome.message)")
            }
        }

        deleteInProgress = false

        if errors.isEmpty {
            deleteResult = DeleteSummary(
                success: true,
                message: loc?.t("已将 \(deletedCount) 项移至废纸篓，释放 \(ByteFormatter.bytes(freedBytes))。",
                               "Moved \(deletedCount) items to Trash, freed \(ByteFormatter.bytes(freedBytes)).")
                    ?? "Moved \(deletedCount) items to Trash.",
                deletedCount: deletedCount,
                freedBytes: freedBytes
            )
        } else {
            let errMsg = errors.prefix(3).joined(separator: "; ")
            deleteResult = DeleteSummary(
                success: deletedCount > 0,
                message: loc?.t("移至废纸篓 \(deletedCount) 项，\(errors.count) 项失败：\(errMsg)",
                               "Moved \(deletedCount) to Trash, \(errors.count) failed: \(errMsg)")
                    ?? "Moved \(deletedCount), \(errors.count) failed.",
                deletedCount: deletedCount,
                freedBytes: freedBytes
            )
        }

        // Remove successfully-deleted paths from selection and from the
        // current result so the UI reflects the new state without a rescan.
        let deletedPaths = Set(paths.filter { !failedPaths.contains($0) })
        selectedPaths.subtract(deletedPaths)
        largeSelectedPaths.subtract(deletedPaths)

        if var r = self.result {
            r.entries = r.entries.filter { !deletedPaths.contains($0.path) }
            // Recompute total size after deletion so percentages stay sane.
            r.totalSize = r.entries.reduce(Int64(0)) { $0 + $1.size }
            if var large = r.largeFiles {
                large = large.filter { !deletedPaths.contains($0.path) }
                r.largeFiles = large
            }
            self.result = r
        }
    }
}

struct AnalyzeView: View {
    @StateObject private var vm = AnalyzeViewModel()
    @EnvironmentObject private var service: MoleService
    @EnvironmentObject private var loc: Localization

    var body: some View {
        Group {
            if !service.isInstalled {
                CLIUnavailableView()
            } else if let result = vm.result {
                content(result)
            } else if vm.isLoading {
                LoadingView(title: loc.t("正在扫描磁盘占用…", "Scanning disk usage…"))
            } else if let error = vm.error {
                EmptyStateView(systemImage: "exclamationmark.triangle",
                               title: loc.t("扫描失败", "Scan failed"),
                               message: error,
                               action: (loc.t("重试", "Retry"), { Task { await vm.refresh(service: service) } }))
            } else {
                EmptyStateView(systemImage: "chart.pie",
                               title: loc.t("磁盘分析", "Disk Explorer"),
                               message: loc.t("可视化查看 Mac 上的空间占用。", "Visualise what's taking up space on your Mac."),
                               action: (loc.t("扫描主目录", "Scan Home folder"), { Task { await vm.loadOverview(service: service) } }))
            }
        }
        .featurePadding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .toolbar {
            if !vm.pathStack.isEmpty {
                ToolbarItem(placement: .navigation) {
                    Button { Task { await vm.goBack(service: service) } } label: {
                        Image(systemName: "chevron.left")
                    }
                    .help(loc.t("返回", "Back"))
                }
            }
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 4) {
                    if vm.isLoading {
                        Button { vm.cancelScan() } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.red)
                        }
                        .help(loc.t("取消扫描", "Cancel scan"))
                    }
                    Button { Task { await vm.refresh(service: service) } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(vm.isLoading)
                    .help(loc.t("重新扫描", "Rescan"))
                }
            }
        }
        .task {
            vm.loc = loc
            if vm.result == nil { await vm.loadOverview(service: service) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .moleRefresh)) { _ in
            Task { await vm.refresh(service: service) }
        }
    }

    @ViewBuilder
    private func content(_ result: AnalyzeResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(result)
                if !vm.isOverview {
                    breadcrumbBar
                }
                summaryRow(result)
                if vm.isLoading {
                    scanProgressBar
                }
                tabPicker
                switch vm.tab {
                case .breakdown:
                    filterBar
                    entriesSection(result)
                case .largeFiles:
                    largeFilesSection(result.largeFiles ?? [])
                }
                if let summary = vm.deleteResult {
                    deleteResultBanner(summary)
                }
            }
            .overlay {
                if vm.deleteInProgress {
                    ZStack {
                        Color.black.opacity(0.15)
                        deleteProgressCard
                    }
                    .ignoresSafeArea()
                    .transition(.opacity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: vm.isLoading)
        .animation(.easeInOut(duration: 0.15), value: vm.tab)
        .alert(loc.t("移至废纸篓？", "Move to Trash?"),
               isPresented: $vm.showDeleteConfirm) {
            Button(loc.t("取消", "Cancel"), role: .cancel) {}
            Button(loc.t("移至废纸篓", "Move to Trash"), role: .destructive) {
                vm.deleteSelected()
            }
        } message: {
            Text(loc.t(
                "将把 \(vm.selectedCount()) 项移至废纸篓，共约 \(ByteFormatter.bytes(vm.selectedTotalSize()))。可从废纸篓恢复。",
                "Will move \(vm.selectedCount()) items to Trash, totaling \(ByteFormatter.bytes(vm.selectedTotalSize())). Recoverable from Trash."
            ))
        }
    }

    /// Clickable breadcrumb navigation bar. Each segment navigates to
    /// that directory level. The last segment (current dir) is not clickable.
    private var breadcrumbBar: some View {
        HStack(spacing: 4) {
            // Home / Overview button
            Button {
                Task { await vm.navigate(service: service, toLevel: 0) }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "house.fill")
                        .font(.system(size: 10))
                    Text(loc.t("主目录", "Home"))
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(Theme.accent)
            }
            .buttonStyle(.plain)

            ForEach(vm.pathStack.indices, id: \.self) { i in
                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                let isLast = i == vm.pathStack.count - 1
                let name = vm.pathStack[i].name
                if isLast {
                    Text(name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Button {
                        Task { await vm.navigate(service: service, toLevel: i + 1) }
                    } label: {
                        Text(name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Theme.accent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private func header(_ result: AnalyzeResult) -> some View {
        FeatureHeader(
            title: loc.t("磁盘分析", "Disk Explorer"),
            subtitle: vm.isOverview
                ? loc.t("主目录概览", "Overview of your Home folder")
                : loc.t("子目录分析", "Subdirectory analysis"),
            systemImage: "chart.pie",
            trailing: AnyView(
                Text(loc.t("\((result.totalFiles ?? 0) > 0 ? "\(result.totalFiles!) 项 · " : "")\(ByteFormatter.bytes(result.totalSize))", "\((result.totalFiles ?? 0) > 0 ? "\(result.totalFiles!) items · " : "")\(ByteFormatter.bytes(result.totalSize))"))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.secondary)
            )
        )
    }

    private func summaryRow(_ result: AnalyzeResult) -> some View {
        let cleanable = result.entries.filter { $0.cleanable ?? false }.reduce(Int64(0)) { $0 + $1.size }
        return HStack(spacing: 14) {
            StatTile(title: loc.t("总大小", "Total Size"), value: ByteFormatter.bytes(result.totalSize),
                     systemImage: "externaldrive", tone: .neutral)
            StatTile(title: loc.t("项目", "Items"), value: (result.totalFiles ?? 0) > 0 ? "\(result.totalFiles!)" : "\(result.entries.count)",
                     systemImage: "doc.on.doc", tone: .neutral)
            StatTile(title: loc.t("可清理", "Cleanable"), value: ByteFormatter.bytes(cleanable),
                     systemImage: "sparkles", tone: cleanable > 0 ? .good : .neutral)
            StatTile(title: loc.t("大文件", "Large Files"), value: "\(result.largeFiles?.count ?? 0)",
                     systemImage: "exclamationmark.triangle", tone: (result.largeFiles?.isEmpty ?? true) ? .neutral : .warn)
        }
    }

    /// In-scan progress bar. The CLI's JSON mode is one-shot, so we show
    /// the path being scanned plus a cancel button. Mirrors the TUI's
    /// scan header in cmd/analyze/view.go (spinner + current path).
    private var scanProgressBar: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(loc.t("正在扫描…", "Scanning…"))
                    .font(.system(size: 12, weight: .medium))
                Text(vm.scanPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Button(loc.t("取消", "Cancel")) { vm.cancelScan() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Tab picker (P2)

    private var tabPicker: some View {
        HStack(spacing: 6) {
            tabButton(.breakdown,
                      label: loc.t("明细", "Breakdown"),
                      icon: "list.bullet",
                      count: vm.result?.entries.count)
            tabButton(.largeFiles,
                      label: loc.t("大文件", "Large Files"),
                      icon: "doc.text.magnifyingglass",
                      count: vm.result?.largeFiles?.count)
            Spacer(minLength: 0)
            if vm.selectedCount() > 0 {
                Button {
                    vm.showDeleteConfirm = true
                } label: {
                    Label(loc.t("移至废纸篓 (\(vm.selectedCount()))", "Trash (\(vm.selectedCount()))"),
                          systemImage: "trash")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(PrimaryButtonStyle(tint: Theme.color(for: .critical)))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
    }

    private func tabButton(_ tab: AnalyzeViewModel.Tab, label: String, icon: String, count: Int?) -> some View {
        let active = vm.tab == tab
        return Button {
            vm.tab = tab
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11))
                Text(label).font(.system(size: 12, weight: active ? .semibold : .regular))
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(.secondary)
                }
            }
            .foregroundColor(active ? Theme.accent : .secondary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(active ? Theme.accent.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Filter bar (P2)

    private var filterBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11)).foregroundColor(.secondary)
            TextField(loc.t("过滤当前目录", "Filter current directory"),
                      text: $vm.entryFilter)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .autocorrectionDisabled(true)
            if !vm.entryFilter.isEmpty {
                Button {
                    vm.entryFilter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            Divider().frame(height: 14)
            Button {
                let visible = filteredEntries
                let visiblePaths = Set(visible.map { $0.path })
                if visiblePaths.isSubset(of: vm.selectedPaths) {
                    vm.selectedPaths.subtract(visiblePaths)
                } else {
                    vm.selectedPaths.formUnion(visiblePaths)
                }
            } label: {
                Text(loc.t("全选", "Select All"))
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain).foregroundColor(Theme.accent)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
    }

    private var filteredEntries: [AnalyzeEntry] {
        guard let entries = vm.result?.entries else { return [] }
        let sorted = entries.sorted { $0.size > $1.size }
        let needle = vm.entryFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return sorted }
        return sorted.filter { $0.name.lowercased().contains(needle) }
    }

    private func entriesSection(_ result: AnalyzeResult) -> some View {
        Card(padding: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(loc.t("明细", "Breakdown"))
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if vm.selectedCount() > 0 {
                        Text(loc.t("已选 \(ByteFormatter.bytes(vm.selectedTotalSize()))",
                                   "Selected \(ByteFormatter.bytes(vm.selectedTotalSize()))"))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundColor(Theme.color(for: .good))
                    }
                }
                .padding(.horizontal, 6).padding(.bottom, 4)

                let max = result.entries.map { $0.size }.max() ?? 1
                let visible = filteredEntries
                if visible.isEmpty {
                    Text(vm.entryFilter.isEmpty
                         ? loc.t("空目录", "Empty directory")
                         : loc.t("无匹配项", "No matches"))
                        .font(.system(size: 12)).foregroundColor(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 12)
                } else {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { idx, entry in
                        entryRow(entry, max: max, total: result.totalSize)
                        if idx < visible.count - 1 {
                            Divider().padding(.horizontal, 6)
                        }
                    }
                }
            }
        }
    }

    private func entryRow(_ entry: AnalyzeEntry, max: Int64, total: Int64) -> some View {
        let fraction = total > 0 ? Double(entry.size) / Double(total) * 100 : 0
        let width = max > 0 ? CGFloat(entry.size) / CGFloat(max) : 0
        let tone: StatusTone = (entry.cleanable ?? false) ? .good : ((entry.insight ?? false) ? .warn : .neutral)
        let isSelected = vm.selectedPaths.contains(entry.path)
        return HStack(spacing: 10) {
            // Selection checkbox (P0). Click toggles selection without
            // drilling, so the user can batch-select cleanable dirs.
            Button {
                if isSelected { vm.selectedPaths.remove(entry.path) }
                else { vm.selectedPaths.insert(entry.path) }
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundColor(isSelected ? Theme.accent : .secondary)
            }
            .buttonStyle(.plain)

            Button {
                if entry.isDir && !vm.isLoading {
                    Task { await vm.drill(service: service, into: entry.path, name: entry.name) }
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: entry.isDir ? "folder.fill" : "doc")
                        .foregroundColor(entry.isDir ? Theme.accent : .secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            if entry.cleanable ?? false {
                                badge(loc.t("可清理", "Cleanable"), tone: .good)
                            } else if entry.insight ?? false {
                                badge(loc.t("洞察", "Insight"), tone: .warn)
                            }
                            Spacer()
                            Text(ByteFormatter.bytes(entry.size))
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                            Text(ByteFormatter.percent(fraction))
                                .font(.system(size: 11, design: .rounded))
                                .foregroundColor(.secondary)
                                .frame(width: 48, alignment: .trailing)
                            if entry.isDir {
                                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundColor(Color.gray.opacity(0.5))
                            }
                        }
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Theme.color(for: tone))
                                .frame(width: width * geo.size.width, height: 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(height: 6)
                        if let lastAccess = entry.lastAccess, !lastAccess.isEmpty {
                            Text(loc.t("最近访问 ", "Last access ") + lastAccess)
                                .font(.system(size: 10, design: .rounded)).foregroundColor(Color.gray.opacity(0.5))
                        }
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(isSelected ? Theme.accent.opacity(0.05) : Color.clear)
        .contentShape(Rectangle())
        // P3: context menu for row actions (Finder reveal / preview /
        // copy path / single-item delete). Mirrors the TUI's O/P/F/⌫ keys.
        // Attached to the outer HStack so right-click works anywhere on the row.
        .contextMenu {
            Button {
                revealInFinder(entry.path)
            } label: {
                Label(loc.t("在 Finder 中显示", "Reveal in Finder"), systemImage: "folder")
            }
            Button {
                previewFile(entry.path)
            } label: {
                Label(loc.t("预览", "Quick Look"), systemImage: "eye")
            }
            Button {
                copyPath(entry.path)
            } label: {
                Label(loc.t("复制路径", "Copy Path"), systemImage: "doc.on.doc")
            }
            Divider()
            Button(role: .destructive) {
                vm.selectedPaths.insert(entry.path)
                vm.showDeleteConfirm = true
            } label: {
                Label(loc.t("移至废纸篓", "Move to Trash"), systemImage: "trash")
            }
        }
    }

    private func badge(_ text: String, tone: StatusTone) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .textCase(.uppercase)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Theme.color(for: tone).opacity(0.18), in: Capsule())
            .foregroundColor(Theme.color(for: tone))
    }

    // MARK: - Large files (P2: full list, selectable, with actions)

    private func largeFilesSection(_ files: [AnalyzeFileEntry]) -> some View {
        Card(padding: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label(loc.t("大文件", "Large Files"), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if !files.isEmpty {
                        Text(loc.t("共 \(files.count) 项", "\(files.count) total"))
                            .font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    if vm.selectedCount() > 0 {
                        Text(loc.t("已选 \(ByteFormatter.bytes(vm.selectedTotalSize()))",
                                   "Selected \(ByteFormatter.bytes(vm.selectedTotalSize()))"))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundColor(Theme.color(for: .good))
                    }
                }
                .padding(.horizontal, 6).padding(.bottom, 4)

                if files.isEmpty {
                    Text(loc.t("未发现大文件", "No large files found"))
                        .font(.system(size: 12)).foregroundColor(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 12)
                } else {
                    let max = files.map { $0.size }.max() ?? 1
                    ForEach(Array(files.enumerated()), id: \.element.id) { idx, file in
                        largeFileRow(file, max: max)
                        if idx < files.count - 1 {
                            Divider().padding(.horizontal, 6)
                        }
                    }
                }
            }
        }
    }

    private func largeFileRow(_ file: AnalyzeFileEntry, max: Int64) -> some View {
        let isSelected = vm.largeSelectedPaths.contains(file.path)
        let width = max > 0 ? CGFloat(file.size) / CGFloat(max) : 0
        return HStack(spacing: 10) {
            Button {
                if isSelected { vm.largeSelectedPaths.remove(file.path) }
                else { vm.largeSelectedPaths.insert(file.path) }
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundColor(isSelected ? Theme.accent : .secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "doc.fill").foregroundColor(.orange).frame(width: 18)
                    Text(file.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(ByteFormatter.bytes(file.size))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .frame(width: 80, alignment: .trailing)
                }
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.orange.opacity(0.7))
                        .frame(width: width * geo.size.width, height: 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 5)
                Text(displayPath(file.path))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .background(isSelected ? Theme.accent.opacity(0.05) : Color.clear)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                revealInFinder(file.path)
            } label: {
                Label(loc.t("在 Finder 中显示", "Reveal in Finder"), systemImage: "folder")
            }
            Button {
                previewFile(file.path)
            } label: {
                Label(loc.t("预览", "Quick Look"), systemImage: "eye")
            }
            Button {
                copyPath(file.path)
            } label: {
                Label(loc.t("复制路径", "Copy Path"), systemImage: "doc.on.doc")
            }
            Divider()
            Button(role: .destructive) {
                vm.largeSelectedPaths.insert(file.path)
                vm.showDeleteConfirm = true
            } label: {
                Label(loc.t("移至废纸篓", "Move to Trash"), systemImage: "trash")
            }
        }
    }

    // MARK: - Delete progress & result (P0)

    private var deleteProgressCard: some View {
        VStack(spacing: 10) {
            ProgressView(value: Double(vm.deleteDone),
                         total: Double(max(vm.deleteTotal, 1)))
                .frame(width: 240)
            Text(loc.t("正在移至废纸篓 \(vm.deleteDone) / \(vm.deleteTotal)",
                       "Moving to Trash \(vm.deleteDone) / \(vm.deleteTotal)"))
                .font(.system(size: 12, weight: .medium))
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func deleteResultBanner(_ summary: AnalyzeViewModel.DeleteSummary) -> some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: summary.success ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(Theme.color(for: summary.success ? .good : .critical))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.success ? loc.t("清理完成", "Trash complete") : loc.t("部分失败", "Partial failure"))
                            .font(.system(size: 14, weight: .semibold))
                        Text(summary.message)
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    Spacer()
                }
                if summary.success {
                    HStack(spacing: 8) {
                        Button {
                            let trashPath = NSString(string: "~/.Trash").expandingTildeInPath
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: trashPath)])
                        } label: {
                            Label(loc.t("打开废纸篓", "Open Trash"), systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        Button { vm.deleteResult = nil } label: {
                            Label(loc.t("关闭", "Dismiss"), systemImage: "xmark")
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    Button { vm.deleteResult = nil } label: {
                        Label(loc.t("关闭", "Dismiss"), systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: - Row actions (P3)

    private func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func previewFile(_ path: String) {
        // Quick Look via the system default handler. For directories this
        // opens Finder; for files it triggers the preview app.
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    private func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
