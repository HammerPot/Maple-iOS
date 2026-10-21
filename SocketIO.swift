import SwiftUI
import SocketIO
import SwiftyJSON
import SwiftUISnackbar

/// Socket.IO callbacks and player snapshots are handled on the main queue.
@MainActor
final class AppSocketManager: ObservableObject {
    static let shared = AppSocketManager()

    @Published var snackbar: Snackbar?
    @Published private(set) var friendsRevision = UUID()
    @Published private(set) var friendPlayback: [String: JSON] = [:]

    private var manager: SocketManager?
    private var socket: SocketIOClient?
    private var ownership = MapleRPCOwnership()
    private var heartbeat: Timer?
    private var playback: (() -> MaplePlaybackSnapshot?)?
    private var latestArtwork: Data?
    private var trackKey: String?
    private var accountID: String?
    private var pendingSocial = false
    private var artworkRequestID: String?
    private var artworkReady = false
    private var artworkDeadline = Date()
    private var artworkUpload: Task<Void, Never>?

    var enabled: Bool { UserDefaults.standard.bool(forKey: "socketIO") }
    private var discord: Bool { UserDefaults.standard.bool(forKey: "mapleRPC") }

    func connect() {
        guard enabled, let id = UserDefaults.standard.string(forKey: "savedServerID"), !id.isEmpty,
              let cookies = HTTPCookieStorage.shared.cookies(for: MapleAPI.baseURL),
              cookies.contains(where: { $0.name == "token" && ($0.expiresDate ?? .distantFuture) > Date() }) else { return }
        if accountID == id, socket?.status == .connected || socket?.status == .connecting { return }
        // Rebuild the manager after login so the handshake uses the current account's cookies.
        closeConnection()
        if accountID != id {
            resetArtwork()
            trackKey = nil
        }
        accountID = id
        let manager = SocketManager(socketURL: MapleAPI.baseURL, config: [.log(false), .cookies(cookies), .handleQueue(.main)])
        self.manager = manager
        let socket = manager.defaultSocket
        self.socket = socket
        setupListeners(socket)
        socket.connect()
        if let snapshot = playback?(), snapshot.playing, let latestArtwork {
            trackKey = snapshot.trackKey
            prepareArtwork(latestArtwork, account: id, track: snapshot.trackKey)
        }
    }

    func disconnect() {
        clearPresence()
        closeConnection()
        accountID = nil
        trackKey = nil
        pendingSocial = false
        resetArtwork()
        friendPlayback = [:]
    }

    private func closeConnection() {
        heartbeat?.invalidate()
        heartbeat = nil
        ownership.reset()
        socket?.removeAllHandlers()
        manager?.disconnect()
        socket = nil
        manager = nil
    }

    private func setupListeners(_ socket: SocketIOClient) {
        socket.on(clientEvent: .connect) { [weak self] _, _ in
            guard let self else { return }
            self.ownership.reset()
            self.publish(claim: self.playback?()?.playing == true)
            socket.emit("rpcOwnershipRequest")
        }
        socket.on(clientEvent: .disconnect) { [weak self] _, _ in
            self?.ownership.reset()
            self?.heartbeat?.invalidate()
        }
        socket.on("rpcOwnership") { [weak self] data, _ in
            guard let self, let object = data.first as? [String: Any], let generation = object["generation"] as? String else { return }
            if let claim = self.ownership.receive(generation: generation, owned: object["owned"] as? Bool ?? false) {
                self.publish(claim: claim)
            }
        }
        socket.on("albumArtUploaded") { [weak self] data, _ in
            guard let self, let object = data.first as? [String: Any],
                  object["id"] as? String == self.accountID,
                  let requestID = object["artworkRequestId"] as? String, requestID == self.artworkRequestID else { return }
            self.artworkReady = true
            self.publish()
        }
        socket.on("friendRequest") { [weak self] data, _ in
            guard let self, let id = JSON(data.first as Any)["id"].string, !id.isEmpty else { return }
            self.friendsRevision = UUID()
            Task { @MainActor in
                do {
                    let user = try await publicUserId(serverID: id)
                    self.snackbar = Snackbar(title: "Friend request received", message: "Friend request from \(user["username"]?.stringValue ?? "Unknown")", action: .text("Accept", .white, {
                        Task { @MainActor in
                            do {
                                let message = try await acceptFriend(id: id)
                                self.snackbar = Snackbar(title: "Accept Friend", message: message)
                                self.friendsRevision = UUID()
                            } catch { self.showError(error.localizedDescription) }
                        }
                    }))
                } catch { self.showError(error.localizedDescription) }
            }
        }
        for event in ["requestAccepted", "acceptedRequest"] {
            socket.on(event) { [weak self] _, _ in self?.friendsRevision = UUID() }
        }
        socket.on("nowPlaying") { [weak self] data, _ in
            guard let self, let object = data.first as? [String: Any], let id = object["id"] as? String,
                  let nowPlaying = object["nowPlaying"] as? [String: Any] else { return }
            self.friendPlayback[id] = JSON(nowPlaying)
        }
        for event in ["error", "invalidNowPlaying", "semiValidNowPlaying"] {
            socket.on(event) { [weak self] data, _ in
                let json = JSON(data.first as Any)
                let message = json.string ?? json["message"].string ?? json["message"].arrayValue.map(\.stringValue).joined(separator: ", ")
                if !message.isEmpty { self?.showError(message) }
            }
        }
        socket.on("notFound") { [weak self] _, _ in self?.showError("User not found") }
    }

    func updatePlayback(_ provider: @escaping () -> MaplePlaybackSnapshot?, artwork: Data? = nil, claim: Bool) {
        guard let snapshot = provider() else { return }
        // A delayed stop notification from the previous player cannot clear the active player.
        if let current = playback?(), current.source != snapshot.source, !snapshot.playing { return }
        playback = provider
        latestArtwork = artwork
        if enabled { connect() }
        let changed = trackKey != snapshot.trackKey
        trackKey = snapshot.trackKey
        if changed { resetArtwork() }
        if (changed || artworkRequestID == nil), snapshot.playing, let artwork, enabled,
           let id = UserDefaults.standard.string(forKey: "savedServerID"), !id.isEmpty {
            prepareArtwork(artwork, account: id, track: snapshot.trackKey)
        }
        pendingSocial = pendingSocial || (snapshot.playing && (changed || claim))
        publish(claim: claim)
    }

    private func publish(claim: Bool = false) {
        heartbeat?.invalidate()
        heartbeat = nil
        guard enabled, let socket, socket.status == .connected, let id = accountID,
              id == UserDefaults.standard.string(forKey: "savedServerID") else { return }
        guard let generation = ownership.generation else {
            ownership.queueClaim(claim)
            return
        }
        var payload = playback?()?.payload(discord: discord) ?? ["playing": false, "discord": discord]
        payload["generation"] = generation
        payload["claim"] = claim
        payload["artworkReady"] = artworkReady
        payload["artworkWait"] = max(0, min(30, artworkDeadline.timeIntervalSinceNow))
        payload["artworkRequestId"] = artworkRequestID
        socket.emit("playbackState", payload)
        if pendingSocial, let snapshot = playback?(), snapshot.playing {
            pendingSocial = false
            var social = payload
            social["id"] = id
            social["source"] = snapshot.source
            let formatter = ISO8601DateFormatter()
            social["timePlayed"] = formatter.string(from: Date()).replacingOccurrences(of: "T", with: " ").replacingOccurrences(of: "Z", with: "")
            socket.emit("nowPlaying", ["nowPlaying": social])
        }
        if payload["playing"] as? Bool == true && discord {
            heartbeat = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.publish() }
            }
        }
    }

    private func prepareArtwork(_ data: Data, account: String, track: String) {
        let requestID = UUID().uuidString
        artworkRequestID = requestID
        artworkReady = false
        artworkDeadline = Date().addingTimeInterval(30)
        let previousUpload = artworkUpload
        // Serialize account cover writes, including across rapid track changes.
        artworkUpload = Task { @MainActor [weak self] in
            await previousUpload?.value
            guard let self, self.artworkRequestID == requestID, self.trackKey == track,
                  UserDefaults.standard.string(forKey: "savedServerID") == account else { return }
            do {
                _ = try await setAlbumArt(serverID: account, albumArt: data, artworkRequestId: requestID)
                guard self.artworkRequestID == requestID, self.trackKey == track,
                      UserDefaults.standard.string(forKey: "savedServerID") == account else { return }
                self.artworkReady = true
                self.publish()
            } catch {
                // Playback remains valid when a cover upload fails; the RPC artwork deadline is bounded.
            }
        }
    }

    private func resetArtwork() {
        artworkRequestID = nil
        artworkReady = false
        artworkDeadline = Date().addingTimeInterval(30)
    }

    func settingsChanged() {
        if enabled {
            connect()
            publish(claim: true)
        } else {
            clearPresence()
            closeConnection()
        }
    }

    func refreshPlayback() { publish() }

    private func clearPresence() {
        if let generation = ownership.generation, socket?.status == .connected {
            socket?.emit("playbackState", ["playing": false, "discord": discord, "generation": generation])
        }
    }

    private func showError(_ message: String) {
        snackbar = Snackbar(title: "Maple", message: message)
    }
}
