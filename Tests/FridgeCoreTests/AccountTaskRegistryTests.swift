import Foundation
import XCTest
@testable import FridgeCore

/// The registry is what makes an account change safe: after it drains, no
/// admitted operation is still touching a store that is about to be removed.
final class AccountTaskRegistryTests: XCTestCase {
    private func scope() -> AccountScopeHash {
        AccountScopeHash(digest: String(repeating: "a", count: 64))!
    }

    private func context(_ generation: AccountGeneration) -> AccountSessionContext {
        AccountSessionContext(
            generationContext: AccountGenerationContext(generation: generation,
                                                        accountScope: scope()),
            privateStoreIdentifier: "private", sharedStoreIdentifier: "shared")
    }

    // MARK: - Admission

    func testWorkForTheOpenGenerationRuns() async throws {
        let registry = AccountTaskRegistry()
        let generation = AccountGeneration()
        await registry.open(generation)

        let value = try await registry.run(generation: generation) { 7 }

        XCTAssertEqual(value, 7)
    }

    func testWorkForAnotherGenerationIsRejected() async {
        let registry = AccountTaskRegistry()
        await registry.open(AccountGeneration())

        do {
            _ = try await registry.run(generation: AccountGeneration()) { 7 }
            XCTFail("a stale generation must not be admitted")
        } catch {
            XCTAssertEqual(error as? AccountTaskRegistry.Rejection, .staleGeneration)
        }
    }

    func testNothingIsAdmittedBeforeAGenerationIsOpened() async {
        let registry = AccountTaskRegistry()

        do {
            _ = try await registry.run(generation: AccountGeneration()) { 7 }
            XCTFail("admission is closed until a generation is opened")
        } catch {
            XCTAssertEqual(error as? AccountTaskRegistry.Rejection, .staleGeneration)
        }
    }

    func testALoadedStoreContextIsAdmittedByItsGeneration() async throws {
        let registry = AccountTaskRegistry()
        let generation = AccountGeneration()
        await registry.open(generation)

        let value = try await registry.run(context: context(generation)) { 9 }
        XCTAssertEqual(value, 9)

        do {
            _ = try await registry.run(context: context(AccountGeneration())) { 9 }
            XCTFail("a context from another generation must not be admitted")
        } catch {
            XCTAssertEqual(error as? AccountTaskRegistry.Rejection, .staleGeneration)
        }
    }

    func testAnOperationFailureReachesItsCaller() async {
        struct Failure: Error {}
        let registry = AccountTaskRegistry()
        let generation = AccountGeneration()
        await registry.open(generation)

        do {
            _ = try await registry.run(generation: generation) { throw Failure() }
            XCTFail("the operation's own error must not be swallowed")
        } catch {
            XCTAssertTrue(error is Failure)
        }
    }

    // MARK: - Transition

    func testDrainClosesAdmission() async {
        let registry = AccountTaskRegistry()
        let generation = AccountGeneration()
        await registry.open(generation)

        await registry.closeAndDrain()

        let current = await registry.currentGeneration
        XCTAssertNil(current)
        do {
            _ = try await registry.run(generation: generation) { 7 }
            XCTFail("the drained generation must not be readmitted")
        } catch {
            XCTAssertEqual(error as? AccountTaskRegistry.Rejection, .staleGeneration)
        }
    }

    func testTheNextAccountCanOpenItsOwnGenerationAfterADrain() async throws {
        let registry = AccountTaskRegistry()
        await registry.open(AccountGeneration())
        await registry.closeAndDrain()

        let next = AccountGeneration()
        await registry.open(next)

        let value = try await registry.run(generation: next) { 3 }
        XCTAssertEqual(value, 3)
    }

    /// The reason the registry exists: a save inside `context.perform` is not
    /// cooperative, so cancelling its task proves nothing. The drain must wait
    /// for the body itself to return before the store can be removed.
    func testDrainWaitsForWorkThatIgnoresCancellation() async {
        let registry = AccountTaskRegistry()
        let generation = AccountGeneration()
        await registry.open(generation)

        let started = AsyncFlag()
        let finished = AsyncFlag()
        let running = Task {
            try? await registry.run(generation: generation) {
                await started.set()
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                        continuation.resume()
                    }
                }
                await finished.set()
            }
        }
        await started.wait()

        await registry.closeAndDrain()

        let didFinish = await finished.isSet
        XCTAssertTrue(didFinish, "the drain returned while a save was still running")
        _ = await running.value
    }

    func testDrainCancelsCooperativeWork() async {
        let registry = AccountTaskRegistry()
        let generation = AccountGeneration()
        await registry.open(generation)

        let started = AsyncFlag()
        let observedCancellation = AsyncFlag()
        let running = Task {
            try? await registry.run(generation: generation) {
                await started.set()
                // Returns as soon as the drain cancels; otherwise the test
                // fails by timing out rather than by passing slowly.
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if Task.isCancelled { await observedCancellation.set() }
            }
        }
        await started.wait()

        await registry.closeAndDrain()

        let didObserveCancellation = await observedCancellation.isSet
        XCTAssertTrue(didObserveCancellation)
        _ = await running.value
    }

    func testDrainWaitsForEveryRegisteredOperation() async {
        let registry = AccountTaskRegistry()
        let generation = AccountGeneration()
        await registry.open(generation)

        let counter = AsyncCounter()
        var running: [Task<Void, Never>] = []
        for _ in 0..<5 {
            let started = AsyncFlag()
            running.append(Task {
                try? await registry.run(generation: generation) {
                    await started.set()
                    await withCheckedContinuation { continuation in
                        DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) {
                            continuation.resume()
                        }
                    }
                    await counter.increment()
                }
            })
            await started.wait()
        }

        await registry.closeAndDrain()

        let completed = await counter.value
        XCTAssertEqual(completed, 5)
        for task in running { _ = await task.value }
    }
}

/// A one-shot signal that lets a test wait until an operation has actually been
/// admitted, so the drain cannot race ahead of registration.
private actor AsyncFlag {
    private var value = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isSet: Bool { value }

    func set() {
        guard !value else { return }
        value = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }

    func wait() async {
        guard !value else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor AsyncCounter {
    private(set) var value = 0

    func increment() { value += 1 }
}
