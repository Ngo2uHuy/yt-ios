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
    @Published var repeatAll = false
    @Published var showWatch = false

    weak var pipController: AVPictureInPictureController?
    @Published var isPiPActive = false

    /// Audio-only playback shows cover art instead of a (black) video layer.
    var showsArtwork: Bool {
        guard current?.source != nil else { return audioOnly }
        return audioOnly || Pref.musicAudioOnly
    }

    /// Whether current track is playing directly through the Spotify App Remote.
    var isUsingSpotifyRemote: Bool {
        current?.source == .spotify && SpotifyRemote.shared.isAvailable && SpotifyRemote.shared.isConnected
    }

    @Published private(set) var isUsingSpotifyConnect = false

    private var sources: [PlaybackSource] = []
    private var sourceIndex = 0
    private var currentExpiresAt: Date?
    private var currentIsLocalFile = false
    @Published private(set) var segments: [SponsorSegment] = []
    private var lastSkippedSegmentEnd: Double?
    private var mutedBySponsor = false
    private var userMuted = false
    private var backStack: [Video] = []
    private var pendingSeek: Double?
    private var isSeeking = false
    private var seekGeneration: UInt64 = 0
    private var wantsToPlay = false
    private var wasPlayingBeforeInterruption = false
    private var reloadAttempts = 0
    private var lastSaved: Double = 0
    private var artwork: MPMediaItemArtwork?
    private var captionCues: [CaptionCue] = []
    private var captionTask: Task<Void, Never>?

    private struct PreloadData {
        let video: Video
        let item: AVPlayerItem
        let info: VideoInfo
        let sources: [PlaybackSource]
        let expiresAt: Date?
    }
    private var preloadedMap: [String: PreloadData] = [:]
    private var preloadTasks: [String: Task<Void, Never>] = [:]
    private var preloadedNext: PreloadData?
    private var preloadTask: Task<Void, Never>?

    private var loadTask: Task<Void, Never>?
    private var seekTask: Task<Void, Never>?
    private var relatedTask: Task<Void, Never>?
    private var segmentsTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var radioTask: Task<Void, Never>?
    private var spotifyConnectPollTask: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    private var itemObservation: NSKeyValueObservation?
    private var itemDurationObservation: NSKeyValueObservation?
    private var statusObservation: NSKeyValueObservation?
    private var bufferEmptyObserver: NSKeyValueObservation?
    private var bufferKeepUpObserver: NSKeyValueObservation?
    private var timeObserver: Any?
    private var notificationTokens: [NSObjectProtocol] = []
    private var lastStatusHandledItem: ObjectIdentifier?

    private let remoteLock = NSLock()
    private var remoteCurrentSnapshot: Video?

    private var stallCount: Int = 0
    private var lastStallTime: Date = Date.distantPast
    @Published private(set) var isNetworkConstrained: Bool = false
    @Published private(set) var currentIndicatedBitrate: Double = 0

    private override init() {
        rate = Float(Pref.defaultRate)
        audioOnly = UserDefaults.standard.bool(forKey: Pref.audioOnlyKey)
        super.init()
        player.defaultRate = rate
        player.allowsExternalPlayback = true
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        observePlayer()
        setupRemoteCommands()
    }

    // MARK: - Public controls

    func setMuted(_ muted: Bool) {
        userMuted = muted
        if !mutedBySponsor {
            player.isMuted = muted
        }
    }

    func play(_ video: Video, queue newQueue: [Video]? = nil, showWatchSheet: Bool = true, preserveMute: Bool = false) {
        HLSServer.shared.ensureRunning()
        if !preserveMute {
            userMuted = false
            mutedBySponsor = false
            player.isMuted = false
        }
        if let newQueue { queue = newQueue }
        if showWatchSheet {
            showWatch = true
        }
        if current?.id == video.id {
            if isUsingSpotifyRemote {
                wantsToPlay = true
                SpotifyRemote.shared.resume()
                updateNowPlaying()
                return
            }
            if isUsingSpotifyConnect {
                resume()
                return
            }
            if let item = player.currentItem, item.status != .failed, errorText == nil {
                wantsToPlay = true
                try? AVAudioSession.sharedInstance().setActive(true)
                if duration > 1 && currentTime >= duration - 0.5 {
                    seek(to: 0)
                }
                player.play()
                player.rate = boosting ? 2 : rate
                updateNowPlaying()
                return
            }
            // Item previously failed or was cleared — restart cleanly.
            start(video)
            return
        }
        if let c = current, c.id != video.id {
            savePosition()
            pushBack(c)
        }
        start(video)
    }

    func playNext(_ video: Video) {
        if current == nil {
            play(video)
        } else {
            queue.removeAll { $0.id == video.id }
            queue.insert(video, at: 0)
        }
    }

    func appendToQueue(_ video: Video) {
        guard !queue.contains(where: { $0.id == video.id }) else { return }
        queue.append(video)
    }

    func resume() {
        HLSServer.shared.ensureRunning()
        wantsToPlay = true
        if isUsingSpotifyRemote {
            SpotifyRemote.shared.resume()
            isPlaying = true
            updateNowPlaying()
            return
        }
        if isUsingSpotifyConnect {
            isPlaying = true
            updateNowPlaying()
            Task { @MainActor in
                try? await SpotifyAPI.shared.resumePlayback()
            }
            return
        }
        guard let v = current else { return }
        guard let item = player.currentItem, item.status != .failed, errorText == nil else {
            start(v, explicitSeek: currentTime > 1 ? currentTime : nil)
            return
        }
        try? AVAudioSession.sharedInstance().setActive(true)
        if duration > 1 && currentTime >= duration - 0.5 {
            seek(to: 0)
        }
        player.play()
        player.rate = boosting ? 2 : rate
        updateNowPlaying()
    }

    func pause() {
        wantsToPlay = false
        if isUsingSpotifyRemote {
            SpotifyRemote.shared.pause()
            isPlaying = false
            updateNowPlaying()
            return
        }
        if isUsingSpotifyConnect {
            isPlaying = false
            updateNowPlaying()
            Task { @MainActor in
                try? await SpotifyAPI.shared.pausePlayback()
            }
            return
        }
        player.pause()
        isPlaying = false
        updateNowPlaying()
    }

    func togglePlay() {
        if isPlaying || wantsToPlay {
            pause()
        } else {
            resume()
        }
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        guard info?.isLive != true else { return }

        let fallbackDur = Fmt.seconds(current?.duration) ?? 0
        let effectiveDur = duration > 0 ? duration : fallbackDur
        let upper = effectiveDur > 0.5 ? effectiveDur - 0.25 : max(0, effectiveDur)
        let target = effectiveDur > 0 ? min(max(0, seconds), upper) : max(0, seconds)

        currentTime = target
        seekGeneration &+= 1
        let gen = seekGeneration
        let activeId = current?.id

        if isUsingSpotifyRemote {
            SpotifyRemote.shared.seek(to: target)
            updateNowPlaying()
            return
        }
        if isUsingSpotifyConnect {
            updateNowPlaying()
            Task { @MainActor in
                try? await SpotifyAPI.shared.seekPlayback(positionMs: Int(target * 1000))
            }
            return
        }

        guard let item = player.currentItem else {
            if current != nil {
                seekWithReload(target: target, resumePlayback: wantsToPlay)
            }
            return
        }

        if item.status == .failed {
            seekWithReload(target: target, resumePlayback: wantsToPlay)
            return
        }

        guard item.status == .readyToPlay else {
            pendingSeek = target
            return
        }

        let shouldResume = wantsToPlay || player.timeControlStatus != .paused
        isSeeking = true
        let cmTime = target <= 0.05 ? CMTime.zero : CMTime(seconds: target, preferredTimescale: 600)

        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.seekGeneration == gen, self.current?.id == activeId else { return }
                if finished {
                    self.isSeeking = false
                    let actual = self.player.currentTime().seconds
                    if actual.isFinite, actual >= 0 {
                        self.currentTime = actual
                    }
                    if shouldResume {
                        self.wantsToPlay = true
                        try? AVAudioSession.sharedInstance().setActive(true)
                        self.player.play()
                        self.player.rate = self.boosting ? 2 : self.rate
                    } else {
                        self.player.pause()
                    }
                    self.updateNowPlaying()
                }
            }
        }
    }

    private func seekWithReload(target: Double, resumePlayback: Bool) {
        guard let v = current else { return }
        HLSServer.shared.ensureRunning()
        loadTask?.cancel()
        loadTask = nil
        seekTask?.cancel()
        isSeeking = false
        isLoading = true
        errorText = nil
        wantsToPlay = resumePlayback
        pendingSeek = target > 0.5 ? target : nil

        if let file = DownloadManager.shared.localFile(for: v.id) {
            sources = [.file(file)]
            sourceIndex = 0
            currentIsLocalFile = true
            try? AVAudioSession.sharedInstance().setActive(true)
            seekTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.loadCurrentSource()
            }
            return
        }

        let wantsAudioOnly = self.audioOnly || (v.source != nil && Pref.musicAudioOnly)

        seekTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                var r: ResolvedVideo
                if v.source == .spotify {
                    let ytId = try await TrackMatcher.shared.youTubeId(for: v)
                    r = try await InnerTube.shared.resolve(ytId, audioOnly: wantsAudioOnly, maxHeight: Pref.maxHeight)
                    r.video = v
                } else {
                    r = try await InnerTube.shared.resolve(v.id, audioOnly: wantsAudioOnly, maxHeight: Pref.maxHeight)
                }
                guard !Task.isCancelled, self.current?.id == v.id else { return }

                self.sources = r.sources
                self.sourceIndex = 0
                self.currentExpiresAt = r.expiresAt
                self.currentIsLocalFile = false
                try? AVAudioSession.sharedInstance().setActive(true)
                await self.loadCurrentSource()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.current?.id == v.id else { return }
                self.player.replaceCurrentItem(with: nil)
                self.isPlaying = false
                self.isLoading = false
                self.errorText = error.localizedDescription
            }
        }
    }

    func seek(by delta: Double) {
        guard info?.isLive != true else { return }
        seek(to: currentTime + delta)
    }

    func setRate(_ r: Float) {
        rate = r
        boosting = false
        player.defaultRate = r
        if isPlaying { player.rate = r }
        updateNowPlaying()
    }

    /// Press-and-hold fast playback; doesn't touch the user's chosen speed or unpause paused playback.
    func setBoost(_ on: Bool) {
        guard on != boosting, player.currentItem != nil else { return }
        if on && !isPlaying && player.timeControlStatus == .paused { return }
        boosting = on
        if on {
            player.rate = 2
        } else if player.timeControlStatus != .paused {
            player.rate = rate
        }
        updateNowPlaying()
    }

    func next(auto: Bool = false) {
        if isUsingSpotifyRemote && queue.isEmpty {
            SpotifyRemote.shared.next()
            return
        }
        guard let c = current else { return }
        let isMusicTrack = c.source == .ytMusic || c.source == .spotify
        var candidate: Video?
        if !queue.isEmpty {
            if !auto || Pref.autoplay || repeatAll {
                candidate = queue.removeFirst()
            }
        } else if auto && repeatAll {
            let cycle = (backStack + [c]).filter { ($0.source != nil) == (c.source != nil) }
            if let first = cycle.first {
                backStack.removeAll { ($0.source != nil) == (c.source != nil) }
                queue = Array(cycle.dropFirst())
                savePosition()
                start(first)
                return
            }
        } else if !auto || (Pref.autoplay && (!isMusicTrack || Pref.endlessRadio)) {
            let seen = Set(backStack.map(\.id) + [c.id])
            candidate = related.first { !seen.contains($0.id) }
        }
        if let v = candidate {
            savePosition()
            pushBack(c)
            start(v)
            return
        }

        // Only auto-start endless music radio for music tracks (YT Music / Spotify) when autoplay + endlessRadio are enabled.
        if isMusicTrack && (!auto || (Pref.autoplay && Pref.endlessRadio)) {
            radioTask?.cancel()
            radioTask = Task { @MainActor [weak self] in
                guard let self else { return }
                if let nextSong = await self.fetchEndlessRadioCandidate(for: c) {
                    guard !Task.isCancelled, self.current?.id == c.id else { return }
                    self.savePosition()
                    self.pushBack(c)
                    self.start(nextSong)
                }
            }
        }
    }

    private func fetchEndlessRadioCandidate(for video: Video) async -> Video? {
        var seedId = video.id
        if video.id.hasPrefix("sp:") {
            if let yt = try? await TrackMatcher.shared.youTubeId(for: video) {
                seedId = yt
            } else {
                return nil
            }
        }
        let seen = Set(backStack.map(\.id) + [video.id])

        if let radioTracks = try? await InnerTube.shared.musicRadio(seedId) {
            let available = radioTracks.filter { !seen.contains($0.id) }
            if let first = available.first {
                self.related = available
                return first
            }
        }
        if let searchTracks = try? await InnerTube.shared.musicSearch("\(video.channelTitle) songs", continuation: nil).videos {
            let available = searchTracks.filter { !seen.contains($0.id) }
            if let first = available.first {
                self.related = available
                return first
            }
        }
        return nil
    }

    func previous() {
        if isUsingSpotifyRemote && currentTime <= 5 && backStack.isEmpty {
            SpotifyRemote.shared.previous()
            return
        }
        if info?.isLive == true {
            guard let v = backStack.popLast() else { return }
            if let c = current {
                savePosition()
                queue.insert(c, at: 0)
            }
            start(v)
            return
        }
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
        if !currentIsLocalFile {
            reload()
        } else {
            objectWillChange.send()
        }
    }

    func qualityChanged() {
        guard current != nil else { return }
        if currentIsLocalFile { return }
        if !audioOnly { reload() }
    }

    func syncSettings() {
        rate = Float(Pref.defaultRate)
        player.defaultRate = rate
        if isPlaying && !boosting { player.rate = rate }

        if !Pref.sponsorBlock {
            segments = []
            lastSkippedSegmentEnd = nil
            if mutedBySponsor {
                mutedBySponsor = false
                player.isMuted = userMuted
            }
        } else if let c = current, segments.isEmpty {
            fetchSegments(for: c)
        }
        updateNowPlaying()
    }

    func retry() {
        reloadAttempts = 0
        reload()
    }

    func togglePiP() {
        guard let pip = pipController, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        if pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
        } else if pip.isPictureInPicturePossible {
            pip.startPictureInPicture()
        }
    }

    func setSleep(_ minutes: Int?) {
        sleepTask?.cancel()
        sleepAt = nil
        guard let minutes else { return }
        sleepAt = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.pause()
            self.sleepAt = nil
        }
    }

    func selectCaption(_ track: CaptionTrack?) {
        captionTask?.cancel()
        selectedCaption = track
        activeCueText = nil
        captionCues = []
        if let track {
            UserDefaults.standard.set(track.languageCode, forKey: "captionLanguage")
            captionTask = Task { @MainActor [weak self] in
                let cues = await InnerTube.shared.fetchCaptions(from: track.url)
                guard !Task.isCancelled, let self, self.selectedCaption?.id == track.id else { return }
                self.captionCues = cues
            }
        } else {
            UserDefaults.standard.removeObject(forKey: "captionLanguage")
        }
    }

    func close() {
        if isUsingSpotifyRemote {
            SpotifyRemote.shared.pause()
        }
        if isUsingSpotifyConnect {
            Task { try? await SpotifyAPI.shared.pausePlayback() }
        }
        savePosition(persist: true)
        cancelActiveWork()
        clearAllPreloads()
        invalidateItemObservers()

        stallCount = 0
        isNetworkConstrained = false
        lastStallTime = .distantPast
        currentIndicatedBitrate = 0
        reloadAttempts = 0
        isSeeking = false
        wantsToPlay = false
        wasPlayingBeforeInterruption = false
        isUsingSpotifyConnect = false
        currentExpiresAt = nil
        currentIsLocalFile = false
        mutedBySponsor = false
        userMuted = false
        player.isMuted = false

        captionTracks = []
        selectedCaption = nil
        activeCueText = nil
        captionCues = []
        info = nil
        related = []
        commentsToken = nil
        chapters = []
        storyboard = nil
        segments = []
        lastSkippedSegmentEnd = nil
        backStack = []
        pendingSeek = nil
        lastSaved = 0
        boosting = false

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
        isPlaying = false
        artwork = nil
        setSleep(nil)
        updateNowPlaying()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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

    private func cancelActiveWork() {
        loadTask?.cancel()
        loadTask = nil
        seekTask?.cancel()
        seekTask = nil
        captionTask?.cancel()
        captionTask = nil
        relatedTask?.cancel()
        relatedTask = nil
        segmentsTask?.cancel()
        segmentsTask = nil
        artworkTask?.cancel()
        artworkTask = nil
        radioTask?.cancel()
        radioTask = nil
        spotifyConnectPollTask?.cancel()
        spotifyConnectPollTask = nil
    }

    private func invalidateItemObservers() {
        itemObservation?.invalidate()
        itemObservation = nil
        itemDurationObservation?.invalidate()
        itemDurationObservation = nil
        bufferEmptyObserver?.invalidate()
        bufferEmptyObserver = nil
        bufferKeepUpObserver?.invalidate()
        bufferKeepUpObserver = nil
        lastStatusHandledItem = nil
    }

    private func pushBack(_ v: Video) {
        backStack.append(v)
        if backStack.count > 200 { backStack.removeFirst() }
    }

    private func reload() {
        guard let v = current else { return }
        let preserveTime = (currentTime > 0.5 && info?.isLive != true) ? currentTime : nil
        if let preserveTime {
            Library.shared.setPosition(v.id, preserveTime, persist: false)
        }
        start(v, explicitSeek: preserveTime)
    }

    private func start(_ video: Video, explicitSeek: Double? = nil) {
        HLSServer.shared.ensureRunning()
        if video.source != .spotify && SpotifyRemote.shared.isConnected {
            SpotifyRemote.shared.pause()
        }
        cancelActiveWork()
        invalidateItemObservers()

        stallCount = 0
        isNetworkConstrained = false
        lastStallTime = .distantPast
        currentIndicatedBitrate = 0
        reloadAttempts = 0
        isSeeking = false
        seekGeneration &+= 1
        wantsToPlay = true
        isUsingSpotifyConnect = false
        currentExpiresAt = nil
        currentIsLocalFile = false
        mutedBySponsor = false
        if !userMuted { player.isMuted = false }

        let resume = explicitSeek ?? Library.shared.position(video.id)
        let seekTarget = resume > 5 ? resume : (explicitSeek.flatMap { $0 > 0.5 ? $0 : nil })

        let hasLocalFile = DownloadManager.shared.localFile(for: video.id) != nil
        let canUseSpotifyDirect = !hasLocalFile && video.source == .spotify && SpotifyRemote.shared.isAvailable

        var p = (!canUseSpotifyDirect ? preloadedMap.removeValue(forKey: video.id) : nil)
            ?? (!canUseSpotifyDirect && preloadedNext?.video.id == video.id ? preloadedNext : nil)
        if let pre = p, let exp = pre.expiresAt, Date() >= exp.addingTimeInterval(-300) {
            pre.item.cancelPendingSeeks()
            pre.item.asset.cancelLoading()
            p = nil
        }

        if let p {
            if preloadedNext?.video.id == video.id { preloadedNext = nil }
            preloadTasks.removeValue(forKey: video.id)?.cancel()
            preloadTask?.cancel()
            preloadTask = nil

            let mergedVideo = Self.mergeMetadata(resolved: p.video, original: video)
            current = mergedVideo
            info = p.info
            currentExpiresAt = p.expiresAt
            currentIsLocalFile = p.sources.first.map { if case .file = $0 { return true }; return false } ?? false
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
            lastSkippedSegmentEnd = nil
            errorText = nil
            isLoading = p.item.status != .readyToPlay
            currentTime = 0
            duration = (p.item.duration.isNumeric && p.item.duration.seconds > 0)
                ? p.item.duration.seconds
                : (Fmt.seconds(mergedVideo.duration) ?? 0)
            lastSaved = 0
            artwork = nil
            pendingSeek = p.info.isLive ? nil : seekTarget
            if let saved = UserDefaults.standard.string(forKey: "captionLanguage"),
               let match = captionTracks.first(where: { $0.languageCode == saved }) {
                selectCaption(match)
            }
            sources = p.sources
            sourceIndex = 0
            applyQuality(to: p.item, isLive: p.info.isLive)
            try? AVAudioSession.sharedInstance().setActive(true)
            Library.shared.addHistory(mergedVideo)
            updateNowPlaying()
            attach(p.item, isLive: p.info.isLive)
            loadArtwork(for: mergedVideo)
            loadRelated(for: mergedVideo)
            return
        }

        if let prevNext = preloadedNext {
            prevNext.item.cancelPendingSeeks()
            prevNext.item.asset.cancelLoading()
            preloadedNext = nil
        }
        preloadTasks.removeValue(forKey: video.id)?.cancel()
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
        lastSkippedSegmentEnd = nil
        captionTracks = []
        selectedCaption = nil
        activeCueText = nil
        captionCues = []
        errorText = nil
        isLoading = true
        currentTime = 0
        duration = Fmt.seconds(video.duration) ?? 0
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

        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if let file = DownloadManager.shared.localFile(for: video.id) {
                self.sources = [.file(file)]
                self.currentIsLocalFile = true
                Library.shared.addHistory(video)
                await self.loadCurrentSource()
                return
            }

            if video.source == .spotify {
                if SpotifyRemote.shared.isAvailable {
                    let directSuccess = await SpotifyRemote.shared.play(trackId: video.id, video: video)
                    if directSuccess {
                        guard !Task.isCancelled, self.current?.id == video.id else { return }
                        self.isLoading = false
                        self.isPlaying = true
                        self.currentTime = 0
                        self.duration = Fmt.seconds(video.duration) ?? 0
                        self.updateNowPlaying()
                        Library.shared.addHistory(video)
                        return
                    }
                }

                // Only stream via Spotify Connect Web API when user explicitly selected a remote Connect device.
                let selectedRemoteDevice = SpotifyConnectManager.shared.activeDevice?.isLocal == false
                if selectedRemoteDevice, SpotifyAuth.shared.isLoggedIn {
                    let rawId = video.id.hasPrefix("sp:") ? String(video.id.dropFirst(3)) : video.id
                    let uri = "spotify:track:\(rawId)"
                    if (try? await SpotifyAPI.shared.playTrack(uri: uri, deviceId: SpotifyConnectManager.shared.activeDevice?.id)) != nil {
                        guard !Task.isCancelled, self.current?.id == video.id else { return }
                        self.isUsingSpotifyConnect = true
                        self.isLoading = false
                        self.isPlaying = true
                        self.currentTime = 0
                        self.duration = Fmt.seconds(video.duration) ?? 0
                        self.updateNowPlaying()
                        self.startSpotifyConnectPolling(for: video.id)
                        Library.shared.addHistory(video)
                        return
                    }
                }
            }

            do {
                var r: ResolvedVideo
                switch video.source {
                case .spotify?:
                    let ytId = try await TrackMatcher.shared.youTubeId(for: video)
                    r = try await InnerTube.shared.resolve(ytId, audioOnly: wantsAudioOnly, maxHeight: Pref.maxHeight)
                    r.video = video
                default:
                    r = try await InnerTube.shared.resolve(video.id, audioOnly: wantsAudioOnly, maxHeight: Pref.maxHeight)
                }
                guard !Task.isCancelled, self.current?.id == video.id else { return }
                let v = Self.mergeMetadata(resolved: r.video, original: video)
                self.current = v
                self.info = r.info
                self.currentExpiresAt = r.expiresAt
                if r.info.isLive {
                    self.pendingSeek = nil
                    self.duration = 0
                }
                self.chapters = Chapter.parse(r.info.description)
                self.storyboard = r.info.storyboard.flatMap { Storyboard(spec: $0) }
                self.captionTracks = r.info.captions
                if let saved = UserDefaults.standard.string(forKey: "captionLanguage"),
                   let match = self.captionTracks.first(where: { $0.languageCode == saved }) {
                    self.selectCaption(match)
                }
                self.sources = r.sources
                Library.shared.addHistory(v)
                self.updateNowPlaying()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.current?.id == video.id else { return }
                self.errorText = error.localizedDescription
                self.isLoading = false
                self.isPlaying = false
                return
            }
            await self.loadCurrentSource()
        }

        loadRelated(for: video)
    }

    private func startSpotifyConnectPolling(for videoId: String) {
        spotifyConnectPollTask?.cancel()
        spotifyConnectPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self,
                      self.isUsingSpotifyConnect, self.current?.id == videoId else { return }
                if let state = try? await SpotifyAPI.shared.currentPlaybackState() {
                    guard self.current?.id == videoId else { return }
                    self.isPlaying = state.isPlaying
                    self.currentTime = Double(state.progressMs) / 1000.0
                    if state.durationMs > 0 {
                        self.duration = Double(state.durationMs) / 1000.0
                    }
                    self.updateNowPlaying()
                }
            }
        }
    }

    private static func mergeMetadata(resolved: Video, original: Video) -> Video {
        var v = resolved
        if v.title.isEmpty { v.title = original.title }
        if v.channelTitle.isEmpty { v.channelTitle = original.channelTitle }
        v.channelId = v.channelId ?? original.channelId
        v.duration = v.duration ?? original.duration
        v.published = original.published ?? v.published
        v.source = original.source
        v.artwork = original.artwork ?? v.artwork
        v.link = original.link ?? v.link
        return v
    }

    private func loadRelated(for video: Video) {
        relatedTask?.cancel()
        relatedTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var upNext: [Video] = []
            var token: String?
            var resolvedYtId = video.id
            switch video.source {
            case .ytMusic?:
                upNext = (try? await InnerTube.shared.musicRadio(video.id)) ?? []
            case .spotify?:
                if let yt = try? await TrackMatcher.shared.youTubeId(for: video) {
                    resolvedYtId = yt
                    upNext = (try? await InnerTube.shared.musicRadio(yt)) ?? []
                }
            case nil:
                guard let n = try? await InnerTube.shared.next(video.id) else { return }
                upNext = n.related
                token = n.commentsToken
            }
            guard !Task.isCancelled, self.current?.id == video.id else { return }
            self.related = upNext
            self.commentsToken = token
            if Pref.sponsorBlock {
                self.fetchSegments(forId: resolvedYtId, matchingCurrentId: video.id)
            }
        }
        if Pref.sponsorBlock && video.source != .spotify {
            fetchSegments(for: video)
        }
    }

    private func fetchSegments(for video: Video) {
        if video.source == .spotify {
            segmentsTask?.cancel()
            segmentsTask = Task { @MainActor [weak self] in
                if let yt = try? await TrackMatcher.shared.youTubeId(for: video), !Task.isCancelled {
                    guard let self, self.current?.id == video.id else { return }
                    self.segments = await Extras.segments(yt)
                }
            }
        } else {
            fetchSegments(forId: video.id, matchingCurrentId: video.id)
        }
    }

    private func fetchSegments(forId sponsorId: String, matchingCurrentId: String) {
        segmentsTask?.cancel()
        segmentsTask = Task { @MainActor [weak self] in
            let s = await Extras.segments(sponsorId)
            guard !Task.isCancelled, let self, self.current?.id == matchingCurrentId else { return }
            self.segments = s
        }
    }

    private func preloadNextIfNeeded() {
        guard preloadTask == nil else { return }
        let nextCandidate: Video? = {
            if !queue.isEmpty { return Pref.autoplay ? queue.first : nil }
            if Pref.autoplay {
                let seen = Set(backStack.map(\.id) + [current?.id].compactMap { $0 })
                return related.first { !seen.contains($0.id) }
            }
            return nil
        }()
        guard let v = nextCandidate, v.id != preloadedNext?.video.id else { return }
        if DownloadManager.shared.localFile(for: v.id) == nil,
           v.source == .spotify && SpotifyRemote.shared.isAvailable { return }

        let wantsAudioOnly = self.audioOnly || (v.source != nil && Pref.musicAudioOnly)
        let candidateId = v.id
        var taskRef: Task<Void, Never>?
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
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
            guard !Task.isCancelled,
                  let resolved = r,
                  let firstSource = resolved.sources.first,
                  let item = try? await self.makeItem(firstSource, isLive: resolved.info.isLive) else {
                if self.preloadTask == taskRef { self.preloadTask = nil }
                return
            }
            guard !Task.isCancelled else {
                item.cancelPendingSeeks()
                item.asset.cancelLoading()
                if self.preloadTask == taskRef { self.preloadTask = nil }
                return
            }
            if candidateId == self.queue.first?.id || self.queue.isEmpty {
                let merged = Self.mergeMetadata(resolved: resolved.video, original: v)
                if let old = self.preloadedNext {
                    old.item.cancelPendingSeeks()
                    old.item.asset.cancelLoading()
                }
                self.preloadedNext = PreloadData(video: merged, item: item, info: resolved.info, sources: resolved.sources, expiresAt: resolved.expiresAt)
            } else {
                item.cancelPendingSeeks()
                item.asset.cancelLoading()
            }
            if self.preloadTask == taskRef { self.preloadTask = nil }
        }
        taskRef = task
        preloadTask = task
    }

    // MARK: - Multi-Item Preload & Memory Management (Shorts & Fast Paging)

    func preload(video: Video) {
        guard video.id != current?.id else { return }
        guard preloadedMap[video.id] == nil, preloadedNext?.video.id != video.id else { return }
        guard preloadTasks[video.id] == nil else { return }

        let wantsAudioOnly = self.audioOnly || (video.source != nil && Pref.musicAudioOnly)
        let taskId = video.id

        var launchedTask: Task<Void, Never>?
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.preloadTasks[taskId] == launchedTask {
                    self.preloadTasks.removeValue(forKey: taskId)
                }
            }
            var r: ResolvedVideo?
            if let file = DownloadManager.shared.localFile(for: video.id) {
                r = ResolvedVideo(video: video, info: VideoInfo(description: "", isLive: false), sources: [.file(file)])
            } else {
                switch video.source {
                case .spotify?:
                    if let yt = try? await TrackMatcher.shared.youTubeId(for: video) {
                        r = try? await InnerTube.shared.resolve(yt, audioOnly: wantsAudioOnly, maxHeight: Pref.maxHeight)
                        r?.video = video
                    }
                default:
                    r = try? await InnerTube.shared.resolve(video.id, audioOnly: wantsAudioOnly, maxHeight: Pref.maxHeight)
                }
            }
            guard !Task.isCancelled, let resolved = r, let firstSource = resolved.sources.first else { return }

            guard let item = try? await self.makeItem(firstSource, isLive: resolved.info.isLive) else { return }
            item.preferredForwardBufferDuration = 6.0

            guard !Task.isCancelled else {
                item.cancelPendingSeeks()
                item.asset.cancelLoading()
                return
            }
            let merged = Self.mergeMetadata(resolved: resolved.video, original: video)
            self.preloadedMap[taskId] = PreloadData(video: merged, item: item, info: resolved.info, sources: resolved.sources, expiresAt: resolved.expiresAt)
        }
        launchedTask = task
        preloadTasks[taskId] = task
    }

    func purgePreloads(keeping keepIds: Set<String>) {
        let tasksToCancel = preloadTasks.filter { !keepIds.contains($0.key) }
        for (id, task) in tasksToCancel {
            task.cancel()
            preloadTasks.removeValue(forKey: id)
        }
        let evicted = preloadedMap.keys.filter { !keepIds.contains($0) }
        for id in evicted {
            if let p = preloadedMap.removeValue(forKey: id) {
                p.item.cancelPendingSeeks()
                p.item.asset.cancelLoading()
            }
        }
    }

    func clearAllPreloads() {
        for (_, task) in preloadTasks {
            task.cancel()
        }
        preloadTasks.removeAll()
        for (_, p) in preloadedMap {
            p.item.cancelPendingSeeks()
            p.item.asset.cancelLoading()
        }
        preloadedMap.removeAll()
        if let p = preloadedNext {
            p.item.cancelPendingSeeks()
            p.item.asset.cancelLoading()
        }
        preloadedNext = nil
        preloadTask?.cancel()
        preloadTask = nil
    }

    private func loadCurrentSource() async {
        let id = current?.id
        let isLive = info?.isLive ?? false
        while sourceIndex < sources.count {
            let item = try? await makeItem(sources[sourceIndex], isLive: isLive)
            if Task.isCancelled || current?.id != id { return }
            if let item {
                attach(item, isLive: isLive)
                return
            }
            sourceIndex += 1
        }
        player.replaceCurrentItem(with: nil)
        errorText = "Không phát được video này"
        isLoading = false
        isPlaying = false
        updateNowPlaying()
    }

    private func makeItem(_ source: PlaybackSource, isLive: Bool = false) async throws -> AVPlayerItem {
        let item: AVPlayerItem
        switch source {
        case .hls(let url, let ua):
            item = AVPlayerItem(asset: Media.asset(url, userAgent: ua))
        case .progressive(let url, let ua):
            item = AVPlayerItem(asset: Media.asset(url, userAgent: ua))
        case .file(let url):
            item = AVPlayerItem(asset: Media.asset(url))
        case .composite(let v, let a, let vUA, let aUA):
            item = AVPlayerItem(asset: try await Media.composition(
                video: Media.asset(v, userAgent: vUA),
                audio: Media.asset(a, userAgent: aUA)
            ))
        }
        applyQuality(to: item, isLive: isLive)
        return item
    }

    private func attach(_ item: AVPlayerItem, isLive: Bool = false) {
        invalidateItemObservers()
        player.automaticallyWaitsToMinimizeStalling = !isLive

        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let status = item.status
            Task { @MainActor [weak self] in
                self?.itemStatusChanged(item, status)
            }
        }

        itemDurationObservation = item.observe(\.duration, options: [.initial, .new]) { [weak self] item, _ in
            let d = item.duration.seconds
            Task { @MainActor [weak self] in
                guard let self, item === self.player.currentItem, d.isFinite, d > 0, d != self.duration else { return }
                self.duration = d
                self.updateNowPlaying()
            }
        }

        bufferEmptyObserver = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, _ in
            let empty = item.isPlaybackBufferEmpty
            Task { @MainActor [weak self] in
                guard let self, item === self.player.currentItem else { return }
                self.handleBufferEmpty(empty)
            }
        }

        bufferKeepUpObserver = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            let keepUp = item.isPlaybackLikelyToKeepUp
            Task { @MainActor [weak self] in
                guard let self, item === self.player.currentItem else { return }
                self.handleBufferKeepUp(keepUp)
            }
        }

        player.replaceCurrentItem(with: item)
        if wantsToPlay {
            player.play()
            player.rate = boosting ? 2 : rate
        }
    }

    private func itemStatusChanged(_ item: AVPlayerItem, _ status: AVPlayerItem.Status) {
        guard item === player.currentItem else { return }
        switch status {
        case .readyToPlay:
            let itemId = ObjectIdentifier(item)
            guard lastStatusHandledItem != itemId else { return }
            lastStatusHandledItem = itemId

            let itemDur = item.duration.seconds
            if itemDur.isFinite && itemDur > 0 && itemDur != duration {
                duration = itemDur
            }

            if let s = pendingSeek, info?.isLive != true {
                pendingSeek = nil
                seek(to: s)
            } else {
                isLoading = false
                if wantsToPlay && player.timeControlStatus == .paused {
                    player.play()
                    player.rate = boosting ? 2 : rate
                }
                updateNowPlaying()
            }
        case .failed:
            handlePlaybackFailure(for: item, error: item.error)
        default:
            break
        }
    }

    private func handlePlaybackFailure(for item: AVPlayerItem, error: Error?) {
        guard item === player.currentItem else { return }
        if let err = error ?? item.error {
            print("Vidra player item failed: \(err.localizedDescription)")
            if sourceIndex == 0 && sources.count > 1 && !audioOnly && (Pref.maxHeight > 1080 || Pref.maxHeight == 0) {
                let nsErr = err as NSError
                if nsErr.domain == AVFoundationErrorDomain || nsErr.code == AVError.Code.decodeFailed.rawValue {
                    showToast("Không giải mã được 4K/2K, tự động chuyển về 1080p")
                }
            }
        }

        let isExpired = currentExpiresAt.map { Date() >= $0.addingTimeInterval(-120) } ?? false
        if isExpired {
            sourceIndex = sources.count // force re-resolve fresh URLs immediately
        } else {
            sourceIndex += 1
        }

        if sourceIndex < sources.count {
            if info?.isLive != true, currentTime > 1 {
                pendingSeek = currentTime
            }
            loadTask?.cancel()
            isLoading = true
            let currentVideoId = current?.id
            loadTask = Task { @MainActor [weak self] in
                guard let self, self.current?.id == currentVideoId else { return }
                await self.loadCurrentSource()
            }
        } else if reloadAttempts < 2 && !currentIsLocalFile {
            reloadAttempts += 1
            let resumeAt = (info?.isLive != true && currentTime > 1) ? currentTime : 0
            seekWithReload(target: resumeAt, resumePlayback: wantsToPlay)
        } else {
            player.replaceCurrentItem(with: nil)
            errorText = "Không phát được video này"
            isLoading = false
            isPlaying = false
            updateNowPlaying()
        }
    }

    private func applyQuality(to item: AVPlayerItem, isLive: Bool = false) {
        let h = Double(Pref.maxHeight)
        // Use bounding square of long edge so portrait Shorts (1080x1920) aren't downscaled on width.
        item.preferredMaximumResolution = h > 0 ? CGSize(width: h * 16 / 9, height: h * 16 / 9) : .zero
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        if isLive {
            item.automaticallyPreservesTimeOffsetFromLive = true
            item.configuredTimeOffsetFromLive = CMTime(seconds: 2.0, preferredTimescale: 600)
            item.preferredForwardBufferDuration = 4.0
        } else {
            item.preferredForwardBufferDuration = 30.0
        }
    }

    // MARK: - Observers

    private func observePlayer() {
        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.syncPlayState() }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                self?.tick(time.seconds)
            }
        }

        let nc = NotificationCenter.default
        notificationTokens.append(nc.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            let item = note.object as AnyObject?
            Task { @MainActor [weak self] in
                guard let self, item === self.player.currentItem else { return }
                self.itemEnded()
            }
        })
        notificationTokens.append(nc.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor [weak self] in
                guard let self, let item, item === self.player.currentItem else { return }
                self.handlePlaybackFailure(for: item, error: err)
            }
        })
        notificationTokens.append(nc.addObserver(forName: .AVPlayerItemPlaybackStalled, object: nil, queue: .main) { [weak self] note in
            let item = note.object as AnyObject?
            Task { @MainActor [weak self] in
                guard let self, item === self.player.currentItem else { return }
                self.handlePlaybackStall()
            }
        })
        notificationTokens.append(nc.addObserver(forName: .AVPlayerItemNewErrorLogEntry, object: nil, queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            Task { @MainActor [weak self] in
                guard let self, let item, item === self.player.currentItem else { return }
                if let evt = item.errorLog()?.events.last,
                   [403, 404, 410].contains(evt.errorStatusCode),
                   self.player.timeControlStatus != .playing,
                   item.isPlaybackBufferEmpty {
                    self.handlePlaybackFailure(for: item, error: YTError.http(evt.errorStatusCode))
                }
            }
        })
        notificationTokens.append(nc.addObserver(forName: .AVPlayerItemNewAccessLogEntry, object: nil, queue: .main) { [weak self] note in
            let item = note.object as AnyObject?
            Task { @MainActor [weak self] in
                guard let self, item === self.player.currentItem else { return }
                self.evaluateNetworkRecovery()
            }
        })
        notificationTokens.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
            let optRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if type == .began {
                    self.wasPlayingBeforeInterruption = self.isPlaying || self.wantsToPlay
                    self.pause()
                } else if type == .ended {
                    if shouldResume && self.wasPlayingBeforeInterruption {
                        self.wasPlayingBeforeInterruption = false
                        self.resume()
                    }
                }
            }
        })
        notificationTokens.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let reasonValue = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
            if reason == .oldDeviceUnavailable {
                Task { @MainActor [weak self] in
                    self?.pause()
                }
            }
        })
    }

    private func syncPlayState() {
        guard current != nil else { return }
        if isUsingSpotifyRemote || isUsingSpotifyConnect { return }

        let oldPlaying = isPlaying
        let oldLoading = isLoading

        switch player.timeControlStatus {
        case .playing:
            isLoading = false
            isPlaying = true
            wantsToPlay = true
            reloadAttempts = 0
        case .waitingToPlayAtSpecifiedRate:
            isLoading = true
            isPlaying = wantsToPlay
        default: // .paused
            if player.currentItem != nil && pendingSeek == nil && !isSeeking {
                isLoading = false
            }
            isPlaying = false
        }

        if oldPlaying && !isPlaying && !isSeeking {
            savePosition(persist: true)
        }
        if isPlaying != oldPlaying || isLoading != oldLoading || player.timeControlStatus == .playing {
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
        guard !isSeeking, pendingSeek == nil else { return }

        currentTime = max(0, t)
        if selectedCaption != nil && !captionCues.isEmpty {
            let cue = findCue(for: t)
            if activeCueText != cue?.text { activeCueText = cue?.text }
        } else if activeCueText != nil {
            activeCueText = nil
        }

        if Pref.sponsorBlock && !segments.isEmpty {
            // Handle "mute" segments cleanly without skipping timeline
            let inMuteSeg = segments.contains { $0.actionType == "mute" && $0.isValid && t >= ($0.start - 0.1) && t < ($0.end - 0.1) }
            if inMuteSeg {
                if !mutedBySponsor {
                    mutedBySponsor = true
                    player.isMuted = true
                }
            } else if mutedBySponsor {
                mutedBySponsor = false
                player.isMuted = userMuted
            }

            if let seg = segments.first(where: { $0.actionType != "mute" && $0.isValid && t >= ($0.start - 0.2) && t < ($0.end - 0.3) }) {
                if lastSkippedSegmentEnd != seg.end {
                    lastSkippedSegmentEnd = seg.end
                    if duration > 1 && seg.end >= duration - 0.5 {
                        seek(to: max(0, duration - 0.3))
                    } else {
                        seek(to: seg.end)
                    }
                    showToast("Đã tự động bỏ qua: \(seg.label)")
                }
            } else if let l = lastSkippedSegmentEnd, t >= l + 0.5 || t < l - 2 {
                lastSkippedSegmentEnd = nil
            }
        } else if mutedBySponsor {
            mutedBySponsor = false
            player.isMuted = userMuted
        }

        if abs(t - lastSaved) >= 30 { savePosition(persist: false) }
        if duration > 0 && currentTime >= duration - 15 {
            preloadNextIfNeeded()
        }
    }

    private func itemEnded() {
        if loop {
            wantsToPlay = true
            seek(to: 0)
            return
        }
        if let v = current { Library.shared.setPosition(v.id, nil, persist: true) }
        if stopAfterCurrent {
            stopAfterCurrent = false
            wantsToPlay = false
            pause()
            seek(to: 0)
            return
        }
        next(auto: true)
    }

    private static func normalizeSpotifyVideoId(_ raw: String) -> String {
        if raw.hasPrefix("sp:") { return raw }
        if raw.hasPrefix("spotify:track:") { return "sp:" + raw.dropFirst("spotify:track:".count) }
        return "sp:" + raw
    }

    func syncFromSpotifyRemote(isPaused: Bool, position: Double, duration: Double, title: String, artist: String, uri: String? = nil) {
        guard current?.source == .spotify else { return }
        self.wantsToPlay = !isPaused
        self.isPlaying = !isPaused
        if position.isFinite && position >= 0 { self.currentTime = position }
        if duration.isFinite && duration > 0 { self.duration = duration }
        self.isLoading = false

        if let uri, let c = current, !title.isEmpty {
            let normalizedId = Self.normalizeSpotifyVideoId(uri)
            if c.id != normalizedId {
                pushBack(c)
                let updated = Video(
                    id: normalizedId,
                    title: title,
                    channelTitle: artist,
                    duration: duration > 0 ? Fmt.time(duration) : nil,
                    source: .spotify,
                    artwork: nil,
                    link: URL(string: "https://open.spotify.com/track/\(normalizedId.dropFirst(3))")
                )
                self.current = updated
                self.artwork = nil
                self.related = []
                self.segments = []
                self.chapters = []
                self.lastSkippedSegmentEnd = nil
                Library.shared.addHistory(updated)
                loadArtwork(for: updated)
                loadRelated(for: updated)
            }
        }
        updateNowPlaying()
    }

    // MARK: - Adaptive Bitrate & Buffer Health

    private func handleBufferEmpty(_ empty: Bool) {
        if empty && (isPlaying || wantsToPlay) {
            isLoading = true
            updateNowPlaying()
        }
    }

    private func handleBufferKeepUp(_ keepUp: Bool) {
        if keepUp {
            isLoading = false
            if player.timeControlStatus == .paused && wantsToPlay && !isSeeking {
                player.play()
                player.rate = boosting ? 2 : rate
            }
            updateNowPlaying()
        }
    }

    private func handlePlaybackStall() {
        let now = Date()
        if now.timeIntervalSince(lastStallTime) < 40 {
            stallCount += 1
        } else {
            stallCount = 1
        }
        lastStallTime = now

        guard let item = player.currentItem else {
            if wantsToPlay { player.play() }
            return
        }

        // If URL expired or repeated stalls happen on this source, fail over instead of retrying forever.
        let isExpired = currentExpiresAt.map { Date() >= $0.addingTimeInterval(-120) } ?? false
        if stallCount >= 4 || isExpired {
            handlePlaybackFailure(for: item, error: nil)
            return
        }

        isNetworkConstrained = true
        switch stallCount {
        case 1:
            item.preferredPeakBitRate = 2_500_000
            item.preferredMaximumResolution = CGSize(width: 1280, height: 1280)
            showToast("Mạng chậm, tự động tối ưu 720p để tiếp tục phát mượt mà")
        case 2:
            item.preferredPeakBitRate = 1_000_000
            item.preferredMaximumResolution = CGSize(width: 854, height: 854)
            showToast("Mạng yếu, tự động điều chỉnh 480p để tránh đứng hình")
        default:
            item.preferredPeakBitRate = 500_000
            item.preferredMaximumResolution = CGSize(width: 640, height: 640)
            showToast("Tối ưu hóa độ phân giải ở mức tiết kiệm dữ liệu")
        }

        if wantsToPlay {
            player.play()
            player.rate = boosting ? 2 : rate
        }
    }

    private func evaluateNetworkRecovery() {
        guard isNetworkConstrained,
              let event = player.currentItem?.accessLog()?.events.last,
              event.observedBitrate > 0 else { return }

        currentIndicatedBitrate = event.indicatedBitrate

        if event.observedBitrate > 5_500_000 && Date().timeIntervalSince(lastStallTime) > 45 {
            isNetworkConstrained = false
            stallCount = 0
            if let item = player.currentItem {
                let maxH = Double(Pref.maxHeight)
                item.preferredPeakBitRate = 0
                item.preferredMaximumResolution = maxH > 0 ? CGSize(width: maxH * 16 / 9, height: maxH * 16 / 9) : .zero
            }
        }
    }

    private func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    // MARK: - Lock screen / Control Center

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()

        c.playCommand.isEnabled = true
        c.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.resume() }
            return .success
        }

        c.pauseCommand.isEnabled = true
        c.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.pause() }
            return .success
        }

        c.togglePlayPauseCommand.isEnabled = true
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.togglePlay() }
            return .success
        }

        c.nextTrackCommand.isEnabled = true
        c.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.next() }
            return .success
        }

        c.previousTrackCommand.isEnabled = true
        c.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.previous() }
            return .success
        }

        c.skipForwardCommand.isEnabled = true
        c.skipForwardCommand.preferredIntervals = [10]
        c.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.seek(by: 10) }
            return .success
        }

        c.skipBackwardCommand.isEnabled = true
        c.skipBackwardCommand.preferredIntervals = [10]
        c.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.seek(by: -10) }
            return .success
        }

        c.likeCommand.isEnabled = true
        c.likeCommand.addTarget { [weak self] _ in
            guard let self else { return .noActionableNowPlayingItem }
            self.remoteLock.lock()
            let snapshot = self.remoteCurrentSnapshot
            self.remoteLock.unlock()
            guard let v = snapshot else { return .noActionableNowPlayingItem }
            Task { @MainActor [weak self] in
                Library.shared.toggleLike(v)
                self?.updateNowPlaying()
            }
            return .success
        }

        c.changePlaybackPositionCommand.isEnabled = true
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let t = e.positionTime
            Task { @MainActor [weak self] in self?.seek(to: t) }
            return .success
        }
    }

    private func updateNowPlaying() {
        remoteLock.lock()
        remoteCurrentSnapshot = current
        remoteLock.unlock()

        let rc = MPRemoteCommandCenter.shared()
        rc.changePlaybackPositionCommand.isEnabled = (current != nil && info?.isLive != true)

        guard let v = current else {
            rc.likeCommand.isActive = false
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            return
        }

        rc.likeCommand.isActive = Library.shared.isLiked(v.id)

        let effectiveRate: Double
        if isUsingSpotifyRemote || isUsingSpotifyConnect {
            effectiveRate = isPlaying ? 1.0 : 0.0
        } else {
            effectiveRate = (isPlaying && !isLoading && player.timeControlStatus == .playing)
                ? Double(boosting ? 2 : rate)
                : 0.0
        }

        var np: [String: Any] = [
            MPMediaItemPropertyTitle: v.title,
            MPMediaItemPropertyArtist: v.channelTitle,
            MPMediaItemPropertyAlbumTitle: v.channelTitle,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, currentTime),
            MPNowPlayingInfoPropertyPlaybackRate: effectiveRate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(rate),
            MPNowPlayingInfoPropertyMediaType: NSNumber(value: (audioOnly || v.source != nil) ? MPNowPlayingInfoMediaType.audio.rawValue : MPNowPlayingInfoMediaType.video.rawValue)
        ]

        if duration > 0 {
            np[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let artwork {
            np[MPMediaItemPropertyArtwork] = artwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = np
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    private func loadArtwork(for v: Video) {
        artworkTask?.cancel()
        var urls: [URL] = []
        if let local = DownloadManager.shared.localArtwork(for: v.id) {
            urls.append(local)
        }
        urls += [v.artwork, v.thumbnail].compactMap { $0 }
        if v.source == nil || v.source == .ytMusic,
           let encoded = v.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
            urls += [
                URL(string: "https://i.ytimg.com/vi/\(encoded)/maxresdefault.jpg"),
                URL(string: "https://i.ytimg.com/vi/\(encoded)/hq720.jpg"),
                URL(string: "https://i.ytimg.com/vi/\(encoded)/mqdefault.jpg")
            ].compactMap { $0 }
        }

        artworkTask = Task { @MainActor [weak self] in
            for url in urls {
                if Task.isCancelled { return }
                if let img = await ImageCache.shared.load(url: url, targetSize: CGSize(width: 600, height: 600)),
                   let self, self.current?.id == v.id, !Task.isCancelled {
                    if img.size.width > 120 {
                        self.artwork = Self.makeArtwork(img)
                        self.updateNowPlaying()
                        return
                    }
                }
            }
        }
    }

    private nonisolated static func makeArtwork(_ img: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: img.size) { _ in img }
    }
}
