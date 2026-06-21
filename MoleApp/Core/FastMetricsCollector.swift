import Foundation

/// Merges native fast-metrics (CPU, memory, disk, network) with CLI slow-metrics
/// (trash, bluetooth, proxy, battery, GPU, thermal, processes) into a single
/// StatusSnapshot. Fast metrics update every 1s via native APIs; slow metrics
/// update every ~30s via `mo status --json`.
@MainActor
final class FastMetricsCollector {
    private var slowSnapshot: StatusSnapshot?
    private var lastSlowRefresh: Date = .distantPast
    private var isRefreshingSlow = false

    /// Ring buffer for network history (last 60 data points = 60s at 1s interval).
    private var rxHistory: [Double] = []
    private var txHistory: [Double] = []
    private let maxHistoryPoints = 60

    /// Interval between slow (CLI) refreshes.
    let slowInterval: TimeInterval = 30

    // MARK: - Public

    /// Collects a fast snapshot by overlaying native metrics onto the latest
    /// slow snapshot. If no slow snapshot exists yet, triggers one.
    func collectFast() async -> StatusSnapshot? {
        if slowSnapshot == nil {
            await refreshSlow()
        }
        guard var base = slowSnapshot else { return nil }

        // Overlay native fast metrics
        let cpu = NativeMetrics.readCPUUsage()
        base.cpu.usage = cpu.total
        base.cpu.perCore = cpu.perCore
        base.cpu.perCoreEstimated = false

        let load = NativeMetrics.readLoadAverage()
        base.cpu.load1 = load.0
        base.cpu.load5 = load.1
        base.cpu.load15 = load.2

        let mem = NativeMetrics.readMemoryUsage()
        base.memory.used = Double(mem.usedBytes)
        base.memory.total = Double(mem.totalBytes)
        base.memory.available = Double(mem.availableBytes)
        base.memory.usedPercent = mem.usedPercent
        base.memory.swapUsed = Double(mem.swapUsedBytes)
        base.memory.swapTotal = Double(mem.swapTotalBytes)

        let disk = NativeMetrics.readDiskUsage()
        if let idx = base.disks.firstIndex(where: { $0.mount == "/" }) {
            var rootDisk = base.disks[idx]
            rootDisk.total = Double(disk.totalBytes)
            rootDisk.used = Double(disk.usedBytes)
            rootDisk.usedPercent = disk.totalBytes > 0
                ? Double(disk.usedBytes) / Double(disk.totalBytes) * 100.0 : 0
            base.disks[idx] = rootDisk
        }

        // Network: native rates + accumulate history
        let netRate = NativeMetrics.readNetworkRate()
        let interfaces = NativeMetrics.listInterfaces()

        // Build updated network list with native rates
        var updatedNetworks: [NetworkStatus] = []
        for iface in interfaces {
            var found = false
            for var n in base.network where n.name == iface.name {
                n.rxRateMBs = netRate.rxBytesPerSec / 1_048_576.0
                n.txRateMBs = netRate.txBytesPerSec / 1_048_576.0
                n.ip = iface.ip
                updatedNetworks.append(n)
                found = true
                break
            }
            if !found {
                updatedNetworks.append(NetworkStatus(
                    name: iface.name,
                    rxRateMBs: netRate.rxBytesPerSec / 1_048_576.0,
                    txRateMBs: netRate.txBytesPerSec / 1_048_576.0,
                    ip: iface.ip
                ))
            }
        }
        if !updatedNetworks.isEmpty {
            base.network = updatedNetworks
        }

        // Accumulate network history (total rx/tx across all interfaces)
        let totalRx = updatedNetworks.reduce(0) { $0 + $1.rxRateMBs }
        let totalTx = updatedNetworks.reduce(0) { $0 + $1.txRateMBs }
        rxHistory.append(totalRx)
        txHistory.append(totalTx)
        if rxHistory.count > maxHistoryPoints {
            rxHistory.removeFirst()
            txHistory.removeFirst()
        }
        base.networkHistory = NetworkHistory(rxHistory: rxHistory, txHistory: txHistory)

        base.collectedAt = Date()
        return base
    }

    /// Refreshes slow metrics via CLI. Only runs if enough time has passed.
    func refreshSlowIfNeeded() async {
        guard !isRefreshingSlow else { return }
        let now = Date()
        guard now.timeIntervalSince(lastSlowRefresh) >= slowInterval else { return }
        await refreshSlow()
    }

    /// Forces a slow refresh (e.g. on first load or user pull-to-refresh).
    func forceRefreshSlow() async {
        await refreshSlow()
    }

    // MARK: - Private

    private func refreshSlow() async {
        guard !isRefreshingSlow else { return }
        isRefreshingSlow = true
        defer { isRefreshingSlow = false }

        guard let service = FastMetricsCollector.sharedService else { return }
        do {
            let snap = try await service.statusSnapshot()
            slowSnapshot = snap
            lastSlowRefresh = Date()
        } catch {
            // Keep the last slow snapshot on error
        }
    }

    nonisolated(unsafe) static var sharedService: MoleService?
}
