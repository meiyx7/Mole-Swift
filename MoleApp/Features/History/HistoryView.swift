import SwiftUI

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published var result: HistoryResult?
    @Published var isLoading = false
    @Published var error: String?
    @Published var expanded: Set<String> = []

    private let service = MoleService()

    func load() async {
        isLoading = true
        error = nil
        do {
            result = try await service.history(limit: 100)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) }
        else { expanded.insert(id) }
    }
}

struct HistoryView: View {
    @EnvironmentObject private var service: MoleService
    @EnvironmentObject private var loc: Localization
    @StateObject private var vm = HistoryViewModel()

    var body: some View {
        Group {
            if !service.isInstalled {
                CLIUnavailableView()
            } else if let result = vm.result {
                content(result)
            } else if vm.isLoading {
                LoadingView(title: loc.t("正在加载清理历史…", "Loading cleanup history…"))
            } else if let error = vm.error {
                EmptyStateView(systemImage: "exclamationmark.triangle",
                               title: loc.t("无法加载历史记录", "Couldn't load history"),
                               message: error,
                               action: (loc.t("重试", "Retry"), { Task { await vm.load() } }))
            } else {
                EmptyStateView(systemImage: "clock.arrow.circlepath",
                               title: loc.t("清理历史", "Cleanup History"),
                               message: loc.t("查看 Mole 历次清理的完整记录。", "Review everything Mole has cleaned over time."),
                               action: (loc.t("加载历史", "Load history"), { Task { await vm.load() } }))
            }
        }
        .featurePadding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await vm.load() } } label: { Image(systemName: "arrow.clockwise") }
                    .help(loc.t("刷新历史", "Refresh history"))
            }
        }
        .task { if vm.result == nil { await vm.load() } }
        .onReceive(NotificationCenter.default.publisher(for: .moleRefresh)) { _ in
            Task { await vm.load() }
        }
    }

    @ViewBuilder
    private func content(_ result: HistoryResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if result.sessions.isEmpty && result.deletions.isEmpty {
                    EmptyStateView(systemImage: "tray",
                                   title: loc.t("暂无历史", "No history yet"),
                                   message: loc.t("运行一次清理后，记录会出现在这里。", "Once you run a cleanup, it will appear here."))
                } else {
                    summaryRow(result)
                    if !result.sessions.isEmpty {
                        sessionsList(result.sessions)
                    }
                    if !result.deletions.isEmpty {
                        deletionsList(result.deletions)
                    }
                    logsRow(result.logs)
                }
            }
        }
    }

    private var header: some View {
        FeatureHeader(
            title: loc.t("历史记录", "History"),
            subtitle: loc.t("Mole 执行过的每一次清理的完整日志。", "A complete log of every cleanup Mole has performed."),
            systemImage: "clock.arrow.circlepath"
        )
    }

    private func summaryRow(_ result: HistoryResult) -> some View {
        let reclaimed: Int64 = result.deletions.compactMap { $0.bytes }.reduce(0, +)
        let deletedCount = result.deletions.filter { $0.status.lowercased() == "removed" || $0.status.lowercased() == "trashed" }.count
        return HStack(spacing: 14) {
            StatTile(title: loc.t("会话", "Sessions"), value: "\(result.sessions.count)",
                     systemImage: "clock", tone: .neutral)
            StatTile(title: loc.t("已删除项", "Items Deleted"), value: "\(deletedCount)",
                     systemImage: "trash", tone: .good)
            StatTile(title: loc.t("回收空间", "Space Reclaimed"), value: ByteFormatter.bytes(reclaimed),
                     systemImage: "arrow.down.circle", tone: .good)
        }
    }

    private func sessionsList(_ sessions: [HistorySession]) -> some View {
        Card(padding: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(loc.t("最近会话", "Recent Sessions"))
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 8).padding(.bottom, 4)
                VStack(spacing: 0) {
                    ForEach(sessions) { session in
                        sessionRow(session)
                        if session.id != sessions.last?.id { Divider() }
                    }
                }
            }
        }
    }

    private func sessionRow(_ session: HistorySession) -> some View {
        let isExpanded = vm.expanded.contains(session.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button { vm.toggle(session.id) } label: {
                HStack(spacing: 12) {
                    Image(systemName: commandIcon(session.command))
                        .foregroundColor(Theme.accent).frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.command.capitalized)
                            .font(.system(size: 13, weight: .semibold))
                        Text(session.startedAt)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(loc.t("\(session.items) 项", "\(session.items) items"))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                        Text(session.size)
                            .font(.system(size: 11, design: .rounded))
                            .foregroundColor(.green)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10)).foregroundColor(Color.gray.opacity(0.5))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 10).padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    if session.endedAt.isEmpty {
                        infoLine(loc.t("结束时间", "Ended"), loc.t("未结束", "not ended"))
                    } else {
                        infoLine(loc.t("结束时间", "Ended"), session.endedAt)
                    }
                    infoLine(loc.t("操作次数", "Operations"), "\(session.operationCount)")
                    actionChips(session.actions)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.3))
            }
        }
    }

    private func infoLine(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 10)).foregroundColor(.secondary)
            Spacer()
            Text(value).font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
        }
    }

    private func actionChips(_ actions: HistoryActions) -> some View {
        let items: [(String, Int, StatusTone)] = [
            (loc.t("已删除", "removed"), actions.removed, .good),
            (loc.t("已回收", "trashed"), actions.trashed, .good),
            (loc.t("已跳过", "skipped"), actions.skipped, .neutral),
            (loc.t("失败", "failed"), actions.failed, .critical),
            (loc.t("已重建", "rebuilt"), actions.rebuilt, .warn),
            (loc.t("其他", "other"), actions.other, .neutral)
        ]
        return FlowChips(items: items.filter { $0.1 > 0 })
    }

    private func deletionsList(_ deletions: [HistoryDeletion]) -> some View {
        Card(padding: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(loc.t("删除审计", "Deletion Audit"))
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(deletions.count)").font(.system(size: 11, design: .rounded)).foregroundColor(.secondary)
                }
                .padding(.horizontal, 8).padding(.bottom, 4)
                VStack(spacing: 0) {
                    ForEach(deletions.prefix(60)) { del in
                        deletionRow(del)
                        if del.id != deletions.prefix(60).last?.id { Divider() }
                    }
                    if deletions.count > 60 {
                        Text(loc.t("…还有 \(deletions.count - 60) 条", "…and \(deletions.count - 60) more"))
                            .font(.system(size: 10)).foregroundColor(Color.gray.opacity(0.5))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                    }
                }
            }
        }
    }

    private func deletionRow(_ del: HistoryDeletion) -> some View {
        HStack(spacing: 10) {
            Image(systemName: statusIcon(del.status))
                .foregroundColor(statusTone(del.status) == .critical ? .red : Theme.accent)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(del.path)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                Text("\(del.timestamp) · \(del.mode) · \(del.status)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Spacer()
            if let bytes = del.bytes, bytes > 0 {
                Text(ByteFormatter.bytes(bytes))
                    .font(.system(size: 10, design: .rounded))
                    .foregroundColor(Color.gray.opacity(0.6))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
    }

    private func logsRow(_ logs: HistoryLogs) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Text(loc.t("日志文件", "Log Files")).font(.system(size: 13, weight: .semibold))
                logPath(loc.t("操作日志", "operations"), logs.operations)
                logPath(loc.t("删除日志", "deletions"), logs.deletions)
            }
        }
    }

    private func logPath(_ label: String, _ path: String) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundColor(.secondary)
            Spacer()
            Text(path)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    private func commandIcon(_ command: String) -> String {
        switch command.lowercased() {
        case "clean": return "sparkles"
        case "uninstall": return "trash.slash"
        case "optimize": return "wand.and.stars"
        case "purge": return "shippingbox"
        case "installer": return "shippingbox.fill"
        default: return "clock"
        }
    }

    private func statusIcon(_ status: String) -> String {
        switch status.lowercased() {
        case let s where s.contains("fail"): return "xmark.circle"
        case let s where s.contains("skip"): return "minus.circle"
        default: return "checkmark.circle"
        }
    }

    private func statusTone(_ status: String) -> StatusTone {
        switch status.lowercased() {
        case let s where s.contains("fail"): return .critical
        case let s where s.contains("skip"): return .neutral
        default: return .good
        }
    }
}

/// A simple wrapping row of tone-coloured chips used for action counts.
struct FlowChips: View {
    let items: [(String, Int, StatusTone)]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(items.indices, id: \.self) { i in
                let item = items[i]
                Text("\(item.0) \(item.1)")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Theme.color(for: item.2).opacity(0.18), in: Capsule())
                    .foregroundColor(Theme.color(for: item.2))
            }
        }
    }
}
