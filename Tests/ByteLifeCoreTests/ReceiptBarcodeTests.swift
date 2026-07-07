import XCTest
@testable import ByteLifeCore

final class ReceiptBarcodeTests: XCTestCase {
    /// The same hash always draws the same barcode: the derivation is a pure function of the hash.
    func testDeterministic() {
        let hash = "9f3c1a7b0e5d2648"
        XCTAssertEqual(ReceiptBarcode.modules(for: hash), ReceiptBarcode.modules(for: hash))
    }

    /// A 16-hex hash yields exactly two modules per digit, alternating a bar then a gap.
    func testDefinedLength() {
        let modules = ReceiptBarcode.modules(for: "0123456789abcdef")
        XCTAssertEqual(modules.count, 16 * ReceiptBarcode.modulesPerDigit)
        XCTAssertEqual(modules.count, 32)
    }

    /// Every module width stays within the 1...4 range the drawing code expects.
    func testWidthsInRange() {
        for width in ReceiptBarcode.modules(for: "ffff0000aaaa5555") {
            XCTAssertGreaterThanOrEqual(width, 1)
            XCTAssertLessThanOrEqual(width, 4)
        }
    }

    /// Distinct hashes produce distinct patterns, so a barcode fingerprints the hash it came from.
    func testDistinctHashesDiffer() {
        let a = ReceiptBarcode.modules(for: "9f3c1a7b0e5d2648")
        let b = ReceiptBarcode.modules(for: "9f3c1a7b0e5d2649") // differs in the final digit only
        XCTAssertNotEqual(a, b)

        // A wider sweep: no collisions across a spread of unrelated hashes.
        let hashes = [
            "0000000000000000", "ffffffffffffffff", "0123456789abcdef",
            "fedcba9876543210", "deadbeefcafef00d", "1111111111111111",
        ]
        let patterns = hashes.map { ReceiptBarcode.modules(for: $0) }
        XCTAssertEqual(Set(patterns.map { $0.map(String.init).joined(separator: ",") }).count, hashes.count)
    }

    /// The high two bits drive the bar and the low two bits the gap, so the map is a per-digit bijection.
    func testBitSplit() {
        // Digit 0 -> bar 1, gap 1; digit 15 (f) -> bar 4, gap 4; digit 6 (0b0110) -> bar 2, gap 3.
        XCTAssertEqual(ReceiptBarcode.modules(for: "0"), [1, 1])
        XCTAssertEqual(ReceiptBarcode.modules(for: "f"), [4, 4])
        XCTAssertEqual(ReceiptBarcode.modules(for: "6"), [2, 3])
    }
}
