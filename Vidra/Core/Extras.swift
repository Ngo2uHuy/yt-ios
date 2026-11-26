import AVFoundation
import Foundation

struct Votes: Decodable, Sendable {
    let likes: Int
    let dislikes: Int
    let rating: Double?
    let viewCount: Int?
}

struct SponsorSegment: Decodable, Sendable {
    let segment: [Double]
    let category: String
    let actionType: String?
    let UUID: String?

    var start: Double { segment.count >= 2 ? segment[0] : 0 }
    var end: Double { segment.count >= 2 ? segment[1] : 0 }
    var isValid: Bool { segment.count >= 2 && start.isFinite && end.isFinite && end > start }

    var label: String {
        switch category {
        case "sponsor": return "Đoạn tài trợ"
        case "selfpromo": return "Tự quảng cáo"
        case "interaction": return "Kêu gọi tương tác"
        case "intro": return "Đoạn mở đầu (Intro)"
        case "outro": return "Đoạn kết thúc (Outro)"
        case "preview": return "Xem trước / Recap"
        case "music_offtopic": return "Đoạn ngoài âm nhạc"
        case "filler": return "Đoạn thừa"
        default: return "Phân đoạn quảng cáo"
        }
    }
}

enum Extras {
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 12
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    private static let votesCache: NSCache<NSString, CacheEntry<Votes>> = {
        let c = NSCache<NSString, CacheEntry<Votes>>()
        c.countLimit = 200
        return c
    }()

    private static let segmentsCache: NSCache<NSString, CacheEntry<[SponsorSegment]>> = {
        let c = NSCache<NSString, CacheEntry<[SponsorSegment]>>()
        c.countLimit = 200
        return c
    }()

    private final class CacheEntry<T>: @unchecked Sendable {
        let value: T
        let timestamp = Date()
        init(_ value: T) { self.value = value }
    }

    /// Return YouTube Dislike community API with memory caching.
    static func votes(_ id: String) async -> Votes? {
        if let cached = votesCache.object(forKey: id as NSString),
           Date().timeIntervalSince(cached.timestamp) < 300 {
            return cached.value
        }
        var c = URLComponents(string: "https://returnyoutubedislikeapi.com/votes")!
        c.queryItems = [URLQueryItem(name: "videoId", value: id)]
        guard let url = c.url,
              let (data, resp) = try? await session.data(from: url),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let votes = try? JSONDecoder().decode(Votes.self, from: data) else { return nil }
        votesCache.setObject(CacheEntry(votes), forKey: id as NSString)
        return votes
    }

    /// SponsorBlock API to skip sponsors, self-promo, intros, outros, and fillers.
    /// Transient server/rate-limit errors are not negatively cached.
    static func segments(_ id: String) async -> [SponsorSegment] {
        if let cached = segmentsCache.object(forKey: id as NSString),
           Date().timeIntervalSince(cached.timestamp) < 600 {
            return cached.value
        }
        var c = URLComponents(string: "https://sponsor.ajay.app/api/skipSegments")!
        c.queryItems = [
            .init(name: "videoID", value: id),
            .init(name: "categories", value: #"["sponsor","selfpromo","interaction","intro","outro","preview","music_offtopic","filler"]"#),
            .init(name: "actionTypes", value: #"["skip","mute"]"#),
        ]
        guard let url = c.url, let (data, resp) = try? await session.data(from: url),
              let http = resp as? HTTPURLResponse else { return [] }
        if http.statusCode == 404 {
            segmentsCache.setObject(CacheEntry([]), forKey: id as NSString)
            return []
        }
        guard (200..<300).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode([SponsorSegment].self, from: data) else {
            return []
        }
        let segs = decoded.filter(\.isValid)
        segmentsCache.setObject(CacheEntry(segs), forKey: id as NSString)
        return segs
    }

    /// Per-channel RSS is cheap and needs no login, unlike the real subscription feed.
    static func channelFeed(_ id: String) async -> [FeedEntry] {
        var c = URLComponents(string: "https://www.youtube.com/feeds/videos.xml")!
        c.queryItems = [URLQueryItem(name: "channel_id", value: id)]
        guard let url = c.url,
              let (data, resp) = try? await session.data(from: url),
              let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return [] }
        return RSSParser.parse(data)
    }

    static func subscriptionFeed(_ channels: [Channel]) async -> [Video] {
        let hideShorts = Pref.hideShorts
        let entries = await withTaskGroup(of: [FeedEntry].self) { group -> [FeedEntry] in
            var pending = channels.makeIterator()
            for _ in 0..<8 {
                guard !Task.isCancelled, let c = pending.next() else { break }
                group.addTask { await channelFeed(c.id) }
            }
            var all: [FeedEntry] = []
            for await batch in group {
                all += batch
                if !Task.isCancelled, let c = pending.next() {
                    group.addTask { await channelFeed(c.id) }
                }
            }
            return all
        }
        var seen = Set<String>()
        var out: [Video] = []
        for entry in entries.filter({ !(hideShorts && $0.isShort) }).sorted(by: { $0.date > $1.date }) {
            if seen.insert(entry.video.id).inserted {
                out.append(entry.video)
                if out.count >= 300 { break }
            }
        }
        return out
    }
}

final class RSSParser: NSObject, XMLParserDelegate {
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let isoFractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoLock = NSLock()

    private var entries: [FeedEntry] = []
    private var fields: [String: String] = [:]
    private var buffer = ""
    private var inEntry = false

    static func parse(_ data: Data) -> [FeedEntry] {
        let delegate = RSSParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.entries
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        buffer = ""
        if elementName == "entry" {
            inEntry = true
            fields = [:]
        } else if inEntry, elementName == "media:statistics" {
            fields["views"] = attributeDict["views"]
        } else if inEntry, elementName == "link", let href = attributeDict["href"] {
            let rel = attributeDict["rel"]
            if rel == "alternate" || fields["link"] == nil {
                fields["link"] = href
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard inEntry else { return }
        switch elementName {
        case "yt:videoId", "yt:channelId", "title", "published", "name":
            if fields[elementName] == nil {
                fields[elementName] = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        case "entry":
            inEntry = false
            if let e = makeEntry() { entries.append(e) }
        default:
            break
        }
    }

    private func makeEntry() -> FeedEntry? {
        guard let id = fields["yt:videoId"], let title = fields["title"] else { return nil }
        let date: Date = {
            guard let p = fields["published"] else { return .distantPast }
            Self.isoLock.lock()
            defer { Self.isoLock.unlock() }
            return Self.isoFormatter.date(from: p)
                ?? Self.isoFractionalFormatter.date(from: p)
                ?? .distantPast
        }()
        let views = fields["views"].flatMap { Int($0) }
        let video = Video(
            id: id,
            title: title,
            channelTitle: fields["name"] ?? "",
            channelId: fields["yt:channelId"],
            views: views.map { "\(Fmt.count($0)) lượt xem" },
            published: date == .distantPast ? nil : Fmt.ago(date)
        )
        return FeedEntry(video: video, date: date, isShort: fields["link"]?.contains("/shorts/") ?? false)
    }
}

enum Media {
    static func asset(_ url: URL, userAgent: String? = nil) -> AVURLAsset {
        if url.isFileURL {
            return AVURLAsset(url: url)
        }
        if let ua = userAgent, !ua.isEmpty {
            return AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": ua]])
        }
        if url.host?.contains("googlevideo") == true {
            return AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": YTClient.ios.userAgent]])
        }
        return AVURLAsset(url: url)
    }

    /// Joins separate video-only and audio-only streams into one composition.
    static func composition(video: AVURLAsset, audio: AVURLAsset) async throws -> AVMutableComposition {
        try Task.checkCancellation()
        guard let vt = try await video.loadTracks(withMediaType: .video).first,
              let at = try await audio.loadTracks(withMediaType: .audio).first else { throw YTError.noStreams }
        let vd = try await video.load(.duration)
        let ad = try await audio.load(.duration)
        guard vd.isNumeric, ad.isNumeric, vd.seconds > 0, ad.seconds > 0 else {
            throw YTError.noStreams
        }
        let range = CMTimeRange(start: .zero, duration: CMTimeMinimum(vd, ad))

        let comp = AVMutableComposition()
        guard let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw YTError.noStreams
        }
        try cv.insertTimeRange(range, of: vt, at: .zero)
        cv.preferredTransform = try await vt.load(.preferredTransform)
        try ca.insertTimeRange(range, of: at, at: .zero)
        return comp
    }

    static func merge(video: URL, audio: URL, to output: URL) async throws {
        try Task.checkCancellation()
        try? FileManager.default.removeItem(at: output)
        let comp = try await composition(video: AVURLAsset(url: video), audio: AVURLAsset(url: audio))
        let primaryPreset = AVAssetExportPresetPassthrough
        let fallbackPreset = AVAssetExportPresetHighestQuality
        let session = AVAssetExportSession(asset: comp, presetName: primaryPreset)
            ?? AVAssetExportSession(asset: comp, presetName: fallbackPreset)
        guard let session else { throw YTError.noStreams }
        session.outputURL = output
        session.outputFileType = .mp4

        await withTaskCancellationHandler {
            await session.export()
        } onCancel: {
            session.cancelExport()
        }
        try Task.checkCancellation()

        if session.status != .completed {
            if session.presetName == primaryPreset,
               let retry = AVAssetExportSession(asset: comp, presetName: fallbackPreset) {
                try? FileManager.default.removeItem(at: output)
                retry.outputURL = output
                retry.outputFileType = .mp4
                await withTaskCancellationHandler {
                    await retry.export()
                } onCancel: {
                    retry.cancelExport()
                }
                try Task.checkCancellation()
                if retry.status == .completed { return }
                throw retry.error ?? session.error ?? YTError.noStreams
            }
            throw session.error ?? YTError.noStreams
        }
    }

    /// Remuxes DASH fragmented MP4 audio into a seekable M4A container for reliable offline seeking.
    static func remuxAudioToM4A(source: URL, to output: URL) async throws {
        try Task.checkCancellation()
        try? FileManager.default.removeItem(at: output)
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw YTError.noStreams
        }
        let duration = try await asset.load(.duration)
        guard duration.isNumeric, duration.seconds > 0 else {
            throw YTError.noStreams
        }
        let comp = AVMutableComposition()
        guard let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw YTError.noStreams
        }
        try ca.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)

        let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough)
            ?? AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetAppleM4A)
        guard let session else { throw YTError.noStreams }
        session.outputURL = output
        session.outputFileType = .m4a
        await withTaskCancellationHandler {
            await session.export()
        } onCancel: {
            session.cancelExport()
        }
        try Task.checkCancellation()
        if session.status != .completed {
            throw session.error ?? YTError.noStreams
        }
    }
}
