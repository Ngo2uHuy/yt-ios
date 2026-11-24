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
    @Published private(set) var captionTracks: [CaptionTrack] = []
    @Published private(set) var selectedCaption: CaptionTrack?
    @Published private(set) var activeCueText: String?
    private(set) var storyboard: Storyboard?
    @Published var stopAfterCurrent = false
    @Published var loop = false
    @Published var showWatch = false

    weak var pipController: AVPictureInPictureController?

    /// Audio-only playback shows cover art instead of a (black) video layer.
    var showsArtwork: Bool {
        guard current?.source != nil else { return audioOnly }
        return audioOnly || Pref.musicAudioOnly
    }

    private var sources: [PlaybackSource] = []
    private var sourceIndex = 0
    private var segments: [SponsorSegment] = []
    private var backStack: [Video] = []
    private var pendingSeek: Double?
    private var lastSaved: Double = 0
    private var artwork: MPMediaItemArtwork?
    private var captionCues: [CaptionCue] = []
    private var captionTask: Task<Void, Never>?

    private struct PreloadData {
        let video: Video
        let item: AVPlayerItem
        let info: VideoInfo
        let sources: [PlaybackSource]
    }
    private var preloadedNext: PreloadData?
    private var preloadTask: Task<Void, Never>?

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

    func play(_ video: Video, queue newQueue: [Video]? = nil, showWatchSheet: Bool = true) {
        if let newQueue { queue = newQueue }
        if showWatchSheet {
            showWatch = true
        }
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

    private var seekTask: Task<Void, Never>?

    func seek(to seconds: Double) {
        let target = max(0, duration > 0 ? min(seconds, duration - 0.5) : seconds)
        let oldTime = currentTime
        currentTime = target

        // If live stream, seek directly in AVPlayer
        if info?.isLive == true {
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { [weak self] _ in
                Task { @MainActor in self?.updateNowPlaying() }
            }
            return
        }

        // If local downloaded file, seek directly in AVPlayer
        if case .file? = (sources.indices.contains(sourceIndex) ? sources[sourceIndex] : nil) {
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { [weak self] _ in
                Task { @MainActor in self?.updateNowPlaying() }
            }
            return
        }

        // Check if target is already inside the loaded time ranges of AVPlayer
        if let ranges = player.currentItem?.loadedTimeRanges {
            let targetCM = CMTime(seconds: target, preferredTimescale: 600)
            for value in ranges {
                let range = value.timeRangeValue
                if CMTimeRangeContainsTime(range, time: targetCM) {
                    player.seek(to: targetCM,
                                toleranceBefore: CMTime(seconds: 1, preferredTimescale: 600),
                                toleranceAfter: CMTime(seconds: 1, preferredTimescale: 600)) { [weak self] _ in
                        Task { @MainActor in self?.updateNowPlaying() }
                    }
                    return
                }
            }
        }

        // For nearby seeks (-60s backward to +45s forward), seek directly in AVPlayer for zero-latency response
        let delta = target - oldTime
        if (delta >= -60 && delta <= 45) && target >= 0 {
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                        toleranceBefore: CMTime(seconds: 1, preferredTimescale: 600),
                        toleranceAfter: CMTime(seconds: 1, preferredTimescale: 600)) { [weak self] finished in
                Task { @MainActor in
                    if finished {
                        self?.player.play()
                        self?.updateNowPlaying()
                    }
                }
            }
            return
        }

        // For major seeks (to the middle/end) in YouTube HLS streams:
        seekWithReload(target: target)
    }

    private func seekWithReload(target: Double) {
        guard let v = current else { return }
        seekTask?.cancel()
        isLoading = true
        pendingSeek = target

        let wantsAudioOnly = self.audioOnly || (v.source != nil && Pref.musicAudioOnly)
        let sec = Int(target)

        seekTask = Task { @MainActor in
            do {
                var r: ResolvedVideo
                if v.source == .spotify {
                    let ytId = try await TrackMatcher.shared.youTubeId(for: v)
                    r = try await InnerTube.shared.resolve(ytId, audioOnly: wantsAudioOnly, maxHeight: Pref.maxHeight, startTimeSecs: sec)
                    r.video = v
                } else {
                    r = try await InnerTube.shared.resolve(v.id, audioOnly: wantsAudioOnly, maxHeight: Pref.maxHeight, startTimeSecs: sec)
                }
                guard !Task.isCancelled else { return }

                self.sources = r.sources
                self.sourceIndex = 0
                guard let first = r.sources.first, let item = try? await self.makeItem(first) else {
                    self.isLoading = false
                    return
                }
                guard !Task.isCancelled else { return }

                self.attach(item)
            } catch {
                guard !Task.isCancelled else { return }
                self.isLoading = false
                self.errorText = error.localizedDescription
            }
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

    func selectCaption(_ track: CaptionTrack?) {
        captionTask?.cancel()
        selectedCaption = track
        activeCueText = nil
        captionCues = []
        if let track {
            UserDefaults.standard.set(track.languageCode, forKey: "captionLanguage")
            captionTask = Task {
                let cues = await InnerTube.shared.fetchCaptions(from: track.url)
                guard !Task.isCancelled, selectedCaption?.id == track.id else { return }
                self.captionCues = cues
            }
        } else {
            UserDefaults.standard.removeObject(forKey: "captionLanguage")
        }
    }

    func close() {
        savePosition(persist: true)
        loadTask?.cancel()
        captionTask?.cancel()
        preloadTask?.cancel()
        preloadedNext = nil
        captionTracks = []
        selectedCaption = nil
        activeCueText = nil
        captionCues = []
        player.pause()
        player.replaceCurrentItem(with: nil)
        current = nil
        showWatch = false
        queue = []
        sources = []
        sourceIndex = 0
        currentTime = 0
        duration = 0
        errorText = nil
        isLoading = false
        artwork = nil
        setSleep(nil)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func clearQueue() {
        queue = []
    }

    func savePosition(persist: Bool = false) {
        guard let v = current, currentTime > 0, info?.isLive != true else { return }
        lastSaved = currentTime
        let nearEnd = duration > 0 && currentTime > duration - 15
        Library.shared.setPosition(v.id, nearEnd ? nil : currentTime, persist: persist)
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
        captionTask?.cancel()

        let resume = Library.shared.position(video.id)
        let seekTarget = resume > 5 ? resume : nil

        if let p = preloadedNext, p.video.id == video.id {
            preloadedNext = nil
            preloadTask?.cancel()
            preloadTask = nil
            current = p.video
            info = p.info
            chapters = Chapter.parse(p.info.description)
            storyboard = p.info.storyboard.flatMap { Storyboard(spec: $0) }
            captionTracks = p.info.captions
            selectedCaption = nil
            activeCueText = nil
            captionCues = []
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
            pendingSeek = seekTarget
            if let saved = UserDefaults.standard.string(forKey: "captionLanguage"),
               let match = captionTracks.first(where: { $0.languageCode == saved }) {
                selectCaption(match)
            }
            sources = p.sources
            sourceIndex = 0
            try? AVAudioSession.sharedInstance().setActive(true)
            Library.shared.addHistory(p.video)
            updateNowPlaying()
            attach(p.item)
            loadArtwork(for: p.video)
            loadRelated(for: p.video)
            return
        }
        preloadedNext = nil
        preloadTask?.cancel()
        preloadTask = nil

        current = video
        info = nil
        chapters = []
        storyboard = nil
        boosting = false
        related = []
        commentsToken = nil
        segments = []
        captionTracks = []
        selectedCaption = nil
        activeCueText = nil
        captionCues = []
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

        pendingSeek = seekTarget
        let wantsAudioOnly = self.audioOnly || (video.source != nil && Pref.musicAudioOnly)

        loadTask = Task {
            if let file = DownloadManager.shared.localFile(for: video.id) {
                sources = [.file(file)]
                Library.shared.addHistory(video)
            } else {
                do {
                    let startSec = Int(seekTarget ?? 0)
                    var r: ResolvedVideo
                    switch video.source {
                    case .spotify?:
                        let ytId = try await TrackMatcher.shared.youTubeId(for: video)
                        r = try await InnerTube.shared.resolve(ytId, audioOnly: wantsAudioOnly, maxHeight: Pref.maxHeight, startTimeSecs: startSec > 0 ? startSec : nil)
                        r.video = video // keep Spotify id and metadata
                    default:
                        r = try await InnerTube.shared.resolve(video.id, audioOnly: wantsAudioOnly, maxHeight: Pref.maxHeight, startTimeSecs: startSec > 0 ? startSec : nil)
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
                    if r.info.isLive {
                        pendingSeek = nil
                    }
                    chapters = Chapter.parse(r.info.description)
                    storyboard = r.info.storyboard.flatMap { Storyboard(spec: $0) }
                    captionTracks = r.info.captions
                    if let saved = UserDefaults.standard.string(forKey: "captionLanguage"),
                       let match = captionTracks.first(where: { $0.languageCode == saved }) {
                        selectCaption(match)
                    }
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

        loadRelated(for: video)
    }

    private func loadRelated(for video: Video) {
        Task {
            var upNext: [Video] = []
            var token: String?
            switch video.source {
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

    private func preloadNextIfNeeded() {
        guard preloadTask == nil else { return }
        let nextCandidate: Video? = {
            if !queue.isEmpty { return queue.first }
            if Pref.autoplay {
                let seen = Set(backStack.map(\.id) + [current?.id].compactMap { $0 })
                return related.first { !seen.contains($0.id) }
            }
            return nil
        }()
        guard let v = nextCandidate, v.id != preloadedNext?.video.id else { return }
        let wantsAudioOnly = self.audioOnly || (v.source != nil && Pref.musicAudioOnly)
        preloadTask = Task {
            var r: ResolvedVideo?
            if let file = DownloadManager.shared.localFile(for: v.id) {
                r = ResolvedVideo(video: v, info: VideoInfo(description: "", isLive: false), sources: [.file(file)])
            } else {
                switch v.source {
                case .spotify?:
                    if let yt = try? await TrackMatcher.shared.youTubeId(for: v) {
                        r = try? await InnerTube.shared.resolve(yt, audioOnly: wantsAudioOnly, maxHeight: Pref.maxHeight)
                        r?.video = v
                    }
                default:
                    r = try? await InnerTube.shared.resolve(v.id, audioOnly: wantsAudioOnly, maxHeight: Pref.maxHeight)
                }
            }
            guard !Task.isCancelled, let resolved = r, let firstSource = resolved.sources.first,
                  let item = try? await self.makeItem(firstSource) else {
                self.preloadTask = nil
                return
            }
            self.preloadedNext = PreloadData(video: resolved.video, item: item, info: resolved.info, sources: resolved.sources)
            self.preloadTask = nil
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
        let item: AVPlayerItem
        switch source {
        case .hls(let url):
            // HLS comes from the iOS client, whose own player is AVPlayer — keep the default user agent.
            item = AVPlayerItem(url: url)
        case .progressive(let url), .file(let url):
            item = AVPlayerItem(asset: Media.asset(url))
        case .composite(let v, let a):
            item = AVPlayerItem(asset: try await Media.composition(video: Media.asset(v), audio: Media.asset(a)))
        }
        applyQuality(to: item)
        return item
    }

    private func attach(_ item: AVPlayerItem) {
        itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            Task { @MainActor in self?.itemStatusChanged(item, status) }
        }
        player.replaceCurrentItem(with: item)
        player.play()
        if item.status != .unknown {
            itemStatusChanged(item, item.status)
        }
    }

    private func itemStatusChanged(_ item: AVPlayerItem, _ status: AVPlayerItem.Status) {
        guard item === player.currentItem else { return }
        switch status {
        case .readyToPlay:
            if let s = pendingSeek {
                pendingSeek = nil
                player.seek(to: CMTime(seconds: s, preferredTimescale: 600),
                            toleranceBefore: CMTime(seconds: 2, preferredTimescale: 600),
                            toleranceAfter: CMTime(seconds: 2, preferredTimescale: 600)) { [weak self] _ in
                    Task { @MainActor in
                        self?.player.play()
                        self?.updateNowPlaying()
                    }
                }
            }
        case .failed:
            if let err = item.error {
                print("Vidra player item failed with error: \(err.localizedDescription)")
            }
            if (Pref.maxHeight > 1080 || Pref.maxHeight == 0) && sourceIndex == 0 {
                showToast("Không giải mã được 4K/2K, tự động chuyển về 1080p")
            }
            if currentTime > 5 {
                seekWithReload(target: currentTime)
                return
            }
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
        item.preferredForwardBufferDuration = 25.0
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
    }

    // MARK: - Observers

    private func observePlayer() {
        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.syncPlayState() }
        }
        player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                self?.tick(time.seconds)
            }
        }

        let nc = NotificationCenter.default
        nc.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            let item = note.object as AnyObject?
            Task { @MainActor in
                guard let self, item === self.player.currentItem else { return }
                self.itemEnded()
            }
        }
        nc.addObserver(forName: .AVPlayerItemPlaybackStalled, object: nil, queue: .main) { [weak self] note in
            let item = note.object as AnyObject?
            Task { @MainActor in
                guard let self, item === self.player.currentItem else { return }
                self.player.play()
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
            if !playing {
                savePosition(persist: true)
            }
            updateNowPlaying()
        }
    }

    private func findCue(for t: Double) -> CaptionCue? {
        guard !captionCues.isEmpty else { return nil }
        var low = 0
        var high = captionCues.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let cue = captionCues[mid]
            if t < cue.start {
                high = mid - 1
            } else if t > cue.end {
                low = mid + 1
            } else {
                return cue
            }
        }
        return nil
    }

    private func tick(_ t: Double) {
        guard t.isFinite, current != nil, player.currentItem != nil else { return }
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0, d != duration {
            duration = d
            updateNowPlaying()
        }
        currentTime = t
        if selectedCaption != nil && !captionCues.isEmpty {
            let cue = findCue(for: t)
            if activeCueText != cue?.text { activeCueText = cue?.text }
        } else if activeCueText != nil {
            activeCueText = nil
        }
        if Pref.sponsorBlock, let seg = segments.first(where: { t >= $0.start && t < $0.end - 1 }) {
            seek(to: seg.end)
            showToast("Đã bỏ qua: \(seg.label)")
        }
        if abs(t - lastSaved) >= 30 { savePosition(persist: false) }
        if duration > 0 && currentTime >= duration - 15 {
            preloadNextIfNeeded()
        }
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
        c.skipForwardCommand.preferredIntervals = [10]
        c.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.seek(by: 10) }
            return .success
        }
        c.skipBackwardCommand.preferredIntervals = [10]
        c.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.seek(by: -10) }
            return .success
        }
        c.likeCommand.isActive = true
        c.likeCommand.addTarget { [weak self] _ in
            guard let v = self?.current else { return .noActionableNowPlayingItem }
            Task { @MainActor in
                Library.shared.toggleLike(v)
                self?.updateNowPlaying()
            }
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
