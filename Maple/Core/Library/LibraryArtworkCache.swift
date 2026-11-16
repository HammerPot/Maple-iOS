import UIKit
import ImageIO

/// Downsampled, pre-decoded artwork thumbnails for list rows and grids.
///
/// Thumbnails are produced with ImageIO directly at the requested pixel size, so a row never
/// decodes a full-size cover. Lookups by `cached` are memory-only and safe to call from `body`.
final class LibraryArtworkCache: @unchecked Sendable {
    // NSCache is thread-safe; nothing else is mutable.
    private let cache = NSCache<NSString, UIImage>()

    init() { cache.totalCostLimit = 48 * 1024 * 1024 }

    func cached(_ url: URL, pixels: Int) -> UIImage? { cache.object(forKey: key(url, pixels)) }

    func thumbnail(at url: URL, pixels: Int) async -> UIImage? {
        let key = key(url, pixels)
        if let hit = cache.object(forKey: key) { return hit }
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard !Task.isCancelled,
                  let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceShouldCacheImmediately: true,
                      kCGImageSourceThumbnailMaxPixelSize: max(pixels, 1),
                  ] as CFDictionary) else { return nil }
            return UIImage(cgImage: cgImage)
        }.value
        if let image {
            cache.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * 4))
        }
        return image
    }

    func removeAll() { cache.removeAllObjects() }

    private func key(_ url: URL, _ pixels: Int) -> NSString { "\(url.lastPathComponent)@\(pixels)" as NSString }
}
