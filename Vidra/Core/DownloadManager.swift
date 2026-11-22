import Foundation

struct DownloadItem: Codable, Identifiable, Hashable {
    var video: Video
    var file: String
    var audioOnly: Bool
    var bytes: Int64
    var id: String { video.id }
}

struct ActiveDownload: Identifiable {
    let video: Video
    var progress: Double
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

    func isDownloaded(_ id: String) -> Bool { items.contains { $0.id == id } }

    func start(_ video: Video, audioOnly: Bool) {
        guard active[video.id] == nil else { return }
        active[video.id] = ActiveDownload(video: video, progress: 0)
        tasks[video.id] = Task {
            do {
                let item = try await Self.download(video, audioOnly: audioOnly) { p in
                    Task { @MainActor in self.active[video.id]?.progress = p }
                }
                items.removeAll { $0.id == item.id }
                items.insert(item, at: 0)
                saveIndex()
            } catch {
                // URLSession reports cancellation as URLError(.cancelled), not CancellationError.
                let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
                if !cancelled { lastError = "\(video.title): \(error.localizedDescription)" }
            }
            active[video.id] = nil
            tasks[video.id] = nil
        }
    }

    func cancel(_ id: String) { tasks[id]?.cancel() }

    func delete(_ item: DownloadItem) {
        try? FileManager.default.removeItem(at: Self.dir.appendingPathComponent(item.file))
        items.removeAll { $0.id == item.id }
        saveIndex()
    }

    private func saveIndex() {
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: Self.indexURL, options: .atomic) }
    }

    // MARK: - Worker

    private nonisolated static func download(_ video: Video, audioOnly: Bool,
                                             progress: @escaping (Double) -> Void) async throws -> DownloadItem {
        let base = video.id.replacingOccurrences(of: ":", with: "_")

        if video.source == .soundCloud {
            let r = try await SoundCloud.shared.resolve(video.id)
            guard case .progressive(let url)? = r.sources.first else {
                throw YTError.unplayable("Bài này chỉ nghe trực tuyến, không tải được")
            }
            let name = "\(base).mp3"
            let dest = dir.appendingPathComponent(name)
            let f = DirectFormat(url: url, size: nil, height: nil, bitrate: 0, mime: "audio/mpeg", isDefaultAudio: true)
            try await fetch(f, to: dest, progress: progress)
            return DownloadItem(video: video, file: name, audioOnly: true, bytes: fileSize(dest))
        }

        var ytId = video.id
        if video.source == .spotify { ytId = try await TrackMatcher.shared.youTubeId(for: video) }
        let resolved = try await InnerTube.shared.directFormats(ytId)
        var meta = resolved.video
        if meta.title.isEmpty || video.source == .spotify { meta = video }
        meta.published = video.published
        meta.source = video.source
        meta.artwork = video.artwork
        let formats = resolved.formats
        let fm = FileManager.default

        if audioOnly {
            guard let a = formats.audio else { throw YTError.noStreams }
            let name = "\(base).m4a"
            let dest = dir.appendingPathComponent(name)
            try await fetch(a, to: dest, progress: progress)
            return DownloadItem(video: meta, file: name, audioOnly: true, bytes: fileSize(dest))
        }

        let name = "\(base).mp4"
        let dest = dir.appendingPathComponent(name)
        try? fm.removeItem(at: dest)

        if let vf = formats.video, let af = formats.audio {
            let tv = fm.temporaryDirectory.appendingPathComponent("\(video.id)-v.mp4")
            let ta = fm.temporaryDirectory.appendingPathComponent("\(video.id)-a.m4a")
            defer { try? fm.removeItem(at: tv); try? fm.removeItem(at: ta) }
            let vs = Double(vf.size ?? 1), asz = Double(af.size ?? 0), total = max(vs + asz, 1)
            do {
                try await fetch(vf, to: tv) { progress($0 * vs / total * 0.98) }
                try await fetch(af, to: ta) { progress((vs + $0 * asz) / total * 0.98) }
                try await Media.merge(video: tv, audio: ta, to: dest)
                return DownloadItem(video: meta, file: name, audioOnly: false, bytes: fileSize(dest))
            } catch {
                try? fm.removeItem(at: dest)
                if Task.isCancelled { throw CancellationError() }
                // otherwise fall back to the single-file 360p stream
            }
        }

        guard let m = formats.muxed else { throw YTError.noStreams }
        try await fetch(m, to: dest, progress: progress)
        return DownloadItem(video: meta, file: name, audioOnly: false, bytes: fileSize(dest))
    }

    /// Downloads in ~10 MB ranges; googlevideo throttles single large requests.
    private nonisolated static func fetch(_ format: DirectFormat, to dest: URL,
                                          progress: @escaping (Double) -> Void) async throws {
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let handle = try FileHandle(forWritingTo: dest)
        defer { try? handle.close() }
        do {
            try await fetchChunks(format, into: handle, progress: progress)
        } catch {
            // Don't leave half-written files visible in the Files app.
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
    }

    private nonisolated static func fetchChunks(_ format: DirectFormat, into handle: FileHandle,
                                                progress: @escaping (Double) -> Void) async throws {
        let chunk: Int64 = 10_000_000
        var offset: Int64 = 0
        var total = format.size ?? 0
        repeat {
            try Task.checkCancellation()
            var req = URLRequest(url: format.url)
            req.setValue("bytes=\(offset)-\(offset + chunk - 1)", forHTTPHeaderField: "Range")
            req.setValue(YTClient.androidVR.userAgent, forHTTPHeaderField: "User-Agent")
            let (data, resp) = try await URLSession.shared.data(for: req)
            let http = resp as? HTTPURLResponse
            guard let code = http?.statusCode, (200..<300).contains(code) else {
                throw YTError.http(http?.statusCode ?? 0)
            }
            if total == 0, let range = http?.value(forHTTPHeaderField: "Content-Range"),
               let t = range.split(separator: "/").last.flatMap({ Int64($0) }) {
                total = t
            }
            if data.isEmpty { break }
            try handle.write(contentsOf: data)
            offset += Int64(data.count)
            if total > 0 { progress(min(Double(offset) / Double(total), 1)) }
        } while total > 0 && offset < total
    }

    private nonisolated static func fileSize(_ url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
