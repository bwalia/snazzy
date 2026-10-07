import AppKit

/// Quits and reopens the app (macOS applies screen-recording permission only
/// after a restart).
@MainActor
enum AppRelaunch {
    static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
