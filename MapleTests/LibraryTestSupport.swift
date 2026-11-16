import Foundation
@testable import Maple

/// A temporary directory that tests remove themselves.
func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Metadata reader returning canned results keyed by file name; unknown files are unreadable.
struct StubMetadataReader: LibraryMetadataReading {
    var fixtures: [String: ImportedAudio] = [:]
    func read(_ url: URL) async throws -> ImportedAudio {
        try Task.checkCancellation()
        guard let fixture = fixtures[url.lastPathComponent] else { throw LibraryError.unreadableAudio }
        return fixture
    }
}

/// Wraps the real file system and fails chosen operations, so tests can reproduce a full disk,
/// an unreadable file, or a copy that dies half way. State is lock-protected because the disk
/// actor calls in from its own executor.
final class FaultingFileSystem: LibraryFileSystem, @unchecked Sendable {
    enum Operation: Hashable { case read, write, copy, move, remove, createDirectory }
    struct Rule { var operations: Set<Operation>; var pathFragment: String; var remaining: Int? }

    private let lock = NSLock()
    private let real = DiskFileSystem()
    private var rules: [Rule] = []
    private var partialCopies = false
    private var history: [String] = []
    private var observer: ((Operation, URL) -> Void)?

    /// Fails matching operations. `times` limits how often the rule fires (nil = until `reset`).
    func fail(_ operations: Operation..., pathContaining fragment: String = "", times: Int? = nil) {
        lock.withLock { rules.append(Rule(operations: Set(operations), pathFragment: fragment, remaining: times)) }
    }
    /// A failing copy leaves a truncated destination behind, like a process killed mid-copy.
    func leavePartialCopies(_ value: Bool = true) { lock.withLock { partialCopies = value } }
    func reset() { lock.withLock { rules = []; partialCopies = false } }
    func observe(_ body: ((Operation, URL) -> Void)?) { lock.withLock { observer = body } }
    var operations: [String] { lock.withLock { history } }

    private func check(_ operation: Operation, _ url: URL) throws {
        let (failure, watcher): (Bool, ((Operation, URL) -> Void)?) = lock.withLock {
            history.append("\(operation) \(url.path)")
            for index in rules.indices where rules[index].operations.contains(operation) && url.path.contains(rules[index].pathFragment) {
                if let remaining = rules[index].remaining {
                    guard remaining > 0 else { continue }
                    rules[index].remaining = remaining - 1
                }
                return (true, observer)
            }
            return (false, observer)
        }
        watcher?(operation, url)
        if failure { throw CocoaError(operation == .read ? .fileReadUnknown : .fileWriteOutOfSpace) }
    }

    func read(_ url: URL) throws -> Data { try check(.read, url); return try real.read(url) }
    func write(_ data: Data, to url: URL) throws { try check(.write, url); try real.write(data, to: url) }
    func copy(_ source: URL, to destination: URL) throws {
        do { try check(.copy, destination) } catch {
            if lock.withLock({ partialCopies }) {
                try? real.write(Data("partial".utf8), to: destination)
            }
            throw error
        }
        try real.copy(source, to: destination)
    }
    func move(_ source: URL, to destination: URL) throws { try check(.move, destination); try real.move(source, to: destination) }
    func remove(_ url: URL) throws { try check(.remove, url); try real.remove(url) }
    func createDirectory(_ url: URL) throws { try check(.createDirectory, url); try real.createDirectory(url) }
    func exists(_ url: URL) -> Bool { real.exists(url) }
    func contents(of url: URL) throws -> [URL] { try real.contents(of: url) }
}
