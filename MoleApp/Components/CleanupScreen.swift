import SwiftUI

/// A reusable screen for the preview → confirm → run cleanup commands
/// (Clean, Optimize, Purge, Installer). Each provides its title, categories,
/// the two service calls, and optional confirmation/result copy; this view
/// handles the lifecycle, the visual preview, and the raw console fallback.
///
/// 布局规范（与 InstallerView/PurgeInteractiveView 一致）：
/// header（无按钮）→ stepGuide → idle: heroCard + categoriesCard | 其他: previewCard（扫描结果 + 内嵌操作栏）。
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
    @State private var showCategories = true
    /// Snapshot of the preview summary captured when the run starts, so the
    /// result banner can show "reclaimed X · Y items" after completion.
    @State private var previewSnapshot: PreviewParser.Summary?

    private enum Phase: Equatable { case idle, previewing, previewed, running, done, error }

    private var parsed: PreviewParser.Summary {
        let texts = runner.lines.map { $0.text }
        DebugLog.append("CleanupScreen.parsed: runner.lines.count=\(runner.lines.count), texts.count=\(texts.count)")
        if texts.count > 0 {
            DebugLog.append("CleanupScreen.parsed: first 3 texts: \(texts.prefix(3).map { String($0.prefix(60)) })")
        }
        return PreviewParser.parse(texts)
    }

    private var hasVisualContent: Bool {
        !parsed.entries.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                stepGuide
                if phase == .idle {
                    idleHeroCard
                    categoriesCard
                } else {
                    previewCard
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
                "这将永久删除扫描中识别的项目，此操作不可撤销。系统级项目需要活动的 sudo 会话。",
                "This will permanently delete the items shown in the scan. This cannot be undone. Some steps may require an active sudo session."
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
            systemImage: systemImage
        )
    }

    // MARK: - Step guide

    /// A compact 3-step banner so the user always knows the flow:
    /// 1. Scan  2. Review  3. Confirm & Run.
    private var stepGuide: some View {
        HStack(spacing: 10) {
            StepDot(n: 1, label: loc.t("扫描", "Scan"), active: phase == .idle || phase == .previewing, done: phaseIsAfterPreview)
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

    // MARK: - Idle hero card

    private var idleHeroCard: some View {
        Card(padding: 0) {
            VStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 32, weight: .light))
                    .foregroundColor(Theme.accent.opacity(0.7))
                Text(previewHint)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)
                Button {
                    Task { await runPreview() }
                } label: {
                    Label(loc.t("开始扫描", "Start Scan"), systemImage: "magnifyingglass")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .frame(maxWidth: .infinity)
            .padding(24)
        }
    }

    // MARK: - Categories card

    private var categoriesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(loc.t("功能说明", "What this does"))
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button {
                        showCategories.toggle()
                    } label: {
                        Image(systemName: "questionmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .help(loc.t("点击显示/隐藏功能说明", "Click to show/hide description"))
                }
                if showCategories {
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
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showCategories)
    }

    // MARK: - Preview card (扫描结果 + 内嵌操作栏)

    private var previewCard: some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                // 头部：标题 + 状态
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
                .padding(.horizontal, 12).padding(.vertical, 10)

                Divider()
                contentArea

                Divider()
                actionBar
                    .padding(.horizontal, 12).padding(.vertical, 10)
            }
        }
    }

    @ViewBuilder
    private var contentArea: some View {
        if phase == .idle {
            Text(previewHint)
                .font(.system(size: 12)).foregroundColor(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                .multilineTextAlignment(.center)
                .padding(12)
        } else if phase == .previewing {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(loc.t("正在扫描（试运行）…", "Scanning (dry-run)…"))
                        .font(.system(size: 12)).foregroundColor(.secondary)
                }
                if hasVisualContent {
                    PreviewSummaryView(summary: parsed, loc: loc)
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(12)
        } else if phase == .running {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(loc.t("正在运行…", "Running…"))
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            .padding(12)
        } else if phase == .done {
            doneContent
        } else if phase == .error {
            errorContent
        } else {
            // previewed
            if showRawConsole {
                ConsoleOutputView(lines: runner.lines)
                    .frame(minHeight: 220, maxHeight: 360)
                    .padding(12)
            } else if hasVisualContent {
                PreviewSummaryView(summary: parsed, loc: loc)
                    .padding(12)
            } else {
                // Output exists but parser found no structured entries
                // (e.g. installer "No installer files to clean"). Show the
                // raw lines in a compact form so the user still sees what
                // happened.
                ConsoleOutputView(lines: runner.lines)
                    .frame(minHeight: 120, maxHeight: 240)
                    .padding(12)
            }
        }
    }

    private var doneContent: some View {
        let succeeded = runner.succeeded
        let cancelled = runner.wasCancelled
        return VStack(alignment: .leading, spacing: 8) {
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
        }
        .padding(12)
    }

    private var errorContent: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28)).foregroundColor(Theme.color(for: .critical))
            Text(loc.t("扫描失败，请重试", "Scan failed, please retry"))
                .font(.system(size: 12)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding(12)
    }

    // MARK: - Action bar (内嵌在扫描结果卡片底部，四个模块统一)

    @ViewBuilder
    private var actionBar: some View {
        HStack {
            switch phase {
            case .idle:
                Spacer()
                Button {
                    Task { await runPreview() }
                } label: {
                    Label(loc.t("开始扫描", "Start Scan"), systemImage: "magnifyingglass")
                }
                .buttonStyle(PrimaryButtonStyle())
            case .previewing:
                Spacer()
                Button(loc.t("停止", "Stop"), role: .destructive) { runner.cancel() }
                    .buttonStyle(.bordered)
            case .previewed:
                Button {
                    resetToIdle()
                } label: {
                    Label(loc.t("重新扫描", "Rescan"), systemImage: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundColor(.secondary)
                Spacer()
                Button {
                    showConfirm = true
                } label: {
                    Label(actionLabel ?? loc.t("运行", "Run"), systemImage: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(PrimaryButtonStyle(disabled: !runner.hasOutput))
                .disabled(!runner.hasOutput)
            case .running:
                Spacer()
                Button(loc.t("停止", "Stop"), role: .destructive) { runner.cancel() }
                    .buttonStyle(.bordered)
            case .done:
                Spacer()
                Button { resetToIdle() } label: {
                    Label(loc.t("再清理一次", "Run Again"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(PrimaryButtonStyle())
            case .error:
                Spacer()
                Button {
                    Task { await runPreview() }
                } label: {
                    Label(loc.t("重试扫描", "Retry scan"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    // MARK: - Status pill

    @ViewBuilder
    private var statusPill: some View {
        if phase == .previewing || phase == .running {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini); Text(loc.t("运行中", "running")).font(.system(size: 10))
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
        } else if phase == .done {
            let succeeded = runner.succeeded
            Text(succeeded ? loc.t("✓ 完成", "✓ done") : loc.t("失败", "failed"))
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Theme.color(for: succeeded ? .good : .critical).opacity(0.18), in: Capsule())
                .foregroundColor(Theme.color(for: succeeded ? .good : .critical))
        } else if phase == .error {
            Text(loc.t("失败", "failed"))
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Theme.color(for: .critical).opacity(0.18), in: Capsule())
                .foregroundColor(Theme.color(for: .critical))
        }
    }

    private var phaseLabel: String {
        switch phase {
        case .idle: return loc.t("扫描结果", "Scan Results")
        case .previewing: return loc.t("扫描中（试运行）…", "Scanning (dry-run)…")
        case .previewed: return loc.t("扫描完成", "Scan complete")
        case .running: return loc.t("运行中…", "Running…")
        case .done: return loc.t("已完成", "Finished")
        case .error: return loc.t("扫描失败", "Scan failed")
        }
    }

    private var resultSummaryText: String {
        if let snap = previewSnapshot {
            let space = snap.totalSpaceText ?? "—"
            let items = snap.totalItems ?? snap.entries.filter { $0.kind == .wouldClean }.count
            return loc.t("本次可回收约 \(space) · \(items) 项已永久删除。",
                         "Approximately \(space) reclaimable · \(items) items permanently deleted.")
        }
        return loc.t("操作已完成，已永久删除。",
                     "Operation complete. Items permanently deleted.")
    }

    @MainActor
    private func runPreview() async {
        phase = .previewing
        showCategories = false
        await runner.runAwaited { onLine in try await preview(onLine) }
        // If scan failed (error set or non-zero exit with no output),
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
            await runner.runAwaited { onLine in try await run(onLine) }
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
        showCategories = true
    }
}
