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

/// 交互式清理项目视图：用 PTY 驱动 `mo purge` 的选择 TUI，把 TUI checklist
/// 翻译成原生 UI，用户勾选后回放按键给 Mole，由 Mole 自己执行删除。
///
/// 与 PurgeView（原生扫描）并存，供用户对比两种实现方式。
struct PurgeInteractiveView: View {
    @EnvironmentObject private var service: MoleService
    @EnvironmentObject private var loc: Localization
    @StateObject private var runner = PurgeInteractiveRunner()
    @State private var selected: Set<Int> = []
    @State private var scanRequested = false
    @State private var showConfirm = false

    var body: some View {
        if !service.isInstalled {
            CLIUnavailableView()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    stepGuide
                    infoCard
                    content
                }
            }
            .featurePadding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .alert(loc.t("确认清理选中的项目？", "Confirm purge selected?"),
                   isPresented: $showConfirm) {
                Button(loc.t("取消", "Cancel"), role: .cancel) {}
                Button(loc.t("清理", "Purge"), role: .destructive) {
                    runner.confirm(selected)
                }
            } message: {
                Text(confirmMessage)
            }
            .onDisappear { runner.cancel() }
        }
    }

    // MARK: - Header

    private var header: some View {
        FeatureHeader(
            title: loc.t("清理项目（CLI 交互）", "Purge Projects (CLI Interactive)"),
            subtitle: loc.t("通过 Mole CLI 的交互式选择菜单清理构建产物，由 Mole 执行删除。",
                            "Purge build artifacts via Mole CLI's interactive selection menu. Mole performs the deletion."),
            systemImage: "shippingbox.fill",
            trailing: AnyView(actionButtons)
        )
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            if scanRequested {
                switch runner.phase {
                case .scanning, .choosing, .applying:
                    Button(loc.t("停止", "Stop"), role: .destructive) {
                        runner.cancel()
                        scanRequested = false
                    }
                    .buttonStyle(.bordered)
                case .done, .failed:
                    Button {
                        selected.removeAll()
                        scanRequested = false
                    } label: {
                        Label(loc.t("返回", "Back"), systemImage: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Button {
                    startScan()
                } label: {
                    Label(loc.t("开始扫描", "Start Scan"), systemImage: "magnifyingglass")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    // MARK: - Step guide

    private var stepGuide: some View {
        HStack(spacing: 10) {
            StepDot(n: 1, label: loc.t("扫描", "Scan"),
                    active: runner.phase == .scanning,
                    done: scanRequested && runner.phase != .scanning)
            StepConnector(active: scanRequested && runner.phase != .scanning)
            StepDot(n: 2, label: loc.t("选择", "Select"),
                    active: runner.phase == .choosing,
                    done: runner.phase == .applying || runner.phase == .done(0))
            StepConnector(active: runner.phase == .applying || runner.phase == .done(0))
            StepDot(n: 3, label: loc.t("清理", "Purge"),
                    active: runner.phase == .applying,
                    done: runner.phase == .done(0))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Info card

    private var infoCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text(loc.t("工作原理", "How it works"))
                    .font(.system(size: 13, weight: .semibold))
                Text(loc.t(
                    "此模式在伪终端中运行 `mo purge`，解析 Mole 的交互式选择菜单为原生列表。你勾选后，App 把选择回放为按键发给 Mole，由 Mole 自己执行删除。发送前会三重校验屏幕选择与你的意图一致，任何不符都会中止且不删除任何内容。",
                    "This mode runs `mo purge` in a pseudo-terminal, parsing Mole's interactive selection menu into a native list. After you select, the app replays your choices as keystrokes to Mole, which performs the deletion itself. Three-way verification before sending ensures the on-screen selection matches your intent; any mismatch aborts with nothing removed."
                ))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !scanRequested {
            emptyState
        } else {
            switch runner.phase {
            case .scanning:
                scanningView
            case .choosing:
                chooser
            case .applying:
                applyingView
            case .done(let code):
                doneView(code)
            case .failed(let message):
                failedView(message)
            }
        }
    }

    private var emptyState: some View {
        Card {
            VStack(spacing: 12) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 36, weight: .light))
                    .foregroundColor(Theme.accent.opacity(0.6))
                Text(loc.t("点击「开始扫描」以启动 Mole CLI 的交互式清理。",
                           "Click \"Start Scan\" to launch Mole CLI's interactive purge."))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        }
    }

    private var scanningView: some View {
        Card {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(loc.t("正在通过 Mole CLI 扫描项目构建产物…",
                           "Scanning project artifacts via Mole CLI…"))
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
        }
    }

    private var applyingView: some View {
        Card {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(loc.t("正在校验选择并执行清理…",
                           "Verifying selection and purging…"))
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
        }
    }

    // MARK: - Chooser

    private var chooser: some View {
        Card(padding: 0) {
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
                    Text(loc.t("未发现项目构建产物", "No project artifacts found"))
                        .font(.system(size: 12)).foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
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

                // 底部操作栏
                Divider()
                HStack {
                    Button {
                        runner.rescan()
                        selected.removeAll()
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
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
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

    private func doneView(_ code: Int32) -> some View {
        let nothing = runner.items.isEmpty && runner.resultText.isEmpty
        return Card(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
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
                if code == 0 && !nothing {
                    HStack(spacing: 8) {
                        Button {
                            let trashPath = NSString(string: "~/.Trash").expandingTildeInPath
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: trashPath)])
                        } label: {
                            Label(loc.t("打开废纸篓", "Open Trash"), systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        Button {
                            selected.removeAll()
                            scanRequested = false
                        } label: {
                            Label(loc.t("完成", "Done"), systemImage: "checkmark")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private func failedView(_ message: String) -> some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
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
                Button {
                    selected.removeAll()
                    scanRequested = false
                } label: {
                    Label(loc.t("返回", "Back"), systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Helpers

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
            "Mole 将删除以下 \(targets.count) 个项目的构建产物：\n\n\(preview)\(more)\n\n由 Mole CLI 执行删除，路由到废纸篓。",
            "Mole will remove build artifacts from these \(targets.count) projects:\n\n\(preview)\(more)\n\nDeletion is performed by Mole CLI, routed to Trash."
        )
    }

    private func startScan() {
        scanRequested = true
        selected.removeAll()
        runner.start()
    }
}
