import SwiftUI

/// Deep cleanup screen. Delegates to `CleanupScreen` (shared with Optimize,
/// Purge, Installer) so the preview → confirm → run lifecycle, visual
/// preview, and result banner stay consistent across all cleanup features.
struct CleanView: View {
    @EnvironmentObject private var service: MoleService
    @EnvironmentObject private var loc: Localization

    var body: some View {
        if !service.isInstalled {
            CLIUnavailableView()
        } else {
            CleanupScreen(
                title: loc.t("清理", "Clean"),
                subtitle: loc.t("深度清理 Mac 上的缓存、日志、残留文件和垃圾。", "Deep cleanup of caches, logs, leftovers and junk across your Mac."),
                systemImage: "sparkles",
                categories: [
                    (loc.t("系统", "System"), loc.t("系统缓存、日志、本地快照", "System caches, logs, local snapshots"), "gearshape"),
                    (loc.t("用户基础", "User Essentials"), loc.t("用户缓存、Finder 元数据", "User caches, Finder metadata"), "person.crop"),
                    (loc.t("应用缓存", "App Caches"), loc.t("沙盒与标准应用的缓存", "Sandboxed & standard app caches"), "app.badge"),
                    (loc.t("浏览器", "Browsers"), loc.t("主流浏览器的 Cookie、缓存、历史记录", "Cookies, cache, history for major browsers"), "globe"),
                    (loc.t("云与办公", "Cloud & Office"), loc.t("iCloud、Office、Slack、Teams 缓存", "iCloud, Office, Slack, Teams caches"), "icloud"),
                    (loc.t("开发工具", "Developer Tools"), loc.t("Xcode DerivedData、模拟器、构建缓存", "Xcode DerivedData, simulators, build caches"), "hammer"),
                    (loc.t("应用程序", "Applications"), loc.t("GUI 应用的缓存与残留", "GUI app caches & leftovers"), "app"),
                    (loc.t("虚拟化", "Virtualization"), loc.t("Docker、虚拟机磁盘、容器镜像", "Docker, VM disks, container images"), "shippingbox"),
                    (loc.t("Application Support", "App Support Logs"), loc.t("应用支持目录中的日志文件", "Log files in Application Support"), "doc.text"),
                    (loc.t("应用残留", "App Leftovers"), loc.t("已卸载应用的残留、孤儿服务、容器桩", "Orphaned app data, services, container stubs"), "trash"),
                    (loc.t("Apple Silicon", "Apple Silicon Caches"), loc.t("Apple Silicon 架构专属缓存", "Apple Silicon architecture caches"), "cpu"),
                    (loc.t("设备备份与固件", "Device Backups & Firmware"), loc.t("iOS 备份、设备固件缓存", "iOS backups, device firmware caches"), "iphone"),
                    (loc.t("Time Machine", "Time Machine"), loc.t("失败的 Time Machine 备份", "Failed Time Machine backups"), "clock.arrow.circlepath"),
                    (loc.t("大文件", "Large Files"), loc.t("大文件候选检查", "Large file candidates"), "tray.full"),
                    (loc.t("系统数据线索", "System Data Clues"), loc.t("系统数据占用提示", "System data usage hints"), "info.circle"),
                    (loc.t("项目产物", "Project Artifacts"), loc.t("各项目的 node_modules、构建目录", "node_modules, build dirs across projects"), "folder.badge.gearshape")
                ],
                previewHint: loc.t("运行扫描以查看 Mole 将精确删除的内容 — 安全且不会做任何更改。", "Run a scan to see exactly what Mole would remove — safely, with no changes made."),
                preview: { onLine in try await service.cleanPreview(onLine: onLine) },
                run: { onLine in try await service.clean(onLine: onLine) },
                confirmTitle: loc.t("运行深度清理？", "Run deep cleanup?"),
                confirmMessage: loc.t(
                    "Mole 将永久删除扫描中识别的缓存和垃圾文件，此操作不可撤销。系统级项目需要活动的 sudo 会话。",
                    "Mole will permanently delete the caches and junk identified in the scan. This cannot be undone. System-level items require an active sudo session."
                ),
                actionLabel: loc.t("清理", "Clean")
            )
        }
    }
}
