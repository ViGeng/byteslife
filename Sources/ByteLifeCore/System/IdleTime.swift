import CoreGraphics

/// Seconds since the last user input event, the permission-free primitive behind attentive-time
/// tracking. It exposes only an elapsed scalar, never event content, so it triggers no TCC prompt.
public enum IdleTime {
    /// `kCGAnyInputEventType` is `CGEventType(rawValue: ~0)`; it matches keyboard, mouse, and tablet
    /// events alike. The value is a valid `CGEventType` on macOS, so the force-unwrap never fails.
    private static let anyInputEvent = CGEventType(rawValue: ~0)!

    /// Seconds since the last input across the combined session state (all input sources).
    public static func idleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInputEvent)
    }
}
