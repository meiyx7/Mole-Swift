import SwiftUI
import AppKit

/// PurgeInteractiveRunner — 宿主 ObservableObject，持有 PTY + tick 定时器，
/// 把 PTY 字节和 tick 作为事件喂给纯 SelectionSession reducer，并执行
/// 返回的 effect（发送按键 / 退出）。
@MainActor
final class PurgeInteractiveRunner: ObservableObject {
    /// 面向视图的阶段。reducer 持有更细的状态，这里折叠为 UI 实际渲染的几种。
    enum Phase: Equatable {
        case scanning, choosing, applying, done(Int32), failed(String)
    }

    @Published var phase: Phase = .scanning
    @Published var items: [MoTUIItem] = []
    @Published var resultText: String = ""
    /// Mole 在 "[n/total]" 头报告的总数。超过 items.count 时 Mole 限制了
    /// 可见行数，UI 据此显示 "共 N 项"。
    @Published var totalCount: Int = 0
    /// "显示全部" 已拉取视口上限之外的所有行。
    @Published var fullyLoaded = false
    /// 滚动捕获进行中（驱动 "正在加载全部 N…" 提示）。
    @Published var loadingAll = false

    private var pty: PTYTask
    private let tickInterval: TimeInterval
    private var state = SelectionSession.State()
    private var timer: DispatchSourceTimer?

    init(tickInterval: TimeInterval = 0.06) {
        self.pty = PTYTask()
        self.tickInterval = tickInterval
    }

    /// （重新）开始扫描，在伪终端中运行 `mo purge`。以用户身份运行（不提权）：
    /// 项目文件夹的 TCC 按 app 钥匙而非 uid，root 也躲不开提示。
    func start() {
        stopTimer()
        pty.terminate()
        // 重建 PTY（一个 Process 只能运行一次）
        pty = PTYTask()
        state = SelectionSession.State()
        publish()
        pty.onOutput = { [weak self] s in
            MainActor.assumeIsolated { self?.dispatch(.output(s)) }
        }
        pty.onExit = { [weak self] code in
            MainActor.assumeIsolated { self?.dispatch(.processExited(code)) }
        }
        guard let mo = CLILocator.resolve() else {
            phase = .failed("未找到 mo 可执行文件")
            return
        }
        do { try pty.launch(mo, ["purge"]) }
        catch { phase = .failed("无法启动 `mo purge`：\(error.localizedDescription)") }
    }

    func rescan() { start() }
    func confirm(_ wanted: Set<Int>) { dispatch(.confirmRequested(wanted)) }
    func loadAll() { dispatch(.showAllRequested) }

    func cancel() {
        // 拆除时不写子进程 — 若已退出，写 'q' 会打到死 PTY。terminate() 干净拆除。
        stopTimer()
        pty.onOutput = nil
        pty.onExit = nil
        pty.terminate()
        switch state.phase {
        case .done, .failed: break
        default: phase = .done(130)
        }
    }

    /// 推进 reducer 的逻辑时钟。tick 定时器调用此方法。
    func tick() { dispatch(.tick) }

    // MARK: - 事件循环

    private func dispatch(_ event: SelectionSession.Event) {
        let (next, effects) = SelectionSession.reduce(state, event)
        state = next
        for effect in effects {
            switch effect {
            case .send(let bytes): pty.send(bytes)
            case .terminate:       pty.terminate()
            }
        }
        publish()
        syncTimer()
    }

    private func publish() {
        phase = Self.viewPhase(state.phase)
        items = state.items
        totalCount = state.totalCount
        resultText = state.resultText
        fullyLoaded = state.fullyLoaded
        loadingAll = (state.phase == .loadingAll)
    }

    private static func viewPhase(_ p: SelectionSession.Phase) -> Phase {
        switch p {
        case .scanning:              return .scanning
        case .choosing, .loadingAll: return .choosing
        case .applyingViewport, .applyingFull, .awaitingConfirm, .confirming:
            return .applying
        case .done(let c):           return .done(c)
        case .failed(let m):         return .failed(m)
        }
    }

    // MARK: - Tick 定时器（仅在需要逻辑时钟的阶段运行）

    private func syncTimer() {
        let needsTicks: Bool
        switch state.phase {
        case .loadingAll, .applyingViewport, .applyingFull, .awaitingConfirm:
            needsTicks = true
        default:
            needsTicks = false
        }
        if needsTicks { startTimer() } else { stopTimer() }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + tickInterval, repeating: tickInterval)
        t.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.resume()
        timer = t
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }
}

// MARK: - View

/// 清理项目视图：扫描项目构建产物，勾选后由 Mole 执行永久删除。
///
/// 布局规范（与 CleanupScreen/InstallerView 一致）：
/// header（无按钮）→ stepGuide → categoriesCard（功能说明）→ previewCard（扫描结果 + 内嵌操作栏）。
struct PurgeInteractiveView: View {
    @EnvironmentObject private var service: MoleService
    @EnvironmentObject private var loc: Localization
    @StateObject private var runner = PurgeInteractiveRunner()
    @State private var selected: Set<Int> = []
    @State private var phase: CleanupPhase = .idle
    @State private var showConfirm = false
    @State private var showCategories = true

    var body: some View {
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
            .alert(loc.t("确认清理选中的项目？", "Confirm purge selected?"),
                   isPresented: $showConfirm) {
                Button(loc.t("取消", "Cancel"), role: .cancel) {}
                Button(loc.t("清理", "Purge"), role: .destructive) {
                    runNow()
                }
            } message: {
                Text(confirmMessage)
            }
            .onChange(of: runner.phase) { _ in
                syncPhaseFromRunner(runner.phase)
            }
            .onDisappear { runner.cancel() }
        }
    }

    // MARK: - Header

    private var header: some View {
        FeatureHeader(
            title: loc.t("清理项目", "Purge Projects"),
            subtitle: loc.t("扫描并清理项目构建产物（node_modules、build 目录等）。",
                            "Scan and clean project build artifacts (node_modules, build dirs, etc.)."),
            systemImage: "shippingbox.fill"
        )
    }

    // MARK: - Step guide

    /// 3 步进度条：扫描 → 查看 → 执行。
    /// 逻辑与 CleanupScreen/InstallerView 保持一致，仅依赖 `phase`。
    private var stepGuide: some View {
        HStack(spacing: 10) {
            StepDot(n: 1, label: loc.t("扫描", "Scan"),
                    active: phase == .idle || phase == .scanning,
                    done: phase.isAfterScan)
            StepConnector(active: phase.isAfterScan)
            StepDot(n: 2, label: loc.t("查看", "Review"),
                    active: phase == .scanned,
                    done: phase == .running || phase == .done || phase == .error)
            StepConnector(active: phase == .running || phase == .done || phase == .error)
            StepDot(n: 3, label: loc.t("执行", "Run"),
                    active: phase == .running,
                    done: phase == .done)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Idle hero card

    private var idleHeroCard: some View {
        Card(padding: 0) {
            VStack(spacing: 14) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 32, weight: .light))
                    .foregroundColor(Theme.accent.opacity(0.7))
                Text(loc.t("扫描项目构建产物以查看可清理的内容。",
                           "Scan project build artifacts to see what can be cleaned."))
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)
                Button {
                    startScan()
                } label: {
                    Label(loc.t("开始扫描", "Start Scan"), systemImage: "magnifyingglass")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .frame(maxWidth: .infinity)
            .padding(24)
        }
    }

    // MARK: - Categories card (功能说明)

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
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                              spacing: 10) {
                        categoryRow(loc.t("node_modules", "node_modules"),
                                    loc.t("npm/yarn 项目依赖目录", "npm/yarn project dependencies"), "shippingbox")
                        categoryRow(loc.t("构建产物", "Build Outputs"),
                                    loc.t("target、build、dist、out 等编译输出", "target, build, dist, out dirs"), "hammer")
                        categoryRow(loc.t("依赖缓存", "Dependency Caches"),
                                    loc.t(".cargo、.gradle、.m2 等包管理器缓存", ".cargo, .gradle, .m2 caches"), "internaldrive")
                        categoryRow(loc.t("Xcode 产物", "Xcode Artifacts"),
                                    loc.t("DerivedData、build 文件夹", "DerivedData, build folders"), "cube")
                        categoryRow(loc.t("临时文件", "Temp Files"),
                                    loc.t(".tmp、.cache 等临时目录", ".tmp, .cache temp dirs"), "clock")
                        categoryRow(loc.t("安全删除", "Safe Deletion"),
                                    loc.t("永久删除，不可恢复", "Permanent, not recoverable"), "trash")
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
            VStack(spacing: 10) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 28, weight: .light))
                    .foregroundColor(Theme.accent.opacity(0.6))
                Text(loc.t("扫描项目构建产物以查看可清理的内容。",
                           "Scan project build artifacts to see what can be cleaned."))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
            .padding(12)
        } else if phase == .scanning {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(loc.t("正在扫描项目构建产物…",
                           "Scanning project artifacts…"))
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            .padding(12)
        } else if phase == .running {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(loc.t("正在校验选择并执行清理…",
                           "Verifying selection and purging…"))
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            .padding(12)
        } else if phase == .done {
            doneContent
        } else if phase == .error {
            errorContent
        } else {
            // scanned
            chooserContent
        }
    }

    // MARK: - Chooser content (扫描结果列表，不含操作栏)

    private var chooserContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 头部：计数 + 全选 + 显示全部
            HStack(spacing: 12) {
                Text(countLabel)
                    .font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                Spacer()
                if !selected.isEmpty {
                    Text(loc.t("已选 \(selected.count) 项", "\(selected.count) selected"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.accent)
                }
                Button {
                    if selected.count == runner.items.count {
                        selected.removeAll()
                    } else {
                        selected = Set(runner.items.indices)
                    }
                } label: {
                    Text(loc.t("全选", "Select All"))
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundColor(Theme.accent)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            Divider()

            // 条目列表
            if runner.items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 28)).foregroundColor(Theme.color(for: .good))
                    Text(loc.t("未发现项目构建产物", "No project artifacts found"))
                        .font(.system(size: 12)).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
                .padding(12)
            } else {
                ForEach(Array(runner.items.enumerated()), id: \.offset) { index, item in
                    itemRow(item, index: index, isSelected: selected.contains(index))
                    if index < runner.items.count - 1 {
                        Divider().padding(.leading, 50)
                    }
                }
            }

            // "显示全部" 滚动捕获提示
            if runner.loadingAll {
                Divider()
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini)
                    Text(loc.t("正在加载全部 \(runner.totalCount) 项…（已加载 \(runner.items.count)）",
                               "Loading all \(runner.totalCount)… (\(runner.items.count) so far)"))
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 8)
            } else if runner.totalCount > runner.items.count {
                Divider()
                HStack(spacing: 8) {
                    Text(loc.t("显示最大的 \(runner.items.count) 项，共 \(runner.totalCount) 项。",
                               "Showing the \(runner.items.count) biggest of \(runner.totalCount)."))
                        .font(.system(size: 10)).foregroundColor(.secondary)
                    Button {
                        runner.loadAll()
                    } label: {
                        Text(loc.t("显示全部 \(runner.totalCount) 项", "Show all \(runner.totalCount)"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 8)
            }
        }
    }

    private func itemRow(_ item: MoTUIItem, index: Int, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            Button {
                if isSelected { selected.remove(index) }
                else { selected.insert(index) }
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundColor(isSelected ? Theme.accent : .secondary)
            }
            .buttonStyle(.plain)

            Image(systemName: "folder.badge.minus")
                .foregroundColor(Theme.accent).frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text("\(item.size)\(item.location.isEmpty ? "" : " · \(item.location)")")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary).lineLimit(1)
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(isSelected ? Theme.accent.opacity(0.04) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelected { selected.remove(index) }
            else { selected.insert(index) }
        }
    }

    // MARK: - Result views

    private var doneContent: some View {
        let code: Int32 = {
            if case .done(let c) = runner.phase { return c }
            return -1
        }()
        let nothing = runner.items.isEmpty && runner.resultText.isEmpty
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: code == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(Theme.color(for: code == 0 ? .good : .critical))
                VStack(alignment: .leading, spacing: 2) {
                    Text(nothing
                         ? loc.t("未发现可清理的项目", "No artifacts found to purge")
                         : (code == 0
                            ? loc.t("清理完成", "Purge complete")
                            : loc.t("部分失败", "Completed with errors")))
                        .font(.system(size: 14, weight: .semibold))
                    if !runner.resultText.isEmpty {
                        Text(runner.resultText)
                            .font(.system(size: 11)).foregroundColor(.secondary)
                            .lineLimit(5)
                    }
                }
                Spacer()
            }
        }
        .padding(12)
    }

    private var errorContent: some View {
        let message: String = {
            if case .failed(let m) = runner.phase { return m }
            return ""
        }()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(Theme.color(for: .critical))
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc.t("清理失败", "Purge failed"))
                        .font(.system(size: 14, weight: .semibold))
                    Text(message)
                        .font(.system(size: 11)).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
        }
        .padding(12)
    }

    // MARK: - Action bar (内嵌在扫描结果卡片底部，四个模块统一)

    @ViewBuilder
    private var actionBar: some View {
        HStack {
            switch phase {
            case .idle:
                Spacer()
                Button {
                    startScan()
                } label: {
                    Label(loc.t("开始扫描", "Start Scan"), systemImage: "magnifyingglass")
                }
                .buttonStyle(PrimaryButtonStyle())
            case .scanning:
                Spacer()
                Button(loc.t("停止", "Stop"), role: .destructive) {
                    runner.cancel()
                    phase = .idle
                    selected.removeAll()
                }
                .buttonStyle(.bordered)
            case .scanned:
                Button {
                    selected.removeAll()
                    startScan()
                } label: {
                    Label(loc.t("重新扫描", "Rescan"), systemImage: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundColor(.secondary)
                Spacer()
                Button {
                    showConfirm = true
                } label: {
                    Label(selected.isEmpty
                          ? loc.t("清理", "Purge")
                          : loc.t("清理 (\(selected.count))", "Purge (\(selected.count))"),
                          systemImage: "trash")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(PrimaryButtonStyle(disabled: selected.isEmpty))
                .disabled(selected.isEmpty)
            case .running:
                Spacer()
                Button(loc.t("停止", "Stop"), role: .destructive) {
                    runner.cancel()
                    phase = .idle
                    selected.removeAll()
                }
                .buttonStyle(.bordered)
            case .done:
                let code: Int32 = {
                    if case .done(let c) = runner.phase { return c }
                    return -1
                }()
                Spacer()
                Button { resetToIdle() } label: {
                    Label(loc.t("再清理一次", "Run Again"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(PrimaryButtonStyle())
            case .error:
                Spacer()
                Button { resetToIdle() } label: {
                    Label(loc.t("重试扫描", "Retry scan"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    // MARK: - Status pill

    @ViewBuilder
    private var statusPill: some View {
        if phase == .scanning || phase == .running {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text(loc.t("运行中", "running")).font(.system(size: 10))
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
        } else if phase == .done {
            let code: Int32 = {
                if case .done(let c) = runner.phase { return c }
                return -1
            }()
            let succeeded = code == 0
            Text(succeeded ? loc.t("✓ 完成", "✓ done") : loc.t("失败", "failed"))
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Theme.color(for: succeeded ? .good : .critical).opacity(0.18), in: Capsule())
                .foregroundColor(Theme.color(for: succeeded ? .good : .critical))
        } else if phase == .error {
            Text(loc.t("失败", "failed"))
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Theme.color(for: .critical).opacity(0.18), in: Capsule())
                .foregroundColor(Theme.color(for: .critical))
        }
    }

    // MARK: - Helpers

    private var phaseLabel: String {
        switch phase {
        case .idle:    return loc.t("扫描结果", "Scan Results")
        case .scanning: return loc.t("扫描中…", "Scanning…")
        case .scanned: return loc.t("扫描完成", "Scan Complete")
        case .running: return loc.t("运行中…", "Running…")
        case .done:    return loc.t("已完成", "Finished")
        case .error:   return loc.t("扫描失败", "Scan failed")
        }
    }

    private var countLabel: String {
        if runner.totalCount > runner.items.count {
            return loc.t("\(runner.items.count) / \(runner.totalCount) 项", "\(runner.items.count) of \(runner.totalCount)")
        }
        return loc.t("\(runner.items.count) 项", "\(runner.items.count) found")
    }

    private var confirmMessage: String {
        let targets = selected.sorted().compactMap { runner.items.indices.contains($0) ? runner.items[$0] : nil }
        let preview = targets.prefix(12).map { "• \($0.name)" }.joined(separator: "\n")
        let more = targets.count > 12 ? "\n… \(loc.t("还有 \(targets.count - 12) 项", "and \(targets.count - 12) more"))" : ""
        return loc.t(
            "将永久删除以下 \(targets.count) 个项目的构建产物：\n\n\(preview)\(more)\n\n此操作不可撤销。",
            "Will permanently delete build artifacts from these \(targets.count) projects:\n\n\(preview)\(more)\n\nThis cannot be undone."
        )
    }

    private func startScan() {
        phase = .scanning
        showCategories = false
        selected.removeAll()
        runner.start()
    }

    private func syncPhaseFromRunner(_ runnerPhase: PurgeInteractiveRunner.Phase) {
        switch runnerPhase {
        case .scanning:
            if phase != .scanning { phase = .scanning }
        case .choosing:
            if phase == .scanning { phase = .scanned }
        case .applying:
            if phase != .running { phase = .running }
        case .done(let code):
            if phase != .done && phase != .error {
                phase = code == 0 ? .done : .error
            }
        case .failed:
            if phase != .error { phase = .error }
        }
    }

    private func runNow() {
        phase = .running
        runner.confirm(selected)
    }

    private func resetToIdle() {
        runner.cancel()
        selected.removeAll()
        phase = .idle
        showCategories = true
    }
}
