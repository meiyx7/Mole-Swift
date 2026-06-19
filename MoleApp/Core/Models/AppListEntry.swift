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
}
