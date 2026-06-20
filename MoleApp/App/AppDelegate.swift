import AppKit

/// Ensures the app terminates when the last window is closed, matching
/// the expected behavior of a single-window utility app on macOS.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
