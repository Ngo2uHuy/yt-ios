import Foundation

struct Video: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var title: String
    var channelTitle: String
    var channelId: String?
    var duration: String?
    var views: String?
    var published: String?
    /// nil = regular YouTube video.
    var source: MediaSource?
    var artwork: URL?
    var link: URL?

    var thumbnail: URL? {
        if let artwork { return artwork }
        if (source == nil || source == .ytMusic), !id.isEmpty,
           let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
            return URL(string: "https://i.ytimg.com/vi/\(encoded)/hq720.jpg")
                ?? URL(string: "https://i.ytimg.com/vi/\(encoded)/mqdefault.jpg")
        }
        return nil
    }

    var shareURL: URL {
        switch source {
        case .spotify?:
            return link ?? URL(string: "https://open.spotify.com")!
        case .ytMusic?:
            var c = URLComponents(string: "https://music.youtube.com/watch")!
            if !id.isEmpty { c.queryItems = [URLQueryItem(name: "v", value: id)] }
            return c.url ?? URL(string: "https://music.youtube.com")!
        case nil:
            guard !id.isEmpty,
                  let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let url = URL(string: "https://youtu.be/\(encoded)") else {
                return URL(string: "https://www.youtube.com")!
            }
            return url
        }
    }
}

/// Id conventions: YouTube/YT Music = raw video id, Spotify = "sp:<trackId>".
/// channelId: Spotify artist = "spa:<artistId>".
enum MediaSource: String, Codable, Sendable {
    case ytMusic, spotify
}

struct Channel: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var title: String
    var avatar: URL?
    var subscribers: String?
}

struct ChannelPlaylist: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var title: String
    var thumbnail: URL?
    var videoCount: String?
}

struct Page: Sendable {
    var videos: [Video] = []
    var channels: [Channel] = []
    var playlists: [ChannelPlaylist] = []
    var continuation: String?
    var title: String?
    var channel: Channel?
}

struct HistoryItem: Identifiable, Codable, Hashable, Sendable {
    var video: Video
    var date: Date
    var id: String { video.id }
}

struct LocalPlaylist: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var videos: [Video] = []
}

struct Comment: Identifiable, Sendable {
    let id: String
    let author: String
    let avatar: URL?
    let text: String
    let published: String
    let likes: String
    var isChannelOwner: Bool = false
    var isHeartedByCreator: Bool = false
    var isPinned: Bool = false
    var replyCount: Int = 0
    var repliesToken: String? = nil
    var replies: [Comment] = []

    init(
        id: String,
        author: String,
        avatar: URL?,
        text: String,
        published: String,
        likes: String,
        isChannelOwner: Bool = false,
        isHeartedByCreator: Bool = false,
        isPinned: Bool = false,
        replyCount: Int = 0,
        repliesToken: String? = nil,
        replies: [Comment] = []
    ) {
        self.id = id
        self.author = author
        self.avatar = avatar
        self.text = text
        self.published = published
        self.likes = likes
        self.isChannelOwner = isChannelOwner
        self.isHeartedByCreator = isHeartedByCreator
        self.isPinned = isPinned
        self.replyCount = replyCount
        self.repliesToken = repliesToken
        self.replies = replies
    }
}

struct CaptionTrack: Identifiable, Codable, Hashable, Sendable {
    var id: String { languageCode + (name.isEmpty ? "" : " - " + name) }
    var name: String
    var languageCode: String
    var url: URL
}

struct CaptionCue: Identifiable, Hashable, Sendable {
    var id: String { "\(start)_\(end)_\(text)" }
    let start: Double
    let end: Double
    let text: String
}

struct VideoInfo: Sendable {
    var description: String
    var viewCount: Int?
    var isLive: Bool
    var storyboard: String?
    var captions: [CaptionTrack] = []
}

struct DirectFormat: Sendable {
    let url: URL
    let size: Int64?
    let width: Int?
    let height: Int?
    let fps: Int?
    let bitrate: Int
    let mime: String
    let isDefaultAudio: Bool
    let initRange: (start: Int, end: Int)?
    let indexRange: (start: Int, end: Int)?
    let itag: Int?
    let approxDurationMs: Double?
    let expiresAt: Date?
    let client: YTClient?
    let isDrc: Bool

    var effectiveUserAgent: String {
        client?.userAgent ?? YTClient.ios.userAgent
    }

    var shortEdge: Int {
        if let w = width, let h = height, w > 0, h > 0 { return min(w, h) }
        return height ?? 0
    }

    var cacheIdentifier: String {
        var h: UInt64 = 14695981039346656037
        for b in url.absoluteString.utf8 {
            h ^= UInt64(b)
            h &*= 1099511628211
        }
        return "\(itag.map(String.init) ?? "x")_\(client?.name ?? "x")_\(width ?? 0)x\(height ?? 0)_\(fps ?? 0)_\(h)"
    }

    init(
        url: URL,
        size: Int64?,
        width: Int? = nil,
        height: Int?,
        fps: Int? = nil,
        bitrate: Int,
        mime: String,
        isDefaultAudio: Bool,
        initRange: (start: Int, end: Int)? = nil,
        indexRange: (start: Int, end: Int)? = nil,
        itag: Int? = nil,
        approxDurationMs: Double? = nil,
        expiresAt: Date? = nil,
        client: YTClient? = nil,
        isDrc: Bool = false
    ) {
        self.url = url
        self.size = size
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrate = bitrate
        self.mime = mime
        self.isDefaultAudio = isDefaultAudio
        self.initRange = initRange
        self.indexRange = indexRange
        self.itag = itag
        self.approxDurationMs = approxDurationMs
        self.expiresAt = expiresAt
        self.client = client
        self.isDrc = isDrc
    }
}

struct DirectSet: Sendable {
    var video: DirectFormat?
    var audio: DirectFormat?
    var muxed: DirectFormat?
    var videoVariants: [DirectFormat] = []

    init(
        video: DirectFormat? = nil,
        audio: DirectFormat? = nil,
        muxed: DirectFormat? = nil,
        videoVariants: [DirectFormat] = []
    ) {
        self.video = video
        self.audio = audio
        self.muxed = muxed
        self.videoVariants = videoVariants
    }
}

enum PlaybackSource: Sendable {
    case hls(URL, userAgent: String? = nil)
    case composite(video: URL, audio: URL, videoUserAgent: String? = nil, audioUserAgent: String? = nil)
    case progressive(URL, userAgent: String? = nil)
    case file(URL)
}

struct ResolvedVideo: Sendable {
    var video: Video
    var info: VideoInfo
    var sources: [PlaybackSource]
    var expiresAt: Date? = nil
}

struct FeedEntry: Sendable {
    let video: Video
    let date: Date
    let isShort: Bool
}

enum YTError: LocalizedError {
    case http(Int)
    case unplayable(String)
    case noStreams

    var errorDescription: String? {
        switch self {
        case .http(let code): return "Lỗi máy chủ (HTTP \(code))"
        case .unplayable(let reason): return reason
        case .noStreams: return "Không tìm thấy luồng phát phù hợp"
        }
    }
}

enum YTLink {
    case video(String), playlist(String), channel(String)

    static func parse(_ text: String) -> YTLink? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let c = URLComponents(string: s), let host = c.host?.lowercased() else { return nil }
        let isYT = host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com")
            || host == "youtube-nocookie.com" || host.hasSuffix(".youtube-nocookie.com")
        guard isYT else { return nil }
        let query = c.queryItems ?? []
        let path = c.path.split(separator: "/").map(String.init)
        if host == "youtu.be", let id = path.first, !id.isEmpty { return .video(id) }
        if let v = query.first(where: { $0.name == "v" })?.value, !v.isEmpty { return .video(v) }
        if path.count >= 2, ["shorts", "live", "embed", "v"].contains(path[0]), !path[1].isEmpty {
            return .video(path[1])
        }
        if let list = query.first(where: { $0.name == "list" })?.value, !list.isEmpty { return .playlist(list) }
        if path.count >= 2, path[0] == "channel", !path[1].isEmpty { return .channel(path[1]) }
        return nil
    }
}

enum Pref {
    static let maxHeightKey = "maxHeight"
    static let autoplayKey = "autoplay"
    static let sponsorBlockKey = "sponsorBlock"
    static let autoPiPKey = "autoPiP"
    static let defaultRateKey = "defaultRate"
    static let audioOnlyKey = "audioOnly"
    static let saveHistoryKey = "saveHistory"
    static let hideShortsKey = "hideShorts"
    static let musicAudioOnlyKey = "musicAudioOnly"
    static let endlessRadioKey = "endlessRadio"

    private static func bool(_ key: String, _ fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }

    /// 0 = automatic (highest available). Defaults to 1080p H.264 for universal hardware compatibility.
    static var maxHeight: Int {
        UserDefaults.standard.object(forKey: maxHeightKey) as? Int ?? 1080
    }
    static var autoplay: Bool { bool(autoplayKey, true) }
    static var endlessRadio: Bool { bool(endlessRadioKey, true) }
    static var sponsorBlock: Bool { bool(sponsorBlockKey, true) }
    static var autoPiP: Bool { bool(autoPiPKey, true) }
    static var saveHistory: Bool { bool(saveHistoryKey, true) }
    static var hideShorts: Bool { bool(hideShortsKey, true) }
    static var musicAudioOnly: Bool { bool(musicAudioOnlyKey, true) }
    static var defaultRate: Double {
        let r = UserDefaults.standard.object(forKey: defaultRateKey) as? Double ?? 1
        return r.isFinite && r > 0 ? r : 1
    }
}

enum Fmt {
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()
    private static let relativeLock = NSLock()

    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max / 2) else { return "0:00" }
        let t = Int(seconds)
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "1:02:03" -> 3723
    static func seconds(_ text: String?) -> Double? {
        guard let text else { return nil }
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        let parts = raw.compactMap { Double($0) }.filter { $0.isFinite && $0 >= 0 }
        guard (2...3).contains(parts.count), parts.count == raw.count else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    static func count(_ n: Int) -> String { n.formatted(.number.notation(.compactName)) }
    static func rate(_ r: Double) -> String { String(format: "%gx", r) }

    static func ago(_ date: Date) -> String {
        relativeLock.lock()
        defer { relativeLock.unlock() }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}
