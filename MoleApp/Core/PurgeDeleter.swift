import Foundation

/// Safe deletion for purge artifacts.
///
/// This mirrors the safety contract of the CLI's `mole_delete` in
/// `lib/core/file_ops.sh`:
///
/// 1. **Trash routing**: artifacts are moved to the Trash via
///    `FileManager.trashItem(at:)`, not permanently removed. The user can
///    recover from the Trash if a purge was a mistake. This matches the
///    CLI's default behavior where user-facing cleanup routes through the
///    Trash for recoverability.
/// 2. **Protected-path check**: before trashing, the path is validated
///    against a protected-path blocklist (system dirs, user data dirs, and
///    the global Xcode DerivedData). This mirrors the CLI's
///    `should_protect_path` + `is_protected_purge_artifact` guards.
/// 3. **Operation log**: every trashed artifact is appended to the purge
///    operation log at `~/Library/Logs/MoleApp/purge.log`, matching the
///    CLI's oplog behavior so users can audit what was removed.
///
/// All three guarantees must hold before a path is removed. If any check
/// fails the artifact is reported as an error and left untouched.
enum PurgeDeleter {

    /// Result of trashing a single artifact.
    struct DeleteOutcome {
        let artifact: PurgeScanner.FoundArtifact
        let success: Bool
        let message: String
        /// The URL the artifact was moved to in the Trash, if successful.
        let trashedURL: URL?
    }

    /// Paths that must never be purged, even if they match an artifact
    /// pattern. Mirrors the spirit of `should_protect_path` for the purge
    /// domain: system directories, user data directories, and the global
    /// Xcode DerivedData (which is managed by Xcode itself).
    private static let protectedPathPrefixes: [String] = {
        let home = NSHomeDirectory()
        return [
            "/System",
            "/Library/Apple",
            "\(home)/Library/Developer/Xcode/DerivedData",
            "\(home)/Library/Containers",
            "\(home)/Library/Group Containers",
            "\(home)/Library/Preferences",
            "\(home)/Library/Mail",
            "\(home)/Library/Messages",
            "\(home)/Library/Cookies",
            "\(home)/Library/Keychains",
            "\(home)/Library/Accounts",
            "\(home)/Library/Application Support",
            "\(home)/Library/Caches",
            "\(home)/.ssh",
            "\(home)/.config",
            "\(home)/.gnupg",
            "\(home)/Documents",
            "\(home)/Desktop",
            "\(home)/Downloads",
            "\(home)/Pictures",
            "\(home)/Movies",
            "\(home)/Music",
        ]
    }()

    /// Trashes the given artifacts. Each artifact is processed independently:
    /// a failure on one does not abort the rest. Returns an outcome per
    /// artifact so the caller can report partial success.
    ///
    /// The `onProgress` closure is invoked on the main actor after each
    /// artifact is processed, with the count completed so far.
    @MainActor
    static func trashArtifacts(
        _ artifacts: [PurgeScanner.FoundArtifact],
        onProgress: @MainActor (Int) -> Void
    ) -> [DeleteOutcome] {
        let fm = FileManager.default
        var outcomes: [DeleteOutcome] = []

        for (index, artifact) in artifacts.enumerated() {
            let outcome = trashOne(artifact, fm: fm)
            outcomes.append(outcome)
            onProgress(index + 1)
        }
        return outcomes
    }

    /// Trashes a single artifact with full safety checks. Returns the
    /// outcome describing what happened.
    private static func trashOne(
        _ artifact: PurgeScanner.FoundArtifact,
        fm: FileManager
    ) -> DeleteOutcome {
        let path = artifact.url.path

        // 1. Path must be inside the user's home directory. This is the
        //    outer guard; protectedPathPrefixes handles the finer-grained
        //    blocks inside home.
        let home = NSHomeDirectory()
        guard path.hasPrefix(home) else {
            return DeleteOutcome(
                artifact: artifact,
                success: false,
                message: "outside home directory",
                trashedURL: nil
            )
        }

        // 2. Reject protected path prefixes. This catches the case where
        //    an artifact pattern (e.g. `build`) happens to exist inside a
        //    protected dir like ~/Library/Caches.
        if isProtected(path: path, home: home) {
            return DeleteOutcome(
                artifact: artifact,
                success: false,
                message: "protected path",
                trashedURL: nil
            )
        }

        // 3. Artifact type must be in the known set. Defense in depth in
        //    case the caller constructed an artifact with an unknown type.
        guard PurgeScanner.artifactPatterns.contains(artifact.artifactType) else {
            return DeleteOutcome(
                artifact: artifact,
                success: false,
                message: "unknown artifact type",
                trashedURL: nil
            )
        }

        // 4. Path must still exist (user may have removed it elsewhere).
        guard fm.fileExists(atPath: path) else {
            return DeleteOutcome(
                artifact: artifact,
                success: false,
                message: "no longer exists",
                trashedURL: nil
            )
        }

        // 5. Route to Trash. FileManager.trashItem moves the item to the
        //    user's Trash and returns the resulting URL. This is the
        //    recoverable path, matching the CLI's mole_delete default.
        do {
            var resultingURL: NSURL?
            try fm.trashItem(at: artifact.url, resultingItemURL: &resultingURL)
            let trashed = resultingURL as URL?

            // 6. Append to the operation log so the user can audit what
            //    was removed and when. Matches the CLI's oplog contract.
            logOperation(
                artifact: artifact,
                trashedURL: trashed,
                success: true
            )

            return DeleteOutcome(
                artifact: artifact,
                success: true,
                message: "trashed",
                trashedURL: trashed
            )
        } catch {
            logOperation(
                artifact: artifact,
                trashedURL: nil,
                success: false,
                error: error.localizedDescription
            )
            return DeleteOutcome(
                artifact: artifact,
                success: false,
                message: error.localizedDescription,
                trashedURL: nil
            )
        }
    }

    /// Returns true if `path` starts with any protected prefix. Uses
    /// standardized path comparison (no trailing slash) to avoid bypass
    /// via `~/Library/Caches/` vs `~/Library/Caches`.
    private static func isProtected(path: String, home: String) -> Bool {
        for prefix in protectedPathPrefixes {
            if path == prefix { return true }
            if path.hasPrefix(prefix + "/") { return true }
        }
        return false
    }

    // MARK: - Operation log

    /// Appends a line to the purge operation log. The log lives at
    /// `~/Library/Logs/MoleApp/purge.log` and is rotated by size (1MB cap)
    /// to avoid unbounded growth, matching the debug.log rotation policy.
    private static func logOperation(
        artifact: PurgeScanner.FoundArtifact,
        trashedURL: URL?,
        success: Bool,
        error: String? = nil
    ) {
        let logDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/MoleApp")
        let logURL = logDir.appendingPathComponent("purge.log")

        // Ensure the log directory exists.
        try? FileManager.default.createDirectory(
            at: logDir,
            withIntermediateDirectories: true
        )

        // Rotate if the log exceeds 1MB.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
           let size = attrs[.size] as? Int64,
           size > 1_048_576 {
            try? FileManager.default.removeItem(at: logURL)
        }

        // Format: ISO8601 timestamp | status | size | path [| trashedURL] [| error]
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let status = success ? "TRASHED" : "FAILED"
        var line = "\(timestamp) | \(status) | \(artifact.sizeBytes) | \(artifact.url.path)"
        if let trashed = trashedURL {
            line += " | -> \(trashed.path)"
        }
        if let error = error {
            line += " | \(error)"
        }
        line += "\n"

        // Append. Use Data to avoid read-modify-write of the whole file.
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
