import Foundation

/// One entry from `mo uninstall --list` (JSON when stdout is piped).
///
/// Note: `size` is a pre-formatted display string (e.g. "1.2 GB") produced by
/// the CLI, and `bundleId` may be empty for non-bundled apps. `sizeKB` and
/// `lastUsedEpoch` are the numeric counterparts used for sorting; both are 0
/// when the CLI could not determine them.
struct AppListEntry: Codable, Hashable, Identifiable {
    var name: String
    var bundleId: String
    var source: String
    var uninstallName: String
    var path: String
    var size: String
    var sizeKB: Int
    var lastUsedEpoch: Int

    var id: String { path }

    enum CodingKeys: String, CodingKey {
        case name
        case bundleId = "bundle_id"
        case source
        case uninstallName = "uninstall_name"
        case path, size
        case sizeKB = "size_kb"
        case lastUsedEpoch = "last_used_epoch"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        bundleId = try c.decodeIfPresent(String.self, forKey: .bundleId) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "App"
        uninstallName = try c.decodeIfPresent(String.self, forKey: .uninstallName) ?? name
        path = try c.decode(String.self, forKey: .path)
        size = try c.decodeIfPresent(String.self, forKey: .size) ?? "N/A"
        // Numeric fields were added later; tolerate older CLI builds that omit them.
        sizeKB = try c.decodeIfPresent(Int.self, forKey: .sizeKB) ?? 0
        lastUsedEpoch = try c.decodeIfPresent(Int.self, forKey: .lastUsedEpoch) ?? 0
    }

    var isHomebrew: Bool { source == "Homebrew" }

    /// Effective size in KB for sorting. Falls back to parsing the `size`
    /// display string (e.g. "1.2GB", "500MB") when `sizeKB` is 0, which
    /// happens when the CLI's quick scan (mdls) couldn't determine the size
    /// and the cache hasn't been refreshed yet.
    var effectiveSizeKB: Int {
        if sizeKB > 0 { return sizeKB }
        return parseSizeStringKB(size)
    }

    private func parseSizeStringKB(_ s: String) -> Int {
        let trimmed = s.trimmingCharacters(in: .whitespaces).uppercased()
        guard !trimmed.isEmpty, trimmed != "N/A", trimmed != "--" else { return 0 }
        let digits = trimmed.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }
        guard let value = Double(String(String.UnicodeScalarView(digits))) else { return 0 }
        if trimmed.contains("GB") { return Int(value * 1_048_576) }
        if trimmed.contains("MB") { return Int(value * 1024) }
        if trimmed.contains("KB") { return Int(value) }
        if trimmed.contains("B") { return Int(value / 1024) }
        return 0
    }
}
