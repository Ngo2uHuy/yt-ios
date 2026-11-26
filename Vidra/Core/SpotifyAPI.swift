import AuthenticationServices
import AVFoundation
import CryptoKit
import Foundation
import Security
import UIKit

// MARK: - Errors

enum SpotifyError: LocalizedError {
    case notLoggedIn
    case http(Int, String?)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Phiên đăng nhập Spotify đã hết hạn, hãy đăng nhập lại"
        case .http(let code, let detail):
            switch code {
            case 403:
                return "Spotify từ chối truy cập (403). Nếu app đang ở Development Mode, hãy thêm email tài khoản vào User Management trên dashboard."
            case 404:
                return "Không tải được nội dung này (404). Spotify chặn một số nội dung với ứng dụng mới."
            case 429:
                return "Spotify đang giới hạn tốc độ, hãy thử lại sau ít phút"
            default:
                return "Lỗi Spotify (HTTP \(code))" + (detail.map { ": \($0)" } ?? "")
            }
        case .message(let m):
            return m
        }
    }
}

// MARK: - Keychain

private enum SpotifyKeychain {
    private static let service = "vidra.spotify"
    private static let account = "refresh_token"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String) {
        delete()
        var query = baseQuery
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

@MainActor
private final class SpotifyAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        return windows.first(where: { $0.isKeyWindow }) ?? windows.first ?? ASPresentationAnchor()
    }
}

// MARK: - Auth (Authorization Code + PKCE)

@MainActor
final class SpotifyAuth: ObservableObject {
    static let shared = SpotifyAuth()

    struct Profile {
        let name: String
        let image: URL?
    }

    static let redirectURI = "vidra://spotify-callback"
    private static let scopes = "user-library-read playlist-read-private playlist-read-collaborative user-follow-read user-top-read user-read-recently-played user-read-private app-remote-control streaming user-read-playback-state user-modify-playback-state"
    private static let clientIdKey = "spotifyClientId"

    @Published var clientId: String {
        didSet { UserDefaults.standard.set(clientId, forKey: Self.clientIdKey) }
    }
    @Published private(set) var isLoggedIn: Bool
    @Published private(set) var profile: Profile?
    @Published private(set) var isWorking = false
    @Published var error: String?

    private var accessToken: String?
    private var expiry = Date.distantPast
    private var refreshTask: Task<String, Error>?
    private var authGeneration: UInt64 = 0
    private var session: ASWebAuthenticationSession?
    private let anchor = SpotifyAnchor()

    private init() {
        clientId = UserDefaults.standard.string(forKey: Self.clientIdKey) ?? ""
        isLoggedIn = SpotifyKeychain.read() != nil
    }

    private var trimmedClientId: String { clientId.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: Login / logout

    func login() async {
        let id = trimmedClientId
        guard !id.isEmpty else {
            error = "Hãy nhập Client ID trước"
            return
        }
        guard !isWorking else { return }
        isWorking = true
        error = nil
        let loginGen = authGeneration
        defer { isWorking = false }

        let verifier = Self.makeVerifier()
        let state = Self.makeVerifier()
        var comps = URLComponents(string: "https://accounts.spotify.com/authorize")!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: id),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: Self.challenge(for: verifier)),
        ]
        guard let authURL = comps.url else { return }

        do {
            let callback: URL = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { cont in
                    let s = ASWebAuthenticationSession(url: authURL, callbackURLScheme: "vidra") { url, err in
                        if let url {
                            cont.resume(returning: url)
                        } else {
                            cont.resume(throwing: err ?? SpotifyError.message("Đăng nhập không thành công"))
                        }
                    }
                    s.presentationContextProvider = anchor
                    session = s
                    if !s.start() {
                        session = nil
                        cont.resume(throwing: SpotifyError.message("Không mở được trang đăng nhập Spotify"))
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.session?.cancel()
                    self?.session = nil
                }
            }
            session = nil
            guard authGeneration == loginGen else { return }

            let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
            if let err = value("error") {
                throw SpotifyError.message(err == "access_denied" ? "Bạn đã từ chối cấp quyền" : "Spotify báo lỗi: \(err)")
            }
            guard value("state") == state, let code = value("code") else {
                throw SpotifyError.message("Phản hồi đăng nhập không hợp lệ")
            }
            let token = try await tokenRequest([
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": Self.redirectURI,
                "client_id": id,
                "code_verifier": verifier,
            ])
            guard authGeneration == loginGen, !Task.isCancelled else { return }
            store(token)
            isLoggedIn = true
            profile = nil
        } catch {
            session = nil
            if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin { return }
            if error is CancellationError { return }
            self.error = error.localizedDescription
        }
    }

    func logout() {
        authGeneration &+= 1
        SpotifyKeychain.delete()
        accessToken = nil
        expiry = .distantPast
        refreshTask?.cancel()
        refreshTask = nil
        session?.cancel()
        session = nil
        profile = nil
        isLoggedIn = false
        Task { await SpotifyAPI.shared.clearCaches() }
    }

    // MARK: Tokens

    func validToken() async throws -> String {
        if let t = accessToken, Date() < expiry.addingTimeInterval(-30) { return t }
        return try await refresh()
    }

    /// Drops the cached access token ONLY if it still matches `failedToken`, preventing stampedes on concurrent 401s.
    func invalidateToken(ifMatching failedToken: String? = nil) {
        if let failedToken, accessToken != failedToken { return }
        accessToken = nil
        expiry = .distantPast
    }

    private func refresh() async throws -> String {
        if let task = refreshTask { return try await task.value }
        let gen = authGeneration
        var createdTask: Task<String, Error>?
        let task = Task {
            try await self.doRefresh(generation: gen)
        }
        createdTask = task
        refreshTask = task
        defer {
            if refreshTask == createdTask { refreshTask = nil }
        }
        return try await task.value
    }

    private func doRefresh(generation: UInt64) async throws -> String {
        guard let refreshToken = SpotifyKeychain.read(), !trimmedClientId.isEmpty else {
            logout()
            throw SpotifyError.notLoggedIn
        }
        do {
            let token = try await tokenRequest([
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "client_id": trimmedClientId,
            ])
            guard generation == authGeneration else { throw SpotifyError.notLoggedIn }
            store(token)
            return token.access
        } catch SpotifyError.notLoggedIn {
            if generation == authGeneration { logout() }
            throw SpotifyError.notLoggedIn
        }
    }

    private struct TokenResponse {
        let access: String
        let refresh: String?
        let expiresIn: Double
    }

    private func store(_ t: TokenResponse) {
        accessToken = t.access
        expiry = Date().addingTimeInterval(t.expiresIn)
        if let r = t.refresh { SpotifyKeychain.write(r) }
    }

    private func tokenRequest(_ params: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(Self.formEncode(params).utf8)

        for attempt in 0..<2 {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let http = resp as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            if code == 429 && attempt == 0 {
                let wait = min(max(Double(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 1, 1), 15)
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                continue
            }
            let j = J(data: data)
            guard (200..<300).contains(code), let access = j["access_token"].string else {
                if j["error"].string == "invalid_grant" { throw SpotifyError.notLoggedIn }
                let detail = j["error_description"].string ?? j["error"].string ?? "HTTP \(code)"
                throw SpotifyError.message("Không lấy được token Spotify: \(detail)")
            }
            return TokenResponse(access: access,
                                 refresh: j["refresh_token"].string,
                                 expiresIn: Double(j["expires_in"].int ?? 3600))
        }
        throw SpotifyError.http(429, nil)
    }

    func loadProfile() async {
        guard isLoggedIn, profile == nil else { return }
        let gen = authGeneration
        guard let j = try? await SpotifyAPI.shared.me(),
              isLoggedIn, gen == authGeneration else { return }
        profile = Profile(name: j["display_name"].string ?? j["id"].string ?? "Spotify",
                          image: SpotifyMap.image(j["images"]))
    }

    // MARK: PKCE helpers

    private static func makeVerifier() -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var g = SystemRandomNumberGenerator()
        return String((0..<64).map { _ in chars.randomElement(using: &g) ?? "a" })
    }

    private static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncode(_ params: [String: String]) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return params.map { k, v in
            let key = k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k
            let val = v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v
            return "\(key)=\(val)"
        }.joined(separator: "&")
    }
}

// MARK: - Models

enum SpotifyKind: Hashable {
    case playlist, album, artist
}

/// Playlist / album / artist tile; `id` is the raw Spotify id (no prefix).
struct SpotifyCard: Identifiable, Hashable, Sendable {
    let id: String
    let kind: SpotifyKind
    let title: String
    let subtitle: String
    let image: URL?
}

struct SpotifyListing: Sendable {
    var cards: [SpotifyCard] = []
    var next: String?
}

struct SpotifySearchResult: Sendable {
    var tracks: [Video] = []
    var artists: [SpotifyCard] = []
    var albums: [SpotifyCard] = []
    var playlists: [SpotifyCard] = []
    var isEmpty: Bool { tracks.isEmpty && artists.isEmpty && albums.isEmpty && playlists.isEmpty }
}

struct SpotifyArtistInfo: Sendable {
    var name: String
    var image: URL?
    var followers: Int?
}

// MARK: - JSON mapping

enum SpotifyMap {
    static func image(_ images: J) -> URL? {
        guard let s = images.array.first?["url"].string else { return nil }
        return URL(string: s)
    }

    static func next(_ page: J, offset: Int, count: Int) -> String? {
        guard count > 0, !page["next"].isNull else { return nil }
        return String(offset + count)
    }

    /// `album` is a fallback for track objects that carry no album (e.g. `albums/{id}/tracks`).
    static func track(_ t: J, album fallback: J = J(nil)) -> Video? {
        guard let id = t["id"].string, !id.isEmpty, t["is_local"].bool != true else { return nil }
        if let type = t["type"].string, type != "track" { return nil }
        let album = t["album"].isNull ? fallback : t["album"]
        let artists = t["artists"].array
        let names = artists.compactMap { $0["name"].string }.joined(separator: ", ")
        var channelId: String?
        if let aid = artists.first?["id"].string { channelId = "spa:\(aid)" }
        var duration: String?
        if let ms = t["duration_ms"].int { duration = Fmt.time(Double(ms) / 1000) }
        return Video(id: "sp:\(id)",
                     title: t["name"].string ?? "",
                     channelTitle: names,
                     channelId: channelId,
                     duration: duration,
                     views: nil,
                     published: album["name"].string,
                     source: .spotify,
                     artwork: image(album["images"]),
                     link: URL(string: "https://open.spotify.com/track/\(id)"))
    }

    static func playlistCard(_ p: J) -> SpotifyCard? {
        guard let id = p["id"].string else { return nil }
        var parts: [String] = []
        if let owner = p["owner"]["display_name"].string { parts.append(owner) }
        if let total = p["tracks"]["total"].int ?? p["items"]["total"].int { parts.append("\(total) bài") }
        return SpotifyCard(id: id, kind: .playlist, title: p["name"].string ?? "Playlist",
                           subtitle: parts.joined(separator: " • "), image: image(p["images"]))
    }

    static func albumCard(_ a: J) -> SpotifyCard? {
        guard let id = a["id"].string else { return nil }
        var parts: [String] = []
        if let date = a["release_date"].string, date.count >= 4 { parts.append(String(date.prefix(4))) }
        let names = a["artists"].array.compactMap { $0["name"].string }.joined(separator: ", ")
        if !names.isEmpty { parts.append(names) }
        return SpotifyCard(id: id, kind: .album, title: a["name"].string ?? "Album",
                           subtitle: parts.joined(separator: " • "), image: image(a["images"]))
    }

    static func artistCard(_ a: J) -> SpotifyCard? {
        guard let id = a["id"].string else { return nil }
        return SpotifyCard(id: id, kind: .artist, title: a["name"].string ?? "Nghệ sĩ",
                           subtitle: "Nghệ sĩ", image: image(a["images"]))
    }
}

// MARK: - Spotify Connect Device Categories & Models

enum SpotifyDeviceCategory: String, Sendable, CaseIterable {
    case computer = "Computer"
    case speaker = "Speaker"
    case tv = "TV"
    case smartphone = "Smartphone"
    case tablet = "Tablet"
    case cast = "Cast"
    case airplay = "AirPlay"
    case other = "Other"

    var localizedTitle: String {
        switch self {
        case .computer: return "Máy tính (PC/Mac)"
        case .speaker: return "Loa không dây"
        case .tv: return "Smart TV"
        case .smartphone: return "Điện thoại"
        case .tablet: return "Máy tính bảng"
        case .cast: return "Google Cast"
        case .airplay: return "AirPlay"
        case .other: return "Thiết bị khác"
        }
    }
}

struct SpotifyDevice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let type: String
    var isActive: Bool
    let isPrivateSession: Bool
    let isRestricted: Bool
    let volumePercent: Int?
    var protocolType: String
    var isLocal: Bool

    init(
        id: String,
        name: String,
        type: String,
        isActive: Bool,
        isPrivateSession: Bool = false,
        isRestricted: Bool = false,
        volumePercent: Int? = nil,
        protocolType: String = "Spotify Connect",
        isLocal: Bool = false
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.isActive = isActive
        self.isPrivateSession = isPrivateSession
        self.isRestricted = isRestricted
        self.volumePercent = volumePercent
        self.protocolType = protocolType
        self.isLocal = isLocal
    }

    var category: SpotifyDeviceCategory {
        let t = type.lowercased()
        if t.contains("computer") || t.contains("pc") || t.contains("mac") {
            return .computer
        } else if t.contains("tv") || t.contains("television") || t.contains("avr") || t.contains("stb") {
            return .tv
        } else if t.contains("speaker") || t.contains("audio") || t.contains("homepod") || t.contains("sonos") || t.contains("soundbar") {
            return .speaker
        } else if t.contains("tablet") || t.contains("ipad") {
            return .tablet
        } else if t.contains("smartphone") || t.contains("phone") || t.contains("mobile") {
            return .smartphone
        } else if t.contains("cast") {
            return .cast
        } else {
            return .other
        }
    }

    var iconName: String {
        switch category {
        case .computer: return "laptopcomputer"
        case .tv: return "tv.fill"
        case .speaker:
            if name.lowercased().contains("homepod") { return "homepod.fill" }
            return "hifispeaker.2.fill"
        case .smartphone: return "iphone"
        case .tablet: return "ipad"
        case .cast: return "airplayvideo"
        case .airplay, .other: return "hifispeaker.fill"
        }
    }

    var protocolIcon: String {
        let p = protocolType.lowercased()
        if p.contains("airplay") {
            return "airplayaudio"
        } else if p.contains("bluetooth") {
            return "wave.3.forward"
        } else if p.contains("cast") {
            return "airplayvideo"
        } else {
            return "wifi"
        }
    }
}

// MARK: - API

actor SpotifyAPI {
    static let shared = SpotifyAPI()

    private let base = "https://api.spotify.com/v1/"
    private var albumCache: [String: J] = [:]
    private var albumCacheOrder: [String] = []
    private var rateLimitedUntil: Date?

    func clearCaches() {
        albumCache.removeAll()
        albumCacheOrder.removeAll()
        rateLimitedUntil = nil
    }

    func get(_ path: String, _ query: [String: String] = [:]) async throws -> J {
        try await request(method: "GET", path: path, query: query, body: nil)
    }

    func put(_ path: String, query: [String: String] = [:], body: [String: Any]? = nil) async throws -> J {
        try await request(method: "PUT", path: path, query: query, body: body)
    }

    func post(_ path: String, query: [String: String] = [:], body: [String: Any]? = nil) async throws -> J {
        try await request(method: "POST", path: path, query: query, body: body)
    }

    private func request(method: String, path: String, query: [String: String] = [:], body: [String: Any]? = nil) async throws -> J {
        guard let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              var comps = URLComponents(string: base + encodedPath) else {
            throw URLError(.badURL)
        }
        if !query.isEmpty {
            comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else { throw URLError(.badURL) }

        var retriedAuth = false
        var retriedRate = false
        while true {
            try Task.checkCancellation()
            if let until = rateLimitedUntil {
                let wait = until.timeIntervalSinceNow
                if wait > 0 {
                    try await Task.sleep(nanoseconds: UInt64(min(wait, 30) * 1_000_000_000))
                }
            }
            let token = try await SpotifyAuth.shared.validToken()
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let body {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            let (data, resp) = try await URLSession.shared.data(for: req)
            let http = resp as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            if code == 401, !retriedAuth {
                retriedAuth = true
                await SpotifyAuth.shared.invalidateToken(ifMatching: token)
                continue
            }
            if code == 429, !retriedRate {
                retriedRate = true
                let wait = Double(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 2
                if wait > 30 { throw SpotifyError.http(429, nil) }
                let clamped = max(wait, 1)
                rateLimitedUntil = Date().addingTimeInterval(clamped)
                try await Task.sleep(nanoseconds: UInt64(clamped * 1_000_000_000))
                continue
            }
            if code == 204 { return J(nil) }
            let json = J(data: data)
            guard (200..<300).contains(code) else {
                if code == 401 { throw SpotifyError.notLoggedIn }
                throw SpotifyError.http(code, json["error"]["message"].string)
            }
            return json
        }
    }

    // MARK: - Playback Control (Spotify Connect Web API)

    func getDevices() async throws -> [SpotifyDevice] {
        let j = try await get("me/player/devices")
        return j["devices"].array.compactMap { d in
            guard let id = d["id"].string, !id.isEmpty else { return nil }
            return SpotifyDevice(
                id: id,
                name: d["name"].string ?? "Thiết bị Spotify",
                type: d["type"].string ?? "Smartphone",
                isActive: d["is_active"].bool ?? false,
                isPrivateSession: d["is_private_session"].bool ?? false,
                isRestricted: d["is_restricted"].bool ?? false,
                volumePercent: d["volume_percent"].int,
                protocolType: "Spotify Connect",
                isLocal: false
            )
        }
    }

    func setVolume(percent: Int, deviceId: String? = nil) async throws {
        var q = ["volume_percent": String(min(max(percent, 0), 100))]
        if let deviceId { q["device_id"] = deviceId }
        _ = try await put("me/player/volume", query: q)
    }

    func transferPlayback(to deviceId: String, play: Bool = true) async throws {
        let body: [String: Any] = [
            "device_ids": [deviceId],
            "play": play
        ]
        _ = try await put("me/player", body: body)
    }

    func playTrack(uri: String, deviceId: String? = nil) async throws {
        let body: [String: Any] = ["uris": [uri]]
        let query = deviceId.map { ["device_id": $0] } ?? [:]
        do {
            _ = try await put("me/player/play", query: query, body: body)
        } catch let SpotifyError.http(code, _) where code == 404 {
            if let devices = try? await getDevices(), let first = devices.first {
                try await transferPlayback(to: first.id, play: true)
                try? await Task.sleep(nanoseconds: 250_000_000)
                _ = try await put("me/player/play", query: ["device_id": first.id], body: body)
            } else {
                throw SpotifyError.message("Không tìm thấy thiết bị Spotify đang mở.")
            }
        }
    }

    func pause() async throws {
        _ = try await put("me/player/pause")
    }

    func resume() async throws {
        _ = try await put("me/player/play")
    }

    func pausePlayback() async throws {
        try await pause()
    }

    func resumePlayback() async throws {
        try await resume()
    }

    func seekPlayback(positionMs: Int) async throws {
        try await seek(positionMs: max(0, positionMs))
    }

    func next() async throws {
        _ = try await post("me/player/next")
    }

    func previous() async throws {
        _ = try await post("me/player/previous")
    }

    func seek(positionMs: Int) async throws {
        _ = try await put("me/player/seek", query: ["position_ms": String(max(0, positionMs))])
    }

    func currentPlaybackState() async throws -> (isPlaying: Bool, progressMs: Int, durationMs: Int, trackId: String?)? {
        let j = try await get("me/player")
        guard !j.isNull else { return nil }
        return (
            isPlaying: j["is_playing"].bool ?? false,
            progressMs: j["progress_ms"].int ?? 0,
            durationMs: j["item"]["duration_ms"].int ?? 0,
            trackId: j["item"]["id"].string
        )
    }

    private func paging(_ offset: Int, limit: Int = 50) -> [String: String] {
        ["limit": String(limit), "offset": String(offset)]
    }

    // MARK: Profile

    func me() async throws -> J {
        try await get("me")
    }

    // MARK: Tracks

    func likedSongs(offset: Int = 0) async throws -> Page {
        let j = try await get("me/tracks", paging(offset))
        let items = j["items"].array
        return Page(videos: items.compactMap { SpotifyMap.track($0["track"]) },
                    continuation: SpotifyMap.next(j, offset: offset, count: items.count))
    }

    func topTracks(offset: Int = 0) async throws -> Page {
        var q = paging(offset)
        q["time_range"] = "short_term"
        let j = try await get("me/top/tracks", q)
        let items = j["items"].array
        return Page(videos: items.compactMap { SpotifyMap.track($0) },
                    continuation: SpotifyMap.next(j, offset: offset, count: items.count))
    }

    func recentlyPlayed() async throws -> [Video] {
        let j = try await get("me/player/recently-played", ["limit": "50"])
        var seen = Set<String>()
        return j["items"].array.compactMap { SpotifyMap.track($0["track"]) }.filter { seen.insert($0.id).inserted }
    }

    // MARK: Playlists

    func playlistInfo(id: String) async throws -> J {
        try await get("playlists/\(id)")
    }

    func myPlaylists(offset: Int = 0) async throws -> SpotifyListing {
        let j = try await get("me/playlists", paging(offset))
        let items = j["items"].array
        return SpotifyListing(cards: items.compactMap { SpotifyMap.playlistCard($0) },
                              next: SpotifyMap.next(j, offset: offset, count: items.count))
    }

    func playlistTracks(id: String, offset: Int = 0) async throws -> Page {
        let q = paging(offset)
        let j: J
        do {
            j = try await get("playlists/\(id)/tracks", q)
        } catch SpotifyError.http(let code, _) where code == 404 {
            j = try await get("playlists/\(id)/items", q)
        }
        let items = j["items"].array
        let videos = items.compactMap { item -> Video? in
            let t = item["track"].isNull ? item["item"] : item["track"]
            return SpotifyMap.track(t)
        }
        return Page(videos: videos, continuation: SpotifyMap.next(j, offset: offset, count: items.count))
    }

    // MARK: Albums

    func savedAlbums(offset: Int = 0) async throws -> SpotifyListing {
        let j = try await get("me/albums", paging(offset))
        let items = j["items"].array
        return SpotifyListing(cards: items.compactMap { SpotifyMap.albumCard($0["album"]) },
                              next: SpotifyMap.next(j, offset: offset, count: items.count))
    }

    func newReleases(offset: Int = 0) async throws -> SpotifyListing {
        let j = try await get("browse/new-releases", paging(offset, limit: 20))
        let items = j["albums"]["items"].array
        return SpotifyListing(cards: items.compactMap { SpotifyMap.albumCard($0) },
                              next: SpotifyMap.next(j["albums"], offset: offset, count: items.count))
    }

    func albumDetails(id: String) async throws -> J {
        try await albumInfo(id: id)
    }

    private func albumInfo(id: String) async throws -> J {
        if let cached = albumCache[id] { return cached }
        let j = try await get("albums/\(id)")
        while albumCacheOrder.count >= 100 {
            let old = albumCacheOrder.removeFirst()
            albumCache.removeValue(forKey: old)
        }
        albumCacheOrder.append(id)
        albumCache[id] = j
        return j
    }

    func albumTracks(id: String, offset: Int = 0) async throws -> Page {
        let album = try await albumInfo(id: id)
        let j = try await get("albums/\(id)/tracks", paging(offset))
        let items = j["items"].array
        return Page(videos: items.compactMap { SpotifyMap.track($0, album: album) },
                    continuation: SpotifyMap.next(j, offset: offset, count: items.count))
    }

    // MARK: Artists

    func followedArtists(after: String? = nil) async throws -> SpotifyListing {
        var q = ["type": "artist", "limit": "50"]
        if let after { q["after"] = after }
        let j = try await get("me/following", q)
        let artists = j["artists"]
        return SpotifyListing(cards: artists["items"].array.compactMap { SpotifyMap.artistCard($0) },
                              next: artists["cursors"]["after"].string)
    }

    func artistInfo(id: String) async throws -> SpotifyArtistInfo {
        let j = try await get("artists/\(id)")
        return SpotifyArtistInfo(name: j["name"].string ?? "",
                                 image: SpotifyMap.image(j["images"]),
                                 followers: j["followers"]["total"].int)
    }

    func artistTopTracks(id: String) async throws -> [Video] {
        let j = try await get("artists/\(id)/top-tracks", ["market": "from_token"])
        return j["tracks"].array.compactMap { SpotifyMap.track($0) }
    }

    func artistAlbums(id: String, offset: Int = 0) async throws -> SpotifyListing {
        var q = paging(offset)
        q["include_groups"] = "album,single"
        let j = try await get("artists/\(id)/albums", q)
        let items = j["items"].array
        return SpotifyListing(cards: items.compactMap { SpotifyMap.albumCard($0) },
                              next: SpotifyMap.next(j, offset: offset, count: items.count))
    }

    // MARK: Search

    func search(_ text: String) async throws -> SpotifySearchResult {
        let j = try await get("search", ["q": text, "type": "track,artist,album,playlist", "limit": "10"])
        return SpotifySearchResult(
            tracks: j["tracks"]["items"].array.compactMap { SpotifyMap.track($0) },
            artists: j["artists"]["items"].array.compactMap { SpotifyMap.artistCard($0) },
            albums: j["albums"]["items"].array.compactMap { SpotifyMap.albumCard($0) },
            playlists: j["playlists"]["items"].array.compactMap { SpotifyMap.playlistCard($0) })
    }
}

// MARK: - Spotify Connect Manager

@MainActor
final class SpotifyConnectManager: ObservableObject {
    static let shared = SpotifyConnectManager()

    @Published private(set) var devices: [SpotifyDevice] = []
    @Published private(set) var activeDevice: SpotifyDevice?
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var transferringDeviceId: String? = nil
    @Published var lastError: String? = nil

    private var pollTimer: Task<Void, Never>?

    private init() {
        setupInitialDevice()
    }

    private func setupInitialDevice() {
        let currentRoute = AVAudioSession.sharedInstance().currentRoute
        let outputPort = currentRoute.outputs.first
        let isAirPlay = outputPort?.portType == .airPlay
        let isBluetooth = outputPort?.portType == .bluetoothA2DP || outputPort?.portType == .bluetoothHFP || outputPort?.portType == .bluetoothLE

        let protoName: String
        let devType: String
        let devName: String

        if isAirPlay {
            protoName = "AirPlay"
            devType = "Speaker"
            devName = outputPort?.portName ?? "AirPlay Speaker"
        } else if isBluetooth {
            protoName = "Bluetooth"
            devType = "Speaker"
            devName = outputPort?.portName ?? "Bluetooth Device"
        } else {
            protoName = "Thiết bị này"
            devType = "Smartphone"
            devName = UIDevice.current.name
        }

        let defaultDev = SpotifyDevice(
            id: "this_device",
            name: devName,
            type: devType,
            isActive: true,
            volumePercent: nil,
            protocolType: protoName,
            isLocal: true
        )
        self.activeDevice = defaultDev
        self.devices = [defaultDev]
    }

    func refreshDevices() async {
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        let currentRoute = AVAudioSession.sharedInstance().currentRoute
        let outputPort = currentRoute.outputs.first
        let isAirPlay = outputPort?.portType == .airPlay
        let isBluetooth = outputPort?.portType == .bluetoothA2DP || outputPort?.portType == .bluetoothHFP || outputPort?.portType == .bluetoothLE

        let localName = isAirPlay ? (outputPort?.portName ?? "AirPlay") : (isBluetooth ? (outputPort?.portName ?? "Bluetooth") : UIDevice.current.name)
        let localProto = isAirPlay ? "AirPlay" : (isBluetooth ? "Bluetooth" : "Thiết bị này")

        var remoteDevices: [SpotifyDevice] = []
        if SpotifyAuth.shared.isLoggedIn {
            do {
                remoteDevices = try await SpotifyAPI.shared.getDevices()
            } catch {
                lastError = error.localizedDescription
            }
        }

        let isRemoteActive = remoteDevices.contains { $0.isActive }
        let thisDevice = SpotifyDevice(
            id: "this_device",
            name: localName,
            type: (isAirPlay || isBluetooth) ? "Speaker" : "Smartphone",
            isActive: !isRemoteActive,
            volumePercent: nil,
            protocolType: localProto,
            isLocal: true
        )

        var result: [SpotifyDevice] = [thisDevice]
        result.append(contentsOf: remoteDevices)

        if let currentActiveRemote = remoteDevices.first(where: { $0.isActive }) {
            self.activeDevice = currentActiveRemote
        } else {
            self.activeDevice = thisDevice
        }
        self.devices = result
    }

    func selectDevice(_ device: SpotifyDevice) async {
        transferringDeviceId = device.id
        lastError = nil

        let previousDevices = devices
        let previousActive = activeDevice

        let updated = devices.map { d -> SpotifyDevice in
            var copy = d
            copy.isActive = (d.id == device.id)
            return copy
        }
        var target = device
        target.isActive = true
        self.activeDevice = target
        self.devices = updated

        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()

        if !device.isLocal && SpotifyAuth.shared.isLoggedIn {
            do {
                try await SpotifyAPI.shared.transferPlayback(to: device.id, play: true)
            } catch {
                self.activeDevice = previousActive
                self.devices = previousDevices
                self.lastError = error.localizedDescription
            }
        }

        try? await Task.sleep(nanoseconds: 250_000_000)
        transferringDeviceId = nil
    }

    func startPolling() {
        pollTimer?.cancel()
        pollTimer = Task {
            while !Task.isCancelled {
                await refreshDevices()
                try? await Task.sleep(nanoseconds: 8_000_000_000)
            }
        }
    }

    func stopPolling() {
        pollTimer?.cancel()
        pollTimer = nil
    }
}
