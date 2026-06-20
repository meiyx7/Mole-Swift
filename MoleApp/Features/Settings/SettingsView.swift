import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var service: MoleService
    @EnvironmentObject private var loc: Localization
    @EnvironmentObject private var updater: UpdateChecker
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
    @State private var showUpdateAlert = false

    private let shells = ["bash", "zsh", "fish"]

    /// GUI version read from the main Bundle (not hardcoded).
    private var guiVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        if !service.isInstalled {
            CLIUnavailableView()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    languageCard
                    aboutCard
                    touchidCard
                    completionCard
                    updateCard
                    removeCard
                    if runner.hasOutput || runner.isRunning || runner.exitCode != nil || runner.error != nil { consoleCard }
                }
            }
            .featurePadding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .alert(loc.t("移除 Mole？", "Remove Mole?"), isPresented: $showRemoveAlert) {
                Button(loc.t("取消", "Cancel"), role: .cancel) {}
                Button(loc.t("移除", "Remove"), role: .destructive) { runRemove() }
            } message: {
                Text(loc.t(
                    "这将从系统卸载 Mole CLI。卸载后应用将无法再运行命令。",
                    "This uninstalls the Mole CLI from your system. The app will no longer be able to run commands."
                ))
            }
            .task {
                version = await service.version()
                touchidStatus = await service.touchidStatus()
            }
            .onReceive(NotificationCenter.default.publisher(for: .moleCheckUpdates)) { _ in
                Task { await updater.checkForUpdates() }
            }
        }
    }

    private var header: some View {
        FeatureHeader(
            title: loc.t("设置", "Settings"),
            subtitle: loc.t("配置 Touch ID、Shell 补全、更新与卸载。", "Configure Touch ID, shell completion, updates and removal."),
            systemImage: "gearshape"
        )
    }

    private var languageCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(loc.t("界面语言", "Interface Language"), systemImage: "globe")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                }
                Text(loc.t(
                    "选择应用界面语言，更改立即生效。",
                    "Choose the app interface language. Changes apply immediately."
                ))
                .font(.system(size: 11)).foregroundColor(.secondary)
                Picker(loc.t("语言", "Language"), selection: Binding(
                    get: { loc.language },
                    set: { loc.setLanguage($0) }
                )) {
                    ForEach(Language.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private var aboutCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text(loc.t("关于", "About")).font(.system(size: 13, weight: .semibold))
                HStack {
                    Label(loc.t("CLI 版本", "CLI Version"), systemImage: "tag").foregroundColor(.secondary)
                    Spacer()
                    Text(version.isEmpty ? "—" : version)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                }
                HStack {
                    Label(loc.t("可执行文件", "Binary"), systemImage: "terminal").foregroundColor(.secondary)
                    Spacer()
                    Text(CLILocator.resolve() ?? loc.t("未找到", "not found"))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                HStack {
                    Label(loc.t("GUI 版本", "GUI Version"), systemImage: "app").foregroundColor(.secondary)
                    Spacer()
                    Text("Mole \(guiVersion)")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                }
                Divider()
                Button {
                    if helpText.isEmpty { Task { helpText = await service.help() } }
                    showHelp.toggle()
                } label: {
                    Label(showHelp ? loc.t("隐藏 CLI 帮助", "Hide CLI Help")
                                   : loc.t("查看 CLI 帮助", "View CLI Help"),
                          systemImage: "questionmark.circle")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                if showHelp && !helpText.isEmpty {
                    ScrollView {
                        Text(helpText)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
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
                    Label(loc.t("用于 sudo 的 Touch ID", "Touch ID for sudo"), systemImage: "touchid")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if !touchidStatus.isEmpty {
                        Text(touchidStatus)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(touchidStatus.lowercased().contains("enabl") ? Color.green.opacity(0.18) : Color.gray.opacity(0.18),
                                        in: Capsule())
                            .foregroundColor(touchidStatus.lowercased().contains("enabl") ? .green : .secondary)
                    }
                }
                Text(loc.t(
                    "使用 Touch ID 进行 sudo 命令验证，无需输入密码。",
                    "Authenticate sudo commands with Touch ID instead of typing your password."
                ))
                .font(.system(size: 11)).foregroundColor(.secondary)
                HStack(spacing: 8) {
                    Button {
                        Task {
                            await touchidRunner.run { onLine in
                                try await service.touchidEnable(onLine: onLine)
                            }
                            touchidStatus = await service.touchidStatus()
                        }
                    } label: { Label(loc.t("启用", "Enable"), systemImage: "checkmark.circle") }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(touchidRunner.isRunning)

                    Button {
                        Task {
                            await touchidRunner.run { onLine in
                                try await service.touchidDisable(onLine: onLine)
                            }
                            touchidStatus = await service.touchidStatus()
                        }
                    } label: { Label(loc.t("禁用", "Disable"), systemImage: "xmark.circle") }
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
                Label(loc.t("Shell 补全", "Shell Completion"), systemImage: "text.append")
                    .font(.system(size: 13, weight: .semibold))
                Text(loc.t("为你的 Shell 生成 Tab 补全脚本。", "Generate tab-completion scripts for your shell."))
                    .font(.system(size: 11)).foregroundColor(.secondary)
                HStack(spacing: 8) {
                    Picker(loc.t("Shell", "Shell"), selection: $selectedShell) {
                        ForEach(shells, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented).frame(width: 210)
                    Button {
                        Task { completionScript = await service.completionScript(for: selectedShell) }
                    } label: { Label(loc.t("生成", "Generate"), systemImage: "doc.text") }
                        .buttonStyle(.bordered)
                    Button {
                        Task {
                            await runner.run { onLine in
                                try await service.installCompletion(onLine: onLine)
                            }
                        }
                    } label: { Label(loc.t("自动安装", "Auto-install"), systemImage: "wand.and.stars") }
                        .buttonStyle(PrimaryButtonStyle())
                }
                if !completionScript.isEmpty {
                    ScrollView {
                        Text(completionScript)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
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
                Label(loc.t("更新 Mole", "Update Mole"), systemImage: "arrow.up.circle")
                    .font(.system(size: 13, weight: .semibold))

                // GUI App update check
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(loc.t("应用更新", "App Update"))
                            .font(.system(size: 12, weight: .medium))
                        Text(loc.t("检查 Mole 应用最新版本。", "Check for the latest Mole app version."))
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { await updater.checkForUpdates() }
                    } label: {
                        HStack(spacing: 4) {
                            if case .checking = updater.state {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.7)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            Text(loc.t("检查更新", "Check"))
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(isCheckingUpdate)
                }

                if let updateMsg = updateStatusText {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: updateMsg.icon)
                            .foregroundColor(updateMsg.color)
                            .font(.system(size: 11))
                        Text(updateMsg.text)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                        if case .available = updater.state {
                            Button(loc.t("下载", "Download")) {
                                if case .available(_, let url, _) = updater.state {
                                    if let u = URL(string: url) { NSWorkspace.shared.open(u) }
                                }
                            }
                            .font(.system(size: 11, weight: .medium))
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Divider()

                Text(loc.t("CLI 更新", "CLI Update"))
                    .font(.system(size: 12, weight: .medium))
                Text(loc.t("检查并安装最新版本的 Mole CLI。", "Check for and install the latest version of the Mole CLI."))
                    .font(.system(size: 11)).foregroundColor(.secondary)
                HStack(spacing: 8) {
                    Button {
                        Task {
                            await runner.runAwaited { onLine in
                                try await service.update(force: false, nightly: false, onLine: onLine)
                            }
                            version = await service.version()
                        }
                    } label: { Label(loc.t("检查并更新", "Check & Update"), systemImage: "arrow.triangle.2.circlepath") }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(runner.isRunning)
                    Button {
                        Task {
                            await runner.runAwaited { onLine in
                                try await service.update(force: true, nightly: false, onLine: onLine)
                            }
                            version = await service.version()
                        }
                    } label: { Label(loc.t("强制", "Force"), systemImage: "exclamationmark.arrow.circlepath") }
                        .buttonStyle(.bordered)
                        .disabled(runner.isRunning)
                }
            }
        }
    }

    private var isCheckingUpdate: Bool {
        if case .checking = updater.state { return true }
        return false
    }

    private struct UpdateStatus {
        let text: String
        let icon: String
        let color: Color
    }

    private var updateStatusText: UpdateStatus? {
        switch updater.state {
        case .idle, .checking:
            return nil
        case .upToDate:
            return UpdateStatus(
                text: loc.t("已是最新版本。", "You're up to date."),
                icon: "checkmark.circle.fill",
                color: .green
            )
        case .available(let v, _, _):
            return UpdateStatus(
                text: loc.t("发现新版本 \(v)，点击下载。", "Version \(v) is available. Click to download."),
                icon: "arrow.up.circle.fill",
                color: .blue
            )
        case .error(let msg):
            return UpdateStatus(
                text: loc.t("检查失败：\(msg)", "Check failed: \(msg)"),
                icon: "exclamationmark.triangle.fill",
                color: .orange
            )
        }
    }

    private var removeCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label(loc.t("移除 Mole", "Remove Mole"), systemImage: "trash")
                    .font(.system(size: 13, weight: .semibold))
                Text(loc.t("从系统卸载 Mole CLI。", "Uninstall the Mole CLI from your system."))
                    .font(.system(size: 11)).foregroundColor(.secondary)
                HStack(spacing: 8) {
                    Button {
                        Task { removePreview = await service.removePreview() }
                    } label: { Label(loc.t("预览", "Preview"), systemImage: "eye") }
                        .buttonStyle(.bordered)
                    Button { showRemoveAlert = true } label: {
                        Label(loc.t("移除", "Remove"), systemImage: "trash")
                    }
                    .buttonStyle(PrimaryButtonStyle(tint: .red))
                }
                if !removePreview.isEmpty {
                    ScrollView {
                        Text(removePreview)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
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
                    Label(runner.isRunning ? loc.t("执行中…", "Working…") : loc.t("输出", "Output"), systemImage: "terminal")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if let code = runner.exitCode {
                        Text(code == 0 ? loc.t("✓ 完成", "✓ done") : loc.t("退出 \(code)", "exit \(code)"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(code == 0 ? .green : .red)
                    }
                }
                if runner.lines.isEmpty && !runner.isRunning {
                    if let err = runner.error {
                        Text(err)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(loc.t("命令已完成，无输出。", "Command completed with no output."))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    ConsoleOutputView(lines: runner.lines).frame(minHeight: 120, maxHeight: 240)
                }
            }
        }
    }

    private func runRemove() {
        Task {
            await runner.runAwaited { onLine in
                try await service.remove(onLine: onLine)
            }
            service.refreshInstallation()
        }
    }
}
