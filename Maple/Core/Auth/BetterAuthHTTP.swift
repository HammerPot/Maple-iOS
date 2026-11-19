import Foundation
import CoreFoundation
import BetterAuth

/// The stock client's middleware doesn't run on all routes. This adapter sets Origin unconditionally,
/// uses the shared secure cookie jar, and decodes fractional ISO timestamps used by Better Auth 1.7.
actor BetterAuthHTTP: HTTPClientProtocol {
    nonisolated let cookieStorage: CookieStorageProtocol
    let http: MapleHTTP
    init(http: MapleHTTP) { self.http = http; cookieStorage = http.cookies }
    func perform<T, C>(action: MiddlewareAction?, route: AuthRoutable, body: EncodableAndSendable?, query: EncodableAndSendable?, responseType: T.Type) async throws -> APIResource<T, C> {
        let encoder = JSONEncoder()
        let encoded = try body.map { try encoder.encode($0) }
        var items: [URLQueryItem] = []
        if let query {
            items = Self.queryItems(from: try JSONSerialization.jsonObject(with: encoder.encode(query)) as? [String: Any] ?? [:])
        }
        let data = try await http.raw("api/auth" + route.path, method: route.method, body: encoded, query: items)
        return try JSONDecoder.maple.decode(APIResource<T, C>.self, from: Self.compatibleReply(data, path: route.path))
    }
    func perform<T, C>(route: AuthRoutable, responseType: T.Type) async throws -> APIResource<T, C> {
        try await perform(action: nil, route: route, body: nil, query: nil, responseType: responseType)
    }
    func perform<T, C>(action: MiddlewareAction, route: AuthRoutable, responseType: T.Type) async throws -> APIResource<T, C> {
        try await perform(action: action, route: route, body: nil, query: nil, responseType: responseType)
    }
    func perform<T, C>(route: AuthRoutable, body: EncodableAndSendable, responseType: T.Type) async throws -> APIResource<T, C> {
        try await perform(action: nil, route: route, body: body, query: nil, responseType: responseType)
    }
    func perform<T, C>(route: AuthRoutable, query: EncodableAndSendable, responseType: T.Type) async throws -> APIResource<T, C> {
        try await perform(action: nil, route: route, body: nil, query: query, responseType: responseType)
    }
    /// WebAuthn descriptors may omit transports (`passkey.transports?.split(",")` in @better-auth/passkey 1.7.13).
    /// BetterAuthSwift 2.1.0 requires the array, and spells the server's `requireResidentKey` as `requiresResidentKey`.
    /// Adapt just those SDK differences; the ordinary decoder still validates the rest of the response.
    private static func compatibleReply(_ data: Data, path: String) throws -> Data {
        guard path == "/passkey/generate-register-options" || path == "/passkey/generate-authenticate-options",
              var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return data }
        for key in ["excludeCredentials", "allowCredentials"] {
            if let descriptors = object[key] as? [[String: Any]] {
                object[key] = descriptors.map { descriptor in
                    var descriptor = descriptor
                    if descriptor["transports"] == nil || descriptor["transports"] is NSNull { descriptor["transports"] = [String]() }
                    return descriptor
                }
            }
        }
        if var selection = object["authenticatorSelection"] as? [String: Any], let required = selection["requireResidentKey"] {
            selection["requiresResidentKey"] = required
            object["authenticatorSelection"] = selection
        }
        return try JSONSerialization.data(withJSONObject: object)
    }
    /// JSONSerialization hands booleans back as NSNumber, which `String(describing:)` renders as 1/0.
    static func queryItems(from object: [String: Any]) -> [URLQueryItem] {
        object.sorted { $0.key < $1.key }.compactMap { key, value in
            if value is NSNull { return nil }
            if let number = value as? NSNumber {
                return URLQueryItem(name: key, value: CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue)
            }
            return URLQueryItem(name: key, value: String(describing: value))
        }
    }
}
