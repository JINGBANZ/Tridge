import Foundation
import XCTest
@testable import Tridge

/// Test doubles shared by the account-session and upgrade suites, so both drive
/// the coordinator through the same seams the app uses.
final class FakeAccountIdentity: AccountIdentityProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _result: Result<AccountScopeHash, Error>

    init(result: Result<AccountScopeHash, Error>) {
        self._result = result
    }

    var result: Result<AccountScopeHash, Error> {
        get { lock.withLock { _result } }
        set { lock.withLock { _result = newValue } }
    }

    func validateCurrentAccountScope() async throws -> AccountScopeHash {
        try result.get()
    }
}

/// Opens real local-only stacks so store identifiers, routing, and teardown are
/// the production ones, while letting a test hold the load open or fail it.
final class StackLoader: @unchecked Sendable {
    private let lock = NSLock()
    private let baseDirectory: URL
    private var _controllers: [PersistenceController] = []

    private var _gate: (@Sendable () async -> Void)?
    private var _failure: Error?

    init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    /// Loads run off the main actor while the test mutates these from it, so
    /// both cross the same lock as `_controllers`.
    var gate: (@Sendable () async -> Void)? {
        get { lock.withLock { _gate } }
        set { lock.withLock { _gate = newValue } }
    }

    var failure: Error? {
        get { lock.withLock { _failure } }
        set { lock.withLock { _failure = newValue } }
    }

    var controllers: [PersistenceController] { lock.withLock { _controllers } }

    var closure: @Sendable (AccountScopeHash) async throws -> PersistenceController {
        { [self] scope in try await load(scope) }
    }

    func tearDownAll() {
        for controller in controllers { controller.tearDown() }
    }

    private func load(_ scope: AccountScopeHash) async throws -> PersistenceController {
        if let gate { await gate() }
        if let failure { throw failure }
        let controller = try await PersistenceController.load(
            configuration: .localOnly(accountScope: scope, baseDirectory: baseDirectory))
        lock.withLock { _controllers.append(controller) }
        return controller
    }
}

extension XCTestCase {
    /// Polls until `condition` holds, for the coordinator work that settles
    /// after the call that started it has already returned.
    @MainActor
    func waitUntil(_ description: String, _ condition: @MainActor () -> Bool,
                   file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<400 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("timed out waiting for \(description)", file: file, line: line)
    }
}
