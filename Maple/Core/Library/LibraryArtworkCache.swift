import Foundation
import ImageIO
import UniformTypeIdentifiers

actor LibraryArtworkCache {
    private let cache = NSCache<NSString, NSData>()
    init() { cache.totalCostLimit = 24 * 1024 * 1024 }
    func thumbnail(at url: URL, pixels: Int) -> Data? {
        let key = "\(url.path):\(pixels)" as NSString
        if let cached = cache.object(forKey: key) { return cached as Data }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels
              ] as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        cache.setObject(data, forKey: key, cost: data.length)
        return data as Data
    }
}
