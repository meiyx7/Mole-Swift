import Foundation

/// Writes diagnostic information for CLI failures to a log file in the
/// user's Library/Logs directory so issues like "cannot parse cli output"
/// can be debugged without attaching a debugger.
///
/// The log path is `~/Library/Logs/MoleApp/debug.log`. Entries are
/// appended, and the file is rotated when it exceeds `maxLogSize`
/// (5 MB) to prevent unbounded growth.
enum DebugLog {
    /// Maximum log file size before rotation. When exceeded, the current
    /// log is moved to `debug.log.old` and a fresh log is started.
    private static let maxLogSize: Int64 = 5 * 1024 * 1024  // 5 MB

    /// Resolves `~/Library/Logs/MoleApp/debug.log`. Creates the directory
    /// if needed. Falls back to a temp path if the directory cannot be
    /// created.
    static var logURL: URL {
        let home = NSHomeDirectory()
        let logsDir = URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Logs/MoleApp")
        let fm = FileManager.default
        try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
        return logsDir.appendingPathComponent("debug.log")
    }

    /// Human-readable path for surfacing in error messages.
    static var logPath: String { logURL.path }

    /// Appends a timestamped entry to the log file. Best-effort: failures are
    /// swallowed silently so logging never masks the original error. Rotates
    /// the log if it exceeds `maxLogSize`.
    static func append(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let block = """
        ========================================
        \(stamp)
        \(message)
        """
        let payload = (block as NSString).appending("\n\n")
        guard let data = payload.data(using: .utf8) else { return }
        let fm = FileManager.default
        let url = logURL

        // Rotate if the file has grown too large.
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64, size > maxLogSize {
            let oldURL = url.deletingLastPathComponent().appendingPathComponent("debug.log.old")
            try? fm.removeItem(at: oldURL)
            try? fm.moveItem(at: url, to: oldURL)
        }

        if fm.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                _ = try? handle.write(contentsOf: data)
                try? handle.close()
            }
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Logs a decoding failure with full command + output context.
    static func logDecodeFailure(
        args: [String],
        exitCode: Int32,
        stdout: String,
        stderr: String,
        error: Error
    ) {
        let block = """
        [DECODE FAILURE]
        command: mo \(args.joined(separator: " "))
        exit code: \(exitCode)
        error: \(error)

        --- stdout (length=\(stdout.count)) ---
        \(stdout)

        --- stderr (length=\(stderr.count)) ---
        \(stderr)
        """
        append(block)
    }

    /// Logs an execution failure (process could not start / binary missing).
    static func logExecutionFailure(args: [String], error: Error) {
        let block = """
        [EXECUTION FAILURE]
        command: mo \(args.joined(separator: " "))
        error: \(error)
        """
        append(block)
    }
}
