import Foundation

struct Profile: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let username: String
    let name: String?
    var label: String { name?.isEmpty == false ? name ?? username : username }
}

struct ListeningProfile: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let username: String
    let name: String?
    var listening: Listening?
    var profile: Profile { Profile(id: id, username: username, name: name) }
}

struct MapleUser: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let username: String
    let name: String?
    let pfp: Data?
    let listeningVisibility: ListeningVisibility
    var listening: Listening
    var profile: Profile { Profile(id: id, username: username, name: name) }
}

enum ListeningVisibility: String, Codable, Sendable { case `public`, `private` }
struct Listening: Codable, Equatable, Sendable {
    var current: CurrentPlayback?
    let lastPlayed: LastPlayed?
}
struct CurrentPlayback: Codable, Equatable, Sendable {
    let title: String
    let artist: String
    let album: String
    let duration: Double?
    let playing: Bool
    let position: Double
    let playbackRate: Double
    let artwork: String?
}
struct LastPlayed: Codable, Equatable, Sendable {
    let title: String
    let artist: String
    let album: String
    let duration: Double?
    let playedAt: Date?
    let artwork: String?
}
struct FriendRequests: Codable, Equatable, Sendable {
    var incoming: [Profile] = []
    var outgoing: [Profile] = []
}
struct MessageReply: Codable, Sendable { let message: String }
struct StatusReply: Codable, Sendable { let status: Bool }
struct AuthUser: Codable, Identifiable, Sendable {
    let id: String
    let name: String?
    let email: String
    let emailVerified: Bool
    let username: String?
}
struct AuthSession: Codable, Identifiable, Sendable {
    let id: String
    let token: String
    let userId: String
    let expiresAt: Date
    let createdAt: Date
    let updatedAt: Date
    let ipAddress: String?
    let userAgent: String?
}
struct SessionReply: Codable, Sendable { let user: AuthUser; let session: AuthSession }
struct LinkedAccount: Codable, Identifiable, Sendable {
    let id: String
    let providerId: String
    let accountId: String
}

extension JSONDecoder {
    static var maple: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO timestamp")
        }
        return decoder
    }
}
