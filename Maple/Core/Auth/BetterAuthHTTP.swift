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
        return try JSONDecoder.maple.decode(APIResource<T, C>.self, from: data)
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
