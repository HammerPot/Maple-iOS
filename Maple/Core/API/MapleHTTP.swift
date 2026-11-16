import Foundation
import BetterAuth

/// One cookie jar for Better Auth, REST, image requests and Socket.IO. The library persists it to Keychain.
actor MapleHTTP {
    static let origin = "https://api.maple.music"
    static let baseURL = URL(string: origin) ?? URL(fileURLWithPath: "/")
    nonisolated let cookies: CookieStorage
    private let session: URLSession

    init(cookies: CookieStorage = CookieStorage(storage: MapleKeychainStorage())) {
        self.cookies = cookies
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = cookies
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.urlCache = nil
        session = URLSession(configuration: config)
    }

    func raw(_ path: String, method: String = "GET", body: Data? = nil,
             contentType: String = "application/json", query: [URLQueryItem] = []) async throws -> Data {
        var components = URLComponents(url: Self.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(Self.origin, forHTTPHeaderField: "Origin")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(response.statusCode) else {
            throw MapleError.response(status: response.statusCode, data: data)
        }
        return data
    }
    func request<T: Decodable & Sendable>(_ path: String, method: String = "GET", body: Data? = nil) async throws -> T {
        try JSONDecoder.maple.decode(T.self, from: await raw(path, method: method, body: body))
    }
    func clearCookies() { cookies.removeCookies(since: .distantPast) }
    nonisolated var sessionCookies: [HTTPCookie] {
        (cookies.cookies(for: Self.baseURL) ?? []).filter { $0.name == "__Secure-maple.session_token" || $0.name.hasPrefix("__Secure-maple.") || $0.name.hasPrefix("maple.") }
    }
}
