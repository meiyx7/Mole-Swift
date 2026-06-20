import SwiftUI

struct OptimizeView: View {
    @EnvironmentObject private var service: MoleService
    @EnvironmentObject private var loc: Localization

    var body: some View {
        if !service.isInstalled {
            CLIUnavailableView()
        } else {
            CleanupScreen(
                title: loc.t("优化", "Optimize"),
                subtitle: loc.t("刷新缓存、重建系统数据库并重置服务。", "Refresh caches, rebuild system databases, and reset services."),
                systemImage: "wand.and.stars",
                categories: [
                    (loc.t("重建数据库", "Rebuild Databases"), loc.t("重建 locate、whatis 及系统数据库", "Rebuild locate, whatis & system databases"), "cylinder.split"),
                    (loc.t("重置网络", "Reset Network"), loc.t("刷新 DNS 并重置网络配置", "Flush DNS and reset network configuration"), "network"),
                    (loc.t("刷新界面", "Refresh UI"), loc.t("重启 Finder、Dock 并重建 LaunchServices", "Restart Finder, Dock & rebuild LaunchServices"), "rectangle.stack"),
                    (loc.t("重建 Spotlight 索引", "Reindex Spotlight"), loc.t("重建 Spotlight 元数据索引", "Rebuild Spotlight metadata index"), "magnifyingglass"),
                    (loc.t("清理崩溃日志", "Clean Crash Logs"), loc.t("移除崩溃与诊断报告", "Remove crash & diagnostic reports"), "ladybug"),
                    (loc.t("清理交换空间", "Purge Swap"), loc.t("刷新非活动内存和交换文件", "Flush inactive memory and swap files"), "arrow.triangle.2.circlepath")
                ],
                previewHint: loc.t("运行预览以查看 Mole 将执行哪些优化步骤 — 暂不会做任何更改。", "Run a preview to see which optimization steps Mole would perform — nothing is changed yet.")
            ) { onLine in
                try await service.optimizePreview(onLine: onLine)
            } run: { onLine in
                try await service.optimize(onLine: onLine)
            }
        }
    }
}
