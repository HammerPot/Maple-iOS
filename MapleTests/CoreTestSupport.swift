import Foundation
import BetterAuth
import Testing
@testable import Maple

/// Locking is confined to synchronous URLProtocol/Keychain callbacks; model tests remain actor isolated.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func read() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    @discardableResult func update<T>(_ body: (inout Value) -> T) -> T {
        lock.lock(); defer { lock.unlock() }; return body(&value)
    }
}

actor TestGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() { opened = true; let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
}

actor TestSleeper {
    nonisolated let cancellationCount = Locked(0)
    private var pending: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var cancelled: Set<UUID> = []
    private var observers: [CheckedContinuation<Void, Never>] = []
    private(set) var delays: [Duration] = []
    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if cancelled.remove(id) != nil { continuation.resume(throwing: CancellationError()); return }
                delays.append(duration); pending[id] = continuation
                let observers = observers; self.observers = []; observers.forEach { $0.resume() }
            }
        } onCancel: {
            self.cancellationCount.update { $0 += 1 }
            Task { await self.cancel(id) }
        }
    }
    private func cancel(_ id: UUID) {
        if let waiter = pending.removeValue(forKey: id) { waiter.resume(throwing: CancellationError()) }
        else { cancelled.insert(id) }
        let observers = observers; self.observers = []; observers.forEach { $0.resume() }
    }
    var pendingCount: Int { pending.count }
    func waitForNoSleeps() async {
        while !pending.isEmpty { await withCheckedContinuation { observers.append($0) } }
    }
    func waitForSleep() async { await waitForSleeps(1) }
    func waitForSleeps(_ count: Int) async {
        while pending.count < count { await withCheckedContinuation { observers.append($0) } }
    }
    func advance() { let waiters = pending.values; pending = [:]; waiters.forEach { $0.resume() } }
}

struct StubReply: Sendable {
    var status = 200
    var data = Data()
    var headers = ["Content-Type": "application/json"]
    init(_ body: String = "", status: Int = 200, headers: [String: String] = ["Content-Type": "application/json"]) {
        self.status = status; self.data = Data(body.utf8); self.headers = headers
    }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) async throws -> StubReply
    static let handlers = Locked<[String: Handler]>([:])
    private let running = Locked<Task<Void, Never>?>(nil)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let handler = request.value(forHTTPHeaderField: "X-Maple-Test").flatMap { Self.handlers.read()[$0] }
        let task = Task {
            do {
                guard let handler else { throw URLError(.unsupportedURL) }
                let reply = try await handler(request)
                try Task.checkCancellation()
                let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: reply.data)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
        running.update { $0 = task }
    }
    override func stopLoading() { running.read()?.cancel() }
    static func configuration(_ handler: @escaping Handler) -> URLSessionConfiguration {
        let id = UUID().uuidString
        handlers.update { $0[id] = handler }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        config.httpAdditionalHeaders = ["X-Maple-Test": id]
        return config
    }
}

struct MemoryCookieStorage: StorageProtocol {
    func get(key: String) -> String? { nil }
    func save(key: String, value: String) throws -> Bool { true }
}
func testHTTP(token: String? = "test-session", handler: @escaping StubURLProtocol.Handler) throws -> MapleHTTP {
    let jar = CookieStorage(storage: MemoryCookieStorage())
    if let token { try jar.setCookie("__Secure-maple.session_token=\(token); Path=/; Secure; SameSite=None", for: MapleHTTP.baseURL) }
    return MapleHTTP(cookies: jar, configuration: StubURLProtocol.configuration(handler))
}
let testSessionJSON = #"{"user":{"id":"user","email":"unit@example.test","emailVerified":true,"username":"unit","name":null},"session":{"id":"session","token":"test-session","userId":"user","expiresAt":"2030-01-01T00:00:00Z","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}}"#
let testUserJSON = #"{"id":"user","username":"unit","name":null,"pfp":null,"listeningVisibility":"public","listening":{"current":null,"lastPlayed":null}}"#
func signedInReply(_ request: URLRequest) -> StubReply {
    StubReply(request.url?.path == "/api/auth/get-session" ? testSessionJSON : testUserJSON)
}
