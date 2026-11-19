import Foundation

/// MusicKit's remote prepare call ignores cancellation and can reset a later queue.
/// Serialize only that native operation; cancelled resolution never enters this lane.
@MainActor final class AppleMusicPreparation {
    private var tail: Task<Void, Never>?

    func run<Value: Sendable>(_ operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            try Task.checkCancellation()
            return try await operation()
        }
        tail = Task { _ = try? await task.value }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
