import Foundation
import CoreAudio

/// Books default-output-device switches and output-volume changes.
///
/// A CoreAudio property listener on the default output device books one `audioDeviceSwitches` each time the
/// system output device changes. A 5 s poll samples the current output volume through an injectable reader
/// and books one `volumeChanges` whenever the level moved by more than a small epsilon since the last
/// sample, so float jitter around an unchanged level is ignored and the first sample only baselines.
/// Availability follows the volume reader: `running` while it reads, `sourceMissing` when no default output
/// device exposes a scalar volume. All mutable state is confined to `queue`; tests inject the reader and
/// clock and call `poll()` / `handleDeviceSwitch()` directly.
public final class AudioCollector: Collector, @unchecked Sendable {
    public let id = "audio"
    public let family: MetricFamily = .auxiliary
    public var onAvailabilityChange: ((Availability) -> Void)?

    private let store: SampleStore
    private let readOutputVolume: () -> Double?
    private let now: () -> Date
    private let epsilon: Double
    private let pollInterval: DispatchTimeInterval
    private let queue = DispatchQueue(label: "life.byte.audio")

    private let lock = NSLock()
    private var backingAvailability: Availability = .running
    private var scheduler: Scheduler?
    private var listenerBlock: AudioObjectPropertyListenerBlock?

    // Confined to `queue` (or driven directly by single-threaded tests).
    private var previousVolume: Double?

    public init(
        store: SampleStore,
        pollInterval: DispatchTimeInterval = .seconds(5),
        epsilon: Double = 0.01,
        now: @escaping () -> Date = Date.init,
        readOutputVolume: @escaping () -> Double? = AudioCollector.defaultOutputVolume
    ) {
        self.store = store
        self.pollInterval = pollInterval
        self.epsilon = epsilon
        self.now = now
        self.readOutputVolume = readOutputVolume
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

        var address = Self.defaultDeviceAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.handleDeviceSwitch() }
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, block
        )
        let scheduler = Scheduler(queue: queue, interval: pollInterval) { [weak self] in self?.poll() }
        lock.lock(); self.scheduler = scheduler; self.listenerBlock = block; lock.unlock()
        scheduler.start()
    }

    public func stop() {
        lock.lock()
        scheduler?.stop()
        scheduler = nil
        let block = listenerBlock
        listenerBlock = nil
        lock.unlock()
        if let block {
            var address = Self.defaultDeviceAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, queue, block
            )
        }
    }

    /// One poll: sample the output volume and book a change when it moved past the epsilon. Degrades to
    /// `sourceMissing` when no volume reads. Runs on `queue`; tests call it directly.
    func poll() {
        guard let volume = readOutputVolume() else {
            setAvailability(.sourceMissing)
            return
        }
        setAvailability(.running)
        if SensorSignal.changed(previous: previousVolume, current: volume, epsilon: epsilon) {
            try? store.record([Sample(kind: .volumeChanges, value: 1, timestamp: now())])
        }
        previousVolume = volume
    }

    /// Books one output-device switch. Runs on `queue` (the listener's dispatch queue); tests call it
    /// directly.
    func handleDeviceSwitch() {
        try? store.record([Sample(kind: .audioDeviceSwitches, value: 1, timestamp: now())])
    }

    private func setAvailability(_ value: Availability) {
        lock.lock()
        let changed = value != backingAvailability
        backingAvailability = value
        lock.unlock()
        if changed { onAvailabilityChange?(value) }
    }

    private static var defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    /// The current default output device's scalar volume (0…1), or nil when there is no default output
    /// device or it exposes no master scalar volume, so the collector degrades honestly.
    public static func defaultOutputVolume() -> Double? {
        var deviceID = AudioDeviceID(0)
        var deviceSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var deviceAddress = defaultDeviceAddress
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &deviceAddress, 0, nil, &deviceSize, &deviceID
        ) == noErr, deviceID != 0 else { return nil }

        var volume = Float32(0)
        var volumeSize = UInt32(MemoryLayout<Float32>.size)
        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            deviceID, &volumeAddress, 0, nil, &volumeSize, &volume
        ) == noErr else { return nil }
        return Double(volume)
    }
}
