import AppKit
import Foundation

enum ThumbnailImageCache {
    // NSCache synchronizes access internally.
    nonisolated(unsafe) private static let cache = NSCache<NSString, NSImage>()

    static func image(at url: URL) -> NSImage? {
        let key = url.path as NSString
        if let image = cache.object(forKey: key) {
            return image
        }

        guard FileManager.default.fileExists(atPath: url.path),
              let image = NSImage(contentsOf: url) else {
            return nil
        }

        cache.setObject(image, forKey: key)
        return image
    }
}
