import Foundation
import SwiftUI

/// Checks GitHub releases for a newer version of the MoleApp GUI.
///
/// The app is distributed as `Mole-macOS-universal.zip` attached to
/// GitHub releases tagged `v*`. This class fetches the latest release
/// via the GitHub API, compares semantic versions, and exposes the
/// result as `@Published` state for SwiftUI views.
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

    @Published var state: CheckState = .idle

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
                let zipURL = release.assets.first { $0.name.hasSuffix(".zip") }?.downloadURL
                state = .available(
                    version: release.version,
                    url: zipURL ?? release.htmlURL,
                    notes: release.body
                )
            } else {
                state = .upToDate
            }
        } catch {
            state = .error(error.localizedDescription)
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
