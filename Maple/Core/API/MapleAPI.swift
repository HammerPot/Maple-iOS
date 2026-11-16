import Foundation
import UIKit
import ImageIO

struct MapleAPI: Sendable {
    let http: MapleHTTP
    func me() async throws -> MapleUser { try await http.request("get/me") }
    func friends() async throws -> [ListeningProfile] { try await http.request("user/friends/me") }
    func requests() async throws -> FriendRequests { try await http.request("user/friends/me/requests") }
    func profile(username: String) async throws -> Profile { try await http.request("public/get/user/" + Self.segment(username)) }
    func profile(id: String) async throws -> ListeningProfile { try await http.request("public/get/user/id/" + Self.segment(id)) }
    func avatar(id: String) async throws -> Data { try await http.raw("public/get/pfp/" + Self.segment(id)) }
    func artwork(id: String, artwork: String) async throws -> Data {
        try await http.raw("public/get/albumArt/" + Self.segment(id) + "/" + Self.segment(artwork))
    }
    /// URL of a user's current/last-played artwork, for `ArtworkView`. Visible only while their listening is public.
    static func artworkURL(userID: String, artwork: String) -> URL? {
        try? MapleHTTP.requestURL(path: "public/get/albumArt/" + segment(userID) + "/" + segment(artwork))
    }
    func setDisplayName(_ name: String) async throws {
        try await message("user/manage/me", method: "PATCH", body: ["displayName": name])
    }
    func setListeningVisibility(_ visibility: ListeningVisibility) async throws {
        try await message("user/manage/me/listening", method: "PATCH", body: ["visibility": visibility.rawValue])
    }
    func sendRequest(id: String) async throws { try await message("user/friends/me/requests/" + Self.segment(id), method: "POST") }
    func acceptRequest(id: String) async throws { try await message("user/friends/me/requests/" + Self.segment(id) + "/accept", method: "POST") }
    func declineOrCancelRequest(id: String) async throws { try await message("user/friends/me/requests/" + Self.segment(id), method: "DELETE") }
    func removeFriend(id: String) async throws { try await message("user/friends/me/" + Self.segment(id), method: "DELETE") }
    func deleteAccount() async throws { _ = try await http.raw("user/manage/me", method: "DELETE") }
    func setAvatar(_ data: Data) async throws { try await upload(data, field: "pfp") }
    func setAlbumArt(_ data: Data, playbackId: String) async throws { try await upload(data, field: "albumArt", playbackId: playbackId) }

    private func message(_ path: String, method: String, body: [String: String]? = nil) async throws {
        let _: MessageReply = try await http.request(path, method: method, body: body.map { try JSONEncoder().encode($0) })
    }
    private func upload(_ data: Data, field: String, playbackId: String? = nil) async throws {
        let image = try UploadImage.prepare(data)
        let boundary = UUID().uuidString
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field)\"; filename=\"image.\(image.ext)\"\r\nContent-Type: \(image.mime)\r\n\r\n")
        body.append(image.data)
        append("\r\n")
        if let playbackId {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"playbackId\"\r\n\r\n\(playbackId)\r\n")
        }
        append("--\(boundary)--\r\n")
        _ = try await http.raw("user/manage/me/" + field, method: "PUT", body: body, contentType: "multipart/form-data; boundary=\(boundary)")
    }
    private static func segment(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }
}

struct UploadImage {
    let data: Data
    let mime: String
    let ext: String
    static let maxBytes = 3 * 1024 * 1024
    static func prepare(_ data: Data) throws -> UploadImage {
        let bytes = [UInt8](data.prefix(8))
        let format: (String, String)?
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { format = ("image/jpeg", "jpg") }
        else if bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) { format = ("image/png", "png") }
        else if data.starts(with: Data("GIF87a".utf8)) || data.starts(with: Data("GIF89a".utf8)) { format = ("image/gif", "gif") }
        else { format = nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw MapleError(status: 400, message: "Choose a valid image.")
        }
        if let format, data.count <= maxBytes { return UploadImage(data: data, mime: format.0, ext: format.1) }
        // ImageIO downsamples without decoding an arbitrarily large image into memory first.
        for size in [1600, 1000, 640, 320] {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: size]
            if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
               let jpeg = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.8), jpeg.count <= maxBytes {
                return UploadImage(data: jpeg, mime: "image/jpeg", ext: "jpg")
            }
        }
        throw MapleError(status: 413)
    }
}
