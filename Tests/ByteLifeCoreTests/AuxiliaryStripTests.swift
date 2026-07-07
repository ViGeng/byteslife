import XCTest
@testable import ByteLifeCore

final class AuxiliaryStripTests: XCTestCase {
    private func chip(_ strip: AuxiliaryStrip, _ key: String) -> AuxiliaryChip {
        strip.chips.first { $0.key == key }!
    }

    /// Every sensor running and every figure booked: each chip carries its formatted figure and reads present.
    func testChipsCarryTheAccessoryFiguresInOrder() {
        let strip = AuxiliaryStrip.build(
            totals: [.energyMilliwattHours: 12_400, .filesTouched: 312, .screenUnlocks: 7, .commandsRun: 58],
            topFocus: (bundleId: "com.apple.Safari", seconds: 2_700),  // 45 minutes
            distinctHosts: 9,
            energyRunning: true, focusRunning: true, filesRunning: true, unlocksRunning: true,
            commandsRunning: true
        )
        XCTAssertEqual(strip.chips.map(\.key), ["energy", "focus", "files", "hosts", "unlocks", "commands"])
        XCTAssertEqual(chip(strip, "energy").value, "12.4 Wh")
        XCTAssertEqual(chip(strip, "focus").value, "Safari 45m")
        XCTAssertEqual(chip(strip, "files").value, "312")
        XCTAssertEqual(chip(strip, "hosts").value, "9")
        XCTAssertEqual(chip(strip, "unlocks").value, "7")
        XCTAssertEqual(chip(strip, "commands").value, "58")
        XCTAssertTrue(strip.chips.allSatisfy(\.present))
    }

    /// Every sensor off or missing: each chip is an honest dim dash, and none reads present.
    func testOffSensorsReadAsDimDashesNotZeros() {
        let strip = AuxiliaryStrip.build(
            totals: [:], topFocus: nil, distinctHosts: nil,
            energyRunning: false, focusRunning: false, filesRunning: false, unlocksRunning: false
        )
        XCTAssertTrue(strip.chips.allSatisfy { $0.value == AuxiliaryStrip.dash && !$0.present })
    }

    /// The fix's heart: a running sensor that has booked nothing yet reads a genuine 0 in normal ink, not
    /// the dim dash an off sensor shows, so an idle sensor never masquerades as an absent one. Every kind
    /// is absent from `totals` here, yet the running sensors still read their zeros.
    func testRunningButUnbookedSensorsReadAsGenuineZeros() {
        let strip = AuxiliaryStrip.build(
            totals: [:], topFocus: nil, distinctHosts: 0,
            energyRunning: true, focusRunning: true, filesRunning: true, unlocksRunning: true
        )
        XCTAssertEqual(chip(strip, "energy").value, "0.0 Wh")
        XCTAssertTrue(chip(strip, "energy").present)
        XCTAssertEqual(chip(strip, "files").value, "0")
        XCTAssertTrue(chip(strip, "files").present)
        XCTAssertEqual(chip(strip, "unlocks").value, "0")
        XCTAssertTrue(chip(strip, "unlocks").present)
        // Hosts is availability-gated by its non-nil count; 0 distinct hosts is a real reading, present.
        XCTAssertEqual(chip(strip, "hosts").value, "0")
        XCTAssertTrue(chip(strip, "hosts").present)
    }

    /// A running files/unlocks sensor with an explicit zero total also reads a genuine 0, present, while
    /// an off energy sensor still dashes.
    func testBookedZeroIsAFigureNotADash() {
        let strip = AuxiliaryStrip.build(
            totals: [.filesTouched: 0, .screenUnlocks: 0], topFocus: nil, distinctHosts: 0,
            energyRunning: false, focusRunning: false, filesRunning: true, unlocksRunning: true
        )
        XCTAssertEqual(chip(strip, "files").value, "0")
        XCTAssertTrue(chip(strip, "files").present)
        XCTAssertEqual(chip(strip, "unlocks").value, "0")
        XCTAssertTrue(chip(strip, "unlocks").present)
        XCTAssertFalse(chip(strip, "energy").present)
        XCTAssertEqual(chip(strip, "energy").value, AuxiliaryStrip.dash)
    }

    /// The commands chip follows the shell collector: a dim dash while it is off, a genuine count while
    /// it runs (0 when it has booked nothing yet).
    func testCommandsChipFollowsShellCollector() {
        let off = AuxiliaryStrip.build(
            totals: [.commandsRun: 12], topFocus: nil, distinctHosts: nil,
            energyRunning: false, focusRunning: false, filesRunning: false, unlocksRunning: false,
            commandsRunning: false
        )
        XCTAssertEqual(chip(off, "commands").value, AuxiliaryStrip.dash)
        XCTAssertFalse(chip(off, "commands").present)

        let idle = AuxiliaryStrip.build(
            totals: [:], topFocus: nil, distinctHosts: nil,
            energyRunning: false, focusRunning: false, filesRunning: false, unlocksRunning: false,
            commandsRunning: true
        )
        XCTAssertEqual(chip(idle, "commands").value, "0")
        XCTAssertTrue(chip(idle, "commands").present)
    }

    /// Focus presence follows its sensor, not its app data: running with a foreground app reads the app;
    /// running with none reads a present placeholder in normal ink; an off sensor reads the dim dash.
    func testFocusPresenceFollowsSensorNotAppData() {
        let withApp = AuxiliaryStrip.build(
            totals: [:], topFocus: (bundleId: "com.apple.Safari", seconds: 2_700), distinctHosts: nil,
            energyRunning: false, focusRunning: true, filesRunning: false, unlocksRunning: false
        )
        XCTAssertEqual(chip(withApp, "focus").value, "Safari 45m")
        XCTAssertTrue(chip(withApp, "focus").present)

        let noApp = AuxiliaryStrip.build(
            totals: [:], topFocus: nil, distinctHosts: nil,
            energyRunning: false, focusRunning: true, filesRunning: false, unlocksRunning: false
        )
        XCTAssertTrue(chip(noApp, "focus").present)
        XCTAssertEqual(chip(noApp, "focus").value, AuxiliaryStrip.dash)

        let off = AuxiliaryStrip.build(
            totals: [:], topFocus: (bundleId: "com.apple.Safari", seconds: 2_700), distinctHosts: nil,
            energyRunning: false, focusRunning: false, filesRunning: false, unlocksRunning: false
        )
        XCTAssertFalse(chip(off, "focus").present)
        XCTAssertEqual(chip(off, "focus").value, AuxiliaryStrip.dash)
    }
}
