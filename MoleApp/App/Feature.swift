import SwiftUI

/// Top-level destinations in the sidebar. One per CLI feature area.
enum Feature: String, CaseIterable, Identifiable, Hashable {
    case status
    case analyze
    case clean
    case uninstall
    case optimize
    case purge
    case installer
    case history
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .status: return "Status"
        case .analyze: return "Disk Explorer"
        case .clean: return "Clean"
        case .uninstall: return "Uninstall Apps"
        case .optimize: return "Optimize"
        case .purge: return "Purge Projects"
        case .installer: return "Installer Files"
        case .history: return "History"
        case .settings: return "Settings"
        }
    }

    var subtitle: String {
        switch self {
        case .status: return "Live system health"
        case .analyze: return "Visual disk usage"
        case .clean: return "Deep cleanup"
        case .uninstall: return "Remove applications"
        case .optimize: return "Refresh caches & services"
        case .purge: return "Reclaim build artifacts"
        case .installer: return "Find leftover installers"
        case .history: return "Cleanup activity"
        case .settings: return "Touch ID, updates & more"
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
        case .installer: return "shippingbox.fill"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
}

/// Logical grouping used to render sidebar sections.
enum FeatureSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case cleanup = "Cleanup"
    case management = "Management"
    case system = "System"

    var id: String { rawValue }

    var features: [Feature] {
        switch self {
        case .overview: return [.status, .analyze]
        case .cleanup: return [.clean, .optimize, .purge, .installer]
        case .management: return [.uninstall, .history]
        case .system: return [.settings]
        }
    }
}
