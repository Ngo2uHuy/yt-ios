import AVFoundation
import AVKit
import MediaPlayer
import UIKit

@MainActor
final class PlayerManager: NSObject, ObservableObject {
    static let shared = PlayerManager()

    let player = AVPlayer()

    @Published private(set) var current: Video?
    @Published private(set) var info: VideoInfo?
    @Published private(set) var related: [Video] = []
    @Published private(set) var commentsToken: String?
    @Published var queue: [Video] = []
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var errorText: String?
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var rate: Float
    @Published private(set) var audioOnly: Bool
    @Published private(set) var sleepAt: Date?
    @Published private(set) var toast: String?
    @Published private(set) var chapters: [Chapter] = []
    @Published private(set) var boosting = false
    private(set) var storyboard: Storyboard?
    @Published var stopAfterCurrent = false
    @Published var loop = false
    @Published var showWatch = false

    weak var pipController: AVPictureInPictureController?

    /// Audio-only playback shows cover art instead of a (black) video layer.
    var showsArtwork: Bool {
        guard let source = current?.source else { return audioOnly }
        return audioOnly || source == .soundCloud || Pref.musicAudioOnly
    }

    private var sources: [PlaybackSource] = []
    private var sourceIndex = 0
    private var segments: [SponsorSegment] = []
    private var backStack: [Video] = []
    private var pendingSeek: Double?
    private var lastSaved: Double = 0
    private var artwork: MPMediaItemArtwork?
    private var loadTask: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var itemObservation: NSKeyValueObservation?
    private var statusObservation: NSKeyValueObservation?

    private override init() {
        rate = Float(Pref.defaultRate)
        audioOnly = UserDefaults.standard.bool(forKey: Pref.audioOnlyKey)
        super.init()
        player.defaultRate = rate
        player.allowsExternalPlayback = true
        // Keep video items playing when the app is backgrounded or the screen is locked.
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        observePlayer()
        setupRemoteCommands()
    }

    // MARK: - Public controls

    func play(_ video: Video, queue newQueue: [Video]? = nil) {
        if let newQueue { queue = newQueue }
        showWatch = true
        if current?.id == video.id, player.currentItem != nil {
            player.play()
            return
        }
        if let c = current {
            savePosition()
            pushBack(c)
        }
        start(video)
    }

    func playNext(_ video: Video) {
        if current == nil { play(video) } else { queue.insert(video, at: 0) }
    }

    func togglePlay() {
        if isPlaying {
            player.pause()
        } else if player.currentItem == nil, let v = current {
            start(v)
        } else {
            player.play()
        }
    }

    func seek(to seconds: Double) {
        let target = max(0, duration > 0 ? min(seconds, duration - 0.5) : seconds)
        currentTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { [weak self] _ in
            Task { @MainActor in self?.updateNowPlaying() }
        }
    }

    func seek(by delta: Double) { seek(to: currentTime + delta) }

    func setRate(_ r: Float) {
        rate = r
        player.defaultRate = r
        if isPlaying { player.rate = r }
        updateNowPlaying()
    }

    /// Press-and-hold fast playback; doesn't touch the user's chosen speed.
    func setBoost(_ on: Bool) {
        guard on != boosting, player.currentItem != nil else { return }
        boosting = on
        if on {
            player.rate = 2
        } else if player.timeControlStatus != .paused {
            player.rate = rate
        }
    }

    func next(auto: Bool = false) {
        guard let c = current else { return }
        var candidate: Video?
        if !queue.isEmpty {
            candidate = queue.removeFirst()
        } else if !auto || Pref.autoplay {
            let seen = Set(backStack.map(\.id) + [c.id])
            candidate = related.first { !seen.contains($0.id) }
        }
        guard let v = candidate else { return }
        savePosition()
        pushBack(c)
        start(v)
    }

    func previous() {
        guard currentTime <= 5, let v = backStack.popLast() else {
            seek(to: 0)
            return
        }
        if let c = current {
            savePosition()
            queue.insert(c, at: 0)
        }
        start(v)
    }

    func toggleAudioOnly() {
        audioOnly.toggle()
        UserDefaults.standard.set(audioOnly, forKey: Pref.audioOnlyKey)
        reload()
    }

    func qualityChanged() {
        guard current != nil, sourceIndex < sources.count else { return }
        switch sources[sourceIndex] {
        case .hls:
            if let item = player.currentItem { applyQuality(to: item) }
        case .file:
            break
        default:
            if !audioOnly { reload() }
        }
    }

    func retry() { reload() }

    func togglePiP() {
        guard let pip = pipController else { return }
        if pip.isPictureInPictureActive { pip.stopPictureInPicture() } else { pip.startPictureInPicture() }
    }

    func setSleep(_ minutes: Int?) {
        sleepTask?.cancel()
        sleepAt = nil
        guard let minutes else { return }
        sleepAt = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60_000_000_000)
            guard !Task.isCancelled else { return }
            player.pause()
            sleepAt = nil
        }
    }

    func close() {
        savePosition()
        loadTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        current = nil
        showWatch = false
        queue = []
        setSleep(nil)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func savePosition() {
        guard let v = current, currentTime > 0 else { return }
        lastSaved = currentTime
        let nearEnd = duration > 0 && currentTime > duration - 15
        Library.shared.setPosition(v.id, nearEnd ? nil : currentTime)
    }

    // MARK: - Loading

    private func pushBack(_ v: Video) {
        backStack.append(v)
        if backStack.count > 200 { backStack.removeFirst() }
    }

    private func reload() {
        guard let v = current else { return }
        savePosition()
        start(v)
    }

    private func start(_ video: Video) {
        loadTask?.cancel()
        current = video
        info = nil
        chapters = []
        storyboard = nil
        boosting = false
        related = []
        commentsToken = nil
        segments = []
        errorText = nil
        isLoading = true
        currentTime = 0
        duration = 0
        lastSaved = 0
        artwork = nil
        sources = []
        sourceIndex = 0
        player.replaceCurrentItem(with: nil)
        try? AVAudioSession.sharedInstance().setActive(true)
        updateNowPlaying()
        loadArtwork(for: video)

        let resume = Library.shared.position(video.id)
        pendingSeek = resume > 5 ? resume : nil
        let wantsAudioOnly = self.audioOnly || (video.source != nil && Pref.musicAudioOnly)

        loadTask = Task {
            if let file = DownloadManager.shared.localFile(for: video.id) {
                sources = [.file(file)]
                Library.shared.addHistory(video)
            } else {
                do {
                    var r: ResolvedVideo
                    switch video.source {
                    case .soundCloud?:
                        r = try await SoundCloud.shared.resolve(video.id)
                    case .spotify?:
                        let ytId = try await TrackMatcher.shared.youTubeId(for: video)
                        r = try await InnerTube.shared.resolve(ytId, audioOnly: wantsAudioOnly, maxHeight: Pref.maxHeight)
                        r.video = video // keep Spotify id and metadata
                    default:
                        r = try await InnerTube.shared.resolve(video.id, audioOnly: wantsAudioOnly, maxHeight: Pref.maxHeight)
                    }
                    guard !Task.isCancelled else { return }
                    var v = r.video
                    if v.title.isEmpty { v.title = video.title }
                    v.published = video.published ?? v.published
                    v.source = video.source
                    v.artwork = video.artwork ?? v.artwork
                    v.link = video.link ?? v.link
                    current = v
                    info = r.info
                    chapters = Chapter.parse(r.info.description)
                    storyboard = r.info.storyboard.flatMap { Storyboard(spec: $0) }
                    sources = r.sources
                    Library.shared.addHistory(v)
                    updateNowPlaying()
                } catch {
                    guard !Task.isCancelled else { return }
                    errorText = error.localizedDescription
                    isLoading = false
                    return
                }
            }
            await loadCurrentSource()
        }

        Task {
            var upNext: [Video] = []
            var token: String?
            switch video.source {
            case .soundCloud?:
                upNext = await SoundCloud.shared.related(video.id)
            case .ytMusic?:
                upNext = (try? await InnerTube.shared.musicRadio(video.id)) ?? []
            case .spotify?:
                if let yt = try? await TrackMatcher.shared.youTubeId(for: video) {
                    upNext = (try? await InnerTube.shared.musicRadio(yt)) ?? []
                }
            case nil:
                guard let n = try? await InnerTube.shared.next(video.id) else { return }
                upNext = n.related
                token = n.commentsToken
            }
            guard current?.id == video.id else { return }
            related = upNext
            commentsToken = token
        }
        if Pref.sponsorBlock, video.source == nil || video.source == .ytMusic {
            Task {
                let s = await Extras.segments(video.id)
                if current?.id == video.id { segments = s }
            }
        }
    }

    private func loadCurrentSource() async {
        let id = current?.id
        while sourceIndex < sources.count {
            let item = try? await makeItem(sources[sourceIndex])
            // The user may have switched videos while a composite was loading.
            if Task.isCancelled || current?.id != id { return }
            if let item {
                attach(item)
                return
            }
            sourceIndex += 1
        }
        errorText = "Không phát được video này"
        isLoading = false
    }

    private func makeItem(_ source: PlaybackSource) async throws -> AVPlayerItem {
        switch source {
        case .hls(let url):
            // HLS comes from the iOS client, whose own player is AVPlayer — keep the default user agent.
            let item = AVPlayerItem(url: url)
            applyQuality(to: item)
            return item
        case .progressive(let url), .file(let url):
            return AVPlayerItem(asset: Media.asset(url))
        case .composite(let v, let a):
            return AVPlayerItem(asset: try await Media.composition(video: Media.asset(v), audio: Media.asset(a)))
        }
    }

    private func attach(_ item: AVPlayerItem) {
        itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            Task { @MainActor in self?.itemStatusChanged(item, status) }
        }
        player.replaceCurrentItem(with: item)
        player.play()
    }

    private func itemStatusChanged(_ item: AVPlayerItem, _ status: AVPlayerItem.Status) {
        guard item === player.currentItem else { return }
        switch status {
        case .readyToPlay:
            if let s = pendingSeek {
                pendingSeek = nil
                seek(to: s)
            }
        case .failed:
            // Try the next stream variant from where we were.
            if currentTime > 0 { pendingSeek = currentTime }
            sourceIndex += 1
            loadTask?.cancel()
            loadTask = Task { await loadCurrentSource() }
        default:
            break
        }
    }

    private func applyQuality(to item: AVPlayerItem) {
        let h = Double(Pref.maxHeight)
        item.preferredMaximumResolution = h > 0 ? CGSize(width: h * 16 / 9, height: h) : .zero
    }

    // MARK: - Observers

    private func observePlayer() {
        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.syncPlayState() }
        }
        player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in self?.tick(time.seconds) }
        }

        let nc = NotificationCenter.default
        nc.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            let item = note.object as AnyObject?
            Task { @MainActor in
                guard let self, item === self.player.currentItem else { return }
                self.itemEnded()
            }
        }
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: typeRaw) == .ended,
                  let optRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
                  AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume) else { return }
            Task { @MainActor in self?.player.play() }
        }
    }

    private func syncPlayState() {
        switch player.timeControlStatus {
        case .playing: isLoading = false
        case .waitingToPlayAtSpecifiedRate: isLoading = true
        default: if player.currentItem != nil { isLoading = false }
        }
        let playing = player.timeControlStatus != .paused
        if playing != isPlaying {
            isPlaying = playing
            updateNowPlaying()
        }
    }

    private func tick(_ t: Double) {
        guard t.isFinite, current != nil, player.currentItem != nil else { return }
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0, d != duration {
            duration = d
            updateNowPlaying()
        }
        currentTime = t
        if Pref.sponsorBlock, let seg = segments.first(where: { t >= $0.start && t < $0.end - 1 }) {
            seek(to: seg.end)
            showToast("Đã bỏ qua: \(seg.label)")
        }
        if abs(t - lastSaved) >= 5 { savePosition() }
    }

    private func itemEnded() {
        if loop {
            seek(to: 0)
            player.play()
            return
        }
        if let v = current { Library.shared.setPosition(v.id, nil) }
        if stopAfterCurrent {
            stopAfterCurrent = false
            return
        }
        next(auto: true)
    }

    private func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if !Task.isCancelled { toast = nil }
        }
    }

    // MARK: - Lock screen / Control Center

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.player.play() }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.player.pause() }
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlay() }
            return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let t = e.positionTime
            Task { @MainActor in self?.seek(to: t) }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let v = current else { return }
        var np: [String: Any] = [
            MPMediaItemPropertyTitle: v.title,
            MPMediaItemPropertyArtist: v.channelTitle,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(rate),
        ]
        if duration > 0 { np[MPMediaItemPropertyPlaybackDuration] = duration }
        if let artwork { np[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = np
    }

    private func loadArtwork(for v: Video) {
        guard let url = v.thumbnail else { return }
        Task {
            guard let res = try? await URLSession.shared.data(from: url), let img = UIImage(data: res.0),
                  current?.id == v.id else { return }
            artwork = Self.makeArtwork(img)
            updateNowPlaying()
        }
    }

    // nonisolated: MediaPlayer calls the handler off the main thread.
    private nonisolated static func makeArtwork(_ img: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: img.size) { _ in img }
    }
}
