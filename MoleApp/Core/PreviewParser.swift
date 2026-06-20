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

            // Section header: `➤ Section Name` (clean) or `━━━ Section ━━━` (purge)
            if line.hasPrefix("➤") {
                currentSection = line.dropFirst().trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix("━━━") {
                let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "━ "))
                if !trimmed.isEmpty { currentSection = trimmed }
                continue
            }
            // purge: `Purge Project Artifacts` (no prefix)
            if line == "Purge Project Artifacts" {
                currentSection = "Purge"
                continue
            }

            // Trailing summary variants:
            // clean:   `Potential space: 94.6MB | Items: 13 | Categories: 5`
            // purge:   `Would free: 94.6MB | Items: 13 | Free: ...`
            //          `Space freed: 94.6MB | Items: 13 | Free: ...`
            if line.hasPrefix("Potential space:") {
                parseSummaryLine(line, space: &totalSpace, items: &totalItems, categories: &totalCategories)
                continue
            }
            if line.hasPrefix("Would free:") || line.hasPrefix("Space freed:") {
                parsePurgeSummaryLine(line, space: &totalSpace, items: &totalItems)
                continue
            }

            // Skip whitelist / header noise that isn't a real entry.
            if line.hasPrefix("↳") { continue }
            if line.contains("DRY RUN MODE") { continue }
            if line.hasPrefix("◎ System caches need sudo") { continue }
            if line.hasPrefix("⚙") { continue }
            if line.hasPrefix("✓ Whitelist") { continue }
            if line.hasPrefix("Clean Your Mac") { continue }
            if line.hasPrefix("Installers cleaned") { continue }
            if line.hasPrefix("Dry run complete") { continue }

            if let entry = parseEntry(line, section: currentSection) {
                entries.append(entry)
            }
        }

        DebugLog.log("PreviewParser: \(entries.count) entries, section=\(currentSection), space=\(totalSpace ?? "nil")")
        return Summary(entries: entries, totalSpaceText: totalSpace, totalItems: totalItems, totalCategories: totalCategories)
    }

    private static func parseEntry(_ line: String, section: String) -> Entry? {
        // `→ item · would clean`
        // `→ item, 92.2MB dry`
        // `→ item 3 items, 92.2MB dry`
        if line.hasPrefix("→") {
            let body = line.dropFirst().trimmingCharacters(in: .whitespaces)
            let (label, size, detail) = splitArrowLine(body)
            return Entry(section: section, label: label, sizeText: size, detail: detail, kind: .wouldClean)
        }

        // purge: `✓ [DRY RUN] path, SIZE`  or  `✓ path, SIZE`
        if line.hasPrefix("✓ [DRY RUN]") {
            let body = line.replacingOccurrences(of: "✓ [DRY RUN]", with: "").trimmingCharacters(in: .whitespaces)
            let (label, size) = splitCommaSize(body)
            return Entry(section: section.isEmpty ? "Purge" : section, label: label, sizeText: size, detail: nil, kind: .wouldClean)
        }

        // `✓ Nothing to clean` / `✓ Great! No installer files to clean` / `✓ No old project artifacts to clean`
        if line.contains("Nothing to clean") || line.contains("No installer files to clean") || line.contains("No old project artifacts to clean") || line.contains("No artifacts found to purge") {
            return Entry(section: section, label: line.trimmingCharacters(in: .whitespaces), sizeText: nil, detail: nil, kind: .nothing)
        }
        // `✓ <other info>` e.g. `✓ Trash · already empty`, `✓ Rust toolchains: 3 found`
        if line.hasPrefix("✓") {
            let label = line.dropFirst().trimmingCharacters(in: .whitespaces)
            // purge real-run: `✓ path, SIZE`
            if let commaIdx = label.lastIndex(of: ","), let size = parseTrailingSize(label) {
                let pathLabel = label[..<commaIdx].trimmingCharacters(in: .whitespaces)
                return Entry(section: section.isEmpty ? "Purge" : section, label: pathLabel, sizeText: size, detail: nil, kind: .wouldClean)
            }
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

        // `No old project artifacts to clean.` (plain, no icon)
        if line == "No old project artifacts to clean." {
            return Entry(section: section, label: line, sizeText: nil, detail: nil, kind: .nothing)
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

    /// Split `path, SIZE` (purge format) into (label, sizeText).
    private static func splitCommaSize(_ body: String) -> (String, String?) {
        if let commaRange = body.range(of: ", ", options: .backwards) {
            let candidate = body[commaRange.upperBound...]
            if isSizeText(String(candidate)) {
                let label = body[..<commaRange.lowerBound].trimmingCharacters(in: .whitespaces)
                return (label, String(candidate))
            }
        }
        return (body, nil)
    }

    /// Try to parse a trailing `, SIZE` from a `✓ path, SIZE` line.
    private static func parseTrailingSize(_ label: String) -> String? {
        guard let commaIdx = label.lastIndex(of: ",") else { return nil }
        let after = label[label.index(after: commaIdx)...].trimmingCharacters(in: .whitespaces)
        return isSizeText(after) ? after : nil
    }

    /// True if the string looks like a human-readable size (`92.2MB`, `418KB`, `1.2GB`).
    private static func isSizeText(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        let pattern = "^[0-9]+(\\.[0-9]+)?(B|KB|MB|GB|TB|PB)$"
        return trimmed.range(of: pattern, options: .regularExpression) != nil
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

    /// Parse `Would free: 94.6MB | Items: 13 | Free: ...` or
    /// `Space freed: 94.6MB | Items: 13 | Free: ...`.
    private static func parsePurgeSummaryLine(_ line: String, space: inout String?, items: inout Int?) {
        let parts = line.components(separatedBy: "|")
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Would free:") {
                space = trimmed.replacingOccurrences(of: "Would free:", with: "").trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Space freed:") {
                space = trimmed.replacingOccurrences(of: "Space freed:", with: "").trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Items:") {
                let n = trimmed.replacingOccurrences(of: "Items:", with: "").trimmingCharacters(in: .whitespaces)
                items = Int(n)
            }
        }
    }
}
