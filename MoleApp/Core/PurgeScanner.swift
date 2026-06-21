import Foundation

/// Native Swift scanner for project build artifacts.
///
/// This scanner mirrors the CLI's purge discovery logic in
/// `lib/clean/purge_shared.sh` and `lib/clean/project.sh` so that the GUI
/// and CLI produce the same scan results. The CLI's preview path is
/// interactive-only (TTY selection menu), so the GUI cannot consume
/// `mo purge --dry-run` directly; instead we reproduce the discovery
/// rules here and keep them in sync with the shell source.
///
/// Safety alignment with the CLI:
/// - Same artifact target set (MOLE_PURGE_TARGETS, 34 entries).
/// - Same default search paths (MOLE_PURGE_DEFAULT_SEARCH_PATHS, 9 entries)
///   plus the user config file at ~/.config/mole/purge_paths.
/// - Same max scan depth (6) and project-container detection
///   (MOLE_PURGE_PROJECT_INDICATORS / MOLE_PURGE_MONOREPO_INDICATORS).
/// - Same MIN_AGE_DAYS (7) recency guard: recently modified artifacts are
///   still listed but flagged so the user can tell active builds apart
///   from stale ones.
/// - Same protected-artifact rules: `bin` only purged in .NET context,
///   `vendor` protected when it looks like a Go/Vendored source dir,
///   `DerivedData` only purged inside project dirs (never the global
///   ~/Library/Developer/Xcode/DerivedData).
enum PurgeScanner {

    struct FoundArtifact: Identifiable, Hashable {
        let url: URL
        var sizeBytes: Int64
        let artifactType: String
        let projectName: String
        /// Age in days since the artifact's last modification. Used to flag
        /// recently-modified entries (active builds) so the user can avoid
        /// deleting them. Mirrors the CLI's MIN_AGE_DAYS guard.
        let ageDays: Int
        /// True when the artifact was modified within MIN_AGE_DAYS. The CLI
        /// hides these from purge by default; we surface them with a flag
        /// so the user can still choose to clean them, informed.
        let isRecent: Bool

        var id: String { url.path }
        var sizeText: String { ByteFormatter.bytes(sizeBytes) }
        var displayName: String { url.lastPathComponent }
        /// Short age label matching the CLI's format: <1d / 3d / 2mo / 1y.
        var ageLabel: String {
            if ageDays < 1 { return "<1d" }
            if ageDays < 30 { return "\(ageDays)d" }
            if ageDays < 365 { return "\(ageDays / 30)mo" }
            return "\(ageDays / 365)y"
        }
    }

    // MARK: - Configuration (mirrors lib/clean/purge_shared.sh)

    /// Artifact directory names to scan for. Must stay in sync with
    /// MOLE_PURGE_TARGETS in purge_shared.sh.
    static let artifactPatterns: Set<String> = [
        "node_modules",
        "target",        // Rust, Maven
        "build",         // Gradle, various
        "dist",          // JS builds
        "venv",          // Python
        ".venv",         // Python
        ".pytest_cache", // Python (pytest)
        ".mypy_cache",   // Python (mypy)
        ".tox",          // Python (tox virtualenvs)
        ".nox",          // Python (nox virtualenvs)
        ".ruff_cache",   // Python (ruff)
        ".gradle",       // Gradle local
        "__pycache__",   // Python
        ".next",         // Next.js
        ".nuxt",         // Nuxt.js
        ".output",       // Nuxt.js
        "vendor",        // PHP Composer (guarded; see isProtected)
        "bin",           // .NET build output (guarded; see isProtected)
        "obj",           // C# / Unity
        ".turbo",        // Turborepo cache
        ".parcel-cache", // Parcel bundler
        ".dart_tool",    // Flutter/Dart build cache
        ".zig-cache",    // Zig
        "zig-out",       // Zig
        ".angular",      // Angular
        ".svelte-kit",   // SvelteKit
        ".astro",        // Astro
        "coverage",      // Code coverage reports
        "DerivedData",   // Xcode (guarded; see isProtected)
        "Pods",          // CocoaPods
        ".cxx",          // React Native Android NDK build cache
        ".expo",         // Expo
        ".build",        // Swift Package Manager
    ]

    /// Default search paths. Must stay in sync with
    /// MOLE_PURGE_DEFAULT_SEARCH_PATHS in purge_shared.sh. Tilde is
    /// expanded at scan time.
    private static let defaultSearchPaths: [String] = [
        "~/www",
        "~/dev",
        "~/Projects",
        "~/GitHub",
        "~/Code",
        "~/Workspace",
        "~/Repos",
        "~/Development",
        "~/Library/CloudStorage",
    ]

    /// Monorepo indicator files. Presence of any one means the directory
    /// is a monorepo root and we should keep descending into workspace
    /// packages. Mirrors MOLE_PURGE_MONOREPO_INDICATORS.
    private static let monorepoIndicators: Set<String> = [
        "lerna.json",
        "pnpm-workspace.yaml",
        "nx.json",
        "rush.json",
    ]

    /// Project indicator files. Presence of any one means the directory is
    /// a project root. Used by isProjectContainer to skip non-project dirs.
    /// Mirrors MOLE_PURGE_PROJECT_INDICATORS.
    private static let projectIndicators: Set<String> = [
        "package.json",
        "Cargo.toml",
        "go.mod",
        "pyproject.toml",
        "requirements.txt",
        "pom.xml",
        "build.gradle",
        "Gemfile",
        "composer.json",
        "pubspec.yaml",
        "Package.swift",
        "Makefile",
        "build.zig",
        "build.zig.zon",
        ".git",
    ]

    /// Directories that are never project containers. Mirrors the basename
    /// skip list in is_project_container() in project.sh.
    private static let nonProjectDirs: Set<String> = [
        "Library", "Applications", "Movies", "Music", "Pictures", "Public",
    ]

    /// Minimum age in days before an artifact is considered safe to clean.
    /// Mirrors MIN_AGE_DAYS in project.sh. Artifacts newer than this are
    /// still listed but flagged `isRecent = true`.
    static let minAgeDays: Int = 7

    /// Maximum scan depth relative to each search root. Mirrors
    /// PURGE_MAX_DEPTH_DEFAULT in project.sh.
    static let maxScanDepth: Int = 6

    // MARK: - Scan

    /// Scans configured project directories for build artifacts.
    /// Resolves search paths from the default set plus the user config
    /// file at ~/.config/mole/purge_paths (one path per line, `#` comments
    /// and blank lines ignored, `~` expanded).
    static func scan() -> [FoundArtifact] {
        var results: [FoundArtifact] = []
        let fm = FileManager.default
        let home = NSHomeDirectory()

        // Build the resolved search path set. Resolve symlinks and
        // standardize case before deduping: macOS HFS+/APFS is
        // case-insensitive, so ~/Code and ~/code point to the same dir.
        // Without this, both paths pass fileExists and the same artifacts
        // get scanned twice, producing duplicate entries.
        // Keep original-paths list for traversal; use standardized set
        // only for dedup so display paths stay readable.
        var seenRoots = Set<String>()
        var searchPaths: [String] = []
        for raw in defaultSearchPaths + readUserConfigPaths(home: home) {
            let expanded = expandTilde(raw, home: home)
            let key = standardizePath(expanded, fm: fm)
            if seenRoots.insert(key).inserted {
                searchPaths.append(expanded)
            }
        }

        let now = Date().timeIntervalSince1970

        for rootPath in searchPaths {
            guard fm.fileExists(atPath: rootPath) else { continue }
            let rootURL = URL(fileURLWithPath: rootPath)
            // Only descend into directories that look like project
            // containers. This mirrors is_project_container() and prevents
            // scanning unrelated dirs (Documents, Movies, etc.).
            guard isProjectContainer(rootURL, depth: 0, fm: fm) else { continue }
            scanDirectory(rootURL, depth: 0, fm: fm, now: now, into: &results)
        }

        // Dedupe by resolved path: overlapping search roots (e.g. ~/dev
        // containing ~/dev/subdir that is also a configured root) can
        // surface the same artifact via two paths. Keep the first
        // (largest-size) occurrence.
        var seen = Set<String>()
        results = results.filter { seen.insert($0.url.resolvingSymlinksInPath().path).inserted }

        // Sort by size descending, matching the CLI's default ordering.
        return results.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Standardizes a path for dedup: resolves symlinks and lowercases
    /// for case-insensitive comparison on HFS+/APFS. Returns the original
    /// path if resolution fails (non-existent path).
    private static func standardizePath(_ path: String, fm: FileManager) -> String {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        return url.path.lowercased()
    }

    // MARK: - Scan internals

    private static func scanDirectory(
        _ url: URL, depth: Int, fm: FileManager,
        now: TimeInterval, into results: inout [FoundArtifact]
    ) {
        guard depth <= maxScanDepth else { return }

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
                // Protected artifacts are skipped entirely, matching the
                // CLI's filter_protected_artifacts / is_protected_purge_artifact.
                if isProtectedArtifact(entry, type: dirName, fm: fm) { continue }

                let size = directorySize(url: entry, fm: fm)
                // Skip trivially small dirs (< 1KB) to avoid noise, matching
                // the CLI's `size > 1024` threshold.
                guard size > 1024 else { continue }

                let modInterval = modificationAgeDays(url: entry, fm: fm, now: now)
                let ageDays = modInterval ?? 0
                results.append(FoundArtifact(
                    url: entry,
                    sizeBytes: size,
                    artifactType: dirName,
                    projectName: entry.deletingLastPathComponent().lastPathComponent,
                    ageDays: ageDays,
                    isRecent: ageDays < minAgeDays
                ))
            } else if depth < maxScanDepth {
                // Keep descending. We don't gate on isProjectContainer here
                // because artifact dirs can nest inside non-project folders
                // (e.g. a monorepo packages/ dir). The depth cap prevents
                // runaway traversal.
                scanDirectory(entry, depth: depth + 1, fm: fm, now: now, into: &results)
            }
        }
    }

    /// Returns true if `url` looks like a project container: it contains a
    /// monorepo or project indicator file, or one of its subdirectories
    /// (up to depth 2) does. Mirrors is_project_container() in project.sh.
    private static func isProjectContainer(_ url: URL, depth: Int, fm: FileManager) -> Bool {
        let basename = url.lastPathComponent
        if basename.hasPrefix(".") { return false }
        if nonProjectDirs.contains(basename) { return false }

        // Check for indicators directly in this directory.
        for name in monorepoIndicators where fm.fileExists(atPath: url.appendingPathComponent(name).path) {
            return true
        }
        for name in projectIndicators where fm.fileExists(atPath: url.appendingPathComponent(name).path) {
            return true
        }

        // Check one level deeper (max_depth=2 in the CLI).
        guard depth < 2 else { return false }
        guard let entries = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return false }

        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            if isProjectContainer(entry, depth: depth + 1, fm: fm) { return true }
        }
        return false
    }

    /// Mirrors is_protected_purge_artifact() in project.sh. Returns true
    /// when the artifact should be protected from purge.
    private static func isProtectedArtifact(_ url: URL, type: String, fm: FileManager) -> Bool {
        switch type {
        case "bin":
            // Only allow purging bin/ in a .NET context (sibling .csproj
            // or .fsproj). Otherwise protect: bin could be a system bin,
            // a Go install dir, etc.
            return !isDotNetBinDir(url, fm: fm)
        case "vendor":
            // Protect Go vendor dirs and similar source vendoring. The CLI
            // protects vendor when it contains Go source or a .gitkeep.
            return isProtectedVendorDir(url, fm: fm)
        case "DerivedData":
            // Protect the global Xcode DerivedData. Only allow purging
            // DerivedData inside project directories.
            let path = url.path
            if path.contains("/Library/Developer/Xcode/DerivedData") {
                return true // protected (global location)
            }
            return false
        default:
            return false
        }
    }

    /// Returns true if `bin/` sits next to a .csproj/.fsproj/.vbproj,
    /// indicating a .NET build output that's safe to purge.
    private static func isDotNetBinDir(_ url: URL, fm: FileManager) -> Bool {
        let parent = url.deletingLastPathComponent()
        let projs = [".csproj", ".fsproj", ".vbproj"]
        guard let entries = try? fm.contentsOfDirectory(atPath: parent.path) else {
            return false
        }
        return entries.contains { name in
            projs.contains { name.hasSuffix($0) }
        }
    }

    /// Returns true if `vendor/` looks like a Go/vendor source dir (contains
    /// .go files or a vendor.json). Mirrors is_protected_vendor_dir.
    private static func isProtectedVendorDir(_ url: URL, fm: FileManager) -> Bool {
        // Heuristic: if the vendor dir contains Go source or a manifest,
        // treat it as protected source rather than a build artifact.
        guard let entries = try? fm.contentsOfDirectory(atPath: url.path) else {
            return false
        }
        for name in entries {
            if name.hasSuffix(".go") { return true }
            if name == "vendor.json" || name == "modules.txt" { return true }
        }
        return false
    }

    // MARK: - Size & age helpers

    /// Computes the total size of a directory tree in bytes. Mirrors
    /// get_dir_size_kb but returns bytes (the CLI returns KB; we convert
    /// at display time). Uses FileManager enumerator with skipsHiddenFiles.
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

    /// Returns the age in days since the artifact's last modification,
    /// or nil if the modification time can't be read.
    private static func modificationAgeDays(url: URL, fm: FileManager, now: TimeInterval) -> Int? {
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let modDate = attrs[.modificationDate] as? Date else {
            return nil
        }
        let interval = now - modDate.timeIntervalSince1970
        return max(0, Int(interval / 86400))
    }

    // MARK: - Path resolution

    /// Expands a leading `~` to the home directory.
    private static func expandTilde(_ path: String, home: String) -> String {
        if path.hasPrefix("~/") {
            return home + String(path.dropFirst(1))
        }
        if path == "~" {
            return home
        }
        return path
    }

    /// Reads the user purge-paths config file at
    /// `~/.config/mole/purge_paths`. Each non-empty, non-comment line is
    /// a search root; `~` is expanded. Mirrors
    /// mole_purge_read_paths_config in purge_shared.sh.
    private static func readUserConfigPaths(home: String) -> [String] {
        let configURL = URL(fileURLWithPath: home)
            .appendingPathComponent(".config/mole/purge_paths")
        guard let content = try? String(contentsOf: configURL, encoding: .utf8) else {
            return []
        }
        var paths: [String] = []
        for raw in content.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw)
            // Trim whitespace.
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip blanks and comments.
            if line.isEmpty || line.hasPrefix("#") { continue }
            line = expandTilde(line, home: home)
            paths.append(line)
        }
        return paths
    }
}
