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
    private static let leadingStamp = try? NSRegularExpression(pattern: #"^(?:\s*\[(\d{1,3}):([0-5]\d)(?:[.:](\d{1,3}))?\])+"#)
    private static let singleStamp = try? NSRegularExpression(pattern: #"\[(\d{1,3}):([0-5]\d)(?:[.:](\d{1,3}))?\]"#)
    private static let offsetTag = try? NSRegularExpression(pattern: #"^\[offset:\s*([+-]?\d+)\s*\]"#, options: .caseInsensitive)

    private struct Item: Decodable {
        let syncedLyrics: String?
        let plainLyrics: String?
        let duration: Double?

        var hasAnyLyrics: Bool {
            !(syncedLyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !(plainLyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private enum FetchOutcome {
        case hit(Item)
        case notFound
        case transientError
    }

    private var cache: [String: LyricsResult] = [:]
    private var cacheOrder: [String] = []
    private var misses: Set<String> = []
    private var missesOrder: [String] = []

    func lyrics(for video: Video, duration: Double) async -> LyricsResult? {
        if let hit = cache[video.id] { return hit }
        if misses.contains(video.id) { return nil }

        let title = Self.cleanTitle(video.title)
        let artist = Self.firstArtist(video.channelTitle)
        let seconds = duration > 0 ? duration : (Fmt.seconds(video.duration) ?? 0)

        var hadTransientError = false
        var chosen: Item?

        let exact = await fetchExact(title: title, artist: artist, duration: Int(seconds.rounded()))
        switch exact {
        case .hit(let item) where item.hasAnyLyrics:
            chosen = item
        case .transientError:
            hadTransientError = true
        default:
            break
        }

        if chosen == nil {
            let searched = await search(query: "\(title) \(artist)", targetSeconds: seconds)
            switch searched {
            case .hit(let item) where item.hasAnyLyrics:
                chosen = item
            case .transientError:
                hadTransientError = true
            default:
                break
            }
        }

        guard let item = chosen else {
            if !Task.isCancelled && !hadTransientError {
                recordMiss(video.id)
            }
            return nil
        }
        let synced = Self.parse(item.syncedLyrics ?? "")
        let plain = item.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = LyricsResult(synced: synced, plain: (plain?.isEmpty ?? true) ? nil : plain)
        if result.isEmpty {
            if !Task.isCancelled && !hadTransientError {
                recordMiss(video.id)
            }
            return nil
        }
        while cacheOrder.count >= 300 {
            let old = cacheOrder.removeFirst()
            cache.removeValue(forKey: old)
        }
        cacheOrder.append(video.id)
        cache[video.id] = result
        return result
    }

    private func recordMiss(_ id: String) {
        if misses.insert(id).inserted {
            missesOrder.append(id)
            while missesOrder.count > 500 {
                let old = missesOrder.removeFirst()
                misses.remove(old)
            }
        }
    }

    // MARK: Network

    private func request(_ path: String, _ query: [URLQueryItem]) -> URLRequest? {
        var c = URLComponents(string: "https://lrclib.net/api/\(path)")
        c?.queryItems = query
        guard let url = c?.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Vidra/1.0", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 12
        return req
    }

    private func fetchExact(title: String, artist: String, duration: Int) async -> FetchOutcome {
        var q = [URLQueryItem(name: "track_name", value: title),
                 URLQueryItem(name: "artist_name", value: artist)]
        if duration > 0 { q.append(URLQueryItem(name: "duration", value: String(duration))) }
        guard let req = request("get", q) else { return .notFound }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return .transientError }
            if http.statusCode == 404 { return .notFound }
            guard http.statusCode == 200 else { return .transientError }
            if let item = try? JSONDecoder().decode(Item.self, from: data) {
                return .hit(item)
            }
            return .notFound
        } catch {
            return .transientError
        }
    }

    private func search(query: String, targetSeconds: Double) async -> FetchOutcome {
        guard let req = request("search", [URLQueryItem(name: "q", value: query)]) else { return .notFound }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return .transientError }
            guard http.statusCode == 200 else { return http.statusCode == 404 ? .notFound : .transientError }
            let list = (try? JSONDecoder().decode([Item].self, from: data)) ?? []
            let withSynced = list.filter { !($0.syncedLyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if !withSynced.isEmpty {
                if targetSeconds > 0, let closest = withSynced.min(by: {
                    abs(($0.duration ?? 1e9) - targetSeconds) < abs(($1.duration ?? 1e9) - targetSeconds)
                }) {
                    return .hit(closest)
                }
                return .hit(withSynced[0])
            }
            if let withPlain = list.first(where: { !($0.plainLyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                return .hit(withPlain)
            }
            return .notFound
        } catch {
            return .transientError
        }
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
        // Split explicit multi-artist delimiters while avoiding lone "&" in band names like "Simon & Garfunkel".
        if let r = s.range(of: #"\s*(?:,|;|\sx\s|\sft\.?\s|\sfeat\.?\s)"#, options: [.regularExpression, .caseInsensitive]) {
            s = String(s[s.startIndex..<r.lowerBound])
        }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? raw : trimmed
    }

    // MARK: LRC parsing

    /// "[mm:ss.xx] text" lines; supports multiple leading timestamps, inline word tags, and `[offset:ms]`.
    static func parse(_ lrc: String) -> [LyricLine] {
        guard !lrc.isEmpty, let leadRe = leadingStamp, let stampRe = singleStamp else { return [] }
        var offsetSeconds = 0.0
        var lines: [LyricLine] = []

        for raw in lrc.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if let offRe = offsetTag,
               let offMatch = offRe.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) {
                let ns = trimmed as NSString
                if let ms = Double(ns.substring(with: offMatch.range(at: 1))) {
                    // LRC [offset:+ms] shifts timestamps earlier (displayed earlier -> subtract offsetSeconds).
                    offsetSeconds = ms / 1000.0
                }
                continue
            }

            let ns = trimmed as NSString
            guard let leadMatch = leadRe.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)) else {
                continue
            }

            let prefixStr = ns.substring(with: leadMatch.range)
            let prefixNS = prefixStr as NSString
            let prefixStamps = stampRe.matches(in: prefixStr, range: NSRange(location: 0, length: prefixNS.length))
            guard !prefixStamps.isEmpty else { continue }

            let bodyRaw = ns.substring(from: leadMatch.range.location + leadMatch.range.length)
            // Strip enhanced LRC inline word timestamps without discarding words before them.
            let bodyNS = bodyRaw as NSString
            let cleanBody = stampRe.stringByReplacingMatches(
                in: bodyRaw,
                range: NSRange(location: 0, length: bodyNS.length),
                withTemplate: ""
            )
            .replacingOccurrences(of: #"<\d{1,3}:[0-5]\d(?:[.:]\d{1,3})?>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

            for m in prefixStamps {
                let min = Double(prefixNS.substring(with: m.range(at: 1))) ?? 0
                let sec = Double(prefixNS.substring(with: m.range(at: 2))) ?? 0
                var frac = 0.0
                if m.range(at: 3).location != NSNotFound {
                    let f = prefixNS.substring(with: m.range(at: 3))
                    frac = (Double(f) ?? 0) / pow(10, Double(f.count))
                }
                let t = max(0, (min * 60 + sec + frac) - offsetSeconds)
                lines.append(LyricLine(time: t, text: cleanBody))
            }
        }
        return lines.sorted { $0.time < $1.time }
    }
}
