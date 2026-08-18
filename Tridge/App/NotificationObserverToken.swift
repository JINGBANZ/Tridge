import Foundation

/// Holds one block-based `NotificationCenter` observer and unregisters it when
/// released.
///
/// Block observers are not removed automatically, and an owner isolated to an
/// actor cannot unregister one from `deinit` — a nonisolated `deinit` may not
/// read its own isolated state. Keeping the token here moves that cleanup to an
/// object whose `deinit` is free to do it.
final class NotificationObserverToken: @unchecked Sendable {
    private let lock = NSLock()
    private var token: NSObjectProtocol?

    var isRegistered: Bool { lock.withLock { token != nil } }

    /// Registers a new observer, removing any it replaces.
    func register(_ makeObserver: () -> NSObjectProtocol) {
        let observer = makeObserver()
        let replaced: NSObjectProtocol? = lock.withLock {
            let previous = token
            token = observer
            return previous
        }
        remove(replaced)
    }

    func remove() {
        let observer: NSObjectProtocol? = lock.withLock {
            let previous = token
            token = nil
            return previous
        }
        remove(observer)
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }

    private func remove(_ observer: NSObjectProtocol?) {
        guard let observer else { return }
        NotificationCenter.default.removeObserver(observer)
    }
}
