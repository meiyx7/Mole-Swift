import Foundation

/// Scans common download/desktop locations for installer files (.dmg, .pkg,
/// .iso, .xip, .zip) — the same paths the `mo installer` CLI scans.
///
/// The installer CLI's preview path is interactive-only: it launches a TTY
/// selection menu that fails under non-interactive stdin, so the GUI cannot
/// get a file list from `mo installer --dry-run`. This scanner reproduces the
/// CLI's discovery logic directly in Swift so the installer screen can show a
/// visual preview of found files with sizes.
enum InstallerScanner {
    struct FoundFile: Identifiable, Hashable {
        let url: URL
        let sizeBytes: Int64
        let source: String
        var id: String { url.path }
        var sizeText: String { ByteFormatter.bytes(sizeBytes) }
        var displayName: String { url.lastPathComponent }
    }

    /// Paths mirrored from `bin/installer.sh` `INSTALLER_SCAN_PATHS`.
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
            "\(home)/Library/Mobile Documents/com~apple~CloudDocs/Downloads"
        ]
    }

    private static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip"]

    /// Scan all configured paths (max depth 2, matching the CLI default) and
    /// return found installer files sorted by size descending.
    static func scan() -> [FoundFile] {
        var results: [FoundFile] = []
        let fm = FileManager.default

        for rootPath in scanPaths {
            guard fm.fileExists(atPath: rootPath) else { continue }
            let rootURL = URL(fileURLWithPath: rootPath)
            scanDirectory(rootURL, depth: 0, maxDepth: 2, fm: fm, into: &results)
        }

        return results.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    private static func scanDirectory(
        _ url: URL, depth: Int, maxDepth: Int,
        fm: FileManager, into results: inout [FoundFile]
    ) {
        guard depth <= maxDepth else { return }
        guard let entries = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return }

        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                if depth < maxDepth {
                    scanDirectory(entry, depth: depth + 1, maxDepth: maxDepth, fm: fm, into: &results)
                }
            } else {
                if let file = makeFoundFile(entry) {
                    results.append(file)
                }
            }
        }
    }

    private static func makeFoundFile(_ url: URL) -> FoundFile? {
        let ext = url.pathExtension.lowercased()
        guard installerExtensions.contains(ext) || ext == "zip" else { return nil }

        // Skip symlinks (matches CLI behaviour).
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: url.path) {
            if let type = attrs[.type] as? FileAttributeType, type == .typeSymbolicLink { return nil }
        }

        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        return FoundFile(
            url: url,
            sizeBytes: size,
            source: sourceName(for: url)
        )
    }

    /// Friendly source label matching the CLI's `get_source_display`.
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
        if parent.contains("CloudDocs/Downloads") { return "iCloud" }
        return url.deletingLastPathComponent().lastPathComponent
    }
}
