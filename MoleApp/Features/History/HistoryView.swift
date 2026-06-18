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
    @StateObject private var vm = HistoryViewModel()

    var body: some View {
        Group {
            if !service.isInstalled {
                CLIUnavailableView()
            } else if let result = vm.result {
                content(result)
            } else if vm.isLoading {
                LoadingView(title: "Loading cleanup history…")
            } else if let error = vm.error {
                EmptyStateView(systemImage: "exclamationmark.triangle",
                               title: "Couldn't load history",
                               message: error,
                               action: ("Retry", { Task { await vm.load() } }))
            } else {
                EmptyStateView(systemImage: "clock.arrow.circlepath",
                               title: "Cleanup History",
                               message: "Review everything Mole has cleaned over time.",
                               action: ("Load history", { Task { await vm.load() } }))
            }
        }
        .featurePadding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await vm.load() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh history")
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
                if result.sessions.isEmpty {
                    EmptyStateView(systemImage: "tray",
                                   title: "No history yet",
                                   message: "Once you run a cleanup, it will appear here.")
                } else {
                    summaryRow(result)
                    sessionsList(result.sessions)
                }
            }
        }
    }

    private var header: some View {
        FeatureHeader(
            title: "History",
            subtitle: "A complete log of every cleanup Mole has performed.",
            systemImage: "clock.arrow.circlepath"
        )
    }

    private func summaryRow(_ result: HistoryResult) -> some View {
        HStack(spacing: 14) {
            StatTile(title: "Sessions", value: "\(result.totalSessions)",
                     systemImage: "clock", tone: .neutral)
            StatTile(title: "Items Deleted", value: "\(result.totalDeleted)",
                     systemImage: "trash", tone: .good)
            StatTile(title: "Space Reclaimed", value: ByteFormatter.bytes(result.totalReclaimed),
                     systemImage: "arrow.down.circle", tone: .good)
        }
    }

    private func sessionsList(_ sessions: [HistorySession]) -> some View {
        Card(padding: 8) {
            VStack(spacing: 0) {
                ForEach(sessions) { session in
                    sessionRow(session)
                    if session.id != sessions.last?.id { Divider() }
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
                        Text(session.timestamp)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if session.dryRun {
                        Text("DRY-RUN")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.gray.opacity(0.2), in: Capsule())
                            .foregroundColor(.secondary)
                    }
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(session.itemsDeleted) items")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                        Text(ByteFormatter.bytes(session.sizeReclaimed))
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

            if isExpanded && !session.deletions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(session.deletions.prefix(40)) { del in
                        HStack {
                            Image(systemName: "doc").font(.system(size: 9)).foregroundColor(Color.gray.opacity(0.5))
                            Text(del.path)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if del.size > 0 {
                                Text(ByteFormatter.bytes(del.size))
                                    .font(.system(size: 10, design: .rounded))
                                    .foregroundColor(Color.gray.opacity(0.5))
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 3)
                    }
                    if session.deletions.count > 40 {
                        Text("…and \(session.deletions.count - 40) more")
                            .font(.system(size: 10)).foregroundColor(Color.gray.opacity(0.5))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                    }
                }
                .padding(.vertical, 6)
                .background(.quaternary.opacity(0.3))
            }
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
}
