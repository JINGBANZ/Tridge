import CloudKit
import CryptoKit

/// Why the current iCloud account cannot scope a session.
///
/// `noAccount` and `restricted` are blocking states with no cache to show;
/// `couldNotDetermine` and `temporarilyUnavailable` are retryable — a cold
/// launch waits rather than guessing which account it is looking at.
enum AccountAvailability: Equatable {
    case noAccount
    case restricted
    case couldNotDetermine
    case temporarilyUnavailable

    init?(_ status: CKAccountStatus) {
        switch status {
        case .available: return nil
        case .noAccount: self = .noAccount
        case .restricted: self = .restricted
        case .temporarilyUnavailable: self = .temporarilyUnavailable
        case .couldNotDetermine: self = .couldNotDetermine
        @unknown default: self = .couldNotDetermine
        }
    }

    /// Retrying can resolve these; the other two need the user to sign in or an
    /// administrator to lift a restriction.
    var isTransient: Bool {
        self == .couldNotDetermine || self == .temporarilyUnavailable
    }
}

enum AccountIdentityError: Error {
    case unavailable(AccountAvailability)
    /// The account looked available but its user record could not be read.
    case lookupFailed(AccountAvailability)
}

/// Resolves the local scope every account-bound artifact hangs from.
protocol AccountIdentityProviding: Sendable {
    func validateCurrentAccountScope() async throws -> AccountScopeHash
}

/// Hashes the container-specific CloudKit user record name into the account
/// scope.
///
/// The raw record id never leaves this type: it is hashed immediately and only
/// the digest is returned, so nothing downstream can persist or log the identity
/// itself. The id is container-specific already, and hashing keeps a stable but
/// nonreversible scope for store paths, defaults keys, history tokens, and
/// notification prefixes.
struct CloudKitAccountIdentity: AccountIdentityProviding {
    let containerIdentifier: String

    init(containerIdentifier: String = "iCloud.com.tridge.app") {
        self.containerIdentifier = containerIdentifier
    }

    func validateCurrentAccountScope() async throws -> AccountScopeHash {
        let container = CKContainer(identifier: containerIdentifier)
        let status = try await container.accountStatus()
        if let unavailable = AccountAvailability(status) {
            throw AccountIdentityError.unavailable(unavailable)
        }

        let recordID: CKRecord.ID
        do {
            recordID = try await container.userRecordID()
        } catch {
            // An account that reported available but cannot produce its user
            // record is undetermined, not signed out: keep it retryable.
            throw AccountIdentityError.lookupFailed(.couldNotDetermine)
        }

        guard let scope = AccountScopeHash(digest: Self.digest(of: recordID.recordName)) else {
            throw AccountIdentityError.lookupFailed(.couldNotDetermine)
        }
        return scope
    }

    static func digest(of recordName: String) -> String {
        SHA256.hash(data: Data(recordName.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
