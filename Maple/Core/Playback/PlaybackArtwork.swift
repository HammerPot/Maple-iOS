import Foundation
import ImageIO
import UniformTypeIdentifiers

actor PlaybackArtwork {
    /// Downsample/decode once per loaded track, with no file or image work in SwiftUI bodies.
    private var cachedURL: URL?
    private var cachedData: Data?
    func read(_ url: URL) async -> Data? {
        if cachedURL == url { return cachedData }
        let data: Data
        do {
            if url.isFileURL {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 20 * 1024 * 1024 else { return nil }
                data = try Data(contentsOf: url)
            } else {
                let (bytes, response) = try await URLSession.shared.data(from: url)
                guard let response = response as? HTTPURLResponse, response.statusCode == 200, bytes.count <= 20 * 1024 * 1024 else { return nil }
                data = bytes
            }
        } catch { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 800,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        cachedURL = url; cachedData = result as Data
        return cachedData
    }
}
