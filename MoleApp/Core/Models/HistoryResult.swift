import Foundation

/// Mirrors the JSON emitted by `mo history --json`.
///
/// The CLI produces a top-level object with `logs`, `limit`, a `sessions`
/// array (operation sessions) and a separate `deletions` array (the per-file
/// deletion audit). Sessions do NOT nest deletions; deletions are global.
struct HistoryResult: Codable, Hashable {
    var logs: HistoryLogs
    var limit: Int
    var sessions: [HistorySession]
    var deletions: [HistoryDeletion]
}

struct HistoryLogs: Codable, Hashable {
    var operations: String
    var deletions: String
}

struct HistorySession: Codable, Hashable, Identifiable {
    var command: String
    var startedAt: String
    var endedAt: String
    var items: Int
    var size: String
    var operationCount: Int
    var actions: HistoryActions

    var id: String { "\(startedAt)-\(command)" }

    enum CodingKeys: String, CodingKey {
        case command
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case items, size
        case operationCount = "operation_count"
        case actions
    }

    /// Total file actions recorded for this session.
    var totalActions: Int {
        actions.removed + actions.trashed + actions.skipped + actions.failed + actions.rebuilt + actions.other
    }
}

struct HistoryActions: Codable, Hashable {
    var removed: Int
    var trashed: Int
    var skipped: Int
    var failed: Int
    var rebuilt: Int
    var other: Int
}

struct HistoryDeletion: Codable, Hashable, Identifiable {
    var timestamp: String
    var mode: String
    var status: String
    var sizeKb: Int?
    var path: String

    var id: String { "\(timestamp)-\(path)" }

    enum CodingKeys: String, CodingKey {
        case timestamp, mode, status
        case sizeKb = "size_kb"
        case path
    }

    /// Bytes reclaimed, when `size_kb` is a known number.
    var bytes: Int64? {
        guard let sizeKb else { return nil }
        return Int64(sizeKb) * 1024
    }
}
