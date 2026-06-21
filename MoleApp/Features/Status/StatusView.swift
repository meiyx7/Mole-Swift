import SwiftUI
import AppKit
import Charts

@MainActor
final class StatusViewModel: ObservableObject {
    @Published var snapshot: StatusSnapshot?
    @Published var isLoading = false
    @Published var error: String?
    @Published var isLive = false
    /// User-selected refresh interval in seconds. Persisted across launches
    /// via UserDefaults so the choice sticks. Defaults to 1s now that fast
    /// metrics are collected natively (< 2ms per tick).
    @Published var refreshInterval: TimeInterval = {
        let stored = UserDefaults.standard.double(forKey: "statusRefreshInterval")
        return stored > 0 ? stored : 1.0
    }()

    /// Available refresh interval choices exposed in the UI.
    /// 1s is now viable because native collection is near-zero cost.
    static let intervalChoices: [TimeInterval] = [1, 3, 5, 10]

    private var refreshTask: Task<Void, Never>?
    private weak var liveService: MoleService?
    private var isRefreshing = false
    private var windowVisible = true
    private let collector = FastMetricsCollector()

    /// Initial load: fetches slow metrics (CLI) then overlays native fast metrics.
    func load(service: MoleService) async {
        isLoading = true
        error = nil
        FastMetricsCollector.sharedService = service
        await collector.forceRefreshSlow()
        if let snap = await collector.collectFast() {
            snapshot = snap
        } else {
            // Fallback: try direct CLI call
            do {
                snapshot = try await service.statusSnapshot()
            } catch {
                self.error = error.localizedDescription
            }
        }
        isLoading = false
    }

    func startLive(service: MoleService) {
        guard !isLive else { return }
        isLive = true
        liveService = service
        FastMetricsCollector.sharedService = service
        startRefreshLoop()
    }

    func setRefreshInterval(_ interval: TimeInterval, service: MoleService) {
        refreshInterval = interval
        UserDefaults.standard.set(interval, forKey: "statusRefreshInterval")
        if isLive {
            startRefreshLoop()
        }
    }

    func setWindowVisible(_ visible: Bool, service: MoleService) {
        windowVisible = visible
        guard isLive else { return }
        if visible {
            Task { await load(service: service) }
            startRefreshLoop()
        } else {
            refreshTask?.cancel()
            refreshTask = nil
        }
    }

    private func startRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, !Task.isCancelled, self.isLive else { return }
                guard self.windowVisible else { return }
                try? await Task.sleep(nanoseconds: UInt64(self.refreshInterval * 1_000_000_000))
                guard !Task.isCancelled, self.isLive, self.windowVisible else { return }
                guard !self.isRefreshing else { continue }
                self.isRefreshing = true

                // Fast path: native metrics (< 2ms), always available
                if let fast = await self.collector.collectFast() {
                    self.snapshot = fast
                }

                // Slow path: trigger CLI refresh if interval elapsed (30s)
                Task { await self.collector.refreshSlowIfNeeded() }

                self.isRefreshing = false
            }
        }
    }

    func stopLive() {
        isLive = false
        refreshTask?.cancel()
        refreshTask = nil
        liveService = nil
    }
}

struct StatusView: View {
    @StateObject private var vm = StatusViewModel()
    @EnvironmentObject private var service: MoleService
    @EnvironmentObject private var loc: Localization

    var body: some View {
        Group {
            if !service.isInstalled {
                CLIUnavailableView()
            } else if let snap = vm.snapshot {
                content(snap)
            } else if vm.isLoading {
                LoadingView(title: loc.t("正在读取系统指标…", "Reading system metrics…"))
            } else if let error = vm.error {
                EmptyStateView(systemImage: "exclamationmark.triangle",
                               title: loc.t("无法加载状态", "Couldn't load status"),
                               message: error,
                               action: (loc.t("重试", "Retry"), { Task { await vm.load(service: service) } }))
            } else {
                EmptyStateView(systemImage: "heart.text.square",
                               title: loc.t("系统状态", "System status"),
                               message: loc.t("加载 Mac 健康状态的实时快照。", "Load a live snapshot of your Mac's health."),
                               action: (loc.t("加载状态", "Load status"), { Task { await vm.load(service: service) } }))
            }
        }
        .featurePadding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: Binding(
                    get: { vm.isLive },
                    set: { $0 ? vm.startLive(service: service) : vm.stopLive() }
                )) {
                    Label(vm.isLive ? loc.t("实时", "Live") : loc.t("已暂停", "Paused"), systemImage: vm.isLive ? "pause.fill" : "play.fill")
                }
                .help(loc.t("切换实时刷新", "Toggle live refresh"))
            }
            // Refresh interval picker, only relevant when live mode is on.
            if vm.isLive {
                ToolbarItem(placement: .primaryAction) {
                    Picker(loc.t("刷新间隔", "Refresh interval"), selection: Binding(
                        get: { vm.refreshInterval },
                        set: { vm.setRefreshInterval($0, service: service) }
                    )) {
                        ForEach(StatusViewModel.intervalChoices, id: \.self) { interval in
                            Text("\(Int(interval))s").tag(interval)
                        }
                    }
                    .pickerStyle(.menu)
                    .help(loc.t("选择实时刷新间隔", "Choose live refresh interval"))
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await vm.load(service: service) } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help(loc.t("立即刷新", "Refresh now"))
            }
        }
        .task { await vm.load(service: service) }
        .onDisappear { vm.stopLive() }
        .onReceive(NotificationCenter.default.publisher(for: .moleRefresh)) { _ in
            Task { await vm.load(service: service) }
        }
        // Pause live refresh when the window is hidden (minimised, behind
        // other windows, or app in background) and resume when it returns.
        // This avoids burning CPU on `mo status` calls nobody is looking at.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            vm.setWindowVisible(true, service: service)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            vm.setWindowVisible(false, service: service)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            vm.setWindowVisible(false, service: service)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            vm.setWindowVisible(true, service: service)
        }
    }

    @ViewBuilder
    private func content(_ snap: StatusSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(snap)
                // Responsive layout: use two columns when there's room,
                // collapse to a single column on narrow windows so cards
                // don't get squeezed. ViewThatFits picks the first layout
                // that fits at the current width.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        leftColumn(snap)
                        rightColumn(snap)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        leftColumn(snap)
                        rightColumn(snap)
                    }
                }
                if shouldShowThermal(snap.thermal, snap) {
                    thermalCard(snap.thermal, snap)
                }
                topProcesses(snap)
                if !snap.processAlerts.isEmpty {
                    alerts(snap.processAlerts)
                }
            }
        }
    }

    /// Left column cards: CPU + Memory + Battery.
    @ViewBuilder
    private func leftColumn(_ snap: StatusSnapshot) -> some View {
        VStack(spacing: 14) {
            cpuCard(snap.cpu)
            memoryCard(snap.memory)
            batteryCard(snap.batteries ?? [])
        }
    }

    /// Right column cards: Storage + Network + GPU + Bluetooth.
    @ViewBuilder
    private func rightColumn(_ snap: StatusSnapshot) -> some View {
        VStack(spacing: 14) {
            disksCard(snap.disks, trash: snap.trashSize, trashApprox: snap.trashApprox)
            networkCard(snap.network, history: snap.networkHistory, proxy: snap.proxy)
            gpuCard(snap.gpu)
            bluetoothCard(snap.bluetooth)
        }
    }

    private func header(_ snap: StatusSnapshot) -> some View {
        let tone = StatusTone.forHealthScore(snap.healthScore)
        return HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.brand)
                    .frame(width: 44, height: 44)
                Image(systemName: "heart.text.square")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(loc.t("系统状态", "System Status"))
                    .font(.system(size: 22, weight: .bold))
                Text(loc.t("\(snap.hardware.model) · \(snap.hardware.osVersion) · 运行 \(snap.uptime)", "\(snap.hardware.model) · \(snap.hardware.osVersion) · up \(snap.uptime)"))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(loc.t("健康评分", "Health Score"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                    Text(snap.healthScoreMsg)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.color(for: tone))
                }
                RingGauge(value: Double(snap.healthScore), label: loc.t("健康", "Health"), tone: tone, size: 44)
                    .padding(4)
            }
            .fixedSize()
        }
        .padding(.bottom, 4)
    }

    /// Returns true only when at least one thermal/power metric is available.
    private func shouldShowThermal(_ t: ThermalStatus, _ snap: StatusSnapshot) -> Bool {
        let cpuTempAvailable = t.cpuTemp > 0
        let gpuTempAvailable = t.gpuTemp > 0
        let hasBattery = snap.batteries?.first != nil && t.batteryTemp > 0
        let hasPower = t.systemPower > 0
        let hasFan = t.fanCount > 0
        return cpuTempAvailable || gpuTempAvailable || hasBattery || hasPower || hasFan
    }

    private func cpuCard(_ cpu: CPUStatus) -> some View {
        let tone = StatusTone.forUsage(cpu.usage)
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(loc.t("CPU", "CPU"), systemImage: "cpu")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(loc.t("\(cpu.logicalCPU) 线程 · \(cpu.coreCount) 核心", "\(cpu.logicalCPU) threads · \(cpu.coreCount) cores"))
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                HStack(alignment: .center, spacing: 16) {
                    RingGauge(value: cpu.usage, label: loc.t("CPU", "CPU"), tone: tone, size: 76)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(ByteFormatter.percent(cpu.usage) + loc.t("已使用", " used"))
                            .font(.system(size: 15, weight: .semibold))
                        HStack(spacing: 14) {
                            Label("\(String(format: "%.2f", cpu.load1))", systemImage: "1.circle")
                            Label("\(String(format: "%.2f", cpu.load5))", systemImage: "5.circle")
                            Label("\(String(format: "%.2f", cpu.load15))", systemImage: "15.circle")
                        }
                        .font(.system(size: 11, design: .rounded))
                        .foregroundColor(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                if !cpu.perCore.isEmpty {
                    perCoreBars(cpu.perCore)
                }
            }
        }
    }

    private func perCoreBars(_ cores: [Double]) -> some View {
        let maxCores = 16
        let shown = Array(cores.prefix(maxCores))
        return VStack(alignment: .leading, spacing: 4) {
            Text(loc.t("各核心使用率", "Per-core usage"))
                .font(.system(size: 10)).foregroundColor(.secondary).textCase(.uppercase)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(shown.indices, id: \.self) { i in
                    let v = shown[i]
                    let tone = StatusTone.forUsage(v)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.color(for: tone))
                        .frame(height: max(3, min(34, v / 100 * 34)))
                }
            }
            .frame(height: 34, alignment: .bottom)
        }
    }

    private func memoryCard(_ mem: MemoryStatus) -> some View {
        let tone = StatusTone.forUsage(mem.usedPercent)
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(loc.t("内存", "Memory"), systemImage: "memorychip")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(mem.pressure.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Theme.color(for: tone).opacity(0.18), in: Capsule())
                        .foregroundColor(Theme.color(for: tone))
                }
                HStack(alignment: .center, spacing: 16) {
                    RingGauge(value: mem.usedPercent, label: loc.t("内存", "RAM"), tone: tone, size: 76)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(loc.t("\(ByteFormatter.bytes(mem.used)) / \(ByteFormatter.bytes(mem.total))", "\(ByteFormatter.bytes(mem.used)) of \(ByteFormatter.bytes(mem.total))"))
                            .font(.system(size: 14, weight: .semibold))
                        ProgressBar(value: mem.usedPercent, tone: tone)
                        HStack(spacing: 14) {
                            Text(loc.t("可用 \(ByteFormatter.bytes(mem.available))", "Free \(ByteFormatter.bytes(mem.available))"))
                            if mem.swapTotal > 0 {
                                Text(loc.t("交换 \(ByteFormatter.bytes(mem.swapUsed))", "Swap \(ByteFormatter.bytes(mem.swapUsed))"))
                            }
                        }
                        .font(.system(size: 11, design: .rounded)).foregroundColor(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func gpuCard(_ gpus: [GPUStatus]) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(loc.t("GPU", "GPU"), systemImage: "rectangle.stack")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if gpus.isEmpty {
                        Text(loc.t("集成显卡", "Integrated")).font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Color.gray.opacity(0.18), in: Capsule())
                            .foregroundColor(.secondary)
                    }
                }
                if gpus.isEmpty {
                    Text(loc.t("此 Mac 使用集成显卡，无独立 GPU 信息。", "This Mac uses integrated graphics. No discrete GPU info."))
                        .font(.system(size: 12)).foregroundColor(.secondary)
                } else {
                    ForEach(gpus.indices, id: \.self) { i in
                        let g = gpus[i]
                        // powermetrics requires root; when unauthorized the
                        // CLI returns -1. Hide the usage bar entirely instead
                        // of showing a misleading "N/A" or "-1%".
                        let usageAvailable = g.usage >= 0
                        VStack(alignment: .leading, spacing: 4) {
                            Text(g.name).font(.system(size: 12, weight: .medium))
                            if usageAvailable {
                                let tone = StatusTone.forUsage(g.usage)
                                HStack {
                                    ProgressBar(value: g.usage, tone: tone)
                                    Text(ByteFormatter.percent(g.usage)).font(.system(size: 11, design: .rounded))
                                        .frame(width: 44, alignment: .trailing)
                                }
                            } else if g.memoryTotal == 0 {
                                Text(loc.t("使用率需管理员权限", "Usage requires admin"))
                                    .font(.system(size: 10)).foregroundColor(.secondary)
                            }
                            if g.memoryTotal > 0 {
                                Text(loc.t("\(ByteFormatter.bytes(g.memoryUsed)) / \(ByteFormatter.bytes(g.memoryTotal)) VRAM", "\(ByteFormatter.bytes(g.memoryUsed)) / \(ByteFormatter.bytes(g.memoryTotal)) VRAM"))
                                    .font(.system(size: 10, design: .rounded)).foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func thermalCard(_ t: ThermalStatus, _ snap: StatusSnapshot) -> some View {
        let cpuTempAvailable = t.cpuTemp > 0
        let gpuTempAvailable = t.gpuTemp > 0
        let hasBattery = snap.batteries?.first != nil && t.batteryTemp > 0
        let hasPower = t.systemPower > 0
        let hasFan = t.fanCount > 0
        let tone: StatusTone = t.cpuTemp > 90 ? .critical : (t.cpuTemp > 75 ? .warn : .good)
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(loc.t("温度与电源", "Thermal & Power"), systemImage: "thermometer.medium")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if hasFan {
                        Text(loc.t("\(t.fanSpeed) RPM", "\(t.fanSpeed) RPM")).font(.system(size: 11, design: .rounded)).foregroundColor(.secondary)
                    }
                }
                let hasAnyTemp = cpuTempAvailable || gpuTempAvailable || hasBattery
                if hasAnyTemp {
                    HStack(spacing: 18) {
                        if cpuTempAvailable {
                            metric(loc.t("CPU", "CPU"), String(format: "%.0f°C", t.cpuTemp), tone: tone)
                        }
                        if gpuTempAvailable {
                            metric(loc.t("GPU", "GPU"), String(format: "%.0f°C", t.gpuTemp), tone: .neutral)
                        }
                        if hasBattery {
                            metric(loc.t("电池", "Battery"), String(format: "%.0f°C", t.batteryTemp), tone: .neutral)
                        }
                    }
                }
                if hasPower {
                    if hasAnyTemp { Divider() }
                    HStack(spacing: 18) {
                        metric(loc.t("系统", "System"), String(format: "%.1f W", t.systemPower), tone: .neutral)
                        if t.adapterPower > 0 { metric(loc.t("适配器", "Adapter"), String(format: "%.1f W", t.adapterPower), tone: .good) }
                        if t.batteryPower > 0 { metric(loc.t("电池", "Battery"), String(format: "%.1f W", t.batteryPower), tone: .warn) }
                    }
                }
            }
        }
    }

    private func metric(_ title: String, _ value: String, tone: StatusTone) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10)).foregroundColor(.secondary).textCase(.uppercase)
            Text(value).font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(Theme.color(for: tone))
        }
    }

    private func disksCard(_ disks: [DiskStatus], trash: Double, trashApprox: Bool) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(loc.t("存储", "Storage"), systemImage: "internaldrive")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if trash > 0 {
                        Label(loc.t("\(trashApprox ? "≈ " : "")\(ByteFormatter.bytes(trash)) 废纸篓", "\(trashApprox ? "≈ " : "")\(ByteFormatter.bytes(trash)) in Trash"), systemImage: "trash")
                            .font(.system(size: 10)).foregroundColor(.secondary)
                    }
                }
                ForEach(disks.indices, id: \.self) { i in
                    let d = disks[i]
                    let tone = StatusTone.forUsage(d.usedPercent)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(d.external ? "🔌 \(d.mount)" : d.mount)
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                            Text("\(ByteFormatter.bytes(d.used)) / \(ByteFormatter.bytes(d.total))")
                                .font(.system(size: 11, design: .rounded)).foregroundColor(.secondary)
                        }
                        ProgressBar(value: d.usedPercent, tone: tone)
                    }
                }
            }
        }
    }

    private func networkCard(_ nets: [NetworkStatus], history: NetworkHistory, proxy: ProxyStatus) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(loc.t("网络", "Network"), systemImage: "network")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if proxy.enabled {
                        Text(loc.t("代理：\(proxy.type)", "Proxy: \(proxy.type)")).font(.system(size: 10)).foregroundColor(.secondary)
                    }
                }
                if !nets.isEmpty {
                    ForEach(nets.indices, id: \.self) { i in
                        let n = nets[i]
                        HStack {
                            Image(systemName: n.ip.isEmpty ? "wifi.slash" : "wifi")
                                .foregroundColor(n.ip.isEmpty ? .secondary : .green)
                            Text(n.name).font(.system(size: 12, weight: .medium))
                            Spacer()
                            Label(ByteFormatter.rate(bytesPerSecond: n.rxRateMBs * 1_000_000), systemImage: "arrow.down")
                            Label(ByteFormatter.rate(bytesPerSecond: n.txRateMBs * 1_000_000), systemImage: "arrow.up")
                        }
                        .font(.system(size: 11, design: .rounded))
                        .foregroundColor(.secondary)
                    }
                }
                if !history.rxHistory.isEmpty {
                    Chart {
                        ForEach(history.rxHistory.indices, id: \.self) { i in
                            LineMark(x: .value("t", i), y: .value("rx", history.rxHistory[i]))
                                .foregroundStyle(.green)
                        }
                        ForEach(history.txHistory.indices, id: \.self) { i in
                            LineMark(x: .value("t", i), y: .value("tx", history.txHistory[i]))
                                .foregroundStyle(.orange)
                        }
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .frame(height: 44)
                }
            }
        }
    }

    private func batteryCard(_ batteries: [BatteryStatus]) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(loc.t("电池", "Battery"), systemImage: "battery.100")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                }
                if batteries.isEmpty {
                    Text(loc.t("未检测到电池（台式机 Mac）。", "No battery detected (desktop Mac)."))
                        .font(.system(size: 12)).foregroundColor(.secondary)
                } else {
                    ForEach(batteries.indices, id: \.self) { i in
                        let b = batteries[i]
                        let charging = b.status.lowercased().contains("charg") && !b.status.lowercased().contains("not")
                        let tone: StatusTone = b.percent < 20 ? .critical : (b.percent < 50 ? .warn : .good)
                        HStack(spacing: 12) {
                            Image(systemName: charging ? "battery.100.bolt" : "battery.100")
                                .foregroundColor(Theme.color(for: tone))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(Int(b.percent))% · \(b.status)")
                                    .font(.system(size: 13, weight: .semibold))
                                Text(loc.t("\(b.health) · \(b.cycleCount) 次循环\(b.timeLeft.isEmpty ? "" : " · \(b.timeLeft)")", "\(b.health) · \(b.cycleCount) cycles\(b.timeLeft.isEmpty ? "" : " · \(b.timeLeft)")"))
                                    .font(.system(size: 11, design: .rounded)).foregroundColor(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    private func bluetoothCard(_ devices: [BluetoothDevice]) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(loc.t("蓝牙", "Bluetooth"), systemImage: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(loc.t("\(devices.filter { $0.connected }.count)/\(devices.count) 已连接", "\(devices.filter { $0.connected }.count)/\(devices.count) connected"))
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
                if devices.isEmpty {
                    Text(loc.t("未找到已配对设备。", "No paired devices found."))
                        .font(.system(size: 12)).foregroundColor(.secondary)
                } else {
                    ForEach(devices.indices, id: \.self) { i in
                        let d = devices[i]
                        HStack {
                            Circle().fill(d.connected ? Color.green : Color.secondary).frame(width: 7, height: 7)
                            Text(d.name).font(.system(size: 12, weight: .medium))
                            Spacer()
                            if !d.battery.isEmpty {
                                Text(d.battery).font(.system(size: 11, design: .rounded)).foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func topProcesses(_ snap: StatusSnapshot) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(loc.t("高占用进程", "Top Processes"), systemImage: "flame")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(loc.t("按 CPU 排序", "By CPU")).font(.system(size: 10)).foregroundColor(.secondary).textCase(.uppercase)
                }
                ForEach(snap.topProcesses.prefix(8).indices, id: \.self) { i in
                    let p = snap.topProcesses[i]
                    let tone = StatusTone.forUsage(p.cpu)
                    HStack(spacing: 10) {
                        Text("\(i + 1)").font(.system(size: 11, weight: .bold, design: .rounded))
                            .frame(width: 16).foregroundColor(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text("PID \(p.pid)").font(.system(size: 10, design: .rounded)).foregroundColor(.secondary)
                        }
                        Spacer()
                        ProgressBar(value: min(100, p.cpu), tone: tone).frame(width: 90)
                        Text(ByteFormatter.percent(p.cpu))
                            .font(.system(size: 11, design: .rounded))
                            .frame(width: 48, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func alerts(_ alerts: [ProcessAlert]) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(loc.t("进程警报", "Process Alerts"), systemImage: "exclamationmark.bubble")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(alerts.count)").font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 7).padding(.vertical, 1)
                        .background(Color.red, in: Capsule())
                }
                ForEach(alerts.prefix(6).indices, id: \.self) { i in
                    let a = alerts[i]
                    HStack {
                        Image(systemName: "flame.fill").foregroundColor(.red).font(.system(size: 11))
                        Text(a.name).font(.system(size: 12, weight: .medium))
                        Text("\(ByteFormatter.percent(a.cpu))").font(.system(size: 11, design: .rounded)).foregroundColor(.secondary)
                        Spacer()
                        Text(a.status).font(.system(size: 10)).foregroundColor(.secondary)
                    }
                }
            }
        }
    }
}
