import Foundation
import UIKit
import MediaPlayer
#if canImport(SpotifyiOS)
import SpotifyiOS
#endif

/// Controls direct high-quality audio playback via the official Spotify iOS app using the Spotify App Remote SDK.
@MainActor
final class SpotifyRemote: NSObject, ObservableObject {
    static let shared = SpotifyRemote()

    @Published private(set) var isConnected = false
    @Published private(set) var isConnecting = false
    @Published private(set) var currentTrackURI: String?
    @Published private(set) var trackTitle: String = ""
    @Published private(set) var artistTitle: String = ""
    @Published private(set) var albumTitle: String = ""
    @Published private(set) var duration: Double = 0
    @Published private(set) var position: Double = 0
    @Published private(set) var isPaused: Bool = true
    @Published private(set) var lastError: String?

    /// User preference to use direct Spotify App Remote when playing Spotify tracks (default: true).
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "spotifyAppRemoteEnabled") }
    }

    private let redirectURI = URL(string: SpotifyAuth.redirectURI)!
    private var pendingURI: String?
    private var progressTask: Task<Void, Never>?
    private var lastStateTimestamp: Date = Date()
    private var basePosition: Double = 0

    #if canImport(SpotifyiOS)
    private var appRemote: SPTAppRemote?
    private var configuration: SPTConfiguration?
    #endif

    override private init() {
        if UserDefaults.standard.object(forKey: "spotifyAppRemoteEnabled") == nil {
            isEnabled = true
        } else {
            isEnabled = UserDefaults.standard.bool(forKey: "spotifyAppRemoteEnabled")
        }
        super.init()
        #if canImport(SpotifyiOS)
        setupAppRemote()
        #endif
    }

    /// Checks if the official Spotify app is installed on the user's iOS device.
    var isSpotifyInstalled: Bool {
        guard let url = URL(string: "spotify:") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    /// Can Spotify App Remote be used for direct audio streaming right now?
    var isAvailable: Bool {
        isEnabled && isSpotifyInstalled
    }

    #if canImport(SpotifyiOS)
    private func setupAppRemote() {
        let clientId = SpotifyAuth.shared.clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientId.isEmpty else { return }
        let config = SPTConfiguration(clientID: clientId, redirectURL: redirectURI)
        config.playURI = ""
        configuration = config
        let remote = SPTAppRemote(configuration: config, logLevel: .none)
        remote.delegate = self
        appRemote = remote
    }

    private func ensureConfigured() -> Bool {
        let clientId = SpotifyAuth.shared.clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientId.isEmpty else {
            lastError = "Hãy nhập Spotify Client ID trong cài đặt Spotify"
            return false
        }
        if appRemote == nil || configuration?.clientID != clientId {
            setupAppRemote()
        }
        return appRemote != nil
    }
    #endif

    /// Requests Spotify App Remote to play a track URI directly.
    /// Returns true if playback was initiated via Spotify, false if fallback is required.
    func play(trackId: String, video: Video) async -> Bool {
        guard isAvailable else { return false }
        let rawId = trackId.hasPrefix("sp:") ? String(trackId.dropFirst(3)) : trackId
        let uri = "spotify:track:\(rawId)"
        pendingURI = uri

        #if canImport(SpotifyiOS)
        guard ensureConfigured(), let remote = appRemote else { return false }

        // If already connected, play directly
        if remote.isConnected {
            return await withCheckedContinuation { cont in
                remote.playerAPI?.play(uri) { [weak self] _, error in
                    if let error {
                        self?.lastError = error.localizedDescription
                        cont.resume(returning: false)
                    } else {
                        self?.currentTrackURI = uri
                        self?.trackTitle = video.title
                        self?.artistTitle = video.channelTitle
                        self?.duration = Fmt.seconds(video.duration) ?? 0
                        self?.isPaused = false
                        self?.basePosition = 0
                        self?.lastStateTimestamp = Date()
                        self?.startProgressTimer()
                        cont.resume(returning: true)
                    }
                }
            }
        }

        // Try connecting with existing OAuth access token first
        isConnecting = true
        if let token = try? await SpotifyAuth.shared.validToken() {
            remote.connectionParameters.accessToken = token
            remote.connect()

            // Wait up to 1.5s for handshake
            for _ in 0..<15 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if remote.isConnected { break }
            }

            if remote.isConnected {
                isConnecting = false
                return await withCheckedContinuation { cont in
                    remote.playerAPI?.play(uri) { [weak self] _, error in
                        if let error {
                            self?.lastError = error.localizedDescription
                            cont.resume(returning: false)
                        } else {
                            self?.currentTrackURI = uri
                            self?.trackTitle = video.title
                            self?.artistTitle = video.channelTitle
                            self?.duration = Fmt.seconds(video.duration) ?? 0
                            self?.isPaused = false
                            cont.resume(returning: true)
                        }
                    }
                }
            }
        }

        // If direct connect failed, wake up Spotify app via authorizeAndPlayURI
        return await withCheckedContinuation { cont in
            remote.authorizeAndPlayURI(uri) { [weak self] success in
                self?.isConnecting = false
                if success {
                    self?.currentTrackURI = uri
                    self?.trackTitle = video.title
                    self?.artistTitle = video.channelTitle
                    self?.duration = Fmt.seconds(video.duration) ?? 0
                    self?.isPaused = false
                    cont.resume(returning: true)
                } else {
                    self?.lastError = "Không thể mở ứng dụng Spotify"
                    cont.resume(returning: false)
                }
            }
        }
        #else
        return false
        #endif
    }

    func pause() {
        stopProgressTimer()
        #if canImport(SpotifyiOS)
        appRemote?.playerAPI?.pause { [weak self] _, error in
            if error == nil { self?.isPaused = true }
        }
        #endif
    }

    func resume() {
        basePosition = position
        lastStateTimestamp = Date()
        startProgressTimer()
        #if canImport(SpotifyiOS)
        appRemote?.playerAPI?.resume { [weak self] _, error in
            if error == nil { self?.isPaused = false }
        }
        #endif
    }

    func togglePlay() {
        if isPaused { resume() } else { pause() }
    }

    func seek(to seconds: Double) {
        basePosition = seconds
        lastStateTimestamp = Date()
        position = seconds
        #if canImport(SpotifyiOS)
        let ms = Int(seconds * 1000)
        appRemote?.playerAPI?.seek(toPosition: ms, callback: nil)
        #endif
    }

    func next() {
        #if canImport(SpotifyiOS)
        appRemote?.playerAPI?.skip(toNext: nil)
        #endif
    }

    func previous() {
        #if canImport(SpotifyiOS)
        appRemote?.playerAPI?.skip(toPrevious: nil)
        #endif
    }

    func stopProgressTimer() {
        progressTask?.cancel()
        progressTask = nil
    }

    func startProgressTimer() {
        stopProgressTimer()
        lastStateTimestamp = Date()
        basePosition = position
        progressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, !self.isPaused else { break }
                let elapsed = Date().timeIntervalSince(self.lastStateTimestamp)
                let currentPos = self.basePosition + elapsed
                let capped = self.duration > 0 ? min(currentPos, self.duration) : currentPos
                self.position = capped
                PlayerManager.shared.syncFromSpotifyRemote(
                    isPaused: self.isPaused,
                    position: capped,
                    duration: self.duration,
                    title: self.trackTitle,
                    artist: self.artistTitle,
                    uri: self.currentTrackURI
                )
            }
        }
    }

    /// Handles incoming deep links (vidra://spotify-callback) when returning from Spotify.
    func handleURL(_ url: URL) {
        #if canImport(SpotifyiOS)
        guard let remote = appRemote else { return }
        let params = remote.authorizationParameters(from: url)
        if let token = params?[SPTAppRemoteAccessTokenKey] {
            remote.connectionParameters.accessToken = token
            remote.connect()
        } else if let error = params?[SPTAppRemoteErrorDescriptionKey] {
            lastError = error
        }
        #endif
    }
}

#if canImport(SpotifyiOS)
extension SpotifyRemote: SPTAppRemoteDelegate {
    nonisolated func appRemoteDidEstablishConnection(_ appRemote: SPTAppRemote) {
        Task { @MainActor in
            self.isConnected = true
            self.isConnecting = false
            self.lastError = nil
            appRemote.playerAPI?.delegate = self
            appRemote.playerAPI?.subscribe(toPlayerState: { _, error in
                if let error {
                    print("Vidra Spotify Remote subscribe error: \(error.localizedDescription)")
                }
            })
            if let pending = self.pendingURI {
                self.pendingURI = nil
                appRemote.playerAPI?.play(pending, callback: nil)
            }
        }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didFailConnectionAttemptWithError error: Error?) {
        Task { @MainActor in
            self.isConnected = false
            self.isConnecting = false
            self.lastError = error?.localizedDescription
        }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didDisconnectWithError error: Error?) {
        Task { @MainActor in
            self.stopProgressTimer()
            self.isConnected = false
            self.isConnecting = false
            self.lastError = error?.localizedDescription
        }
    }
}

extension SpotifyRemote: SPTAppRemotePlayerStateDelegate {
    nonisolated func playerStateDidChange(_ playerState: SPTAppRemotePlayerState) {
        Task { @MainActor in
            self.isPaused = playerState.isPaused
            self.basePosition = Double(playerState.playbackPosition) / 1000.0
            self.position = self.basePosition
            self.lastStateTimestamp = Date()
            self.duration = Double(playerState.track.duration) / 1000.0
            self.trackTitle = playerState.track.name
            self.artistTitle = playerState.track.artist.name
            self.albumTitle = playerState.track.album.name
            self.currentTrackURI = playerState.track.uri

            if !playerState.isPaused {
                self.startProgressTimer()
            } else {
                self.stopProgressTimer()
            }

            // Synchronize with Vidra's PlayerManager
            PlayerManager.shared.syncFromSpotifyRemote(
                isPaused: playerState.isPaused,
                position: self.position,
                duration: self.duration,
                title: playerState.track.name,
                artist: playerState.track.artist.name,
                uri: playerState.track.uri
            )
        }
    }
}
#endif
