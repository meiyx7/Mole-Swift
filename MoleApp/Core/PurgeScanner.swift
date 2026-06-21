import Foundation

/// Native Swift scanner for project build artifacts.
///
/// The purge CLI's preview path is interactive-only (TTY selection menu),
/// so the GUI cannot get a file list from `mo purge --dry-run`. This scanner
/// reproduces the CLI's discovery logic in Swift for visual preview and
/// user selection.
enum PurgeScanner {
    struct FoundArtifact: Identifiable, Hashable {
        let url: URL
        var sizeBytes: Int64
        let artifactType: String
        let projectName: String
        var id: String { url.path }
        var sizeText: String { ByteFormatter.bytes(sizeBytes) }
        var displayName: String { url.lastPathComponent }
    }

    /// Artifact directory names to scan for (matching CLI's scan logic).
    static let artifactPatterns: Set<String> = [
        "node_modules",
        "target",
        "build",
        "dist",
        "out",
        "DerivedData",
        ".venv",
        "venv",
        "__pycache__",
        ".gradle",
        ".m2",
        "Pods",
        ".turbo"
    ]

    /// Scan configured project directories for build artifacts.
    static func scan() -> [FoundArtifact] {
        var results: [FoundArtifact] = []
        let fm = FileManager.default
        let home = NSHomeDirectory()

        let searchPaths = [
            "\(home)/workspace",
            "\(home)/Workspace",
            "\(home)/dev",
            "\(home)/projects",
            "\(home)/Projects",
            "\(home)/src",
            "\(home)/code"
        ]

        for rootPath in searchPaths {
            guard fm.fileExists(atPath: rootPath) else { continue }
            scanDirectory(URL(fileURLWithPath: rootPath), depth: 0, maxDepth: 3, fm: fm, into: &results)
        }

        return results.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    private static func scanDirectory(
        _ url: URL, depth: Int, maxDepth: Int,
        fm: FileManager, into results: inout [FoundArtifact]
    ) {
        guard depth <= maxDepth else { return }

        guard let entries = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }

            let dirName = entry.lastPathComponent

            if artifactPatterns.contains(dirName) {
                let size = directorySize(url: entry, fm: fm)
                if size > 1024 {
                    results.append(FoundArtifact(
                        url: entry,
                        sizeBytes: size,
                        artifactType: dirName,
                        projectName: entry.deletingLastPathComponent().lastPathComponent
                    ))
                }
            } else if depth < maxDepth {
                scanDirectory(entry, depth: depth + 1, maxDepth: maxDepth, fm: fm, into: &results)
            }
        }
    }

    private static func directorySize(url: URL, fm: FileManager) -> Int64 {
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        while let fileURL = enumerator.nextObject() as? URL {
            if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
               let size = attrs[.size] as? Int64 {
                total += size
            }
        }
        return total
    }
}
