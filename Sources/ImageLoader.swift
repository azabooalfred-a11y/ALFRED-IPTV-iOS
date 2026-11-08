import SwiftUI
import UIKit
import ImageIO

/// Loads pictures off the main thread, shrinks them to the size shown and keeps them in memory,
/// so scrolling posters and logos stays smooth.
final class ImageLoader {
    static let shared = ImageLoader()

    private let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 600
        c.totalCostLimit = 120 * 1024 * 1024
        return c
    }()

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.urlCache = URLCache.shared
        c.requestCachePolicy = .returnCacheDataElseLoad
        c.timeoutIntervalForRequest = 20
        c.httpMaximumConnectionsPerHost = 6
        c.httpAdditionalHeaders = ["User-Agent": Xtream.userAgent]
        return URLSession(configuration: c)
    }()

    func cached(_ url: String, _ px: Int) -> UIImage? {
        cache.object(forKey: "\(px)|\(url)" as NSString)
    }

    func load(_ url: String, maxPixels px: Int) async -> UIImage? {
        let key = "\(px)|\(url)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let u = URL(string: url), u.scheme?.hasPrefix("http") == true,
              let res = try? await session.data(from: u) else { return nil }
        let data = res.0
        if Task.isCancelled { return nil }
        let img = await Task.detached(priority: .utility) { ImageLoader.downsample(data, px) }.value
        if let img { cache.setObject(img, forKey: key, cost: Int(img.size.width * img.size.height * 4)) }
        return img
    }

    private static func downsample(_ data: Data, _ px: Int) -> UIImage? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, opts) else { return nil }
        let thumb = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(32, px),
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumb) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// Picture from a link, shrunk to `maxPixels`; shows `placeholder` until it arrives.
struct RemoteImage<Placeholder: View>: View {
    let url: String
    var maxPixels = 300
    var fill = true
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                if fill {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(uiImage: image).resizable().scaledToFit()
                }
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            if let hit = ImageLoader.shared.cached(url, maxPixels) {
                image = hit
                return
            }
            image = nil
            guard !url.isEmpty else { return }
            image = await ImageLoader.shared.load(url, maxPixels: maxPixels)
        }
    }
}
