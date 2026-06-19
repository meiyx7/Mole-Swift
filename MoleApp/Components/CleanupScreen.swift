import SwiftUI

/// A reusable screen for the preview → confirm → run cleanup commands
/// (Optimize, Purge, Installer). Each provides its title, categories, and the
/// two service calls; this view handles the lifecycle and console output.
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

    private enum Phase: Equatable { case idle, previewing, previewed, running, done }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                categoriesCard
                consoleCard
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

    private var actionButtons: some View {
        HStack(spacing: 8) {
            if runner.isRunning {
                Button(loc.t("停止", "Stop"), role: .destructive) { runner.cancel() }.buttonStyle(.bordered)
            } else {
                Button { Task { await runPreview() } } label: {
                    Label(loc.t("预览", "Preview"), systemImage: "eye")
                }
                .buttonStyle(.bordered)
                .disabled(phase == .previewing)

                Button { showConfirm = true } label: {
                    Label(loc.t("运行", "Run"), systemImage: systemImage)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!runner.hasOutput || phase == .running)
            }
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

    private var consoleCard: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(phaseLabel, systemImage: "terminal")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    statusPill
                }
                if runner.lines.isEmpty && !runner.isRunning {
                    Text(previewHint)
                        .font(.system(size: 12)).foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                        .multilineTextAlignment(.center)
                } else {
                    ConsoleOutputView(lines: runner.lines)
                        .frame(minHeight: 220, maxHeight: 360)
                }
            }
        }
    }

    private var phaseLabel: String {
        switch phase {
        case .idle: return loc.t("输出", "Output")
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
