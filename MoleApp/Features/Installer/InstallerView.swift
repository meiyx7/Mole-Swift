import SwiftUI

struct InstallerView: View {
    @EnvironmentObject private var service: MoleService

    var body: some View {
        Group {
            if !service.isInstalled {
                CLIUnavailableView()
            } else {
                CleanupScreen(
                    title: "Installer Files",
                    subtitle: "Find and remove leftover installers, DMGs, PKGs and ISOs.",
                    systemImage: "shippingbox.fill",
                    categories: [
                        (".dmg Files", "Disk image installers in Downloads & Desktop", "opticaldiscdrive"),
                        (".pkg Files", "macOS package installers", "archivebox"),
                        (".iso Files", "Disc images and VM installers", "opticaldisc"),
                        ("Stale Archives", "Old .zip, .tar archives from installs", "doc.zipper"),
                        ("App Zips", "Downloaded app archives already extracted", "app"),
                        ("Cached Installers", "Brew & installer caches", "internaldrive")
                    ],
                    previewHint: "Run a preview to find installer files that are safe to delete and reclaim disk space."
                ) { onLine in
                    try await service.installerPreview(onLine: onLine)
                } run: { onLine in
                    try await service.installer(onLine: onLine)
                }
            }
        }
    }
}
