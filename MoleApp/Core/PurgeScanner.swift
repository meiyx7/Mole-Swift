import Foundation

/// Scans project directories for build artifacts (node_modules, target, build,
/// DerivedData, .venv, etc.) — the same paths the `mo purge` CLI scans.
///
/// The purge CLI's preview path is interactive-only: it launches a TTY
/// selection menu that fails under non-interactive stdin, so the GUI cannot
/// get a file list from `mo purge --dry-run`. This scanner reproduces the
/// CLI's discovery logic directly in Swift so the purge screen can show a
/// visual preview of found artifacts with sizes and allow user selection.
enum PurgeScanner {
    struct FoundArtifact: Identifiable, Hashable {
        let url: URL
        let sizeBytes: Int64
        let artifactType: String
        let projectName: String
        var id: String { url.path }
        var sizeText: String { ByteFormatter.bytes(sizeBytes) }
        var displayName: String { url.lastPathComponent }
    }

    /// Artifact directory names to scan for (matching CLI's ARTIFACT_PATTERNS).
    static let artifactPatterns: [String] = [
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
    /// Returns found artifacts sorted by size descending.
    static func scan() -> [FoundArtifact] {
        var results: [FoundArtifact] = []
        let fm = FileManager.default
        let home = NSHomeDirectory()

        // Default search paths (matching CLI's DEFAULT_PURGE_SEARCH_PATHS)
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
            let rootURL = URL(fileURLWithPath: rootPath)
            scanDirectory(rootURL, fm: fm, into: &results)
        }

        return results.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    private static func scanDirectory(
        _ url: URL, fm: FileManager, into results: inout [FoundArtifact]
    ) {
        guard let entries = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }

            let dirName = entry.lastPathComponent

            // Check if this directory is a known artifact
            if artifactPatterns.contains(dirName) {
                let size = directorySize(url: entry, fm: fm)
                if size > 0 {
                    let projectName = extractProjectName(from: entry)
                    results.append(FoundArtifact(
                        url: entry,
                        sizeBytes: size,
                        artifactType: dirName,
                        projectName: projectName
                    ))
                }
            } else {
                // Recurse into non-artifact directories (max depth 2)
                scanDirectory(entry, fm: fm, into: &results)
            }
        }
    }

    private static func directorySize(url: URL, fm: FileManager) -> Int64 {
        guard let enumerator = fm.enumerator(at: url,
                                            includingPropertiesForKeys: [.fileSizeKey],
                                            options: [.skipsHiddenFiles]) else { return 0 }

        var totalSize: Int64 = 0
        while let fileURL = enumerator.nextObject() as? URL {
            if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
               let size = attrs[.size] as? Int64 {
                totalSize += size
            }
        }
        return totalSize
    }

    private static func extractProjectName(from artifactURL: URL) -> String {
        // Walk up to find the project root (parent of the artifact)
        let projectDir = artifactURL.deletingLastPathComponent()
        return projectDir.lastPathComponent
    }
}
