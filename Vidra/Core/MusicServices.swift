import Foundation

// MARK: - SoundCloud

struct TimedComment: Identifiable, Sendable {
    let id: Int
    let body: String
    let author: String
    let avatar: URL?
    let seconds: Double
}

struct SCPlaylistInfo: Identifiable, Hashable, Sendable {
    let id: Int
    let title: String
    let artwork: URL?
    let owner: String
    let trackCount: Int
}

struct SCList: Sendable {
    var tracks: [Video] = []
    var playlists: [SCPlaylistInfo] = []
    var next: String?
}

struct SCUser: Sendable {
    let id: String
    let name: String
    let avatar: URL?
    let followers: Int
    let trackCount: Int
    let bio: String
    let banner: URL?
}

struct SCPlaylist: Sendable {
    let id: Int
    let title: String
    let artwork: URL?
    let owner: String
    let tracks: [Video]
}

/// Uses SoundCloud's public web API with the client_id their own website ships.
actor SoundCloud {
    static let shared = SoundCloud()

    private static let clientIdKey = "scClientId"
    private let api = "https://api-v2.soundcloud.com"
    private var clientId = UserDefaults.standard.string(forKey: SoundCloud.clientIdKey)

    func search(_ query: String, next: String?) async throws -> Page {
        let j: J
        if let next {
            j = try await get(next)
        } else {
            j = try await get("/search/tracks", query: [.init(name: "q", value: query), .init(name: "limit", value: "30")])
        }
        return Page(videos: j["collection"].array.compactMap(Self.track), continuation: j["next_href"].string)
    }

    func related(_ id: String) async -> [Video] {
        guard let num = Self.number(id),
              let j = try? await get("/tracks/\(num)/related", query: [.init(name: "limit", value: "30")]) else { return [] }
        return j["collection"].array.compactMap(Self.track)
    }

    func resolveLink(_ url: String) async throws -> Video? {
        Self.track(try await get("/resolve", query: [.init(name: "url", value: url)]))
    }

    func resolve(_ id: String) async throws -> ResolvedVideo {
        guard let num = Self.number(id) else { throw YTError.noStreams }
        let t = try await get("/tracks/\(num)")
        guard let video = Self.track(t) else { throw YTError.noStreams }
        let auth = t["track_authorization"].string.map { [URLQueryItem(name: "track_authorization", value: $0)] } ?? []

        // Encrypted HLS variants are DRM-protected; only the plain ones are used.
        let plain = t["media"]["transcodings"].array.filter {
            let proto = $0["format"]["protocol"].string ?? ""
            return proto == "progressive" || proto == "hls"
        }
        let ordered = plain.filter { $0["format"]["protocol"].string == "progressive" }
            + plain.filter { $0["format"]["protocol"].string == "hls" }

        var sources: [PlaybackSource] = []
        for tr in ordered {
            guard let u = tr["url"].string,
                  let s = try? await get(u, query: auth),
                  let final = s["url"].string.flatMap({ URL(string: $0) }) else { continue }
            sources.append(tr["format"]["protocol"].string == "hls" ? .hls(final) : .progressive(final))
            if sources.count >= 2 { break }
        }
        guard !sources.isEmpty else { throw YTError.unplayable("Bài này không phát được (có thể cần SoundCloud Go+)") }
        let info = VideoInfo(description: t["description"].string ?? "", viewCount: t["playback_count"].int, isLive: false)
        return ResolvedVideo(video: video, info: info, sources: sources)
    }

    // MARK: Social, profiles & playlists

    private var waveCache: [String: [Float]] = [:]

    func timedComments(_ trackId: String) async -> [TimedComment] {
        guard let num = Self.number(trackId),
              let j = try? await get("/tracks/\(num)/comments", query: [
                  .init(name: "threaded", value: "0"), .init(name: "limit", value: "200"),
                  .init(name: "filter_replies", value: "1")]) else { return [] }
        var out: [TimedComment] = []
        for c in j["collection"].array {
            guard let id = c["id"].int, let ms = c["timestamp"].int, let body = c["body"].string, !body.isEmpty else { continue }
            out.append(TimedComment(id: id, body: body, author: c["user"]["username"].string ?? "",
                                    avatar: c["user"]["avatar_url"].string.flatMap { URL(string: $0) },
                                    seconds: Double(ms) / 1000))
        }
        return out.sorted { $0.seconds < $1.seconds }
    }

    func waveform(_ trackId: String) async -> [Float] {
        if let cached = waveCache[trackId] { return cached }
        guard let num = Self.number(trackId),
              let t = try? await get("/tracks/\(num)"),
              let png = t["waveform_url"].string,
              let url = URL(string: png.replacingOccurrences(of: ".png", with: ".json")),
              let res = try? await URLSession.shared.data(from: url) else { return [] }
        let samples = J(data: res.0)["samples"].array.compactMap { $0.int }
        guard let peak = samples.max(), peak > 0 else { return [] }
        let bars = 120
        var out: [Float] = []
        if samples.count <= bars {
            out = samples.map { Float($0) / Float(peak) }
        } else {
            for i in 0..<bars {
                let lo = i * samples.count / bars
                let hi = max(lo + 1, (i + 1) * samples.count / bars)
                let m = samples[lo..<hi].max() ?? 0
                out.append(Float(m) / Float(peak))
            }
        }
        waveCache[trackId] = out
        return out
    }

    func searchUsers(_ q: String, next: String?) async throws -> Page {
        let j = try await collection("/search/users", q: q, next: next)
        return Page(channels: j["collection"].array.compactMap(Self.userChannel), continuation: j["next_href"].string)
    }

    func searchPlaylists(_ q: String, next: String?) async throws -> SCList {
        let j = try await collection("/search/playlists_without_albums", q: q, next: next)
        return SCList(playlists: j["collection"].array.compactMap(Self.playlistInfo), next: j["next_href"].string)
    }

    func user(_ id: String) async throws -> SCUser {
        guard let num = Self.userNumber(id) else { throw YTError.noStreams }
        let u = try await get("/users/\(num)")
        let banner = u["visuals"]["visuals"][0]["visual_url"].string
        return SCUser(
            id: id,
            name: u["username"].string ?? "",
            avatar: Self.bigArt(u["avatar_url"].string),
            followers: u["followers_count"].int ?? 0,
            trackCount: u["track_count"].int ?? 0,
            bio: u["description"].string ?? "",
            banner: banner.flatMap { URL(string: $0) }
        )
    }

    func userTracks(_ id: String, next: String?) async throws -> SCList {
        let j = try await userCollection(id, "tracks", next)
        return SCList(tracks: j["collection"].array.compactMap(Self.track), next: j["next_href"].string)
    }

    func userPlaylists(_ id: String, next: String?) async throws -> SCList {
        let j = try await userCollection(id, "playlists", next)
        return SCList(playlists: j["collection"].array.compactMap(Self.playlistInfo), next: j["next_href"].string)
    }

    func userLikes(_ id: String, next: String?) async throws -> SCList {
        let j = try await userCollection(id, "likes", next)
        var list = SCList(next: j["next_href"].string)
        for item in j["collection"].array {
            if let v = Self.track(item["track"]) { list.tracks.append(v) }
            else if let p = Self.playlistInfo(item["playlist"]) { list.playlists.append(p) }
        }
        return list
    }

    func playlist(_ id: Int) async throws -> SCPlaylist {
        let p = try await get("/playlists/\(id)")
        var ordered: [Int] = []
        var known: [Int: Video] = [:]
        for t in p["tracks"].array {
            guard let tid = t["id"].int else { continue }
            ordered.append(tid)
            if t["title"].string != nil, let v = Self.track(t) { known[tid] = v }
        }
        let missing = ordered.filter { known[$0] == nil }
        var start = 0
        while start < missing.count {
            let chunk = missing[start..<min(start + 50, missing.count)]
            start += 50
            let ids = chunk.map(String.init).joined(separator: ",")
            guard let r = try? await get("/tracks", query: [.init(name: "ids", value: ids)]) else { continue }
            for t in r.array {
                if let tid = t["id"].int, let v = Self.track(t) { known[tid] = v }
            }
        }
        let tracks = ordered.compactMap { known[$0] }
        let art = Self.bigArt(p["artwork_url"].string) ?? tracks.first?.artwork
        return SCPlaylist(id: id, title: p["title"].string ?? "", artwork: art,
                          owner: p["user"]["username"].string ?? "", tracks: tracks)
    }

    private func collection(_ path: String, q: String, next: String?) async throws -> J {
        if let next { return try await get(next) }
        return try await get(path, query: [.init(name: "q", value: q), .init(name: "limit", value: "30")])
    }

    private func userCollection(_ id: String, _ kind: String, _ next: String?) async throws -> J {
        if let next { return try await get(next) }
        guard let num = Self.userNumber(id) else { throw YTError.noStreams }
        return try await get("/users/\(num)/\(kind)", query: [.init(name: "limit", value: "30")])
    }

    // MARK: Transport

    private func get(_ path: String, query: [URLQueryItem] = [], retried: Bool = false) async throws -> J {
        let id = try await ensureClientId(refresh: retried)
        var c = URLComponents(string: path.hasPrefix("http") ? path : api + path)!
        c.queryItems = (c.queryItems ?? []).filter { $0.name != "client_id" } + query + [.init(name: "client_id", value: id)]
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        let (data, resp) = try await URLSession.shared.data(from: c.url!)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if (code == 401 || code == 403) && !retried {
            return try await get(path, query: query, retried: true)
        }
        guard (200..<300).contains(code) else { throw YTError.http(code) }
        return J(data: data)
    }

    /// The client_id rotates; it is scraped from soundcloud.com's JS bundles and cached.
    private func ensureClientId(refresh: Bool) async throws -> String {
        if !refresh, let clientId { return clientId }
        let (html, _) = try await URLSession.shared.data(from: URL(string: "https://soundcloud.com")!)
        let scripts = Self.matches(#"<script crossorigin src="(https://a-v2\.sndcdn\.com/assets/[^"]+\.js)""#,
                                   in: String(decoding: html, as: UTF8.self))
        for src in scripts.reversed() {
            guard let url = URL(string: src), let res = try? await URLSession.shared.data(from: url) else { continue }
            let js = String(decoding: res.0, as: UTF8.self)
            if let id = Self.matches(#"client_id(?:\s*:\s*"|=)([a-zA-Z0-9]{32})"#, in: js).first {
                clientId = id
                UserDefaults.standard.set(id, forKey: Self.clientIdKey)
                return id
            }
        }
        throw YTError.unplayable("Không kết nối được SoundCloud")
    }

    // MARK: Parsing

    private static func number(_ id: String) -> Int? {
        id.hasPrefix("sc:") ? Int(id.dropFirst(3)) : nil
    }

    private static func userNumber(_ id: String) -> Int? {
        id.hasPrefix("scu:") ? Int(id.dropFirst(4)) : nil
    }

    private static func bigArt(_ s: String?) -> URL? {
        s.flatMap { URL(string: $0.replacingOccurrences(of: "-large.", with: "-t500x500.")) }
    }

    static func userChannel(_ u: J) -> Channel? {
        guard let id = u["id"].int else { return nil }
        return Channel(id: "scu:\(id)", title: u["username"].string ?? "", avatar: bigArt(u["avatar_url"].string),
                       subscribers: "\(Fmt.count(u["followers_count"].int ?? 0)) người theo dõi")
    }

    static func playlistInfo(_ p: J) -> SCPlaylistInfo? {
        guard let id = p["id"].int else { return nil }
        let art = bigArt(p["artwork_url"].string) ?? bigArt(p["tracks"][0]["artwork_url"].string)
        return SCPlaylistInfo(id: id, title: p["title"].string ?? "", artwork: art,
                              owner: p["user"]["username"].string ?? "", trackCount: p["track_count"].int ?? 0)
    }

    static func track(_ t: J) -> Video? {
        guard let id = t["id"].int, (t["kind"].string ?? "track") == "track",
              t["policy"].string != "BLOCK" else { return nil }
        let art = (t["artwork_url"].string ?? t["user"]["avatar_url"].string)?
            .replacingOccurrences(of: "-large.", with: "-t500x500.")
        let ms = t["duration"].int ?? t["full_duration"].int
        return Video(
            id: "sc:\(id)",
            title: t["title"].string ?? "",
            channelTitle: t["user"]["username"].string ?? "",
            channelId: t["user"]["id"].int.map { "scu:\($0)" },
            duration: ms.map { Fmt.time(Double($0) / 1000) },
            views: t["playback_count"].int.map { "\(Fmt.count($0)) lượt nghe" },
            published: t["policy"].string == "SNIP" ? "Chỉ nghe thử 30s (Go+)" : nil,
            source: .soundCloud,
            artwork: art.flatMap { URL(string: $0) },
            link: t["permalink_url"].string.flatMap { URL(string: $0) }
        )
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}

// MARK: - Cross-service matching

/// Maps a track from another catalog (Spotify) to a playable YouTube Music id; cached across launches.
actor TrackMatcher {
    static let shared = TrackMatcher()
    private static let key = "trackMatches"
    private var cache = UserDefaults.standard.dictionary(forKey: TrackMatcher.key) as? [String: String] ?? [:]

    func youTubeId(for v: Video) async throws -> String {
        if let id = cache[v.id] { return id }
        let artist = v.channelTitle.components(separatedBy: ",").first ?? v.channelTitle
        let results = try await InnerTube.shared.musicSearch("\(v.title) \(artist)", continuation: nil).videos.prefix(5)
        guard let first = results.first else {
            throw YTError.unplayable("Không tìm thấy bài này trên YouTube Music")
        }
        // Same song often has several uploads; the closest duration is usually the original.
        var best = first
        if let target = Fmt.seconds(v.duration) {
            best = results.min { abs((Fmt.seconds($0.duration) ?? 1e9) - target) < abs((Fmt.seconds($1.duration) ?? 1e9) - target) } ?? first
        }
        if cache.count > 5000 { cache.removeAll() }
        cache[v.id] = best.id
        UserDefaults.standard.set(cache, forKey: Self.key)
        return best.id
    }
}

// MARK: - Spotify

/// Spotify audio is DRM-protected, so only the track list is read (from the public embed page)
/// and each song is matched to YouTube Music for playback.
enum Spotify {
    struct Track: Sendable {
        let title: String
        let artist: String
        var label: String { artist.isEmpty ? title : "\(title) – \(artist)" }
    }

    static func parseLink(_ text: String) -> (kind: String, id: String)? {
        guard let c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.host?.contains("spotify.com") == true else { return nil }
        let path = c.path.split(separator: "/").map(String.init).filter { !$0.hasPrefix("intl-") && $0 != "embed" }
        guard path.count >= 2, ["playlist", "album", "track"].contains(path[0]) else { return nil }
        return (path[0], path[1])
    }

    static func fetch(_ link: String) async throws -> (name: String, tracks: [Track]) {
        guard let parsed = parseLink(link),
              let url = URL(string: "https://open.spotify.com/embed/\(parsed.kind)/\(parsed.id)") else {
            throw YTError.unplayable("Link Spotify không hợp lệ")
        }
        let kind = parsed.kind
        var req = URLRequest(url: url)
        req.setValue(YTClient.web.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        let html = String(decoding: data, as: UTF8.self)

        guard let re = try? NSRegularExpression(pattern: #"<script id="__NEXT_DATA__"[^>]*>(.*?)</script>"#,
                                                options: .dotMatchesLineSeparators),
              let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let r = Range(m.range(at: 1), in: html) else {
            throw YTError.unplayable("Không đọc được danh sách Spotify (playlist có thể ở chế độ riêng tư)")
        }
        let entity = J(data: Data(html[r].utf8)).first("entity") ?? J(nil)
        let name = entity["name"].string ?? entity["title"].string ?? "Spotify"
        var tracks = entity["trackList"].array.compactMap { t -> Track? in
            guard let title = t["title"].string else { return nil }
            return Track(title: title, artist: t["subtitle"].string ?? "")
        }
        if tracks.isEmpty, kind == "track", let title = entity["title"].string ?? entity["name"].string {
            let artists = entity["artists"].array.compactMap { $0["name"].string }.joined(separator: ", ")
            tracks = [Track(title: title, artist: artists)]
        }
        guard !tracks.isEmpty else { throw YTError.unplayable("Danh sách Spotify trống") }
        return (name, tracks)
    }

    static func matchAll(_ tracks: [Track], progress: @escaping (Int) -> Void) async -> [Video?] {
        await withTaskGroup(of: (Int, Video?).self) { group -> [Video?] in
            var results = [Video?](repeating: nil, count: tracks.count)
            var nextIndex = 0
            var done = 0
            for _ in 0..<min(4, tracks.count) {
                let i = nextIndex
                nextIndex += 1
                group.addTask { (i, await match(tracks[i])) }
            }
            for await (i, video) in group {
                results[i] = video
                done += 1
                progress(done)
                if nextIndex < tracks.count {
                    let k = nextIndex
                    nextIndex += 1
                    group.addTask { (k, await match(tracks[k])) }
                }
            }
            return results
        }
    }

    private static func match(_ t: Track) async -> Video? {
        try? await InnerTube.shared.musicSearch("\(t.title) \(t.artist)", continuation: nil).videos.first
    }
}

@MainActor
final class SpotifyImporter: ObservableObject {
    struct Result {
        let name: String
        let playlist: UUID
        let matched: Int
        let missed: [String]
    }

    @Published private(set) var running = false
    @Published private(set) var done = 0
    @Published private(set) var total = 0
    @Published private(set) var result: Result?
    @Published var error: String?

    func run(_ link: String) {
        guard !running else { return }
        running = true
        error = nil
        result = nil
        Task {
            do {
                let (name, tracks) = try await Spotify.fetch(link)
                total = tracks.count
                done = 0
                let matched = await Spotify.matchAll(tracks) { d in
                    Task { @MainActor in self.done = d }
                }
                let lib = Library.shared
                let id = lib.createPlaylist("Spotify: \(name)")
                matched.compactMap { $0 }.forEach { lib.add($0, to: id) }
                let missed = zip(tracks, matched).filter { $0.1 == nil }.map { $0.0.label }
                result = Result(name: name, playlist: id, matched: tracks.count - missed.count, missed: missed)
            } catch {
                self.error = error.localizedDescription
            }
            running = false
        }
    }
}
