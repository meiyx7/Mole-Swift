import Foundation

/// Mirrors the `MetricsSnapshot` JSON emitted by `mo status --json`.
struct StatusSnapshot: Codable, Hashable {
    var collectedAt: Date
    var host: String
    var platform: String
    var uptime: String
    var uptimeSeconds: Double
    var procs: Double
    var hardware: HardwareInfo
    var healthScore: Int
    var healthScoreMsg: String
    var cpu: CPUStatus
    var gpu: [GPUStatus]
    var memory: MemoryStatus
    var disks: [DiskStatus]
    var trashSize: Double
    var trashApprox: Bool
    var diskIO: DiskIOStatus
    var network: [NetworkStatus]
    var networkHistory: NetworkHistory
    var proxy: ProxyStatus
    /// `batteries` is `null` on machines without a battery (Mac mini, Mac Pro,
    /// iMac, desktop Macs in general).
    var batteries: [BatteryStatus]?
    var thermal: ThermalStatus
    /// `sensors` is `null` on machines without SMC sensor access (e.g. Mac mini
    /// without permission, or Apple Silicon without SMC).
    var sensors: [SensorReading]?
    var bluetooth: [BluetoothDevice]
    var topProcesses: [ProcessInfo]
    var processWatch: ProcessWatchConfig
    var processAlerts: [ProcessAlert]

    enum CodingKeys: String, CodingKey {
        case collectedAt = "collected_at"
        case host, platform, uptime
        case uptimeSeconds = "uptime_seconds"
        case procs, hardware
        case healthScore = "health_score"
        case healthScoreMsg = "health_score_msg"
        case cpu, gpu, memory, disks
        case trashSize = "trash_size"
        case trashApprox = "trash_approx"
        case diskIO = "disk_io"
        case network
        case networkHistory = "network_history"
        case proxy, batteries, thermal, sensors, bluetooth
        case topProcesses = "top_processes"
        case processWatch = "process_watch"
        case processAlerts = "process_alerts"
    }
}

struct HardwareInfo: Codable, Hashable {
    var model: String
    var cpuModel: String
    var totalRAM: String
    var diskSize: String
    var osVersion: String
    var refreshRate: String

    enum CodingKeys: String, CodingKey {
        case model
        case cpuModel = "cpu_model"
        case totalRAM = "total_ram"
        case diskSize = "disk_size"
        case osVersion = "os_version"
        case refreshRate = "refresh_rate"
    }
}

struct CPUStatus: Codable, Hashable {
    var usage: Double
    var perCore: [Double]
    var perCoreEstimated: Bool
    var load1: Double
    var load5: Double
    var load15: Double
    var coreCount: Int
    var logicalCPU: Int
    var pCoreCount: Int
    var eCoreCount: Int

    enum CodingKeys: String, CodingKey {
        case usage, perCore = "per_core"
        case perCoreEstimated = "per_core_estimated"
        case load1, load5, load15
        case coreCount = "core_count"
        case logicalCPU = "logical_cpu"
        case pCoreCount = "p_core_count"
        case eCoreCount = "e_core_count"
    }
}

struct GPUStatus: Codable, Hashable {
    var name: String
    var usage: Double
    var memoryUsed: Double
    var memoryTotal: Double
    var coreCount: Int
    var note: String

    enum CodingKeys: String, CodingKey {
        case name, usage
        case memoryUsed = "memory_used"
        case memoryTotal = "memory_total"
        case coreCount = "core_count"
        case note
    }
}

struct MemoryStatus: Codable, Hashable {
    var used: Double
    var total: Double
    var available: Double
    var usedPercent: Double
    var swapUsed: Double
    var swapTotal: Double
    var cached: Double
    var pressure: String

    enum CodingKeys: String, CodingKey {
        case used, total, available
        case usedPercent = "used_percent"
        case swapUsed = "swap_used"
        case swapTotal = "swap_total"
        case cached, pressure
    }
}

struct DiskStatus: Codable, Hashable {
    var mount: String
    var device: String
    var used: Double
    var total: Double
    var usedPercent: Double
    var fstype: String
    var external: Bool

    enum CodingKeys: String, CodingKey {
        case mount, device, used, total
        case usedPercent = "used_percent"
        case fstype, external
    }
}

struct DiskIOStatus: Codable, Hashable {
    var readRate: Double
    var writeRate: Double

    enum CodingKeys: String, CodingKey {
        case readRate = "read_rate"
        case writeRate = "write_rate"
    }
}

struct NetworkStatus: Codable, Hashable {
    var name: String
    var rxRateMBs: Double
    var txRateMBs: Double
    var ip: String

    enum CodingKeys: String, CodingKey {
        case name
        case rxRateMBs = "rx_rate_mbs"
        case txRateMBs = "tx_rate_mbs"
        case ip
    }
}

struct NetworkHistory: Codable, Hashable {
    var rxHistory: [Double]
    var txHistory: [Double]

    enum CodingKeys: String, CodingKey {
        case rxHistory = "rx_history"
        case txHistory = "tx_history"
    }
}

struct ProxyStatus: Codable, Hashable {
    var enabled: Bool
    var type: String
    var host: String
}

struct BatteryStatus: Codable, Hashable {
    var percent: Double
    var status: String
    var timeLeft: String
    var health: String
    var cycleCount: Int
    var capacity: Int

    enum CodingKeys: String, CodingKey {
        case percent, status
        case timeLeft = "time_left"
        case health
        case cycleCount = "cycle_count"
        case capacity
    }
}

struct ThermalStatus: Codable, Hashable {
    var cpuTemp: Double
    var gpuTemp: Double
    var batteryTemp: Double
    var fanSpeed: Int
    var fanCount: Int
    var systemPower: Double
    var adapterPower: Double
    var batteryPower: Double

    enum CodingKeys: String, CodingKey {
        case cpuTemp = "cpu_temp"
        case gpuTemp = "gpu_temp"
        case batteryTemp = "battery_temp"
        case fanSpeed = "fan_speed"
        case fanCount = "fan_count"
        case systemPower = "system_power"
        case adapterPower = "adapter_power"
        case batteryPower = "battery_power"
    }
}

struct SensorReading: Codable, Hashable {
    var label: String
    var value: Double
    var unit: String
    var note: String
}

struct BluetoothDevice: Codable, Hashable {
    var name: String
    var connected: Bool
    var battery: String
}

struct ProcessInfo: Codable, Hashable {
    var pid: Int
    var ppid: Int
    var name: String
    var command: String
    var cpu: Double
    var memory: Double
    var memoryBytes: Double?

    enum CodingKeys: String, CodingKey {
        case pid, ppid, name, command, cpu, memory
        case memoryBytes = "memory_bytes"
    }
}

struct ProcessWatchConfig: Codable, Hashable {
    var enabled: Bool
    var cpuThreshold: Double
    var window: String

    enum CodingKeys: String, CodingKey {
        case enabled
        case cpuThreshold = "cpu_threshold"
        case window
    }
}

struct ProcessAlert: Codable, Hashable {
    var pid: Int
    var name: String
    var command: String?
    var cpu: Double
    var threshold: Double
    var window: String
    var triggeredAt: Date
    var status: String

    enum CodingKeys: String, CodingKey {
        case pid, name, command, cpu, threshold, window
        case triggeredAt = "triggered_at"
        case status
    }
}
