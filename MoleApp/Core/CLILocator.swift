import Foundation

/// Locates the installed `mole` / `mo` CLI binary.
///
/// The GUI is a thin native front-end over the existing CLI: it shells out to
/// the same `mole` entry script (and the bundled Go `analyze`/`status` helpers)
/// that terminal users run. This keeps every safety boundary, whitelist rule,
/// and operation log identical to the CLI.
enum CLILocator {
    /// Candidate binary names in resolution order.
    static let names = ["mole", "mo"]

    /// Well-known install locations checked before falling back to PATH.
    static let knownPaths: [String] = [
        "/opt/homebrew/bin/mole",
        "/opt/homebrew/bin/mo",
        "/usr/local/bin/mole",
        "/usr/local/bin/mo",
        NSHomeDirectory() + "/.local/bin/mole",
        NSHomeDirectory() + "/.local/bin/mo"
    ]

    /// Resolved absolute path to the CLI, or `nil` when Mole is not installed.
    static func resolve() -> String? {
        for path in knownPaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        for name in names {
            if let path = findInPATH(name) {
                return path
            }
        }
        return nil
    }

    /// Returns `true` when the CLI is available on this machine.
    static var isAvailable: Bool { resolve() != nil }

    /// Looks up an executable by name on the user's `PATH`.
    private static func findInPATH(_ name: String) -> String? {
        let path = NSProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in path.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
