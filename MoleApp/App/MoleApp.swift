import SwiftUI

@main
struct MoleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var service = MoleService()
    @StateObject private var localization = Localization()
    @StateObject private var updater = UpdateChecker()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(service)
                .environmentObject(localization)
                .environmentObject(updater)
                .frame(minWidth: 980, minHeight: 640)
                .task {
                    // Silent background check for app updates on launch.
                    await updater.checkForUpdates()
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .sidebar) {
                Button(localization.t("刷新", "Refresh")) {
                    NotificationCenter.default.post(name: .moleRefresh, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
            }
            CommandGroup(after: .appSettings) {
                Button(localization.t("检查更新…", "Check for Updates…")) {
                    NotificationCenter.default.post(name: .moleCheckUpdates, object: nil)
                }
            }
        }
    }
}

extension Notification.Name {
    static let moleRefresh = Notification.Name("mole.refresh")
    static let moleCheckUpdates = Notification.Name("mole.checkUpdates")
}
