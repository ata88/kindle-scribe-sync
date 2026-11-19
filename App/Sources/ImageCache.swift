import AppKit
import ImageIO
import SwiftUI

/// Decodes images off the main thread at the size they are shown and keeps them
/// in memory – the main reason scrolling is smooth now.
actor ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, CGImage>()

    init() { cache.totalCostLimit = 160 * 1024 * 1024 }

    func image(at url: URL, maxPixel: Int) -> CGImage? {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
            .timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(maxPixel)|\(mtime)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        cache.setObject(img, forKey: key, cost: img.bytesPerRow * img.height)
        return img
    }

    func purge() { cache.removeAllObjects() }
}

/// SwiftUI image backed by `ImageCache`; shows a calm placeholder until decoded.
struct CachedImage: View {
    let url: URL?
    var maxPixel: Int = 800
    var contentMode: ContentMode = .fit
    var placeholderAspect: CGFloat = 0.707
    /// Changes when the file behind `url` was rewritten (same name, new content).
    var revision: String = ""

    @State private var image: CGImage?
    @Environment(\.displayScale) private var scale

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: contentMode)
            } else {
                Rectangle().fill(Color.secondary.opacity(0.08))
                    .aspectRatio(placeholderAspect, contentMode: contentMode)
            }
        }
        .task(id: "\(url?.path ?? "")|\(revision)") {
            guard let url else { return }
            let px = Int(Double(maxPixel) * Double(scale))
            image = await ImageCache.shared.image(at: url, maxPixel: px)
        }
    }
}
