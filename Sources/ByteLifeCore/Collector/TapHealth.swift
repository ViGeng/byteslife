/// A pure, clock-free detector for the "silent disable race" behind ByteLife's frozen input counts.
///
/// Input Monitoring TCC grants bind to the app's code-signing identity. An ad-hoc re-sign on every
/// rebuild mints a fresh identity, so the prior grant goes stale: the event tap is still created
/// successfully but silently delivers nothing. The counters then freeze — collected once, never moving
/// again — while the tap reports itself running.
///
/// This state machine watches for that exact signature: a run of attentive time during which the
/// reportedly-live tap accumulates zero input events. Its caller feeds periodic observations, each
/// carrying the input events and attentive seconds accrued since the previous observation, and reads back
/// whether the tap now looks suspect. It owns no clock; the attentive seconds in each observation are the
/// only time it ever sees, so it is fully covered by `swift test`.
public struct TapHealth: Equatable, Sendable {
    /// Attentive seconds of zero-input activity that must accumulate before the tap is called suspect.
    /// Conservative by design: three attentive minutes with not one key, click, or scroll is the honest
    /// signature of a dead tap, not of a user who merely paused to read.
    public let suspectAfterAttentiveSeconds: Int64

    /// Attentive seconds accrued so far in the current zero-input run. Any input event resets it.
    public private(set) var zeroInputAttentiveSeconds: Int64
    /// Whether the tap currently looks stale. It latches once flagged and clears only when input resumes,
    /// so a single recovered observation is enough to trust the tap again.
    public private(set) var isSuspect: Bool

    /// - Parameter suspectAfterAttentiveSeconds: the zero-input attentive run that trips the flag.
    ///   Defaults to 180 (three attentive minutes), the conservative threshold the diagnosis calls for.
    public init(suspectAfterAttentiveSeconds: Int64 = 180) {
        self.suspectAfterAttentiveSeconds = suspectAfterAttentiveSeconds
        self.zeroInputAttentiveSeconds = 0
        self.isSuspect = false
    }

    /// Folds one observation into the run and returns whether the tap now looks suspect.
    ///
    /// Any input event is proof the tap is delivering, so it resets the run and clears a prior flag
    /// (recovery). With zero input, attentive seconds accumulate; genuine idle contributes nothing,
    /// because idle time reports zero attentive seconds, so a user who steps away never trips the
    /// detector. Once the zero-input attentive run reaches the threshold the tap latches suspect until
    /// input resumes.
    @discardableResult
    public mutating func observe(inputEvents: Int64, attentiveSeconds: Int64) -> Bool {
        if inputEvents > 0 {
            zeroInputAttentiveSeconds = 0
            isSuspect = false
        } else if attentiveSeconds > 0 {
            zeroInputAttentiveSeconds += attentiveSeconds
            if zeroInputAttentiveSeconds >= suspectAfterAttentiveSeconds {
                isSuspect = true
            }
        }
        return isSuspect
    }

    /// Discards the accumulated run and clears the flag. The collector calls this when the tap is torn
    /// down or the grant is explicitly revoked, so a fresh tap starts from a clean slate rather than
    /// inheriting a stale suspicion.
    public mutating func reset() {
        zeroInputAttentiveSeconds = 0
        isSuspect = false
    }
}
