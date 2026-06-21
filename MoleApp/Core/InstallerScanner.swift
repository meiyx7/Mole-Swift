import Foundation

/// Scans common download/desktop locations for installer files (.dmg, .pkg,
/// .iso, .xip, .zip) — the same paths the `mo installer` CLI scans.
///
/// The installer CLI's preview path is interactive-only: it launches a TTY
/// selection menu that fails under non-interactive stdin, so the GUI cannot
/// get a file list from `mo installer --dry-run`. This scanner reproduces the
/// CLI's discovery logic directly in Swift so the installer screen can show a
/// visual preview of found files with sizes.
///
/// Alignment with `bin/installer.sh`:
/// - Same `INSTALLER_SCAN_PATHS` (12 entries, including Mail Downloads and
///   Telegram Desktop).
/// - Same `is_installer_zip()` filter: a `.zip` is only listed when its
///   first 50 entries contain an `.app/.pkg/.dmg/.xip` payload. Without this
///   the GUI would list every zip in Downloads, but the CLI would only
///   delete installer-bearing zips — causing preview/execute divergence.
/// - Same hidden-file inclusion (`fd --no-ignore --hidden` / `find` without
///   skip-hidden). The CLI does not skip hidden files.
/// - Same `get_source_display()` source labels (Downloads/Desktop/.../Mail/
///   Telegram).
/// - Same Homebrew hash-prefix stripping (`sha256--name--version` →
///   `name--version`) so Homebrew cache entries are readable.
/// - Same `INSTALLER_SCAN_MAX_DEPTH_DEFAULT=2`, overridable via
///   `MOLE_INSTALLER_SCAN_MAX_DEPTH`.
enum InstallerScanner {
    struct FoundFile: Identifiable, Hashable {
        let url: URL
        let sizeBytes: Int64
        let source: String
        /// Display name with Homebrew hash prefix stripped, matching the CLI.
        let displayName: String
        var id: String { url.path }
        var sizeText: String { ByteFormatter.bytes(sizeBytes) }
    }

    /// Paths mirrored from `bin/installer.sh` `INSTALLER_SCAN_PATHS`.
    /// Must stay in sync with the shell array.
    static var scanPaths: [String] {
        let home = NSHomeDirectory()
        return [
            "\(home)/Downloads",
            "\(home)/Desktop",
            "\(home)/Documents",
            "\(home)/Public",
            "\(home)/Library/Downloads",
            "/Users/Shared",
            "/Users/Shared/Downloads",
            "\(home)/Library/Caches/Homebrew",
            "\(home)/Library/Mobile Documents/com~apple~CloudDocs/Downloads",
            "\(home)/Library/Containers/com.apple.mail/Data/Library/Mail Downloads",
            "\(home)/Library/Application Support/Telegram Desktop",
            "\(home)/Downloads/Telegram Desktop",
        ]
    }

    /// Installer extensions accepted unconditionally (no content check).
    /// Mirrors the case branches in `handle_candidate_file()`.
    private static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip"]

    /// Extensions inside a .zip that qualify it as an installer archive.
    /// Mirrors the awk pattern in `is_installer_zip()`.
    private static let zipPayloadExtensions: Set<String> = ["app", "pkg", "dmg", "xip"]

    /// Max zip entries to inspect, matching `MAX_ZIP_ENTRIES`.
    private static let maxZipEntries = 50

    /// Max scan depth, matching `INSTALLER_SCAN_MAX_DEPTH_DEFAULT`. Can be
    /// overridden via `MOLE_INSTALLER_SCAN_MAX_DEPTH` env var, matching the
    /// CLI's `${MOLE_INSTALLER_SCAN_MAX_DEPTH:-$INSTALLER_SCAN_MAX_DEPTH_DEFAULT}`.
    private static var maxDepth: Int {
        if let raw = ProcessInfo.processInfo.environment["MOLE_INSTALLER_SCAN_MAX_DEPTH"],
           let n = Int(raw), n > 0 {
            return n
        }
        return 2
    }

    /// Scan all configured paths and return found installer files sorted by
    /// size descending. Mirrors `scan_all_installers()` + the size sort.
    static func scan() -> [FoundFile] {
        var results: [FoundFile] = []
        let fm = FileManager.default

        for rootPath in scanPaths {
            guard fm.fileExists(atPath: rootPath) else { continue }
            let rootURL = URL(fileURLWithPath: rootPath)
            // NOTE: we do NOT pass .skipsHiddenFiles here. The CLI uses
            // `fd --no-ignore --hidden` / `find` without -not-path '.*',
            // so hidden files are included. Skipping them would cause
            // GUI/CLI scan divergence.
            scanDirectory(rootURL, depth: 0, fm: fm, into: &results)
        }

        return results.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    private static func scanDirectory(
        _ url: URL, depth: Int,
        fm: FileManager, into results: inout [FoundFile]
    ) {
        guard depth <= maxDepth else { return }
        // No .skipsHiddenFiles: match the CLI's hidden-inclusive scan.
        guard let entries = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: []
        ) else { return }

        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                if depth < maxDepth {
                    scanDirectory(entry, depth: depth + 1, fm: fm, into: &results)
                }
            } else {
                if let file = makeFoundFile(entry, fm: fm) {
                    results.append(file)
                }
            }
        }
    }

    /// Mirrors `handle_candidate_file()`: accept installer extensions
    /// unconditionally; for `.zip`, only accept if `isInstallerZip` returns
    /// true. Symlinks are always skipped.
    private static func makeFoundFile(_ url: URL, fm: FileManager) -> FoundFile? {
        let ext = url.pathExtension.lowercased()
        guard installerExtensions.contains(ext) || ext == "zip" else { return nil }

        // Skip symlinks (matches CLI `[[ -L "$file" ]] && return 0`).
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let type = attrs[.type] as? FileAttributeType,
           type == .typeSymbolicLink {
            return nil
        }

        // For .zip, verify it actually contains an installer payload.
        // Without this check the GUI would list every zip in Downloads,
        // but the CLI only deletes installer-bearing zips.
        if ext == "zip" {
            guard isInstallerZip(url: url, fm: fm) else { return nil }
        }

        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let source = sourceName(for: url)
        return FoundFile(
            url: url,
            sizeBytes: size,
            source: source,
            displayName: strippedDisplayName(filename: url.lastPathComponent, source: source)
        )
    }

    /// Mirrors `is_installer_zip()`: inspect the first `maxZipEntries`
    /// entries of the zip and return true if any ends with an installer
    /// payload extension (.app/.pkg/.dmg/.xip). Returns false if the zip
    /// can't be read (matches the CLI's `2>/dev/null` swallow).
    private static func isInstallerZip(url: URL, fm: FileManager) -> Bool {
        guard fm.isReadableFile(atPath: url.path) else { return false }

        // Use the system `unzip -Z -1` (zipinfo equivalent) to list entries.
        // The CLI prefers `zipinfo -1`, falls back to `unzip -Z -1`. We use
        // `unzip -Z -1` since it's always present on macOS (zipinfo is too,
        // but unzip -Z -1 is the documented stable interface).
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z", "-1", url.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()  // swallow errors, matching 2>/dev/null

        do {
            try process.run()
        } catch {
            return false
        }

        // Read only the first `maxZipEntries` lines, then terminate the
        // process early so we don't buffer huge zip listings.
        let data = pipe.fileHandleForReading.readData(ofLength: 64 * 1024)
        process.terminate()
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return false }

        var count = 0
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            count += 1
            if count > maxZipEntries { break }
            let entry = String(line).lowercased()
            // Match the awk pattern: entry path ends with .app/.pkg/.dmg/.xip
            // possibly followed by a directory separator.
            for payloadExt in zipPayloadExtensions {
                if entry.hasSuffix(".\(payloadExt)") || entry.contains(".\(payloadExt)/") {
                    return true
                }
            }
        }
        return false
    }

    /// Friendly source label matching the CLI's `get_source_display()`.
    /// Order matters: more specific prefixes first (e.g. Mail Downloads
    /// before generic Library).
    private static func sourceName(for url: URL) -> String {
        let parent = url.deletingLastPathComponent().path
        let home = NSHomeDirectory()
        if parent.hasPrefix("\(home)/Downloads") { return "Downloads" }
        if parent.hasPrefix("\(home)/Desktop") { return "Desktop" }
        if parent.hasPrefix("\(home)/Documents") { return "Documents" }
        if parent.hasPrefix("\(home)/Public") { return "Public" }
        if parent.hasPrefix("\(home)/Library/Downloads") { return "Library" }
        if parent.hasPrefix("/Users/Shared") { return "Shared" }
        if parent.hasPrefix("\(home)/Library/Caches/Homebrew") { return "Homebrew" }
        if parent.hasPrefix("\(home)/Library/Mobile Documents/com~apple~CloudDocs/Downloads") { return "iCloud" }
        if parent.hasPrefix("\(home)/Library/Containers/com.apple.mail") { return "Mail" }
        if parent.contains("Telegram Desktop") { return "Telegram" }
        return url.deletingLastPathComponent().lastPathComponent
    }

    /// Strips the Homebrew `sha256--` hash prefix from a filename when the
    /// source is Homebrew, matching the CLI's regex
    /// `^[0-9a-f]{64}--(.*)`. Non-Homebrew filenames are returned as-is.
    private static func strippedDisplayName(filename: String, source: String) -> String {
        guard source == "Homebrew" else { return filename }
        // Match 64 hex chars followed by `--`.
        let pattern = "^[0-9a-f]{64}--(.*)$"
        if let regex = try? NSRegularExpression(pattern: pattern, options: []),
           let match = regex.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)),
           let r = Range(match.range(at: 1), in: filename) {
            return String(filename[r])
        }
        return filename
    }
}
