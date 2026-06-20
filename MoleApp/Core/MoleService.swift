import Foundation

/// High-level access to every Mole CLI feature.
///
/// Each method maps to one CLI subcommand and returns typed data the SwiftUI
/// views can render directly. JSON-producing commands decode into models;
/// text-producing commands return captured output or streamed lines.
@MainActor
final class MoleService: ObservableObject {

    /// Whether the CLI binary is installed and reachable.
    @Published private(set) var isInstalled: Bool = CLILocator.isAvailable

    /// Re-checks installation state (e.g. after the user runs `mo update`).
    func refreshInstallation() {
        isInstalled = CLILocator.isAvailable
    }

    // MARK: - Version & help

    func version() async -> String {
        guard isInstalled else { return "Not installed" }
        let result = try? await CLIBridge.run(["--version"])
        let raw = result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown"
        // `mo --version` outputs "Mole version 1.43.1\nmacOS: ...". Extract
        // just the semver string so downstream version comparison works.
        if let match = raw.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) {
            return String(raw[match])
        }
        return raw
    }

    func help() async -> String {
        guard isInstalled else { return "Install Mole to see help." }
        let result = try? await CLIBridge.run(["--help"])
        return result?.stdout ?? ""
    }

    // MARK: - Status (JSON)

    /// One-shot system status snapshot for the dashboard.
    func statusSnapshot() async throws -> StatusSnapshot {
        try await CLIBridge.runDecoding(["status", "--json"], as: StatusSnapshot.self)
    }

    // MARK: - Analyze (JSON)

    /// Disk overview (Home, Applications, Library, insights).
    func analyzeOverview() async throws -> AnalyzeResult {
        var options = CLIOptions()
        options.timeout = 60 // 1 minute timeout for overview
        return try await CLIBridge.runDecoding(["analyze", "--json"], as: AnalyzeResult.self, options: options)
    }

    /// Directory-level analysis for a specific path.
    func analyze(path: String) async throws -> AnalyzeResult {
        var options = CLIOptions()
        // Large directories like ~/Library/Containers (600+ subdirs) need more time.
        options.timeout = 300 // 5 minutes timeout for directory analysis
        return try await CLIBridge.runDecoding(["analyze", "--json", path], as: AnalyzeResult.self, options: options)
    }

    // MARK: - History (JSON)

    func history(limit: Int = 50) async throws -> HistoryResult {
        try await CLIBridge.runDecoding(["history", "--json", "--limit", "\(limit)"], as: HistoryResult.self)
    }

    // MARK: - Uninstall (JSON list)

    /// Read-only list of installed apps with sizes and uninstall names.
    func listApps() async throws -> [AppListEntry] {
        try await CLIBridge.runDecoding(["uninstall", "--list"], as: [AppListEntry].self)
    }

    // MARK: - Clean

    /// Streams `mo clean --dry-run` output for the preview pane.
    @discardableResult
    func cleanPreview(onLine: @escaping (CLIOutputLine) -> Void) async throws -> Int32 {
        var options = CLIOptions()
        options.dryRun = true
        options.nonInteractive = true
        return try await CLIBridge.runStreaming(["clean", "--dry-run"], options: options, onLine: onLine)
    }

    /// Runs the real cleanup, streaming progress.
    @discardableResult
    func clean(onLine: @escaping (CLIOutputLine) -> Void) async throws -> Int32 {
        var options = CLIOptions()
        options.nonInteractive = true
        return try await CLIBridge.runStreaming(["clean"], options: options, onLine: onLine)
    }

    // MARK: - Optimize

    @discardableResult
    func optimizePreview(onLine: @escaping (CLIOutputLine) -> Void) async throws -> Int32 {
        var options = CLIOptions()
        options.dryRun = true
        options.nonInteractive = true
        return try await CLIBridge.runStreaming(["optimize", "--dry-run"], options: options, onLine: onLine)
    }

    @discardableResult
    func optimize(onLine: @escaping (CLIOutputLine) -> Void) async throws -> Int32 {
        var options = CLIOptions()
        options.nonInteractive = true
        return try await CLIBridge.runStreaming(["optimize"], options: options, onLine: onLine)
    }

    // MARK: - Purge

    @discardableResult
    func purgePreview(onLine: @escaping (CLIOutputLine) -> Void) async throws -> Int32 {
        var options = CLIOptions()
        options.dryRun = true
        options.nonInteractive = true
        return try await CLIBridge.runStreaming(["purge", "--dry-run"], options: options, onLine: onLine)
    }

    @discardableResult
    func purge(onLine: @escaping (CLIOutputLine) -> Void) async throws -> Int32 {
        var options = CLIOptions()
        options.nonInteractive = true
        return try await CLIBridge.runStreaming(["purge"], options: options, onLine: onLine)
    }

    // MARK: - Installer

    @discardableResult
    func installerPreview(onLine: @escaping (CLIOutputLine) -> Void) async throws -> Int32 {
        var options = CLIOptions()
        options.dryRun = true
        options.nonInteractive = true
        return try await CLIBridge.runStreaming(["installer", "--dry-run"], options: options, onLine: onLine)
    }

    @discardableResult
    func installer(onLine: @escaping (CLIOutputLine) -> Void) async throws -> Int32 {
        var options = CLIOptions()
        options.nonInteractive = true
        return try await CLIBridge.runStreaming(["installer"], options: options, onLine: onLine)
    }

    // MARK: - Uninstall (destructive)

    /// Uninstalls apps by name, streaming progress.
    @discardableResult
    func uninstall(apps: [String], permanent: Bool, onLine: @escaping (CLIOutputLine) -> Void) async throws -> Int32 {
        var args = ["uninstall"]
        if permanent { args.append("--permanent") }
        args.append(contentsOf: apps)
        var options = CLIOptions()
        options.nonInteractive = true
        // Don't auto-answer "y" for uninstall. The CLI checks
        // MOLE_NON_INTERACTIVE and skips its own confirmation prompt.
        // If we pipe "y" here, the CLI commits to the uninstall before
        // the macOS sudo dialog appears; cancelling the password would
        // still leave the app trashed. With noAutoConfirm, if sudo is
        // cancelled the CLI aborts with a non-zero exit code.
        options.noAutoConfirm = true
        return try await CLIBridge.runStreaming(args, options: options, onLine: onLine)
    }

    // MARK: - Touch ID

    func touchidStatus() async -> String {
        let result = try? await CLIBridge.run(["touchid", "status"])
        return result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    @discardableResult
    func touchidEnable(onLine: @escaping (CLIOutputLine) -> Void) async throws -> Int32 {
        try await CLIBridge.runStreaming(["touchid", "enable"], options: CLIOptions(), onLine: onLine)
    }

    @discardableResult
    func touchidDisable(onLine: @escaping (CLIOutputLine) -> Void) async throws -> Int32 {
        try await CLIBridge.runStreaming(["touchid", "disable"], options: CLIOptions(), onLine: onLine)
    }

    // MARK: - Update & remove

    @discardableResult
    func update(force: Bool = false, nightly: Bool = false,
                onLine: @escaping (CLIOutputLine) -> Void) async throws -> Int32 {
        var args = ["update"]
        if force { args.append("--force") }
        if nightly { args.append("--nightly") }
        return try await CLIBridge.runStreaming(args, options: CLIOptions(), onLine: onLine)
    }
}
