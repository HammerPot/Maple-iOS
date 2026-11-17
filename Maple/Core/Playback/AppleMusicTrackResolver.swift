import Foundation
import OSLog

struct AppleMusicIdentity: Codable, Hashable, Sendable {
    var libraryID: String?
    var catalogID: String?
}
extension PlaybackItem {
    var musicIdentityIDs: Set<String> { Set([id, appleMusicIdentity?.libraryID, appleMusicIdentity?.catalogID].compactMap { $0 }) }
}
enum AppleMusicResolutionError: LocalizedError {
    case notFound
    var errorDescription: String? { "This Apple Music track is no longer available." }
}

/// Complete segments, with bounded bulk requests rather than one round trip per song.
@MainActor final class AppleMusicTrackResolver<Value> {
    private var cache: [String: Value] = [:]
    private let library: ([String]) async throws -> [String: Value]
    private let catalog: ([String]) async throws -> [String: Value]
    private let identities: (Value) -> Set<String>
    init(library: @escaping ([String]) async throws -> [String: Value],
         catalog: @escaping ([String]) async throws -> [String: Value],
         identities: @escaping (Value) -> Set<String> = { _ in [] }) {
        self.library = library; self.catalog = catalog; self.identities = identities
    }
    func register(_ value: Value, id: String) {
        for key in identities(value).union([id]) { cache[key] = value }
    }
    private func cached(_ item: PlaybackItem) -> Value? { item.musicIdentityIDs.compactMap { cache[$0] }.first }
    func resolve(_ item: PlaybackItem) async throws -> Value {
        let entry = PlaybackEntry(item: item)
        let result = try await context([entry], selected: entry.id)
        guard let value = result.values.first?.1 else { throw AppleMusicResolutionError.notFound }
        return value
    }
    func context(_ entries: [PlaybackEntry], selected: UUID,
                 progress: (Double) -> Void = { _ in }) async throws -> (values: [(PlaybackEntry, Value)], unavailable: Set<UUID>) {
        guard entries.contains(where: { $0.id == selected }) else { throw CancellationError() }
        let uncached = entries.filter { cached($0.item) == nil }
        var unavailable: Set<UUID> = []
        progress(Double(entries.count - uncached.count) / Double(max(1, entries.count)))
        for offset in stride(from: 0, to: uncached.count, by: 100) {
            let batch = Array(uncached.dropFirst(offset).prefix(100))
            func libraryID(_ item: PlaybackItem) -> String? { item.appleMusicIdentity?.libraryID ?? (item.appleMusicIdentity == nil ? item.id : nil) }
            func catalogID(_ item: PlaybackItem) -> String? { item.appleMusicIdentity?.catalogID ?? (item.appleMusicIdentity == nil ? item.id : nil) }
            let libraryIDs = Array(Set(batch.compactMap { libraryID($0.item) })).sorted()
            var lookupErrors: [String: Error] = [:]
            if !libraryIDs.isEmpty {
                do {
                    let songs = try await library(libraryIDs)
                    AppleMusicDiagnostics.logger.debug("resolution source=library batch=\(offset / 100, privacy: .public) requested=\(libraryIDs.count, privacy: .public) returned=\(songs.count, privacy: .public) ids=[\(AppleMusicDiagnostics.ids(libraryIDs), privacy: .public)] songs=[\(AppleMusicDiagnostics.ids(songs.keys.sorted()), privacy: .public)]")
                    for (id, value) in songs { register(value, id: id) }
                }
                catch is CancellationError { throw CancellationError() }
                catch {
                    for id in libraryIDs { lookupErrors[id] = error }
                    AppleMusicDiagnostics.logger.debug("resolution source=library batch=\(offset / 100, privacy: .public) requested=\(libraryIDs.count, privacy: .public) returned=error ids=[\(AppleMusicDiagnostics.ids(libraryIDs), privacy: .public)] errorDomain=\((error as NSError).domain, privacy: .public) code=\((error as NSError).code, privacy: .public)")
                }
            }
            try Task.checkCancellation()
            let misses = batch.filter { cached($0.item) == nil }
            let catalogIDs = Array(Set(misses.compactMap { catalogID($0.item) })).sorted()
            if !catalogIDs.isEmpty {
                do {
                    let songs = try await catalog(catalogIDs)
                    AppleMusicDiagnostics.logger.debug("resolution source=catalog batch=\(offset / 100, privacy: .public) requested=\(catalogIDs.count, privacy: .public) returned=\(songs.count, privacy: .public) ids=[\(AppleMusicDiagnostics.ids(catalogIDs), privacy: .public)] songs=[\(AppleMusicDiagnostics.ids(songs.keys.sorted()), privacy: .public)]")
                    for (id, value) in songs { register(value, id: id) }
                }
                catch is CancellationError { throw CancellationError() }
                catch {
                    for id in catalogIDs { lookupErrors[id] = error }
                    AppleMusicDiagnostics.logger.debug("resolution source=catalog batch=\(offset / 100, privacy: .public) requested=\(catalogIDs.count, privacy: .public) returned=error ids=[\(AppleMusicDiagnostics.ids(catalogIDs), privacy: .public)] errorDomain=\((error as NSError).domain, privacy: .public) code=\((error as NSError).code, privacy: .public)")
                }
            }
            try Task.checkCancellation()
            for entry in batch where cached(entry.item) == nil {
                let lookupError = entry.item.musicIdentityIDs.compactMap { lookupErrors[$0] }.first
                if let lookupError {
                    AppleMusicDiagnostics.logger.info("resolution deferred song=\(entry.item.id, privacy: .public) kind=\(AppleMusicDiagnostics.kind(entry.item), privacy: .public) reason=lookup error")
                    if entry.id == selected { throw lookupError }
                    continue
                }
                AppleMusicDiagnostics.logger.info("resolution notFound song=\(entry.item.id, privacy: .public) kind=\(AppleMusicDiagnostics.kind(entry.item), privacy: .public)")
                if entry.id == selected { throw AppleMusicResolutionError.notFound }
                unavailable.insert(entry.id)
            }
            let completed = min(offset + batch.count, uncached.count)
            let cachedCount = entries.count - uncached.count
            let fraction = Double(completed + cachedCount) / Double(max(1, entries.count))
            progress(fraction)
        }
        return (entries.compactMap { entry in cached(entry.item).map { (entry, $0) } }, unavailable)
    }
}
