import SwiftUI

@MainActor
final class AnalyzeViewModel: ObservableObject {
    @Published var result: AnalyzeResult?
    /// Stack of (displayName, fullPath) tuples for breadcrumb navigation.
    /// Each entry is a level the user has drilled into.
    @Published var pathStack: [(name: String, path: String)] = []
    @Published var isLoading = false
    @Published var error: String?
    
    /// Reference to localization for error messages.
    var loc: Localization?

    var currentPath: String { pathStack.last?.path ?? "" }
    var isOverview: Bool { pathStack.isEmpty }

    func loadOverview(service: MoleService) async {
        pathStack.removeAll()
        await fetch(service: service, path: nil)
    }

    func drill(service: MoleService, into path: String, name: String) async {
        // Prevent drilling while a scan is already running (avoids race
        // conditions where rapid clicks pile up breadcrumb entries).
        guard !isLoading else { return }
        // Prevent drilling into the same path (avoids duplicate breadcrumb entries).
        guard path != currentPath else { return }
        pathStack.append((name: name, path: path))
        await fetch(service: service, path: path)
    }

    func goBack(service: MoleService) async {
        if !pathStack.isEmpty {
            pathStack.removeLast()
            await fetch(service: service, path: pathStack.isEmpty ? nil : currentPath)
        }
    }

    /// Navigate to a specific level in the path stack (0 = overview).
    /// Removes everything after the given index.
    func navigate(service: MoleService, toLevel level: Int) async {
        guard !isLoading else { return }
        if level >= pathStack.count { return }
        if level == 0 {
            await loadOverview(service: service)
        } else {
            pathStack = Array(pathStack.prefix(level))
            await fetch(service: service, path: currentPath)
        }
    }

    func refresh(service: MoleService) async {
        await fetch(service: service, path: isOverview ? nil : currentPath)
    }

    private func fetch(service: MoleService, path: String?) async {
        isLoading = true
        error = nil
        do {
            if let path {
                result = try await service.analyze(path: path)
            } else {
                result = try await service.analyzeOverview()
            }
        } catch {
            // Provide a user-friendly message for timeout errors
            let nsError = error as NSError
            if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(SIGTERM) {
                self.error = loc.t("扫描超时，该目录可能过大。请尝试扫描更小的子目录。", 
                                   "Scan timed out. The directory may be too large. Try scanning a smaller subdirectory.")
            } else {
                self.error = error.localizedDescription
            }
            // Roll back the breadcrumb so the user isn't trapped in a
            // level that failed to load.
            if path != nil && !pathStack.isEmpty {
                pathStack.removeLast()
            }
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
                               action: (loc.t("重试", "Retry"), { Task { await vm.refresh(service: service) } }))
            } else {
                EmptyStateView(systemImage: "chart.pie",
                               title: loc.t("磁盘分析", "Disk Explorer"),
                               message: loc.t("可视化查看 Mac 上的空间占用。", "Visualise what's taking up space on your Mac."),
                               action: (loc.t("扫描主目录", "Scan Home folder"), { Task { await vm.loadOverview(service: service) } }))
            }
        }
        .featurePadding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .toolbar {
            if !vm.pathStack.isEmpty {
                ToolbarItem(placement: .navigation) {
                    Button { Task { await vm.goBack(service: service) } } label: {
                        Image(systemName: "chevron.left")
                    }
                    .help(loc.t("返回", "Back"))
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await vm.refresh(service: service) } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help(loc.t("重新扫描", "Rescan"))
            }
        }
        .task { 
            vm.loc = loc
            if vm.result == nil { await vm.loadOverview(service: service) } 
        }
        .onReceive(NotificationCenter.default.publisher(for: .moleRefresh)) { _ in
            Task { await vm.refresh(service: service) }
        }
    }

    @ViewBuilder
    private func content(_ result: AnalyzeResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(result)
                if vm.isLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(loc.t("正在加载子目录…", "Loading subdirectory…"))
                            .font(.system(size: 12)).foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                }
                if !vm.isOverview {
                    breadcrumbBar
                }
                summaryRow(result)
                entriesSection(result)
                if let largeFiles = result.largeFiles, !largeFiles.isEmpty {
                    largeFilesSection(largeFiles, total: result.totalSize)
                }
            }
        }
    }

    /// Clickable breadcrumb navigation bar. Each segment navigates to
    /// that directory level. The last segment (current dir) is not clickable.
    private var breadcrumbBar: some View {
        HStack(spacing: 4) {
            // Home / Overview button
            Button {
                Task { await vm.navigate(service: service, toLevel: 0) }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "house.fill")
                        .font(.system(size: 10))
                    Text(loc.t("主目录", "Home"))
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(Theme.accent)
            }
            .buttonStyle(.plain)

            ForEach(vm.pathStack.indices, id: \.self) { i in
                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                let isLast = i == vm.pathStack.count - 1
                let name = vm.pathStack[i].name
                if isLast {
                    Text(name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Button {
                        Task { await vm.navigate(service: service, toLevel: i + 1) }
                    } label: {
                        Text(name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Theme.accent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private func header(_ result: AnalyzeResult) -> some View {
        FeatureHeader(
            title: loc.t("磁盘分析", "Disk Explorer"),
            subtitle: vm.isOverview
                ? loc.t("主目录概览", "Overview of your Home folder")
                : loc.t("子目录分析", "Subdirectory analysis"),
            systemImage: "chart.pie",
            trailing: AnyView(
                Text(loc.t("\((result.totalFiles ?? 0) > 0 ? "\(result.totalFiles!) 项 · " : "")\(ByteFormatter.bytes(result.totalSize))", "\((result.totalFiles ?? 0) > 0 ? "\(result.totalFiles!) items · " : "")\(ByteFormatter.bytes(result.totalSize))"))
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
        let cleanable = result.entries.filter { $0.cleanable ?? false }.reduce(Int64(0)) { $0 + $1.size }
        return HStack(spacing: 14) {
            StatTile(title: loc.t("总大小", "Total Size"), value: ByteFormatter.bytes(result.totalSize),
                     systemImage: "externaldrive", tone: .neutral)
            StatTile(title: loc.t("项目", "Items"), value: (result.totalFiles ?? 0) > 0 ? "\(result.totalFiles!)" : "\(result.entries.count)",
                     systemImage: "doc.on.doc", tone: .neutral)
            StatTile(title: loc.t("可清理", "Cleanable"), value: ByteFormatter.bytes(cleanable),
                     systemImage: "sparkles", tone: cleanable > 0 ? .good : .neutral)
            StatTile(title: loc.t("大文件", "Large Files"), value: "\(result.largeFiles?.count ?? 0)",
                     systemImage: "exclamationmark.triangle", tone: (result.largeFiles?.isEmpty ?? true) ? .neutral : .warn)
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
        let tone: StatusTone = (entry.cleanable ?? false) ? .good : ((entry.insight ?? false) ? .warn : .neutral)
        return Button {
            if entry.isDir && !vm.isLoading { Task { await vm.drill(service: service, into: entry.path, name: entry.name) } }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: entry.isDir ? "folder.fill" : "doc")
                    .foregroundColor(entry.isDir ? Theme.accent : .secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(entry.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        if entry.cleanable ?? false {
                            badge(loc.t("可清理", "Cleanable"), tone: .good)
                        } else if entry.insight ?? false {
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
                    if let lastAccess = entry.lastAccess, !lastAccess.isEmpty {
                        Text(loc.t("最近访问 ", "Last access ") + lastAccess)
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
