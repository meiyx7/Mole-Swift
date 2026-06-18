import SwiftUI
import Charts

@MainActor
final class StatusViewModel: ObservableObject {
    @Published var snapshot: StatusSnapshot?
    @Published var isLoading = false
    @Published var error: String?
    @Published var isLive = false

    private var timer: Timer?
    private let interval: TimeInterval = 3.0

    func load() async {
        isLoading = true
        error = nil
        do {
            snapshot = try await MoleService().statusSnapshot()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func startLive() {
        guard !isLive else { return }
        isLive = true
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { await self.load() }
        }
    }

    func stopLive() {
        isLive = false
        timer?.invalidate()
        timer = nil
    }
}

struct StatusView: View {
    @StateObject private var vm = StatusViewModel()
    @EnvironmentObject private var service: MoleService

    var body: some View {
        Group {
            if !service.isInstalled {
                CLIUnavailableView()
            } else if let snap = vm.snapshot {
                content(snap)
            } else if vm.isLoading {
                LoadingView(title: "Reading system metrics…")
            } else if let error = vm.error {
                EmptyStateView(systemImage: "exclamationmark.triangle",
                               title: "Couldn't load status",
                               message: error,
                               action: ("Retry", { Task { await vm.load() } }))
            } else {
                EmptyStateView(systemImage: "heart.text.square",
                               title: "System status",
                               message: "Load a live snapshot of your Mac's health.",
                               action: ("Load status", { Task { await vm.load() } }))
            }
        }
        .featurePadding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: Binding(
                    get: { vm.isLive },
                    set: { $0 ? vm.startLive() : vm.stopLive() }
                )) {
                    Label(vm.isLive ? "Live" : "Paused", systemImage: vm.isLive ? "pause.fill" : "play.fill")
                }
                .help("Toggle live refresh (every 3s)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await vm.load() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh now")
            }
        }
        .task { await vm.load() }
        .onDisappear { vm.stopLive() }
        .onReceive(NotificationCenter.default.publisher(for: .moleRefresh)) { _ in
            Task { await vm.load() }
        }
    }

    @ViewBuilder
    private func content(_ snap: StatusSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(snap)
                resourceGrid(snap)
                disksAndNetwork(snap)
                topProcesses(snap)
                if !snap.processAlerts.isEmpty {
                    alerts(snap.processAlerts)
                }
            }
        }
    }

    private func header(_ snap: StatusSnapshot) -> some View {
        FeatureHeader(
            title: "System Status",
            subtitle: "\(snap.hardware.model) · \(snap.hardware.osVersion) · up \(snap.uptime)",
            systemImage: "heart.text.square",
            trailing: AnyView(healthBadge(snap))
        )
    }

    private func healthBadge(_ snap: StatusSnapshot) -> some View {
        let tone = StatusTone.forHealthScore(snap.healthScore)
        return HStack(spacing: 10) {
            RingGauge(value: Double(snap.healthScore), label: "Health", tone: tone, size: 64)
            VStack(alignment: .leading, spacing: 2) {
                Text("Health Score")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                Text(snap.healthScoreMsg)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.color(for: tone))
            }
        }
        .padding(.trailing, 4)
    }

    private func resourceGrid(_ snap: StatusSnapshot) -> some View {
        let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
        return LazyVGrid(columns: columns, spacing: 14) {
            cpuCard(snap.cpu)
            memoryCard(snap.memory)
            gpuCard(snap.gpu)
            thermalCard(snap.thermal, snap)
        }
    }

    private func cpuCard(_ cpu: CPUStatus) -> some View {
        let tone = StatusTone.forUsage(cpu.usage)
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("CPU", systemImage: "cpu")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(cpu.logicalCPU) threads · \(cpu.coreCount) cores")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                HStack(alignment: .center, spacing: 16) {
                    RingGauge(value: cpu.usage, label: "CPU", tone: tone, size: 76)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(ByteFormatter.percent(cpu.usage) + " used")
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
            Text("Per-core usage")
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
                    Label("Memory", systemImage: "memorychip")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(mem.pressure.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Theme.color(for: tone).opacity(0.18), in: Capsule())
                        .foregroundColor(Theme.color(for: tone))
                }
                HStack(alignment: .center, spacing: 16) {
                    RingGauge(value: mem.usedPercent, label: "RAM", tone: tone, size: 76)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(ByteFormatter.bytes(mem.used)) of \(ByteFormatter.bytes(mem.total))")
                            .font(.system(size: 14, weight: .semibold))
                        ProgressBar(value: mem.usedPercent, tone: tone)
                        HStack(spacing: 14) {
                            Text("Free \(ByteFormatter.bytes(mem.available))")
                            if mem.swapTotal > 0 {
                                Text("Swap \(ByteFormatter.bytes(mem.swapUsed))")
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
                    Label("GPU", systemImage: "rectangle.stack")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if gpus.isEmpty {
                        Text("No discrete GPU").font(.system(size: 11)).foregroundColor(.secondary)
                    }
                }
                if gpus.isEmpty {
                    Text("Integrated graphics only on this Mac.")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                } else {
                    ForEach(gpus.indices, id: \.self) { i in
                        let g = gpus[i]
                        let tone = StatusTone.forUsage(g.usage)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(g.name).font(.system(size: 12, weight: .medium))
                            HStack {
                                ProgressBar(value: g.usage, tone: tone)
                                Text(ByteFormatter.percent(g.usage)).font(.system(size: 11, design: .rounded))
                                    .frame(width: 44, alignment: .trailing)
                            }
                            if g.memoryTotal > 0 {
                                Text("\(ByteFormatter.bytes(g.memoryUsed)) / \(ByteFormatter.bytes(g.memoryTotal)) VRAM")
                                    .font(.system(size: 10, design: .rounded)).foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func thermalCard(_ t: ThermalStatus, _ snap: StatusSnapshot) -> some View {
        let tone: StatusTone = t.cpuTemp > 90 ? .critical : (t.cpuTemp > 75 ? .warn : .good)
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Thermal & Power", systemImage: "thermometer.medium")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if t.fanCount > 0 {
                        Text("\(t.fanSpeed) RPM").font(.system(size: 11, design: .rounded)).foregroundColor(.secondary)
                    }
                }
                HStack(spacing: 18) {
                    metric("CPU", String(format: "%.0f°C", t.cpuTemp), tone: tone)
                    if t.gpuTemp > 0 { metric("GPU", String(format: "%.0f°C", t.gpuTemp), tone: .neutral) }
                    if snap.batteries.first != nil {
                        metric("Battery", String(format: "%.0f°C", t.batteryTemp), tone: .neutral)
                    }
                }
                if t.systemPower > 0 {
                    Divider()
                    HStack(spacing: 18) {
                        metric("System", String(format: "%.1f W", t.systemPower), tone: .neutral)
                        if t.adapterPower > 0 { metric("Adapter", String(format: "%.1f W", t.adapterPower), tone: .good) }
                        if t.batteryPower > 0 { metric("Battery", String(format: "%.1f W", t.batteryPower), tone: .warn) }
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

    private func disksAndNetwork(_ snap: StatusSnapshot) -> some View {
        let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
        return LazyVGrid(columns: columns, spacing: 14) {
            disksCard(snap.disks, trash: snap.trashSize, trashApprox: snap.trashApprox)
            networkCard(snap.network, history: snap.networkHistory, proxy: snap.proxy)
            batteryCard(snap.batteries)
            bluetoothCard(snap.bluetooth)
        }
    }

    private func disksCard(_ disks: [DiskStatus], trash: Double, trashApprox: Bool) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Storage", systemImage: "internaldrive")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if trash > 0 {
                        Label("\(trashApprox ? "≈ " : "")\(ByteFormatter.bytes(trash)) in Trash", systemImage: "trash")
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
                    Label("Network", systemImage: "network")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if proxy.enabled {
                        Text("Proxy: \(proxy.type)").font(.system(size: 10)).foregroundColor(.secondary)
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
                                .foregroundColor(.green)
                        }
                        ForEach(history.txHistory.indices, id: \.self) { i in
                            LineMark(x: .value("t", i), y: .value("tx", history.txHistory[i]))
                                .foregroundColor(.orange)
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
                    Label("Battery", systemImage: "battery.100")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                }
                if batteries.isEmpty {
                    Text("No battery detected (desktop Mac).")
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
                                Text("\(b.health) · \(b.cycleCount) cycles\(b.timeLeft.isEmpty ? "" : " · \(b.timeLeft)")")
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
                    Label("Bluetooth", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(devices.filter { $0.connected }.count)/\(devices.count) connected")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
                if devices.isEmpty {
                    Text("No paired devices found.")
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
                    Label("Top Processes", systemImage: "flame")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("By CPU").font(.system(size: 10)).foregroundColor(.secondary).textCase(.uppercase)
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
                    Label("Process Alerts", systemImage: "exclamationmark.bubble")
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
