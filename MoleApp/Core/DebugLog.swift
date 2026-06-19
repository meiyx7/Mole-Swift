import Foundation

/// Writes diagnostic information for CLI failures to a log file on the user's
/// Desktop so issues like "cannot parse cli output" can be debugged without
/// attaching a debugger.
///
/// The log path is `~/Desktop/MoleApp-debug.log`. Entries are appended, never
/// overwritten, so multiple failures accumulate for a single support session.
enum DebugLog {
    /// Resolves `~/Desktop/MoleApp-debug.log`. Falls back to a temp path if the
    /// Desktop folder cannot be located (e.g. sandboxed HOME without a Desktop).
    static var logURL: URL {
        let home = NSHomeDirectory()
        let desktop = URL(fileURLWithPath: home).appendingPathComponent("Desktop")
        return desktop.appendingPathComponent("MoleApp-debug.log")
    }

    /// Human-readable path for surfacing in error messages.
    static var logPath: String { logURL.path }

    /// Appends a timestamped entry to the log file. Best-effort: failures are
    /// swallowed silently so logging never masks the original error.
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
