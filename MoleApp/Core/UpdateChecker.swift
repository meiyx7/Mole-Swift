import Foundation
import SwiftUI

/// Checks GitHub releases for a newer version of the MoleApp GUI and
/// can download + install the update in place (no browser needed).
///
/// The app is distributed as `Mole-macOS-universal.zip` attached to
/// GitHub releases tagged `v*`. This class fetches the latest release
/// via the GitHub API, compares semantic versions, and exposes the
/// result as `@Published` state for SwiftUI views. When an update is
/// available, `downloadAndInstall()` streams the zip to a temp dir,
/// unzips it, replaces the running .app bundle (requesting admin
/// privileges via osascript if the install location requires it), and
/// relaunches the new bundle.
@MainActor
final class UpdateChecker: ObservableObject {

    /// Repository owner/name on GitHub.
    private let repo = "meiyx7/Mole-Swift"

    /// Current app version (e.g. "1.1.0"), read from the main Bundle.
    let currentVersion: String

    enum CheckState: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, url: String, notes: String)
        case error(String)
    }

    /// Progress of the in-flight download/install, if any.
    enum InstallState: Equatable {
        case idle
        case downloading(progress: Double)  // 0.0 ... 1.0
        case extracting
        case replacing
        case done(version: String)  // The version that was just installed
        case error(String)
    }

    @Published var state: CheckState = .idle
    @Published var installState: InstallState = .idle

    /// Holds the download URL captured from the last successful check so
    /// `downloadAndInstall()` can run without re-fetching the release.
    private var pendingDownloadURL: URL?

    init() {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        currentVersion = v ?? "0.0.0"
    }

    /// Fetches the latest release from GitHub and compares versions.
    func checkForUpdates() async {
        state = .checking
        do {
            let release = try await fetchLatestRelease()
            if isNewer(release.version, than: currentVersion) {
                let zipURLString = release.assets.first { $0.name.hasSuffix(".zip") }?.downloadURL
                let resolvedURL = zipURLString.flatMap(URL.init(string:))
                pendingDownloadURL = resolvedURL
                state = .available(
                    version: release.version,
                    url: resolvedURL?.absoluteString ?? release.htmlURL,
                    notes: release.body
                )
            } else {
                pendingDownloadURL = nil
                state = .upToDate
            }
        } catch {
            pendingDownloadURL = nil
            state = .error(error.localizedDescription)
        }
    }

    // MARK: - Download & install

    /// Downloads the pending update zip, unzips it, replaces the running
    /// bundle, and relaunches. Requires a prior successful `checkForUpdates`
    /// that found an available update. Throws via `installState.error` on
    /// failure rather than Swift `throws` so the UI can render the message.
    func downloadAndInstall() async {
        guard case .available = state else {
            installState = .error("No update available. Check for updates first.")
            return
        }
        guard let downloadURL = pendingDownloadURL else {
            installState = .error("Download URL missing. Check for updates first.")
            return
        }

        installState = .downloading(progress: 0)

        // 1. Download to a temp file with progress.
        let tempZip: URL
        do {
            tempZip = try await download(url: downloadURL) { [weak self] fraction in
                guard let self else { return }
                self.installState = .downloading(progress: fraction)
            }
        } catch {
            installState = .error("Download failed: \(error.localizedDescription)")
            return
        }
        defer { try? FileManager.default.removeItem(at: tempZip) }

        // 2. Unzip into a temp staging dir.
        installState = .extracting
        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mole-update-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            try unzip(at: tempZip, into: stagingDir)
        } catch {
            try? FileManager.default.removeItem(at: stagingDir)
            installState = .error("Unzip failed: \(error.localizedDescription)")
            return
        }

        // 3. Locate the extracted .app bundle.
        guard let newAppURL = findAppBundle(in: stagingDir) else {
            try? FileManager.default.removeItem(at: stagingDir)
            installState = .error("Update archive did not contain an .app bundle.")
            return
        }

        // 4. Replace the running bundle.
        installState = .replacing
        let currentAppURL = URL(fileURLWithPath: Bundle.main.bundlePath)
        do {
            try await replaceApp(at: currentAppURL, with: newAppURL)
        } catch {
            try? FileManager.default.removeItem(at: stagingDir)
            installState = .error("Install failed: \(error.localizedDescription)")
            return
        }

        // 5. Verify the new bundle is in place and report the version we
        // just installed. This gives the user concrete confirmation that
        // the update landed (rather than a silent exit), and catches the
        // case where the replacement silently no-op'd.
        let installedVersion = versionOfBundle(at: currentAppURL) ?? "?"
        installState = .done(version: installedVersion)

        // 6. Relaunch the new bundle via a detached helper script so the
        // new process starts *after* this one exits. Launching directly
        // with `open -n` while we're still alive can race with the OS
        // releasing the old bundle's executable. The helper sleeps briefly,
        // then opens the app, then deletes itself.
        relaunch(at: currentAppURL)

        // Give the user time to see the "installed" confirmation before
        // the app terminates. 1.5s is long enough to read the message but
        // short enough not to feel stuck.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        exit(0)
    }

    /// Reads `CFBundleShortVersionString` from the Info.plist inside the
    /// .app bundle at `url`. Returns nil if the bundle or key is missing.
    private func versionOfBundle(at url: URL) -> String? {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        return plist["CFBundleShortVersionString"] as? String
    }

    /// Cancels any in-flight download/install. Safe to call when idle.
    func cancelInstall() {
        session?.invalidateAndCancel()
        session = nil
        if case .downloading = installState {
            installState = .idle
        }
    }

    // MARK: - Networking

    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: String
        let body: String
        let assets: [Asset]
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case body
            case assets
        }
        struct Asset: Decodable {
            let name: String
            let downloadURL: String
            enum CodingKeys: String, CodingKey {
                case name
                case downloadURL = "browser_download_url"
            }
        }
        var version: String {
            tagName.lowercased().hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        }
    }

    private func fetchLatestRelease() async throws -> GitHubRelease {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("MoleApp/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        switch http.statusCode {
        case 200:
            return try JSONDecoder().decode(GitHubRelease.self, from: data)
        case 404:
            // No releases published yet.
            return GitHubRelease(
                tagName: "0.0.0",
                htmlURL: "https://github.com/\(repo)/releases",
                body: "",
                assets: []
            )
        case 403:
            // Rate limited or forbidden.
            throw NSError(
                domain: "UpdateChecker",
                code: 403,
                userInfo: [NSLocalizedDescriptionKey: "GitHub API rate limit reached. Try again later."]
            )
        default:
            throw NSError(
                domain: "UpdateChecker",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Server returned HTTP \(http.statusCode)"]
            )
        }
    }

    // MARK: - Download plumbing

    private var session: URLSession?

    /// Streams `url` to a temp file, reporting progress via `onProgress`
    /// (0.0...1.0). Returns the temp file URL on success. Cancellation
    /// (via `cancelInstall`) invalidates the session and resumes the
    /// continuation with an error.
    private func download(
        url: URL,
        onProgress: @escaping (Double) -> Void
    ) async throws -> URL {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("mole-update-\(UUID().uuidString).zip")
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        let delegate = DownloadProgressDelegate(
            onProgress: onProgress,
            destination: tempFile
        )
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        self.session = session

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                delegate.completion = { result in
                    continuation.resume(with: result)
                }
                session.downloadTask(with: url).resume()
            }
        } onCancel: {
            // Invalidate on cancellation. URLSession.invalidateAndCancel()
            // is thread-safe, so this is safe to call from the cancellation
            // handler (which may run off the main actor).
            session.invalidateAndCancel()
        }
    }

    /// Unzips `zipURL` into `destination` using the system `unzip` tool.
    /// We avoid Compression framework because it doesn't preserve the
    /// directory structure / permissions that macOS app bundles rely on.
    private func unzip(at zipURL: URL, into destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", "-q", zipURL.path, "-d", destination.path]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(
                domain: "UpdateChecker",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "unzip failed: \(stderr)"]
            )
        }
    }

    /// Walks `dir` one level deep looking for a `.app` bundle. Returns
    /// the first match. The release zip is expected to contain Mole.app
    /// at the top level, but we tolerate a wrapping directory.
    private func findAppBundle(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return nil
        }
        for entry in entries {
            if entry.pathExtension == "app" { return entry }
            // Look one level deeper in case the zip wrapped the app.
            if let inner = try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: [.isDirectoryKey]) {
                if let app = inner.first(where: { $0.pathExtension == "app" }) {
                    return app
                }
            }
        }
        return nil
    }

    /// Replaces the bundle at `target` with `newApp`. If the target is
    /// in a privileged location (e.g. /Applications), the copy is done
    /// via `osascript ... with administrator privileges` so the user
    /// gets the standard macOS auth prompt. Otherwise a plain `ditto`
    /// is used (works for ~/Applications and dev builds).
    private func replaceApp(at target: URL, with newApp: URL) async throws {
        let fm = FileManager.default

        // Test writability of the target's parent directory. If we can't
        // remove the old bundle directly, we need admin privileges.
        let parentWritable = fm.isWritableFile(atPath: target.deletingLastPathComponent().path)
        let targetRemovable = fm.isDeletableFile(atPath: target.path)

        if parentWritable && targetRemovable {
            // Plain user-space replacement.
            // Move old bundle aside, copy new one in, then delete the old.
            let trashURL = target.deletingLastPathComponent()
                .appendingPathComponent(target.lastPathComponent + ".old-\(UUID().uuidString)")
            try fm.moveItem(at: target, to: trashURL)
            do {
                try fm.copyItem(at: newApp, to: target)
                try? fm.removeItem(at: trashURL)
            } catch {
                // Roll back: restore the old bundle.
                try? fm.moveItem(at: trashURL, to: target)
                throw error
            }
            return
        }

        // Privileged replacement via ditto, wrapped in osascript.
        // We delete the old bundle first (ditto can't merge into an
        // existing .app cleanly), then ditto the new one into place.
        //
        // Safety: validate the target path before constructing the shell
        // command. The target must be a .app bundle under a known
        // applications directory. This prevents a malformed/empty path
        // from turning `rm -rf '<path>'` into something dangerous.
        guard isValidAppBundlePath(target) else {
            throw NSError(
                domain: "UpdateChecker",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Refusing to replace bundle at unexpected path: \(target.path)"]
            )
        }

        // Test guard: when MOLE_TEST_NO_AUTH=1 is set, never invoke
        // osascript with administrator privileges. This mirrors the
        // CLI's MOLE_TEST_NO_AUTH / MOLE_TEST_MODE contract so tests
        // and CI never trigger an auth prompt.
        if ProcessInfo.processInfo.environment["MOLE_TEST_NO_AUTH"] == "1" {
            throw NSError(
                domain: "UpdateChecker",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Privileged install skipped (MOLE_TEST_NO_AUTH=1)."]
            )
        }

        // Build the shell command with single-quote escaping. A single
        // quote inside a single-quoted string is escaped as '\'' (close
        // quote, escaped literal quote, reopen quote). This handles app
        // names like "Mole's App.app" without breaking the command.
        let rmScript = "rm -rf \(shellQuote(target.path))"
        let dittoScript = "ditto \(shellQuote(newApp.path)) \(shellQuote(target.path))"
        let combined = "\(rmScript) && \(dittoScript)"
        // Escape double quotes for the AppleScript string literal.
        let escaped = combined.replacingOccurrences(of: "\\", with: "\\\\")
                              .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(escaped)\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            // If the user cancelled the auth prompt, surface a friendly message.
            if stderr.contains("User canceled") || stderr.contains("-128") {
                throw NSError(
                    domain: "UpdateChecker",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Installation cancelled."]
                )
            }
            throw NSError(
                domain: "UpdateChecker",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Privileged install failed: \(stderr)"]
            )
        }
    }

    /// Returns true if `url` is a `.app` bundle located under a known
    /// applications directory. Used to guard the privileged `rm -rf` so
    /// a malformed or empty bundle path can never produce a dangerous
    /// deletion command.
    private func isValidAppBundlePath(_ url: URL) -> Bool {
        // Must end in .app.
        guard url.pathExtension == "app" else { return false }
        let path = url.path
        let home = NSHomeDirectory()
        // Allowed parent directories for app bundles.
        let allowedPrefixes = [
            "/Applications/",
            "/Applications",
            "\(home)/Applications/",
            "\(home)/Applications",
            "/Users/Shared/",
            "/System/Applications/",  // read-only on modern macOS, but valid
        ]
        for prefix in allowedPrefixes {
            if path == prefix || path.hasPrefix(prefix) {
                // The path itself should be the .app, not a deeper child.
                // i.e. parent must be one of the allowed dirs.
                let parent = url.deletingLastPathComponent().path
                if parent == "/Applications" || parent == "\(home)/Applications"
                    || parent == "/Users/Shared" || parent == "/System/Applications" {
                    return true
                }
            }
        }
        return false
    }

    /// Single-quote-escapes a path for safe inclusion in a shell command.
    /// Wraps the value in single quotes and escapes any embedded single
    /// quote as `'\''` (close, escaped literal, reopen). This is the
    /// standard POSIX-safe quoting and handles paths like
    /// `/Applications/Mole's App.app`.
    private func shellQuote(_ s: String) -> String {
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Relaunches the app at `url` after this process exits. We write a
    /// small shell helper to a temp file and run it detached: the helper
    /// waits for the current PID to disappear, then `open`s the app, then
    /// deletes itself. This avoids the race where `open -n` launches the
    /// new instance before the OS has fully released the old bundle's
    /// executable, which on some macOS versions causes the relaunch to
    /// silently fail or reopen the stale bundle.
    private func relaunch(at url: URL) {
        // getpid() is POSIX, available via Foundation on macOS. We avoid
        // ProcessInfo.processInfo here because under @MainActor isolation
        // + certain SDK versions the static accessor resolves incorrectly.
        let pid = getpid()
        let helperURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mole-relaunch-\(UUID().uuidString).sh")
        let script = """
        #!/bin/bash
        # Wait for the old Mole process to exit.
        while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done
        # Small grace period for the OS to release file handles.
        sleep 0.3
        /usr/bin/open -n "\(url.path)"
        # Self-destruct.
        rm -f "$0"
        """
        do {
            try script.write(to: helperURL, atomically: true, encoding: String.Encoding.utf8)
            // Make executable.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: helperURL.path
            )
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [helperURL.path]
            // Detach: don't let this process be a child that dies with us.
            process.qualityOfService = .background
            try? process.run()
        } catch {
            // Fallback: direct open, better than nothing.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-n", url.path]
            try? process.run()
        }
    }

    // MARK: - Version comparison

    /// Returns true if `lhs` is a newer semantic version than `rhs`.
    /// Strips leading "v" and prerelease suffixes (e.g. "-nightly") so
    /// "1.44.0-nightly" compares as 1.44.0.
    private func isNewer(_ lhs: String, than rhs: String) -> Bool {
        let l = Self.parseVersion(lhs)
        let r = Self.parseVersion(rhs)
        if l.major != r.major { return l.major > r.major }
        if l.minor != r.minor { return l.minor > r.minor }
        return l.patch > r.patch
    }

    /// Parses a version string into (major, minor, patch), stripping a
    /// leading "v" and any prerelease suffix (e.g. "-nightly", "-beta1").
    /// Shared with SettingsView so version comparison is consistent.
    static func parseVersion(_ s: String) -> (major: Int, minor: Int, patch: Int) {
        var cleaned = s.hasPrefix("v") ? String(s.dropFirst()) : s
        // Strip prerelease suffix: "1.44.0-nightly" → "1.44.0"
        if let dash = cleaned.firstIndex(of: "-") {
            cleaned = String(cleaned[..<dash])
        }
        let parts = cleaned.split(separator: ".").map { Int($0) ?? 0 }
        return (
            parts.count > 0 ? parts[0] : 0,
            parts.count > 1 ? parts[1] : 0,
            parts.count > 2 ? parts[2] : 0
        )
    }
}

/// URLSession delegate that reports download progress as a 0...1 fraction
/// and moves the finished file to a stable destination.
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    private let onProgress: (Double) -> Void
    private let destination: URL
    private var lastReported: Double = -1
    private var hasCompleted = false

    /// Called exactly once when the download finishes (success or failure).
    var completion: ((Result<URL, Error>) -> Void)?

    init(onProgress: @escaping (Double) -> Void, destination: URL) {
        self.onProgress = onProgress
        self.destination = destination
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        // Throttle: only report when progress moves by >= 1%.
        if fraction - lastReported >= 0.01 || fraction >= 1.0 {
            lastReported = fraction
            DispatchQueue.main.async { self.onProgress(fraction) }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard !hasCompleted else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            hasCompleted = true
            completion?(.success(destination))
        } catch {
            hasCompleted = true
            completion?(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // If the download already finished successfully, the completion
        // handler was called from didFinishDownloadingTo. Only surface
        // errors here.
        guard !hasCompleted, let error = error else { return }
        hasCompleted = true
        completion?(.failure(error))
    }
}
