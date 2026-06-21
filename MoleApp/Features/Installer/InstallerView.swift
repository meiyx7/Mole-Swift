import SwiftUI

/// Installer files screen.
///
/// Unlike the other cleanup screens, the installer CLI's preview path is
/// interactive-only (it launches a TTY selection menu), so we can't get a
/// file list from `mo installer --dry-run`. Instead, `InstallerScanner`
/// discovers the files directly in Swift and renders them as a visual list.
/// The "Run" action still shells out to `mo installer` for the actual
/// deletion (with Trash routing, safety checks, etc.).
///
/// 布局规范（与 CleanupScreen/PurgeInteractiveView 一致）：
/// header（无按钮）→ stepGuide → categoriesCard（功能说明）→ previewCard（扫描结果 + 内嵌操作栏）。
struct InstallerView: View {
    @EnvironmentObject private var service: MoleService
    @EnvironmentObject private var loc: Localization
    @StateObject private var runner = CommandRunner()
    @State private var phase: Phase = .idle
    @State private var showConfirm = false
    @State private var showRawConsole = false
    @State private var showCategories = true
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
                .alert(loc.t("运行安装包清理？", "Run installer cleanup?"), isPresented: $showConfirm) {
                    Button(loc.t("取消", "Cancel"), role: .cancel) {}
                    Button(loc.t("运行", "Run"), role: .destructive) { runNow() }
                } message: {
                    Text(loc.t("这将通过 Mole CLI 永久删除扫描到的安装包文件，此操作不可撤销。", "This will permanently delete the scanned installer files via the Mole CLI. This cannot be undone."))
                }
                .onReceive(NotificationCenter.default.publisher(for: .moleRefresh)) { _ in
                    if !runner.isRunning { scanNow() }
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        FeatureHeader(
            title: loc.t("安装包文件", "Installer Files"),
            subtitle: loc.t("查找并删除残留的安装包、DMG、PKG 和 ISO 文件。", "Find and remove leftover installers, DMGs, PKGs and ISOs."),
            systemImage: "shippingbox.fill"
        )
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

    // MARK: - Idle hero card

    private var idleHeroCard: some View {
        Card(padding: 0) {
            VStack(spacing: 14) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 32, weight: .light))
                    .foregroundColor(Theme.accent.opacity(0.7))
                Text(loc.t("点击「开始扫描」查找可安全删除的安装包文件（.dmg、.pkg、.iso、.xip、.zip）。",
                           "Click \"Start Scan\" to find installer files safe to delete (.dmg, .pkg, .iso, .xip, .zip)."))
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)
                Button {
                    scanNow()
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
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 10) {
                        categoryRow(loc.t(".dmg 文件", ".dmg Files"), loc.t("下载与桌面目录中的磁盘镜像安装包", "Disk image installers in Downloads & Desktop"), "opticaldiscdrive")
                        categoryRow(loc.t(".pkg 文件", ".pkg Files"), loc.t("macOS 安装包", "macOS package installers"), "archivebox")
                        categoryRow(loc.t(".iso 文件", ".iso Files"), loc.t("光盘镜像与虚拟机安装包", "Disc images and VM installers"), "opticaldisc")
                        categoryRow(loc.t(".xip 文件", ".xip Files"), loc.t("Apple 签名压缩包", "Apple signed archives"), "doc.zipper")
                        categoryRow(loc.t(".zip 压缩包", ".zip Archives"), loc.t("下载目录中的压缩包", "Archives in Downloads"), "app")
                        categoryRow(loc.t("Homebrew 缓存", "Homebrew Cache"), loc.t("Brew 下载缓存", "Brew download cache"), "internaldrive")
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showCategories)
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

    // MARK: - Preview card (扫描结果 + 内嵌操作栏)

    private var previewCard: some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                // 头部：标题 + 状态
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
            Text(loc.t("点击「开始扫描」查找可安全删除的安装包文件（.dmg、.pkg、.iso、.xip、.zip）。",
                       "Click \"Start Scan\" to find installer files safe to delete (.dmg, .pkg, .iso, .xip, .zip)."))
                .font(.system(size: 12)).foregroundColor(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                .multilineTextAlignment(.center)
                .padding(12)
        } else if phase == .scanning {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(loc.t("正在扫描下载、桌面等目录…", "Scanning Downloads, Desktop, and other paths…"))
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
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
        } else {
            // scanned
            if showRawConsole {
                ConsoleOutputView(lines: runner.lines)
                    .frame(minHeight: 220, maxHeight: 360)
                    .padding(12)
            } else if !foundFiles.isEmpty {
                filesList
                    .padding(12)
            } else if let err = scanError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 28)).foregroundColor(Theme.color(for: .critical))
                    Text(loc.t("扫描出错：", "Scan error: ") + err)
                        .font(.system(size: 12)).foregroundColor(Theme.color(for: .critical))
                }
                .frame(maxWidth: .infinity, minHeight: 120)
                .padding(12)
            } else {
                // Scanned but nothing found.
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 28)).foregroundColor(Theme.color(for: .good))
                    Text(loc.t("未发现安装包文件，你的 Mac 很干净！", "No installer files found. Your Mac is clean!"))
                        .font(.system(size: 12)).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
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
                    Text(loc.t("安装包文件已永久删除。",
                               "Installer files permanently deleted."))
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                Spacer()
            }
        }
        .padding(12)
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

    // MARK: - Action bar (内嵌在扫描结果卡片底部，四个模块统一)

    @ViewBuilder
    private var actionBar: some View {
        HStack {
            switch phase {
            case .idle:
                Spacer()
                Button {
                    scanNow()
                } label: {
                    Label(loc.t("开始扫描", "Start Scan"), systemImage: "magnifyingglass")
                }
                .buttonStyle(PrimaryButtonStyle())
            case .scanning:
                Spacer()
                Button(loc.t("停止", "Stop"), role: .destructive) { runner.cancel() }
                    .buttonStyle(.bordered)
            case .scanned:
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
                    Label(loc.t("运行", "Run"), systemImage: "shippingbox.fill")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(PrimaryButtonStyle(disabled: foundFiles.isEmpty))
                .disabled(foundFiles.isEmpty)
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
            }
        }
    }

    // MARK: - Status pill

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
            Text(code == 0 ? loc.t("✓ 完成", "✓ done") : loc.t("退出 \(code)", "exit \(code)"))
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Theme.color(for: tone).opacity(0.18), in: Capsule())
                .foregroundColor(Theme.color(for: tone))
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

    // MARK: - Actions

    private func scanNow() {
        phase = .scanning
        showCategories = false
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
            await runner.runAwaited { onLine in
                try await service.installer(onLine: onLine)
            }
            phase = .done
        }
    }

    private func resetToIdle() {
        runner.cancel()
        runner.lines.removeAll()
        runner.exitCode = nil
        runner.error = nil
        foundFiles.removeAll()
        scanError = nil
        phase = .idle
        showCategories = true
    }
}
