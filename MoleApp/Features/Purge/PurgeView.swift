import SwiftUI

struct PurgeView: View {
    @EnvironmentObject private var service: MoleService

    var body: some View {
        Group {
            if !service.isInstalled {
                CLIUnavailableView()
            } else {
                CleanupScreen(
                    title: "Purge Projects",
                    subtitle: "Reclaim space by purging build artifacts from your projects.",
                    systemImage: "shippingbox",
                    categories: [
                        ("node_modules", "JavaScript & Node dependency folders", "shippingbox"),
                        ("Build Directories", "target/, build/, dist/, out/", "hammer"),
                        ("Derived Data", "Xcode & Swift derived data", "cube"),
                        (".venv / venv", "Python virtual environments", "scope"),
                        ("Gradle / Maven", ".gradle, .m2 build caches", "tray.full"),
                        ("Go Build Cache", "Go build & module caches", "g.circle")
                    ],
                    previewHint: "Run a preview to discover how much space your project build artifacts are wasting."
                ) { onLine in
                    try await service.purgePreview(onLine: onLine)
                } run: { onLine in
                    try await service.purge(onLine: onLine)
                }
            }
        }
    }
}
