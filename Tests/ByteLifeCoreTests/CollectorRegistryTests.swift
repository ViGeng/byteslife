import XCTest
@testable import ByteLifeCore

final class CollectorRegistryTests: XCTestCase {

    /// A collector whose availability the test drives directly, with a lock so `availability` is
    /// safe to read from the registry's queue while the test mutates it.
    private final class FakeCollector: Collector, @unchecked Sendable {
        let id: String
        let family: MetricFamily
        var onAvailabilityChange: ((Availability) -> Void)?

        private let lock = NSLock()
        private var backingAvailability: Availability

        init(id: String, family: MetricFamily, availability: Availability) {
            self.id = id
            self.family = family
            self.backingAvailability = availability
        }

        var availability: Availability {
            lock.lock(); defer { lock.unlock() }
            return backingAvailability
        }

        func start() {}
        func stop() {}

        /// Flips availability and announces the transition the way a real collector would.
        func flip(to newValue: Availability) {
            lock.lock()
            backingAvailability = newValue
            lock.unlock()
            onAvailabilityChange?(newValue)
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() -> Int {
            lock.lock(); defer { lock.unlock() }
            value += 1
            return value
        }
    }

    func testSnapshotReflectsInitialAvailability() {
        let network = FakeCollector(id: "net", family: .network, availability: .running)
        let input = FakeCollector(id: "in", family: .input, availability: .needsPermission)
        let registry = CollectorRegistry(collectors: [network, input])

        let snapshot = registry.availabilitySnapshot()
        XCTAssertEqual(snapshot.count, 2)
        // Order matches registration order.
        XCTAssertEqual(snapshot[0], CollectorAvailability(id: "net", family: .network, availability: .running))
        XCTAssertEqual(snapshot[1], CollectorAvailability(id: "in", family: .input, availability: .needsPermission))
        XCTAssertEqual(registry.availability(forID: "in"), .needsPermission)
        XCTAssertNil(registry.availability(forID: "missing"))
    }

    func testAvailabilityFlipUpdatesSnapshotAndForwardsCallback() {
        let input = FakeCollector(id: "in", family: .input, availability: .needsPermission)
        let registry = CollectorRegistry(collectors: [input])

        var forwarded: [CollectorAvailability] = []
        registry.onAvailabilityChange = { forwarded.append($0) }

        input.flip(to: .running)

        XCTAssertEqual(registry.availability(forID: "in"), .running)
        XCTAssertEqual(forwarded, [CollectorAvailability(id: "in", family: .input, availability: .running)])
    }

    func testSchedulerFiresRepeatedlyOnItsQueue() {
        let queue = DispatchQueue(label: "test.scheduler")
        let fired = expectation(description: "timer fires several times")
        let counter = Counter()

        let scheduler = Scheduler(queue: queue, interval: .milliseconds(40), leeway: .milliseconds(10)) {
            if counter.increment() == 3 { fired.fulfill() }
        }
        scheduler.start()

        wait(for: [fired], timeout: 5.0)
        scheduler.stop()
    }

    func testSchedulerStartIsIdempotent() {
        let queue = DispatchQueue(label: "test.scheduler.idempotent")
        let fired = expectation(description: "timer fires despite double start")
        let counter = Counter()

        let scheduler = Scheduler(queue: queue, interval: .milliseconds(40), leeway: .milliseconds(10)) {
            if counter.increment() == 2 { fired.fulfill() }
        }
        scheduler.start()
        scheduler.start() // second start must not spin up a second source

        wait(for: [fired], timeout: 5.0)
        scheduler.stop()
        scheduler.stop() // second stop is a no-op
    }
}
