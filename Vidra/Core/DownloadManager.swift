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
    private nonisolated static let indexQueue = DispatchQueue(label: "vidra.downloads.index", qos: .utility)

    @Published private(set) var items: [DownloadItem] = []
    @Published private(set) var active: [String: ActiveDownload] = [:]
    @Published var lastError: String?
    private var tasks: [String: Task<Void, Never>] = [:]
    private var pendingQueue: [(video: Video, audioOnly: Bool)] = []
    private let maxConcurrentDownloads = 2

    private nonisolated static func safeBaseName(for id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let out = String(mapped)
        return out.isEmpty ? UUID().uuidString : out
    }

    private init() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Self.indexURL.path),
              let data = try? Data(contentsOf: Self.indexURL) else { return }
        guard let saved = try? JSONDecoder().decode([DownloadItem].self, from: data) else {
            let backup = Self.dir.appendingPathComponent("index.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? fm.moveItem(at: Self.indexURL, to: backup)
            return
        }
        items = saved.filter { fm.fileExists(atPath: Self.dir.appendingPathComponent($0.file).path) }
    }

    func localFile(for id: String) -> URL? {
        guard let entry = items.first(where: { $0.id == id }) else { return nil }
        let url = Self.dir.appendingPathComponent(entry.file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func localArtwork(for id: String) -> URL? {
        let base = Self.safeBaseName(for: id)
        let thumbURL = Self.dir.appendingPathComponent("\(base).thumb.jpg")
        if FileManager.default.fileExists(atPath: thumbURL.path) {
            return thumbURL
        }
        return nil
    }

    func isDownloaded(_ id: String) -> Bool { localFile(for: id) != nil }

    func isDownloading(_ id: String) -> Bool {
        guard let a = active[id] else { return false }
        return !a.isPaused
    }

    func isPaused(_ id: String) -> Bool {
        active[id]?.isPaused == true
    }

    func start(_ video: Video, audioOnly: Bool) {
        if isDownloaded(video.id) { return }
        if let existing = active[video.id] {
            if existing.isPaused {
                resume(video.id)
            }
            return
        }
        active[video.id] = ActiveDownload(video: video, progress: 0, isPaused: false, audioOnly: audioOnly)
        enqueueOrStart(video: video, audioOnly: audioOnly)
    }

    func pause(_ id: String) {
        guard active[id] != nil else { return }
        active[id]?.isPaused = true
        pendingQueue.removeAll { $0.video.id == id }
        tasks[id]?.cancel()
        tasks[id] = nil
        pumpPendingQueue()
    }

    func resume(_ id: String) {
        guard let currentActive = active[id], currentActive.isPaused else { return }
        active[id]?.isPaused = false
        enqueueOrStart(video: currentActive.video, audioOnly: currentActive.audioOnly)
    }

    func cancel(_ id: String) {
        pendingQueue.removeAll { $0.video.id == id }
        tasks[id]?.cancel()
        tasks[id] = nil
        active[id] = nil
        let base = Self.safeBaseName(for: id)
        let fm = FileManager.default
        let tempFiles = [
            Self.dir.appendingPathComponent("\(base).part"),
            Self.dir.appendingPathComponent("\(base).part.mp4"),
            Self.dir.appendingPathComponent("\(base).part.m4a"),
            Self.dir.appendingPathComponent("\(base)-v.part.mp4"),
            Self.dir.appendingPathComponent("\(base)-a.part.m4a"),
            Self.dir.appendingPathComponent("\(base)-v.part"),
            Self.dir.appendingPathComponent("\(base)-a.part"),
            Self.dir.appendingPathComponent("\(base).thumb.jpg")
        ]
        for p in tempFiles {
            try? fm.removeItem(at: p)
        }
        pumpPendingQueue()
    }

    func delete(_ item: DownloadItem) {
        deleteBatch([item])
    }

    func delete(at offsets: IndexSet) {
        let toDelete = offsets.compactMap { items.indices.contains($0) ? items[$0] : nil }
        deleteBatch(toDelete)
    }

    private func deleteBatch(_ targets: [DownloadItem]) {
        guard !targets.isEmpty else { return }
        let targetIds = Set(targets.map(\.id))
        if let activeId = PlayerManager.shared.current?.id, targetIds.contains(activeId) {
            PlayerManager.shared.close()
        }
        let fm = FileManager.default
        for item in targets {
            try? fm.removeItem(at: Self.dir.appendingPathComponent(item.file))
            if let thumb = item.thumbnailFile {
                try? fm.removeItem(at: Self.dir.appendingPathComponent(thumb))
            }
        }
        items.removeAll { targetIds.contains($0.id) }
        saveIndex()
    }

    func flushIndex() {
        let snapshot = items
        let url = Self.indexURL
        Self.indexQueue.sync {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func enqueueOrStart(video: Video, audioOnly: Bool) {
        if tasks.count < maxConcurrentDownloads {
            startTask(for: video, audioOnly: audioOnly)
        } else if !pendingQueue.contains(where: { $0.video.id == video.id }) {
            pendingQueue.append((video, audioOnly))
        }
    }

    private func pumpPendingQueue() {
        while tasks.count < maxConcurrentDownloads, !pendingQueue.isEmpty {
            let next = pendingQueue.removeFirst()
            if active[next.video.id]?.isPaused == false {
                startTask(for: next.video, audioOnly: next.audioOnly)
            }
        }
    }

    private func startTask(for video: Video, audioOnly: Bool) {
        tasks[video.id]?.cancel()
        tasks[video.id] = Task {
            do {
                let item = try await Self.download(video, audioOnly: audioOnly) { downloaded, total in
                    Task { @MainActor in
                        guard self.active[video.id] != nil, self.active[video.id]?.isPaused == false else { return }
                        let progress = total > 0 ? min(max(Double(downloaded) / Double(total), 0), 1.0) : 0
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
                    if self.active[video.id]?.isPaused != true {
                        self.active[video.id] = nil
                    }
                } else {
                    lastError = "\(video.title): \(error.localizedDescription)"
                    active[video.id] = nil
                }
            }
            tasks[video.id] = nil
            pumpPendingQueue()
        }
    }

    private func saveIndex() {
        let currentItems = items
        let url = Self.indexURL
        Self.indexQueue.async {
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
        let base = safeBaseName(for: video.id)
        let fm = FileManager.default

        var ytId = video.id
        if video.source == .spotify { ytId = try await TrackMatcher.shared.youTubeId(for: video) }
        let resolved = try await InnerTube.shared.directFormats(ytId)
        var meta = resolved.video
        if meta.title.isEmpty || video.source == .spotify { meta = video }
        meta.published = video.published ?? meta.published
        meta.source = video.source
        meta.artwork = video.artwork ?? meta.artwork
        meta.link = video.link ?? meta.link
        let formats = resolved.formats

        var thumbFileName: String? = nil
        if let thumbURL = meta.thumbnail,
           let (thumbData, thumbResp) = try? await URLSession.shared.data(from: thumbURL),
           let http = thumbResp as? HTTPURLResponse,
           (200..<300).contains(http.statusCode),
           !thumbData.isEmpty {
            let thumbDest = dir.appendingPathComponent("\(base).thumb.jpg")
            if (try? thumbData.write(to: thumbDest, options: .atomic)) != nil {
                thumbFileName = "\(base).thumb.jpg"
            }
        }

        if audioOnly {
            guard let a = formats.audio else { throw YTError.noStreams }
            let name = "\(base).m4a"
            let dest = dir.appendingPathComponent(name)
            // Remux DASH fragmented MP4 audio into standard M4A for reliable offline seeking.
            let rawAudioPart = dir.appendingPathComponent("\(base)-a.part.m4a")
            try await fetch(a, to: rawAudioPart, progress: progress)
            do {
                try await Media.remuxAudioToM4A(source: rawAudioPart, to: dest)
                try? fm.removeItem(at: rawAudioPart)
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                try? fm.removeItem(at: dest)
                try fm.moveItem(at: rawAudioPart, to: dest)
            }
            return DownloadItem(video: meta, file: name, audioOnly: true, bytes: fileSize(dest), thumbnailFile: thumbFileName)
        }

        let name = "\(base).mp4"
        let dest = dir.appendingPathComponent(name)

        if let vf = formats.video, let af = formats.audio {
            // Use .mp4/.m4a extensions on temp staging files so AVURLAsset can inspect and merge them cleanly.
            let tv = dir.appendingPathComponent("\(base)-v.part.mp4")
            let ta = dir.appendingPathComponent("\(base)-a.part.m4a")
            let vs = vf.size ?? 0
            let asz = af.size ?? 0
            let estimatedTotal = (vs > 0 && asz > 0) ? (vs + asz) : 0

            do {
                var actualVSize: Int64 = vs
                try await fetch(vf, to: tv) { downloaded, vTotal in
                    let effectiveV = max(vs, vTotal)
                    actualVSize = max(actualVSize, vTotal, downloaded)
                    let overallTotal = estimatedTotal > 0 ? estimatedTotal : (effectiveV + asz)
                    progress(downloaded, overallTotal)
                }
                try await fetch(af, to: ta) { downloaded, aTotal in
                    let effectiveA = max(asz, aTotal)
                    let overallTotal = max(actualVSize + effectiveA, actualVSize + downloaded)
                    progress(actualVSize + downloaded, overallTotal)
                }
                try await Media.merge(video: tv, audio: ta, to: dest)
                try? fm.removeItem(at: tv)
                try? fm.removeItem(at: ta)
                return DownloadItem(video: meta, file: name, audioOnly: false, bytes: fileSize(dest), thumbnailFile: thumbFileName)
            } catch {
                if Task.isCancelled || error is CancellationError {
                    throw CancellationError()
                }
                try? fm.removeItem(at: tv)
                try? fm.removeItem(at: ta)
                try? fm.removeItem(at: dest)
            }
        }

        guard let m = formats.muxed else { throw YTError.noStreams }
        let muxTemp = dir.appendingPathComponent("\(base).part.mp4")
        try await fetch(m, to: muxTemp, progress: progress)
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: muxTemp, to: dest)
        return DownloadItem(video: meta, file: name, audioOnly: false, bytes: fileSize(dest), thumbnailFile: thumbFileName)
    }

    /// Downloads with resumable byte-range support into a temp URL.
    private nonisolated static func fetch(
        _ format: DirectFormat,
        to tempPartURL: URL,
        progress: @escaping (Int64, Int64) -> Void
    ) async throws {
        let fm = FileManager.default
        var existingSize: Int64 = 0
        if fm.fileExists(atPath: tempPartURL.path) {
            existingSize = fileSize(tempPartURL)
        } else {
            fm.createFile(atPath: tempPartURL.path, contents: nil)
        }

        if let expected = format.size, expected > 0, existingSize == expected {
            progress(existingSize, expected)
            return
        }
        if let expected = format.size, expected > 0, existingSize > expected {
            try? Data().write(to: tempPartURL)
            existingSize = 0
        }

        let handle = try FileHandle(forWritingTo: tempPartURL)
        defer { try? handle.close() }

        try await fetchChunks(format, fileURL: tempPartURL, into: handle, existingBytes: existingSize, totalBytes: format.size ?? 0, progress: progress)
    }

    private nonisolated static func fetchChunks(
        _ format: DirectFormat,
        fileURL: URL,
        into handle: FileHandle,
        existingBytes: Int64,
        totalBytes: Int64,
        progress: @escaping (Int64, Int64) -> Void
    ) async throws {
        let chunk: Int64 = 4_000_000 // 4MB chunk for smooth progress & fewer timeouts
        var offset: Int64 = existingBytes
        var total: Int64 = totalBytes

        try handle.seek(toOffset: UInt64(offset))

        while total == 0 || offset < total {
            try Task.checkCancellation()

            let endByte = (total > 0) ? min(offset + chunk - 1, total - 1) : (offset + chunk - 1)
            var req = URLRequest(url: format.url)
            req.setValue("bytes=\(offset)-\(endByte)", forHTTPHeaderField: "Range")
            if format.url.host?.contains("googlevideo") == true {
                req.setValue(format.effectiveUserAgent, forHTTPHeaderField: "User-Agent")
            }

            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw YTError.http(0) }

            if http.statusCode == 416 && offset > 0 {
                // Server reports requested start is at/past EOF -> check if file is complete or reset.
                if let range = http.value(forHTTPHeaderField: "Content-Range"),
                   let serverTotal = range.split(separator: "/").last.flatMap({ Int64($0) }),
                   serverTotal > 0, offset == serverTotal {
                    progress(offset, serverTotal)
                    return
                }
                offset = 0
                try handle.truncate(atOffset: 0)
                try handle.seek(toOffset: 0)
                continue
            }

            guard (200..<300).contains(http.statusCode) else {
                throw YTError.http(http.statusCode)
            }

            // If server ignored Range and returned 200 OK full resource, rewrite from offset 0 cleanly.
            if http.statusCode == 200 && offset > 0 {
                offset = 0
                try handle.truncate(atOffset: 0)
                try handle.seek(toOffset: 0)
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
