import XCTest
@testable import FridgeCore

final class NameKeyTests: XCTestCase {
    func testFoldsCaseAndDiacritics() {
        XCTAssertEqual(NameKey.normalize("Jalapeño Pepper"), "jalapeno pepper")
        XCTAssertEqual(NameKey.normalize("CRÈME FRAÎCHE"), "creme fraiche")
    }

    func testTrimsAndCollapsesWhitespace() {
        XCTAssertEqual(NameKey.normalize("  Whole   Milk "), "whole milk")
        XCTAssertEqual(NameKey.normalize("\tEggs\n"), "eggs")
    }

    func testEmptyAndWhitespaceOnly() {
        XCTAssertEqual(NameKey.normalize(""), "")
        XCTAssertEqual(NameKey.normalize("   "), "")
    }

    func testEqualNamesShareAKey() {
        XCTAssertEqual(NameKey.normalize("Jalapeño  Peppers"),
                       NameKey.normalize("jalapeno peppers"))
    }

    func testDistinctNamesStayDistinct() {
        XCTAssertNotEqual(NameKey.normalize("Milk"), NameKey.normalize("Milkshake"))
        XCTAssertNotEqual(NameKey.normalize("Pepper"), NameKey.normalize("Peppers"))
    }
}
