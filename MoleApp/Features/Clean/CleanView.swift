import SwiftUI

/// The categories `mo clean` sweeps, shown so users know what they're getting.
private struct CleanCategory: Identifiable {
    let id = UUID()
    let name: String
    let systemImage: String
    let detail: String
}

private let cleanCategories: [CleanCategory] = [
    .init(name: "System & User Caches", systemImage: "gearshape", detail: "System caches, logs, diagnostic reports"),
    .init(name: "App Caches", systemImage: "app.badge", detail: "Per-application cache & support junk"),
    .init(name: "Browsers", systemImage: "globe", detail: "Cookies, cache, history for major browsers"),
    .init(name: "Cloud & Office", systemImage: "icloud", detail: "iCloud, Office, Slack, Teams caches"),
    .init(name: "Developer Tools", systemImage: "hammer", detail: "Xcode DerivedData, simulators, build caches"),
    .init(name: "Virtualization", systemImage: "shippingbox", detail: "Docker, VM disks, container images"),
    .init(name: "App Leftovers", systemImage: "trash", detail: "Residual files from removed apps"),
    .init(name: "Large & Old Files", systemImage: "tray.full", detail: "Big files and long-unused data"),
    .init(name: "Project Artifacts", systemImage: "folder.badge.gearshape", detail: "node_modules, build dirs across projects"),
]

struct CleanView: View {
    @EnvironmentObject private var service: MoleService
    @StateObject private var runner = CommandRunner()
    @State private var phase: Phase = .idle
    @State private var showConfirm = false

    private enum Phase: Equatable {
        case idle, previewing, previewed, running, done
    }

    var body: some View {
        if !service.isInstalled {
            CLIUnavailableView()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    categoriesCard
                    consoleCard
                }
            }
            .featurePadding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .alert("Run deep cleanup?", isPresented: $showConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Clean", role: .destructive) { runClean() }
            } message: {
                Text("Mole will delete the caches and junk identified in the preview. System-level items require an active sudo session. This cannot be undone.")
            }
        }
    }

    private var header: some View {
        FeatureHeader(
            title: "Clean",
            subtitle: "Deep cleanup of caches, logs, leftovers and junk across your Mac.",
            systemImage: "sparkles",
            trailing: AnyView(actionButtons)
        )
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            if runner.isRunning {
                Button("Stop", role: .destructive) { runner.cancel() }
                    .buttonStyle(.bordered)
            } else {
                Button {
                    Task { await runPreview() }
                } label: {
                    Label("Preview", systemImage: "eye")
                }
                .buttonStyle(.bordered)
                .disabled(phase == .previewing)

                Button {
                    showConfirm = true
                } label: {
                    Label("Clean Now", systemImage: "sparkles")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!runner.hasOutput || phase == .running)
            }
        }
    }

    private var categoriesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("What gets cleaned")
                    .font(.system(size: 13, weight: .semibold))
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                          spacing: 10) {
                    ForEach(cleanCategories) { cat in
                        HStack(spacing: 10) {
                            Image(systemName: cat.systemImage)
                                .foregroundStyle(Theme.accent)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(cat.name).font(.system(size: 12, weight: .medium))
                                Text(cat.detail).font(.system(size: 10)).foregroundStyle(.secondary)
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
                    Text("Run a preview to see exactly what Mole would remove — safely, with no changes made.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                } else {
                    ConsoleOutputView(lines: runner.lines)
                        .frame(minHeight: 220, maxHeight: 360)
                }
            }
        }
    }

    private var phaseLabel: String {
        switch phase {
        case .idle: return "Output"
        case .previewing: return "Previewing (dry-run)…"
        case .previewed: return "Preview ready"
        case .running: return "Cleaning…"
        case .done: return "Finished"
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        if runner.isRunning {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("running").font(.system(size: 10))
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
        } else if let code = runner.exitCode {
            let tone: StatusTone = code == 0 ? .good : .critical
            Text(code == 0 ? "✓ exit 0" : "exit \(code)")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Theme.color(for: tone).opacity(0.18), in: Capsule())
                .foregroundStyle(Theme.color(for: tone))
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
