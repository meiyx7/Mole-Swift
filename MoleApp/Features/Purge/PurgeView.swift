import SwiftUI

struct PurgeView: View {
    @EnvironmentObject private var service: MoleService
    @EnvironmentObject private var loc: Localization
    @State private var phase: CleanupPhase = .idle
    @State private var artifacts: [PurgeScanner.FoundArtifact] = []
    @State private var selectedIDs: Set<String> = []
    @State private var showConfirm = false
    @State private var scanError: String?
    @State private var deleteResult: DeleteResult?
    @State private var progressDone = 0
    @State private var progressTotal = 0
    /// Optional type filter. nil = show all. Bound to the filter Picker.
    @State private var typeFilter: String?
    /// True when the last scan fell back to the local Swift scanner.
    /// Shown as a subtle hint so the user knows the CLI scan failed.
    @State private var usedFallback = false
    @State private var fallbackReason: String?
    /// Configured purge scan paths, loaded from `~/.config/mole/purge_paths`.
    /// Empty when the file doesn't exist (CLI falls back to defaults).
    @State private var configuredScanPaths: [String] = []
    @State private var usingDefaultPaths = true

    private struct DeleteResult: Identifiable {
        let id = UUID()
        let success: Bool
        let message: String
        let deletedCount: Int
        let freedBytes: Int64
    }

    /// Artifacts after applying the type filter. This is what the list shows.
    private var filteredArtifacts: [PurgeScanner.FoundArtifact] {
        guard let filter = typeFilter else { return artifacts }
        return artifacts.filter { $0.artifactType == filter }
    }

    /// Distinct artifact types present in the current scan, for the filter.
    private var availableTypes: [String] {
        Array(Set(artifacts.map { $0.artifactType })).sorted()
    }

    var totalSelectedSize: Int64 {
        artifacts.filter { selectedIDs.contains($0.id) }.reduce(0) { $0 + $1.sizeBytes }
    }

    var body: some View {
        if !service.isInstalled {
            CLIUnavailableView()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    stepGuide
                    categoriesCard
                    scanPathsCard
                    if phase == .scanned {
                        artifactsList
                    } else if phase == .scanning {
                        scanningView
                    } else if phase == .error {
                        errorView
                    } else if phase == .running {
                        runningView
                    }
                    if let result = deleteResult {
                        resultBanner(result)
                    }
                }
            }
            .featurePadding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .task { loadScanPaths() }
            .alert(loc.t("清理选中的项目？", "Purge selected artifacts?"),
                   isPresented: $showConfirm) {
                Button(loc.t("取消", "Cancel"), role: .cancel) {}
                Button(loc.t("移至废纸篓", "Move to Trash"), role: .destructive) { deleteSelected() }
            } message: {
                Text(loc.t(
                    "将把 \(selectedIDs.count) 个项目构建产物移至废纸篓，共约 \(ByteFormatter.bytes(totalSelectedSize))。可从废纸篓恢复。",
                    "Will move \(selectedIDs.count) project artifacts to Trash, totaling \(ByteFormatter.bytes(totalSelectedSize)). Recoverable from Trash."
                ))
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        FeatureHeader(
            title: loc.t("清理项目", "Purge Projects"),
            subtitle: loc.t("通过清理项目构建产物来回收空间。", "Reclaim space by purging build artifacts."),
            systemImage: "shippingbox",
            trailing: AnyView(actionButtons)
        )
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            if phase == .running {
                ProgressView().controlSize(.small)
            } else if phase == .done {
                Button {
                    resetToIdle()
                } label: {
                    Label(loc.t("再扫描", "Scan Again"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(PrimaryButtonStyle())
            } else {
                Button {
                    if phase == .scanned && !selectedIDs.isEmpty {
                        showConfirm = true
                    } else {
                        Task { await scanArtifacts() }
                    }
                } label: {
                    Label(primaryActionLabel, systemImage: primaryActionIcon)
                }
                .buttonStyle(PrimaryButtonStyle(disabled: !canRunPrimary))
                .disabled(!canRunPrimary)
            }
        }
    }

    private var canRunPrimary: Bool {
        if phase == .scanning || phase == .running { return false }
        if phase == .idle { return true }
        if phase == .scanned { return !selectedIDs.isEmpty }
        if phase == .error { return true }
        return false
    }

    private var primaryActionLabel: String {
        switch phase {
        case .idle, .scanning: return loc.t("扫描", "Scan")
        case .scanned: return loc.t("清理选中 (\(selectedIDs.count))", "Purge (\(selectedIDs.count))")
        case .running: return loc.t("清理中…", "Purging…")
        case .done: return loc.t("完成", "Done")
        case .error: return loc.t("重试", "Retry")
        }
    }
    private var primaryActionIcon: String {
        switch phase {
        case .idle, .scanning: return "magnifyingglass"
        case .scanned: return "trash"
        case .running: return "circle.dashed"
        case .done: return "checkmark.circle.fill"
        case .error: return "arrow.clockwise"
        }
    }

    // MARK: - Step guide

    private var stepGuide: some View {
        HStack(spacing: 10) {
            StepDot(n: 1, label: loc.t("扫描", "Scan"), active: phase == .idle || phase == .scanning, done: phase.isAfterScan)
            StepConnector(active: phase.isAfterScan)
            StepDot(n: 2, label: loc.t("选择", "Select"), active: phase == .scanned, done: phase == .running || phase == .done)
            StepConnector(active: phase == .running || phase == .done)
            StepDot(n: 3, label: loc.t("清理", "Purge"), active: phase == .running, done: phase == .done)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Categories card

    private var categoriesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text(loc.t("扫描范围", "Scan Scope"))
                    .font(.system(size: 13, weight: .semibold))
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 10) {
                    catRow("node_modules", loc.t("JS 依赖", "JS deps"), "shippingbox")
                    catRow("target/build", loc.t("构建产物", "Build output"), "hammer")
                    catRow("Derived Data", loc.t("Xcode 数据", "Xcode data"), "cube")
                    catRow(".venv", loc.t("Python 环境", "Python env"), "scope")
                    catRow("Gradle/Maven", loc.t("构建缓存", "Build cache"), "tray.full")
                    catRow("Pods", loc.t("iOS 依赖", "iOS deps"), "app.badge")
                }
            }
        }
    }

    private func catRow(_ name: String, _ detail: String, _ icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundColor(Theme.accent).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 10)).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Scan paths config card

    /// Shows the purge scan paths from `~/.config/mole/purge_paths` so the
    /// user knows which directories `mo purge` will search. Provides a
    /// "Reveal Config" button to open the file in Finder for editing,
    /// mirroring `mo purge --paths` which opens `$EDITOR`.
    private var scanPathsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(loc.t("扫描路径配置", "Scan Path Config"), systemImage: "folder.badge.gearshape")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if usingDefaultPaths {
                        Text(loc.t("默认路径", "Default paths"))
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Color.gray.opacity(0.18), in: Capsule())
                            .foregroundColor(.secondary)
                    } else {
                        Text(loc.t("自定义路径", "Custom paths"))
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Theme.accent.opacity(0.18), in: Capsule())
                            .foregroundColor(Theme.accent)
                    }
                }

                if configuredScanPaths.isEmpty {
                    Text(loc.t(
                        "未找到配置文件，将使用默认路径扫描。",
                        "No config file found; will scan default paths."
                    ))
                    .font(.system(size: 11)).foregroundColor(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(configuredScanPaths, id: \.self) { path in
                            HStack(spacing: 6) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                                Text(path)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        revealConfigFile()
                    } label: {
                        Label(loc.t("编辑配置", "Edit Config"), systemImage: "pencil")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)

                    if !usingDefaultPaths {
                        Button {
                            Task { await reloadAfterEdit() }
                        } label: {
                            Label(loc.t("重新加载", "Reload"), systemImage: "arrow.clockwise")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    /// Reads `~/.config/mole/purge_paths` and parses non-comment, non-blank
    /// lines. Sets `usingDefaultPaths` to false when the file has at least
    /// one valid path entry.
    private func loadScanPaths() {
        let configURL = URL(fileURLWithPath: NSString(string: "~/.config/mole/purge_paths").expandingTildeInPath)
        guard let content = try? String(contentsOf: configURL, encoding: .utf8) else {
            configuredScanPaths = []
            usingDefaultPaths = true
            return
        }
        let paths = content
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { line -> String in
                // Expand ~ to home, matching the CLI's mole_purge_read_paths_config
                if line.hasPrefix("~") {
                    return NSString(string: line).expandingTildeInPath
                }
                return line
            }
            .map { path -> String in
                // Show as ~/path for readability
                let home = NSHomeDirectory()
                if path.hasPrefix(home + "/") {
                    return "~" + path.dropFirst(home.count)
                }
                return path
            }
        configuredScanPaths = paths
        usingDefaultPaths = paths.isEmpty
    }

    private func revealConfigFile() {
        let configPath = NSString(string: "~/.config/mole/purge_paths").expandingTildeInPath
        let configURL = URL(fileURLWithPath: configPath)
        // If the file doesn't exist, reveal the parent directory so the
        // user can create it. The CLI's `mo purge --paths` creates a
        // template on first run; here we just point the user to the
        // config location.
        if FileManager.default.fileExists(atPath: configPath) {
            NSWorkspace.shared.activateFileViewerSelecting([configURL])
        } else {
            let dirURL = configURL.deletingLastPathComponent()
            // Create the directory if needed so Finder can open it
            try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
            NSWorkspace.shared.open(dirURL)
        }
    }

    private func reloadAfterEdit() async {
        loadScanPaths()
        // If the user edited paths and is in idle/error state, offer to
        // rescan. Don't auto-trigger if already scanning or has results.
        if phase == .idle || phase == .error {
            await scanArtifacts()
        }
    }

    // MARK: - Scanning view

    private var scanningView: some View {
        Card {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(loc.t("正在扫描项目构建产物…", "Scanning project artifacts…"))
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
        }
    }

    // MARK: - Running view

    private var runningView: some View {
        Card {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(loc.t("正在移至废纸篓…", "Moving to Trash…"))
                        .font(.system(size: 12)).foregroundColor(.secondary)
                }
                if progressTotal > 0 {
                    // Per-item progress so the user can tell the operation
                    // is advancing, not stuck.
                    Text(loc.t("\(progressDone) / \(progressTotal)", "\(progressDone) / \(progressTotal)"))
                        .font(.system(size: 11, design: .rounded)).foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
        }
    }

    // MARK: - Error view

    private var errorView: some View {
        EmptyStateView(
            systemImage: "exclamationmark.triangle",
            title: loc.t("扫描失败", "Scan failed"),
            message: scanError ?? loc.t("无法扫描项目目录", "Could not scan project directories"),
            action: (loc.t("重试", "Retry"), { Task { await scanArtifacts() } })
        )
    }

    // MARK: - Artifacts list

    private var artifactsList: some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(loc.t("\(filteredArtifacts.count) 个构建产物", "\(filteredArtifacts.count) artifacts"))
                        .font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                    if usedFallback {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.orange)
                            .help(fallbackReason.map {
                                loc.t("CLI 扫描失败，已降级到本地扫描：\($0)",
                                      "CLI scan failed, fell back to local scan: \($0)")
                            } ?? loc.t("CLI 扫描失败，已降级到本地扫描",
                                       "CLI scan failed, fell back to local scan"))
                    }
                    Spacer()
                    if !selectedIDs.isEmpty {
                        Text(loc.t("可回收 \(ByteFormatter.bytes(totalSelectedSize))", "Reclaim \(ByteFormatter.bytes(totalSelectedSize))"))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(Theme.color(for: .good))
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)

                Divider()

                // Type filter + select-all row. The filter narrows the
                // visible list; select-all operates on the filtered set so
                // users can batch-select one artifact type at a time.
                HStack(spacing: 12) {
                    Button {
                        let filteredIDs = Set(filteredArtifacts.map { $0.id })
                        if selectedIDs.isSuperset(of: filteredIDs) {
                            selectedIDs.subtract(filteredIDs)
                        } else {
                            selectedIDs.formUnion(filteredIDs)
                        }
                    } label: {
                        Text(loc.t("全选", "Select All"))
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain).foregroundColor(Theme.accent)

                    Spacer()

                    Picker(loc.t("类型", "Type"), selection: $typeFilter) {
                        Text(loc.t("全部", "All")).tag(String?.none)
                        ForEach(availableTypes, id: \.self) { type in
                            Text(type).tag(String?.some(type))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 160)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)

                Divider()

                ForEach(Array(filteredArtifacts.enumerated()), id: \.element.id) { index, artifact in
                    artifactRow(artifact)
                    if index < filteredArtifacts.count - 1 {
                        Divider().padding(.leading, 50)
                    }
                }
            }
        }
    }

    private func artifactRow(_ artifact: PurgeScanner.FoundArtifact) -> some View {
        let isSelected = selectedIDs.contains(artifact.id)
        return HStack(spacing: 12) {
            Button {
                if isSelected { selectedIDs.remove(artifact.id) }
                else { selectedIDs.insert(artifact.id) }
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundColor(isSelected ? Theme.accent : .secondary)
            }
            .buttonStyle(.plain)

            Image(systemName: iconForType(artifact.artifactType))
                .foregroundColor(Theme.accent).frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(artifact.projectName)
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                // Full path relative to home, so users can tell multiple
                // same-named artifacts (e.g. several node_modules) apart.
                Text(displayPath(artifact.url))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
            }

            Spacer(minLength: 8)

            // Age label: warns the user when an artifact was modified
            // recently (active build). Matches the CLI's age display.
            Text(artifact.ageLabel)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundColor(artifact.isRecent ? .orange : .secondary)
                .help(artifact.isRecent
                      ? loc.t("最近修改（\(artifact.ageDays) 天内），可能正在使用", "Recently modified (within \(artifact.ageDays) days), may be in use")
                      : loc.t("\(artifact.ageDays) 天未修改", "Last modified \(artifact.ageDays) days ago"))

            Text(artifact.sizeText)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(artifact.sizeBytes > 100_000_000 ? Theme.color(for: .good) : .primary)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(isSelected ? Theme.accent.opacity(0.04) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelected { selectedIDs.remove(artifact.id) }
            else { selectedIDs.insert(artifact.id) }
        }
    }

    /// Returns a display-friendly path: `~/`-prefixed relative to home,
    /// so long absolute paths stay readable in the row.
    private func displayPath(_ url: URL) -> String {
        let home = NSHomeDirectory()
        let path = url.path
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func iconForType(_ type: String) -> String {
        switch type {
        case "node_modules": return "shippingbox"
        case "target", "build", "dist", "out": return "hammer"
        case "DerivedData": return "cube"
        case ".venv", "venv": return "scope"
        case ".gradle", ".m2": return "tray.full"
        case "Pods": return "app.badge"
        default: return "folder"
        }
    }

    // MARK: - Result banner

    private func resultBanner(_ result: DeleteResult) -> some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: result.success ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(Theme.color(for: result.success ? .good : .critical))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.success ? loc.t("清理完成", "Purge complete") : loc.t("部分失败", "Partial failure"))
                            .font(.system(size: 14, weight: .semibold))
                        Text(result.message)
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    Spacer()
                }
                if result.success {
                    HStack(spacing: 8) {
                        Button {
                            let trashPath = NSString(string: "~/.Trash").expandingTildeInPath
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: trashPath)])
                        } label: {
                            Label(loc.t("打开废纸篓", "Open Trash"), systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        Button { resetToIdle() } label: {
                            Label(loc.t("再扫描", "Scan Again"), systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func scanArtifacts() async {
        phase = .scanning
        scanError = nil
        deleteResult = nil
        selectedIDs.removeAll()
        usedFallback = false
        fallbackReason = nil

        // 默认走 CLI 扫描（mo purge --dry-run），消除与 CLI 的 34 个 target /
        // 9 个搜索路径的手动同步负担。CLI 不可用或解析失败时降级到本地扫描。
        let result = await CLIPurgeScanner.scan(useFallback: true)
        let found = result.artifacts.map { $0.asPurgeArtifact() }
        usedFallback = result.usedFallback
        fallbackReason = result.fallbackReason

        if found.isEmpty {
            phase = .error
            scanError = loc.t("未发现项目构建产物", "No project artifacts found")
        } else {
            artifacts = found
            selectedIDs = Set(found.map { $0.id })
            phase = .scanned
        }
    }

    private func deleteSelected() {
        let toDelete = artifacts.filter { selectedIDs.contains($0.id) }
        guard !toDelete.isEmpty else { return }

        phase = .running
        progressDone = 0
        progressTotal = toDelete.count

        // Use PurgeDeleter which routes through the Trash (recoverable),
        // checks protected paths, and writes an operation log. This
        // matches the CLI's mole_delete safety contract.
        let outcomes = PurgeDeleter.trashArtifacts(toDelete) { done in
            progressDone = done
        }

        var deletedCount = 0
        var freedBytes: Int64 = 0
        var errors: [String] = []
        var failedIDs: Set<String> = []

        for outcome in outcomes {
            if outcome.success {
                deletedCount += 1
                freedBytes += outcome.artifact.sizeBytes
            } else {
                failedIDs.insert(outcome.artifact.id)
                errors.append("\(outcome.artifact.displayName): \(outcome.message)")
            }
        }

        phase = .done
        if errors.isEmpty {
            deleteResult = DeleteResult(
                success: true,
                message: loc.t("已将 \(deletedCount) 个项目移至废纸篓，释放 \(ByteFormatter.bytes(freedBytes))。",
                               "Moved \(deletedCount) artifacts to Trash, freed \(ByteFormatter.bytes(freedBytes))."),
                deletedCount: deletedCount,
                freedBytes: freedBytes
            )
        } else {
            let errMsg = errors.joined(separator: "; ")
            deleteResult = DeleteResult(
                success: deletedCount > 0,
                message: loc.t("移至废纸篓 \(deletedCount) 项，\(errors.count) 项失败：\(errMsg)",
                               "Moved \(deletedCount) to Trash, \(errors.count) failed: \(errMsg)"),
                deletedCount: deletedCount,
                freedBytes: freedBytes
            )
        }

        // Remove successfully-deleted artifacts from the list; keep
        // failed ones so the user can see what didn't get cleaned.
        artifacts.removeAll { selectedIDs.contains($0.id) && !failedIDs.contains($0.id) }
        selectedIDs.removeAll()
    }

    private func resetToIdle() {
        artifacts.removeAll()
        selectedIDs.removeAll()
        scanError = nil
        deleteResult = nil
        typeFilter = nil
        progressDone = 0
        progressTotal = 0
        phase = .idle
    }
}
