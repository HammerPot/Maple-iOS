import OSLog
import UIKit

/// A short assertion for finishing an already-started native queue fill, never background audio.
@MainActor final class AppleMusicFillAssertion {
    typealias Begin = @MainActor (@escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier
    private let begin: Begin
    private let finish: @MainActor (UIBackgroundTaskIdentifier) -> Void
    private var identifier = UIBackgroundTaskIdentifier.invalid
    private var generation = 0
    private(set) var expired = false

    init(begin: @escaping Begin = { UIApplication.shared.beginBackgroundTask(withName: "Finish Apple Music queue", expirationHandler: $0) },
         end: @escaping @MainActor (UIBackgroundTaskIdentifier) -> Void = { UIApplication.shared.endBackgroundTask($0) }) {
        self.begin = begin; self.finish = end
    }
    func start(generation: Int, onExpiration: @escaping @MainActor () -> Void) -> Bool {
        self.generation = generation
        identifier = begin { [weak self] in
            guard let self, self.identifier != .invalid else { return }
            self.expired = true
            onExpiration()
            self.end(reason: "expiration")
        }
        AppleMusicDiagnostics.logger.info("fill assertion begin generation=\(generation, privacy: .public) id=\(self.identifier.rawValue, privacy: .public) granted=\(self.identifier != .invalid, privacy: .public)")
        return identifier != .invalid
    }
    func end(reason: String) {
        guard identifier != .invalid else { return }
        let previous = identifier
        identifier = .invalid
        finish(previous)
        AppleMusicDiagnostics.logger.info("fill assertion end generation=\(self.generation, privacy: .public) id=\(previous.rawValue, privacy: .public) reason=\(reason, privacy: .public)")
    }
}
