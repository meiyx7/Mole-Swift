import SwiftUI

/// Top-level destinations in the sidebar. One per CLI feature area.
enum Feature: String, CaseIterable, Identifiable, Hashable {
    case status
    case analyze
    case clean
    case uninstall
    case optimize
    case purge
    case purgeInteractive
    case installer
    case history
    case settings

    var id: String { rawValue }

    func title(_ loc: Localization) -> String {
        switch self {
        case .status: return loc.t("系统状态", "Status")
        case .analyze: return loc.t("磁盘分析", "Disk Explorer")
        case .clean: return loc.t("清理", "Clean")
        case .uninstall: return loc.t("卸载应用", "Uninstall Apps")
        case .optimize: return loc.t("优化", "Optimize")
        case .purge: return loc.t("清理项目", "Purge Projects")
        case .purgeInteractive: return loc.t("清理项目", "Purge Projects")
        case .installer: return loc.t("安装包", "Installer Files")
        case .history: return loc.t("历史记录", "History")
        case .settings: return loc.t("设置", "Settings")
        }
    }

    func subtitle(_ loc: Localization) -> String {
        switch self {
        case .status: return loc.t("实时系统健康", "Live system health")
        case .analyze: return loc.t("可视化磁盘占用", "Visual disk usage")
        case .clean: return loc.t("深度清理", "Deep cleanup")
        case .uninstall: return loc.t("移除应用程序", "Remove applications")
        case .optimize: return loc.t("刷新缓存与服务", "Refresh caches & services")
        case .purge: return loc.t("清理项目构建产物", "Clean project build artifacts")
        case .purgeInteractive: return loc.t("清理项目构建产物", "Clean project build artifacts")
        case .installer: return loc.t("查找残留安装包", "Find leftover installers")
        case .history: return loc.t("清理活动记录", "Cleanup activity")
        case .settings: return loc.t("语言、更新等", "Language, updates & more")
        }
    }

    var systemImage: String {
        switch self {
        case .status: return "heart.text.square"
        case .analyze: return "chart.pie"
        case .clean: return "sparkles"
        case .uninstall: return "trash.slash"
        case .optimize: return "wand.and.stars"
        case .purge: return "shippingbox"
        case .purgeInteractive: return "shippingbox.fill"
        case .installer: return "shippingbox.fill"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
}

/// Logical grouping used to render sidebar sections.
enum FeatureSection: String, CaseIterable, Identifiable {
    case overview
    case cleanup
    case management
    case system

    var id: String { rawValue }

    func title(_ loc: Localization) -> String {
        switch self {
        case .overview: return loc.t("概览", "Overview")
        case .cleanup: return loc.t("清理", "Cleanup")
        case .management: return loc.t("管理", "Management")
        case .system: return loc.t("系统", "System")
        }
    }

    var features: [Feature] {
        switch self {
        case .overview: return [.status, .analyze]
        case .cleanup: return [.clean, .optimize, .purgeInteractive, .installer]
        case .management: return [.uninstall, .history]
        case .system: return [.settings]
        }
    }
}
