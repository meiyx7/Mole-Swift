import Foundation

/// Safe deletion for analyze-driven ad hoc cleanup.
///
/// Mirrors the safety contract of the CLI's `cmd/analyze/delete.go`:
///
/// 1. **Trash routing**: paths are moved to the Trash via
///    `FileManager.trashItem(at:)`, not permanently removed. This matches
///    the CLI's `moveToTrash` (Finder AppleScript) path so the user can
///    recover from a mistake. The AGENTS.md rule "analyze-driven ad hoc
///    cleanup uses Trash routing" is honoured here.
/// 2. **Protected-path check**: mirrors `isProtectedAnalyzeDeletePath`
///    in `cmd/analyze/delete.go` — OrbStack state dir and Group Containers
///    `*.dev.orbstack` entries are rejected. The CLI's `validatePath`
///    (absolute, no null bytes, no `..` traversal) is also mirrored.
/// 3. **Operation log**: every trashed path is appended to
///    `~/Library/Logs/MoleApp/analyze.log`, matching the CLI's oplog
///    contract so users can audit what was removed.
///
/// All three guarantees must hold before a path is removed. If any check
/// fails the path is reported as an error and left untouched.
enum AnalyzeDeleter {

    /// Result of trashing a single path.
    struct DeleteOutcome {
        let path: String
        let name: String
        let size: Int64
        let isDir: Bool
        let success: Bool
        let message: String
        /// The URL the path was moved to in the Trash, if successful.
        let trashedURL: URL?
    }

    /// Trashes the given paths. Each path is processed independently: a
    /// failure on one does not abort the rest. Returns an outcome per path
    /// so the caller can report partial success.
    ///
    /// Deeper paths are processed first to avoid parent/child conflicts
    /// (matching `deleteMultiplePathsCmd` in `cmd/analyze/delete.go`).
    ///
    /// `onProgress` is invoked on the main actor after each path is
    /// processed, with the count completed so far.
    @MainActor
    static func trashPaths(
        _ paths: [String],
        sizes: [String: Int64],
        onProgress: @MainActor (Int) -> Void
    ) -> [DeleteOutcome] {
        let fm = FileManager.default

        // Process deeper paths first so we never delete a parent before its
        // children (which would orphan the child entry and confuse the user).
        let sorted = paths.sorted { lhs, rhs in
            lhs.components(separatedBy: "/").count > rhs.components(separatedBy: "/").count
        }

        var outcomes: [DeleteOutcome] = []
        for (index, path) in sorted.enumerated() {
            let outcome = trashOne(
                path: path,
                size: sizes[path] ?? 0,
                fm: fm
            )
            outcomes.append(outcome)
            onProgress(index + 1)
        }
        return outcomes
    }

    /// Trashes a single path with full safety checks. Returns the outcome
    /// describing what happened.
    private static func trashOne(
        path: String,
        size: Int64,
        fm: FileManager
    ) -> DeleteOutcome {
        let name = (path as NSString).lastPathComponent

        // 1. Validate path: must be absolute, no null bytes, no traversal.
        //    Mirrors `validatePath` in cmd/analyze/delete.go.
        if let err = validateAnalyzePath(path) {
            return DeleteOutcome(
                path: path, name: name, size: size, isDir: false,
                success: false, message: err, trashedURL: nil
            )
        }

        // 2. Reject protected paths. Mirrors `isProtectedAnalyzeDeletePath`:
        //    OrbStack state and Group Containers *.dev.orbstack entries.
        //    Additionally consult ProtectionResolver to honor the CLI's
        //    SYSTEM_CRITICAL_BUNDLES / DATA_PROTECTED_BUNDLES lists so the
        //    GUI stays in sync with CLI updates without code changes.
        if isProtectedAnalyzeDeletePath(path) {
            return DeleteOutcome(
                path: path, name: name, size: size, isDir: false,
                success: false, message: "protected path", trashedURL: nil
            )
        }
        if let reason = ProtectionResolver.protectedReason(path: path, bundleID: nil) {
            return DeleteOutcome(
                path: path, name: name, size: size, isDir: false,
                success: false, message: "protected: \(reason)", trashedURL: nil
            )
        }

        // 3. Path must still exist (user may have removed it elsewhere).
        //    Use fileExists to handle both files and directories.
        guard fm.fileExists(atPath: path) else {
            return DeleteOutcome(
                path: path, name: name, size: size, isDir: false,
                success: false, message: "no longer exists", trashedURL: nil
            )
        }

        let isDir = isDirectory(path: path, fm: fm)
        let url = URL(fileURLWithPath: path)

        // 4. Route to Trash. FileManager.trashItem moves the item to the
        //    user's Trash and returns the resulting URL. This is the
        //    recoverable path, matching the CLI's moveToTrash default.
        do {
            var resultingURL: NSURL?
            try fm.trashItem(at: url, resultingItemURL: &resultingURL)
            let trashed = resultingURL as URL?

            // 5. Append to the operation log so the user can audit what
            //    was removed and when. Matches the CLI's oplog contract.
            logOperation(
                path: path,
                size: size,
                isDir: isDir,
                trashedURL: trashed,
                success: true
            )
            // 5b. Also append to the CLI's unified deletions.log so
            //     `mo history --json` includes GUI-driven deletes.
            UnifiedOperationLog.appendToCLIDeletionLog(
                path: path,
                sizeBytes: size,
                mode: "trash",
                status: "trashed"
            )

            return DeleteOutcome(
                path: path, name: name, size: size, isDir: isDir,
                success: true, message: "trashed", trashedURL: trashed
            )
        } catch {
            logOperation(
                path: path,
                size: size,
                isDir: isDir,
                trashedURL: nil,
                success: false,
                error: error.localizedDescription
            )
            UnifiedOperationLog.appendToCLIDeletionLog(
                path: path,
                sizeBytes: size,
                mode: "trash",
                status: "failed",
                error: error.localizedDescription
            )
            return DeleteOutcome(
                path: path, name: name, size: size, isDir: isDir,
                success: false, message: error.localizedDescription, trashedURL: nil
            )
        }
    }

    // MARK: - Path validation (mirrors cmd/analyze/delete.go)

    /// Mirrors `validatePath` in cmd/analyze/delete.go: rejects empty,
    /// relative, null-byte, or `..` traversal paths.
    static func validateAnalyzePath(_ path: String) -> String? {
        if path.isEmpty { return "path is empty" }
        if !path.hasPrefix("/") { return "path must be absolute: \(path)" }
        if path.contains("\0") { return "path contains null bytes" }
        let components = path.components(separatedBy: "/")
        if components.contains("..") { return "path contains traversal components: \(path)" }
        return nil
    }

    /// Mirrors `isProtectedAnalyzeDeletePath` in cmd/analyze/delete.go.
    /// Rejects the OrbStack state dir and Group Containers entries whose
    /// container name ends with `dev.orbstack`.
    static func isProtectedAnalyzeDeletePath(_ path: String) -> Bool {
        let home = NSHomeDirectory()
        guard !home.isEmpty, !path.isEmpty else { return false }

        let cleanPath = (path as NSString).standardizingPath
        let orbstackState = (home as NSString).appendingPathComponent(".orbstack")
        if cleanPath == orbstackState { return true }
        if cleanPath.hasPrefix(orbstackState + "/") { return true }

        let groupContainers = (home as NSString)
            .appendingPathComponent("Library/Group Containers")
        guard cleanPath.hasPrefix(groupContainers + "/") else { return false }

        let rel = String(cleanPath.dropFirst(groupContainers.count + 1))
        let containerName: String
        if let idx = rel.firstIndex(of: "/") {
            containerName = String(rel[..<idx])
        } else {
            containerName = rel
        }
        return containerName.hasSuffix("dev.orbstack")
    }

    private static func isDirectory(path: String, fm: FileManager) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: - Operation log

    /// Appends a line to the analyze operation log at
    /// `~/Library/Logs/MoleApp/analyze.log`. Rotated by size (1MB cap)
    /// to avoid unbounded growth, matching the purge.log policy.
    private static func logOperation(
        path: String,
        size: Int64,
        isDir: Bool,
        trashedURL: URL?,
        success: Bool,
        error: String? = nil
    ) {
        let logDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/MoleApp")
        let logURL = logDir.appendingPathComponent("analyze.log")

        try? FileManager.default.createDirectory(
            at: logDir,
            withIntermediateDirectories: true
        )

        if let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
           let size = attrs[.size] as? Int64,
           size > 1_048_576 {
            try? FileManager.default.removeItem(at: logURL)
        }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let status = success ? "TRASHED" : "FAILED"
        let kind = isDir ? "dir" : "file"
        var line = "\(timestamp) | \(status) | \(kind) | \(size) | \(path)"
        if let trashed = trashedURL {
            line += " | -> \(trashed.path)"
        }
        if let error = error {
            line += " | \(error)"
        }
        line += "\n"

        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path) {
                if let handle = try? FileHandle(forWritingTo: logURL) {
                    defer { try? handle.close() }
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                }
            } else {
                try? data.write(to: logURL)
            }
        }
    }
}
