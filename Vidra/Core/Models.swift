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
        return source == nil || source == .ytMusic ? URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg") : nil
    }

    var shareURL: URL {
        switch source {
        case .soundCloud?: return link ?? URL(string: "https://soundcloud.com")!
        case .spotify?: return link ?? URL(string: "https://open.spotify.com")!
        case .ytMusic?: return URL(string: "https://music.youtube.com/watch?v=\(id)")!
        case nil: return URL(string: "https://youtu.be/\(id)")!
        }
    }
}

/// Id conventions: YouTube/YT Music = raw video id, SoundCloud = "sc:<trackId>", Spotify = "sp:<trackId>".
/// channelId: SoundCloud user = "scu:<userId>", Spotify artist = "spa:<artistId>".
enum MediaSource: String, Codable, Sendable {
    case ytMusic, soundCloud, spotify
}

struct Channel: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var title: String
    var avatar: URL?
    var subscribers: String?
}

struct Page {
    var videos: [Video] = []
    var channels: [Channel] = []
    var continuation: String?
    var title: String?
    var channel: Channel?
}

struct HistoryItem: Identifiable, Codable, Hashable {
    var video: Video
    var date: Date
    var id: String { video.id }
}

struct LocalPlaylist: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var videos: [Video] = []
}

struct Comment: Identifiable {
    let id: String
    let author: String
    let avatar: URL?
    let text: String
    let published: String
    let likes: String
}

struct VideoInfo {
    var description: String
    var viewCount: Int?
    var isLive: Bool
    var storyboard: String?
}

struct DirectFormat {
    let url: URL
    let size: Int64?
    let height: Int?
    let bitrate: Int
    let mime: String
    let isDefaultAudio: Bool
}

struct DirectSet {
    var video: DirectFormat?
    var audio: DirectFormat?
    var muxed: DirectFormat?
}

enum PlaybackSource {
    case hls(URL)
    case composite(video: URL, audio: URL)
    case progressive(URL)
    case file(URL)
}

struct ResolvedVideo {
    var video: Video
    var info: VideoInfo
    var sources: [PlaybackSource]
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
        guard let c = URLComponents(string: s), let host = c.host?.lowercased(), host.contains("youtu") else { return nil }
        let query = c.queryItems ?? []
        let path = c.path.split(separator: "/").map(String.init)
        if host.contains("youtu.be"), let id = path.first { return .video(id) }
        if let v = query.first(where: { $0.name == "v" })?.value { return .video(v) }
        if path.count >= 2, ["shorts", "live", "embed", "v"].contains(path[0]) { return .video(path[1]) }
        if let list = query.first(where: { $0.name == "list" })?.value { return .playlist(list) }
        if path.count >= 2, path[0] == "channel" { return .channel(path[1]) }
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

    private static func bool(_ key: String, _ fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }

    /// 0 = automatic (highest available).
    static var maxHeight: Int { UserDefaults.standard.object(forKey: maxHeightKey) as? Int ?? 1080 }
    static var autoplay: Bool { bool(autoplayKey, true) }
    static var sponsorBlock: Bool { bool(sponsorBlockKey, true) }
    static var autoPiP: Bool { bool(autoPiPKey, true) }
    static var saveHistory: Bool { bool(saveHistoryKey, true) }
    static var hideShorts: Bool { bool(hideShortsKey, true) }
    static var musicAudioOnly: Bool { bool(musicAudioOnlyKey, true) }
    static var defaultRate: Double { UserDefaults.standard.object(forKey: defaultRateKey) as? Double ?? 1 }
}

enum Fmt {
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let t = Int(seconds)
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "1:02:03" -> 3723
    static func seconds(_ text: String?) -> Double? {
        guard let text else { return nil }
        let raw = text.split(separator: ":")
        let parts = raw.compactMap { Double($0) }
        guard (2...3).contains(parts.count), parts.count == raw.count else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    static func count(_ n: Int) -> String { n.formatted(.number.notation(.compactName)) }
    static func rate(_ r: Double) -> String { String(format: "%gx", r) }

    static func ago(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }
}
