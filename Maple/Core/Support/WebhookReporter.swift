import Foundation

/// Retains the existing opt-in Discord webhook setting without coupling players to HTTP details.
struct WebhookReporter: Sendable {
    func send(track: TrackSnapshot, artwork: Data?, userID: String) async throws {
        let configured = UserDefaults.standard.string(forKey: "webhookURL") ?? ""
        guard !configured.isEmpty else { return }
        guard let url = URL(string: configured), url.scheme == "https" else {
            throw MapleError(status: 400, message: "The webhook URL must use HTTPS.")
        }
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
        let image = try artwork.map(UploadImage.prepare)
        let payload = Payload(avatar_url: MapleHTTP.origin + "/public/get/pfp/" + userID,
            embeds: [Embed(description: "**\(track.title)** by \(track.artist)", fields: [Field(name: "Album", value: track.album.isEmpty ? "Unknown Album" : track.album)], image: image.map { _ in Image(url: "attachment://artwork.jpg") })])
        let boundary = UUID().uuidString
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"payload_json\"\r\nContent-Type: application/json\r\n\r\n")
        body.append(try JSONEncoder().encode(payload)); append("\r\n")
        if let image {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"files[0]\"; filename=\"artwork.jpg\"\r\nContent-Type: \(image.mime)\r\n\r\n")
            body.append(image.data); append("\r\n")
        }
        append("--\(boundary)--\r\n")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(MapleHTTP.origin, forHTTPHeaderField: "Origin")
        let session = URLSession(configuration: .ephemeral)
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw MapleError(status: 0, message: "The configured webhook could not be delivered.")
        }
    }
}
