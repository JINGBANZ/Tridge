import CloudKit
import XCTest
@testable import Tridge

/// The capabilities sharing depends on are build settings, so nothing in the
/// Swift sources fails when one goes missing. These read the built app bundle
/// instead.
final class AppCapabilitiesTests: XCTestCase {
    private var app: Bundle { Bundle(for: HouseholdRecord.self) }

    func testTheAppAcceptsShareInvitationsAndWakesForRemoteChanges() {
        // Both come from Tridge-Info.plist: Xcode's INFOPLIST_KEY_ settings drop
        // keys outside its own table, and a string "YES" would not register the
        // app as a share target either.
        XCTAssertEqual(app.object(forInfoDictionaryKey: "CKSharingSupported") as? Bool, true)
        XCTAssertEqual(app.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String],
                       ["remote-notification"])
    }

    func testTheGeneratedInfoPlistKeysSurviveTheMerge() {
        // Adding a partial Info.plist must not displace what the build settings
        // still generate.
        XCTAssertNotNil(app.object(forInfoDictionaryKey: "NSCameraUsageDescription"))
        XCTAssertNotNil(app.object(forInfoDictionaryKey: "UILaunchScreen"))
    }

    func testTheDeploymentTargetStaysAtIOS18UnderTheNewerSDK() {
        XCTAssertEqual(app.object(forInfoDictionaryKey: "MinimumOSVersion") as? String, "18.0")
    }

    func testTheCompiledModelShipsInTheAppBundle() {
        XCTAssertNotNil(app.url(forResource: TridgeModel.name, withExtension: "momd"))
    }
}

/// The account scope is the hash of the container-specific user record name, and
/// the raw identity never leaves `CloudKitAccountIdentity`.
final class AccountIdentityTests: XCTestCase {
    func testARecordNameHashesToOneCanonicalScope() throws {
        let digest = CloudKitAccountIdentity.digest(of: "_abc123")
        let scope = try XCTUnwrap(AccountScopeHash(digest: digest))

        XCTAssertEqual(digest, CloudKitAccountIdentity.digest(of: "_abc123"))
        XCTAssertFalse(scope.value.contains("_abc123"))
        XCTAssertNotEqual(digest, CloudKitAccountIdentity.digest(of: "_abc124"))
    }

    func testOnlyAnAvailableAccountProducesNoAvailabilityProblem() {
        XCTAssertNil(AccountAvailability(.available))
        XCTAssertEqual(AccountAvailability(.noAccount), .noAccount)
        XCTAssertEqual(AccountAvailability(.restricted), .restricted)
        XCTAssertEqual(AccountAvailability(.couldNotDetermine), .couldNotDetermine)
        XCTAssertEqual(AccountAvailability(.temporarilyUnavailable), .temporarilyUnavailable)
    }

    func testOnlyUndeterminedAccountsRetry() {
        // Signed out or restricted needs the user or an administrator; the other
        // two resolve by asking again.
        XCTAssertFalse(LaunchState(accountError: .unavailable(.noAccount)).isRetryable)
        XCTAssertFalse(LaunchState(accountError: .unavailable(.restricted)).isRetryable)
        XCTAssertTrue(LaunchState(accountError: .unavailable(.temporarilyUnavailable)).isRetryable)
        XCTAssertTrue(LaunchState(accountError: .lookupFailed(.couldNotDetermine)).isRetryable)
        XCTAssertEqual(LaunchState(accountError: .unavailable(.noAccount)),
                       .iCloudAccountRequired(.noAccount))
    }
}
