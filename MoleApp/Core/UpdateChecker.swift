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
        case done
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
        guard case .available(let version, _, _) = state else {
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

        // 5. Relaunch the new bundle and terminate this process.
        installState = .done
        relaunch(at: currentAppURL)
        // Give the relaunch a moment before we exit.
        try? await Task.sleep(nanoseconds: 300_000_000)
        exit(0)
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

        // Privileged replacement via ditto + rm, wrapped in osascript.
        // We delete the old bundle first (ditto can't merge into an
        // existing .app cleanly), then ditto the new one into place.
        let rmScript = "rm -rf '\(target.path)'"
        let dittoScript = "ditto '\(newApp.path)' '\(target.path)'"
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

    /// Launches the updated bundle at `url` and terminates this process.
    /// Uses `open` so the new instance gets a fresh launch context.
    private func relaunch(at url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", url.path]
        try? process.run()
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
