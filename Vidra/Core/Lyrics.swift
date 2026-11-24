import Foundation

struct LyricLine: Hashable, Sendable {
    let time: Double
    let text: String
}

struct LyricsResult: Sendable {
    var synced: [LyricLine]
    var plain: String?

    var isEmpty: Bool { synced.isEmpty && (plain ?? "").isEmpty }
}

/// Lyrics from the public LRCLIB API (https://lrclib.net), cached in memory per track id.
actor LyricsService {
    static let shared = LyricsService()

    private static let cleanPatterns: [(NSRegularExpression, String)] = [
        (try! NSRegularExpression(pattern: #"\s*[\(\[][^\)\]]*official[^\)\]]*[\)\]]"#, options: .caseInsensitive), ""),
        (try! NSRegularExpression(pattern: #"\s*\[[^\]]*\]"#, options: .caseInsensitive), ""),
        (try! NSRegularExpression(pattern: #"\s*[\(\[]?\s*(?:ft\.?|feat\.?|featuring)\s.*$"#, options: .caseInsensitive), ""),
        (try! NSRegularExpression(pattern: #"\s*-\s*Topic\s*$"#, options: .caseInsensitive), "")
    ]
    private static let lrcStamp = try? NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#)

    private struct Item: Decodable {
        let syncedLyrics: String?
        let plainLyrics: String?
    }

    private var cache: [String: LyricsResult] = [:]
    private var misses: Set<String> = []

    func lyrics(for video: Video, duration: Double) async -> LyricsResult? {
        if let hit = cache[video.id] { return hit }
        if misses.contains(video.id) { return nil }

        let title = Self.cleanTitle(video.title)
        let artist = Self.firstArtist(video.channelTitle)
        let seconds = duration > 0 ? duration : (Fmt.seconds(video.duration) ?? 0)

        var item = await fetchExact(title: title, artist: artist, duration: Int(seconds.rounded()))
        if item == nil { item = await search(query: "\(title) \(artist)") }

        guard let item else {
            if !Task.isCancelled {
                if misses.count > 500 { misses.removeAll() }
                misses.insert(video.id)
            }
            return nil
        }
        let synced = Self.parse(item.syncedLyrics ?? "")
        let plain = item.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = LyricsResult(synced: synced, plain: (plain?.isEmpty ?? true) ? nil : plain)
        if result.isEmpty {
            if misses.count > 500 { misses.removeAll() }
            misses.insert(video.id)
            return nil
        }
        if cache.count > 300 { cache.removeAll() }
        cache[video.id] = result
        return result
    }

    // MARK: Network

    private func request(_ path: String, _ query: [URLQueryItem]) -> URLRequest? {
        var c = URLComponents(string: "https://lrclib.net/api/\(path)")
        c?.queryItems = query
        guard let url = c?.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Vidra/1.0", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        return req
    }

    private func fetchExact(title: String, artist: String, duration: Int) async -> Item? {
        var q = [URLQueryItem(name: "track_name", value: title),
                 URLQueryItem(name: "artist_name", value: artist)]
        if duration > 0 { q.append(URLQueryItem(name: "duration", value: String(duration))) }
        guard let req = request("get", q) else { return nil }
        guard let result = try? await URLSession.shared.data(for: req),
              (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let data = result.0
        return try? JSONDecoder().decode(Item.self, from: data)
    }

    private func search(query: String) async -> Item? {
        guard let req = request("search", [URLQueryItem(name: "q", value: query)]) else { return nil }
        guard let result = try? await URLSession.shared.data(for: req),
              (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let data = result.0
        let list = (try? JSONDecoder().decode([Item].self, from: data)) ?? []
        return list.first { !($0.syncedLyrics ?? "").isEmpty } ?? list.first
    }

    // MARK: Cleaning

    static func cleanTitle(_ raw: String) -> String {
        var s = raw
        for (re, replacement) in cleanPatterns {
            let ns = s as NSString
            s = re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: replacement)
        }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? raw : trimmed
    }

    static func firstArtist(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: #"\s*-\s*Topic\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        if let r = s.range(of: #"\s*(?:,|&|;|\sx\s|\sft\.?\s|\sfeat\.?\s)"#, options: [.regularExpression, .caseInsensitive]) {
            s = String(s[s.startIndex..<r.lowerBound])
        }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? raw : trimmed
    }

    // MARK: LRC parsing

    /// "[mm:ss.xx] text" lines; a line may carry several timestamps.
    static func parse(_ lrc: String) -> [LyricLine] {
        guard !lrc.isEmpty, let stamp = lrcStamp else { return [] }
        var lines: [LyricLine] = []
        for raw in lrc.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let matches = stamp.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let text = ns.substring(from: last.range.location + last.range.length)
                .trimmingCharacters(in: .whitespaces)
            for m in matches {
                let min = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let sec = Double(ns.substring(with: m.range(at: 2))) ?? 0
                var frac = 0.0
                if m.range(at: 3).location != NSNotFound {
                    let f = ns.substring(with: m.range(at: 3))
                    frac = (Double(f) ?? 0) / pow(10, Double(f.count))
                }
                lines.append(LyricLine(time: min * 60 + sec + frac, text: text))
            }
        }
        return lines.sorted { $0.time < $1.time }
    }
}
