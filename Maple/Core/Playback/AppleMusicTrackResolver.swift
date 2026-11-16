import Foundation

/// Both namespaces survive persistence. Older checkpoints have no provenance and try both lookups.
struct AppleMusicIdentity: Codable, Hashable, Sendable {
    var libraryID: String?
    var catalogID: String?
}

@MainActor final class AppleMusicTrackResolver<Value> {
    private var cache: [String: Value] = [:]
    private let library: (String) async throws -> Value?
    private let catalog: (String) async throws -> Value?
    init(library: @escaping (String) async throws -> Value?, catalog: @escaping (String) async throws -> Value?) {
        self.library = library; self.catalog = catalog
    }
    func register(_ value: Value, id: String) { cache[id] = value }
    func resolve(_ item: PlaybackItem) async throws -> Value {
        if let cached = cache[item.id] { return cached }
        let identity = item.appleMusicIdentity
        var lookups: [(String, (String) async throws -> Value?)] = []
        if let id = identity?.libraryID ?? (identity == nil ? item.id : nil) { lookups.append((id, library)) }
        if let id = identity?.catalogID ?? (identity == nil ? item.id : nil) { lookups.append((id, catalog)) }
        var lastError: Error?
        for (id, lookup) in lookups {
            do {
                let value = try await lookup(id)
                try Task.checkCancellation()
                if let value { cache[item.id] = value; return value }
            } catch is CancellationError { throw CancellationError() }
            catch { lastError = error }
        }
        throw lastError ?? MapleError(status: 0, message: "This Apple Music track is no longer available.")
    }
    /// Resolve the selected occurrence first. Missing neighbors are pruned, never made fatal to it.
    func context(_ entries: [PlaybackEntry], selected: UUID) async throws -> (values: [(PlaybackEntry, Value)], unavailable: Set<UUID>) {
        guard let current = entries.first(where: { $0.id == selected }) else { throw CancellationError() }
        let selectedValue = try await resolve(current.item)
        var values: [(PlaybackEntry, Value)] = [], unavailable: Set<UUID> = []
        for entry in entries {
            if entry.id == selected { values.append((entry, selectedValue)); continue }
            do { values.append((entry, try await resolve(entry.item))) }
            catch is CancellationError { throw CancellationError() }
            catch { unavailable.insert(entry.id) }
        }
        return (values, unavailable)
    }
}
