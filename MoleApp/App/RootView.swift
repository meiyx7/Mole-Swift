import SwiftUI

/// The root two-column layout: sidebar + detail.
struct RootView: View {
    @EnvironmentObject private var service: MoleService
    @EnvironmentObject private var loc: Localization
    @State private var selection: Feature = .status

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } detail: {
            detailView
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .status:    StatusView()
        case .analyze:   AnalyzeView()
        case .clean:     CleanView()
        case .uninstall: UninstallView()
        case .optimize:  OptimizeView()
        case .purge:     PurgeInteractiveView()
        case .purgeInteractive: PurgeInteractiveView()
        case .installer: InstallerView()
        case .history:   HistoryView()
        case .settings:  SettingsView()
        }
    }
}

/// Sidebar with grouped navigation and a footer showing CLI status.
struct SidebarView: View {
    @Binding var selection: Feature
    @EnvironmentObject private var service: MoleService
    @EnvironmentObject private var loc: Localization

    var body: some View {
        List(selection: $selection) {
            ForEach(FeatureSection.allCases) { section in
                Section(section.title(loc)) {
                    ForEach(section.features) { feature in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(feature.title(loc))
                                    .font(.system(size: 13, weight: .medium))
                                Text(feature.subtitle(loc))
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: feature.systemImage)
                                .foregroundColor(Theme.accent)
                                .frame(width: 22)
                        }
                        .tag(feature)
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            footer
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: service.isInstalled ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(service.isInstalled ? .green : .orange)
            VStack(alignment: .leading, spacing: 0) {
                Text(service.isInstalled
                     ? loc.t("Mole CLI 已连接", "Mole CLI connected")
                     : loc.t("未找到 Mole CLI", "Mole CLI not found"))
                    .font(.system(size: 11, weight: .semibold))
                Text(service.isInstalled
                     ? loc.t("已准备好管理你的 Mac", "Ready to manage your Mac")
                     : loc.t("通过 Homebrew 安装以开始", "Install via Homebrew to begin"))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(10)
    }
}
