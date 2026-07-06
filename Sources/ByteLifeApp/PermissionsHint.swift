import AppKit

/// Deep links into the system settings pane a collector needs. v1 has one: Input Monitoring, which
/// gates the keystroke and mouse-travel event tap.
enum PermissionsHint {
    /// Opens System Settings directly at Privacy & Security > Input Monitoring.
    static func openInputMonitoringSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
