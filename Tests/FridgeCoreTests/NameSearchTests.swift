import XCTest
@testable import FridgeCore

final class NameSearchTests: XCTestCase {
    private func entry(_ name: String, daysAgo: Int = 0, uses: Int = 1) -> SearchEntry {
        SearchEntry(normalizedName: NameKey.normalize(name),
                    lastUsed: Date(timeIntervalSinceNow: -Double(daysAgo) * 86_400),
                    useCount: uses)
    }

    func testTierOrdering() {
        XCTAssertEqual(NameSearch.tier(query: "milk", candidate: "milk"), 0)
        XCTAssertEqual(NameSearch.tier(query: "mi", candidate: "milk"), 1)
        XCTAssertEqual(NameSearch.tier(query: "mi", candidate: "whole milk"), 2)
        XCTAssertEqual(NameSearch.tier(query: "ilk", candidate: "milk"), 3)
        XCTAssertNil(NameSearch.tier(query: "egg", candidate: "milk"))
    }

    func testRankPutsBetterTiersFirst() {
        let results = NameSearch.rank(
            query: "mi",
            in: [entry("almond milk"), entry("milk"), entry("vermicelli")],
            limit: 10)
        XCTAssertEqual(results.map(\.normalizedName),
                       ["milk", "almond milk", "vermicelli"])
    }

    func testDiacriticBlindQuery() {
        let results = NameSearch.rank(query: "jala", in: [entry("Jalapeño Peppers")], limit: 5)
        XCTAssertEqual(results.first?.normalizedName, "jalapeno peppers")
    }

    func testRecencyBreaksTies() {
        let results = NameSearch.rank(
            query: "m",
            in: [entry("mango", daysAgo: 10), entry("milk", daysAgo: 1)],
            limit: 5)
        XCTAssertEqual(results.map(\.normalizedName), ["milk", "mango"])
    }

    func testFrequencyBreaksRemainingTies() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let often = SearchEntry(normalizedName: "milk", lastUsed: now, useCount: 9)
        let rare = SearchEntry(normalizedName: "mango", lastUsed: now, useCount: 1)
        let results = NameSearch.rank(query: "m", in: [rare, often], limit: 5)
        XCTAssertEqual(results.map(\.normalizedName), ["milk", "mango"])
    }

    func testEmptyQueryReturnsRecents() {
        let results = NameSearch.rank(
            query: "",
            in: [entry("cheese", daysAgo: 5), entry("eggs", daysAgo: 1), entry("rice", daysAgo: 3)],
            limit: 2)
        XCTAssertEqual(results.map(\.normalizedName), ["eggs", "rice"])
    }

    func testLimitIsRespected() {
        let entries = (0..<20).map { entry("item \($0)", daysAgo: $0) }
        XCTAssertEqual(NameSearch.rank(query: "item", in: entries, limit: 6).count, 6)
    }
}
