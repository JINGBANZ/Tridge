import XCTest
@testable import FridgeCore

/// Byte-order UUID comparison is the tie-break every household member must
/// agree on, so it is pinned by construction rather than by `uuidString`.
final class UUIDOrderTests: XCTestCase {
    private func uuid(_ bytes: [UInt8]) -> UUID {
        var raw = [UInt8](repeating: 0, count: 16)
        raw.replaceSubrange(0..<bytes.count, with: bytes)
        return UUID(uuid: (raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7],
                           raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15]))
    }

    func testComparesLeadingBytesFirst() {
        XCTAssertTrue(UUIDOrder.isBefore(uuid([0x00, 0xFF]), uuid([0x01, 0x00])))
        XCTAssertFalse(UUIDOrder.isBefore(uuid([0x01, 0x00]), uuid([0x00, 0xFF])))
    }

    func testComparesUnsignedNotSigned() {
        // 0x80 must sort above 0x7F; a signed byte comparison would invert this.
        XCTAssertTrue(UUIDOrder.isBefore(uuid([0x7F]), uuid([0x80])))
    }

    func testFallsThroughToTheFinalByte() {
        let base = [UInt8](repeating: 0xAB, count: 15)
        XCTAssertTrue(UUIDOrder.isBefore(uuid(base + [0x00]), uuid(base + [0x01])))
    }

    func testEqualIdsAreNotOrdered() {
        let id = UUID()
        XCTAssertFalse(UUIDOrder.isBefore(id, id))
    }

    func testSortAndSmallestAgree() {
        let ids = (0..<20).map { _ in UUID() }
        let sorted = UUIDOrder.sorted(ids)
        XCTAssertEqual(Set(sorted), Set(ids))
        XCTAssertEqual(UUIDOrder.smallest(ids), sorted.first)
        for (earlier, later) in zip(sorted, sorted.dropFirst()) {
            XCTAssertTrue(UUIDOrder.isBefore(earlier, later))
        }
    }

    func testSmallestOfNothingIsNil() {
        XCTAssertNil(UUIDOrder.smallest([]))
    }
}
