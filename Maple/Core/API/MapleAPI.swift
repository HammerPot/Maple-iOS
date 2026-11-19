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
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw MapleError(status: 400, message: "Choose a valid image.")
        }
        // Decode only a bounded thumbnail, applying orientation. Never copy source properties: EXIF, GPS,
        // comments and animation metadata must not reach public avatars or album art. GIFs become stills.
        for size in [1600, 1000, 640, 320] {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: size]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { continue }
            let alpha = [.first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly].contains(image.alphaInfo)
            let output = NSMutableData()
            let type = alpha ? "public.png" : "public.jpeg"
            guard let destination = CGImageDestinationCreateWithData(output, type as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            if CGImageDestinationFinalize(destination), output.length <= maxBytes {
                let encoded = try removingEncoderMetadata(output as Data, png: alpha)
                return UploadImage(data: encoded, mime: alpha ? "image/png" : "image/jpeg", ext: alpha ? "png" : "jpg")
            }
        }
        throw MapleError(status: 413)
    }
    /// ImageIO may synthesize an EXIF block with dimensions/color space even when no source properties
    /// are copied. Remove metadata containers from our freshly encoded image as a final privacy boundary.
    private static func removingEncoderMetadata(_ data: Data, png: Bool) throws -> Data {
        let bytes = [UInt8](data)
        func invalid() -> MapleError { MapleError(status: 400, message: "That image couldn’t be prepared. Choose another photo.") }
        if png {
            guard bytes.count >= 8 else { throw invalid() }
            var output = Data(bytes.prefix(8))
            var offset = 8
            while offset + 12 <= bytes.count {
                let length = bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
                guard length <= bytes.count - offset - 12 else { throw invalid() }
                let end = offset + length + 12
                let type = String(bytes: bytes[offset + 4..<offset + 8], encoding: .ascii)
                if !["eXIf", "tEXt", "zTXt", "iTXt"].contains(type) { output.append(contentsOf: bytes[offset..<end]) }
                offset = end
            }
            guard offset == bytes.count else { throw invalid() }
            return output
        }
        guard bytes.starts(with: [0xff, 0xd8]) else { throw invalid() }
        var output = Data(bytes.prefix(2))
        var offset = 2
        while offset + 4 <= bytes.count {
            guard bytes[offset] == 0xff else { throw invalid() }
            let marker = bytes[offset + 1]
            // The scan and its compressed data are preserved byte-for-byte.
            if marker == 0xda { output.append(contentsOf: bytes[offset...]); return output }
            let length = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            guard length >= 2, length <= bytes.count - offset - 2 else { throw invalid() }
            let end = offset + length + 2
            if marker != 0xe1 && marker != 0xfe { output.append(contentsOf: bytes[offset..<end]) }
            offset = end
        }
        throw invalid()
    }

}
