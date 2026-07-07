import XCTest
@testable import ByteLifeCore

final class AuxiliaryStoryTests: XCTestCase {
    func testDayStoryCarriesEveryAccessoryFigure() {
        let story = AuxiliaryStory.build(
            totals: [.energyMilliwattHours: 8_600, .filesTouched: 140,
                     .screenUnlocks: 4, .attentionSessions: 11],
            focus: [(bundleId: "com.apple.Safari", seconds: 3_600),
                    (bundleId: "com.microsoft.VSCode", seconds: 1_800),
                    (bundleId: "com.apple.Terminal", seconds: 900)],
            distinctHosts: 6,
            energyHourly: [100, 0, 200]
        )
        XCTAssertEqual(story.energyHeadline, "8.6 Wh")
        XCTAssertTrue(story.energyPresent)
        XCTAssertEqual(story.energyHourly, [100, 0, 200])
        XCTAssertEqual(story.filesTouched, 140)
        XCTAssertTrue(story.filesPresent)
        XCTAssertEqual(story.distinctHosts, 6)
        XCTAssertEqual(story.unlocks, 4)
        XCTAssertEqual(story.sessions, 11)
    }

    func testFocusAppsRankAndScaleAgainstTheLeader() {
        let story = AuxiliaryStory.build(
            totals: [:],
            focus: [(bundleId: "com.microsoft.VSCode", seconds: 1_800),
                    (bundleId: "com.apple.Safari", seconds: 3_600),
                    (bundleId: "com.apple.Terminal", seconds: 900)],
            distinctHosts: nil
        )
        XCTAssertEqual(story.focusApps.map(\.name), ["Safari", "VSCode", "Terminal"])
        XCTAssertEqual(story.focusApps[0].fraction, 1.0, accuracy: 0.0001)   // the leader fills
        XCTAssertEqual(story.focusApps[1].fraction, 0.5, accuracy: 0.0001)
        XCTAssertEqual(story.focusApps[2].fraction, 0.25, accuracy: 0.0001)
        XCTAssertEqual(story.focusApps[0].timeLabel, ByteFormatting.duration(seconds: 3_600))
    }

    func testFocusMergesAppsSharingAShortName() {
        // Two distinct bundle ids that both render "Safari" collapse into one ranked row.
        let story = AuxiliaryStory.build(
            totals: [:],
            focus: [(bundleId: "com.apple.Safari", seconds: 1_000),
                    (bundleId: "org.webkit.Safari", seconds: 500)],
            distinctHosts: nil
        )
        XCTAssertEqual(story.focusApps.count, 1)
        XCTAssertEqual(story.focusApps[0].name, "Safari")
        XCTAssertEqual(story.focusApps[0].seconds, 1_500)
    }

    func testFocusLimitCapsTheTopList() {
        let focus = (1...8).map { (bundleId: "com.app\($0)", seconds: Int64($0) * 100) }
        let story = AuxiliaryStory.build(totals: [:], focus: focus, distinctHosts: nil, focusLimit: 5)
        XCTAssertEqual(story.focusApps.count, 5)
        // Highest seconds first: app8 (800) down to app4 (400).
        XCTAssertEqual(story.focusApps.map(\.seconds), [800, 700, 600, 500, 400])
    }

    func testMissingEnergyAndFilesReadAsUnopened() {
        let story = AuxiliaryStory.build(totals: [:], focus: [], distinctHosts: nil)
        XCTAssertFalse(story.energyPresent)
        XCTAssertEqual(story.energyHeadline, "0.0 Wh")
        XCTAssertFalse(story.filesPresent)
        XCTAssertNil(story.distinctHosts)
        XCTAssertTrue(story.focusApps.isEmpty)
        XCTAssertEqual(story.unlocks, 0)
        XCTAssertEqual(story.sessions, 0)
    }
}
