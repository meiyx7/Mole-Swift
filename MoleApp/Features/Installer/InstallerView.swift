import SwiftUI

struct InstallerView: View {
    @EnvironmentObject private var service: MoleService
    @EnvironmentObject private var loc: Localization

    var body: some View {
        Group {
            if !service.isInstalled {
                CLIUnavailableView()
            } else {
                CleanupScreen(
                    title: loc.t("安装包文件", "Installer Files"),
                    subtitle: loc.t("查找并删除残留的安装包、DMG、PKG 和 ISO 文件。", "Find and remove leftover installers, DMGs, PKGs and ISOs."),
                    systemImage: "shippingbox.fill",
                    categories: [
                        (loc.t(".dmg 文件", ".dmg Files"), loc.t("下载与桌面目录中的磁盘镜像安装包", "Disk image installers in Downloads & Desktop"), "opticaldiscdrive"),
                        (loc.t(".pkg 文件", ".pkg Files"), loc.t("macOS 安装包", "macOS package installers"), "archivebox"),
                        (loc.t(".iso 文件", ".iso Files"), loc.t("光盘镜像与虚拟机安装包", "Disc images and VM installers"), "opticaldisc"),
                        (loc.t("过期压缩包", "Stale Archives"), loc.t("安装产生的旧 .zip、.tar 压缩包", "Old .zip, .tar archives from installs"), "doc.zipper"),
                        (loc.t("应用压缩包", "App Zips"), loc.t("已解压的下载应用压缩包", "Downloaded app archives already extracted"), "app"),
                        (loc.t("缓存的安装包", "Cached Installers"), loc.t("Brew 与安装包缓存", "Brew & installer caches"), "internaldrive")
                    ],
                    previewHint: loc.t("运行预览以找到可安全删除的安装包文件并回收磁盘空间。", "Run a preview to find installer files that are safe to delete and reclaim disk space.")
                ) { onLine in
                    try await service.installerPreview(onLine: onLine)
                } run: { onLine in
                    try await service.installer(onLine: onLine)
                }
            }
        }
    }
}
