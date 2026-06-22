import Foundation

/// Merges native fast-metrics (CPU, memory, disk, network) with CLI slow-metrics
/// (trash, bluetooth, proxy, battery, GPU, thermal, processes) into a single
/// StatusSnapshot. Fast metrics update every 1s via native APIs; slow metrics
/// update via `mo status --json` on a tiered schedule:
/// - Medium tier (top processes, process alerts): every ~15s
/// - Slow tier (battery, thermal, bluetooth, GPU, trash, proxy): every ~120s
/// Both tiers share a single CLI call when both are due; when only the medium
/// tier is due, the slow-tier fields are preserved from the last full refresh.
@MainActor
final class FastMetricsCollector {
    private var slowSnapshot: StatusSnapshot?
    private var lastSlowRefresh: Date = .distantPast
    private var lastMediumRefresh: Date = .distantPast
    private var isRefreshingSlow = false

    /// Ring buffer for network history (last 60 data points = 60s at 1s interval).
    private var rxHistory: [Double] = []
    private var txHistory: [Double] = []
    private let maxHistoryPoints = 60

    /// Interval for medium-tier refresh (top processes, process alerts).
    /// These change frequently enough to warrant a shorter cycle.
    let mediumInterval: TimeInterval = 15
    /// Interval for slow-tier refresh (battery, thermal, bluetooth, GPU, trash,
    /// proxy). These change slowly; refreshing them every 15s wastes CPU and
    /// triggers unnecessary SwiftUI re-renders.
    let slowInterval: TimeInterval = 120

    // MARK: - Public

    /// Collects a fast snapshot by overlaying native metrics onto the latest
    /// slow snapshot. If no slow snapshot exists yet, triggers one.
    func collectFast() async -> StatusSnapshot? {
        if slowSnapshot == nil {
            await refreshFromCLI(fullUpdate: true)
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

        // Network: per-interface native rates
        let ifaceRates = NativeMetrics.readInterfaceRates()

        // Build updated network list with per-interface rates
        var updatedNetworks: [NetworkStatus] = []
        for rate in ifaceRates {
            var found = false
            for var n in base.network where n.name == rate.name {
                n.rxRateMBs = rate.rxBytesPerSec / 1_048_576.0
                n.txRateMBs = rate.txBytesPerSec / 1_048_576.0
                n.ip = rate.ip
                updatedNetworks.append(n)
                found = true
                break
            }
            if !found {
                updatedNetworks.append(NetworkStatus(
                    name: rate.name,
                    rxRateMBs: rate.rxBytesPerSec / 1_048_576.0,
                    txRateMBs: rate.txBytesPerSec / 1_048_576.0,
                    ip: rate.ip
                ))
            }
        }
        if !updatedNetworks.isEmpty {
            base.network = updatedNetworks
        }

        // Accumulate network history (total rx/tx across all interfaces)
        let totalRx = ifaceRates.reduce(0) { $0 + $1.rxBytesPerSec }
        let totalTx = ifaceRates.reduce(0) { $0 + $1.txBytesPerSec }
        rxHistory.append(totalRx / 1_048_576.0)
        txHistory.append(totalTx / 1_048_576.0)
        if rxHistory.count > maxHistoryPoints {
            rxHistory.removeFirst()
            txHistory.removeFirst()
        }
        base.networkHistory = NetworkHistory(rxHistory: rxHistory, txHistory: txHistory)

        base.collectedAt = Date()
        return base
    }

    /// Refreshes CLI metrics on a tiered schedule. When the medium tier is due
    /// but the slow tier is not, only top processes and process alerts are
    /// updated; slow-tier fields (battery, thermal, bluetooth, GPU, trash,
    /// proxy) are preserved from the last full refresh. When both are due,
    /// a single CLI call updates everything.
    func refreshSlowIfNeeded() async {
        guard !isRefreshingSlow else { return }
        let now = Date()
        let needsMedium = now.timeIntervalSince(lastMediumRefresh) >= mediumInterval
        let needsSlow = now.timeIntervalSince(lastSlowRefresh) >= slowInterval
        guard needsMedium || needsSlow else { return }
        await refreshFromCLI(fullUpdate: needsSlow)
    }

    /// Forces a slow refresh (e.g. on first load or user pull-to-refresh).
    func forceRefreshSlow() async {
        await refreshFromCLI(fullUpdate: true)
    }

    // MARK: - Private

    private func refreshFromCLI(fullUpdate: Bool) async {
        guard !isRefreshingSlow else { return }
        isRefreshingSlow = true
        defer { isRefreshingSlow = false }

        guard let service = FastMetricsCollector.sharedService else { return }
        do {
            let snap = try await service.statusSnapshot()
            if fullUpdate {
                slowSnapshot = snap
                lastSlowRefresh = Date()
                lastMediumRefresh = Date()
            } else {
                // Medium-tier partial update: preserve slow-changing fields
                // from the last full refresh, only update top processes and
                // process alerts.
                if var base = slowSnapshot {
                    base.topProcesses = snap.topProcesses
                    base.processAlerts = snap.processAlerts
                    slowSnapshot = base
                } else {
                    slowSnapshot = snap
                    lastSlowRefresh = Date()
                }
                lastMediumRefresh = Date()
            }
        } catch {
            // Keep the last slow snapshot on error
        }
    }

    nonisolated(unsafe) static var sharedService: MoleService?
}
