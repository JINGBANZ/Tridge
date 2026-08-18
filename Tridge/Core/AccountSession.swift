import Foundation

/// One attempt at running an iCloud account's session. The value is never
/// reused, so work that was already in flight when the account changed can be
/// recognized as belonging to the previous attempt and dropped instead of
/// applying to the current one.
public struct AccountGeneration: Hashable, Sendable {
    public let id: UUID

    public init() {
        self.id = UUID()
    }

    /// Only for tests that need two comparable generations; production code
    /// always mints a fresh one.
    public init(id: UUID) {
        self.id = id
    }
}

/// What work started *before* the stores exist can know: which account, and
/// which attempt at it. Account validation, store construction, and store
/// loading itself all run under this context.
public struct AccountGenerationContext: Hashable, Sendable {
    public let generation: AccountGeneration
    public let accountScope: AccountScopeHash

    public init(generation: AccountGeneration = AccountGeneration(),
                accountScope: AccountScopeHash) {
        self.generation = generation
        self.accountScope = accountScope
    }
}

/// What work against loaded stores knows: the generation context plus the two
/// store identifiers that were actually opened for it.
///
/// Sync events and history tokens are scoped by these identifiers, so a
/// completion belonging to another account's store — or to a store this
/// account opened in an earlier attempt — can never be mistaken for this
/// session's.
public struct AccountSessionContext: Hashable, Sendable {
    public let generationContext: AccountGenerationContext
    public let privateStoreIdentifier: String
    public let sharedStoreIdentifier: String

    public init(generationContext: AccountGenerationContext,
                privateStoreIdentifier: String,
                sharedStoreIdentifier: String) {
        self.generationContext = generationContext
        self.privateStoreIdentifier = privateStoreIdentifier
        self.sharedStoreIdentifier = sharedStoreIdentifier
    }

    public var generation: AccountGeneration { generationContext.generation }
    public var accountScope: AccountScopeHash { generationContext.accountScope }

    public var storeIdentifiers: Set<String> {
        [privateStoreIdentifier, sharedStoreIdentifier]
    }
}
