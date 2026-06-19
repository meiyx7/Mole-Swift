import SwiftUI

/// A reusable screen for the preview → confirm → run cleanup commands
/// (Optimize, Purge, Installer). Each provides its title, categories, and the
/// two service calls; this view handles the lifecycle, the visual preview, and
/// the raw console fallback.
struct CleanupScreen: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let categories: [(name: String, detail: String, icon: String)]
    let previewHint: String

    let preview: (@MainActor @escaping (CLIOutputLine) -> Void) async throws -> Int32
    let run: (@MainActor @escaping (CLIOutputLine) -> Void) async throws -> Int32

    @EnvironmentObject private var loc: Localization
    @StateObject private var runner = CommandRunner()
    @State private var phase: Phase = .idle
    @State private var showConfirm = false
    @State private var showRawConsole = false

    private enum Phase: Equatable { case idle, previewing, previewed, running, done }

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
            }
        }
        .featurePadding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .alert(loc.t("运行\(title)？", "Run \(title.lowercased())?"), isPresented: $showConfirm) {
            Button(loc.t("取消", "Cancel"), role: .cancel) {}
            Button(loc.t("运行", "Run"), role: .destructive) { runNow() }
        } message: {
            Text(loc.t("这将应用预览中显示的更改。某些步骤可能需要活动的 sudo 会话。", "This will apply the changes shown in the preview. Some steps may require an active sudo session."))
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
            stepDot(1, label: loc.t("预览", "Preview"), active: phase == .idle || phase == .previewing, done: phaseIsAfterPreview)
            stepConnector(active: phaseIsAfterPreview)
            stepDot(2, label: loc.t("查看", "Review"), active: phase == .previewed, done: phase == .running || phase == .done)
            stepConnector(active: phase == .running || phase == .done)
            stepDot(3, label: loc.t("执行", "Run"), active: phase == .running, done: phase == .done)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var phaseIsAfterPreview: Bool {
        phase == .previewed || phase == .running || phase == .done
    }

    private func stepDot(_ n: Int, label: String, active: Bool, done: Bool) -> some View {
        HStack(spacing: 6) {
            ZStack {
                Circle().fill(done ? Theme.color(for: .good) : (active ? Theme.accent : Color.secondary.opacity(0.3)))
                    .frame(width: 18, height: 18)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundColor(.white)
                } else {
                    Text("\(n)").font(.system(size: 10, weight: .bold)).foregroundColor(.white)
                }
            }
            Text(label).font(.system(size: 11, weight: done || active ? .semibold : .regular))
                .foregroundColor(done || active ? .primary : .secondary)
        }
    }

    private func stepConnector(active: Bool) -> some View {
        Rectangle()
            .fill(active ? Theme.color(for: .good) : Color.secondary.opacity(0.25))
            .frame(height: 2)
            .frame(maxWidth: 60)
    }

    // MARK: - Actions

    private var actionButtons: some View {
        HStack(spacing: 8) {
            if runner.isRunning {
                Button(loc.t("停止", "Stop"), role: .destructive) { runner.cancel() }.buttonStyle(.bordered)
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
        return false                                                // running/done
    }

    private var primaryActionLabel: String {
        switch phase {
        case .idle, .previewing:
            return loc.t("预览", "Preview")
        case .previewed:
            return loc.t("运行", "Run")
        case .running:
            return loc.t("运行中…", "Running…")
        case .done:
            return loc.t("已完成", "Done")
        }
    }

    private var primaryActionIcon: String {
        switch phase {
        case .idle, .previewing: return "eye"
        case .previewed:         return systemImage
        case .running:           return "circle.dashed"
        case .done:              return "checkmark.circle.fill"
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

    private var phaseLabel: String {
        switch phase {
        case .idle: return loc.t("预览结果", "Preview")
        case .previewing: return loc.t("预览中（试运行）…", "Previewing (dry-run)…")
        case .previewed: return loc.t("预览完成", "Preview ready")
        case .running: return loc.t("运行中…", "Running…")
        case .done: return loc.t("已完成", "Finished")
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
        phase = .previewed
    }

    private func runNow() {
        phase = .running
        Task {
            await runner.run { onLine in try await run(onLine) }
            phase = .done
        }
    }
}
