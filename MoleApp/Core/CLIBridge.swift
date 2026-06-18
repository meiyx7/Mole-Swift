import Foundation

/// Options that map directly onto the CLI's flag surface.
struct CLIOptions {
    var dryRun: Bool = false
    var debug: Bool = false
    var extraEnv: [String: String] = [:]
    var workingDirectory: String? = nil
    /// When true, stdin is closed so interactive scripts fall back to their
    /// non-interactive code paths. This is how the GUI drives `clean`,
    /// `optimize`, `purge`, and `installer` without a TTY.
    var nonInteractive: Bool = true

    /// Environment merged on top of the current process environment.
    func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // Force a UTF-8 locale so size/label parsing stays stable.
        env["LC_ALL"] = "en_US.UTF-8"
        env["LANG"] = "en_US.UTF-8"
        if dryRun { env["MOLE_DRY_RUN"] = "1" }
        if debug { env["MO_DEBUG"] = "1" }
        if nonInteractive { env["MOLE_NON_INTERACTIVE"] = "1" }
        for (k, v) in extraEnv { env[k] = v }
        return env
    }
}

/// A single line of process output tagged with its stream.
struct CLIOutputLine: Identifiable, Hashable {
    let id = UUID()
    let text: String
    let isError: Bool
    let date: Date
}

/// Result of a captured (non-streaming) command run.
struct CLIResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    var succeeded: Bool { exitCode == 0 }
}

enum CLIBridgeError: LocalizedError {
    case binaryMissing
    case decodeFailed(String)
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .binaryMissing:
            return "Mole CLI was not found. Install it with `brew install mole` and relaunch the app."
        case .decodeFailed(let detail):
            return "Failed to parse CLI output: \(detail)"
        case .executionFailed(let detail):
            return "Command failed to start: \(detail)"
        }
    }
}

/// Bridges the SwiftUI layer to the installed `mole` CLI.
///
/// All command construction happens here so feature views stay declarative.
/// Every call resolves the live binary path, which means the GUI always
/// reflects the version the user actually installed.
enum CLIBridge {

    // MARK: - Captured execution

    /// Runs a command, collecting stdout and stderr into strings.
    static func run(_ args: [String], options: CLIOptions = CLIOptions()) async throws -> CLIResult {
        guard let binary = CLILocator.resolve() else { throw CLIBridgeError.binaryMissing }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try capture(binary: binary, args: args, options: options)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Runs a command and decodes its stdout as JSON.
    static func runDecoding<T: Decodable>(
        _ args: [String],
        as type: T.Type,
        options: CLIOptions = CLIOptions()
    ) async throws -> T {
        let result = try await run(args, options: options)
        guard let data = result.stdout.data(using: .utf8) else {
            throw CLIBridgeError.decodeFailed("output was not UTF-8")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw CLIBridgeError.decodeFailed("\(error)")
        }
    }

    // MARK: - Streaming execution

    /// Runs a command, delivering each output line to `onLine` as it arrives.
    /// Returns the final exit code. Cancellation is honoured: the process is
    /// terminated when the surrounding `Task` is cancelled.
    @discardableResult
    static func runStreaming(
        _ args: [String],
        options: CLIOptions = CLIOptions(),
        onLine: @escaping (CLIOutputLine) -> Void
    ) async throws -> Int32 {
        guard let binary = CLILocator.resolve() else { throw CLIBridgeError.binaryMissing }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let code = try stream(
                            binary: binary,
                            args: args,
                            options: options,
                            onLine: onLine
                        )
                        continuation.resume(returning: code)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            streamingTerminator?.terminate()
        }
    }

    // MARK: - Convenience builders

    /// Builds the argument vector for a subcommand with optional flags.
    static func args(_ subcommand: String, _ rest: [String] = []) -> [String] {
        [subcommand] + rest
    }

    // MARK: - Private process plumbing

    private static var streamingTerminator: Process?

    private static func capture(binary: String, args: [String], options: CLIOptions) throws -> CLIResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        process.environment = options.environment()
        if let cwd = options.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        if options.nonInteractive, let null = FileHandle(forReadingAtPath: "/dev/null") {
            process.standardInput = null
        }

        do {
            try process.run()
        } catch {
            throw CLIBridgeError.executionFailed("\(error)")
        }
        process.waitUntilExit()

        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return CLIResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    private static func stream(
        binary: String,
        args: [String],
        options: CLIOptions,
        onLine: @escaping (CLIOutputLine) -> Void
    ) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        process.environment = options.environment()
        if let cwd = options.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        if options.nonInteractive, let null = FileHandle(forReadingAtPath: "/dev/null") {
            process.standardInput = null
        }

        streamingTerminator = process

        let lock = NSLock()

        func readLines(from handle: FileHandle, isError: Bool) {
            var buffer = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer.prefix(upTo: nl)
                    buffer.removeSubrange(0...nl)
                    if let text = String(data: lineData, encoding: .utf8) {
                        let cleaned = text.hasSuffix("\r") ? String(text.dropLast()) : text
                        let line = CLIOutputLine(text: cleaned, isError: isError, date: Date())
                        lock.lock(); onLine(line); lock.unlock()
                    }
                }
            }
            if !buffer.isEmpty, let text = String(data: buffer, encoding: .utf8) {
                let line = CLIOutputLine(text: text, isError: isError, date: Date())
                lock.lock(); onLine(line); lock.unlock()
            }
        }

        do {
            try process.run()
        } catch {
            streamingTerminator = nil
            throw CLIBridgeError.executionFailed("\(error)")
        }

        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading

        let outThread = Thread { readLines(from: outHandle, isError: false) }
        let errThread = Thread { readLines(from: errHandle, isError: true) }
        outThread.qualityOfService = .userInitiated
        errThread.qualityOfService = .userInitiated
        outThread.start()
        errThread.start()

        process.waitUntilExit()
        outThread.waitUntilDone()
        errThread.waitUntilDone()
        streamingTerminator = nil
        return process.terminationStatus
    }
}
