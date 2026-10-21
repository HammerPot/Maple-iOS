import Foundation

nonisolated enum MapleLibrary {
    static var directory: URL {
        #if os(macOS)
        URL.applicationSupportDirectory.appending(path: "dev.hammerpot.Maple/Library", directoryHint: .isDirectory)
        #else
        URL.documentsDirectory
        #endif
    }

    static let changed = Notification.Name("MapleLibraryChanged")

    static func prepare() async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(macOS)
        let previousDirectory = URL.documentsDirectory
        guard previousDirectory.path.contains("/Library/Containers/") else { return }
        try migrate(from: previousDirectory, to: directory)
        #endif
    }

    static func migrate(from previousDirectory: URL, to directory: URL) throws {
        let fileManager = FileManager.default
        let marker = directory.appending(path: ".migration-complete")
        guard !fileManager.fileExists(atPath: marker.path) else { return }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for folder in ["tracks", "images", "albums", "artists", "playlists"] {
            let source = previousDirectory.appending(path: folder)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let target = directory.appending(path: folder)
            try copyContents(from: source, to: target)
        }
        try Data().write(to: marker, options: .atomic)
    }
    private static func copyContents(from source: URL, to target: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        for file in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            let destination = target.appending(path: file.lastPathComponent)
            let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isDirectory == true && values.isSymbolicLink != true {
                try copyContents(from: file, to: destination)
            } else if !fileManager.fileExists(atPath: destination.path) {
                try fileManager.copyItem(at: file, to: destination)
            }
        }
    }

}
