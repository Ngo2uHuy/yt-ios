import Foundation
import UIKit

struct DownloadItem: Codable, Identifiable, Hashable, Sendable {
    var video: Video
    var file: String
    var audioOnly: Bool
    var bytes: Int64
    var thumbnailFile: String?
    var id: String { video.id }
}

struct ActiveDownload: Identifiable {
    let video: Video
    var progress: Double
    var isPaused: Bool = false
    var audioOnly: Bool
    var downloadedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var id: String { video.id }
}

@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    /// Documents/Downloads — visible in the Files app.
    nonisolated static let dir: URL = {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private nonisolated static var indexURL: URL { dir.appendingPathComponent("index.json") }

    @Published private(set) var items: [DownloadItem] = []
    @Published private(set) var active: [String: ActiveDownload] = [:]
    @Published var lastError: String?
    private var tasks: [String: Task<Void, Never>] = [:]

    private init() {
        guard let data = try? Data(contentsOf: Self.indexURL),
              let saved = try? JSONDecoder().decode([DownloadItem].self, from: data) else { return }
        items = saved.filter { FileManager.default.fileExists(atPath: Self.dir.appendingPathComponent($0.file).path) }
    }

    func localFile(for id: String) -> URL? {
        items.first { $0.id == id }.map { Self.dir.appendingPathComponent($0.file) }
    }

    func localArtwork(for id: String) -> URL? {
        let base = id.replacingOccurrences(of: ":", with: "_")
        let thumbURL = Self.dir.appendingPathComponent("\(base).thumb.jpg")
        if FileManager.default.fileExists(atPath: thumbURL.path) {
            return thumbURL
        }
        return nil
    }

    func isDownloaded(_ id: String) -> Bool { items.contains { $0.id == id } }

    func isDownloading(_ id: String) -> Bool {
        guard let a = active[id] else { return false }
        return !a.isPaused
    }

    func isPaused(_ id: String) -> Bool {
        active[id]?.isPaused == true
    }

    func start(_ video: Video, audioOnly: Bool) {
        if let existing = active[video.id] {
            if existing.isPaused {
                resume(video.id)
            }
            return
        }
        active[video.id] = ActiveDownload(video: video, progress: 0, isPaused: false, audioOnly: audioOnly)
        startTask(for: video, audioOnly: audioOnly)
    }

    func pause(_ id: String) {
        guard active[id] != nil else { return }
        active[id]?.isPaused = true
        tasks[id]?.cancel()
        tasks[id] = nil
    }

    func resume(_ id: String) {
        guard let currentActive = active[id], currentActive.isPaused else { return }
        active[id]?.isPaused = false
        startTask(for: currentActive.video, audioOnly: currentActive.audioOnly)
    }

    func cancel(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        active[id] = nil
        let base = id.replacingOccurrences(of: ":", with: "_")
        let fm = FileManager.default
        let partFiles = [
            Self.dir.appendingPathComponent("\(base).part"),
            Self.dir.appendingPathComponent("\(base)-v.part"),
            Self.dir.appendingPathComponent("\(base)-a.part"),
            Self.dir.appendingPathComponent("\(base).thumb.jpg")
        ]
        for p in partFiles {
            try? fm.removeItem(at: p)
        }
    }

    func delete(_ item: DownloadItem) {
        let fm = FileManager.default
        try? fm.removeItem(at: Self.dir.appendingPathComponent(item.file))
        if let thumb = item.thumbnailFile {
            try? fm.removeItem(at: Self.dir.appendingPathComponent(thumb))
        }
        items.removeAll { $0.id == item.id }
        saveIndex()
    }

    private func startTask(for video: Video, audioOnly: Bool) {
        tasks[video.id]?.cancel()
        tasks[video.id] = Task {
            do {
                let item = try await Self.download(video, audioOnly: audioOnly) { downloaded, total in
                    Task { @MainActor in
                        guard self.active[video.id] != nil, self.active[video.id]?.isPaused == false else { return }
                        let progress = total > 0 ? min(Double(downloaded) / Double(total), 1.0) : 0
                        self.active[video.id]?.downloadedBytes = downloaded
                        self.active[video.id]?.totalBytes = total
                        self.active[video.id]?.progress = progress
                    }
                }
                items.removeAll { $0.id == item.id }
                items.insert(item, at: 0)
                saveIndex()
                active[video.id] = nil
            } catch {
                let isCancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
                if isCancelled {
                    // Paused or cancelled: keep state in active dictionary if paused
                    if self.active[video.id]?.isPaused != true {
                        self.active[video.id] = nil
                    }
                } else {
                    lastError = "\(video.title): \(error.localizedDescription)"
                    active[video.id] = nil
                }
            }
            tasks[video.id] = nil
        }
    }

    private func saveIndex() {
        let currentItems = items
        let url = Self.indexURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(currentItems) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    // MARK: - Worker

    private nonisolated static func download(
        _ video: Video,
        audioOnly: Bool,
        progress: @escaping (Int64, Int64) -> Void
    ) async throws -> DownloadItem {
        let base = video.id.replacingOccurrences(of: ":", with: "_")
        let fm = FileManager.default

        var ytId = video.id
        if video.source == .spotify { ytId = try await TrackMatcher.shared.youTubeId(for: video) }
        let resolved = try await InnerTube.shared.directFormats(ytId)
        var meta = resolved.video
        if meta.title.isEmpty || video.source == .spotify { meta = video }
        meta.published = video.published
        meta.source = video.source
        meta.artwork = video.artwork
        let formats = resolved.formats

        // Cache thumbnail locally for offline display
        var thumbFileName: String? = nil
        if let thumbURL = meta.thumbnail,
           let thumbData = try? await URLSession.shared.data(from: thumbURL).0 {
            let thumbDest = dir.appendingPathComponent("\(base).thumb.jpg")
            if (try? thumbData.write(to: thumbDest, options: .atomic)) != nil {
                thumbFileName = "\(base).thumb.jpg"
            }
        }

        if audioOnly {
            guard let a = formats.audio else { throw YTError.noStreams }
            let name = "\(base).m4a"
            let dest = dir.appendingPathComponent(name)
            try await fetch(a, to: dest, progress: progress)
            return DownloadItem(video: meta, file: name, audioOnly: true, bytes: fileSize(dest), thumbnailFile: thumbFileName)
        }

        let name = "\(base).mp4"
        let dest = dir.appendingPathComponent(name)

        if let vf = formats.video, let af = formats.audio {
            let tv = dir.appendingPathComponent("\(base)-v.part")
            let ta = dir.appendingPathComponent("\(base)-a.part")
            let vs = Double(vf.size ?? 1)
            let asz = Double(af.size ?? 0)
            let total = max(vs + asz, 1)

            do {
                try await fetch(vf, to: tv) { downloaded, vTotal in
                    let effectiveTotal = vTotal > 0 ? Int64(total) : 0
                    progress(downloaded, effectiveTotal)
                }
                try await fetch(af, to: ta) { downloaded, aTotal in
                    let currentOverall = Int64(vs) + downloaded
                    let effectiveTotal = aTotal > 0 ? Int64(total) : 0
                    progress(currentOverall, effectiveTotal)
                }
                try await Media.merge(video: tv, audio: ta, to: dest)
                try? fm.removeItem(at: tv)
                try? fm.removeItem(at: ta)
                return DownloadItem(video: meta, file: name, audioOnly: false, bytes: fileSize(dest), thumbnailFile: thumbFileName)
            } catch {
                if Task.isCancelled || error is CancellationError {
                    throw CancellationError()
                }
                // Fallback to muxed stream if separate stream merging failed
                try? fm.removeItem(at: dest)
            }
        }

        guard let m = formats.muxed else { throw YTError.noStreams }
        try await fetch(m, to: dest, progress: progress)
        return DownloadItem(video: meta, file: name, audioOnly: false, bytes: fileSize(dest), thumbnailFile: thumbFileName)
    }

    /// Downloads with support for resuming from existing byte offset
    private nonisolated static func fetch(
        _ format: DirectFormat,
        to dest: URL,
        progress: @escaping (Int64, Int64) -> Void
    ) async throws {
        let fm = FileManager.default
        let isDirectPart = dest.pathExtension == "part"
        let partURL = isDirectPart ? dest : dest.deletingPathExtension().appendingPathExtension("part")

        var existingSize: Int64 = 0
        if fm.fileExists(atPath: partURL.path) {
            existingSize = fileSize(partURL)
        } else {
            fm.createFile(atPath: partURL.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: partURL)
        defer { try? handle.close() }

        do {
            try await fetchChunks(format, into: handle, existingBytes: existingSize, totalBytes: format.size ?? 0, progress: progress)
            try? handle.close()
            if !isDirectPart {
                try? fm.removeItem(at: dest)
                try fm.moveItem(at: partURL, to: dest)
            }
        } catch {
            if Task.isCancelled || error is CancellationError {
                throw CancellationError()
            }
            throw error
        }
    }

    private nonisolated static func fetchChunks(
        _ format: DirectFormat,
        into handle: FileHandle,
        existingBytes: Int64,
        totalBytes: Int64,
        progress: @escaping (Int64, Int64) -> Void
    ) async throws {
        let chunk: Int64 = 8_000_000 // 8MB chunk
        var offset: Int64 = existingBytes
        var total: Int64 = totalBytes > 0 ? totalBytes : (format.size ?? 0)

        try handle.seek(toOffset: UInt64(offset))

        while total == 0 || offset < total {
            try Task.checkCancellation()

            let endByte = (total > 0) ? min(offset + chunk - 1, total - 1) : (offset + chunk - 1)
            var req = URLRequest(url: format.url)
            req.setValue("bytes=\(offset)-\(endByte)", forHTTPHeaderField: "Range")
            if format.url.host?.contains("googlevideo") == true {
                req.setValue(YTClient.ios.userAgent, forHTTPHeaderField: "User-Agent")
            }

            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                throw YTError.http(code)
            }

            if total == 0 {
                if let range = http.value(forHTTPHeaderField: "Content-Range"),
                   let t = range.split(separator: "/").last.flatMap({ Int64($0) }) {
                    total = t
                } else if let len = http.value(forHTTPHeaderField: "Content-Length").flatMap({ Int64($0) }) {
                    total = len
                }
            }

            if data.isEmpty { break }
            try handle.write(contentsOf: data)
            offset += Int64(data.count)
            progress(offset, total)

            if http.statusCode == 200 {
                break
            }
        }
    }

    private nonisolated static func fileSize(_ url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
