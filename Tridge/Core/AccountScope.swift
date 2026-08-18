import Foundation

/// Which CloudKit database a household's records live in. The pair is fixed:
/// one private store for households this account owns, one shared store for
/// households that arrived through someone else's share.
public enum HouseholdDatabaseScope: String, CaseIterable, Sendable {
    case privateDatabase = "private"
    case sharedDatabase = "shared"

    /// The store's file name inside the account directory.
    public var storeFileName: String { "\(rawValue).sqlite" }
}

/// The local scope every account-bound artifact hangs from: store paths, the
/// active-household id, history tokens, notification prefixes, and sharing
/// transition state.
///
/// It is the SHA-256 digest of the container-specific CloudKit user record
/// name, hashed by the caller (CryptoKit is unavailable to this Linux-testable
/// module). Construction is the enforcement point for the contract's rule that
/// the raw record id is never persisted or logged: only a canonical 64-character
/// lowercase digest can become a scope, so a record name — or a path fragment
/// like `../..` — cannot reach the file system or `UserDefaults`.
public struct AccountScopeHash: Hashable, Sendable {
    public let value: String

    public init?(digest: String) {
        guard digest.count == 64,
              digest.allSatisfy({ $0.isNumber || ("a"..."f").contains($0) })
        else { return nil }
        self.value = digest
    }

    /// `Application Support/HouseholdSharing/Accounts/<hash>`, relative to
    /// Application Support.
    public var accountDirectoryComponents: [String] {
        ["HouseholdSharing", "Accounts", value]
    }

    public func storePathComponents(for scope: HouseholdDatabaseScope) -> [String] {
        accountDirectoryComponents + [scope.storeFileName]
    }

    /// A `UserDefaults` key that cannot collide with another account's, so
    /// signing into a second account never reads the first one's selection.
    public func defaultsKey(_ name: String) -> String {
        "household.\(value).\(name)"
    }
}
