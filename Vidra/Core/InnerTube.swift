import Foundation

/// Client identities for YouTube's internal API. Versions go stale over time;
/// if playback breaks, bumping these is usually the first fix.
enum YTClient {
    case web, ios, androidVR, webRemix

    var host: String { self == .webRemix ? "music.youtube.com" : "www.youtube.com" }

    var name: String {
        switch self {
        case .webRemix: return "WEB_REMIX"
        case .web: return "WEB"
        case .ios: return "IOS"
        case .androidVR: return "ANDROID_VR"
        }
    }

    var version: String {
        switch self {
        case .web: return "2.20251101.01.00"
        case .webRemix: return "1.20251101.01.00"
        case .ios: return "20.10.4"
        case .androidVR: return "1.65.10"
        }
    }

    var nameId: String {
        switch self {
        case .web: return "1"
        case .webRemix: return "67"
        case .ios: return "5"
        case .androidVR: return "28"
        }
    }

    var userAgent: String {
        switch self {
        case .web, .webRemix:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        case .ios:
            return "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)"
        case .androidVR:
            return "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"
        }
    }

    func context(hl: String, gl: String, visitorData: String?) -> [String: Any] {
        var c: [String: Any] = ["clientName": name, "clientVersion": version, "hl": hl, "gl": gl]
        switch self {
        case .web, .webRemix: break
        case .ios:
            c["deviceMake"] = "Apple"; c["deviceModel"] = "iPhone16,2"
            c["osName"] = "iPhone"; c["osVersion"] = "18.3.2.22D82"
        case .androidVR:
            c["deviceMake"] = "Oculus"; c["deviceModel"] = "Quest 3"
            c["osName"] = "Android"; c["osVersion"] = "12L"; c["androidSdkVersion"] = 32
            c["userAgent"] = userAgent
            c["timeZone"] = "UTC"
            c["utcOffsetMinutes"] = 0
        }
        if let visitorData { c["visitorData"] = visitorData }
        return ["client": c]
    }
}

actor InnerTube {
    static let shared = InnerTube()
    static let hl = Locale.current.language.languageCode?.identifier ?? "en"
    static let gl = Locale.current.region?.identifier ?? "US"

    private var visitorData: String? = "CgtsRGRWV1hiaVNYcyjAl5bYBjIKCgJWThIEGgAgPUgBYqoCCqcCQ3RvQkNBVVNqQUVCREI2UERMUWpuZ0dJUnNwajdLOHZDRTNVZ0x4NkM3UklBcnNUR2ZUbk9JRDc4MFV0Zmh5WWFFQ0xxWENYQ0ZwaHFUUDdPMFZDWXFaZ2lSR0I4VENIYjdrcXJEVmVNQVF2cDE2bHJLOTczR0E3ZFplRmxxUmRTc0VhZHBZdnpkdlVBUTNyYnVqTC0tRUZIX2psTmZRY21jOHU0TkRDSTByTjBOeDVjTFE2YzN6cktuX3pZSXpQMmJ5QUZpZ0ZNa1VCSEZqMWFqUDY2c05mRVFQdW9YS3hWOGRJOTc1cGk3QUpBUjJDMFFEcWNlRzRJUVY0clk4bVp6aUFGWW9DbGx5b1pEOVhWNmJxdFFRTTU4X0lQazBDYTBkdG1Rcw%3D%3D"
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        return URLSession(configuration: cfg)
    }()

    // MARK: - Transport

    private func post(_ endpoint: String, client: YTClient = .web, body: [String: Any],
                      query: [URLQueryItem] = []) async throws -> J {
        var payload = body
        payload["context"] = client.context(hl: Self.hl, gl: Self.gl, visitorData: visitorData)
        var c = URLComponents(string: "https://\(client.host)/youtubei/v1/\(endpoint)")!
        c.queryItems = [URLQueryItem(name: "prettyPrint", value: "false")] + query
        var req = URLRequest(url: c.url!)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(client.nameId, forHTTPHeaderField: "X-YouTube-Client-Name")
        req.setValue(client.version, forHTTPHeaderField: "X-YouTube-Client-Version")
        req.setValue("https://\(client.host)", forHTTPHeaderField: "Origin")
        if let visitorData { req.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id") }

        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw YTError.http(code) }
        let j = J(data: data)
        if let v = j["responseContext"]["visitorData"].string { visitorData = v }
        return j
    }

    // MARK: - Browse / search

    func search(_ query: String, params: String?, continuation: String?) async throws -> Page {
        var body: [String: Any] = [:]
        if let continuation {
            body["continuation"] = continuation
        } else {
            body["query"] = query
            if let params { body["params"] = params }
        }
        return YTParse.page(try await post("search", body: body))
    }

    func suggestions(_ query: String) async -> [String] {
        var c = URLComponents(string: "https://suggestqueries-clients6.youtube.com/complete/search")!
        c.queryItems = [
            .init(name: "client", value: "firefox"), .init(name: "ds", value: "yt"),
            .init(name: "hl", value: Self.hl), .init(name: "q", value: query),
        ]
        // URLComponents leaves "+" unescaped, which servers read as a space.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = c.url, let res = try? await session.data(from: url) else { return [] }
        var j = J(data: res.0)
        if j.isNull, let s = String(data: res.0, encoding: .isoLatin1), let d = s.data(using: .utf8) { j = J(data: d) }
        return j[1].array.compactMap(\.string)
    }

    func channelVideos(_ id: String, continuation: String?) async throws -> Page {
        if let continuation {
            return YTParse.page(try await post("browse", body: ["continuation": continuation]))
        }
        // params = "Videos" tab
        let j = try await post("browse", body: ["browseId": id, "params": "EgZ2aWRlb3PyBgQKAjoA"])
        var page = YTParse.page(j)
        let meta = j["metadata"]["channelMetadataRenderer"]
        page.channel = Channel(
            id: id,
            title: meta["title"].string ?? "",
            avatar: YTParse.thumb(meta["avatar"]),
            subscribers: j["header"]["c4TabbedHeaderRenderer"]["subscriberCountText"].text
        )
        return page
    }

    func channelPlaylists(_ id: String, continuation: String?) async throws -> Page {
        if let continuation {
            return YTParse.page(try await post("browse", body: ["continuation": continuation]))
        }
        // params = "Playlists" tab
        let j = try await post("browse", body: ["browseId": id, "params": "EglwbGF5bGlzdHPyBgQKAjoA"])
        var page = YTParse.page(j)
        let meta = j["metadata"]["channelMetadataRenderer"]
        page.channel = Channel(
            id: id,
            title: meta["title"].string ?? "",
            avatar: YTParse.thumb(meta["avatar"]),
            subscribers: j["header"]["c4TabbedHeaderRenderer"]["subscriberCountText"].text
        )
        return page
    }

    func playlist(_ id: String, continuation: String?) async throws -> Page {
        if let continuation {
            return YTParse.page(try await post("browse", body: ["continuation": continuation]))
        }
        let j = try await post("browse", body: ["browseId": "VL" + id])
        var page = YTParse.page(j)
        page.title = j["metadata"]["playlistMetadataRenderer"]["title"].string
        return page
    }

    func next(_ id: String) async throws -> (related: [Video], commentsToken: String?) {
        let j = try await post("next", body: ["videoId": id])
        let secondary = j["contents"]["twoColumnWatchNextResults"]["secondaryResults"]
        let related = YTParse.page(secondary.isNull ? j : secondary).videos.filter { $0.id != id }
        var token: String?
        for (_, s) in j.collect(["itemSectionRenderer"]) where s["sectionIdentifier"].string == "comment-item-section" {
            token = s.first("continuationCommand")?["token"].string
        }
        return (related, token)
    }

    func comments(_ token: String) async throws -> (items: [Comment], next: String?) {
        let j = try await post("next", body: ["continuation": token])
        var items: [Comment] = []
        for (_, p) in j.collect(["commentEntityPayload"]) {
            let props = p["properties"]
            items.append(Comment(
                id: props["commentId"].string ?? UUID().uuidString,
                author: p["author"]["displayName"].string ?? "",
                avatar: p["author"]["avatarThumbnailUrl"].string.flatMap { URL(string: $0) },
                text: props["content"]["content"].string ?? "",
                published: props["publishedTime"].string ?? "",
                likes: p["toolbar"]["likeCountNotliked"].string ?? ""
            ))
        }
        if items.isEmpty {
            for (_, c) in j.collect(["commentRenderer"]) {
                items.append(Comment(
                    id: c["commentId"].string ?? UUID().uuidString,
                    author: c["authorText"].text ?? "",
                    avatar: YTParse.thumb(c["authorThumbnail"]),
                    text: c["contentText"].text ?? "",
                    published: c["publishedTimeText"].text ?? "",
                    likes: c["voteCount"].text ?? ""
                ))
            }
        }
        // Only top-level continuations; nested ones belong to reply threads.
        var next: String?
        for e in j["onResponseReceivedEndpoints"].array {
            let reload = e["reloadContinuationItemsCommand"]["continuationItems"]
            let items = reload.isNull ? e["appendContinuationItemsAction"]["continuationItems"] : reload
            if let t = items.array.last?["continuationItemRenderer"].first("continuationCommand")?["token"].string {
                next = t
            }
        }
        return (items, next)
    }

    // MARK: - YouTube Music

    func musicHome() async throws -> Page {
        var page = YTParse.musicPage(try await post("browse", client: .webRemix, body: ["browseId": "FEmusic_home"]))
        page.continuation = nil
        return page
    }

    func musicSearch(_ query: String, continuation: String?) async throws -> Page {
        let j: J
        if let continuation, continuation.hasPrefix("ct:") {
            let token = String(continuation.dropFirst(3))
            j = try await post("search", client: .webRemix, body: [:], query: [
                .init(name: "ctoken", value: token), .init(name: "continuation", value: token), .init(name: "type", value: "next"),
            ])
        } else if let continuation {
            j = try await post("search", client: .webRemix, body: ["continuation": continuation])
        } else {
            // params = "Songs" filter
            j = try await post("search", client: .webRemix, body: ["query": query, "params": "EgWKAQIIAWoKEAkQBRAKEAMQBA=="])
        }
        return YTParse.musicPage(j)
    }

    /// Endless "radio" queue seeded by a song — what YouTube Music plays next.
    func musicRadio(_ id: String) async throws -> [Video] {
        let j = try await post("next", client: .webRemix, body: ["videoId": id, "playlistId": "RDAMVM" + id, "isAudioOnly": true])
        var seen: Set<String> = [id]
        var out: [Video] = []
        for (_, r) in j.collect(["playlistPanelVideoRenderer"]) {
            guard var v = YTParse.video(r), seen.insert(v.id).inserted else { continue }
            v.source = .ytMusic
            v.artwork = YTParse.musicArt(r["thumbnail"])
            out.append(v)
        }
        return out
    }

    // MARK: - Streams

    private func player(_ id: String, client: YTClient, startTimeSecs: Int? = nil) async throws -> J {
        var body: [String: Any] = [
            "videoId": id,
            "contentCheckOk": true,
            "racyCheckOk": true,
            "playbackContext": [
                "contentPlaybackContext": [
                    "html5Preference": "HTML5_PREF_WANTS"
                ]
            ]
        ]
        if let s = startTimeSecs, s > 0 { body["startTimeSecs"] = s }
        return try await post("player", client: client, body: body)
    }

    private func tryPlayer(_ id: String, _ client: YTClient, startTimeSecs: Int? = nil) async -> J? {
        try? await player(id, client: client, startTimeSecs: startTimeSecs)
    }

    /// Plays raw streams directly, so no ads are ever requested or shown.
    func resolve(_ id: String, audioOnly: Bool, maxHeight: Int, startTimeSecs: Int? = nil) async throws -> ResolvedVideo {
        let needsHighRes = !audioOnly && (maxHeight > 1080 || maxHeight == 0)
        async let iosRes = tryPlayer(id, .ios, startTimeSecs: startTimeSecs)
        async let vrRes = needsHighRes ? tryPlayer(id, .androidVR, startTimeSecs: startTimeSecs) : nil
        var ios = await iosRes
        var vr = await vrRes

        func playable(_ j: J?) -> J? { j?["playabilityStatus"]["status"].string == "OK" ? j : nil }
        var iosOK = playable(ios)
        var vrOK = playable(vr)

        // Fallback to AndroidVR if iOS stream is unavailable/unplayable and VR wasn't fetched yet
        if iosOK == nil && vrOK == nil && !needsHighRes {
            vr = await tryPlayer(id, .androidVR, startTimeSecs: startTimeSecs)
            vrOK = playable(vr)
        }

        guard let meta = iosOK ?? vrOK else {
            let reason = (ios ?? vr)?["playabilityStatus"]["reason"].string
            throw YTError.unplayable(reason ?? "Video không khả dụng")
        }

        let directCandidates = [iosOK, vrOK].compactMap { $0 }.map { YTParse.directFormats($0, maxHeight: maxHeight) }
        let direct = DirectSet(
            video: directCandidates.compactMap(\.video).first,
            audio: directCandidates.compactMap(\.audio).first,
            muxed: directCandidates.compactMap(\.muxed).first
        )

        // If high resolution (>1080p) is selected, also prepare a 1080p H.264 fallback
        let fallbackDirect: DirectSet? = {
            guard (maxHeight > 1080 || maxHeight == 0), (direct.video?.height ?? 0) > 1080 else { return nil }
            let fCandidates = [iosOK, vrOK].compactMap { $0 }.map { YTParse.directFormats($0, maxHeight: 1080) }
            return DirectSet(
                video: fCandidates.compactMap(\.video).first,
                audio: fCandidates.compactMap(\.audio).first,
                muxed: fCandidates.compactMap(\.muxed).first
            )
        }()
        let isLive = (vrOK ?? iosOK)?["videoDetails"]["isLive"].bool ?? false
        let hls = [vrOK, iosOK].compactMap { $0?["streamingData"]["hlsManifestUrl"].string }.compactMap { URL(string: $0) }

        // Ordered by preference; the player falls through on failure.
        var sources: [PlaybackSource] = []
        if isLive {
            // 1. YouTube provided official HLS manifest (.m3u8)
            sources = hls.map { PlaybackSource.hls($0) }

            // 2. Dynamic Sliding-Window Live HLS reconstructed from adaptive live tracks
            if !audioOnly, let v = direct.video, let a = direct.audio {
                if let liveMaster = await HLSBuilder.buildLiveMaster(id: id, video: v, audio: a) {
                    sources.append(.hls(liveMaster))
                }
            }
            if let a = direct.audio {
                if let liveAudio = await HLSBuilder.buildLiveAudio(id: id, audio: a) {
                    sources.append(.hls(liveAudio))
                }
            }
        } else if audioOnly {
            if let a = direct.audio {
                if let audioHLS = await HLSBuilder.buildAudio(id: id, audio: a, startTimeSecs: startTimeSecs) {
                    sources.append(.hls(audioHLS))
                }
                sources.append(.progressive(a.url))
            }
            sources += hls.map { PlaybackSource.hls($0) }
        } else {
            // 1. Primary high-resolution source (4K / 2K / 1080p)
            if let v = direct.video, let a = direct.audio {
                if let dynamicHLS = await HLSBuilder.buildMaster(id: id, video: v, audio: a, startTimeSecs: startTimeSecs) {
                    sources.append(.hls(dynamicHLS))
                }
                sources.append(.composite(video: v.url, audio: a.url))
            }

            // 2. Fallback to 1080p H.264 if high-res stream is unplayable on this hardware
            if let fb = fallbackDirect, let fv = fb.video, let fa = fb.audio ?? direct.audio, (fv.height ?? 0) < (direct.video?.height ?? 0) {
                if let dynamicHLS1080 = await HLSBuilder.buildMaster(id: id, video: fv, audio: fa, startTimeSecs: startTimeSecs) {
                    sources.append(.hls(dynamicHLS1080))
                }
                sources.append(.composite(video: fv.url, audio: fa.url))
            }

            if let m = direct.muxed { sources.append(.progressive(m.url)) }
            sources += hls.map { PlaybackSource.hls($0) }
            if let a = direct.audio {
                if let audioHLS = await HLSBuilder.buildAudio(id: id, audio: a, startTimeSecs: startTimeSecs) {
                    sources.append(.hls(audioHLS))
                }
                sources.append(.progressive(a.url))
            }
        }
        guard !sources.isEmpty else { throw YTError.noStreams }

        let details = YTParse.details(meta, id: id)
        var info = details.1
        info.storyboard = [vrOK, iosOK].compactMap { $0?["storyboards"]["playerStoryboardSpecRenderer"]["spec"].string }.first
        let rawCaptions = [iosOK, vrOK].compactMap { $0?["captions"]["playerCaptionsTracklistRenderer"]["captionTracks"].array }.first ?? []
        info.captions = rawCaptions.compactMap { ct in
            guard let base = ct["baseUrl"].string else { return nil }
            let vttUrlString = base + (base.contains("?") ? "&" : "?") + "fmt=vtt"
            guard let url = URL(string: vttUrlString) else { return nil }
            let name = ct["name"].text ?? ct["languageCode"].string ?? ""
            let lang = ct["languageCode"].string ?? ""
            return CaptionTrack(name: name, languageCode: lang, url: url)
        }
        return ResolvedVideo(video: details.0, info: info, sources: sources)
    }

    func fetchCaptions(from url: URL) async -> [CaptionCue] {
        guard let res = try? await session.data(from: url),
              let text = String(data: res.0, encoding: .utf8) else { return [] }
        return Self.parseVTT(text)
    }

    static func parseVTT(_ text: String) -> [CaptionCue] {
        var cues: [CaptionCue] = []
        let lines = text.components(separatedBy: .newlines)
        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.contains("-->") {
                let parts = line.components(separatedBy: "-->")
                if parts.count == 2,
                   let start = parseVTTTime(parts[0].trimmingCharacters(in: .whitespaces)),
                   let end = parseVTTTime(parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? "") {
                    i += 1
                    var textParts: [String] = []
                    while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                        let clean = lines[i].replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                            .trimmingCharacters(in: .whitespaces)
                        if !clean.isEmpty { textParts.append(clean) }
                        i += 1
                    }
                    let fullText = textParts.joined(separator: "\n")
                    if !fullText.isEmpty {
                        cues.append(CaptionCue(start: start, end: end, text: fullText))
                    }
                }
            }
            i += 1
        }
        return cues
    }

    private static func parseVTTTime(_ raw: String) -> Double? {
        let p = raw.split(separator: ":").map(String.init)
        guard p.count >= 2 else { return nil }
        if p.count == 3 {
            guard let h = Double(p[0]), let m = Double(p[1]), let s = Double(p[2].replacingOccurrences(of: ",", with: ".")) else { return nil }
            return h * 3600 + m * 60 + s
        } else if p.count == 2 {
            guard let m = Double(p[0]), let s = Double(p[1].replacingOccurrences(of: ",", with: ".")) else { return nil }
            return m * 60 + s
        }
        return nil
    }

    func directFormats(_ id: String) async throws -> (video: Video, formats: DirectSet) {
        async let iosRes = tryPlayer(id, .ios)
        async let vrRes = tryPlayer(id, .androidVR)
        let ios = await iosRes, vr = await vrRes

        func playable(_ j: J?) -> J? { j?["playabilityStatus"]["status"].string == "OK" ? j : nil }
        guard let meta = playable(ios) ?? playable(vr) else {
            let reason = (ios ?? vr)?["playabilityStatus"]["reason"].string
            throw YTError.unplayable(reason ?? "Video không khả dụng")
        }

        let directCandidates = [playable(ios), playable(vr)].compactMap { $0 }.map { YTParse.directFormats($0, maxHeight: Pref.maxHeight) }
        let direct = DirectSet(
            video: directCandidates.compactMap(\.video).first,
            audio: directCandidates.compactMap(\.audio).first,
            muxed: directCandidates.compactMap(\.muxed).first
        )
        return (YTParse.details(meta, id: id).0, direct)
    }
}

// MARK: - Parsing

enum YTParse {
    private static let itemKeys: Set<String> = [
        "videoRenderer", "compactVideoRenderer", "gridVideoRenderer", "playlistVideoRenderer",
        "lockupViewModel", "channelRenderer", "continuationItemRenderer", "playlistRenderer", "gridPlaylistRenderer"
    ]

    static func page(_ j: J) -> Page {
        var page = Page()
        var seen = Set<String>()
        for (key, value) in j.collect(itemKeys) {
            switch key {
            case "channelRenderer":
                if let c = channel(value) { page.channels.append(c) }
            case "continuationItemRenderer":
                if let t = value.first("continuationCommand")?["token"].string { page.continuation = t }
            case "playlistRenderer", "gridPlaylistRenderer":
                if let p = playlist(value) { page.playlists.append(p) }
            case "lockupViewModel":
                if let v = lockup(value), seen.insert(v.id).inserted {
                    page.videos.append(v)
                } else if let p = lockupPlaylist(value) {
                    page.playlists.append(p)
                }
            default:
                if let v = video(value), seen.insert(v.id).inserted { page.videos.append(v) }
            }
        }
        return page
    }

    static func video(_ r: J) -> Video? {
        guard let id = r["videoId"].string else { return nil }
        let owner = [r["ownerText"], r["longBylineText"], r["shortBylineText"]].first { !$0["runs"].array.isEmpty }
        let run = owner?["runs"][0]
        let duration = r["lengthText"].text
            ?? r["thumbnailOverlays"].first("thumbnailOverlayTimeStatusRenderer")?["text"].text
        return Video(
            id: id,
            title: r["title"].text ?? "",
            channelTitle: run?["text"].string ?? "",
            channelId: run?["navigationEndpoint"]["browseEndpoint"]["browseId"].string,
            duration: duration,
            views: r["shortViewCountText"].text ?? r["viewCountText"].text,
            published: r["publishedTimeText"].text
        )
    }

    static func lockup(_ l: J) -> Video? {
        guard let id = l["contentId"].string, l["contentType"].string == "LOCKUP_CONTENT_TYPE_VIDEO" else { return nil }
        let meta = l["metadata"]["lockupMetadataViewModel"]
        let rows = meta["metadata"]["contentMetadataViewModel"]["metadataRows"].array.map { row in
            row["metadataParts"].array.compactMap { $0["text"]["content"].string }
        }
        // Rows are [channel], [views, age] — or just [views, age] on channel pages.
        let channelTitle = rows.count > 1 ? (rows[0].first ?? "") : ""
        let stats = rows.last ?? []
        let channelId = l.collect(["browseId"]).compactMap { $0.value.string }.first { $0.hasPrefix("UC") }
        return Video(
            id: id,
            title: meta["title"]["content"].string ?? "",
            channelTitle: channelTitle,
            channelId: channelId,
            duration: l["contentImage"].first("thumbnailBadgeViewModel")?["text"].string,
            views: stats.first,
            published: stats.count > 1 ? stats[1] : nil
        )
    }

    static func lockupPlaylist(_ l: J) -> ChannelPlaylist? {
        guard let id = l["contentId"].string, l["contentType"].string == "LOCKUP_CONTENT_TYPE_PLAYLIST" else { return nil }
        let meta = l["metadata"]["lockupMetadataViewModel"]
        return ChannelPlaylist(
            id: id,
            title: meta["title"]["content"].string ?? "",
            thumbnail: thumb(l["contentImage"]),
            videoCount: l["contentImage"].first("thumbnailBadgeViewModel")?["text"].string
        )
    }

    static func playlist(_ r: J) -> ChannelPlaylist? {
        guard let id = r["playlistId"].string else { return nil }
        let count = r["videoCountText"].text ?? r["videoCountShortText"].text ?? r["videoCount"].text
        return ChannelPlaylist(
            id: id,
            title: r["title"].text ?? "",
            thumbnail: thumb(r["thumbnail"]),
            videoCount: count
        )
    }

    static func channel(_ r: J) -> Channel? {
        guard let id = r["channelId"].string else { return nil }
        return Channel(
            id: id,
            title: r["title"].text ?? "",
            avatar: thumb(r["thumbnail"]),
            subscribers: r["videoCountText"].text ?? r["subscriberCountText"].text
        )
    }

    static func musicPage(_ j: J) -> Page {
        var page = Page()
        var seen = Set<String>()
        let keys: Set<String> = ["musicResponsiveListItemRenderer", "musicTwoRowItemRenderer",
                                 "nextContinuationData", "continuationItemRenderer"]
        for (key, r) in j.collect(keys) {
            switch key {
            case "nextContinuationData":
                if let c = r["continuation"].string { page.continuation = "ct:" + c }
            case "continuationItemRenderer":
                if let t = r.first("continuationCommand")?["token"].string { page.continuation = t }
            case "musicTwoRowItemRenderer":
                if let v = musicTwoRow(r), seen.insert(v.id).inserted { page.videos.append(v) }
            default:
                if let v = musicItem(r), seen.insert(v.id).inserted { page.videos.append(v) }
            }
        }
        return page
    }

    /// Song row: flexColumns[0] = title, [1] = "Artist • Album • 3:45", [2] = plays.
    static func musicItem(_ r: J) -> Video? {
        guard let id = r["playlistItemData"]["videoId"].string ?? r.first("watchEndpoint")?["videoId"].string else { return nil }
        let cols = r["flexColumns"].array.map { $0["musicResponsiveListItemFlexColumnRenderer"]["text"] }
        let runs = cols.count > 1 ? cols[1]["runs"].array : []
        // A "[" at the start of a line would begin a new statement, so the subscript chain is split via a local.
        let artistRun = runs.first { run in
            let configs = run["navigationEndpoint"]["browseEndpoint"]["browseEndpointContextSupportedConfigs"]
            return configs["browseEndpointContextMusicConfig"]["pageType"].string == "MUSIC_PAGE_TYPE_ARTIST"
        }
        let parts = runs.compactMap { $0["text"].string?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "•" && $0 != "&" && $0 != "," }
        let duration = parts.last.flatMap { Fmt.seconds($0) != nil ? $0 : nil }
            ?? r["fixedColumns"].first("text")?.text
        return Video(
            id: id,
            title: cols.first?.text ?? "",
            channelTitle: artistRun?["text"].string ?? parts.first ?? "",
            channelId: artistRun?["navigationEndpoint"]["browseEndpoint"]["browseId"].string,
            duration: duration,
            views: cols.count > 2 ? cols[2].text : nil,
            source: .ytMusic,
            artwork: musicArt(r["thumbnail"]["musicThumbnailRenderer"]["thumbnail"])
        )
    }

    static func musicTwoRow(_ r: J) -> Video? {
        guard let id = r["navigationEndpoint"]["watchEndpoint"]["videoId"].string else { return nil }
        return Video(
            id: id,
            title: r["title"].text ?? "",
            channelTitle: r["subtitle"].text ?? "",
            source: .ytMusic,
            artwork: musicArt(r["thumbnailRenderer"]["musicThumbnailRenderer"]["thumbnail"])
        )
    }

    /// Music thumbnails come at 60px; the URL suffix picks the size.
    static func musicArt(_ t: J) -> URL? {
        guard let url = thumb(t) else { return nil }
        let s = url.absoluteString.replacingOccurrences(of: #"=w\d+-h\d+"#, with: "=w400-h400", options: .regularExpression)
        return URL(string: s)
    }

    static func thumb(_ t: J) -> URL? {
        guard var s = t["thumbnails"].array.last?["url"].string else { return nil }
        if s.hasPrefix("//") { s = "https:" + s }
        return URL(string: s)
    }

    static func details(_ j: J, id: String) -> (Video, VideoInfo) {
        let d = j["videoDetails"]
        let live = d["isLive"].bool ?? false
        let views = d["viewCount"].int
        let video = Video(
            id: id,
            title: d["title"].string ?? "",
            channelTitle: d["author"].string ?? "",
            channelId: d["channelId"].string,
            duration: d["lengthSeconds"].int.flatMap { $0 > 0 && !live ? Fmt.time(Double($0)) : nil },
            views: views.map { "\(Fmt.count($0)) lượt xem" },
            published: nil
        )
        return (video, VideoInfo(description: d["shortDescription"].string ?? "", viewCount: views, isLive: live))
    }

    static func directFormats(_ j: J, maxHeight: Int) -> DirectSet {
        let sd = j["streamingData"]
        func format(_ f: J) -> DirectFormat? {
            guard let s = f["url"].string, let url = URL(string: s) else { return nil }
            let ir = f["initRange"]
            let initR = ir["start"].string.flatMap { s in ir["end"].string.flatMap { e in Int(s).flatMap { si in Int(e).map { (si, $0) } } } }
            let xr = f["indexRange"]
            let indexR = xr["start"].string.flatMap { s in xr["end"].string.flatMap { e in Int(s).flatMap { si in Int(e).map { (si, $0) } } } }
            return DirectFormat(
                url: url,
                size: f["contentLength"].string.flatMap { Int64($0) },
                width: f["width"].int,
                height: f["height"].int,
                fps: f["fps"].int,
                bitrate: f["bitrate"].int ?? 0,
                mime: f["mimeType"].string ?? "",
                isDefaultAudio: f["audioTrack"]["audioIsDefault"].bool ?? true,
                initRange: initR,
                indexRange: indexR
            )
        }
        let adaptive = sd["adaptiveFormats"].array.compactMap(format)
        let cap = maxHeight > 0 ? maxHeight : 2160
        // Supported video streams in ISO BMFF (MP4) container.
        // H.264 (avc1) is hardware-accelerated on all iOS devices up to 1080p.
        // 2K (1440p) and 4K (2160p) are served by YouTube in AV1 (av01) in MP4 container.
        let mp4Videos = adaptive.filter {
            $0.mime.hasPrefix("video/mp4") && ($0.height ?? 0) <= cap
        }
        let video: DirectFormat? = {
            if cap > 1080 {
                // If 2K or 4K requested, select highest resolution available up to cap
                return mp4Videos.max {
                    ($0.height ?? 0, $0.fps ?? 30, $0.bitrate) < ($1.height ?? 0, $1.fps ?? 30, $1.bitrate)
                }
            } else {
                // For <= 1080p, prioritize H.264 (avc1) for maximum battery efficiency, falling back to any MP4
                let avc = mp4Videos.filter { $0.mime.contains("avc1") }
                return (avc.isEmpty ? mp4Videos : avc).max {
                    ($0.height ?? 0, $0.fps ?? 30, $0.bitrate) < ($1.height ?? 0, $1.fps ?? 30, $1.bitrate)
                }
            }
        }()
        let audio = adaptive
            .filter { $0.mime.hasPrefix("audio/mp4") && $0.isDefaultAudio }
            .max { $0.bitrate < $1.bitrate }
        let muxed = sd["formats"].array.compactMap(format).max { ($0.height ?? 0) < ($1.height ?? 0) }
        return DirectSet(video: video, audio: audio, muxed: muxed)
    }
}
