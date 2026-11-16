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
    @ObservationIgnored private var manager: SocketManager?
    @ObservationIgnored private(set) var socket: SocketIOClient?
    @ObservationIgnored private var revalidation: Task<Void, Never>?
    @ObservationIgnored private let openSocket: (SocketIOClient) -> Void
    @ObservationIgnored private let retrySleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var pendingAcks: [UUID: CheckedContinuation<PlaybackReply?, Never>] = [:]
    @ObservationIgnored private var ackTimeouts: [UUID: Task<Void, Never>] = [:]
    private var generation = 0
    private var checkedSession = false
    private let logger = Logger(subsystem: "dev.hammerpot.Maple-iOS", category: "Realtime")

    init(openSocket: @escaping (SocketIOClient) -> Void = { $0.connect() },
         retrySleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.openSocket = openSocket; self.retrySleep = retrySleep
    }
    func connect(cookies: [HTTPCookie]) {
        guard manager == nil else { return }
        guard !cookies.isEmpty else { logger.error("Realtime connection has no session cookie"); return }
        logger.info("Starting authenticated realtime connection")
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
                // A rejected authentication handshake stops reconnecting. Check the session once per connection attempt.
                if message.contains("Authentication error") {
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
        isConnected = true; checkedSession = false; revalidation?.cancel(); revalidation = nil
        onConnect?()
    }
    func socketDidLose() {
        isConnected = false; lastRPCUpdate = nil
        for id in Array(pendingAcks.keys) { finishAck(id, reply: nil) }
        onDisconnect?()
    }
    private func revalidate(socket: SocketIOClient?) {
        guard !checkedSession, revalidation == nil, let socket, socket.status != .connected,
              socket.status != .connecting else { return }
        let version = generation
        let sleep = retrySleep
        revalidation = Task { [weak self, weak socket] in
            while !Task.isCancelled {
                let result = await self?.validateSession?() ?? .invalid
                guard !Task.isCancelled, let self, self.generation == version, self.socket === socket else { return }
                switch result {
                case .valid:
                    self.checkedSession = true; self.revalidation = nil
                    if let socket, socket.status == .notConnected || socket.status == .disconnected { self.openSocket(socket) }
                    return
                case .invalid:
                    self.checkedSession = true; self.revalidation = nil; return
                case .unreachable: break
                }
                do { try await sleep(.seconds(5)) } catch { return }
            }
        }
    }
    func sceneBecameActive() {
        guard !connected else { return }
        checkedSession = false
        revalidate(socket: socket)
    }
    func disconnect() {
        generation += 1
        revalidation?.cancel(); revalidation = nil
        socket?.removeAllHandlers(); socket?.disconnect(); manager?.disconnect()
        socket = nil; manager = nil; isConnected = false; checkedSession = false
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
