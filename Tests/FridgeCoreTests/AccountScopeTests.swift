import XCTest
@testable import FridgeCore

final class AccountScopeTests: XCTestCase {
    private let digest = String(repeating: "ab", count: 32)

    func testAValidLowercaseDigestIsAccepted() {
        XCTAssertEqual(AccountScopeHash(digest: digest)?.value, digest)
    }

    func testAnUppercaseOrShortOrNonHexDigestIsRejected() {
        // The hash is a path component and a defaults-key component, so anything
        // that is not one canonical 64-character digest is refused rather than
        // sanitized.
        XCTAssertNil(AccountScopeHash(digest: digest.uppercased()))
        XCTAssertNil(AccountScopeHash(digest: String(digest.dropLast())))
        XCTAssertNil(AccountScopeHash(digest: digest + "cd"))
        XCTAssertNil(AccountScopeHash(digest: ""))
        XCTAssertNil(AccountScopeHash(digest: String(repeating: "g", count: 64)))
        // Unicode digits are numbers too, and they are not hexadecimal.
        XCTAssertNil(AccountScopeHash(digest: String(repeating: "٣", count: 64)))
        XCTAssertNil(AccountScopeHash(digest: String(repeating: "½", count: 64)))
    }

    func testARawCloudKitRecordNameCanNeverBecomeAScope() {
        // The record id is hashed by the caller; the raw value never reaches a
        // store path (wiki/household-sharing.md → "Store setup").
        XCTAssertNil(AccountScopeHash(digest: "_1a2b3c4d5e6f7890"))
        XCTAssertNil(AccountScopeHash(digest: "../../escape"))
    }

    func testTheStorePathIsAccountScopedAndPerDatabaseScope() {
        let scope = AccountScopeHash(digest: digest)!
        XCTAssertEqual(scope.storePathComponents(for: .privateDatabase),
                       ["HouseholdSharing", "Accounts", digest, "private.sqlite"])
        XCTAssertEqual(scope.storePathComponents(for: .sharedDatabase),
                       ["HouseholdSharing", "Accounts", digest, "shared.sqlite"])
        XCTAssertEqual(scope.accountDirectoryComponents,
                       ["HouseholdSharing", "Accounts", digest])
    }

    func testTwoAccountsNeverShareAPathOrADefaultsKey() {
        let first = AccountScopeHash(digest: String(repeating: "1", count: 64))!
        let second = AccountScopeHash(digest: String(repeating: "2", count: 64))!
        XCTAssertNotEqual(first.storePathComponents(for: .privateDatabase),
                          second.storePathComponents(for: .privateDatabase))
        XCTAssertNotEqual(first.defaultsKey("activeHouseholdID"),
                          second.defaultsKey("activeHouseholdID"))
    }

    func testADefaultsKeyIsNamespacedAndStable() {
        let scope = AccountScopeHash(digest: digest)!
        XCTAssertEqual(scope.defaultsKey("activeHouseholdID"),
                       "household.\(digest).activeHouseholdID")
    }
}
