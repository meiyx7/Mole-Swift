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

    /// Interval between slow (CLI) refreshes.
    let slowInterval: TimeInterval = 30

    // MARK: - Public

    /// Collects a fast snapshot by overlaying native metrics onto the latest
    /// slow snapshot. If no slow snapshot exists yet, triggers one.
    func collectFast() async -> StatusSnapshot? {
        // Ensure we have a base slow snapshot
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
        if var rootDisk = base.disks.first(where: { $0.mount == "/" }) {
            rootDisk.total = Double(disk.totalBytes)
            rootDisk.used = Double(disk.usedBytes)
            rootDisk.usedPercent = disk.totalBytes > 0
                ? Double(disk.usedBytes) / Double(disk.totalBytes) * 100.0 : 0
            if let idx = base.disks.firstIndex(where: { $0.mount == "/" }) {
                base.disks[idx] = rootDisk
            }
        }

        let netRate = NativeMetrics.readNetworkRate()
        let interfaces = NativeMetrics.listInterfaces()
        for (i, iface) in interfaces.enumerated() {
            if i < base.network.count {
                base.network[i].rxRateMBs = netRate.rxBytesPerSec / 1_048_576.0
                base.network[i].txRateMBs = netRate.txBytesPerSec / 1_048_576.0
                base.network[i].ip = iface.ip
            }
        }

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

        guard let service = await findService() else { return }
        do {
            let snap = try await service.statusSnapshot()
            slowSnapshot = snap
            lastSlowRefresh = Date()
        } catch {
            // Keep the last slow snapshot on error
        }
    }

    private func findService() async -> MoleService? {
        // Access the shared environment object via the app's service reference.
        // This is injected at initialization time.
        return FastMetricsCollector.sharedService
    }

    nonisolated(unsafe) static var sharedService: MoleService?
}
