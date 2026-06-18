import Foundation

/// Formatting helpers for byte sizes and percentages shared across views.
enum ByteFormatter {
    /// Formats a raw byte count as a human-readable string (e.g. "1.2 GB").
    static func bytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func bytes(_ bytes: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Formats a rate in bytes/sec as "1.2 MB/s".
    static func rate(bytesPerSecond: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: Int64(bytesPerSecond)) + "/s"
    }

    /// One-decimal percentage with a trailing %.
    static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    /// Integer percentage, clamped to 0–100.
    static func percentInt(_ value: Double) -> Int {
        max(0, min(100, Int(value.rounded())))
    }
}

/// Shared colour logic for health/gauge states.
enum StatusTone {
    case good, warn, critical, neutral

    static func forUsage(_ percent: Double) -> StatusTone {
        switch percent {
        case ..<70: return .good
        case ..<90: return .warn
        default: return .critical
        }
    }

    static func forHealthScore(_ score: Int) -> StatusTone {
        switch score {
        case 80...: return .good
        case 50..<80: return .warn
        default: return .critical
        }
    }
}
