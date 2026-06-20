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
    @State private var helpText = ""
    @State private var showHelp = false
    @State private var userInitiatedCheck = false

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
    /// Uses the shared `UpdateChecker.parseVersion` for consistency.
    private func versionMeets(_ v: String, min: String) -> Bool {
        let vp = UpdateChecker.parseVersion(v)
        let mp = UpdateChecker.parseVersion(min)
        if vp.major != mp.major { return vp.major > mp.major }
        if vp.minor != mp.minor { return vp.minor > mp.minor }
        return vp.patch >= mp.patch
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
                    if runner.hasOutput || runner.isRunning || runner.exitCode != nil || runner.error != nil { consoleCard }
                    // About section last (reference info, low interaction).
                    aboutCard
                }
            }
            .featurePadding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .task {
                version = await service.version()
                touchidStatus = await service.touchidStatus()
                touchidSupported = Self.checkTouchIDSupport()
            }
            .onReceive(NotificationCenter.default.publisher(for: .moleCheckUpdates)) { _ in
                Task { await updater.checkForUpdates() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .moleRefresh)) { _ in
                Task {
                    version = await service.version()
                    touchidStatus = await service.touchidStatus()
                }
            }
            .onChange(of: updater.state) { newState in
                // When a user-initiated check finds an update, surface it
                // in-card so the user can download & install in place.
                // We no longer auto-open the browser; the in-app installer
                // handles the whole flow.
                if userInitiatedCheck, case .available = newState {
                    userInitiatedCheck = false
                }
            }
        }
    }

    private var header: some View {
        FeatureHeader(
            title: loc.t("设置", "Settings"),
            subtitle: loc.t("配置 Touch ID 与更新。", "Configure Touch ID and updates."),
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

                // GUI App update check + in-app install
                HStack(spacing: 8) {
                    Button {
                        userInitiatedCheck = true
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
                    .disabled(isCheckingUpdate || isInstalling)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(loc.t("应用更新", "App Update"))
                            .font(.system(size: 12, weight: .medium))
                        Text(loc.t("检查并安装 Mole 应用最新版本。", "Check for and install the latest Mole app version."))
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
                    }
                    .padding(.vertical, 4)
                }

                // In-app download + install controls, shown when an update
                // is available or an install is in progress.
                if case .available(let version, _, _) = updater.state {
                    installControls(version: version)
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

    /// Whether an install (download/replace) is currently in flight.
    private var isInstalling: Bool {
        switch updater.installState {
        case .idle, .done, .error: return false
        case .downloading, .extracting, .replacing: return true
        }
    }

    /// Download / install / cancel controls shown when an update is available.
    @ViewBuilder
    private func installControls(version: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch updater.installState {
            case .idle:
                HStack(spacing: 8) {
                    Button {
                        Task { await updater.downloadAndInstall() }
                    } label: {
                        Label(loc.t("下载并安装 \(version)", "Download & Install \(version)"), systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    Button {
                        if let url = URL(string: githubReleaseURL(for: version)) {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label(loc.t("在浏览器查看", "View in Browser"), systemImage: "safari")
                    }
                    .buttonStyle(.bordered)
                }
            case .downloading(let progress):
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(loc.t("正在下载 \(version)…", "Downloading \(version)…"))
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text("\(Int(progress * 100))%")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundColor(.secondary)
                        Button {
                            updater.cancelInstall()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(loc.t("取消下载", "Cancel download"))
                    }
                    ProgressBar(value: progress * 100, tone: .good, height: 6)
                }
                .padding(.vertical, 4)
            case .extracting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(loc.t("正在解压…", "Extracting…"))
                        .font(.system(size: 12)).foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            case .replacing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(loc.t("正在替换应用，可能需要输入密码…", "Replacing app, may require your password…"))
                        .font(.system(size: 12)).foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            case .done:
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text(loc.t("安装完成，正在重启…", "Installed, relaunching…"))
                        .font(.system(size: 12)).foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            case .error(let msg):
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text(loc.t("安装失败：\(msg)", "Install failed: \(msg)"))
                        .font(.system(size: 11)).foregroundColor(.orange)
                    Spacer()
                    Button {
                        Task { await updater.downloadAndInstall() }
                    } label: {
                        Label(loc.t("重试", "Retry"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// Builds the GitHub release page URL for a given version tag.
    private func githubReleaseURL(for version: String) -> String {
        "https://github.com/meiyx7/Mole-Swift/releases/tag/v\(version)"
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
                text: loc.t("发现新版本 \(v)，点击下方按钮下载并安装。", "Version \(v) available. Click the button below to download and install."),
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
}
