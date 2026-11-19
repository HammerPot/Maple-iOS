import Foundation
import BetterAuth

struct MapleError: Error, LocalizedError, Equatable, Sendable {
    let status: Int
    let code: String?
    let error: String?
    let message: String?

    init(status: Int, code: String? = nil, error: String? = nil, message: String? = nil) {
        self.status = status; self.code = code; self.error = error; self.message = message
    }
    static func response(status: Int, data: Data, contentType: String? = nil) -> MapleError {
        struct Body: Decodable { let code: String?; let error: String?; let message: String? }
        let body = try? JSONDecoder().decode(Body.self, from: data)
        return MapleError(status: status, code: body?.code, error: body?.error,
                          message: body?.message ?? (body == nil ? plainText(data, contentType: contentType) : nil))
    }
    /// Only short plain-text bodies (the server's `Unauthorized`) are user-presentable. HTML error pages from a
    /// proxy or CDN, captive portals and oversized bodies must fall through to the status-based message.
    static func plainText(_ data: Data, contentType: String?) -> String? {
        guard data.count <= 800, contentType?.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespaces) == "text/plain",
              let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, raw.count <= 200, !raw.contains("<"), !raw.contains("\n") else { return nil }
        if let contentType, contentType.lowercased().contains("html") { return nil }
        return raw
    }
    static func normalize(_ error: Error) -> Error {
        if let error = error as? BetterAuthApiError {
            return MapleError(status: error.status ?? 0, code: error.code, message: error.message)
        }
        return error
    }
    var errorDescription: String? {
        switch code {
        case "EMAIL_NOT_VERIFIED": return "Verify your email in your browser, then return here and sign in."
        case "LEGACY_ENROLLMENT_REQUIRED": return "Add an email address to finish moving your Maple account."
        case "USERNAME_REPLACEMENT_REQUIRED": return "Choose a new username to finish moving your account."
        case "INVALID_USERNAME_OR_PASSWORD", "INVALID_EMAIL_OR_PASSWORD", "INVALID_LEGACY_CREDENTIALS": return "The username, email, or password is incorrect."
        case "USERNAME_IS_ALREADY_TAKEN", "USERNAME_TAKEN": return "That username is already taken."
        default:
            if let text = message ?? error, !text.isEmpty, text != "Unauthorized" { return text }
            switch status {
            case 401: return "Your session has ended. Please sign in again."
            case 413: return "Choose an image smaller than 3 MB."
            case 429: return "Too many attempts. Please wait and try again."
            case 500...599: return "Maple is unavailable. Please try again shortly."
            default: return "The request could not be completed. Please try again."
            }
        }
    }
}
