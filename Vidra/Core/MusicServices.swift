import Foundation

// MARK: - Cross-service matching

/// Maps a track from another catalog (Spotify) to a playable YouTube Music id; cached across launches.
actor TrackMatcher {
    static let shared = TrackMatcher()
    private static let key = "trackMatches"
    private static let customKey = "trackMatchesCustom"
    private var cache = UserDefaults.standard.dictionary(forKey: TrackMatcher.key) as? [String: String] ?? [:]
    private var customIds = Set(UserDefaults.standard.stringArray(forKey: TrackMatcher.customKey) ?? [])
    private var cacheOrder: [String] = []
    private var inFlight: [String: Task<String, Error>] = [:]
    private var saveTask: Task<Void, Never>?

    func currentMatch(for videoId: String) -> String? {
        cache[videoId]
    }

    func setCustomMatch(for spotifyId: String, youtubeId: String) {
        cache[spotifyId] = youtubeId
        customIds.insert(spotifyId)
        persist()
    }

    func youTubeId(for v: Video) async throws -> String {
        if let id = cache[v.id] { return id }
        if let existing = inFlight[v.id] {
            return try await existing.value
        }
        let task = Task<String, Error> {
            let artist = v.channelTitle.components(separatedBy: ",").first ?? v.channelTitle
            let results = try await InnerTube.shared.musicSearch("\(v.title) \(artist)", continuation: nil).videos.prefix(5)
            guard let first = results.first else {
                throw YTError.unplayable("Không tìm thấy nguồn phát cho bài hát này")
            }
            var best = first
            if let target = Fmt.seconds(v.duration), target > 0 {
                let scored = results.min {
                    abs((Fmt.seconds($0.duration) ?? 1e9) - target) < abs((Fmt.seconds($1.duration) ?? 1e9) - target)
                }
                if let scored, let sDur = Fmt.seconds(scored.duration), abs(sDur - target) <= 60 {
                    best = scored
                }
            }
            return best.id
        }
        inFlight[v.id] = task
        defer { inFlight.removeValue(forKey: v.id) }

        let matchedId = try await task.value
        if cache.count > 5000 {
            let customOnly = cache.filter { customIds.contains($0.key) }
            let recentKeys = cacheOrder.suffix(2000)
            var nextCache = customOnly
            for k in recentKeys {
                if let val = cache[k] { nextCache[k] = val }
            }
            cache = nextCache
            cacheOrder = Array(recentKeys)
        }
        cache[v.id] = matchedId
        cacheOrder.append(v.id)
        schedulePersist()
        return matchedId
    }

    func flush() {
        persist()
    }

    private func persist() {
        saveTask?.cancel()
        saveTask = nil
        UserDefaults.standard.set(cache, forKey: Self.key)
        UserDefaults.standard.set(Array(customIds), forKey: Self.customKey)
    }

    private func schedulePersist() {
        guard saveTask == nil else { return }
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            UserDefaults.standard.set(self.cache, forKey: Self.key)
            UserDefaults.standard.set(Array(self.customIds), forKey: Self.customKey)
            self.saveTask = nil
        }
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
              let host = c.host?.lowercased(),
              host == "open.spotify.com" || host == "play.spotify.com" else { return nil }
        let path = c.path.split(separator: "/").map(String.init).filter { !$0.hasPrefix("intl-") && $0 != "embed" }
        guard path.count >= 2, ["playlist", "album", "track"].contains(path[0]), !path[1].isEmpty else { return nil }
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
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw YTError.http(http.statusCode)
        }
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

    static func matchAll(_ tracks: [Track], progress: @escaping @Sendable (Int) -> Void) async -> [Video?] {
        await withTaskGroup(of: (Int, Video?).self) { group -> [Video?] in
            var results = [Video?](repeating: nil, count: tracks.count)
            var nextIndex = 0
            var done = 0
            for _ in 0..<min(4, tracks.count) {
                if Task.isCancelled { break }
                let i = nextIndex
                nextIndex += 1
                group.addTask { (i, await match(tracks[i])) }
            }
            for await (i, video) in group {
                results[i] = video
                done += 1
                progress(done)
                if !Task.isCancelled, nextIndex < tracks.count {
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
    private var importTask: Task<Void, Never>?

    func cancel() {
        importTask?.cancel()
        importTask = nil
        running = false
    }

    func run(_ link: String) {
        guard !running else { return }
        running = true
        error = nil
        result = nil
        importTask?.cancel()
        importTask = Task {
            do {
                let (name, tracks) = try await Spotify.fetch(link)
                guard !Task.isCancelled else {
                    running = false
                    return
                }
                total = tracks.count
                done = 0
                let matched = await Spotify.matchAll(tracks) { d in
                    Task { @MainActor in self.done = d }
                }
                guard !Task.isCancelled else {
                    running = false
                    return
                }
                let playable = matched.compactMap { $0 }
                guard !playable.isEmpty else {
                    error = "Không tìm thấy bài hát phù hợp trên YouTube Music"
                    running = false
                    return
                }
                let lib = Library.shared
                let id = lib.createPlaylist("Spotify: \(name)")
                playable.forEach { lib.add($0, to: id) }
                let missed = zip(tracks, matched).filter { $0.1 == nil }.map { $0.0.label }
                result = Result(name: name, playlist: id, matched: playable.count, missed: missed)
            } catch {
                if !(error is CancellationError) {
                    self.error = error.localizedDescription
                }
            }
            running = false
        }
    }
}
