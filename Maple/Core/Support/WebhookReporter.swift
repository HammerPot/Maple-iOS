import Foundation

/// Retains the existing opt-in Discord webhook setting without coupling players to HTTP details.
/// One reused, cookie-less session; no Maple `Origin` (this is a third-party host).
actor WebhookReporter {
    private let session: URLSession
    private let configuredURL: @Sendable () async -> String
    private let now: @Sendable () -> TimeInterval
    private let sleep: @Sendable (Duration) async throws -> Void
    private let minimumInterval: TimeInterval
    private var lastAttempt: TimeInterval?
    private var latest = 0
    init(session: URLSession = WebhookReporter.makeSession(), minimumInterval: TimeInterval = 10,
         configuredURL: @escaping @Sendable () async -> String = { "" },
         now: @escaping @Sendable () -> TimeInterval = { PlaybackReporter.monotonicNow() },
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.session = session; self.minimumInterval = minimumInterval; self.configuredURL = configuredURL
        self.now = now; self.sleep = sleep
    }
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil
        return URLSession(configuration: config)
    }
    func send(track: TrackSnapshot, artwork: Data?, userID: String) async throws {
        let configured = await configuredURL()
        guard !configured.isEmpty else { return }
        guard let url = URL(string: configured), url.scheme == "https" else {
            throw MapleError(status: 400, message: "The webhook URL must use HTTPS.")
        }
        // Rate guard: at most one post per `minimumInterval`. Calls inside the window wait for it to reopen and
        // only the newest survives, so rapid skipping posts once, for the track the user settled on.
        latest += 1
        let ticket = latest
        if let lastAttempt {
            let wait = minimumInterval - (now() - lastAttempt)
            if wait > 0 { try await sleep(.milliseconds(Int((wait * 1000).rounded(.up)))) }
            guard ticket == latest else { return }
        }
        lastAttempt = now()
        struct Payload: Encodable {
            let username = "Maple-iOS"
            let avatar_url: String
            let embeds: [Embed]
        }
        struct Embed: Encodable {
            let title = "Now Playing"
            let description: String
            let fields: [Field]
            let image: Image?
        }
        struct Field: Encodable { let name: String; let value: String }
        struct Image: Encodable { let url: String }
        let image = artwork.flatMap { try? UploadImage.prepare($0) }
        let payload = Payload(avatar_url: MapleHTTP.origin + "/public/get/pfp/" + userID,
            embeds: [Embed(description: "**\(track.title)** by \(track.artist)", fields: [Field(name: "Album", value: track.album.isEmpty ? "Unknown Album" : track.album)], image: image.map { _ in Image(url: "attachment://artwork.\(image?.ext ?? "jpg")") })])
        let boundary = UUID().uuidString
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"payload_json\"\r\nContent-Type: application/json\r\n\r\n")
        body.append(try JSONEncoder().encode(payload)); append("\r\n")
        if let image {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"files[0]\"; filename=\"artwork.\(image.ext)\"\r\nContent-Type: \(image.mime)\r\n\r\n")
            body.append(image.data); append("\r\n")
        }
        append("--\(boundary)--\r\n")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw MapleError(status: 0, message: "The configured webhook could not be delivered.")
        }
    }
}
