import SwiftUI
import LocalAuthentication

struct SettingsView: View {
    @EnvironmentObject private var service: MoleService
    @EnvironmentObject private var loc: Localization
    @EnvironmentObject private var updater: UpdateChecker
    @State private var version = ""
    @State private var touchidStatus = ""
    @State private var touchidSupported = false
    @StateObject private var runner = CommandRunner()
    @StateObject private var touchidRunner = CommandRunner()
    @State private var showRemoveAlert = false
    @State private var removePreview = ""
    @State private var helpText = ""
    @State private var showHelp = false
    @State private var showUpdateAlert = false

    /// Minimum Mole CLI version this GUI app is compatible with.
    /// Bump when a new feature relies on CLI behavior not present in
    /// older releases. The current value reflects the CLI version the
    /// app was developed and tested against.
    private let minCLIVersion = "1.43.1"

    /// GUI version read from the main Bundle (not hardcoded).
    private var guiVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    /// Whether the installed CLI version meets the minimum requirement.
    private var cliCompatible: Bool {
        versionMeets(version, min: minCLIVersion)
    }

    /// Returns true when `v` >= `min` (semantic version compare).
    private func versionMeets(_ v: String, min: String) -> Bool {
        let vp = parseSemVer(v)
        let mp = parseSemVer(min)
        if vp.major != mp.major { return vp.major > mp.major }
        if vp.minor != mp.minor { return vp.minor > mp.minor }
        return vp.patch >= mp.patch
    }

    private func parseSemVer(_ s: String) -> (major: Int, minor: Int, patch: Int) {
        // Strip leading "v" and any suffix like "-nightly".
        let cleaned = s.hasPrefix("v") ? String(s.dropFirst()) : s
        let base = cleaned.split(separator: "-").first.map(String.init) ?? cleaned
        let parts = base.split(separator: ".").map { Int($0) ?? 0 }
        return (
            parts.count > 0 ? parts[0] : 0,
            parts.count > 1 ? parts[1] : 0,
            parts.count > 2 ? parts[2] : 0
        )
    }

    /// Checks whether this Mac has Touch ID hardware available.
    private static func checkTouchIDSupport() -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return false
        }
        return context.biometryType == .touchID
    }

    var body: some View {
        if !service.isInstalled {
            CLIUnavailableView()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    // High-frequency / interactive sections first.
                    languageCard
                    updateCard
                    if touchidSupported { touchidCard }
                    removeCard
                    if runner.hasOutput || runner.isRunning || runner.exitCode != nil || runner.error != nil { consoleCard }
                    // About section last (reference info, low interaction).
                    aboutCard
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
                touchidSupported = Self.checkTouchIDSupport()
            }
            .onReceive(NotificationCenter.default.publisher(for: .moleCheckUpdates)) { _ in
                Task { await updater.checkForUpdates() }
            }
        }
    }

    private var header: some View {
        FeatureHeader(
            title: loc.t("设置", "Settings"),
            subtitle: loc.t("配置 Touch ID、更新与卸载。", "Configure Touch ID, updates and removal."),
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
                    Label(loc.t("适配 CLI", "Requires CLI"), systemImage: "checkmark.shield").foregroundColor(.secondary)
                    Spacer()
                    Text("≥ \(minCLIVersion)")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(cliCompatible ? .green : .orange)
                }
                if !version.isEmpty && !cliCompatible {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.system(size: 10))
                        Text(loc.t(
                            "当前 CLI 版本过低，部分功能可能不可用。请在下方更新 CLI。",
                            "CLI version is too old. Some features may be unavailable. Update the CLI below."
                        ))
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                    }
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

    private var updateCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label(loc.t("更新 Mole", "Update Mole"), systemImage: "arrow.up.circle")
                    .font(.system(size: 13, weight: .semibold))

                // GUI App update check
                HStack(spacing: 8) {
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
                    VStack(alignment: .leading, spacing: 2) {
                        Text(loc.t("应用更新", "App Update"))
                            .font(.system(size: 12, weight: .medium))
                        Text(loc.t("检查 Mole 应用最新版本。", "Check for the latest Mole app version."))
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    Spacer()
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
