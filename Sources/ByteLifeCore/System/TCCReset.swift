import Foundation

/// Resets the app's Input Monitoring (ListenEvent) TCC decision so the system prompt can fire again.
///
/// macOS records a per-identity decision the first time an app requests Input Monitoring; after that,
/// `CGRequestListenEventAccess()` silently no-ops and no prompt appears. `tccutil reset` is a per-user
/// command that clears the stored decision, needing no privileges, so the next request genuinely prompts.
/// The argument construction is pure and separated from the `Process` invocation so the command is
/// asserted in tests without running it.
public enum TCCReset {
    /// The tccutil service name for the Input Monitoring grant.
    static let service = "ListenEvent"

    /// The bundle identifier to reset, read from the running bundle with the literal fallback for
    /// `swift run` and tests, where there is no app bundle.
    public static var bundleID: String {
        Bundle.main.bundleIdentifier ?? "com.vigeng.bytelife"
    }

    /// The tccutil argument vector for resetting one bundle's ListenEvent decision. Pure, so a test can
    /// assert the exact command.
    static func arguments(bundleID: String) -> [String] {
        ["reset", service, bundleID]
    }

    /// Runs `/usr/bin/tccutil reset ListenEvent <bundleID>` and returns its exit status. A launch failure
    /// (the binary missing) reports a synthetic nonzero code so the caller degrades honestly.
    public static func run(bundleID: String = TCCReset.bundleID) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = arguments(bundleID: bundleID)
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
