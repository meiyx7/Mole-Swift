import SwiftUI

@main
struct MoleApp: App {
    @StateObject private var service = MoleService()
    @StateObject private var localization = Localization()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(service)
                .environmentObject(localization)
                .frame(minWidth: 980, minHeight: 640)
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
        }
    }
}

extension Notification.Name {
    static let moleRefresh = Notification.Name("mole.refresh")
}
