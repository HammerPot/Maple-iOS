import Foundation
import Observation
import SocketIO
import OSLog

struct PlaybackOwnershipEvent: Decodable { let playbackId: String? }
struct ListeningEvent: Decodable { let id: String; let listening: Listening? }
struct FriendshipEvent: Decodable { let id: String; let message: String? }
struct RPCUpdate: Decodable {
    let playing: Bool
    let id: String?
    let title: String?
    let artist: String?
    let album: String?
    let state: String?
    let largeImageKey: String?
    let largeImageText: String?
    let smallImageKey: String?
    let smallText: String?
    let position: Double?
    let duration: Double?
    let playbackRate: Double?
    let buttons: [Button]?
    struct Button: Decodable { let label: String; let url: String }
}

enum SessionValidity: Sendable { case valid, invalid, unreachable }

extension PlaybackReply {
    /// Ack arguments are `[reply]` on success but `["NO ACK"]` (a bare String) on timeout. Feeding the latter to
    /// JSONSerialization raises an uncatchable Objective-C exception, so only dictionaries are ever serialised.
    static func parse(ackValues values: [Any]) -> PlaybackReply? {
        guard let first = values.first as? [String: Any], JSONSerialization.isValidJSONObject(first),
              let data = try? JSONSerialization.data(withJSONObject: first) else { return nil }
        return try? JSONDecoder().decode(PlaybackReply.self, from: data)
    }
}

@MainActor @Observable
final class MapleRealtime: PlaybackTransport {
    private var isConnected = false
    var connected: Bool { isConnected && socket?.status == .connected }
    private(set) var lastRPCUpdate: RPCUpdate?
    @ObservationIgnored var onOwnership: ((String?) -> Void)?
    @ObservationIgnored var onListening: ((ListeningEvent) -> Void)?
    @ObservationIgnored var onFriendship: ((String, FriendshipEvent) -> Void)?
    @ObservationIgnored var onConnect: (() -> Void)?
    @ObservationIgnored var onDisconnect: (() -> Void)?
    @ObservationIgnored var validateSession: (() async -> SessionValidity)?
    /// The app's current session cookies. Asked whenever the connection might be stale (a revalidated session, a return
    /// to the foreground) so it never keeps presenting a cookie the server has replaced.
    @ObservationIgnored var cookieProvider: (() -> [HTTPCookie])?
    /// The cookies the live manager handshakes with.
    @ObservationIgnored private(set) var presentedCookies: [HTTPCookie] = []
    @ObservationIgnored private var manager: SocketManager?
    @ObservationIgnored private(set) var socket: SocketIOClient?
    @ObservationIgnored private var revalidation: Task<Void, Never>?
    @ObservationIgnored private let openSocket: (SocketIOClient) -> Void
    @ObservationIgnored private let retrySleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var pendingAcks: [UUID: CheckedContinuation<PlaybackReply?, Never>] = [:]
    @ObservationIgnored private var ackTimeouts: [UUID: Task<Void, Never>] = [:]
    private var generation = 0
    private var checkedSession = false
    /// Consecutive handshakes the server refused. Reset by a successful connection or an explicit disconnect.
    private var authFailures = 0
    private let logger = Logger(subsystem: "dev.hammerpot.Maple-iOS", category: "Realtime")

    init(openSocket: @escaping (SocketIOClient) -> Void = { $0.connect() },
         retrySleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.openSocket = openSocket; self.retrySleep = retrySleep
    }
    /// Opens the connection with these cookies. A live connection that already presents exactly these is kept; one that
    /// presents different cookies (the session was replaced, for instance by a password change) is rebuilt, because the
    /// server rejects the old cookie and the manager cannot be given a new one.
    func connect(cookies: [HTTPCookie]) {
        if manager != nil {
            guard !cookies.isEmpty, !Self.samePresentation(cookies, presentedCookies) else { return }
            logger.info("Session cookie changed; rebuilding realtime connection")
            teardown()
        }
        guard !cookies.isEmpty else { logger.error("Realtime connection has no session cookie"); return }
        logger.info("Starting authenticated realtime connection")
        presentedCookies = cookies
        generation += 1
        let manager = SocketManager(socketURL: MapleHTTP.baseURL, config: [
            .cookies(cookies), .extraHeaders(["Origin": MapleHTTP.origin]), .log(false),
            .reconnects(true), .reconnectWait(1), .reconnectWaitMax(5), .handleQueue(.main)
        ])
        self.manager = manager
        let socket = manager.defaultSocket
        self.socket = socket
        // Every handler runs on the manager's handle queue, which is the main queue: apply state synchronously so
        // events (ownership before the start ack, for one) are observed in wire order instead of after a Task hop.
        socket.on(clientEvent: .connect) { [weak self, weak socket] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.socket === socket else { return }
                self.logger.info("Realtime connected")
                self.socketDidConnect()
            }
        }
        // With reconnects enabled the library reports a lost transport as `.reconnect`, never `.disconnect`.
        for event in [SocketClientEvent.reconnect, .reconnectAttempt, .disconnect] {
            socket.on(clientEvent: event) { [weak self, weak socket] data, _ in
                MainActor.assumeIsolated {
                    guard let self, self.socket === socket else { return }
                    self.logger.info("Realtime disconnected")
                    let reason = data.first as? String
                    self.socketDidLose()
                    if event == .disconnect, reason == "Got Disconnect" || reason == "io server disconnect" { self.revalidate(socket: socket) }
                }
            }
        }
        socket.on(clientEvent: .error) { [weak self, weak socket] data, _ in
            MainActor.assumeIsolated {
                guard let self, self.socket === socket else { return }
                let message = String(describing: data.first)
                if message.contains("Invalid session") { self.logger.error("Realtime authentication rejected") }
                else { self.logger.error("Realtime connection failed") }
                // A rejected authentication handshake stops reconnecting. Check the session, and if it is still valid
                // connect again with the current cookies (see `revalidate`).
                if message.contains("Authentication error") {
                    // A refusal after the session checked out is new information: check again (after a pause).
                    self.authFailures += 1; self.checkedSession = false
                    // The SDK leaves namespace handshake failures in `.connecting`; end that failed attempt first.
                    socket?.disconnect()
                    self.revalidate(socket: socket)
                } else if socket?.status != .connected, socket?.status != .connecting {
                    self.revalidate(socket: socket)
                }
            }
        }
        listen("playbackOwnership", as: PlaybackOwnershipEvent.self) { [weak self] in self?.onOwnership?($0.playbackId) }
        listen("listening", as: ListeningEvent.self) { [weak self] in self?.onListening?($0) }
        listen("rpcUpdate", as: RPCUpdate.self) { [weak self] in self?.lastRPCUpdate = $0 }
        for event in ["friendRequest", "requestAccepted", "acceptedRequest", "friendRemoved"] {
            listen(event, as: FriendshipEvent.self) { [weak self] in self?.onFriendship?(event, $0) }
        }
        openSocket(socket)
    }
    func socketDidConnect() {
        isConnected = true; checkedSession = false; authFailures = 0; revalidation?.cancel(); revalidation = nil
        onConnect?()
    }
    func socketDidLose() {
        isConnected = false; lastRPCUpdate = nil
        for id in Array(pendingAcks.keys) { finishAck(id, reply: nil) }
        onDisconnect?()
    }
    /// How long to wait before asking the server again after a valid session was still refused at the handshake.
    /// The first refusal is checked at once; repeats back off to a minute, and never stop while the session is valid.
    private var authRetryDelay: Duration? {
        authFailures > 1 ? .seconds(min(60, 5 << min(authFailures - 2, 4))) : nil
    }
    private func revalidate(socket: SocketIOClient?) {
        guard !checkedSession, revalidation == nil, let socket, socket.status != .connected,
              socket.status != .connecting else { return }
        let version = generation
        let sleep = retrySleep
        let initialDelay = authRetryDelay
        revalidation = Task { [weak self, weak socket] in
            if let initialDelay { do { try await sleep(initialDelay) } catch { return } }
            while !Task.isCancelled {
                let result = await self?.validateSession?() ?? .invalid
                guard !Task.isCancelled, let self, self.generation == version, self.socket === socket else { return }
                switch result {
                case .valid:
                    self.checkedSession = true; self.revalidation = nil
                    self.reconnectValidSession(socket)
                    return
                case .invalid:
                    self.checkedSession = true; self.revalidation = nil; return
                case .unreachable: break
                }
                do { try await sleep(.seconds(5)) } catch { return }
            }
        }
    }
    /// The session is still valid, so the connection must come back: with the current cookies if they changed,
    /// otherwise by reopening the same socket.
    private func reconnectValidSession(_ socket: SocketIOClient?) {
        if let current = cookieProvider?(), !current.isEmpty, !Self.samePresentation(current, presentedCookies) {
            connect(cookies: current)
        } else if let socket, socket.status == .notConnected || socket.status == .disconnected {
            openSocket(socket)
        }
    }
    func sceneBecameActive() {
        // A cookie replaced while the app was away (or while a stale socket was still up) must not stay presented.
        if manager != nil, let current = cookieProvider?(), !current.isEmpty { connect(cookies: current) }
        guard !connected else { return }
        checkedSession = false; authFailures = 0
        revalidation?.cancel(); revalidation = nil
        revalidate(socket: socket)
    }
    private static func samePresentation(_ lhs: [HTTPCookie], _ rhs: [HTTPCookie]) -> Bool {
        func key(_ cookies: [HTTPCookie]) -> [String] { cookies.map { $0.name + "\u{0}" + $0.value }.sorted() }
        return key(lhs) == key(rhs)
    }
    func disconnect() {
        authFailures = 0
        teardown()
    }
    private func teardown() {
        generation += 1
        revalidation?.cancel(); revalidation = nil
        socket?.removeAllHandlers(); socket?.disconnect(); manager?.disconnect()
        socket = nil; manager = nil; isConnected = false; checkedSession = false; presentedCookies = []
        for id in Array(pendingAcks.keys) { finishAck(id, reply: nil) }
        lastRPCUpdate = nil
        onDisconnect?()
    }
    private func listen<T: Decodable>(_ event: String, as type: T.Type, receive: @escaping @MainActor (T) -> Void) {
        let version = generation
        socket?.on(event) { [weak self] data, _ in
            guard let object = data.first as? [String: Any], JSONSerialization.isValidJSONObject(object),
                  let bytes = try? JSONSerialization.data(withJSONObject: object) else { return }
            MainActor.assumeIsolated {
                guard let self, self.generation == version else { return }
                do { receive(try JSONDecoder.maple.decode(type, from: bytes)) }
                catch { self.logger.error("Malformed realtime event: \(event, privacy: .public)") }
            }
        }
    }
    func send(_ event: String, payload: PlaybackPayload) async -> PlaybackReply? {
        guard connected, let socket, socket.status == .connected,
              let bytes = try? JSONEncoder().encode(payload),
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return nil }
        let version = generation
        let id = UUID()
        let reply: PlaybackReply? = await withCheckedContinuation { continuation in
            pendingAcks[id] = continuation
            // An SDK serialization failure can skip its ack callback entirely. Own the timeout as well.
            ackTimeouts[id] = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                self?.finishAck(id, reply: nil)
            }
            socket.emitWithAck(event, object).timingOut(after: 10) { [weak self] values in
                MainActor.assumeIsolated { self?.finishAck(id, reply: PlaybackReply.parse(ackValues: values)) }
            }
        }
        return generation == version ? reply : nil
    }
    private func finishAck(_ id: UUID, reply: PlaybackReply?) {
        ackTimeouts.removeValue(forKey: id)?.cancel()
        pendingAcks.removeValue(forKey: id)?.resume(returning: reply)
    }
    deinit { revalidation?.cancel(); ackTimeouts.values.forEach { $0.cancel() } }

}
