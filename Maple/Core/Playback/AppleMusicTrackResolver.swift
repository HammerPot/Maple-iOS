import Foundation

/// Both namespaces survive persistence. Older checkpoints have no provenance and try both lookups.
struct AppleMusicIdentity: Codable, Hashable, Sendable {
    var libraryID: String?
    var catalogID: String?
}

enum AppleMusicResolutionError: Error { case notFound }

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
        throw lastError ?? AppleMusicResolutionError.notFound
    }
    /// Selected plus a bounded forward window. Audio startup never scans a whole saved library.
    func context(_ entries: [PlaybackEntry], selected: UUID, limit: Int = 11) async throws -> (values: [(PlaybackEntry, Value)], unavailable: Set<UUID>, deferred: Set<UUID>, remaining: [PlaybackEntry]) {
        guard let index = entries.firstIndex(where: { $0.id == selected }) else { throw CancellationError() }
        let window = Array(entries.dropFirst(index).prefix(max(1, limit)))
        let result = try await resolveBatch(window, requireFirst: true)
        return (result.values, result.unavailable, result.deferred, Array(entries.dropFirst(index + window.count)))
    }
    func resolveBatch(_ entries: [PlaybackEntry], requireFirst: Bool = false) async throws -> (values: [(PlaybackEntry, Value)], unavailable: Set<UUID>, deferred: Set<UUID>) {
        var values: [(PlaybackEntry, Value)] = [], unavailable: Set<UUID> = [], deferred: Set<UUID> = []
        for (index, entry) in entries.enumerated() {
            do { values.append((entry, try await resolve(entry.item))) }
            catch is CancellationError { throw CancellationError() }
            catch {
                if requireFirst && index == 0 { throw error }
                if case AppleMusicResolutionError.notFound = error { unavailable.insert(entry.id) }
                else { deferred.insert(entry.id) }
            }
        }
        return (values, unavailable, deferred)
    }
}
