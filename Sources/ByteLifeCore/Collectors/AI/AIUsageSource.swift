/// A single AI tool whose token usage ByteLife can track (Claude Code in v1; the protocol leaves
/// room for a Codex CLI adapter, whose cumulative token_count semantics differ).
///
/// A source watches its own on-disk transcripts, deduplicates usage, and emits already-reduced
/// additive `Sample` batches through the closure passed to `start`. The `AICollector` owns the store
/// side and records whatever a source emits.
public protocol AIUsageSource: AnyObject {
    /// Stable identifier, unique within the collector (for example "ai.claudeCode").
    var id: String { get }

    /// Whether the source's data root currently exists. False means the tool is not installed here.
    var isAvailable: Bool { get }

    /// Begins watching and emits deduplicated sample batches through `emit`. Idempotent.
    func start(emit: @escaping ([Sample]) -> Void)

    /// Stops watching and releases every OS resource (file descriptors, watchers). Idempotent.
    func stop()
}
