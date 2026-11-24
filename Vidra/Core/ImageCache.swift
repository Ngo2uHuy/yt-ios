import Foundation
import SwiftUI
import UIKit
import ImageIO

// MARK: - High-Performance Memory Decoded Image Cache

/// Thread-safe in-memory bitmap cache with automatic memory pressure handling and cost tracking.
/// Eliminates JPEG/PNG decoding overhead during 60/120Hz list and grid scrolling.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private let cache = NSCache<NSURL, UIImage>()

    private init() {
        cache.countLimit = 350
        cache.totalCostLimit = 150 * 1024 * 1024 // 150 MB memory limit

        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.clear()
        }
        #endif
    }

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func insert(_ image: UIImage, for url: URL) {
        let pixelCount = Int(image.size.width * image.scale * image.size.height * image.scale)
        let cost = pixelCount * 4
        cache.setObject(image, forKey: url as NSURL, cost: cost)
    }

    func remove(for url: URL) {
        cache.removeObject(forKey: url as NSURL)
    }

    func clear() {
        cache.removeAllObjects()
    }

    /// Downsamples an image directly from raw data to the target display size using ImageIO.
    /// Recommended by Apple WWDC to prevent decoding full-resolution textures into memory.
    static func downsample(data: Data, to pointSize: CGSize, scale: CGFloat = 2.0) -> UIImage? {
        let maxDimensionInPixels = max(pointSize.width, pointSize.height) * scale
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]

        guard let imageSource = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
            return UIImage(data: data)
        }

        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimensionInPixels
        ]

        guard let downsampledImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, downsampleOptions as CFDictionary) else {
            return UIImage(data: data)
        }

        return UIImage(cgImage: downsampledImage)
    }
}

// MARK: - CachedAsyncImage Component

/// Drop-in replacement for SwiftUI's `AsyncImage` with in-memory bitmap cache and zero-delay synchronous rendering.
struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL?
    var targetSize: CGSize? = nil
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var uiImage: UIImage?

    init(
        url: URL?,
        targetSize: CGSize? = nil,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.targetSize = targetSize
        self.content = content
        self.placeholder = placeholder

        if let url, let cached = ImageCache.shared.image(for: url) {
            _uiImage = State(initialValue: cached)
        }
    }

    var body: some View {
        Group {
            if let uiImage {
                content(Image(uiImage: uiImage))
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else {
                uiImage = nil
                return
            }

            // 1. Fast cache check
            if let cached = ImageCache.shared.image(for: url) {
                if uiImage !== cached {
                    uiImage = cached
                }
                return
            }

            // 2. Background asynchronous fetch & decode
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard !Task.isCancelled else { return }

                let decoded: UIImage?
                if let size = targetSize, size.width > 0, size.height > 0 {
                    decoded = ImageCache.downsample(data: data, to: size)
                } else {
                    decoded = UIImage(data: data)
                }

                guard let img = decoded, !Task.isCancelled else { return }
                ImageCache.shared.insert(img, for: url)

                withAnimation(.easeIn(duration: 0.16)) {
                    uiImage = img
                }
            } catch {
                // Keep placeholder visible on failure
            }
        }
    }
}
