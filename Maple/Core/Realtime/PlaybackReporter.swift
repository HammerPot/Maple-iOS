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
    @ObservationIgnored var artworkProvider: ((String) async -> Data?)?
    @ObservationIgnored var snapshotProvider: (() -> TrackSnapshot?)?
    @ObservationIgnored private let transport: PlaybackTransport
    @ObservationIgnored private let discord: () -> Bool
    @ObservationIgnored private let upload: (Data, String) async throws -> Void
    @ObservationIgnored private let reportError: (Error) -> Void
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    @ObservationIgnored private var uploads: Task<Void, Never>?
    private var artwork: Data?
    private var epoch = 0
    /// Another device took over: terminal until the track changes or the user starts/resumes playback here.
    private var foreignOwner = false
    private var claiming = false
    /// The server refused `playbackStart` itself. Passive updates (the Apple Music poll) must not retry it every
    /// tick; only an explicit trigger (track change, local start, reconnect, foreground) tries again.
    private var startRejected = false
    /// `didStart` (the webhook) fires once per track, not again for every lease re-acquisition.
    private var announcedIdentity: String?
    private var lastAcknowledgedAt: TimeInterval?
    @ObservationIgnored private var reacquisition: Task<Void, Never>?
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let now: () -> TimeInterval
    private let logger = Logger(subsystem: "dev.hammerpot.Maple-iOS", category: "PlaybackReporting")
    private let automaticHeartbeat: Bool
    private let heartbeatInterval: Duration

    init(transport: PlaybackTransport, automaticHeartbeat: Bool = true,
         heartbeatInterval: Duration = .seconds(25),
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         now: @escaping () -> TimeInterval = PlaybackReporter.monotonicNow,
         discord: @escaping () -> Bool = { UserDefaults.standard.bool(forKey: "mapleRPC") },
         upload: @escaping (Data, String) async throws -> Void = { _, _ in }, reportError: @escaping (Error) -> Void = { _ in }) {
        self.transport = transport; self.automaticHeartbeat = automaticHeartbeat
        self.heartbeatInterval = heartbeatInterval; self.sleep = sleep; self.now = now
        self.discord = discord; self.upload = upload; self.reportError = reportError
    }
    /// Track changes and explicit paused-to-playing transitions may take ownership back from another device.
    func update(_ value: TrackSnapshot, artwork: Data? = nil, force: Bool = false) async {
        defer { synchronizeHeartbeat() }
        let changed = snapshot?.identity != value.identity
        let old = snapshot
        snapshot = value
        if changed {
            self.artwork = artwork; foreignOwner = false; startRejected = false
            if value.playing { await claim() }
            else {
                let previousID = playbackId
                epoch += 1; claiming = false; release(); playbackId = nil
                if let previousID { _ = await transport.send("playbackStop", payload: PlaybackPayload(playbackId: previousID)) }
            }
        } else if !ownsPlayback, !claiming, !foreignOwner, !startRejected, value.playing {
            await claim()
        } else if force || old?.playing != value.playing || old?.playbackRate != value.playbackRate || old?.duration != value.duration || abs((old?.position ?? 0) - value.position) > 2 {
            await sendUpdate()
        }
    }
    private func claim() async {
        guard snapshot?.playing == true else { return }
        reacquisition?.cancel(); reacquisition = nil
        release()
        epoch += 1
        let version = epoch
        let id = UUID().uuidString
        playbackId = id
        guard transport.connected else {
            // `connected()` claims again once realtime is back.
            logger.info("Playback queued until realtime connects")
            return
        }
        claiming = true
        let reply = await transport.send("playbackStart", payload: payload(id: id, start: true))
        guard epoch == version, playbackId == id else { return }
        claiming = false
        // A successful start ack grants the claim. The matching ownership broadcast can arrive on either side
        // of the continuation; a foreign ownership event fences the attempt by advancing the epoch.
        guard transport.connected, reply?.ok == true, !foreignOwner else {
            if let reply, !reply.ok { startRejected = true; reportError(MapleError(status: 409, message: reply.error)) }
            return
        }
        ownsPlayback = true; startRejected = false; lastAcknowledgedAt = now()
        if artwork != nil || artworkProvider == nil { announceStart(artwork: artwork) }
        synchronizeHeartbeat()
        await sendUpdate(reacquireOnRejection: false)
        // Artwork never delays ACK handling, heartbeat, Stop, or the next track's wire operations.
        // A CDN/HTTP operation may ignore cancellation, so every result is fenced by claim epoch.
        let data = artwork, identity = snapshot?.identity, provider = artworkProvider
        uploads?.cancel()
        uploads = Task { [weak self] in
            let fetched: Data?
            if let data { fetched = data }
            else if let identity, let provider { fetched = await provider(identity) }
            else { fetched = nil }
            guard let self, !Task.isCancelled, self.epoch == version, self.ownsPlayback,
                  self.playbackId == id, self.snapshot?.identity == identity else { return }
            self.artwork = fetched
            self.announceStart(artwork: fetched)
            guard let fetched else { return }
            do { try await self.upload(fetched, id) }
            catch { if self.epoch == version, self.playbackId == id { self.reportError(error) } }
        }
    }
    private func synchronizeHeartbeat() {
        guard automaticHeartbeat, ownsPlayback, snapshot?.playing == true else {
            heartbeat?.cancel(); heartbeat = nil; return
        }
        guard heartbeat == nil else { return }
        let sleep = sleep, interval = heartbeatInterval
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleep(interval) } catch { return }
                guard !Task.isCancelled else { return }
                await self?.sendUpdate()
            }
        }
    }
    private func announceStart(artwork: Data?) {
        guard let snapshot, snapshot.playing, snapshot.identity != announcedIdentity else { return }
        announcedIdentity = snapshot.identity
        didStart?(snapshot, artwork)
    }
    func waitForArtwork() async { await uploads?.value }
    func sendUpdate() async { await sendUpdate(reacquireOnRejection: true) }
    private func sendUpdate(reacquireOnRejection: Bool) async {
        refreshSnapshot()
        guard ownsPlayback, let id = playbackId else { return }
        if let lastAcknowledgedAt, now() - lastAcknowledgedAt >= 90, snapshot?.playing == true {
            await reclaim(); return
        }
        let version = epoch
        let reply = await transport.send("playbackUpdate", payload: payload(id: id))
        guard epoch == version, playbackId == id else { return }
        if reply?.ok == true { lastAcknowledgedAt = now() }
        else if reply?.ok == false {
            release()
            if reacquireOnRejection { await reclaim() }
        }
    }
    func stop() async {
        let id = playbackId
        resetSession()
        if let id { _ = await transport.send("playbackStop", payload: PlaybackPayload(playbackId: id)) }
    }
    /// Synchronous account boundary; never send an old playbackStop through a new account's socket.
    func resetSession() {
        epoch += 1; playbackId = nil; snapshot = nil; artwork = nil
        foreignOwner = false; claiming = false; startRejected = false; announcedIdentity = nil
        reacquisition?.cancel(); reacquisition = nil
        release()
    }
    /// `playbackOwnership` is applied synchronously in wire order, so it may arrive before or after the start ack.
    func ownershipChanged(_ id: String?) {
        guard snapshot != nil, id != playbackId else { return }
        if id != nil {
            foreignOwner = true; epoch += 1; claiming = false
            reacquisition?.cancel(); reacquisition = nil; release()
        } else if !claiming {
            release()
            scheduleReacquisition()
        }
    }
    func disconnected() {
        epoch += 1; claiming = false
        reacquisition?.cancel(); reacquisition = nil; release()
    }
    func connected() async { startRejected = false; await reclaim() }
    /// Call on foreground even if the socket stayed connected: the server lease may have expired in suspension.
    func sceneBecameActive() async { startRejected = false; await reclaim() }
    /// An explicit local start/resume may override a previous foreign-device takeover, even on the same track.
    func playbackStarted() async {
        foreignOwner = false; startRejected = false
        if ownsPlayback { await sendUpdate() } else { await reclaim() }
    }
    private func refreshSnapshot() {
        if let fresh = snapshotProvider?(), fresh.identity == snapshot?.identity { snapshot = fresh }
    }
    private func reclaim() async {
        refreshSnapshot()
        guard !foreignOwner, !claiming, snapshot?.playing == true else { return }
        await claim()
    }
    private func scheduleReacquisition() {
        guard reacquisition == nil, !foreignOwner else { return }
        let version = epoch
        reacquisition = Task { [weak self] in
            guard let self, self.epoch == version, !Task.isCancelled else { return }
            self.reacquisition = nil
            await self.reclaim()
        }
    }
    /// Includes time the device spent asleep (unlike `systemUptime`), which is what the server's 90 s lease sees.
    nonisolated static func monotonicNow() -> TimeInterval { TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000 }
    private func release() {
        uploads?.cancel(); uploads = nil
        ownsPlayback = false; lastAcknowledgedAt = nil; heartbeat?.cancel(); heartbeat = nil
    }
    deinit { heartbeat?.cancel(); uploads?.cancel(); reacquisition?.cancel() }
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
