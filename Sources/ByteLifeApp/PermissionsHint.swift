import AppKit

/// Routes the user to the Input Monitoring grant. On macOS 26 the old standalone-pane deep link is no
/// longer a reliable path, so the instruction the UI shows is the System Settings SEARCH route: open
/// Settings and search for "Input Monitoring". The deep link stays as a best-effort shortcut with a
/// plain open-Settings fallback when it cannot be opened, and a failed permission reset surfaces as an
/// honest alert.
enum PermissionsHint {
    /// The human instruction shown alongside the affordance. macOS 26 has no stable direct pane path, so
    /// the reliable route is the Settings search field.
    static let searchInstruction =
        "Open System Settings, search for “Input Monitoring”, then enable ByteLife."

    /// Best-effort deep link to Privacy & Security > Input Monitoring, falling back to opening System
    /// Settings bare when the URL cannot be opened (the macOS 26 case), from which the user searches.
    static func openInputMonitoringSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"),
              NSWorkspace.shared.open(url) else {
            openSystemSettings()
            return
        }
    }

    /// Opens System Settings with no pane target, the reliable fallback on macOS 26. The user then uses
    /// the search field to reach Input Monitoring.
    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Surfaces an honest alert when the tccutil reset exited nonzero, so a failed reset is never mistaken
    /// for a silent success. Offers the manual search route by opening System Settings.
    static func presentResetFailure(exitCode: Int32) {
        let alert = NSAlert()
        alert.messageText = "Could not reset Input Monitoring permission"
        alert.informativeText = "The reset command exited with status \(exitCode). " + searchInstruction
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn {
            openSystemSettings()
        }
    }
}
