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
                    // Core optimizations
                    (loc.t("DNS 与 Spotlight 检查", "DNS & Spotlight Check"), loc.t("刷新 DNS 缓存并验证 Spotlight 状态", "Refresh DNS cache & verify Spotlight status"), "network"),
                    (loc.t("Finder 缓存刷新", "Finder Cache Refresh"), loc.t("刷新 QuickLook 缩略图与图标服务缓存", "Refresh QuickLook thumbnails & icon services cache"), "rectangle.stack"),
                    (loc.t("应用状态清理", "App State Cleanup"), loc.t("移除 30 天以上的旧应用状态", "Remove old saved application states (30+ days)"), "clock.badge.checkmark"),
                    (loc.t("配置修复", "Broken Config Repair"), loc.t("修复损坏的偏好设置文件", "Fix corrupted preferences files"), "wrench.adjustable"),
                    (loc.t("网络缓存刷新", "Network Cache Refresh"), loc.t("优化 DNS 缓存并重启 mDNSResponder", "Optimize DNS cache & restart mDNSResponder"), "wifi"),
                    // Advanced optimizations
                    (loc.t("数据库优化", "Database Optimization"), loc.t("压缩 Mail、Safari、Messages 的 SQLite 数据库", "Compress SQLite databases for Mail, Safari & Messages"), "cylinder.split"),
                    (loc.t("LaunchServices 修复", "LaunchServices Repair"), loc.t("修复"打开方式"菜单与文件关联", "Repair \"Open with\" menu & file associations"), "list.bullet.rectangle"),
                    (loc.t("Dock 刷新", "Dock Refresh"), loc.t("修复 Dock 中损坏的图标和视觉故障", "Fix broken icons and visual glitches in the Dock"), "dock.arrow.up.rectangle"),
                    (loc.t("阻止 .DS_Store", "Prevent Finder .DS_Store"), loc.t("阻止 Finder 在网络和 USB 卷上写入 .DS_Store", "Stop Finder writing .DS_Store on network/USB volumes"), "nosign"),
                    // System performance
                    (loc.t("内存优化", "Memory Optimization"), loc.t("释放非活动内存以提升响应速度", "Release inactive memory to improve responsiveness"), "memorychip"),
                    (loc.t("网络栈刷新", "Network Stack Refresh"), loc.t("刷新路由表和 ARP 缓存", "Flush routing table and ARP cache"), "arrow.triangle.2.circlepath"),
                    (loc.t("权限修复", "Permission Repair"), loc.t("修复用户目录权限问题", "Fix user directory permission issues"), "lock.shield"),
                    (loc.t("Spotlight 优化", "Spotlight Optimization"), loc.t("搜索缓慢时重建索引（智能检测）", "Rebuild index if search is slow (smart detection)"), "magnifyingglass"),
                    (loc.t("Spotlight 孤儿规则", "Spotlight Orphan Rules"), loc.t("移除已卸载应用的 Spotlight 搜索规则", "Remove Spotlight rules for uninstalled apps"), "magnifyingglass.circle"),
                    (loc.t("定期维护", "Periodic Maintenance"), loc.t("运行 macOS 日/周/月维护脚本", "Run macOS daily/weekly/monthly maintenance scripts"), "calendar"),
                    (loc.t("共享文件列表", "Shared File Lists"), loc.t("修复损坏的 Finder 收藏和最近文档", "Repair corrupted Finder favorites and recent documents"), "folder"),
                    (loc.t("磁盘健康", "Disk Health"), loc.t("验证文件系统完整性", "Verify filesystem integrity"), "internaldrive"),
                    (loc.t("登录项", "Login Items"), loc.t("审计登录项中的损坏条目", "Audit login items for broken entries"), "person.crop.rectangle.badge.checkmark"),
                    // System database cleanup
                    (loc.t("隔离数据库清理", "Quarantine Database Cleanup"), loc.t("清除 Gatekeeper 下载跟踪历史", "Clear Gatekeeper download tracking history"), "shield.lefthalf.filled"),
                    (loc.t("Launch Agents 清理", "Launch Agents Cleanup"), loc.t("移除二进制文件已不存在的 LaunchAgents", "Remove broken LaunchAgents whose binaries no longer exist"), "ant"),
                    (loc.t("通知清理", "Notifications"), loc.t("清理旧通知以减少数据库膨胀", "Clean old delivered notifications to reduce database bloat"), "bell.badge"),
                    (loc.t("使用数据清理", "Usage Data"), loc.t("清理旧的使用跟踪数据", "Clean old usage tracking data"), "chart.bar")
                ],
                previewHint: loc.t("运行扫描以查看 Mole 将执行哪些优化步骤 — 暂不会做任何更改。", "Run a scan to see which optimization steps Mole would perform — nothing is changed yet.")
            ) { onLine in
                try await service.optimizePreview(onLine: onLine)
            } run: { onLine in
                try await service.optimize(onLine: onLine)
            }
        }
    }
}
