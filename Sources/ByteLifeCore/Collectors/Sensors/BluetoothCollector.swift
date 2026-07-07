import Foundation
import CoreBluetooth
import IOBluetooth

/// Books Bluetooth peripheral connect events, counting only.
///
/// A 30 s tick reads the number of connected paired devices through an injectable reader (production:
/// `IOBluetoothDevice.pairedDevices()`, counting those reporting connected). A rise in the count books that
/// many `btConnects`; a fall (a disconnect) is never counted as a connect, and the first sample only
/// baselines. Per the privacy design, v1 needs only counts, so no device name or address is ever read or
/// stored (the salted-hash path that `HostsSeenCollector` uses is deliberately unused here).
///
/// SAFETY GATE, learned the hard way: enumerating Bluetooth devices is TCC-protected, and touching
/// IOBluetooth without the user's grant is a privacy violation macOS punishes by KILLING THE PROCESS
/// (SIGABRT from tccd; this crashed 0.8.0 within a minute of every launch). Every tick therefore checks
/// `CBCentralManager.authorization` first — a read-only class property that never prompts — and only an
/// `.allowedAlways` state may reach IOBluetooth. Anything else books `.needsPermission` honestly and
/// touches nothing. The app never raises the Bluetooth prompt on its own, so the family stays dormant
/// until a future grant affordance requests it explicitly.
///
/// Availability: `.needsPermission` until the grant exists, `running` while the count reads,
/// `sourceMissing` when Bluetooth itself is unavailable. All mutable state is confined to `queue`;
/// tests inject the authorization, reader, and clock and call `tick()` directly.
public final class BluetoothCollector: Collector, @unchecked Sendable {
    public let id = "bluetooth"
    public let family: MetricFamily = .auxiliary
    public var onAvailabilityChange: ((Availability) -> Void)?

    private let store: SampleStore
    private let isAuthorized: () -> Bool
    private let readConnectedCount: () -> Int?
    private let now: () -> Date
    private let tickInterval: DispatchTimeInterval
    private let queue = DispatchQueue(label: "life.byte.bluetooth")

    private let lock = NSLock()
    private var backingAvailability: Availability = .needsPermission
    private var scheduler: Scheduler?

    // Confined to `queue` (or driven directly by single-threaded tests).
    private var previousCount: Int?

    public init(
        store: SampleStore,
        tickInterval: DispatchTimeInterval = .seconds(30),
        now: @escaping () -> Date = Date.init,
        isAuthorized: @escaping () -> Bool = BluetoothCollector.systemAuthorized,
        readConnectedCount: @escaping () -> Int? = BluetoothCollector.connectedDeviceCount
    ) {
        self.store = store
        self.tickInterval = tickInterval
        self.now = now
        self.isAuthorized = isAuthorized
        self.readConnectedCount = readConnectedCount
    }

    deinit { stop() }

    public var availability: Availability {
        lock.lock(); defer { lock.unlock() }
        return backingAvailability
    }

    public func start() {
        lock.lock()
        let alreadyRunning = scheduler != nil
        lock.unlock()
        guard !alreadyRunning else { return }
        let scheduler = Scheduler(queue: queue, interval: tickInterval) { [weak self] in self?.tick() }
        lock.lock(); self.scheduler = scheduler; lock.unlock()
        scheduler.start()
    }

    public func stop() {
        lock.lock()
        scheduler?.stop()
        scheduler = nil
        lock.unlock()
    }

    /// One tick: verify the TCC grant, then sample the connected count and book any rise as connect
    /// events. Without the grant the tick books `.needsPermission` and returns BEFORE the reader — the
    /// reader call is what tccd kills unpermitted processes over. Degrades to `sourceMissing` when the
    /// count cannot be read. Runs on `queue`; tests call it directly.
    func tick() {
        guard isAuthorized() else {
            setAvailability(.needsPermission)
            return
        }
        guard let count = readConnectedCount() else {
            setAvailability(.sourceMissing)
            return
        }
        setAvailability(.running)
        let connects = SensorSignal.rise(previous: previousCount, current: count)
        if connects > 0 {
            try? store.record([Sample(kind: .btConnects, value: Int64(connects), timestamp: now())])
        }
        previousCount = count
    }

    private func setAvailability(_ value: Availability) {
        lock.lock()
        let changed = value != backingAvailability
        backingAvailability = value
        lock.unlock()
        if changed { onAvailabilityChange?(value) }
    }

    /// Whether the user has granted this app Bluetooth access. `CBCentralManager.authorization` is a
    /// read-only class property: it reports the TCC state without instantiating a manager, so checking it
    /// can never raise the system prompt (and never crashes an unpermitted process).
    public static func systemAuthorized() -> Bool {
        CBCentralManager.authorization == .allowedAlways
    }

    /// The number of currently connected paired Bluetooth devices, or nil when Bluetooth is unavailable
    /// (no hardware or the paired list cannot be read). Reads counts only; no name or address is touched.
    /// MUST be called only behind a true `systemAuthorized()` — see the class note.
    public static func connectedDeviceCount() -> Int? {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return nil }
        return paired.filter { $0.isConnected() }.count
    }
}
