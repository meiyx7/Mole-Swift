import SwiftUI

struct OptimizeView: View {
    @EnvironmentObject private var service: MoleService

    var body: some View {
        Group {
            if !service.isInstalled {
                CLIUnavailableView()
            } else {
                CleanupScreen(
                    title: "Optimize",
                    subtitle: "Refresh caches, rebuild system databases, and reset services.",
                    systemImage: "wand.and.stars",
                    categories: [
                        ("Rebuild Databases", "Rebuild locate, whatis & system databases", "cylinder.split"),
                        ("Reset Network", "Flush DNS and reset network configuration", "network"),
                        ("Refresh UI", "Restart Finder, Dock & rebuild LaunchServices", "rectangle.stack"),
                        ("Reindex Spotlight", "Rebuild Spotlight metadata index", "magnifyingglass"),
                        ("Clean Crash Logs", "Remove crash & diagnostic reports", "ladybug"),
                        ("Purge Swap", "Flush inactive memory and swap files", "arrow.triangle.2.circlepath")
                    ],
                    previewHint: "Run a preview to see which optimization steps Mole would perform — nothing is changed yet."
                ) { onLine in
                    try await service.optimizePreview(onLine: onLine)
                } run: { onLine in
                    try await service.optimize(onLine: onLine)
                }
            }
        }
    }
}
