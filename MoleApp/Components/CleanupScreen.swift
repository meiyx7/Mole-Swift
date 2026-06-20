import SwiftUI

/// A reusable screen for the preview → confirm → run cleanup commands
/// (Clean, Optimize, Purge, Installer). Each provides its title, categories,
/// the two service calls, and optional confirmation/result copy; this view
/// handles the lifecycle, the visual preview, and the raw console fallback.
struct CleanupScreen: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let categories: [(name: String, detail: String, icon: String)]
    let previewHint: String

    let preview: (@MainActor @escaping (CLIOutputLine) -> Void) async throws -> Int32
    let run: (@MainActor @escaping (CLIOutputLine) -> Void) async throws -> Int32

    /// Custom copy for the confirmation alert. Defaults to a safe,
    /// Trash-routing-aware message shared by all cleanup screens.
    var confirmTitle: String? = nil
    var confirmMessage: String? = nil
    /// Label for the destructive action button in the confirm alert.
    var actionLabel: String? = nil

    @EnvironmentObject private var loc: Localization
    @StateObject private var runner = CommandRunner()
    @State private var phase: Phase = .idle
    @State private var showConfirm = false
    @State private var showRawConsole = false
    /// Snapshot of the preview summary captured when the run starts, so the
    /// result banner can show "reclaimed X · Y items" after completion.
    @State private var previewSnapshot: PreviewParser.Summary?

    private enum Phase: Equatable { case idle, previewing, previewed, running, done, error }

    private var parsed: PreviewParser.Summary {
        PreviewParser.parse(runner.lines.map { $0.text })
    }

    private var hasVisualContent: Bool {
        !parsed.entries.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                stepGuide
                categoriesCard
                previewCard
                if phase == .done {
                    resultBanner
                }
            }
        }
        .featurePadding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .alert(confirmTitle ?? loc.t("运行\(title)？", "Run \(title.lowercased())?"), isPresented: $showConfirm) {
            Button(loc.t("取消", "Cancel"), role: .cancel) {}
            Button(actionLabel ?? loc.t("运行", "Run"), role: .destructive) { runNow() }
        } message: {
            Text(confirmMessage ?? loc.t(
                "这将把预览中识别的项目移至废纸篓，可从废纸篓恢复。系统级项目需要活动的 sudo 会话。",
                "This will move the items shown in the preview to Trash, where they can be recovered. Some steps may require an active sudo session."
            ))
        }
        .onReceive(NotificationCenter.default.publisher(for: .moleRefresh)) { _ in
            // Cmd+R resets the screen to idle so the user can start fresh.
            // Only reset if not currently running to avoid interrupting.
            if !runner.isRunning {
                resetToIdle()
            }
        }
    }

    private var header: some View {
        FeatureHeader(
            title: title,
            subtitle: subtitle,
            systemImage: systemImage,
            trailing: AnyView(actionButtons)
        )
    }

    // MARK: - Step guide

    /// A compact 3-step banner so the user always knows the flow:
    /// 1. Preview  2. Review  3. Confirm & Run.
    private var stepGuide: some View {
        HStack(spacing: 10) {
            StepDot(n: 1, label: loc.t("预览", "Preview"), active: phase == .idle || phase == .previewing, done: phaseIsAfterPreview)
            StepConnector(active: phaseIsAfterPreview)
            StepDot(n: 2, label: loc.t("查看", "Review"), active: phase == .previewed, done: phase == .running || phase == .done)
            StepConnector(active: phase == .running || phase == .done)
            StepDot(n: 3, label: loc.t("执行", "Run"), active: phase == .running, done: phase == .done)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var phaseIsAfterPreview: Bool {
        phase == .previewed || phase == .running || phase == .done || phase == .error
    }

    // MARK: - Actions

    private var actionButtons: some View {
        HStack(spacing: 8) {
            if runner.isRunning {
                Button(loc.t("停止", "Stop"), role: .destructive) { runner.cancel() }.buttonStyle(.bordered)
            } else if phase == .done {
                Button {
                    resetToIdle()
                } label: {
                    Label(loc.t("再试一次", "Run Again"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(PrimaryButtonStyle())
            } else {
                // Single primary action whose label/behaviour follows the flow:
                // idle/previewing → "Preview", previewed → "Run".
                // The button is visibly disabled (flat gray) until the preview
                // step is done, so the gating is obvious without a second button.
                Button {
                    if phase == .previewed {
                        showConfirm = true
                    } else {
                        Task { await runPreview() }
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
        if phase == .idle || phase == .previewing { return true }   // can start preview
        if phase == .previewed { return runner.hasOutput }          // can run after preview
        if phase == .error { return true }                          // can retry from error
        return false                                                // running/done
    }

    private var primaryActionLabel: String {
        switch phase {
        case .idle, .previewing:
            return loc.t("预览", "Preview")
        case .previewed:
            return actionLabel ?? loc.t("运行", "Run")
        case .running:
            return loc.t("运行中…", "Running…")
        case .done:
            return loc.t("已完成", "Done")
        case .error:
            return loc.t("重试预览", "Retry preview")
        }
    }

    private var primaryActionIcon: String {
        switch phase {
        case .idle, .previewing: return "eye"
        case .previewed:         return systemImage
        case .running:           return "circle.dashed"
        case .done:              return "checkmark.circle.fill"
        case .error:             return "arrow.clockwise"
        }
    }

    private var categoriesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text(loc.t("功能说明", "What this does"))
                    .font(.system(size: 13, weight: .semibold))
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                          spacing: 10) {
                    ForEach(categories.indices, id: \.self) { i in
                        let c = categories[i]
                        HStack(spacing: 10) {
                            Image(systemName: c.icon).foregroundColor(Theme.accent).frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.name).font(.system(size: 12, weight: .medium))
                                Text(c.detail).font(.system(size: 10)).foregroundColor(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Preview card (visual + raw console toggle)

    private var previewCard: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(phaseLabel, systemImage: "sparkles.rectangle.stack")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    statusPill
                    if runner.hasOutput {
                        Button {
                            showRawConsole.toggle()
                        } label: {
                            Image(systemName: showRawConsole ? "list.bullet.indent" : "terminal")
                                .font(.system(size: 11))
                                .help(loc.t("切换原始输出", "Toggle raw output"))
                        }
                        .buttonStyle(.borderless)
                    }
                }

                if runner.lines.isEmpty && !runner.isRunning {
                    Text(previewHint)
                        .font(.system(size: 12)).foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                        .multilineTextAlignment(.center)
                } else if showRawConsole {
                    ConsoleOutputView(lines: runner.lines)
                        .frame(minHeight: 220, maxHeight: 360)
                } else if hasVisualContent {
                    PreviewSummaryView(summary: parsed, loc: loc)
                } else {
                    // Output exists but parser found no structured entries
                    // (e.g. installer "No installer files to clean"). Show the
                    // raw lines in a compact form so the user still sees what
                    // happened.
                    ConsoleOutputView(lines: runner.lines)
                        .frame(minHeight: 120, maxHeight: 240)
                }
            }
        }
    }

    // MARK: - Result banner (shown after run completes)

    private var resultBanner: some View {
        let succeeded = runner.succeeded
        let cancelled = runner.wasCancelled
        return Card(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: cancelled ? "stop.circle.fill" : (succeeded ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"))
                        .font(.system(size: 22))
                        .foregroundColor(Theme.color(for: cancelled ? .neutral : (succeeded ? .good : .critical)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cancelled
                             ? loc.t("已取消", "Cancelled")
                             : (succeeded
                                ? loc.t("完成", "Finished")
                                : loc.t("未完全成功", "Completed with errors")))
                            .font(.system(size: 14, weight: .semibold))
                        Text(resultSummaryText)
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    Spacer()
                }
                if succeeded {
                    HStack(spacing: 8) {
                        Button {
                            openTrash()
                        } label: {
                            Label(loc.t("打开废纸篓", "Open Trash"), systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        Button {
                            resetToIdle()
                        } label: {
                            Label(loc.t("再清理一次", "Run Again"), systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private var resultSummaryText: String {
        if let snap = previewSnapshot {
            let space = snap.totalSpaceText ?? "—"
            let items = snap.totalItems ?? snap.entries.filter { $0.kind == .wouldClean }.count
            return loc.t("本次可回收约 \(space) · \(items) 项已移至废纸篓，可从废纸篓恢复。",
                         "Approximately \(space) reclaimable · \(items) items moved to Trash, recoverable from Trash.")
        }
        return loc.t("操作已完成，已移至废纸篓，可从废纸篓恢复。",
                     "Operation complete. Items moved to Trash, recoverable from Trash.")
    }

    private func openTrash() {
        let trashPath = NSString(string: "~/.Trash").expandingTildeInPath
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: trashPath)])
    }

    private var phaseLabel: String {
        switch phase {
        case .idle: return loc.t("预览结果", "Preview")
        case .previewing: return loc.t("预览中（试运行）…", "Previewing (dry-run)…")
        case .previewed: return loc.t("预览完成", "Preview ready")
        case .running: return loc.t("运行中…", "Running…")
        case .done: return loc.t("已完成", "Finished")
        case .error: return loc.t("预览失败", "Preview failed")
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        if runner.isRunning {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini); Text(loc.t("运行中", "running")).font(.system(size: 10))
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
        } else if let code = runner.exitCode {
            let tone: StatusTone = code == 0 ? .good : .critical
            Text(code == 0 ? loc.t("✓ 完成", "✓ exit 0") : loc.t("退出 \(code)", "exit \(code)"))
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Theme.color(for: tone).opacity(0.18), in: Capsule())
                .foregroundColor(Theme.color(for: tone))
        }
    }

    @MainActor
    private func runPreview() async {
        phase = .previewing
        await runner.run { onLine in try await preview(onLine) }
        // If preview failed (error set or non-zero exit with no output),
        // go to error phase so the user can retry instead of being stuck.
        if runner.error != nil || (runner.exitCode != nil && runner.exitCode != 0 && !runner.hasOutput) {
            phase = .error
        } else {
            phase = .previewed
        }
    }

    private func runNow() {
        // Capture the preview summary so the result banner can show
        // "reclaimed X · Y items" after the run completes.
        previewSnapshot = parsed
        phase = .running
        Task {
            await runner.run { onLine in try await run(onLine) }
            phase = .done
        }
    }

    private func resetToIdle() {
        runner.cancel()
        runner.lines.removeAll()
        runner.exitCode = nil
        runner.error = nil
        previewSnapshot = nil
        phase = .idle
    }
}
