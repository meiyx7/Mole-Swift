import SwiftUI

/// Installer files screen.
///
/// Unlike the other cleanup screens, the installer CLI's preview path is
/// interactive-only (it launches a TTY selection menu), so we can't get a
/// file list from `mo installer --dry-run`. Instead, `InstallerScanner`
/// discovers the files directly in Swift and renders them as a visual list.
/// The "Run" action still shells out to `mo installer` for the actual
/// deletion (with Trash routing, safety checks, etc.).
struct InstallerView: View {
    @EnvironmentObject private var service: MoleService
    @EnvironmentObject private var loc: Localization
    @StateObject private var runner = CommandRunner()
    @State private var phase: Phase = .idle
    @State private var showConfirm = false
    @State private var showRawConsole = false
    @State private var foundFiles: [InstallerScanner.FoundFile] = []
    @State private var scanError: String?

    private enum Phase: Equatable { case idle, scanning, scanned, running, done }

    private var totalSize: Int64 {
        foundFiles.reduce(0) { $0 + $1.sizeBytes }
    }

    var body: some View {
        Group {
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
                .alert(loc.t("运行安装包清理？", "Run installer cleanup?"), isPresented: $showConfirm) {
                    Button(loc.t("取消", "Cancel"), role: .cancel) {}
                    Button(loc.t("运行", "Run"), role: .destructive) { runNow() }
                } message: {
                    Text(loc.t("这将通过 Mole CLI 删除扫描到的安装包文件（路由到废纸篓）。", "This will delete the scanned installer files via the Mole CLI (routed to Trash)."))
                }
                .onReceive(NotificationCenter.default.publisher(for: .moleRefresh)) { _ in
                    if !runner.isRunning { scanNow() }
                }
            }
        }
    }

    // MARK: - Header & actions

    private var header: some View {
        FeatureHeader(
            title: loc.t("安装包文件", "Installer Files"),
            subtitle: loc.t("查找并删除残留的安装包、DMG、PKG 和 ISO 文件。", "Find and remove leftover installers, DMGs, PKGs and ISOs."),
            systemImage: "shippingbox.fill",
            trailing: AnyView(actionButtons)
        )
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            if runner.isRunning {
                Button(loc.t("停止", "Stop"), role: .destructive) { runner.cancel() }.buttonStyle(.bordered)
            } else {
                Button {
                    if phase == .scanned {
                        showConfirm = true
                    } else {
                        scanNow()
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
        if phase == .idle || phase == .scanning { return true }
        if phase == .scanned { return !foundFiles.isEmpty }
        return false
    }

    private var primaryActionLabel: String {
        switch phase {
        case .idle, .scanning: return loc.t("扫描", "Scan")
        case .scanned:         return loc.t("运行", "Run")
        case .running:         return loc.t("运行中…", "Running…")
        case .done:            return loc.t("已完成", "Done")
        }
    }

    private var primaryActionIcon: String {
        switch phase {
        case .idle, .scanning: return "magnifyingglass"
        case .scanned:         return "shippingbox.fill"
        case .running:         return "circle.dashed"
        case .done:            return "checkmark.circle.fill"
        }
    }

    // MARK: - Step guide

    private var stepGuide: some View {
        HStack(spacing: 10) {
            StepDot(n: 1, label: loc.t("扫描", "Scan"), active: phase == .idle || phase == .scanning, done: phaseIsAfterScan)
            StepConnector(active: phaseIsAfterScan)
            StepDot(n: 2, label: loc.t("查看", "Review"), active: phase == .scanned, done: phase == .running || phase == .done)
            StepConnector(active: phase == .running || phase == .done)
            StepDot(n: 3, label: loc.t("执行", "Run"), active: phase == .running, done: phase == .done)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var phaseIsAfterScan: Bool {
        phase == .scanned || phase == .running || phase == .done
    }

    // MARK: - Categories card

    private var categoriesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text(loc.t("功能说明", "What this does"))
                    .font(.system(size: 13, weight: .semibold))
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 10) {
                    categoryRow(loc.t(".dmg 文件", ".dmg Files"), loc.t("下载与桌面目录中的磁盘镜像安装包", "Disk image installers in Downloads & Desktop"), "opticaldiscdrive")
                    categoryRow(loc.t(".pkg 文件", ".pkg Files"), loc.t("macOS 安装包", "macOS package installers"), "archivebox")
                    categoryRow(loc.t(".iso 文件", ".iso Files"), loc.t("光盘镜像与虚拟机安装包", "Disc images and VM installers"), "opticaldisc")
                    categoryRow(loc.t(".xip 文件", ".xip Files"), loc.t("Apple 签名压缩包", "Apple signed archives"), "doc.zipper")
                    categoryRow(loc.t(".zip 压缩包", ".zip Archives"), loc.t("下载目录中的压缩包", "Archives in Downloads"), "app")
                    categoryRow(loc.t("Homebrew 缓存", "Homebrew Cache"), loc.t("Brew 下载缓存", "Brew download cache"), "internaldrive")
                }
            }
        }
    }

    private func categoryRow(_ name: String, _ detail: String, _ icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundColor(Theme.accent).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 10)).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Preview card

    private var previewCard: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(phaseLabel, systemImage: "shippingbox")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    statusPill
                    if runner.hasOutput {
                        Button { showRawConsole.toggle() } label: {
                            Image(systemName: showRawConsole ? "list.bullet.indent" : "terminal")
                                .font(.system(size: 11))
                                .help(loc.t("切换原始输出", "Toggle raw output"))
                        }
                        .buttonStyle(.borderless)
                    }
                }

                if phase == .idle {
                    Text(loc.t("点击「扫描」查找可安全删除的安装包文件（.dmg、.pkg、.iso、.xip、.zip）。", "Click \"Scan\" to find installer files safe to delete (.dmg, .pkg, .iso, .xip, .zip)."))
                        .font(.system(size: 12)).foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                        .multilineTextAlignment(.center)
                } else if phase == .scanning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(loc.t("正在扫描下载、桌面等目录…", "Scanning Downloads, Desktop, and other paths…"))
                            .font(.system(size: 12)).foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                } else if showRawConsole {
                    ConsoleOutputView(lines: runner.lines)
                        .frame(minHeight: 220, maxHeight: 360)
                } else if !foundFiles.isEmpty {
                    filesList
                } else if let err = scanError {
                    Text(loc.t("扫描出错：", "Scan error: ") + err)
                        .font(.system(size: 12)).foregroundColor(Theme.color(for: .critical))
                        .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
                } else {
                    // Scanned but nothing found.
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 28)).foregroundColor(Theme.color(for: .good))
                        Text(loc.t("未发现安装包文件，你的 Mac 很干净！", "No installer files found. Your Mac is clean!"))
                            .font(.system(size: 12)).foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                }
            }
        }
    }

    private var filesList: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Stat row
            HStack(spacing: 12) {
                StatTile(title: loc.t("可回收空间", "Reclaimable"),
                         value: ByteFormatter.bytes(totalSize),
                         systemImage: "arrow.down.circle.fill",
                         tone: .good)
                StatTile(title: loc.t("文件数", "Files"),
                         value: "\(foundFiles.count)",
                         systemImage: "doc.on.doc.fill",
                         tone: .neutral)
            }
            Divider()
            // File rows
            ForEach(foundFiles) { file in
                fileRow(file)
            }
        }
    }

    private func fileRow(_ file: InstallerScanner.FoundFile) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: fileIcon(for: file.url.pathExtension))
                .foregroundColor(Theme.color(for: .good))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.displayName).font(.system(size: 12, weight: .medium))
                Text(file.source + " · " + file.url.deletingLastPathComponent().path)
                    .font(.system(size: 10)).foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Text(file.sizeText)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(Theme.color(for: .good))
        }
        .padding(.vertical, 1)
    }

    private func fileIcon(for ext: String) -> String {
        switch ext.lowercased() {
        case "dmg": return "opticaldiscdrive"
        case "pkg", "mpkg": return "archivebox"
        case "iso": return "opticaldisc"
        case "xip": return "doc.zipper"
        case "zip": return "app"
        default: return "doc"
        }
    }

    private var phaseLabel: String {
        switch phase {
        case .idle: return loc.t("扫描结果", "Scan Results")
        case .scanning: return loc.t("扫描中…", "Scanning…")
        case .scanned: return loc.t("扫描完成", "Scan Complete")
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

    // MARK: - Actions

    private func scanNow() {
        phase = .scanning
        scanError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let files = InstallerScanner.scan()
            DispatchQueue.main.async {
                self.foundFiles = files
                self.phase = .scanned
            }
        }
    }

    private func runNow() {
        phase = .running
        Task {
            await runner.run { onLine in
                try await service.installer(onLine: onLine)
            }
            phase = .done
        }
    }
}
