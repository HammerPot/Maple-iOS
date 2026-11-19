import UIKit

/// Keeps the process alive long enough to finish a catalog write when the app is moving to the
/// background. Without it, iOS may suspend Maple between "playlist saved" and the disk write.
@MainActor
final class LibraryBackgroundAssertion {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    static func begin(_ name: String) -> LibraryBackgroundAssertion {
        let assertion = LibraryBackgroundAssertion()
        assertion.identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak assertion] in
            // UIKit invokes expiration handlers on the main thread. End synchronously before returning.
            MainActor.assumeIsolated { assertion?.end() }
        }
        return assertion
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

/// First-in-first-out mutual exclusion across `await`s, on the main actor. Creating a
/// content-addressed file and deciding whether it may be deleted both run under it, so a file
/// can never be deleted between being written and being referenced.
@MainActor
final class LibraryFileLock {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T>(_ body: () async throws -> T) async rethrows -> T {
        if locked { await withCheckedContinuation { waiters.append($0) } } else { locked = true }
        defer {
            if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() }
        }
        return try await body()
    }
}
