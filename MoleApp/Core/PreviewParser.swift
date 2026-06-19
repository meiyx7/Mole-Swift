import Foundation

/// Parses the streaming text output of `mo clean --dry-run` (and the other
/// preview-style commands) into a structured, renderable summary.
///
/// The CLI output follows a stable shape:
///
/// ```
/// ➤ Section Name
///   → item · would clean
///   → item, 92.2MB dry
///   → item 3 items, 92.2MB dry
///   ✓ Nothing to clean
///   ◎ Skipped: reason
///   • Potential orphan dotfile: ~/.name (8KB)
/// ```
///
/// plus a trailing summary line:
/// `Potential space: 94.6MB | Items: 13 | Categories: 5`
struct PreviewParser {
    /// One parsed preview entry. `sizeText` is the raw human-readable size
    /// string from the CLI (e.g. "92.2MB", "418KB"); nil when the line had no
    /// size information.
    struct Entry: Identifiable, Hashable {
        let id = UUID()
        let section: String
        let label: String
        let sizeText: String?
        let detail: String?
        let kind: Kind

        enum Kind {
            case wouldClean   // `→ ... would clean` or `→ ..., SIZE dry`
            case nothing      // `✓ Nothing to clean`
            case skipped      // `◎ Skipped: ...`
            case orphan       // `• Potential orphan ...`
            case info         // `✓ <other info>`
        }
    }

    struct Summary: Hashable {
        var entries: [Entry]
        var totalSpaceText: String?
        var totalItems: Int?
        var totalCategories: Int?
    }

    /// Parse a full buffer of output lines into a summary. Safe to call
    /// repeatedly as new lines arrive.
    static func parse(_ lines: [String]) -> Summary {
        var entries: [Entry] = []
        var currentSection = ""
        var totalSpace: String?
        var totalItems: Int?
        var totalCategories: Int?

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            // Section header: `➤ Section Name`
            if line.hasPrefix("➤") {
                currentSection = line.dropFirst().trimmingCharacters(in: .whitespaces)
                continue
            }

            // Trailing summary: `Potential space: 94.6MB | Items: 13 | Categories: 5`
            if line.hasPrefix("Potential space:") {
                parseSummaryLine(line, space: &totalSpace, items: &totalItems, categories: &totalCategories)
                continue
            }

            // Skip whitelist / header noise that isn't a real entry.
            if line.hasPrefix("↳") { continue }
            if line.contains("DRY RUN MODE") { continue }
            if line.hasPrefix("◎ System caches need sudo") { continue }
            if line.hasPrefix("⚙") { continue }
            if line.hasPrefix("✓ Whitelist") { continue }

            if let entry = parseEntry(line, section: currentSection) {
                entries.append(entry)
            }
        }

        return Summary(entries: entries, totalSpaceText: totalSpace, totalItems: totalItems, totalCategories: totalCategories)
    }

    private static func parseEntry(_ line: String, section: String) -> Entry? {
        // `→ item · would clean`
        // `→ item, 92.2MB dry`
        // `→ item 3 items, 92.2MB dry`
        // `→ npm cache directory 3 items, 92.2MB dry`
        if line.hasPrefix("→") {
            let body = line.dropFirst().trimmingCharacters(in: .whitespaces)
            let (label, size, detail) = splitArrowLine(body)
            return Entry(section: section, label: label, sizeText: size, detail: detail, kind: .wouldClean)
        }

        // `✓ Nothing to clean`
        if line.hasPrefix("✓ Nothing to clean") {
            return Entry(section: section, label: "Nothing to clean", sizeText: nil, detail: nil, kind: .nothing)
        }
        // `✓ <other info>` e.g. `✓ Trash · already empty`, `✓ Rust toolchains: 3 found`
        if line.hasPrefix("✓") {
            let label = line.dropFirst().trimmingCharacters(in: .whitespaces)
            return Entry(section: section, label: label, sizeText: nil, detail: nil, kind: .info)
        }

        // `◎ Skipped: reason`
        if line.hasPrefix("◎") {
            let label = line.dropFirst().trimmingCharacters(in: .whitespaces)
            return Entry(section: section, label: label, sizeText: nil, detail: nil, kind: .skipped)
        }

        // `• Potential orphan dotfile: ~/.name (8KB)`
        if line.hasPrefix("•") {
            let body = line.dropFirst().trimmingCharacters(in: .whitespaces)
            let size = extractSize(in: body)
            return Entry(section: section, label: body, sizeText: size, detail: nil, kind: .orphan)
        }

        // `☞ Review manually ...` — hint line, treat as info under current section.
        if line.hasPrefix("☞") {
            let label = line.dropFirst().trimmingCharacters(in: .whitespaces)
            return Entry(section: section, label: label, sizeText: nil, detail: nil, kind: .info)
        }

        return nil
    }

    /// Split a `→` body like `npm cache directory 3 items, 92.2MB dry` into
    /// (label, sizeText, detail).
    private static func splitArrowLine(_ body: String) -> (String, String?, String?) {
        // Strip a trailing `· would clean` marker.
        var work = body
        if work.hasSuffix("· would clean") {
            work = String(work.dropLast("· would clean".count)).trimmingCharacters(in: .whitespaces)
        }

        // Look for a trailing `, SIZE dry` or ` SIZE dry`.
        if let dryRange = work.range(of: ", ", options: .backwards) {
            let candidate = work[dryRange.upperBound...]
            if candidate.hasSuffix("dry") {
                let sizeText = String(candidate.dropLast(" dry".count)).trimmingCharacters(in: .whitespaces)
                let label = work[..<dryRange.lowerBound].trimmingCharacters(in: .whitespaces)
                return (label, sizeText, nil)
            }
        }

        return (work, nil, nil)
    }

    /// Extract a `(8KB)` style size from a line.
    private static func extractSize(in body: String) -> String? {
        guard let open = body.lastIndex(of: "("),
              let close = body.lastIndex(of: ")"),
              open < close else { return nil }
        return String(body[body.index(after: open)..<close])
    }

    private static func parseSummaryLine(_ line: String, space: inout String?, items: inout Int?, categories: inout Int?) {
        let parts = line.components(separatedBy: "|")
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Potential space:") {
                space = trimmed.replacingOccurrences(of: "Potential space:", with: "").trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Items:") {
                let n = trimmed.replacingOccurrences(of: "Items:", with: "").trimmingCharacters(in: .whitespaces)
                items = Int(n)
            } else if trimmed.hasPrefix("Categories:") {
                let n = trimmed.replacingOccurrences(of: "Categories:", with: "").trimmingCharacters(in: .whitespaces)
                categories = Int(n)
            }
        }
    }
}
