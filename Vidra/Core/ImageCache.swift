import Foundation
import SwiftUI
import UIKit
import ImageIO
#if canImport(Darwin)
import Darwin
#endif

// MARK: - High-Performance Memory Decoded Image Cache

/// Thread-safe in-memory bitmap cache with strict memory bounds (< 120MB app RAM),
/// off-main-thread ImageIO downsampling, in-flight request deduplication, and automatic memory warning purging.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [NSString: (id: UUID, task: Task<UIImage?, Never>)] = [:]
    private var trackedKeysByURL: [String: Set<NSString>] = [:]
    private let lock = NSLock()
    private var lastPressurePurge: Date = .distantPast

    private var _screenScale: CGFloat = 3.0
    private var _maxSafePointSize = CGSize(width: 480, height: 854)

    var screenScale: CGFloat {
        lock.lock()
        defer { lock.unlock() }
        return _screenScale
    }

    private var maxSafePointSize: CGSize {
        lock.lock()
        defer { lock.unlock() }
        return _maxSafePointSize
    }

    static let maxCacheCostBytes = 32 * 1024 * 1024 // 32 MB
    static let maxCacheCount = 150

    private init() {
        cache.countLimit = Self.maxCacheCount
        cache.totalCostLimit = Self.maxCacheCostBytes

        #if canImport(UIKit)
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                self._screenScale = UIScreen.main.scale
                let b = UIScreen.main.bounds.size
                self._maxSafePointSize = CGSize(width: min(max(b.width, 320), 640), height: min(max(b.height, 480), 960))
            }
        } else {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let scale = UIScreen.main.scale
                let b = UIScreen.main.bounds.size
                self.lock.lock()
                self._screenScale = scale
                self._maxSafePointSize = CGSize(width: min(max(b.width, 320), 640), height: min(max(b.height, 480), 960))
                self.lock.unlock()
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.clear()
            URLCache.shared.removeAllCachedResponses()
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.clear()
        }
        #endif
    }

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

    private func checkMemoryPressure() {
        #if canImport(Darwin)
        lock.lock()
        let shouldCheck = Date().timeIntervalSince(lastPressurePurge) > 5
        if shouldCheck { lastPressurePurge = Date() }
        lock.unlock()
        guard shouldCheck else { return }

        if Self.currentProcessMemoryMB > 110.0 {
            cache.removeAllObjects()
            lock.lock()
            trackedKeysByURL.removeAll()
            lock.unlock()
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
        let cost = max(1, pixelCount * 4)
        cache.setObject(image, forKey: key, cost: cost)
        lock.lock()
        trackedKeysByURL[url.absoluteString, default: []].insert(key)
        lock.unlock()
    }

    func remove(for url: URL) {
        lock.lock()
        let keys = trackedKeysByURL.removeValue(forKey: url.absoluteString) ?? []
        lock.unlock()
        cache.removeObject(forKey: url.absoluteString as NSString)
        for k in keys {
            cache.removeObject(forKey: k)
        }
    }

    func clear() {
        lock.lock()
        let tasks = inFlight.values.map(\.task)
        inFlight.removeAll()
        trackedKeysByURL.removeAll()
        lock.unlock()
        for task in tasks {
            task.cancel()
        }
        cache.removeAllObjects()
    }

    func load(url: URL, targetSize: CGSize? = nil, scale: CGFloat? = nil) async -> UIImage? {
        let actualScale = scale ?? screenScale
        let key = cacheKey(for: url, targetSize: targetSize, scale: actualScale)

        if let cached = cache.object(forKey: key) {
            return cached
        }
        if targetSize != nil {
            let baseKey = cacheKey(for: url, targetSize: nil, scale: actualScale)
            if let cached = cache.object(forKey: baseKey) {
                return cached
            }
        }

        lock.lock()
        if let existing = inFlight[key]?.task {
            lock.unlock()
            return await existing.value
        }

        // Read `_maxSafePointSize` directly while `lock` is held to avoid re-entering non-recursive NSLock.
        let safeSize = _maxSafePointSize
        let requestId = UUID()
        let task = Task<UIImage?, Never> { [weak self] in
            defer {
                if let self {
                    self.lock.lock()
                    if self.inFlight[key]?.id == requestId {
                        self.inFlight.removeValue(forKey: key)
                    }
                    self.lock.unlock()
                }
            }
            guard !Task.isCancelled else { return nil }
            guard let (data, resp) = try? await URLSession.shared.data(from: url),
                  !Task.isCancelled else {
                return nil
            }
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return nil
            }
            guard !data.isEmpty else { return nil }

            let decoded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                let chosenSize = (targetSize != nil && targetSize!.width > 0 && targetSize!.height > 0)
                    ? targetSize!
                    : safeSize
                let img = ImageCache.downsample(data: data, to: chosenSize, scale: actualScale)
                if #available(iOS 15.0, *) {
                    return img?.preparingForDisplay() ?? img
                }
                return img
            }.value

            guard let self, let image = decoded, !Task.isCancelled else { return nil }
            self.insert(image, for: url, targetSize: targetSize, scale: actualScale)
            return image
        }
        inFlight[key] = (requestId, task)
        lock.unlock()

        return await task.value
    }

    static func downsample(data: Data, to pointSize: CGSize, scale: CGFloat? = nil) -> UIImage? {
        let actualScale = scale ?? ImageCache.shared.screenScale
        let maxDimensionInPixels = max(pointSize.width, pointSize.height) * actualScale
        guard maxDimensionInPixels > 0 else { return UIImage(data: data) }

        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
            return nil
        }

        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimensionInPixels
        ]

        guard let downsampledImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, downsampleOptions as CFDictionary) else {
            return nil
        }

        return UIImage(cgImage: downsampledImage, scale: actualScale, orientation: .up)
    }
}

// MARK: - CachedAsyncImage Component

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

            if let cached = ImageCache.shared.image(for: url, targetSize: targetSize) {
                if uiImage !== cached {
                    uiImage = cached
                }
                return
            }
            uiImage = nil

            if let img = await ImageCache.shared.load(url: url, targetSize: targetSize), !Task.isCancelled {
                withAnimation(.easeIn(duration: 0.16)) {
                    uiImage = img
                }
            }
        }
    }
}
