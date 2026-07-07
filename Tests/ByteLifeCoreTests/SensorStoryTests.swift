import XCTest
@testable import ByteLifeCore

final class SensorStoryTests: XCTestCase {
    private func memo(_ story: SensorStory, _ key: String) -> SensorMemo? {
        story.memos.first { $0.key == key }
    }

    /// A single day carries the five curves plus the count memos. Curves label their latest reading in the
    /// gauge's own unit and keep the nil gaps honest.
    func testDayStoryCarriesCurvesAndMemos() {
        var temp = [Int64?](repeating: nil, count: 1440)
        temp[60] = 415        // 41.5°C
        temp[120] = 468       // 46.8°C, the latest reading
        var charge = [Int64?](repeating: nil, count: 1440)
        charge[10] = 87

        let story = SensorStory.build(
            totals: [.lidOpens: 6, .systemWakes: 9, .systemBoots: 0,
                     .audioDeviceSwitches: 3, .btConnects: 2, .volumeChanges: 14],
            thermalStateChanges: 4,
            chargingSessions: 2,
            batteryCycleCount: 312,
            gaugeSeries: [
                GaugeName.cpuTemperature: temp,
                GaugeName.batteryCharge: charge,
            ]
        )

        XCTAssertEqual(story.curves.map(\.gauge), SensorStory.curveGauges.map(\.gauge))
        let tempCurve = story.curves.first { $0.gauge == GaugeName.cpuTemperature }!
        XCTAssertEqual(tempCurve.latest, "46.8°C")
        XCTAssertTrue(tempCurve.hasData)
        XCTAssertEqual(tempCurve.points[60], 415)
        XCTAssertNil(tempCurve.points[0])
        // A gauge with no reading all day reads as no-data and draws nothing.
        let luxCurve = story.curves.first { $0.gauge == GaugeName.ambientLux }!
        XCTAssertNil(luxCurve.latest)
        XCTAssertFalse(luxCurve.hasData)

        XCTAssertEqual(memo(story, "lidOpens")?.value, "6")
        XCTAssertEqual(memo(story, "wakes")?.value, "9")
        XCTAssertEqual(memo(story, "audioSwitches")?.value, "3")
        XCTAssertEqual(memo(story, "btConnects")?.value, "2")
        XCTAssertEqual(memo(story, "volumeChanges")?.value, "14")
        XCTAssertEqual(memo(story, "thermalChanges")?.value, "4")
        XCTAssertEqual(memo(story, "chargingSessions")?.value, "2")
        XCTAssertEqual(memo(story, "batteryCycles")?.value, "312")
    }

    /// Boots print only when nonzero, and battery cycles only when the battery reported them.
    func testConditionalMemos() {
        let noBoots = SensorStory.build(
            totals: [.systemBoots: 0], thermalStateChanges: 0, chargingSessions: 0, batteryCycleCount: nil
        )
        XCTAssertNil(memo(noBoots, "boots"))
        XCTAssertNil(memo(noBoots, "batteryCycles"))

        let withBoots = SensorStory.build(
            totals: [.systemBoots: 2], thermalStateChanges: 0, chargingSessions: 0, batteryCycleCount: 0
        )
        XCTAssertEqual(memo(withBoots, "boots")?.value, "2")
        // A reported cycle count of zero is a real fact and still prints.
        XCTAssertEqual(memo(withBoots, "batteryCycles")?.value, "0")
    }

    /// An aggregate period passes no gauge series, so it carries only the summed count memos and no curves.
    func testAggregateSkipsCurves() {
        let story = SensorStory.build(
            totals: [.lidOpens: 40, .systemWakes: 55],
            thermalStateChanges: 12, chargingSessions: 9, batteryCycleCount: 320
        )
        XCTAssertTrue(story.curves.isEmpty)
        XCTAssertEqual(memo(story, "lidOpens")?.value, "40")
        XCTAssertEqual(memo(story, "thermalChanges")?.value, "12")
    }

    /// Each gauge reading formats in its own display unit.
    func testReadingFormatting() {
        XCTAssertEqual(SensorStory.reading(gauge: GaugeName.cpuTemperature, value: 425), "42.5°C")
        XCTAssertEqual(SensorStory.reading(gauge: GaugeName.batteryCharge, value: 87), "87%")
        XCTAssertEqual(SensorStory.reading(gauge: GaugeName.ambientLux, value: 1_240), "level 1,240")
        XCTAssertEqual(SensorStory.reading(gauge: GaugeName.displayBrightness, value: 640), "64%")
        XCTAssertEqual(SensorStory.reading(gauge: GaugeName.systemPowerWatts, value: 184), "18.4 W")
    }
}
