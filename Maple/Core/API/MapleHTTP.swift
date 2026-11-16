import Foundation
import BetterAuth

/// Called when an authenticated request is rejected with 401 for the session that sent it.
final class UnauthorizedHook: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (String) async -> Void)?
    func set(_ handler: (@Sendable (String) async -> Void)?) { lock.lock(); self.handler = handler; lock.unlock() }
    private func currentHandler() -> (@Sendable (String) async -> Void)? {
        lock.lock(); defer { lock.unlock() }; return handler
    }
    func fire(token: String) async { await currentHandler()?(token) }
}

/// One cookie jar for Better Auth, REST, image requests and Socket.IO. The library persists it to Keychain.
actor MapleHTTP {
    static let origin = "https://api.maple.music"
    static let baseURL = URL(string: origin + "/") ?? URL(fileURLWithPath: "/")
    static let sessionCookieName = "__Secure-maple.session_token"
    nonisolated let cookies: CookieStorage
    nonisolated let unauthorized = UnauthorizedHook()
    private let session: URLSession

    init(cookies: CookieStorage = MapleHTTP.persistentCookies(), protocolClasses: [AnyClass]? = nil,
         configuration: URLSessionConfiguration = .ephemeral) {
        self.cookies = cookies
        let config = configuration
        config.httpCookieStorage = cookies
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.urlCache = nil
        if let protocolClasses { config.protocolClasses = protocolClasses }
        session = URLSession(configuration: config)
    }

    /// Keychain items outlive app deletion, so a fresh install must not inherit the previous install's session.
    nonisolated static func persistentCookies(defaults: UserDefaults = .standard,
        onSaveFailure: @escaping @Sendable (MapleError) -> Void = { _ in }) -> CookieStorage {
        MapleKeychainStorage.wipeIfFreshInstall(defaults: defaults)
        return CookieStorage(storage: MapleKeychainStorage(onSaveFailure: onSaveFailure))
    }

    func raw(_ path: String, method: String = "GET", body: Data? = nil,
             contentType: String = "application/json", query: [URLQueryItem] = []) async throws -> Data {
        let url = try Self.requestURL(path: path, query: query)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(Self.origin, forHTTPHeaderField: "Origin")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let token = sessionToken
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(response.statusCode) else {
            // Only a 401 for the session that made the request ends the session; 403 never does, and a stale
            // response from before a new sign-in must not sign the new account out.
            if response.statusCode == 401, let token, token == sessionToken, Self.sessionBearing(path: path) {
                await unauthorized.fire(token: token)
            }
            throw MapleError.response(status: response.statusCode, data: data, contentType: response.value(forHTTPHeaderField: "Content-Type"))
        }
        return data
    }
    func request<T: Decodable & Sendable>(_ path: String, method: String = "GET", body: Data? = nil) async throws -> T {
        try JSONDecoder.maple.decode(T.self, from: await raw(path, method: method, body: body))
    }
    /// Routes where a 401 means the stored session is no longer valid (as opposed to wrong credentials).
    nonisolated static func sessionBearing(path: String) -> Bool {
        if path.hasPrefix("public/") { return false }
        guard path.hasPrefix("api/auth") else { return true }
        let anonymous = ["sign-in", "sign-up", "legacy", "request-password-reset", "reset-password", "send-verification-email",
                         "sign-out", "passkey/generate-authenticate-options", "passkey/verify-authentication", "verify-email"]
        let route = path.dropFirst("api/auth/".count)
        return !anonymous.contains { route.hasPrefix($0) }
    }
    /// Paths already contain escaped individual segments. Do not escape percent signs a second time.
    nonisolated static func requestURL(path: String, query: [URLQueryItem] = []) throws -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.percentEncodedPath = "/" + path
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw URLError(.badURL) }
        return url
    }
    func image(at url: URL) async throws -> Data {
        guard url.scheme == "https" else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        // The Maple origin is only meaningful (and only sent) to Maple's own host.
        if url.host == MapleHTTP.baseURL.host { request.setValue(Self.origin, forHTTPHeaderField: "Origin") }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(response.statusCode) else {
            throw MapleError.response(status: response.statusCode, data: data, contentType: response.value(forHTTPHeaderField: "Content-Type"))
        }
        return data
    }
    /// Revokes the captured old session without reading or modifying a subsequent sign-in's cookie jar.
    func revokeSession(cookies: [HTTPCookie]) async {
        try? await revokeCapturedSession(cookies: cookies, everywhere: false)
    }
    /// Explicit sign-out uses the captured cookie after local invalidation, without touching a later session.
    func revokeCapturedSession(cookies: [HTTPCookie], everywhere: Bool) async throws {
        guard !cookies.isEmpty else { return }
        let path = everywhere ? "api/auth/revoke-sessions" : "api/auth/sign-out"
        var request = URLRequest(url: Self.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"; request.httpShouldHandleCookies = false; request.timeoutInterval = 5
        request.setValue(Self.origin, forHTTPHeaderField: "Origin")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(HTTPCookie.requestHeaderFields(with: cookies)["Cookie"], forHTTPHeaderField: "Cookie")
        request.httpBody = Data("{}".utf8)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(response.statusCode) else {
            throw MapleError.response(status: response.statusCode, data: data,
                                      contentType: response.value(forHTTPHeaderField: "Content-Type"))
        }
    }
    nonisolated func clearCookies() { cookies.removeCookies(since: .distantPast) }
    nonisolated var sessionToken: String? { sessionCookies.first { $0.name == Self.sessionCookieName }?.value }
    nonisolated var sessionCookies: [HTTPCookie] {
        (cookies.cookies(for: Self.baseURL) ?? []).filter { $0.name == "__Secure-maple.session_token" || $0.name.hasPrefix("__Secure-maple.") || $0.name.hasPrefix("maple.") }
    }
}
