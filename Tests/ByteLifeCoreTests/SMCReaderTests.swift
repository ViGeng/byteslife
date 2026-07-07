import XCTest
@testable import ByteLifeCore

/// The SMC decoding and the SMC-preferred power selection under fixture byte patterns and injected
/// readers, so the math is proven without any hardware. The IOKit path itself is production-only.
final class SMCReaderTests: XCTestCase {

    // MARK: - FourCC keys

    func testFourCCEncodesKeyBigEndian() {
        // 'P'=0x50, 'S'=0x53, 'T'=0x54, 'R'=0x52.
        XCTAssertEqual(SMCDecoding.fourCC("PSTR"), 0x5053_5452)
    }

    func testFourCCStringRoundTrips() {
        XCTAssertEqual(SMCDecoding.fourCCString(0x5053_5452), "PSTR")
        XCTAssertEqual(SMCDecoding.fourCCString(SMCDecoding.fourCC("flt ")), "flt ")
        XCTAssertEqual(SMCDecoding.fourCCString(SMCDecoding.fourCC("sp78")), "sp78")
    }

    // MARK: - Value decoding

    func testDecodeFloatLittleEndian() {
        // 12.5 has bit pattern 0x41480000; on the wire the float is little-endian.
        XCTAssertEqual(SMCDecoding.decode(bytes: [0x00, 0x00, 0x48, 0x41], dataType: "flt "), 12.5)
    }

    func testDecodeFPE2UnsignedBigEndianDividesByFour() {
        // A 2000 RPM fan reads raw 8000 = 0x1F40, big-endian, value = raw / 4.
        XCTAssertEqual(SMCDecoding.decode(bytes: [0x1F, 0x40], dataType: "fpe2"), 2000.0)
    }

    func testDecodeSP78SignedBigEndianDividesBy256() {
        // 45.5 °C reads raw 11648 = 0x2D80, big-endian, value = raw / 256.
        XCTAssertEqual(SMCDecoding.decode(bytes: [0x2D, 0x80], dataType: "sp78"), 45.5)
        // A negative reading exercises the sign: -1.0 is raw 0xFF00.
        XCTAssertEqual(SMCDecoding.decode(bytes: [0xFF, 0x00], dataType: "sp78"), -1.0)
    }

    func testDecodeRejectsUnknownTypeAndShortBuffers() {
        XCTAssertNil(SMCDecoding.decode(bytes: [0x00, 0x00, 0x48, 0x41], dataType: "xxxx"))
        XCTAssertNil(SMCDecoding.decode(bytes: [0x00], dataType: "flt "))
        XCTAssertNil(SMCDecoding.decode(bytes: [0x00], dataType: "sp78"))
        XCTAssertNil(SMCDecoding.decode(bytes: [0x00], dataType: "fpe2"))
    }

    // MARK: - System power selection

    func testSystemPowerPrefersSMCWattsAndConvertsToMilliwatts() {
        // 18 W from the SMC becomes 18,000 mW, and the battery fallback is not consulted.
        let mw = SystemPower.milliwatts(smc: StubSMC(value: 18.0), battery: { 9_999 })
        XCTAssertEqual(mw, 18_000)
    }

    func testSystemPowerFallsBackToBatteryWhenSMCAbsent() {
        XCTAssertEqual(SystemPower.milliwatts(smc: StubSMC(value: nil), battery: { 4_200 }), 4_200)
    }

    func testSystemPowerIgnoresNonPositiveSMCReadingAndFallsBack() {
        // A zero watt reading is not a real signal; the battery path stands in.
        XCTAssertEqual(SystemPower.milliwatts(smc: StubSMC(value: 0), battery: { 5_000 }), 5_000)
    }

    func testSystemPowerReturnsNilWhenNeitherSourceHasSignal() {
        XCTAssertNil(SystemPower.milliwatts(smc: StubSMC(value: nil), battery: { nil }))
    }
}

/// A fixed SMC reading for the power-selection tests, ignoring the key.
private struct StubSMC: SMCReading {
    let value: Double?
    func read(key: String) -> Double? { value }
}
