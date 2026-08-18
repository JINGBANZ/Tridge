import CloudKit
import CoreData

/// The compiled Core Data model, loaded once. Entities name their Objective-C
/// classes explicitly (`@objc(HouseholdRecord)`), so the lookup does not depend
/// on the Swift module name.
enum TridgeModel {
    static let name = "TridgeModel"

    static let managedObjectModel: NSManagedObjectModel = {
        // The model ships in whichever bundle the record classes ship in, which
        // is the app bundle both at runtime and under the hosted test target.
        guard let url = Bundle(for: HouseholdRecord.self).url(forResource: name, withExtension: "momd"),
              let model = NSManagedObjectModel(contentsOf: url)
        else {
            preconditionFailure("\(name).momd is missing from the app bundle")
        }
        return model
    }()
}

/// One account's complete persistence stack: the private store for Households
/// this account owns, the shared store for Households that arrived through
/// someone else's share, and the contexts confined to them.
///
/// The stack is ready only after **both** stores load. A partial private-only
/// stack is never handed to the UI, because a command routed to the wrong store
/// would be invisible to the Household it was meant for. Failure is reported,
/// not fatal: `LaunchState` offers Retry with a content-free diagnostic id.
final class PersistenceController {
    /// Everything the stack needs to open one account's stores.
    struct Configuration {
        let accountScope: AccountScopeHash
        /// Nil disables CloudKit mirroring, which is how model and routing tests
        /// run both stores without an iCloud account.
        let cloudKitContainerIdentifier: String?
        /// Application Support at runtime; a temporary directory in tests.
        let baseDirectory: URL

        static func cloudKit(accountScope: AccountScopeHash,
                             baseDirectory: URL) -> Configuration {
            Configuration(accountScope: accountScope,
                          cloudKitContainerIdentifier: "iCloud.com.tridge.app",
                          baseDirectory: baseDirectory)
        }

        static func localOnly(accountScope: AccountScopeHash,
                              baseDirectory: URL) -> Configuration {
            Configuration(accountScope: accountScope, cloudKitContainerIdentifier: nil,
                          baseDirectory: baseDirectory)
        }
    }

    /// One or both stores could not be opened. Retryable, and the id is
    /// content-free — an error domain and code, never a path or a record.
    struct LoadError: Error, Equatable {
        let diagnosticID: String
    }

    let container: NSPersistentCloudKitContainer
    let privateStore: NSPersistentStore
    let sharedStore: NSPersistentStore

    /// Main-queue and read-only by contract: SwiftUI reads value snapshots built
    /// from it and never mutates a managed object.
    var viewContext: NSManagedObjectContext { container.viewContext }

    /// The two loaded store identifiers, which scope this account session's sync
    /// events and history tokens.
    var storeIdentifiers: Set<String> {
        [privateStore.identifier, sharedStore.identifier]
    }

    private init(container: NSPersistentCloudKitContainer,
                 privateStore: NSPersistentStore,
                 sharedStore: NSPersistentStore) {
        self.container = container
        self.privateStore = privateStore
        self.sharedStore = sharedStore

        let viewContext = container.viewContext
        viewContext.name = "view"
        viewContext.automaticallyMergesChangesFromParent = true
        viewContext.mergePolicy = NSMergePolicy(merge: .mergeByPropertyStoreTrumpMergePolicyType)
    }

    // MARK: - Launch

    static func load(configuration: Configuration) async throws -> PersistenceController {
        let directory = try accountDirectory(for: configuration)
        let privateURL = directory
            .appendingPathComponent(HouseholdDatabaseScope.privateDatabase.storeFileName)
        let sharedURL = directory
            .appendingPathComponent(HouseholdDatabaseScope.sharedDatabase.storeFileName)

        let container = NSPersistentCloudKitContainer(
            name: TridgeModel.name, managedObjectModel: TridgeModel.managedObjectModel)
        container.persistentStoreDescriptions = [
            description(at: privateURL, scope: .privateDatabase, configuration: configuration),
            description(at: sharedURL, scope: .sharedDatabase, configuration: configuration),
        ]

        let failures = await loadStores(in: container)
        let coordinator = container.persistentStoreCoordinator
        guard failures.isEmpty,
              let privateStore = coordinator.persistentStore(for: privateURL),
              let sharedStore = coordinator.persistentStore(for: sharedURL)
        else {
            // A half-open stack would hold its files against the retry.
            remove(loadedStoresOf: container)
            throw LoadError(diagnosticID: diagnosticID(for: failures.first))
        }

        return PersistenceController(container: container, privateStore: privateStore,
                                     sharedStore: sharedStore)
    }

    /// Releases both stores so a retry — or the next account — can open its own.
    /// The files stay on disk: an account transition never deletes either
    /// account's directory.
    func tearDown() {
        Self.remove(loadedStoresOf: container)
    }

    private static func accountDirectory(for configuration: Configuration) throws -> URL {
        let directory = configuration.accountScope.accountDirectoryComponents
            .reduce(configuration.baseDirectory) { $0.appendingPathComponent($1, isDirectory: true) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func description(at url: URL, scope: HouseholdDatabaseScope,
                                    configuration: Configuration) -> NSPersistentStoreDescription {
        let description = NSPersistentStoreDescription(url: url)
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber,
                              forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        // Background imports must be able to run after the first unlock without
        // leaving the file readable while the device is locked.
        description.setOption(
            FileProtectionType.completeUntilFirstUserAuthentication.rawValue as NSString,
            forKey: NSPersistentStoreFileProtectionKey)
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true

        if let identifier = configuration.cloudKitContainerIdentifier {
            let options = NSPersistentCloudKitContainerOptions(containerIdentifier: identifier)
            options.databaseScope = scope.cloudKitDatabaseScope
            description.cloudKitContainerOptions = options
        } else {
            description.cloudKitContainerOptions = nil
        }
        return description
    }

    /// `loadPersistentStores` calls its handler once per description. The caller
    /// resumes only after the last one, so no code can observe a single store.
    private static func loadStores(in container: NSPersistentCloudKitContainer) async -> [Error] {
        let expected = container.persistentStoreDescriptions.count
        return await withCheckedContinuation { continuation in
            let collector = StoreLoadCollector(expecting: expected, continuation: continuation)
            container.loadPersistentStores { _, error in
                collector.record(error)
            }
        }
    }

    private static func remove(loadedStoresOf container: NSPersistentContainer) {
        let coordinator = container.persistentStoreCoordinator
        for store in coordinator.persistentStores {
            try? coordinator.remove(store)
        }
    }

    private static func diagnosticID(for error: Error?) -> String {
        guard let error else { return "store.unresolved" }
        let details = error as NSError
        return "\(details.domain).\(details.code)"
    }

    // MARK: - Store routing

    func store(for scope: HouseholdDatabaseScope) -> NSPersistentStore {
        switch scope {
        case .privateDatabase: privateStore
        case .sharedDatabase: sharedStore
        }
    }

    func scope(of store: NSPersistentStore) -> HouseholdDatabaseScope? {
        if store === privateStore { return .privateDatabase }
        if store === sharedStore { return .sharedDatabase }
        return nil
    }

    /// A Household's store is the authority on ownership — private means owned,
    /// shared means received. Optional participant fields are never consulted.
    func ownership(of household: HouseholdRecord) -> HouseholdOwnership? {
        guard let store = StoreRouting.store(of: household), let scope = scope(of: store) else {
            return nil
        }
        return scope == .privateDatabase ? .owned : .received
    }

    // MARK: - Contexts

    /// Creates a writer for repository commands: serial, private-queue, and
    /// tagged so its transactions can be told apart from imports in history.
    func newWriterContext() -> NSManagedObjectContext {
        writerContext(author: "app.inventory")
    }

    /// Duplicate reconciliation writes its permanent claims on its own context
    /// with its own author, so history processing can recognize its own work.
    func newReconcilerContext() -> NSManagedObjectContext {
        writerContext(author: "app.reconcile")
    }

    private func writerContext(author: String) -> NSManagedObjectContext {
        let context = container.newBackgroundContext()
        context.name = author
        context.transactionAuthor = author
        context.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
        return context
    }
}

/// Collects both `loadPersistentStores` callbacks and resumes the awaiting
/// caller exactly once.
private final class StoreLoadCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var failures: [Error] = []
    private var continuation: CheckedContinuation<[Error], Never>?

    init(expecting count: Int, continuation: CheckedContinuation<[Error], Never>) {
        self.remaining = count
        self.continuation = continuation
    }

    func record(_ error: Error?) {
        lock.lock()
        if let error { failures.append(error) }
        remaining -= 1
        let collected = failures
        let finished = remaining <= 0
        let continuation = finished ? self.continuation : nil
        if finished { self.continuation = nil }
        lock.unlock()

        continuation?.resume(returning: collected)
    }
}

extension HouseholdDatabaseScope {
    var cloudKitDatabaseScope: CKDatabase.Scope {
        switch self {
        case .privateDatabase: .private
        case .sharedDatabase: .shared
        }
    }
}

enum StoreRoutingError: Error, Equatable {
    /// A relationship endpoint lives in another persistent store. CloudKit could
    /// never mirror it, and Core Data raises an Objective-C exception at save
    /// time that Swift cannot catch — so the command fails first.
    case crossStoreRelationship
}

/// Assignment and cross-store checks for the objects a command inserts or links.
enum StoreRouting {
    /// The store an object already belongs to; nil while it is only inserted and
    /// has no permanent id yet.
    static func store(of object: NSManagedObject) -> NSPersistentStore? {
        object.objectID.isTemporaryID ? nil : object.objectID.persistentStore
    }

    /// Routes every newly inserted object to the Household's resolved store. A
    /// member-created child is assigned to the shared store explicitly; nothing
    /// relies on Core Data picking a default.
    static func assign(_ objects: [NSManagedObject], to store: NSPersistentStore,
                       in context: NSManagedObjectContext) {
        for object in objects where object.objectID.isTemporaryID {
            context.assign(object, to: store)
        }
    }

    /// Fails the command when any already-persisted object lives somewhere else.
    static func validate(_ objects: [NSManagedObject], belongTo store: NSPersistentStore) throws {
        for object in objects {
            if let existing = Self.store(of: object), existing !== store {
                throw StoreRoutingError.crossStoreRelationship
            }
        }
    }
}
