import Foundation

/// Mirrors the JSON emitted by `mo history --json`.
struct HistoryResult: Codable, Hashable {
    var sessions: [HistorySession]
    var totalSessions: Int
    var totalDeleted: Int
    var totalReclaimed: Int64

    enum CodingKeys: String, CodingKey {
        case sessions
        case totalSessions = "total_sessions"
        case totalDeleted = "total_deleted"
        case totalReclaimed = "total_reclaimed"
    }
}

struct HistorySession: Codable, Hashable, Identifiable {
    var timestamp: String
    var command: String
    var itemsDeleted: Int
    var sizeReclaimed: Int64
    var duration: String
    var dryRun: Bool
    var deletions: [HistoryDeletion]

    var id: String { "\(timestamp)-\(command)" }

    enum CodingKeys: String, CodingKey {
        case timestamp, command
        case itemsDeleted = "items_deleted"
        case sizeReclaimed = "size_reclaimed"
        case duration
        case dryRun = "dry_run"
        case deletions
    }
}

struct HistoryDeletion: Codable, Hashable, Identifiable {
    var path: String
    var size: Int64
    var category: String

    var id: String { path }
}
