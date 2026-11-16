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

@MainActor @Observable
final class MapleRealtime: PlaybackTransport {
    private(set) var connected = false
    private(set) var lastRPCUpdate: RPCUpdate?
    @ObservationIgnored var onOwnership: ((String?) -> Void)?
    @ObservationIgnored var onListening: ((ListeningEvent) -> Void)?
    @ObservationIgnored var onFriendship: ((String, FriendshipEvent) -> Void)?
    @ObservationIgnored var onConnect: (() -> Void)?
    @ObservationIgnored var onDisconnect: (() -> Void)?
    @ObservationIgnored var validateSession: (() async -> Bool)?
    @ObservationIgnored private var manager: SocketManager?
    @ObservationIgnored private var socket: SocketIOClient?
    private var generation = 0
    private var checkedSession = false
    private let logger = Logger(subsystem: "dev.hammerpot.Maple-iOS", category: "Realtime")

    func connect(cookies: [HTTPCookie]) {
        guard manager == nil, !cookies.isEmpty else { return }
        generation += 1
        let manager = SocketManager(socketURL: MapleHTTP.baseURL, config: [
            .cookies(cookies), .extraHeaders(["Origin": MapleHTTP.origin]), .log(false),
            .reconnects(true), .reconnectWait(1), .reconnectWaitMax(5), .handleQueue(.main)
        ])
        self.manager = manager
        let socket = manager.defaultSocket
        self.socket = socket
        socket.on(clientEvent: .connect) { [weak self, weak socket] _, _ in
            Task { @MainActor in
                guard let self, self.socket === socket else { return }
                self.connected = true; self.checkedSession = false; self.onConnect?()
            }
        }
        socket.on(clientEvent: .disconnect) { [weak self, weak socket] data, _ in
            Task { @MainActor in
                guard let self, self.socket === socket else { return }
                self.connected = false; self.onDisconnect?()
                if let reason = data.first as? String, reason.contains("server disconnect") { await self.revalidate(socket: socket) }
            }
        }
        socket.on(clientEvent: .error) { [weak self, weak socket] _, _ in
            Task { @MainActor in
                guard let self, self.socket === socket else { return }
                // A rejected authentication handshake stops reconnecting. Check the session once per connection attempt.
                if socket?.status != .connected { await self.revalidate(socket: socket) }
            }
        }
        listen("playbackOwnership", as: PlaybackOwnershipEvent.self) { [weak self] in self?.onOwnership?($0.playbackId) }
        listen("listening", as: ListeningEvent.self) { [weak self] in self?.onListening?($0) }
        listen("rpcUpdate", as: RPCUpdate.self) { [weak self] in self?.lastRPCUpdate = $0 }
        for event in ["friendRequest", "requestAccepted", "acceptedRequest", "friendRemoved"] {
            listen(event, as: FriendshipEvent.self) { [weak self] in self?.onFriendship?(event, $0) }
        }
        socket.connect()
    }
    private func revalidate(socket: SocketIOClient?) async {
        guard !checkedSession else { return }
        checkedSession = true
        let version = generation
        if await validateSession?() == true, generation == version, self.socket === socket { socket?.connect() }
    }
    func disconnect() {
        generation += 1
        socket?.removeAllHandlers(); socket?.disconnect(); manager?.disconnect()
        socket = nil; manager = nil; connected = false; onDisconnect?()
    }
    private func listen<T: Decodable>(_ event: String, as type: T.Type, receive: @escaping @MainActor (T) -> Void) {
        let version = generation
        socket?.on(event) { [weak self] data, _ in
            guard let object = data.first, let bytes = try? JSONSerialization.data(withJSONObject: object) else { return }
            Task { @MainActor in
                guard let self, self.generation == version else { return }
                do { receive(try JSONDecoder.maple.decode(type, from: bytes)) }
                catch { self.logger.error("Malformed realtime event: \(event, privacy: .public)") }
            }
        }
    }
    func send(_ event: String, payload: PlaybackPayload) async -> PlaybackReply? {
        guard connected, let socket,
              let bytes = try? JSONEncoder().encode(payload),
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return nil }
        let version = generation
        let reply: PlaybackReply? = await withCheckedContinuation { continuation in
            socket.emitWithAck(event, object).timingOut(after: 10) { values in
                guard let first = values.first, let data = try? JSONSerialization.data(withJSONObject: first),
                      let reply = try? JSONDecoder().decode(PlaybackReply.self, from: data) else {
                    continuation.resume(returning: nil); return
                }
                continuation.resume(returning: reply)
            }
        }
        return generation == version ? reply : nil
    }
}
