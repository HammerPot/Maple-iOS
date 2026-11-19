import Foundation

/// The file operations `LibraryDisk` performs. Production uses `DiskFileSystem`; tests inject
/// a wrapper that fails or interrupts chosen operations (full disk, crash between two writes).
protocol LibraryFileSystem: Sendable {
    func read(_ url: URL) throws -> Data
    /// Replaces the file at `url` in one step: readers see the old or the new bytes, never a mix.
    func write(_ data: Data, to url: URL) throws
    func copy(_ source: URL, to destination: URL) throws
    func move(_ source: URL, to destination: URL) throws
    func remove(_ url: URL) throws
    func createDirectory(_ url: URL) throws
    func exists(_ url: URL) -> Bool
    /// Direct children, including hidden entries.
    func contents(of url: URL) throws -> [URL]
}

struct DiskFileSystem: LibraryFileSystem {
    func read(_ url: URL) throws -> Data { try Data(contentsOf: url) }
    func write(_ data: Data, to url: URL) throws { try data.write(to: url, options: .atomic) }
    func copy(_ source: URL, to destination: URL) throws { try FileManager.default.copyItem(at: source, to: destination) }
    func move(_ source: URL, to destination: URL) throws { try FileManager.default.moveItem(at: source, to: destination) }
    func remove(_ url: URL) throws { try FileManager.default.removeItem(at: url) }
    func createDirectory(_ url: URL) throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    func contents(of url: URL) throws -> [URL] { try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: []) }
}
