/// What the app shows until Inventory is usable.
///
/// Every failure here is a state, never a `fatalError`: a store that will not
/// open, or an account that cannot be checked yet, leaves the user on a Retry
/// screen rather than crashing the app. A cold launch never shows a cached
/// account's inventory before the current identity is validated.
enum LaunchState: Equatable {
    /// Validating the iCloud account and opening both stores.
    case preparing
    /// No usable iCloud account. Blocking, and nothing local is shown.
    case iCloudAccountRequired(AccountAvailability)
    /// Neither store is exposed. The id is content-free and safe to quote in a
    /// support report.
    case persistenceUnavailable(diagnosticID: String)
    /// Both stores opened, but this account's cache is empty and its first
    /// CloudKit import has not succeeded yet. Creating `My Fridge` now would
    /// duplicate a household that is still arriving.
    ///
    /// Like `preparing`, this clears itself: the container keeps importing and
    /// the coordinator is already waiting on the barrier. It is deliberately
    /// not `isRetryable`, because restarting would tear down stores that
    /// opened fine and discard a setup that already succeeded.
    case finishingCloudSetup
    case ready

    init(accountError: AccountIdentityError) {
        switch accountError {
        case .unavailable(let availability), .lookupFailed(let availability):
            self = .iCloudAccountRequired(availability)
        }
    }

    init(loadError: PersistenceController.LoadError) {
        self = .persistenceUnavailable(diagnosticID: loadError.diagnosticID)
    }

    /// Whether the state resolves by trying again — automatically or through
    /// the Retry control — rather than needing the user to sign in.
    var isRetryable: Bool {
        switch self {
        case .preparing, .finishingCloudSetup, .ready: false
        case .iCloudAccountRequired(let availability): availability.isTransient
        case .persistenceUnavailable: true
        }
    }
}
