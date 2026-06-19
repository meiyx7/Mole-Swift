import SwiftUI

/// The categories `mo clean` sweeps, shown so users know what they're getting.
private struct CleanCategory: Identifiable {
    let id = UUID()
    let name: String
    let systemImage: String
    let detail: String
}

struct CleanView: View {
    @EnvironmentObject private var service: MoleService
    @EnvironmentObject private var loc: Localization
    @StateObject private var runner = CommandRunner()
    @State private var phase: Phase = .idle
    @State private var showConfirm = false
    @State private var showRawConsole = false

    private enum Phase: Equatable {
        case idle, previewing, previewed, running, done
    }

    private var cleanCategories: [CleanCategory] {
        [
            .init(name: loc.t("系统与用户缓存", "System & User Caches"), systemImage: "gearshape", detail: loc.t("系统缓存、日志、诊断报告", "System caches, logs, diagnostic reports")),
            .init(name: loc.t("应用缓存", "App Caches"), systemImage: "app.badge", detail: loc.t("各应用的缓存与支持文件垃圾", "Per-application cache & support junk")),
            .init(name: loc.t("浏览器", "Browsers"), systemImage: "globe", detail: loc.t("主流浏览器的 Cookie、缓存、历史记录", "Cookies, cache, history for major browsers")),
            .init(name: loc.t("云与办公", "Cloud & Office"), systemImage: "icloud", detail: loc.t("iCloud、Office、Slack、Teams 缓存", "iCloud, Office, Slack, Teams caches")),
            .init(name: loc.t("开发工具", "Developer Tools"), systemImage: "hammer", detail: loc.t("Xcode DerivedData、模拟器、构建缓存", "Xcode DerivedData, simulators, build caches")),
            .init(name: loc.t("虚拟化", "Virtualization"), systemImage: "shippingbox", detail: loc.t("Docker、虚拟机磁盘、容器镜像", "Docker, VM disks, container images")),
            .init(name: loc.t("应用残留", "App Leftovers"), systemImage: "trash", detail: loc.t("已卸载应用的残留文件", "Residual files from removed apps")),
            .init(name: loc.t("大文件与旧文件", "Large & Old Files"), systemImage: "tray.full", detail: loc.t("大文件与长期未用的数据", "Big files and long-unused data")),
            .init(name: loc.t("项目产物", "Project Artifacts"), systemImage: "folder.badge.gearshape", detail: loc.t("各项目的 node_modules、构建目录", "node_modules, build dirs across projects")),
        ]
    }

    private var parsed: PreviewParser.Summary {
        PreviewParser.parse(runner.lines.map { $0.text })
    }

    private var hasVisualContent: Bool {
        !parsed.entries.isEmpty
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
                    previewCard
                }
            }
            .featurePadding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .alert(loc.t("运行深度清理？", "Run deep cleanup?"), isPresented: $showConfirm) {
                Button(loc.t("取消", "Cancel"), role: .cancel) {}
                Button(loc.t("清理", "Clean"), role: .destructive) { runClean() }
            } message: {
                Text(loc.t("Mole 将删除预览中识别的缓存和垃圾文件。系统级项目需要活动的 sudo 会话。此操作不可撤销。", "Mole will delete the caches and junk identified in the preview. System-level items require an active sudo session. This cannot be undone."))
            }
        }
    }

    private var header: some View {
        FeatureHeader(
            title: loc.t("清理", "Clean"),
            subtitle: loc.t("深度清理 Mac 上的缓存、日志、残留文件和垃圾。", "Deep cleanup of caches, logs, leftovers and junk across your Mac."),
            systemImage: "sparkles",
            trailing: AnyView(actionButtons)
        )
    }

    // MARK: - Step guide

    /// A compact 3-step banner so the user always knows the flow:
    /// 1. Preview  2. Review  3. Confirm & Clean.
    private var stepGuide: some View {
        HStack(spacing: 10) {
            stepDot(1, label: loc.t("预览", "Preview"), active: phase == .idle || phase == .previewing, done: phaseIsAfterPreview)
            stepConnector(active: phaseIsAfterPreview)
            stepDot(2, label: loc.t("查看", "Review"), active: phase == .previewed, done: phase == .running || phase == .done)
            stepConnector(active: phase == .running || phase == .done)
            stepDot(3, label: loc.t("清理", "Clean"), active: phase == .running, done: phase == .done)
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

    private var actionButtons: some View {
        HStack(spacing: 8) {
            if runner.isRunning {
                Button(loc.t("停止", "Stop"), role: .destructive) { runner.cancel() }
                    .buttonStyle(.bordered)
            } else {
                Button {
                    Task { await runPreview() }
                } label: {
                    Label(loc.t("预览", "Preview"), systemImage: "eye")
                }
                .buttonStyle(.bordered)
                .disabled(phase == .previewing)

                Button {
                    showConfirm = true
                } label: {
                    Label(loc.t("立即清理", "Clean Now"), systemImage: "sparkles")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!runner.hasOutput || phase == .running)
            }
        }
    }

    private var categoriesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text(loc.t("清理内容", "What gets cleaned"))
                    .font(.system(size: 13, weight: .semibold))
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                          spacing: 10) {
                    ForEach(cleanCategories) { cat in
                        HStack(spacing: 10) {
                            Image(systemName: cat.systemImage)
                                .foregroundColor(Theme.accent)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(cat.name).font(.system(size: 12, weight: .medium))
                                Text(cat.detail).font(.system(size: 10)).foregroundColor(.secondary)
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
                    Text(loc.t("运行预览以查看 Mole 将精确删除的内容 — 安全且不会做任何更改。", "Run a preview to see exactly what Mole would remove — safely, with no changes made."))
                        .font(.system(size: 12)).foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                        .multilineTextAlignment(.center)
                } else if showRawConsole {
                    ConsoleOutputView(lines: runner.lines)
                        .frame(minHeight: 220, maxHeight: 360)
                } else if hasVisualContent {
                    PreviewSummaryView(summary: parsed, loc: loc)
                } else {
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
        case .running: return loc.t("清理中…", "Cleaning…")
        case .done: return loc.t("已完成", "Finished")
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        if runner.isRunning {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text(loc.t("运行中", "running")).font(.system(size: 10))
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

    private func runPreview() async {
        phase = .previewing
        await runner.run { onLine in
            try await service.cleanPreview(onLine: onLine)
        }
        phase = .previewed
    }

    private func runClean() {
        phase = .running
        Task {
            await runner.run { onLine in
                try await service.clean(onLine: onLine)
            }
            phase = .done
        }
    }
}
