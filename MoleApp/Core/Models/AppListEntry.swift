import Foundation

/// One entry from `mo uninstall --list` (JSON when stdout is piped).
///
/// Note: `size` is a pre-formatted display string (e.g. "1.2 GB") produced by
/// the CLI, and `bundleId` may be empty for non-bundled apps.
struct AppListEntry: Codable, Hashable, Identifiable {
    var name: String
    var bundleId: String
    var source: String
    var uninstallName: String
    var path: String
    var size: String

    var id: String { path }

    enum CodingKeys: String, CodingKey {
        case name
        case bundleId = "bundle_id"
        case source
        case uninstallName = "uninstall_name"
        case path, size
    }

    var isHomebrew: Bool { source == "Homebrew" }
}
