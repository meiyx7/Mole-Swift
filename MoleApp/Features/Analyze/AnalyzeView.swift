import SwiftUI

@MainActor
final class AnalyzeViewModel: ObservableObject {
    @Published var result: AnalyzeResult?
    @Published var pathStack: [String] = []
    @Published var isLoading = false
    @Published var error: String?

    private let service = MoleService()

    var currentPath: String { pathStack.last ?? "" }
    var isOverview: Bool { pathStack.isEmpty }

    func loadOverview() async {
        pathStack.removeAll()
        await fetch(path: nil)
    }

    func drill(into path: String) async {
        pathStack.append(path)
        await fetch(path: path)
    }

    func goBack() async {
        if !pathStack.isEmpty {
            pathStack.removeLast()
            await fetch(path: pathStack.isEmpty ? nil : currentPath)
        }
    }

    func refresh() async {
        await fetch(path: isOverview ? nil : currentPath)
    }

    private func fetch(path: String?) async {
        isLoading = true
        error = nil
        do {
            if let path {
                result = try await service.analyze(path: path)
            } else {
                result = try await service.analyzeOverview()
            }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}

struct AnalyzeView: View {
    @StateObject private var vm = AnalyzeViewModel()
    @EnvironmentObject private var service: MoleService
    @EnvironmentObject private var loc: Localization

    var body: some View {
        Group {
            if !service.isInstalled {
                CLIUnavailableView()
            } else if let result = vm.result {
                content(result)
            } else if vm.isLoading {
                LoadingView(title: loc.t("正在扫描磁盘占用…", "Scanning disk usage…"))
            } else if let error = vm.error {
                EmptyStateView(systemImage: "exclamationmark.triangle",
                               title: loc.t("扫描失败", "Scan failed"),
                               message: error,
                               action: (loc.t("重试", "Retry"), { Task { await vm.refresh() } }))
            } else {
                EmptyStateView(systemImage: "chart.pie",
                               title: loc.t("磁盘分析", "Disk Explorer"),
                               message: loc.t("可视化查看 Mac 上的空间占用。", "Visualise what's taking up space on your Mac."),
                               action: (loc.t("扫描主目录", "Scan Home folder"), { Task { await vm.loadOverview() } }))
            }
        }
        .featurePadding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .toolbar {
            if !vm.pathStack.isEmpty {
                ToolbarItem(placement: .navigation) {
                    Button { Task { await vm.goBack() } } label: {
                        Image(systemName: "chevron.left")
                    }
                    .help(loc.t("返回", "Back"))
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await vm.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help(loc.t("重新扫描", "Rescan"))
            }
        }
        .task { if vm.result == nil { await vm.loadOverview() } }
        .onReceive(NotificationCenter.default.publisher(for: .moleRefresh)) { _ in
            Task { await vm.refresh() }
        }
    }

    @ViewBuilder
    private func content(_ result: AnalyzeResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(result)
                summaryRow(result)
                entriesSection(result)
                if !result.largeFiles.isEmpty {
                    largeFilesSection(result.largeFiles, total: result.totalSize)
                }
            }
        }
    }

    private func header(_ result: AnalyzeResult) -> some View {
        FeatureHeader(
            title: loc.t("磁盘分析", "Disk Explorer"),
            subtitle: vm.isOverview
                ? loc.t("主目录概览", "Overview of your Home folder")
                : breadcrumb(result.path),
            systemImage: "chart.pie",
            trailing: AnyView(
                Text(loc.t("\(result.totalFiles > 0 ? "\(result.totalFiles) 项 · " : "")\(ByteFormatter.bytes(result.totalSize))", "\(result.totalFiles > 0 ? "\(result.totalFiles) items · " : "")\(ByteFormatter.bytes(result.totalSize))"))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.secondary)
            )
        )
    }

    private func breadcrumb(_ path: String) -> String {
        let home = NSHomeDirectory()
        var display = path
        if path.hasPrefix(home) {
            display = "~" + path.dropFirst(home.count)
        }
        return display
    }

    private func summaryRow(_ result: AnalyzeResult) -> some View {
        let cleanable = result.entries.filter { $0.cleanable }.reduce(Int64(0)) { $0 + $1.size }
        return HStack(spacing: 14) {
            StatTile(title: loc.t("总大小", "Total Size"), value: ByteFormatter.bytes(result.totalSize),
                     systemImage: "externaldrive", tone: .neutral)
            StatTile(title: loc.t("项目", "Items"), value: result.totalFiles > 0 ? "\(result.totalFiles)" : "\(result.entries.count)",
                     systemImage: "doc.on.doc", tone: .neutral)
            StatTile(title: loc.t("可清理", "Cleanable"), value: ByteFormatter.bytes(cleanable),
                     systemImage: "sparkles", tone: cleanable > 0 ? .good : .neutral)
            StatTile(title: loc.t("大文件", "Large Files"), value: "\(result.largeFiles.count)",
                     systemImage: "exclamationmark.triangle", tone: result.largeFiles.isEmpty ? .neutral : .warn)
        }
    }

    private func entriesSection(_ result: AnalyzeResult) -> some View {
        Card(padding: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(loc.t("明细", "Breakdown"))
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 6).padding(.bottom, 4)
                let max = result.entries.map { $0.size }.max() ?? 1
                ForEach(result.entries.sorted { $0.size > $1.size }) { entry in
                    entryRow(entry, max: max, total: result.totalSize)
                    if entry.id != result.entries.last?.id { Divider().padding(.horizontal, 6) }
                }
            }
        }
    }

    private func entryRow(_ entry: AnalyzeEntry, max: Int64, total: Int64) -> some View {
        let fraction = total > 0 ? Double(entry.size) / Double(total) * 100 : 0
        let width = max > 0 ? CGFloat(entry.size) / CGFloat(max) : 0
        let tone: StatusTone = entry.cleanable ? .good : (entry.insight ? .warn : .neutral)
        return Button {
            if entry.isDir { Task { await vm.drill(into: entry.path) } }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: entry.isDir ? "folder.fill" : "doc")
                    .foregroundColor(entry.isDir ? Theme.accent : .secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(entry.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        if entry.cleanable {
                            badge(loc.t("可清理", "Cleanable"), tone: .good)
                        } else if entry.insight {
                            badge(loc.t("洞察", "Insight"), tone: .warn)
                        }
                        Spacer()
                        Text(ByteFormatter.bytes(entry.size))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                        Text(ByteFormatter.percent(fraction))
                            .font(.system(size: 11, design: .rounded))
                            .foregroundColor(.secondary)
                            .frame(width: 48, alignment: .trailing)
                        if entry.isDir {
                            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundColor(Color.gray.opacity(0.5))
                        }
                    }
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.color(for: tone))
                            .frame(width: width * geo.size.width, height: 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 6)
                    if !entry.lastAccess.isEmpty {
                        Text(loc.t("最近访问 ", "Last access ") + entry.lastAccess)
                            .font(.system(size: 10, design: .rounded)).foregroundColor(Color.gray.opacity(0.5))
                    }
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func badge(_ text: String, tone: StatusTone) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .textCase(.uppercase)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Theme.color(for: tone).opacity(0.18), in: Capsule())
            .foregroundColor(Theme.color(for: tone))
    }

    private func largeFilesSection(_ files: [AnalyzeFileEntry], total: Int64) -> some View {
        Card(padding: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label(loc.t("大文件", "Large Files"), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(loc.t("占用最高的文件", "Top space hogs")).font(.system(size: 10)).foregroundColor(.secondary)
                }
                .padding(.horizontal, 6).padding(.bottom, 4)
                let max = files.map { $0.size }.max() ?? 1
                ForEach(files.prefix(12)) { file in
                    HStack(spacing: 12) {
                        Image(systemName: "doc.fill").foregroundColor(.orange).frame(width: 18)
                        Text(file.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.orange.opacity(0.7))
                                .frame(width: CGFloat(file.size) / CGFloat(max) * geo.size.width, height: 5)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }.frame(width: 120, height: 5)
                        Text(ByteFormatter.bytes(file.size))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .frame(width: 80, alignment: .trailing)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 4)
                }
            }
        }
    }
}
