import Foundation
import Observation
import OSLog

struct TrackSnapshot: Equatable, Sendable {
    /// Include the player name so local and Apple Music identifiers cannot collide.
    let identity: String
    let title: String
    let artist: String
    let album: String
    var duration: Double?
    var playing: Bool
    var position: Double
    var playbackRate: Double = 1
}
struct PlaybackPayload: Codable, Equatable, Sendable {
    let playbackId: String
    var title: String?
    var artist: String?
    var album: String?
    var duration: Double?
    var playing: Bool?
    var position: Double?
    var playbackRate: Double?
    var discord: Bool?
    // Duration must be explicit null for unknown durations on starts/updates.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(playbackId, forKey: .playbackId)
        try c.encodeIfPresent(title, forKey: .title); try c.encodeIfPresent(artist, forKey: .artist); try c.encodeIfPresent(album, forKey: .album)
        if playing != nil { try c.encode(duration, forKey: .duration) }
        try c.encodeIfPresent(playing, forKey: .playing); try c.encodeIfPresent(position, forKey: .position)
        try c.encodeIfPresent(playbackRate, forKey: .playbackRate); try c.encodeIfPresent(discord, forKey: .discord)
    }
}
struct PlaybackReply: Codable, Sendable { let ok: Bool; let error: String? }
@MainActor protocol PlaybackTransport: AnyObject {
    var connected: Bool { get }
    func send(_ event: String, payload: PlaybackPayload) async -> PlaybackReply?
}

@MainActor @Observable
final class PlaybackReporter {
    private(set) var playbackId: String?
    private(set) var ownsPlayback = false
    private(set) var snapshot: TrackSnapshot?
    @ObservationIgnored var didStart: ((TrackSnapshot, Data?) -> Void)?
    @ObservationIgnored var snapshotProvider: (() -> TrackSnapshot?)?
    @ObservationIgnored private let transport: PlaybackTransport
    @ObservationIgnored private let discord: () -> Bool
    @ObservationIgnored private let upload: (Data, String) async throws -> Void
    @ObservationIgnored private let reportError: (Error) -> Void
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    @ObservationIgnored private var uploads: Task<Void, Never>?
    private var ownerPlaybackId: String?
    private var artwork: Data?
    private var pendingConnection = false
    private var epoch = 0
    private let logger = Logger(subsystem: "dev.hammerpot.Maple-iOS", category: "PlaybackReporting")
    private let automaticHeartbeat: Bool

    init(transport: PlaybackTransport, automaticHeartbeat: Bool = true,
         discord: @escaping () -> Bool = { UserDefaults.standard.bool(forKey: "mapleRPC") },
         upload: @escaping (Data, String) async throws -> Void = { _, _ in }, reportError: @escaping (Error) -> Void = { _ in }) {
        self.transport = transport; self.automaticHeartbeat = automaticHeartbeat
        self.discord = discord; self.upload = upload; self.reportError = reportError
    }
    /// New identity claims playback. State changes on the same identity never steal ownership back.
    func update(_ value: TrackSnapshot, artwork: Data? = nil, force: Bool = false) async {
        let changed = snapshot?.identity != value.identity
        let old = snapshot
        snapshot = value
        if changed {
            self.artwork = artwork
            await claim()
        } else if force || old?.playing != value.playing || old?.playbackRate != value.playbackRate || old?.duration != value.duration || abs((old?.position ?? 0) - value.position) > 2 {
            await sendUpdate()
        }
    }
    private func claim() async {
        release()
        epoch += 1
        let version = epoch
        let id = UUID().uuidString
        playbackId = id
        guard transport.connected else {
            logger.info("Playback queued until realtime connects")
            pendingConnection = true; return
        }
        pendingConnection = false
        let reply = await transport.send("playbackStart", payload: payload(id: id, start: true))
        logger.info("Playback start acknowledged: \(reply?.ok == true); ownership confirmed: \(self.ownerPlaybackId == id)")
        guard epoch == version, playbackId == id, ownerPlaybackId == id, transport.connected, reply?.ok == true else {
            if let reply, !reply.ok { reportError(MapleError(status: 409, message: reply.error)) }
            return
        }
        ownsPlayback = true
        if let snapshot { didStart?(snapshot, artwork) }
        if automaticHeartbeat {
            heartbeat = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(25)) } catch { return }
                    guard let self else { return }
                    await self.sendUpdate()
                }
            }
        }
        await sendUpdate()
        // Serialize cover writes; each write is guarded against stale playback before and after await.
        let previous = uploads
        let data = artwork
        uploads = Task { [weak self] in
            await previous?.value
            guard let self, self.ownsPlayback, self.playbackId == id, let data else { return }
            do { try await self.upload(data, id) }
            catch { if self.playbackId == id { self.reportError(error) } }
        }
    }
    func sendUpdate() async {
        guard ownsPlayback, let id = playbackId else { return }
        if let fresh = snapshotProvider?(), fresh.identity == snapshot?.identity { snapshot = fresh }
        let reply = await transport.send("playbackUpdate", payload: payload(id: id))
        if let reply, !reply.ok, playbackId == id { release() }
    }
    func stop() async {
        let id = playbackId
        epoch += 1; playbackId = nil; snapshot = nil; artwork = nil; pendingConnection = false
        release()
        if let id { _ = await transport.send("playbackStop", payload: PlaybackPayload(playbackId: id)) }
    }
    func ownershipChanged(_ id: String?) {
        ownerPlaybackId = id
        if id != playbackId { release() }
    }
    func disconnected() {
        epoch += 1; ownerPlaybackId = nil; pendingConnection = false; release()
    }
    func connected() async {
        // Only report a track loaded while waiting for the initial connection. A reconnect never reclaims an old track.
        if pendingConnection, snapshot != nil { await claim() }
    }
    private func release() { ownsPlayback = false; heartbeat?.cancel(); heartbeat = nil }
    private func payload(id: String, start: Bool = false) -> PlaybackPayload {
        let value = snapshot
        func seconds(_ value: Double?) -> Double { guard let value, value.isFinite else { return 0 }; return min(max(value, 0), 86400) }
        func text(_ value: String?) -> String { String((value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(512)) }
        let duration = seconds(value?.duration)
        let rate = value?.playbackRate ?? 1
        return PlaybackPayload(playbackId: id,
            title: start ? (text(value?.title).isEmpty ? "Unknown Title" : text(value?.title)) : nil,
            artist: start ? text(value?.artist) : nil, album: start ? text(value?.album) : nil,
            duration: duration > 0 ? duration : nil, playing: value?.playing ?? false,
            position: seconds(value?.position), playbackRate: rate.isFinite ? min(max(rate, 0.1), 16) : 1, discord: discord())
    }
}
