import SwiftUI

/// Visual rendering of a parsed preview summary.
///
/// Replaces the raw console dump with:
/// - A headline stat row (total space / items / categories)
/// - Grouped, collapsible sections per CLI category
/// - Per-entry rows with icon, label, and size badge
///
/// Used by Clean, Installer, Optimize, and Purge screens.
struct PreviewSummaryView: View {
    let summary: PreviewParser.Summary
    var loc: Localization

    /// Maps English CLI section names to localized display names and descriptions.
    private static let sectionInfo: [(en: String, zh: String, desc: String)] = [
        ("System",                  "系统清理",     "系统缓存、日志和诊断报告"),
        ("User essentials",         "用户基础缓存", "用户运行时文件和 Finder 元数据"),
        ("App caches",              "应用缓存",     "各应用的缓存与支持文件"),
        ("Browsers",                "浏览器",       "浏览器缓存、Cookie 和历史记录"),
        ("Cloud & Office",          "云与办公",     "iCloud、Office、Slack 等缓存"),
        ("Developer tools",         "开发工具",     "Xcode、npm、Docker 等开发缓存"),
        ("Applications",            "应用程序",     "已安装应用的缓存文件"),
        ("Virtualization",          "虚拟化",       "Docker、虚拟机磁盘和容器镜像"),
        ("Application Support",     "应用支持文件", "应用支持目录中的可重建数据"),
        ("App leftovers",           "应用残留",     "已卸载应用的残留文件"),
        ("Device backups & firmware", "设备备份与固件", "iOS 设备备份和固件缓存"),
        ("Time Machine",            "时间机器",     "Time Machine 备份快照"),
        ("Large files",             "大文件",       "长期未用的大文件"),
        ("System Data clues",       "系统数据",     "系统数据占用来源分析"),
        ("Project artifacts",       "项目产物",     "node_modules 等项目构建产物"),
        ("External volume",         "外部卷",       "外接磁盘上的缓存和垃圾文件"),
    ]

    private static let sectionLookup: [String: (zh: String, desc: String)] = {
        Dictionary(uniqueKeysWithValues: sectionInfo.map { ($0.en, ($0.zh, $0.desc)) })
    }()

    static func sectionDisplayName(_ name: String) -> String {
        sectionLookup[name]?.zh ?? name
    }

    static func sectionDescription(_ name: String) -> String? {
        sectionLookup[name]?.desc
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            statRow
            Divider()
            sectionsList
        }
    }

    // MARK: - Stat row

    @ViewBuilder
    private var statRow: some View {
        let space = summary.totalSpaceText ?? "—"
        let items = summary.totalItems ?? summary.entries.filter { $0.kind == .wouldClean }.count
        let cats = summary.totalCategories ?? groupedSections.count
        HStack(spacing: 12) {
            StatTile(title: loc.t("可回收空间", "Reclaimable"),
                     value: space,
                     systemImage: "arrow.down.circle.fill",
                     tone: .good)
            StatTile(title: loc.t("项目数", "Items"),
                     value: "\(items)",
                     systemImage: "doc.on.doc.fill",
                     tone: .neutral)
            StatTile(title: loc.t("类别", "Categories"),
                     value: "\(cats)",
                     systemImage: "square.grid.2x2.fill",
                     tone: .neutral)
        }
    }

    // MARK: - Sections

    private var groupedSections: [(name: String, entries: [PreviewParser.Entry])] {
        var order: [String] = []
        var groups: [String: [PreviewParser.Entry]] = [:]
        for entry in summary.entries {
            if groups[entry.section] == nil {
                groups[entry.section] = []
                order.append(entry.section)
            }
            groups[entry.section]?.append(entry)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    private var sectionsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(groupedSections, id: \.name) { section in
                sectionCard(name: section.name, entries: section.entries)
            }
        }
    }

    private func sectionCard(name: String, entries: [PreviewParser.Entry]) -> some View {
        let cleanable = entries.filter { $0.kind == .wouldClean }
        let sectionSize = aggregateSize(of: cleanable)
        let hasCleanable = !cleanable.isEmpty
        let displayName = Self.sectionDisplayName(name)
        let description = Self.sectionDescription(name)
        return Card(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: hasCleanable ? "sparkles" : "checkmark.seal")
                        .foregroundColor(hasCleanable ? Theme.accent : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(displayName).font(.system(size: 13, weight: .semibold))
                        if let description {
                            Text(description).font(.system(size: 10)).foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    if hasCleanable, let size = sectionSize {
                        Text(size).font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(Theme.color(for: .good))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Theme.color(for: .good).opacity(0.16), in: Capsule())
                    }
                }
                ForEach(entries) { entry in
                    entryRow(entry)
                }
            }
        }
    }

    private func entryRow(_ entry: PreviewParser.Entry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(for: entry.kind))
                .foregroundColor(color(for: entry.kind))
                .frame(width: 14, alignment: .center)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.label)
                    .font(.system(size: 12))
                    .foregroundColor(entry.kind == .nothing ? .secondary : .primary)
                if let detail = entry.detail {
                    Text(detail).font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 4)
            if let size = entry.sizeText, entry.kind == .wouldClean || entry.kind == .orphan {
                Text(size)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(Theme.color(for: .good))
            }
        }
        .padding(.vertical, 1)
    }

    // MARK: - Helpers

    private func icon(for kind: PreviewParser.Entry.Kind) -> String {
        switch kind {
        case .wouldClean: return "arrow.trash"
        case .nothing:    return "checkmark"
        case .skipped:    return "minus.circle"
        case .orphan:     return "exclamationmark.triangle"
        case .info:       return "info.circle"
        }
    }

    private func color(for kind: PreviewParser.Entry.Kind) -> Color {
        switch kind {
        case .wouldClean: return Theme.color(for: .good)
        case .nothing:    return .secondary
        case .skipped:    return .secondary
        case .orphan:     return Theme.color(for: .warn)
        case .info:       return .secondary
        }
    }

    /// Sum sizes within a section. Returns nil if none of the entries had a
    /// parseable size (so we don't show a misleading "0B").
    private func aggregateSize(of entries: [PreviewParser.Entry]) -> String? {
        var total: Double = 0
        var any = false
        for e in entries {
            if let s = e.sizeText, let bytes = parseSizeToBytes(s) {
                total += bytes
                any = true
            }
        }
        guard any else { return nil }
        return formatBytes(total)
    }

    private func parseSizeToBytes(_ s: String) -> Double? {
        let trimmed = s.trimmingCharacters(in: .whitespaces).uppercased()
        let patterns: [(String, Double)] = [
            ("KB", 1024), ("MB", 1024 * 1024), ("GB", 1024 * 1024 * 1024),
            ("B", 1)
        ]
        for (suffix, mult) in patterns {
            if trimmed.hasSuffix(suffix) {
                let numStr = trimmed.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
                if let n = Double(numStr) { return n * mult }
            }
        }
        return nil
    }

    private func formatBytes(_ bytes: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = bytes
        var i = 0
        while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
        if v >= 100 { return String(format: "%.0f%@", v, units[i]) }
        if v >= 10  { return String(format: "%.1f%@", v, units[i]) }
        return String(format: "%.2f%@", v, units[i])
    }
}
