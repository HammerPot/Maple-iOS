import Foundation
import BetterAuth

/// Callback storage shared by the HTTP actor and app setup. The lock protects every access to the handler.
final class HTTPHook<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (Value) async -> Void)?
    func set(_ handler: (@Sendable (Value) async -> Void)?) { lock.lock(); self.handler = handler; lock.unlock() }
    private func currentHandler() -> (@Sendable (Value) async -> Void)? {
        lock.lock(); defer { lock.unlock() }; return handler
    }
    func fire(_ value: Value) async { await currentHandler()?(value) }
}

/// One cookie jar for Better Auth, REST, image requests and Socket.IO. The library persists it to Keychain.
actor MapleHTTP {
    static let origin = "https://api.maple.music"
    static let baseURL = URL(string: origin + "/") ?? URL(fileURLWithPath: "/")
    static let sessionCookieName = "__Secure-maple.session_token"
    nonisolated let cookies: CookieStorage
    nonisolated let unauthorized = HTTPHook<String>()
    /// Any response may replace a session cookie, including get-session's rolling refresh.
    nonisolated let sessionChanged = HTTPHook<Void>()
    private let session: URLSession
    private var cookieRevision = 0

    init(cookies: CookieStorage = MapleHTTP.persistentCookies(), protocolClasses: [AnyClass]? = nil,
         configuration: URLSessionConfiguration = .ephemeral) {
        self.cookies = cookies
        let config = configuration
        // Apply response cookies ourselves: URLSession would otherwise let a late get-session response
        // delete the replacement cookie from a concurrent password change before we can check its revision.
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
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
        let version = cookieRevision
        attachCookies(to: &request)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        try acceptCookies(from: response, token: token, revision: version)
        if token != sessionToken { await sessionChanged.fire(()) }
        guard (200..<300).contains(response.statusCode) else {
            // Only a 401 for the session that made the request ends the session; 403 never does, and a stale
            // response from before a new sign-in must not sign the new account out.
            if response.statusCode == 401, version == cookieRevision, let token,
               sessionToken == nil || token == sessionToken, Self.sessionBearing(path: path) {
                await unauthorized.fire(token)
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
        let token = sessionToken
        let version = cookieRevision
        attachCookies(to: &request)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        try acceptCookies(from: response, token: token, revision: version)
        if token != sessionToken { await sessionChanged.fire(()) }
        guard (200..<300).contains(response.statusCode) else {
            throw MapleError.response(status: response.statusCode, data: data, contentType: response.value(forHTTPHeaderField: "Content-Type"))
        }
        return data
    }
    /// A credential mutation makes replies already in flight with the old session obsolete.
    func invalidatePendingSessionResponses() { cookieRevision += 1 }
    private func attachCookies(to request: inout URLRequest) {
        request.httpShouldHandleCookies = false
        guard let url = request.url, url.host == Self.baseURL.host else { return }
        for (name, value) in HTTPCookie.requestHeaderFields(with: cookies.cookies(for: url) ?? []) {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }
    private func acceptCookies(from response: HTTPURLResponse, token: String?, revision: Int) throws {
        guard revision == cookieRevision, token == sessionToken,
              let url = response.url, url.scheme == "https", url.host == Self.baseURL.host,
              let header = response.value(forHTTPHeaderField: "Set-Cookie") else { return }
        try cookies.setCookie(header, for: url)
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
