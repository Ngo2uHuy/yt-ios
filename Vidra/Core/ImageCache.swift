import Foundation
import SwiftUI
import UIKit
import ImageIO
#if canImport(Darwin)
import Darwin
#endif

// MARK: - High-Performance Memory Decoded Image Cache

/// Thread-safe in-memory bitmap cache with strict memory bounds (< 120MB app RAM),
/// off-main-thread ImageIO downsampling accurately calculated by display frame size × device scale,
/// GPU texture pre-warming, in-flight request deduplication, and automatic memory warning purging.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [NSString: Task<UIImage?, Never>] = [:]
    private let inFlightLock = NSLock()

    /// Hardware device scale factor (e.g. 2.0x on standard screens, 3.0x on Retina Super Retina Pro).
    let screenScale: CGFloat = {
        #if canImport(UIKit)
        if Thread.isMainThread {
            return UIScreen.main.scale
        }
        #endif
        return 2.0
    }()

    /// Memory budget for cached textures (40 MB max) ensuring app stays well below 120MB RAM limit.
    static let maxCacheCostBytes = 40 * 1024 * 1024 // 40 MB
    static let maxCacheCount = 150

    private init() {
        cache.countLimit = Self.maxCacheCount
        cache.totalCostLimit = Self.maxCacheCostBytes

        #if canImport(UIKit)
        // Auto-purge cache when iOS triggers memory pressure warning
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.clear()
            URLCache.shared.removeAllCachedResponses()
        }

        // Auto-purge cache when app enters background to prevent jetsam termination
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.clear()
        }
        #endif
    }

    /// Current resident memory of the process in Megabytes (MB).
    static var currentProcessMemoryMB: Double {
        #if canImport(Darwin)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / 4)
        let kerr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if kerr == KERN_SUCCESS {
            return Double(info.resident_size) / (1024 * 1024)
        }
        #endif
        return 0
    }

    /// Automatically purges cached textures if total process memory approaches the 120MB ceiling.
    private func checkMemoryPressure() {
        #if canImport(Darwin)
        let mem = Self.currentProcessMemoryMB
        if mem > 100.0 { // Enforce RAM stays strictly under 120MB
            clear()
        }
        #endif
    }

    func cacheKey(for url: URL, targetSize: CGSize?, scale: CGFloat) -> NSString {
        if let size = targetSize, size.width > 0, size.height > 0 {
            let pxW = Int((size.width * scale).rounded())
            let pxH = Int((size.height * scale).rounded())
            return "\(url.absoluteString)@\(pxW)x\(pxH)" as NSString
        }
        return url.absoluteString as NSString
    }

    func image(for url: URL, targetSize: CGSize? = nil, scale: CGFloat? = nil) -> UIImage? {
        let actualScale = scale ?? screenScale
        let key = cacheKey(for: url, targetSize: targetSize, scale: actualScale)
        if let cached = cache.object(forKey: key) {
            return cached
        }
        if targetSize != nil {
            let baseKey = cacheKey(for: url, targetSize: nil, scale: actualScale)
            return cache.object(forKey: baseKey)
        }
        return nil
    }

    func insert(_ image: UIImage, for url: URL, targetSize: CGSize? = nil, scale: CGFloat? = nil) {
        checkMemoryPressure()
        let actualScale = scale ?? image.scale
        let key = cacheKey(for: url, targetSize: targetSize, scale: actualScale)
        let pixelCount = Int(image.size.width * image.scale * image.size.height * image.scale)
        let cost = pixelCount * 4
        cache.setObject(image, forKey: key, cost: cost)
    }

    func remove(for url: URL) {
        cache.removeObject(forKey: url.absoluteString as NSString)
    }

    func clear() {
        inFlightLock.lock()
        for (_, task) in inFlight {
            task.cancel()
        }
        inFlight.removeAll()
        inFlightLock.unlock()
        cache.removeAllObjects()
    }

    /// Asynchronously loads, downsamples using ImageIO according to display frame size × device scale,
    /// and pre-decodes the bitmap off the main thread with request deduplication.
    func load(url: URL, targetSize: CGSize? = nil, scale: CGFloat? = nil) async -> UIImage? {
        let actualScale = scale ?? screenScale
        let key = cacheKey(for: url, targetSize: targetSize, scale: actualScale)

        // 1. In-memory cache hit
        if let cached = cache.object(forKey: key) {
            return cached
        }
        if targetSize != nil {
            let baseKey = cacheKey(for: url, targetSize: nil, scale: actualScale)
            if let cached = cache.object(forKey: baseKey) {
                return cached
            }
        }

        // 2. Request deduplication
        inFlightLock.lock()
        if let existing = inFlight[key] {
            inFlightLock.unlock()
            return await existing.value
        }

        let task = Task<UIImage?, Never> {
            guard !Task.isCancelled else { return nil }

            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  !Task.isCancelled else {
                return nil
            }

            // Decode and prepare for display off the main thread
            let decoded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                let img: UIImage?
                if let size = targetSize, size.width > 0, size.height > 0 {
                    img = ImageCache.downsample(data: data, to: size, scale: actualScale)
                } else {
                    // Default safe downsampling: cap at max screen dimension to prevent uncompressed 4K/1080p RAM bloat
                    #if canImport(UIKit)
                    let screenBounds = UIScreen.main.bounds.size
                    let safeSize = CGSize(width: min(screenBounds.width, 480), height: min(screenBounds.height, 854))
                    img = ImageCache.downsample(data: data, to: safeSize, scale: actualScale)
                    #else
                    img = UIImage(data: data)
                    #endif
                }
                if #available(iOS 15.0, *) {
                    return img?.preparingForDisplay() ?? img
                }
                return img
            }.value

            guard let image = decoded, !Task.isCancelled else { return nil }
            self.insert(image, for: url, targetSize: targetSize, scale: actualScale)
            return image
        }

        inFlight[key] = task
        inFlightLock.unlock()

        let result = await task.value

        inFlightLock.lock()
        inFlight.removeValue(forKey: key)
        inFlightLock.unlock()

        return result
    }

    /// Downsamples an image directly from raw data to the exact target display size × scale using ImageIO.
    /// Recommended by Apple WWDC to prevent decoding full-resolution textures into memory.
    static func downsample(data: Data, to pointSize: CGSize, scale: CGFloat? = nil) -> UIImage? {
        let actualScale = scale ?? ImageCache.shared.screenScale
        let maxDimensionInPixels = max(pointSize.width, pointSize.height) * actualScale
        guard maxDimensionInPixels > 0 else { return UIImage(data: data) }

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

        return UIImage(cgImage: downsampledImage, scale: actualScale, orientation: .up)
    }
}

// MARK: - CachedAsyncImage Component

/// Drop-in replacement for SwiftUI's `AsyncImage` with in-memory bitmap cache,
/// ImageIO downsampling matching target display frame × device scale, and zero-delay synchronous rendering.
struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL?
    var targetSize: CGSize? = nil
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var uiImage: UIImage?

    private var cacheKey: String {
        let urlStr = url?.absoluteString ?? ""
        if let targetSize {
            let pxW = Int(targetSize.width.rounded())
            let pxH = Int(targetSize.height.rounded())
            return "\(urlStr)_\(pxW)x\(pxH)"
        }
        return urlStr
    }

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

        if let url, let cached = ImageCache.shared.image(for: url, targetSize: targetSize) {
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
        .task(id: cacheKey) {
            guard let url else {
                uiImage = nil
                return
            }

            // 1. Fast cache check
            if let cached = ImageCache.shared.image(for: url, targetSize: targetSize) {
                if uiImage !== cached {
                    uiImage = cached
                }
                return
            }
            uiImage = nil

            // 2. High-performance deduplicated asynchronous fetch & off-thread decode
            if let img = await ImageCache.shared.load(url: url, targetSize: targetSize), !Task.isCancelled {
                withAnimation(.easeIn(duration: 0.16)) {
                    uiImage = img
                }
            }
        }
    }
}
