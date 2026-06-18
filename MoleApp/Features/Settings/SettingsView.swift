import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var service: MoleService
    @State private var version = ""
    @State private var touchidStatus = ""
    @State private var completionScript = ""
    @State private var selectedShell = "zsh"
    @StateObject private var runner = CommandRunner()
    @StateObject private var touchidRunner = CommandRunner()
    @State private var showRemoveAlert = false
    @State private var removePreview = ""
    @State private var helpText = ""
    @State private var showHelp = false

    private let shells = ["bash", "zsh", "fish"]

    var body: some View {
        if !service.isInstalled {
            CLIUnavailableView()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    aboutCard
                    touchidCard
                    completionCard
                    updateCard
                    removeCard
                    if runner.hasOutput || runner.isRunning { consoleCard }
                }
            }
            .featurePadding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .alert("Remove Mole?", isPresented: $showRemoveAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Remove", role: .destructive) { runRemove() }
            } message: {
                Text("This uninstalls the Mole CLI from your system. The app will no longer be able to run commands.")
            }
            .task {
                version = await service.version()
                touchidStatus = await service.touchidStatus()
            }
        }
    }

    private var header: some View {
        FeatureHeader(
            title: "Settings",
            subtitle: "Configure Touch ID, shell completion, updates and removal.",
            systemImage: "gearshape"
        )
    }

    private var aboutCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("About").font(.system(size: 13, weight: .semibold))
                HStack {
                    Label("CLI Version", systemImage: "tag").foregroundStyle(.secondary)
                    Spacer()
                    Text(version.isEmpty ? "—" : version)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                }
                HStack {
                    Label("Binary", systemImage: "terminal").foregroundStyle(.secondary)
                    Spacer()
                    Text(CLILocator.resolve() ?? "not found")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                HStack {
                    Label("GUI Version", systemImage: "app").foregroundStyle(.secondary)
                    Spacer()
                    Text("Mole 1.0.0")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                }
                Divider()
                Button {
                    if helpText.isEmpty { Task { helpText = await service.help() } }
                    showHelp.toggle()
                } label: {
                    Label(showHelp ? "Hide CLI Help" : "View CLI Help", systemImage: "questionmark.circle")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                if showHelp && !helpText.isEmpty {
                    ScrollView {
                        Text(helpText)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var touchidCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Touch ID for sudo", systemImage: "touchid")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if !touchidStatus.isEmpty {
                        Text(touchidStatus)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(touchidStatus.lowercased().contains("enabl") ? Color.green.opacity(0.18) : Color.gray.opacity(0.18),
                                        in: Capsule())
                            .foregroundStyle(touchidStatus.lowercased().contains("enabl") ? .green : .secondary)
                    }
                }
                Text("Authenticate sudo commands with Touch ID instead of typing your password.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button {
                        Task {
                            await touchidRunner.run { onLine in
                                try await service.touchidEnable(onLine: onLine)
                            }
                            touchidStatus = await service.touchidStatus()
                        }
                    } label: { Label("Enable", systemImage: "checkmark.circle") }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(touchidRunner.isRunning)

                    Button {
                        Task {
                            await touchidRunner.run { onLine in
                                try await service.touchidDisable(onLine: onLine)
                            }
                            touchidStatus = await service.touchidStatus()
                        }
                    } label: { Label("Disable", systemImage: "xmark.circle") }
                        .buttonStyle(.bordered)
                        .disabled(touchidRunner.isRunning)

                    Spacer()
                    Button { Task { touchidStatus = await service.touchidStatus() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }.buttonStyle(.borderless)
                }
                if touchidRunner.hasOutput {
                    ConsoleOutputView(lines: touchidRunner.lines).frame(minHeight: 80, maxHeight: 140)
                }
            }
        }
    }

    private var completionCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("Shell Completion", systemImage: "text.append")
                    .font(.system(size: 13, weight: .semibold))
                Text("Generate tab-completion scripts for your shell.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Picker("Shell", selection: $selectedShell) {
                        ForEach(shells, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented).frame(width: 210)
                    Button {
                        Task { completionScript = await service.completionScript(for: selectedShell) }
                    } label: { Label("Generate", systemImage: "doc.text") }
                        .buttonStyle(.bordered)
                    Button {
                        Task {
                            await runner.run { onLine in
                                try await service.installCompletion(onLine: onLine)
                            }
                        }
                    } label: { Label("Auto-install", systemImage: "wand.and.stars") }
                        .buttonStyle(PrimaryButtonStyle())
                }
                if !completionScript.isEmpty {
                    ScrollView {
                        Text(completionScript)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var updateCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("Update Mole", systemImage: "arrow.up.circle")
                    .font(.system(size: 13, weight: .semibold))
                Text("Check for and install the latest version of the Mole CLI.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button {
                        Task {
                            await runner.run { onLine in
                                try await service.update(force: false, nightly: false, onLine: onLine)
                            }
                            version = await service.version()
                        }
                    } label: { Label("Check & Update", systemImage: "arrow.triangle.2.circlepath") }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(runner.isRunning)
                    Button {
                        Task {
                            await runner.run { onLine in
                                try await service.update(force: true, nightly: false, onLine: onLine)
                            }
                            version = await service.version()
                        }
                    } label: { Label("Force", systemImage: "exclamationmark.arrow.circlepath") }
                        .buttonStyle(.bordered)
                        .disabled(runner.isRunning)
                }
            }
        }
    }

    private var removeCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("Remove Mole", systemImage: "trash")
                    .font(.system(size: 13, weight: .semibold))
                Text("Uninstall the Mole CLI from your system.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button {
                        Task { removePreview = await service.removePreview() }
                    } label: { Label("Preview", systemImage: "eye") }
                        .buttonStyle(.bordered)
                    Button { showRemoveAlert = true } label: {
                        Label("Remove", systemImage: "trash")
                    }
                    .buttonStyle(PrimaryButtonStyle(tint: .red))
                }
                if !removePreview.isEmpty {
                    ScrollView {
                        Text(removePreview)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var consoleCard: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(runner.isRunning ? "Working…" : "Output", systemImage: "terminal")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if let code = runner.exitCode {
                        Text(code == 0 ? "✓ done" : "exit \(code)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(code == 0 ? .green : .red)
                    }
                }
                ConsoleOutputView(lines: runner.lines).frame(minHeight: 120, maxHeight: 240)
            }
        }
    }

    private func runRemove() {
        Task {
            await runner.run { onLine in
                try await service.remove(onLine: onLine)
            }
            service.refreshInstallation()
        }
    }
}
