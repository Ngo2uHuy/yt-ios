import AVFoundation
import Foundation

struct Votes: Decodable {
    let likes: Int
    let dislikes: Int
}

struct SponsorSegment: Decodable {
    let segment: [Double]
    let category: String

    var start: Double { segment.first ?? 0 }
    var end: Double { segment.last ?? 0 }

    var label: String {
        switch category {
        case "sponsor": return "Tài trợ"
        case "selfpromo": return "Tự quảng bá"
        case "interaction": return "Kêu gọi đăng ký"
        case "music_offtopic": return "Đoạn không phải nhạc"
        default: return category
        }
    }
}

enum Extras {
    /// Return YouTube Dislike community API.
    static func votes(_ id: String) async -> Votes? {
        guard let url = URL(string: "https://returnyoutubedislikeapi.com/votes?videoId=\(id)"),
              let res = try? await URLSession.shared.data(from: url) else { return nil }
        return try? JSONDecoder().decode(Votes.self, from: res.0)
    }

    static func segments(_ id: String) async -> [SponsorSegment] {
        var c = URLComponents(string: "https://sponsor.ajay.app/api/skipSegments")!
        c.queryItems = [
            .init(name: "videoID", value: id),
            .init(name: "categories", value: #"["sponsor","selfpromo","interaction","music_offtopic"]"#),
        ]
        guard let url = c.url, let res = try? await URLSession.shared.data(from: url) else { return [] }
        return (try? JSONDecoder().decode([SponsorSegment].self, from: res.0)) ?? []
    }

    /// Per-channel RSS is cheap and needs no login, unlike the real subscription feed.
    static func channelFeed(_ id: String) async -> [FeedEntry] {
        guard let url = URL(string: "https://www.youtube.com/feeds/videos.xml?channel_id=\(id)"),
              let res = try? await URLSession.shared.data(from: url) else { return [] }
        return RSSParser.parse(res.0)
    }

    static func subscriptionFeed(_ channels: [Channel]) async -> [Video] {
        let hideShorts = Pref.hideShorts
        let entries = await withTaskGroup(of: [FeedEntry].self) { group -> [FeedEntry] in
            var pending = channels.makeIterator()
            for _ in 0..<8 {
                if let c = pending.next() { group.addTask { await channelFeed(c.id) } }
            }
            var all: [FeedEntry] = []
            for await batch in group {
                all += batch
                if let c = pending.next() { group.addTask { await channelFeed(c.id) } }
            }
            return all
        }
        return entries
            .filter { !(hideShorts && $0.isShort) }
            .sorted { $0.date > $1.date }
            .prefix(300)
            .map(\.video)
    }
}

final class RSSParser: NSObject, XMLParserDelegate {
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
            fields["link"] = href
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
        let date = fields["published"].flatMap { ISO8601DateFormatter().date(from: $0) } ?? .distantPast
        let views = fields["views"].flatMap { Int($0) }
        let video = Video(
            id: id,
            title: title,
            channelTitle: fields["name"] ?? "",
            channelId: fields["yt:channelId"],
            views: views.map { "\(Fmt.count($0)) lượt xem" },
            published: Fmt.ago(date)
        )
        return FeedEntry(video: video, date: date, isShort: fields["link"]?.contains("/shorts/") ?? false)
    }
}

enum Media {
    static func asset(_ url: URL) -> AVURLAsset {
        guard url.host?.contains("googlevideo") == true else { return AVURLAsset(url: url) }
        // Stream URLs are bound to the client that requested them.
        return AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": YTClient.androidVR.userAgent]])
    }

    /// Joins separate video-only and audio-only streams (how YouTube serves >360p) into one item.
    static func composition(video: AVURLAsset, audio: AVURLAsset) async throws -> AVMutableComposition {
        guard let vt = try await video.loadTracks(withMediaType: .video).first,
              let at = try await audio.loadTracks(withMediaType: .audio).first else { throw YTError.noStreams }
        let vd = try await video.load(.duration)
        let ad = try await audio.load(.duration)
        let range = CMTimeRange(start: .zero, duration: CMTimeMinimum(vd, ad))

        let comp = AVMutableComposition()
        let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        try cv?.insertTimeRange(range, of: vt, at: .zero)
        cv?.preferredTransform = try await vt.load(.preferredTransform)
        let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        try ca?.insertTimeRange(range, of: at, at: .zero)
        return comp
    }

    static func merge(video: URL, audio: URL, to output: URL) async throws {
        let comp = try await composition(video: AVURLAsset(url: video), audio: AVURLAsset(url: audio))
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else {
            throw YTError.noStreams
        }
        export.outputURL = output
        export.outputFileType = .mp4
        await export.export()
        if export.status != .completed { throw export.error ?? YTError.noStreams }
    }
}
