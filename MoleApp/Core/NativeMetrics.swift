import Foundation
import Darwin
import MachO

/// Native macOS metrics collection using system APIs.
/// All methods are designed to be called from any thread and complete in < 2ms total.
enum NativeMetrics {

    // MARK: - CPU

    struct CPUUsage {
        let total: Double
        let perCore: [Double]
    }

    /// Reads per-core CPU usage via Mach host_processor_info.
    /// Returns (totalPercent, perCorePercents). Falls back to zeros on failure.
    static func readCPUUsage() -> CPUUsage {
        var numCPU: natural_t = 0
        var cpuInfo: UnsafeMutablePointer<integer_t>?
        var numCPUInfo: mach_msg_type_number_t = 0

        let result = host_processor_info(mach_host_self(),
                                         PROCESSOR_CPU_LOAD_INFO,
                                         &numCPU,
                                         &cpuInfo,
                                         &numCPUInfo)
        guard result == KERN_SUCCESS, let info = cpuInfo, numCPU > 0 else {
            return CPUUsage(total: 0, perCore: [])
        }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(Int(bitPattern: info)),
                          vm_size_t(Int(numCPUInfo) * MemoryLayout<integer_t>.size))
        }

        let cpuCount = Int(numCPU)
        let ticksPerCore = Int(numCPUInfo / numCPU)
        var perCore: [Double] = []
        var totalTicks: Double = 0
        var activeTicks: Double = 0

        for i in 0..<cpuCount {
            let base = i * ticksPerCore
            let user  = Double(info[base + Int(CPU_STATE_USER)])
            let system = Double(info[base + Int(CPU_STATE_SYSTEM)])
            let idle  = Double(info[base + Int(CPU_STATE_IDLE)])
            let nice  = Double(info[base + Int(CPU_STATE_NICE)])
            let total = user + system + idle + nice
            let active = user + system + nice
            totalTicks += total
            activeTicks += active
            perCore.append(total > 0 ? (active / total) * 100.0 : 0)
        }

        let avg = totalTicks > 0 ? (activeTicks / totalTicks) * 100.0 : 0
        return CPUUsage(total: avg, perCore: perCore)
    }

    // MARK: - Memory

    struct MemoryUsage {
        let totalBytes: UInt64
        let usedBytes: UInt64
        let availableBytes: UInt64
        let usedPercent: Double
        let swapUsedBytes: UInt64
        let swapTotalBytes: UInt64
    }

    /// Reads memory usage via vm_stat + sysctl.
    static func readMemoryUsage() -> MemoryUsage {
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)

        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        var totalMem: UInt64 = 0
        var totalSwap: UInt64 = 0
        var usedSwap: UInt64 = 0
        var sysctlSize = MemoryLayout<UInt64>.size

        sysctlbyname("hw.memsize", &totalMem, &sysctlSize, nil, 0)

        // Read swap via sysctl (avoids swap_usage struct availability issues)
        var swapInfo = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swapInfo, &swapSize, nil, 0) == 0 {
            totalSwap = UInt64(swapInfo.xsu_total) * 1024 * 1024
            usedSwap = UInt64(swapInfo.xsu_used) * 1024 * 1024
        }

        guard result == KERN_SUCCESS else {
            return MemoryUsage(totalBytes: totalMem, usedBytes: 0, availableBytes: totalMem,
                               usedPercent: 0, swapUsedBytes: usedSwap, swapTotalBytes: totalSwap)
        }

        let free = UInt64(vmStats.free_count) * UInt64(pageSize)
        let active = UInt64(vmStats.active_count) * UInt64(pageSize)
        let inactive = UInt64(vmStats.inactive_count) * UInt64(pageSize)
        let speculative = UInt64(vmStats.speculative_count) * UInt64(pageSize)
        let wired = UInt64(vmStats.wire_count) * UInt64(pageSize)
        let compressed = UInt64(vmStats.compressor_page_count) * UInt64(pageSize)

        let used = active + wired + compressed
        let available = free + inactive + speculative
        let pct = totalMem > 0 ? Double(used) / Double(totalMem) * 100.0 : 0

        return MemoryUsage(totalBytes: totalMem, usedBytes: used, availableBytes: available,
                           usedPercent: pct, swapUsedBytes: usedSwap, swapTotalBytes: totalSwap)
    }

    // MARK: - Disk

    struct DiskUsage {
        let totalBytes: UInt64
        let usedBytes: UInt64
    }

    /// Reads disk usage for a mount point via FileManager.
    static func readDiskUsage(for path: String = "/") -> DiskUsage {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let total = attrs[.systemSize] as? UInt64,
              let free = attrs[.systemFreeSize] as? UInt64 else {
            return DiskUsage(totalBytes: 0, usedBytes: 0)
        }
        return DiskUsage(totalBytes: total, usedBytes: total - free)
    }

    // MARK: - Network

    struct NetworkRate {
        let rxBytesPerSec: Double
        let txBytesPerSec: Double
    }

    private static var lastRx: UInt64 = 0
    private static var lastTx: UInt64 = 0
    private static var lastNetTime: Date = .distantPast

    /// Reads network byte counters via getifaddrs and computes rate since last call.
    static func readNetworkRate() -> NetworkRate {
        var rxTotal: UInt64 = 0
        var txTotal: UInt64 = 0

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
            return NetworkRate(rxBytesPerSec: 0, txBytesPerSec: 0)
        }
        defer { freeifaddrs(ifaddr) }

        var ptr = first
        while true {
            if let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK) {
                let data = UnsafeRawPointer(ptr.pointee.ifa_data).bindMemory(to: if_data.self, capacity: 1)
                let name = String(cString: ptr.pointee.ifa_name)
                // Skip loopback and unnecessary interfaces
                if name != "lo0" && !name.hasPrefix("awdl") && !name.hasPrefix("utun") {
                    rxTotal += UInt64(data.pointee.ifi_ibytes)
                    txTotal += UInt64(data.pointee.ifi_obytes)
                }
            }
            guard let next = ptr.pointee.ifa_next else { break }
            ptr = next
        }

        let now = Date()
        let elapsed = now.timeIntervalSince(lastNetTime)
        var rate = NetworkRate(rxBytesPerSec: 0, txBytesPerSec: 0)

        if elapsed > 0.1 && lastNetTime > .distantPast {
            let rxDelta = rxTotal > lastRx ? rxTotal - lastRx : 0
            let txDelta = txTotal > lastTx ? txTotal - lastTx : 0
            rate = NetworkRate(rxBytesPerSec: Double(rxDelta) / elapsed,
                               txBytesPerSec: Double(txDelta) / elapsed)
        }

        lastRx = rxTotal
        lastTx = txTotal
        lastNetTime = now
        return rate
    }

    // MARK: - Load Average

    /// Reads 1/5/15 minute load averages via getloadavg.
    static func readLoadAverage() -> (Double, Double, Double) {
        var loadavg: [Double] = [0, 0, 0]
        getloadavg(&loadavg, 3)
        return (loadavg[0], loadavg[1], loadavg[2])
    }

    // MARK: - Network Interfaces

    struct InterfaceInfo {
        let name: String
        let ip: String
    }

    /// Lists active network interface names and IPs (excludes loopback/virtual).
    static func listInterfaces() -> [InterfaceInfo] {
        var results: [InterfaceInfo] = []

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return results }
        defer { freeifaddrs(ifaddr) }

        var ptr = first
        while true {
            let name = String(cString: ptr.pointee.ifa_name)
            if let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
               name != "lo0" && !name.hasPrefix("awdl") && !name.hasPrefix("utun") {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                            &hostname, socklen_t(hostname.count),
                            nil, 0, NI_NUMERICHOST)
                let ip = String(cString: hostname)
                if ip != "0.0.0.0" && !results.contains(where: { $0.name == name }) {
                    results.append(InterfaceInfo(name: name, ip: ip))
                }
            }
            guard let next = ptr.pointee.ifa_next else { break }
            ptr = next
        }
        return results
    }
}
