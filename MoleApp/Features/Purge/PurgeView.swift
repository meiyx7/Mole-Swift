import SwiftUI

struct PurgeView: View {
    @EnvironmentObject private var service: MoleService
    @EnvironmentObject private var loc: Localization

    var body: some View {
        Group {
            if !service.isInstalled {
                CLIUnavailableView()
            } else {
                CleanupScreen(
                    title: loc.t("清理项目", "Purge Projects"),
                    subtitle: loc.t("通过清理项目构建产物来回收空间。", "Reclaim space by purging build artifacts from your projects."),
                    systemImage: "shippingbox",
                    categories: [
                        ("node_modules", loc.t("JavaScript 与 Node 依赖目录", "JavaScript & Node dependency folders"), "shippingbox"),
                        (loc.t("构建目录", "Build Directories"), loc.t("target/、build/、dist/、out/", "target/, build/, dist/, out/"), "hammer"),
                        ("Derived Data", loc.t("Xcode 与 Swift 派生数据", "Xcode & Swift derived data"), "cube"),
                        (".venv / venv", loc.t("Python 虚拟环境", "Python virtual environments"), "scope"),
                        ("Gradle / Maven", loc.t(".gradle、.m2 构建缓存", ".gradle, .m2 build caches"), "tray.full"),
                        (loc.t("Go 构建缓存", "Go Build Cache"), loc.t("Go 构建与模块缓存", "Go build & module caches"), "g.circle")
                    ],
                    previewHint: loc.t("运行预览以发现项目构建产物占用了多少空间。", "Run a preview to discover how much space your project build artifacts are wasting.")
                ) { onLine in
                    try await service.purgePreview(onLine: onLine)
                } run: { onLine in
                    try await service.purge(onLine: onLine)
                }
            }
        }
    }
}
