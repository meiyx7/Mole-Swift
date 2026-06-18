import Foundation

/// Mirrors the `jsonOutput` emitted by `mo analyze --json`.
struct AnalyzeResult: Codable, Hashable {
    var path: String
    var overview: Bool
    var entries: [AnalyzeEntry]
    var largeFiles: [AnalyzeFileEntry]
    var totalSize: Int64
    var totalFiles: Int64

    enum CodingKeys: String, CodingKey {
        case path, overview, entries
        case largeFiles = "large_files"
        case totalSize = "total_size"
        case totalFiles = "total_files"
    }
}

struct AnalyzeEntry: Codable, Hashable, Identifiable {
    var name: String
    var path: String
    var size: Int64
    var isDir: Bool
    var insight: Bool
    var cleanable: Bool
    var lastAccess: String

    var id: String { path }

    enum CodingKeys: String, CodingKey {
        case name, path, size
        case isDir = "is_dir"
        case insight, cleanable
        case lastAccess = "last_access"
    }
}

struct AnalyzeFileEntry: Codable, Hashable, Identifiable {
    var name: String
    var path: String
    var size: Int64

    var id: String { path }
}
