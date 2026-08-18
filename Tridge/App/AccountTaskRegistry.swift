import Foundation

/// Admits account-bound work for exactly one generation and guarantees that
/// every admitted operation has actually returned before its stores are torn
/// down.
///
/// Cancellation alone is not enough: a repository save inside `context.perform`
/// keeps running after its task is cancelled, and removing the store underneath
/// it would fault. So the transition cancels cooperative work and then *awaits*
/// every registered operation. Call sites never launch account-bound `Task`
/// work outside this registry — an unregistered task is invisible to the drain.
public actor AccountTaskRegistry {
    /// The supplied generation is no longer the open one: the account changed,
    /// or the session was torn down, while this call was being made.
    public enum Rejection: Error, Equatable {
        case staleGeneration
    }

    /// A registered child, type-erased so operations returning different values
    /// can share one table.
    private struct Registration {
        let cancel: @Sendable () -> Void
        let drain: @Sendable () async -> Void
    }

    private var openGeneration: AccountGeneration?
    private var registrations: [UUID: Registration] = [:]

    public init() {}

    public var currentGeneration: AccountGeneration? { openGeneration }

    /// Opens admission for a new generation. The caller drains the previous one
    /// first; a generation is never reopened.
    public func open(_ generation: AccountGeneration) {
        openGeneration = generation
    }

    /// Runs pre-load work — account validation, store construction, the dual
    /// `loadPersistentStores` call — which has a generation but no stores yet.
    public func run<T: Sendable>(
        generation: AccountGeneration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard openGeneration == generation else { throw Rejection.staleGeneration }
        return try await register(operation)
    }

    /// Runs work against loaded stores: repository commands, persistent
    /// history, reconciliation, sharing, reminder refreshes.
    public func run<T: Sendable>(
        context: AccountSessionContext,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await run(generation: context.generation, operation: operation)
    }

    /// Closes admission and invalidates the generation. Nothing new can be
    /// admitted from here on, which is what lets the coordinator clear the UI
    /// before it starts waiting.
    public func close() {
        openGeneration = nil
    }

    /// Cancels every registered child and waits for all of them to return.
    /// Cancellation alone would not be enough — a `context.perform` body keeps
    /// running — so this awaits the operations themselves.
    public func cancelAndDrain() async {
        let children = registrations.values
        for child in children { child.cancel() }

        for child in children { await child.drain() }
    }

    /// The whole transition in one call, for callers with nothing to do in
    /// between.
    public func closeAndDrain() async {
        close()
        await cancelAndDrain()
    }

    private func register<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let id = UUID()
        let task = Task<T, Error> { try await operation() }
        // Recorded before the first suspension point, so a drain running
        // concurrently cannot miss a task that has already started.
        registrations[id] = Registration(cancel: { task.cancel() },
                                         drain: { _ = try? await task.value })
        defer { registrations[id] = nil }
        return try await task.value
    }
}
