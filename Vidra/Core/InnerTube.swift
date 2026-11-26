import Foundation
import VideoToolbox

/// Client identities for YouTube's internal API. Versions go stale over time;
/// if playback breaks, bumping these is usually the first fix.
enum YTClient: String, Sendable, Equatable {
    case web, ios, androidVR, webRemix, tvEmbedded

    var host: String { self == .webRemix ? "music.youtube.com" : "www.youtube.com" }

    var name: String {
        switch self {
        case .webRemix: return "WEB_REMIX"
        case .web: return "WEB"
        case .ios: return "IOS"
        case .androidVR: return "ANDROID_VR"
        case .tvEmbedded: return "TVHTML5_SIMPLY_EMBEDDED_PLAYER"
        }
    }

    var version: String {
        switch self {
        case .web: return "2.20251101.01.00"
        case .webRemix: return "1.20251101.01.00"
        case .ios: return "20.10.4"
        case .androidVR: return "1.65.10"
        case .tvEmbedded: return "2.0"
        }
    }

    var nameId: String {
        switch self {
        case .web: return "1"
        case .webRemix: return "67"
        case .ios: return "5"
        case .androidVR: return "28"
        case .tvEmbedded: return "85"
        }
    }

    var isBrowser: Bool {
        self == .web || self == .webRemix || self == .tvEmbedded
    }

    var userAgent: String {
        switch self {
        case .web, .webRemix:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        case .ios:
            return "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)"
        case .androidVR:
            return "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"
        case .tvEmbedded:
            return "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version"
        }
    }

    func context(hl: String, gl: String, visitorData: String?) -> [String: Any] {
        var c: [String: Any] = ["clientName": name, "clientVersion": version, "hl": hl, "gl": gl]
        switch self {
        case .web, .webRemix:
            break
        case .tvEmbedded:
            c["clientScreen"] = "EMBED"
        case .ios:
            c["deviceMake"] = "Apple"
            c["deviceModel"] = "iPhone16,2"
            c["osName"] = "iPhone"
            c["osVersion"] = "18.3.2.22D82"
        case .androidVR:
            c["deviceMake"] = "Oculus"
            c["deviceModel"] = "Quest 3"
            c["osName"] = "Android"
            c["osVersion"] = "12L"
            c["androidSdkVersion"] = 32
            c["userAgent"] = userAgent
            c["timeZone"] = "UTC"
            c["utcOffsetMinutes"] = 0
        }
        if let visitorData, !visitorData.isEmpty { c["visitorData"] = visitorData }
        var ctx: [String: Any] = ["client": c]
        if self == .tvEmbedded {
            ctx["thirdParty"] = ["embedUrl": "https://www.youtube.com/"]
        }
        return ctx
    }
}

actor InnerTube {
    static let shared = InnerTube()
    static var hl: String { Locale.current.language.languageCode?.identifier ?? "en" }
    static var gl: String { Locale.current.region?.identifier ?? "US" }

    /// Hardware AV1 decode check (av01 FourCC = 0x61763031) safe across all iOS 16+ targets.
    static let supportsHardwareAV1: Bool = {
        VTIsHardwareDecodeSupported(0x61763031)
    }()

    /// Isolated visitorData per client session so WEB/WEB_REMIX never contaminate IOS/ANDROID_VR player tokens.
    private var visitorDataByClient: [YTClient: String] = [:]

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        cfg.httpMaximumConnectionsPerHost = 8
        cfg.httpShouldUsePipelining = true
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .useProtocolCachePolicy
        return URLSession(configuration: cfg)
    }()

    private static func makeCPN() -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return String((0..<16).map { _ in chars.randomElement()! })
    }

    // MARK: - Transport

    private func post(_ endpoint: String, client: YTClient = .web, body: [String: Any],
                      query: [URLQueryItem] = []) async throws -> J {
        try Task.checkCancellation()
        var payload = body
        let visitor = visitorDataByClient[client]
        payload["context"] = client.context(hl: Self.hl, gl: Self.gl, visitorData: visitor)
        guard var c = URLComponents(string: "https://\(client.host)/youtubei/v1/\(endpoint)") else {
            throw YTError.unplayable("URL InnerTube không hợp lệ")
        }
        c.queryItems = [URLQueryItem(name: "prettyPrint", value: "false")] + query
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = c.url else {
            throw YTError.unplayable("URL InnerTube không hợp lệ")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
        req.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(client.nameId, forHTTPHeaderField: "X-YouTube-Client-Name")
        req.setValue(client.version, forHTTPHeaderField: "X-YouTube-Client-Version")
        if client.isBrowser {
            req.setValue("https://\(client.host)", forHTTPHeaderField: "Origin")
            req.setValue("https://\(client.host)/", forHTTPHeaderField: "Referer")
        }
        if let visitor, !visitor.isEmpty {
            req.setValue(visitor, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }

        let (data, resp) = try await session.data(for: req)
        try Task.checkCancellation()
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw YTError.http(code) }
        let j = J(data: data)
        guard !j.isNull else { throw YTError.unplayable("Phản hồi máy chủ không hợp lệ") }
        if let v = j["responseContext"]["visitorData"].string, !v.isEmpty {
            visitorDataByClient[client] = v
        }
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
        guard let url = c.url, let (data, resp) = try? await session.data(from: url),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return [] }
        var j = J(data: data)
        if j.isNull, let s = String(data: data, encoding: .isoLatin1), let d = s.data(using: .utf8) { j = J(data: d) }
        return j[1].array.compactMap(\.string)
    }

    func channelVideos(_ id: String, continuation: String?) async throws -> Page {
        if let continuation {
            return YTParse.page(try await post("browse", body: ["continuation": continuation]))
        }
        // params = "Videos" tab
        let j = try await post("browse", body: ["browseId": id, "params": "EgZ2aWRlb3PyBgQKAjoA"])
        var page = YTParse.page(j)
        page.channel = YTParse.channelHeader(j, id: id)
        return page
    }

    func channelPlaylists(_ id: String, continuation: String?) async throws -> Page {
        if let continuation {
            return YTParse.page(try await post("browse", body: ["continuation": continuation]))
        }
        // params = "Playlists" tab
        let j = try await post("browse", body: ["browseId": id, "params": "EglwbGF5bGlzdHPyBgQKAjoA"])
        var page = YTParse.page(j)
        page.channel = YTParse.channelHeader(j, id: id)
        return page
    }

    func playlist(_ id: String, continuation: String?) async throws -> Page {
        if let continuation {
            return YTParse.page(try await post("browse", body: ["continuation": continuation]))
        }
        let browseId = id.hasPrefix("VL") ? id : "VL" + id
        let j = try await post("browse", body: ["browseId": browseId])
        var page = YTParse.page(j)
        page.title = j["metadata"]["playlistMetadataRenderer"]["title"].text
            ?? j["header"]["playlistHeaderRenderer"]["title"].text
        return page
    }

    func next(_ id: String) async throws -> (related: [Video], commentsToken: String?) {
        let j = try await post("next", body: ["videoId": id])
        let secondary = j["contents"]["twoColumnWatchNextResults"]["secondaryResults"]
        let related = YTParse.page(secondary.isNull ? j : secondary).videos.filter { $0.id != id }
        var token: String?
        for (_, s) in j.collect(["itemSectionRenderer"])
        where s["sectionIdentifier"].string == "comment-item-section" || s["targetId"].string == "comments-section" {
            if let t = s.first("continuationCommand")?["token"].string {
                token = t
                break
            }
        }
        if token == nil {
            for (_, p) in j.collect(["engagementPanelSectionListRenderer"])
            where p["panelIdentifier"].string == "engagement-panel-comments-section" {
                if let t = p.first("continuationCommand")?["token"].string {
                    token = t
                    break
                }
            }
        }
        return (related, token)
    }

    func comments(_ token: String) async throws -> (items: [Comment], next: String?) {
        let j = try await post("next", body: ["continuation": token])

        // Index modern frameworkUpdates payloads so commentThreadRenderer keeps exact order & repliesToken.
        var entityPayloads: [String: J] = [:]
        var toolbarStates: [String: J] = [:]
        for mut in j["frameworkUpdates"]["entityBatchUpdate"]["mutations"].array {
            let p = mut["payload"]
            if !p["commentEntityPayload"].isNull {
                let cp = p["commentEntityPayload"]
                if let cid = cp["properties"]["commentId"].string ?? mut["entityKey"].string {
                    entityPayloads[cid] = cp
                }
            } else if !p["engagementToolbarStateEntityPayload"].isNull {
                let ts = p["engagementToolbarStateEntityPayload"]
                if let key = mut["entityKey"].string ?? ts["key"].string {
                    toolbarStates[key] = ts
                }
            }
        }

        var items: [Comment] = []

        // 1. Classic & modern commentThreadRenderer
        let threads = j.collect(["commentThreadRenderer"])
        for (_, thread) in threads {
            let repliesRenderer = thread["replies"]["commentRepliesRenderer"]
            let repliesToken = repliesRenderer.first("continuationCommand")?["token"].string
                ?? repliesRenderer.first("nextContinuationData")?["continuation"].string

            let c = thread["comment"]["commentRenderer"]
            if !c.isNull {
                let replyCount = thread["replyCount"].int ?? c["replyCount"].int ?? Int(c["replyCount"].string ?? "") ?? 0
                let isHearted = !c["actionButtons"]["commentActionButtonsRenderer"]["creatorHeart"].isNull
                let isPinned = !thread["pinnedCommentBadge"].isNull || !c["pinnedCommentBadge"].isNull
                let isOwner = c["authorIsChannelOwner"].bool ?? false

                items.append(Comment(
                    id: c["commentId"].string ?? UUID().uuidString,
                    author: c["authorText"].text ?? "",
                    avatar: YTParse.thumb(c["authorThumbnail"]),
                    text: c["contentText"].text ?? "",
                    published: c["publishedTimeText"].text ?? "",
                    likes: c["voteCount"].text ?? "",
                    isChannelOwner: isOwner,
                    isHeartedByCreator: isHearted,
                    isPinned: isPinned,
                    replyCount: replyCount,
                    repliesToken: repliesToken
                ))
                continue
            }

            let vm = thread["commentViewModel"]["commentViewModel"]
            let cid = vm["commentId"].string ?? thread["commentViewModel"]["commentId"].string
            if let cid, let cp = entityPayloads[cid] {
                let props = cp["properties"]
                let toolbar = cp["toolbar"]
                let author = cp["author"]
                let stateKey = props["toolbarStateKey"].string
                let ts = stateKey.flatMap { toolbarStates[$0] }
                let isHearted = toolbar["heartState"].string == "CREATOR_HEART_STATE_HEARTED"
                    || ts?["heartState"].string == "CREATOR_HEART_STATE_HEARTED"
                let isPinned = !vm["pinnedText"].isNull || !cp["pinnedText"].isNull || props["isPinned"].bool == true
                let isOwner = author["isCreator"].bool ?? false
                let replyCount = Int(toolbar["replyCount"].string ?? "") ?? toolbar["replyCount"].int ?? 0
                let avatarURL = YTParse.normalizeURL(author["avatarThumbnailUrl"].string)

                items.append(Comment(
                    id: cid,
                    author: author["displayName"].string ?? "",
                    avatar: avatarURL,
                    text: props["content"]["content"].string ?? "",
                    published: props["publishedTime"].string ?? "",
                    likes: toolbar["likeCountNotliked"].string ?? "",
                    isChannelOwner: isOwner,
                    isHeartedByCreator: isHearted,
                    isPinned: isPinned,
                    replyCount: replyCount,
                    repliesToken: repliesToken
                ))
            }
        }

        // 2. Fallback commentEntityPayload if no threads were matched directly
        if items.isEmpty {
            for (_, p) in j.collect(["commentEntityPayload"]) {
                let props = p["properties"]
                let toolbar = p["toolbar"]
                let author = p["author"]
                let stateKey = props["toolbarStateKey"].string
                let ts = stateKey.flatMap { toolbarStates[$0] }
                let isOwner = author["isCreator"].bool ?? false
                let isHearted = toolbar["heartState"].string == "CREATOR_HEART_STATE_HEARTED"
                    || ts?["heartState"].string == "CREATOR_HEART_STATE_HEARTED"
                let replyCount = toolbar["replyCount"].int ?? (Int(toolbar["replyCount"].string ?? "") ?? 0)
                let isPinned = !p["pinnedText"].isNull || props["isPinned"].bool == true

                items.append(Comment(
                    id: props["commentId"].string ?? UUID().uuidString,
                    author: author["displayName"].string ?? "",
                    avatar: YTParse.normalizeURL(author["avatarThumbnailUrl"].string),
                    text: props["content"]["content"].string ?? "",
                    published: props["publishedTime"].string ?? "",
                    likes: toolbar["likeCountNotliked"].string ?? "",
                    isChannelOwner: isOwner,
                    isHeartedByCreator: isHearted,
                    isPinned: isPinned,
                    replyCount: replyCount,
                    repliesToken: nil
                ))
            }
        }

        // 3. Fallback commentRenderer directly (replies continuation)
        if items.isEmpty {
            for (_, c) in j.collect(["commentRenderer"]) {
                let isOwner = c["authorIsChannelOwner"].bool ?? false
                let isHearted = !c["actionButtons"]["commentActionButtonsRenderer"]["creatorHeart"].isNull
                let isPinned = !c["pinnedCommentBadge"].isNull
                let replyCount = c["replyCount"].int ?? (Int(c["replyCount"].string ?? "") ?? 0)

                items.append(Comment(
                    id: c["commentId"].string ?? UUID().uuidString,
                    author: c["authorText"].text ?? "",
                    avatar: YTParse.thumb(c["authorThumbnail"]),
                    text: c["contentText"].text ?? "",
                    published: c["publishedTimeText"].text ?? "",
                    likes: c["voteCount"].text ?? "",
                    isChannelOwner: isOwner,
                    isHeartedByCreator: isHearted,
                    isPinned: isPinned,
                    replyCount: replyCount,
                    repliesToken: nil
                ))
            }
        }

        // Next-page continuation token
        var next: String?
        for e in j["onResponseReceivedEndpoints"].array {
            let reload = e["reloadContinuationItemsCommand"]["continuationItems"]
            let contItems = reload.isNull ? e["appendContinuationItemsAction"]["continuationItems"] : reload
            for item in contItems.array.reversed() {
                if !item["continuationItemRenderer"].isNull,
                   let t = item["continuationItemRenderer"].first("continuationCommand")?["token"].string {
                    next = t
                    break
                }
            }
        }
        return (items, next)
    }

    // MARK: - YouTube Music

    func musicHome() async throws -> Page {
        YTParse.musicPage(try await post("browse", client: .webRemix, body: ["browseId": "FEmusic_home"]))
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

    /// Recommends similar songs based on playlist seed tracks and query hint.
    func recommendedSongs(for seeds: [Video], queryHint: String? = nil, limit: Int = 15) async -> [Video] {
        var results: [Video] = []
        var seenIds = Set<String>(seeds.map(\.id))

        for seed in seeds.prefix(3) {
            if Task.isCancelled { return results }
            var seedId = seed.id
            if seed.id.hasPrefix("sp:") {
                if let yt = try? await TrackMatcher.shared.youTubeId(for: seed) {
                    seedId = yt
                } else {
                    continue
                }
            }
            if let radio = try? await musicRadio(seedId) {
                for track in radio {
                    if seenIds.insert(track.id).inserted {
                        results.append(track)
                        if results.count >= limit { return results }
                    }
                }
            }
        }

        if results.count < limit, !Task.isCancelled {
            let query: String
            if let hint = queryHint, !hint.isEmpty {
                query = hint
            } else if let first = seeds.first {
                query = "\(first.channelTitle) songs"
            } else {
                query = "top hits"
            }
            if let page = try? await musicSearch(query, continuation: nil) {
                for track in page.videos where seenIds.insert(track.id).inserted {
                    results.append(track)
                    if results.count >= limit { return results }
                }
            }
        }

        return results
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
            ],
            "cpn": Self.makeCPN(),
        ]
        if let s = startTimeSecs, s > 0 { body["startTimeSecs"] = s }
        return try await post("player", client: client, body: body)
    }

    private func tryPlayer(_ id: String, _ client: YTClient, startTimeSecs: Int? = nil) async throws -> (client: YTClient, json: J) {
        try Task.checkCancellation()
        return (client, try await player(id, client: client, startTimeSecs: startTimeSecs))
    }

    private func hasPlayableStreams(_ j: J) -> Bool {
        guard j["playabilityStatus"]["status"].string == "OK" else { return false }
        let sd = j["streamingData"]
        if sd["hlsManifestUrl"].string != nil { return true }
        return !sd["adaptiveFormats"].array.isEmpty || !sd["formats"].array.isEmpty
    }

    private func extractReason(_ responses: [J?]) -> String? {
        for r in responses {
            guard let r else { continue }
            let ps = r["playabilityStatus"]
            if let reason = ps["reason"].string, !reason.isEmpty { return reason }
            if let errReason = ps["errorScreen"]["playerErrorMessageRenderer"]["reason"].text, !errReason.isEmpty {
                return errReason
            }
            if let sub = ps["errorScreen"]["playerErrorMessageRenderer"]["subreason"].text, !sub.isEmpty {
                return sub
            }
        }
        return nil
    }

    /// Resolves playable streams with multi-client resilience, uniform codecs, and proxied byte-range HLS.
    func resolve(_ id: String, audioOnly: Bool, maxHeight: Int, startTimeSecs: Int? = nil) async throws -> ResolvedVideo {
        try Task.checkCancellation()
        HLSServer.shared.ensureRunning()

        async let iosAttempt: Result<(client: YTClient, json: J), Error> = {
            do { return .success(try await tryPlayer(id, .ios, startTimeSecs: startTimeSecs)) }
            catch { return .failure(error) }
        }()
        async let vrAttempt: Result<(client: YTClient, json: J), Error> = {
            do { return .success(try await tryPlayer(id, .androidVR, startTimeSecs: startTimeSecs)) }
            catch { return .failure(error) }
        }()

        let iosResult = await iosAttempt
        let vrResult = await vrAttempt
        try Task.checkCancellation()

        var iosJSON: J?
        var vrJSON: J?
        var tvJSON: J?
        var transportErrors: [Error] = []

        switch iosResult {
        case .success(let pair): iosJSON = pair.json
        case .failure(let err):
            if err is CancellationError { throw err }
            transportErrors.append(err)
        }
        switch vrResult {
        case .success(let pair): vrJSON = pair.json
        case .failure(let err):
            if err is CancellationError { throw err }
            transportErrors.append(err)
        }

        let usableIOS = iosJSON.flatMap { hasPlayableStreams($0) ? $0 : nil }
        let usableVR = vrJSON.flatMap { hasPlayableStreams($0) ? $0 : nil }
        var usableTV: J?

        if usableIOS == nil && usableVR == nil {
            if let tvPair = try? await tryPlayer(id, .tvEmbedded, startTimeSecs: startTimeSecs) {
                tvJSON = tvPair.json
                if hasPlayableStreams(tvPair.json) { usableTV = tvPair.json }
            }
            try Task.checkCancellation()
        }

        let orderedClients: [(YTClient, J)] = [
            usableVR.map { (.androidVR, $0) },
            usableIOS.map { (.ios, $0) },
            usableTV.map { (.tvEmbedded, $0) },
        ].compactMap { $0 }

        guard let primaryMeta = orderedClients.first?.1 else {
            if let reason = extractReason([iosJSON, vrJSON, tvJSON]) {
                throw YTError.unplayable(reason)
            }
            if let netErr = transportErrors.first {
                throw netErr
            }
            throw YTError.unplayable("Video không khả dụng")
        }

        let cap = maxHeight > 0 ? maxHeight : 2160
        let directCandidates: [(client: YTClient, json: J, set: DirectSet)] = orderedClients.map { pair in
            (pair.0, pair.1, YTParse.directFormats(pair.1, maxHeight: cap, client: pair.0))
        }

        // Pick coherent same-client stream pairs, preferring highest playable resolution up to cap (with H.264 priority <= 1080).
        let primaryCandidate = directCandidates.max { a, b in
            let aH = a.set.video?.shortEdge ?? 0
            let bH = b.set.video?.shortEdge ?? 0
            if aH != bH { return aH < bH }
            let aAVC = a.set.video?.mime.contains("avc1") ?? false
            let bAVC = b.set.video?.mime.contains("avc1") ?? false
            if aAVC != bAVC { return !aAVC && bAVC }
            return (a.set.audio?.bitrate ?? 0) < (b.set.audio?.bitrate ?? 0)
        } ?? directCandidates[0]

        let direct = primaryCandidate.set

        let isLive = orderedClients.contains { $0.1["videoDetails"]["isLive"].bool == true }
            || (orderedClients.contains { $0.1["videoDetails"]["isLiveContent"].bool == true }
                && direct.video?.indexRange == nil
                && orderedClients.contains { $0.1["streamingData"]["hlsManifestUrl"].string != nil })

        let hlsPairs: [(URL, YTClient)] = [usableIOS, usableVR, usableTV].enumerated().compactMap { idx, j in
            guard let str = j?["streamingData"]["hlsManifestUrl"].string, let u = URL(string: str) else { return nil }
            let c: YTClient = idx == 0 ? .ios : (idx == 1 ? .androidVR : .tvEmbedded)
            return (u, c)
        }

        var sources: [PlaybackSource] = []

        if isLive {
            sources = hlsPairs.map { PlaybackSource.hls($0.0, userAgent: $0.1.userAgent) }
            if !audioOnly, let v = direct.video, let a = direct.audio {
                if let liveMaster = await HLSBuilder.buildLiveMaster(id: id, video: v, audio: a) {
                    sources.append(.hls(liveMaster))
                }
            }
            for cand in directCandidates {
                if let a = cand.set.audio, let liveAudio = await HLSBuilder.buildLiveAudio(id: id, audio: a) {
                    sources.append(.hls(liveAudio))
                    break
                }
            }
        } else if audioOnly {
            for cand in directCandidates {
                if let a = cand.set.audio,
                   let audioHLS = await HLSBuilder.buildAudio(id: id, audio: a, startTimeSecs: startTimeSecs) {
                    sources.append(.hls(audioHLS))
                }
            }
            for cand in directCandidates {
                if let m = cand.set.muxed {
                    sources.append(.progressive(m.url, userAgent: m.effectiveUserAgent))
                    break
                }
            }
            sources += hlsPairs.map { PlaybackSource.hls($0.0, userAgent: $0.1.userAgent) }
        } else {
            // 1. Primary dynamic HLS (coherent codec ladder via local byte-range proxy)
            if let v = direct.video, let a = direct.audio {
                if let dynamicHLS = await HLSBuilder.buildMaster(
                    id: id,
                    video: v,
                    audio: a,
                    variants: direct.videoVariants,
                    startTimeSecs: startTimeSecs
                ) {
                    sources.append(.hls(dynamicHLS))
                }
            }

            // 2. If primary was > 1080p or non-H.264 (e.g. AV1), prepare a clean 1080p H.264 HLS fallback
            let primaryIsNonAVC = !(direct.video?.mime.contains("avc1") ?? true)
            let primaryAbove1080 = (direct.video?.shortEdge ?? 0) > 1080
            if primaryIsNonAVC || primaryAbove1080 {
                let fb = YTParse.directFormats(primaryCandidate.json, maxHeight: 1080, client: primaryCandidate.client)
                if let fv = fb.video, let fa = fb.audio ?? direct.audio, fv.mime.contains("avc1") {
                    if let hls1080 = await HLSBuilder.buildMaster(
                        id: id,
                        video: fv,
                        audio: fa,
                        variants: fb.videoVariants,
                        startTimeSecs: startTimeSecs
                    ) {
                        sources.append(.hls(hls1080))
                    }
                }
            }

            // 3. Official YouTube iOS HLS manifest if available (proven Apple AVPlayer fallback)
            sources += hlsPairs.map { PlaybackSource.hls($0.0, userAgent: $0.1.userAgent) }

            // 4. Secondary client dynamic HLS (failover if primary client gets 403/throttled mid-stream)
            for cand in directCandidates where cand.client != primaryCandidate.client {
                if let av = cand.set.video, let aa = cand.set.audio {
                    if let altHLS = await HLSBuilder.buildMaster(
                        id: id,
                        video: av,
                        audio: aa,
                        variants: cand.set.videoVariants,
                        startTimeSecs: startTimeSecs
                    ) {
                        sources.append(.hls(altHLS))
                    }
                }
            }

            // 5. Muxed MP4 progressive stream fallback (itag 18/22 etc.)
            for cand in directCandidates {
                if let m = cand.set.muxed {
                    sources.append(.progressive(m.url, userAgent: m.effectiveUserAgent))
                }
            }

            // 6. Audio-only HLS emergency fallback
            if let a = direct.audio,
               let audioHLS = await HLSBuilder.buildAudio(id: id, audio: a, startTimeSecs: startTimeSecs) {
                sources.append(.hls(audioHLS))
            }
        }

        guard !sources.isEmpty else { throw YTError.noStreams }

        let details = YTParse.details(primaryMeta, id: id)
        var info = details.1
        info.isLive = isLive
        info.storyboard = orderedClients.compactMap { $0.1["storyboards"]["playerStoryboardSpecRenderer"]["spec"].string }.first
        let rawCaptions = orderedClients.compactMap { $0.1["captions"]["playerCaptionsTracklistRenderer"]["captionTracks"].array }.first { !$0.isEmpty } ?? []
        info.captions = rawCaptions.compactMap { ct in
            guard let base = ct["baseUrl"].string,
                  var comps = URLComponents(string: base) else { return nil }
            var items = comps.queryItems ?? []
            items.removeAll { $0.name == "fmt" }
            items.append(URLQueryItem(name: "fmt", value: "vtt"))
            comps.queryItems = items
            guard let url = comps.url else { return nil }
            let name = ct["name"].text ?? ct["languageCode"].string ?? ""
            let lang = ct["languageCode"].string ?? ""
            return CaptionTrack(name: name, languageCode: lang, url: url)
        }

        let expiryDates = [direct.video?.expiresAt, direct.audio?.expiresAt, direct.muxed?.expiresAt].compactMap { $0 }
        let expiresAt = expiryDates.min()
        return ResolvedVideo(video: details.0, info: info, sources: sources, expiresAt: expiresAt)
    }

    func fetchCaptions(from url: URL) async -> [CaptionCue] {
        var req = URLRequest(url: url)
        req.setValue(YTClient.ios.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8) else { return [] }
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
                        let stripped = lines[i].replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                        let clean = unescapeHTML(stripped).trimmingCharacters(in: .whitespaces)
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

    private static func unescapeHTML(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
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
        async let iosAttempt = try? tryPlayer(id, .ios)
        async let vrAttempt = try? tryPlayer(id, .androidVR)
        let ios = await iosAttempt
        let vr = await vrAttempt

        var pairs = [vr, ios].compactMap { $0 }.filter { hasPlayableStreams($0.json) }
        if pairs.isEmpty, let tv = try? await tryPlayer(id, .tvEmbedded), hasPlayableStreams(tv.json) {
            pairs = [tv]
        }

        guard let meta = pairs.first?.json else {
            if let reason = extractReason([ios?.json, vr?.json]) {
                throw YTError.unplayable(reason)
            }
            throw YTError.unplayable("Video không khả dụng")
        }

        let candidates = pairs.map { YTParse.directFormats($0.json, maxHeight: Pref.maxHeight, client: $0.client) }
        let best = candidates.max { a, b in
            (a.video?.shortEdge ?? 0, a.video?.mime.contains("avc1") ?? false ? 1 : 0, a.audio?.bitrate ?? 0)
                < (b.video?.shortEdge ?? 0, b.video?.mime.contains("avc1") ?? false ? 1 : 0, b.audio?.bitrate ?? 0)
        } ?? DirectSet()
        return (YTParse.details(meta, id: id).0, best)
    }
}

// MARK: - Parsing

enum YTParse {
    private static let itemKeys: Set<String> = [
        "videoRenderer", "compactVideoRenderer", "gridVideoRenderer", "playlistVideoRenderer",
        "reelItemRenderer", "shortsLockupViewModel",
        "lockupViewModel", "channelRenderer", "continuationItemRenderer", "playlistRenderer", "gridPlaylistRenderer"
    ]

    static func normalizeURL(_ raw: String?) -> URL? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if s.hasPrefix("//") { s = "https:" + s }
        return URL(string: s)
    }

    static func channelHeader(_ j: J, id: String) -> Channel {
        let meta = j["metadata"]["channelMetadataRenderer"]
        var subs = j["header"]["c4TabbedHeaderRenderer"]["subscriberCountText"].text
        if subs == nil {
            let vm = j["header"]["pageHeaderRenderer"]["content"]["pageHeaderViewModel"]
            let rows = vm["metadata"]["contentMetadataViewModel"]["metadataRows"].array
            for row in rows {
                for part in row["metadataParts"].array {
                    if let t = part["text"]["content"].string,
                       t.localizedCaseInsensitiveContains("sub") || t.localizedCaseInsensitiveContains("đăng ký") {
                        subs = t
                        break
                    }
                }
                if subs != nil { break }
            }
        }
        return Channel(
            id: id,
            title: meta["title"].string ?? "",
            avatar: thumb(meta["avatar"]),
            subscribers: subs
        )
    }

    static func page(_ j: J) -> Page {
        var page = Page()
        var seenVideos = Set<String>()
        var seenChannels = Set<String>()
        var seenPlaylists = Set<String>()
        for (key, value) in j.collect(itemKeys) {
            switch key {
            case "channelRenderer":
                if let c = channel(value), seenChannels.insert(c.id).inserted { page.channels.append(c) }
            case "continuationItemRenderer":
                if let t = value.first("continuationCommand")?["token"].string { page.continuation = t }
            case "playlistRenderer", "gridPlaylistRenderer":
                if let p = playlist(value), seenPlaylists.insert(p.id).inserted { page.playlists.append(p) }
            case "lockupViewModel":
                if let v = lockup(value), seenVideos.insert(v.id).inserted {
                    page.videos.append(v)
                } else if let p = lockupPlaylist(value), seenPlaylists.insert(p.id).inserted {
                    page.playlists.append(p)
                }
            case "shortsLockupViewModel":
                if let v = shortsLockup(value), seenVideos.insert(v.id).inserted { page.videos.append(v) }
            case "reelItemRenderer":
                if let v = reelItem(value), seenVideos.insert(v.id).inserted { page.videos.append(v) }
            default:
                if let v = video(value), seenVideos.insert(v.id).inserted { page.videos.append(v) }
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
        let art = thumb(r["thumbnail"])
        return Video(
            id: id,
            title: r["title"].text ?? "",
            channelTitle: run?["text"].string ?? "",
            channelId: run?["navigationEndpoint"]["browseEndpoint"]["browseId"].string,
            duration: duration,
            views: r["shortViewCountText"].text ?? r["viewCountText"].text,
            published: r["publishedTimeText"].text,
            artwork: art
        )
    }

    static func reelItem(_ r: J) -> Video? {
        guard let id = r["videoId"].string ?? r["navigationEndpoint"]["reelWatchEndpoint"]["videoId"].string else { return nil }
        return Video(
            id: id,
            title: r["headline"].text ?? "",
            channelTitle: "",
            views: r["viewCountText"].text,
            artwork: thumb(r["thumbnail"])
        )
    }

    static func shortsLockup(_ s: J) -> Video? {
        guard let id = s["onTap"]["innertubeCommand"]["reelWatchEndpoint"]["videoId"].string
                ?? s["entityId"].string?.components(separatedBy: "-").last else { return nil }
        let acc = s["accessibilityText"].string ?? ""
        let title = s["overlayMetadata"]["primaryText"]["content"].string ?? acc
        let views = s["overlayMetadata"]["secondaryText"]["content"].string
        let art = thumb(s["thumbnail"]) ?? thumb(s["thumbnailViewModel"])
        return Video(id: id, title: title, channelTitle: "", views: views, artwork: art)
    }

    static func lockup(_ l: J) -> Video? {
        guard let id = l["contentId"].string, l["contentType"].string == "LOCKUP_CONTENT_TYPE_VIDEO" else { return nil }
        let meta = l["metadata"]["lockupMetadataViewModel"]
        let rows = meta["metadata"]["contentMetadataViewModel"]["metadataRows"].array.map { row in
            row["metadataParts"].array.compactMap { $0["text"]["content"].string }
        }.filter { !$0.isEmpty }
        let channelTitle = rows.count > 1 ? (rows[0].first ?? "") : ""
        let stats = rows.count > 1 ? rows[1] : (rows.first ?? [])
        let channelId = l.collect(["browseId"]).compactMap { $0.value.string }.first { $0.hasPrefix("UC") }
        let art = thumb(l["contentImage"])
        var duration: String?
        for (_, badge) in l["contentImage"].collect(["thumbnailBadgeViewModel"]) {
            if let t = badge["text"].string, Fmt.seconds(t) != nil {
                duration = t
                break
            }
        }
        return Video(
            id: id,
            title: meta["title"]["content"].string ?? "",
            channelTitle: channelTitle,
            channelId: channelId,
            duration: duration,
            views: stats.first,
            published: stats.count > 1 ? stats[1] : nil,
            artwork: art
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
        let count = r["videoCountText"].text ?? r["videoCountShortText"].text ?? r["videoCount"].text ?? r["videoCount"].string
        let artwork = thumb(r["thumbnail"]) ?? r["thumbnails"].array.compactMap { thumb($0) }.first
        return ChannelPlaylist(
            id: id,
            title: r["title"].text ?? "",
            thumbnail: artwork,
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
        let cols = r["flexColumns"].array.map { $0["musicResponsiveListItemFlexColumnRenderer"]["text"] }
        let titleWatchId = cols.first?["runs"][0]["navigationEndpoint"]["watchEndpoint"]["videoId"].string
        let directWatchId = r["navigationEndpoint"]["watchEndpoint"]["videoId"].string
        guard let id = r["playlistItemData"]["videoId"].string
                ?? directWatchId
                ?? titleWatchId
                ?? r["overlay"].first("watchEndpoint")?["videoId"].string
                ?? r.first("watchEndpoint")?["videoId"].string else { return nil }
        let runs = cols.count > 1 ? cols[1]["runs"].array : []
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
        let subRuns = r["subtitle"]["runs"].array
        let artistRun = subRuns.first { run in
            run["navigationEndpoint"]["browseEndpoint"]["browseId"].string != nil
        }
        let artistParts = subRuns.compactMap { $0["text"].string?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "•" && $0 != "Song" && $0 != "Video" }
        return Video(
            id: id,
            title: r["title"].text ?? "",
            channelTitle: artistRun?["text"].string ?? artistParts.first ?? r["subtitle"].text ?? "",
            channelId: artistRun?["navigationEndpoint"]["browseEndpoint"]["browseId"].string,
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
        if let url = normalizeURL(t["thumbnails"].array.last?["url"].string) {
            return url
        }
        if let url = normalizeURL(t["thumbnailViewModel"]["image"]["sources"].array.last?["url"].string) {
            return url
        }
        if let url = normalizeURL(t["collectionThumbnailViewModel"]["primaryThumbnail"]["thumbnailViewModel"]["image"]["sources"].array.last?["url"].string) {
            return url
        }
        if let url = normalizeURL(t["image"]["sources"].array.last?["url"].string) {
            return url
        }
        return nil
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

    static func directFormats(_ j: J, maxHeight: Int, client: YTClient? = nil) -> DirectSet {
        let sd = j["streamingData"]
        let streamExpiresIn = sd["expiresInSeconds"].double ?? sd["expiresInSeconds"].int.map(Double.init)

        func parseExpiry(url: URL) -> Date? {
            if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let expStr = comps.queryItems?.first(where: { $0.name == "expire" })?.value,
               let ts = Double(expStr), ts > 0 {
                return Date(timeIntervalSince1970: ts)
            }
            if let s = streamExpiresIn, s > 0 {
                return Date().addingTimeInterval(s)
            }
            return nil
        }

        func format(_ f: J) -> DirectFormat? {
            guard let s = f["url"].string, let url = URL(string: s) else { return nil }
            let ir = f["initRange"]
            let initR = ir["start"].string.flatMap { st in ir["end"].string.flatMap { en in Int(st).flatMap { si in Int(en).map { (si, $0) } } } }
            let xr = f["indexRange"]
            let indexR = xr["start"].string.flatMap { st in xr["end"].string.flatMap { en in Int(st).flatMap { si in Int(en).map { (si, $0) } } } }
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
                indexRange: indexR,
                itag: f["itag"].int,
                approxDurationMs: f["approxDurationMs"].double,
                expiresAt: parseExpiry(url: url),
                client: client,
                isDrc: f["isDrc"].bool ?? false
            )
        }

        let adaptive = sd["adaptiveFormats"].array.compactMap(format)
        let cap = maxHeight > 0 ? maxHeight : 2160
        let allowAV1 = cap > 1080 && InnerTube.supportsHardwareAV1

        // Never pick VP9 in MP4 (unsupported by AVPlayer); restrict to AVC1 or hardware-supported AV1.
        let mp4Videos = adaptive.filter {
            guard $0.mime.hasPrefix("video/mp4"), $0.shortEdge <= cap else { return false }
            if $0.mime.contains("avc1") { return true }
            if allowAV1 && $0.mime.contains("av01") { return true }
            return false
        }

        let video: DirectFormat? = {
            if allowAV1 {
                // Only choose AV1 >1080p if it genuinely beats 1080p; otherwise stick to reliable H.264.
                let av1High = mp4Videos.filter { $0.mime.contains("av01") && $0.shortEdge > 1080 }
                if let bestHigh = av1High.max(by: { ($0.shortEdge, $0.fps ?? 30, $0.bitrate) < ($1.shortEdge, $1.fps ?? 30, $1.bitrate) }) {
                    return bestHigh
                }
            }
            let avc = mp4Videos.filter { $0.mime.contains("avc1") }
            return (avc.isEmpty ? mp4Videos : avc).max {
                ($0.shortEdge, $0.fps ?? 30, $0.bitrate) < ($1.shortEdge, $1.fps ?? 30, $1.bitrate)
            }
        }()

        // Strictly require AAC (mp4a) in MP4 so Dolby ec-3/ac-3/opus/iamf never break AVPlayer;
        // prefer non-DRC default track, falling back cleanly if all tracks are non-default.
        let aacAll = adaptive.filter { $0.mime.hasPrefix("audio/mp4") && $0.mime.contains("mp4a") }
        let aacDefault = aacAll.filter { $0.isDefaultAudio }
        let aacPool = aacDefault.isEmpty ? aacAll : aacDefault
        let aacNonDrc = aacPool.filter { !$0.isDrc }
        let audio = (aacNonDrc.isEmpty ? aacPool : aacNonDrc).max { $0.bitrate < $1.bitrate }

        let muxedCandidates = sd["formats"].array.compactMap(format).filter {
            $0.mime.hasPrefix("video/mp4") && $0.shortEdge <= cap
        }
        let muxed = (muxedCandidates.isEmpty ? sd["formats"].array.compactMap(format) : muxedCandidates)
            .max { ($0.shortEdge, $0.bitrate) < ($1.shortEdge, $1.bitrate) }

        // Keep ABR variants within the same codec family as `video` (computed against shortEdge for vertical/ultrawide).
        let targetFamilyAVC = video?.mime.contains("avc1") ?? true
        let familyVideos = mp4Videos.filter { targetFamilyAVC ? $0.mime.contains("avc1") : $0.mime.contains("av01") }
        let heightTiers: [Int] = [2160, 1440, 1080, 720, 480, 360, 240]
        var variants: [DirectFormat] = []
        for tier in heightTiers where tier <= cap {
            let matching = familyVideos.filter { $0.shortEdge == tier }
            if let bestInTier = matching.max(by: { ($0.fps ?? 30, $0.bitrate) < ($1.fps ?? 30, $1.bitrate) }) {
                variants.append(bestInTier)
            }
        }

        return DirectSet(video: video, audio: audio, muxed: muxed, videoVariants: variants)
    }
}
