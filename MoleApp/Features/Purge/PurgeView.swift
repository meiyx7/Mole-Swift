import SwiftUI

struct PurgeView: View {
    @EnvironmentObject private var service: MoleService
    @EnvironmentObject private var loc: Localization
    @StateObject private var runner = CommandRunner()
    @State private var phase: Phase = .idle
    @State private var artifacts: [PurgeScanner.FoundArtifact] = []
    @State private var selectedIDs: Set<String> = []
    @State private var showConfirm = false
    @State private var showRawConsole = false
    @State private var scanError: String?

    private enum Phase: Equatable { case idle, scanning, scanned, running, done, error }

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
                    if phase == .scanned || phase == .running || phase == .done {
                        artifactsList
                    } else if phase == .scanning {
                        scanningView
                    } else if phase == .error {
                        errorView
                    }
                    if runner.hasOutput || runner.isRunning {
                        consoleCard
                    }
                    if phase == .done {
                        resultBanner
                    }
                }
            }
            .featurePadding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .alert(loc.t("清理选中的项目？", "Purge selected artifacts?"),
                   isPresented: $showConfirm) {
                Button(loc.t("取消", "Cancel"), role: .cancel) {}
                Button(loc.t("清理", "Purge"), role: .destructive) { runPurge() }
            } message: {
                Text(loc.t(
                    "将删除 \(selectedIDs.count) 个项目构建产物，共约 \(ByteFormatter.bytes(totalSelectedSize))。此操作可从废纸篓恢复。",
                    "Will delete \(selectedIDs.count) project artifacts totaling approximately \(ByteFormatter.bytes(totalSelectedSize)). Recoverable from Trash."
                ))
            }
            .onReceive(NotificationCenter.default.publisher(for: .moleRefresh)) { _ in
                if !runner.isRunning { resetToIdle() }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        FeatureHeader(
            title: loc.t("清理项目", "Purge Projects"),
            subtitle: loc.t("通过清理项目构建产物来回收空间。", "Reclaim space by purging build artifacts from your projects."),
            systemImage: "shippingbox",
            trailing: AnyView(actionButtons)
        )
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            if runner.isRunning {
                Button(loc.t("停止", "Stop"), role: .destructive) { runner.cancel() }
                    .buttonStyle(.bordered)
            } else if phase == .done {
                Button {
                    resetToIdle()
                } label: {
                    Label(loc.t("再扫描一次", "Scan Again"), systemImage: "arrow.clockwise")
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
        if runner.isRunning { return false }
        if phase == .idle || phase == .scanning { return true }
        if phase == .scanned { return !selectedIDs.isEmpty }
        if phase == .error { return true }
        return false
    }

    private var primaryActionLabel: String {
        switch phase {
        case .idle, .scanning:
            return loc.t("扫描", "Scan")
        case .scanned:
            return loc.t("清理选中", "Purge Selected")
        case .running:
            return loc.t("清理中…", "Purging…")
        case .done:
            return loc.t("完成", "Done")
        case .error:
            return loc.t("重试", "Retry")
        }
    }

    private var primaryActionIcon: String {
        switch phase {
        case .idle, .scanning: return "magnifyingglass"
        case .scanned: return "shippingbox"
        case .running: return "circle.dashed"
        case .done: return "checkmark.circle.fill"
        case .error: return "arrow.clockwise"
        }
    }

    // MARK: - Step guide

    private var stepGuide: some View {
        HStack(spacing: 10) {
            StepDot(n: 1, label: loc.t("扫描", "Scan"), active: phase == .idle || phase == .scanning, done: phaseIsAfterScan)
            StepConnector(active: phaseIsAfterScan)
            StepDot(n: 2, label: loc.t("选择", "Select"), active: phase == .scanned, done: phase == .running || phase == .done)
            StepConnector(active: phase == .running || phase == .done)
            StepDot(n: 3, label: loc.t("清理", "Purge"), active: phase == .running, done: phase == .done)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var phaseIsAfterScan: Bool {
        phase == .scanned || phase == .running || phase == .done || phase == .error
    }

    // MARK: - Categories card

    private var categoriesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text(loc.t("扫描范围", "Scan Scope"))
                    .font(.system(size: 13, weight: .semibold))
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 10) {
                    categoryRow("node_modules", loc.t("JavaScript 依赖目录", "JS dependency folders"), "shippingbox")
                    categoryRow(loc.t("构建目录", "Build Dirs"), loc.t("target/build/dist/out", "target/build/dist/out"), "hammer")
                    categoryRow("Derived Data", loc.t("Xcode 派生数据", "Xcode derived data"), "cube")
                    categoryRow(".venv / venv", loc.t("Python 虚拟环境", "Python virtual envs"), "scope")
                    categoryRow("Gradle / Maven", loc.t("构建缓存", "Build caches"), "tray.full")
                    categoryRow(loc.t("其他", "Others"), "Pods, __pycache__, .turbo", "folder")
                }
            }
        }
    }

    private func categoryRow(_ name: String, _ detail: String, _ icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundColor(Theme.accent).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 10)).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Scanning view

    private var scanningView: some View {
        Card {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(loc.t("正在扫描项目构建产物…", "Scanning project build artifacts…"))
                    .font(.system(size: 12)).foregroundColor(.secondary)
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
                // Header
                HStack {
                    Text(loc.t("\(artifacts.count) 个项目构建产物", "\(artifacts.count) project artifacts"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(loc.t("可回收 \(ByteFormatter.bytes(totalSelectedSize))", "Reclaimable \(ByteFormatter.bytes(totalSelectedSize))")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(selectedIDs.isEmpty ? .secondary : Theme.color(for: .good))
                }
                .padding(.horizontal, 14).padding(.vertical, 10)

                Divider()

                // Select all / deselect all
                HStack(spacing: 12) {
                    Button {
                        if selectedIDs.count == artifacts.count {
                            selectedIDs.removeAll()
                        } else {
                            selectedIDs = Set(artifacts.map { $0.id })
                        }
                    } label: {
                        Text(selectedIDs.count == artifacts.count
                             ? loc.t("取消全选", "Deselect All")
                             : loc.t("全选", "Select All"))
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(Theme.accent)
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 8)

                Divider()

                // Artifact rows
                ForEach(Array(artifacts.enumerated()), id: \.element.id) { index, artifact in
                    artifactRow(artifact)
                    if index < artifacts.count - 1 {
                        Divider().padding(.leading, 50)
                    }
                }
            }
        }
    }

    private func artifactRow(_ artifact: PurgeScanner.FoundArtifact) -> some View {
        let isSelected = selectedIDs.contains(artifact.id)
        return HStack(spacing: 12) {
            // Checkbox
            Button {
                if isSelected {
                    selectedIDs.remove(artifact.id)
                } else {
                    selectedIDs.insert(artifact.id)
                }
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundColor(isSelected ? Theme.accent : .secondary)
            }
            .buttonStyle(.plain)

            // Icon
            Image(systemName: iconForArtifact(artifact.artifactType))
                .foregroundColor(Theme.accent)
                .frame(width: 20)

            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(artifact.projectName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text("\(artifact.artifactType) · \(artifact.url.deletingLastPathComponent().lastPathComponent)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            // Size
            Text(artifact.sizeText)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(artifact.sizeBytes > 100_000_000 ? Theme.color(for: .good) : .primary)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(isSelected ? Theme.accent.opacity(0.04) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelected {
                selectedIDs.remove(artifact.id)
            } else {
                selectedIDs.insert(artifact.id)
            }
        }
    }

    private func iconForArtifact(_ type: String) -> String {
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

    // MARK: - Console card

    private var consoleCard: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(runner.isRunning ? loc.t("清理中…", "Purging…") : loc.t("输出", "Output"), systemImage: "terminal")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if let code = runner.exitCode {
                        Text(code == 0 ? loc.t("✓ 完成", "✓ done") : "exit \(code)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(code == 0 ? .green : .red)
                    }
                }
                ConsoleOutputView(lines: runner.lines)
                    .frame(minHeight: 120, maxHeight: 260)
            }
        }
    }

    // MARK: - Result banner

    private var resultBanner: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: runner.succeeded ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(Theme.color(for: runner.succeeded ? .good : .critical))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(runner.succeeded ? loc.t("完成", "Finished") : loc.t("未完全成功", "Completed with errors"))
                            .font(.system(size: 14, weight: .semibold))
                        Text(loc.t("已清理选中的项目构建产物", "Purged selected project artifacts"))
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    Spacer()
                }
                if runner.succeeded {
                    Button {
                        let trashPath = NSString(string: "~/.Trash").expandingTildeInPath
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: trashPath)])
                    } label: {
                        Label(loc.t("打开废纸篓", "Open Trash"), systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: - Actions

    private func scanArtifacts() async {
        phase = .scanning
        scanError = nil
        selectedIDs.removeAll()

        let found = await Task.detached(priority: .userInitiated) {
            PurgeScanner.scan()
        }.value

        if found.isEmpty {
            scanError = loc.t("未发现项目构建产物", "No project artifacts found")
            phase = .error
        } else {
            artifacts = found
            // Auto-select all artifacts
            selectedIDs = Set(found.map { $0.id })
            phase = .scanned
        }
    }

    private func runPurge() {
        let selectedPaths = artifacts
            .filter { selectedIDs.contains($0.id) }
            .map { $0.url.path }

        phase = .running
        Task {
            let code = await runner.runAwaited { onLine in
                // Build command with selected paths
                var args = ["purge"]
                args.append(contentsOf: selectedPaths)
                return try await service.purge(args: args, onLine: onLine)
            }
            phase = .done
        }
    }

    private func resetToIdle() {
        runner.cancel()
        runner.lines.removeAll()
        runner.exitCode = nil
        runner.error = nil
        artifacts.removeAll()
        selectedIDs.removeAll()
        scanError = nil
        phase = .idle
    }
}
