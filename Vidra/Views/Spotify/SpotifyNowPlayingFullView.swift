import AVFoundation
import AVKit
import CoreImage
import SwiftUI
import UIKit

// MARK: - Spotify Design System Colors

private enum SpotifyColors {
    static let green = Color(red: 29 / 255.0, green: 185 / 255.0, blue: 84 / 255.0) // #1DB954
    static let backgroundBlack = Color(red: 18 / 255.0, green: 18 / 255.0, blue: 18 / 255.0) // #121212
    static let cardBlack = Color(red: 24 / 255.0, green: 24 / 255.0, blue: 24 / 255.0) // #181818
    static let subtextGray = Color(red: 179 / 255.0, green: 179 / 255.0, blue: 179 / 255.0) // #B3B3B3
    static let trackUnfilled = Color.white.opacity(0.2)
    static let controlInactive = Color(red: 179 / 255.0, green: 179 / 255.0, blue: 179 / 255.0)
}

// MARK: - Repeat Mode

private enum SpotifyRepeatMode: Int, CaseIterable {
    case off = 0
    case all = 1
    case one = 2

    var iconName: String {
        switch self {
        case .off, .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    var isActive: Bool {
        self != .off
    }
}

// MARK: - Spotify Now Playing Full View

struct SpotifyNowPlayingFullView: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject private var pm = PlayerManager.shared
    @ObservedObject private var library = Library.shared
    @ObservedObject private var downloads = DownloadManager.shared
    @ObservedObject private var connectManager = SpotifyConnectManager.shared

    // Visual theme
    @State private var tintColor: Color = Color(red: 0.18, green: 0.28, blue: 0.22)

    // Player state
    @State private var scrubFraction: Double? = nil
    @State private var isScrubbing = false
    @State private var isShuffle = false
    @State private var repeatMode: SpotifyRepeatMode = .off
    @State private var artDragOffset: CGFloat = 0

    // Lyrics
    @State private var lyrics: LyricsResult? = nil
    @State private var lyricsLoading = false
    @State private var isLyricsExpanded = false
    @State private var userScrolledAway = false

    // Sheets & modals
    @State private var showQueueSheet = false
    @State private var showDevicePickerSheet = false
    @State private var addTarget: Video? = nil
    @State private var remapTarget: Video? = nil

    init() {}

    var body: some View {
        NavigationStack {
            ZStack {
                // Dynamic Gradient Background transitioning down to #121212
                dynamicBackground
                    .ignoresSafeArea()

                if let currentTrack = pm.current {
                    if isLyricsExpanded {
                        fullLyricsView(currentTrack)
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .move(edge: .bottom).combined(with: .opacity)
                            ))
                    } else {
                        playerScrollView(currentTrack)
                            .transition(.opacity)
                    }
                } else {
                    emptyPlaceholder
                }
            }
            .navigationBarHidden(true)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showQueueSheet) {
            SpotifyQueueSheet().presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showDevicePickerSheet) {
            SpotifyConnectSheet().presentationDetents([.medium, .large])
        }
        .sheet(item: $addTarget) { v in
            AddToPlaylistView(video: v).presentationDetents([.medium, .large])
        }
        .sheet(item: $remapTarget) { v in
            SpotifyRemapSheet(video: v).presentationDetents([.medium, .large])
        }
        .task(id: pm.current?.id) {
            scrubFraction = nil
            artDragOffset = 0
            userScrolledAway = false
            await loadAlbumArtworkColor()
            await loadTrackLyrics()
            await connectManager.refreshDevices()
        }
    }

    // MARK: - Dynamic Background

    private var dynamicBackground: some View {
        LinearGradient(
            stops: [
                .init(color: tintColor.opacity(0.88), location: 0.0),
                .init(color: tintColor.opacity(0.45), location: 0.42),
                .init(color: SpotifyColors.backgroundBlack.opacity(0.95), location: 0.72),
                .init(color: SpotifyColors.backgroundBlack, location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Empty State

    private var emptyPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note")
                .font(.system(size: 64))
                .foregroundStyle(SpotifyColors.subtextGray)
            Text("Chưa có bài hát nào đang phát")
                .font(.headline)
                .foregroundStyle(SpotifyColors.subtextGray)
            Button {
                dismiss()
            } label: {
                Text("Đóng")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.12), in: Capsule())
                    .foregroundStyle(Color.white)
            }
        }
    }

    // MARK: - Main Player Scroll View

    private func playerScrollView(_ v: Video) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                // Top bar: Minimize button, Playlist/Album title, Context menu
                topBar(v)
                    .padding(.top, 8)
                    .padding(.bottom, 12)

                // Large square album artwork with spring scale on play/pause
                artworkSection(v)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                // Song Title, Artist name & Spotify green Heart
                songInfoSection(v)
                    .padding(.horizontal, 24)
                    .padding(.top, 16)

                // Custom Spotify Scrubber
                scrubberSection(v)
                    .padding(.horizontal, 24)
                    .padding(.top, 10)

                // Playback Controls: Shuffle, Previous, Play/Pause, Next, Repeat
                playbackControlsSection
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                // Bottom Toolbar: Spotify Connect / Device picker, Share, Queue
                bottomToolbarSection(v)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)

                // Synced Karaoke Lyrics Card preview
                lyricsCardPreview(v)
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 36)
            }
        }
    }

    // MARK: - Top Bar

    private func topBar(_ v: Video) -> some View {
        HStack(alignment: .center) {
            // Dismiss button (chevron.down)
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }

            Spacer()

            // Header labels
            VStack(spacing: 2) {
                Text(sourceSubheader(v))
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(Color.white.opacity(0.7))

                Text(sourceTitle(v))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
            }
            .frame(maxWidth: 240)

            Spacer()

            // Options menu (ellipsis)
            Menu {
                Menu {
                    ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2], id: \.self) { r in
                        Button {
                            pm.setRate(r)
                        } label: {
                            if pm.rate == r {
                                Label(Fmt.rate(Double(r)), systemImage: "checkmark")
                            } else {
                                Text(Fmt.rate(Double(r)))
                            }
                        }
                    }
                } label: {
                    Label("Tốc độ phát", systemImage: "speedometer")
                }

                SleepMenu()

                if v.source == .spotify {
                    Button {
                        if let url = v.link {
                            UIApplication.shared.open(url)
                        } else {
                            let rawId = v.id.hasPrefix("sp:") ? String(v.id.dropFirst(3)) : v.id
                            if let spUrl = URL(string: "spotify:track:\(rawId)") {
                                UIApplication.shared.open(spUrl)
                            }
                        }
                    } label: {
                        Label("Mở trong ứng dụng Spotify", systemImage: "arrow.up.forward.app")
                    }

                    Button {
                        remapTarget = v
                    } label: {
                        Label("Đổi nguồn âm thanh", systemImage: "arrow.triangle.2.circlepath")
                    }
                }

                Button {
                    addTarget = v
                } label: {
                    Label("Thêm vào danh sách phát", systemImage: "text.badge.plus")
                }

                Button {
                    DownloadManager.shared.start(v, audioOnly: true)
                } label: {
                    Label(downloadTitle(v), systemImage: "arrow.down.circle")
                }
                .disabled(downloads.isDownloaded(v.id) || downloads.active[v.id] != nil)

                ShareLink(item: v.shareURL) {
                    Label("Chia sẻ", systemImage: "square.and.arrow.up")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 16)
    }

    private func sourceSubheader(_ v: Video) -> String {
        switch v.source {
        case .spotify?: return "ĐANG PHÁT TỪ SPOTIFY"
        case .ytMusic?: return "ĐANG PHÁT TỪ YOUTUBE MUSIC"
        default: return "ĐANG PHÁT TỪ"
        }
    }

    private func sourceTitle(_ v: Video) -> String {
        if let author = v.channelTitle.isEmpty ? nil : v.channelTitle {
            return author
        }
        return "Vidra Music"
    }

    private func downloadTitle(_ v: Video) -> String {
        if downloads.isDownloaded(v.id) { return "Đã tải xuống" }
        return downloads.active[v.id] != nil ? "Đang tải xuống…" : "Tải xuống bài hát"
    }

    // MARK: - Album Artwork

    private func artworkSection(_ v: Video) -> some View {
        ZStack {
            // Dynamic ambient halo glow behind album artwork
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(
                    RadialGradient(
                        colors: [
                            tintColor.opacity(pm.isPlaying ? 0.70 : 0.25),
                            tintColor.opacity(0.12),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 30,
                        endRadius: 210
                    )
                )
                .frame(maxWidth: 360, maxHeight: 360)
                .blur(radius: pm.isPlaying ? 40 : 20)
                .drawingGroup()
                .scaleEffect(pm.isPlaying ? 1.08 : 0.92)
                .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: pm.isPlaying)

            CachedAsyncImage(url: v.thumbnail, targetSize: CGSize(width: 400, height: 400)) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                ZStack {
                    Color.white.opacity(0.08)
                    Image(systemName: "music.note")
                        .font(.system(size: 68))
                        .foregroundStyle(Color.white.opacity(0.3))
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            )
            .shadow(color: tintColor.opacity(0.45), radius: 26, x: 0, y: 14)
            .shadow(color: Color.black.opacity(0.55), radius: 16, x: 0, y: 8)
            .overlay { stateOverlay }
        }
        // Spotify dynamic bounce: art shrinks subtly when paused
        .scaleEffect(pm.isPlaying ? 1.0 : 0.88)
        .animation(.spring(response: 0.45, dampingFraction: 0.72), value: pm.isPlaying)
        // Swipe gesture to switch tracks
        .offset(x: artDragOffset)
        .rotationEffect(.degrees(Double(artDragOffset) / 38))
        .gesture(
            DragGesture(minimumDistance: 15)
                .onChanged { gesture in
                    if abs(gesture.translation.width) > abs(gesture.translation.height) {
                        artDragOffset = gesture.translation.width
                    }
                }
                .onEnded { gesture in
                    if gesture.translation.width < -80 {
                        triggerHaptic(style: .medium)
                        pm.next()
                    } else if gesture.translation.width > 80 {
                        triggerHaptic(style: .medium)
                        pm.previous()
                    }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        artDragOffset = 0
                    }
                }
        )
        .frame(maxWidth: 380, maxHeight: 380)
    }

    @ViewBuilder
    private var stateOverlay: some View {
        if let err = pm.errorText {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.yellow)
                Text(err)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.white)
                Button("Thử lại") {
                    pm.retry()
                }
                .buttonStyle(.borderedProminent)
                .tint(SpotifyColors.green)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else if pm.isLoading {
            ZStack {
                Color.black.opacity(0.38)
                ProgressView()
                    .tint(Color.white)
                    .scaleEffect(1.3)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    // MARK: - Song Info Section

    private func songInfoSection(_ v: Video) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(v.title)
                    .font(.title3.bold())
                    .foregroundStyle(Color.white)
                    .lineLimit(2)

                artistLink(v)
            }

            Spacer(minLength: 12)

            // Spotify Green Heart Button
            Button {
                library.toggleLike(v)
                triggerHaptic(style: .medium)
            } label: {
                let isLiked = library.isLiked(v.id)
                Image(systemName: isLiked ? "heart.fill" : "heart")
                    .font(.title2)
                    .foregroundStyle(isLiked ? SpotifyColors.green : SpotifyColors.controlInactive)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
        }
    }

    @ViewBuilder
    private func artistLink(_ v: Video) -> some View {
        let label = Text(v.channelTitle)
            .font(.subheadline)
            .foregroundStyle(SpotifyColors.subtextGray)
            .lineLimit(1)

        if let cid = v.channelId, cid.hasPrefix("spa:") {
            NavigationLink {
                SpotifyArtistView(artistId: String(cid.dropFirst(4)), name: v.channelTitle)
            } label: {
                label
            }
        } else {
            label
        }
    }

    // MARK: - Spotify Scrubber Section

    private func scrubberSection(_ v: Video) -> some View {
        let total = max(pm.duration, 0)
        let fraction = scrubFraction ?? (total > 0 ? min(max(pm.currentTime / total, 0), 1) : 0)
        let shownTime = scrubFraction.map { $0 * total } ?? pm.currentTime

        return VStack(spacing: 4) {
            GeometryReader { geo in
                let width = geo.size.width
                let progressWidth = max(0, min(width, width * fraction))

                ZStack(alignment: .leading) {
                    // Unfilled track
                    Capsule()
                        .fill(SpotifyColors.trackUnfilled)
                        .frame(height: 4)

                    // Filled progress track (Spotify uses white scrubber bar)
                    Capsule()
                        .fill(Color.white)
                        .frame(width: progressWidth, height: 4)

                    // Spotify Scrubber Thumb: appears and scales on interaction
                    Circle()
                        .fill(Color.white)
                        .frame(width: isScrubbing ? 14 : 10, height: isScrubbing ? 14 : 10)
                        .shadow(color: Color.black.opacity(0.35), radius: 3, y: 1)
                        .offset(x: max(0, min(width - (isScrubbing ? 14 : 10), progressWidth - (isScrubbing ? 7 : 5))))
                        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isScrubbing)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            isScrubbing = true
                            scrubFraction = min(max(g.location.x / max(width, 1), 0), 1)
                        }
                        .onEnded { g in
                            let f = min(max(g.location.x / max(width, 1), 0), 1)
                            isScrubbing = false
                            scrubFraction = nil
                            if total > 0 {
                                pm.seek(to: f * total)
                            }
                        }
                )
            }
            .frame(height: 22)

            // Timestamp indicators
            HStack {
                Text(Fmt.time(shownTime))
                Spacer()
                Text("-" + Fmt.time(max(total - shownTime, 0)))
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(SpotifyColors.subtextGray)
        }
    }

    // MARK: - Main Playback Controls

    private var playbackControlsSection: some View {
        HStack {
            // Shuffle Button with small green indicator dot
            Button {
                isShuffle.toggle()
                if isShuffle {
                    pm.queue.shuffle()
                }
                triggerHaptic(style: .light)
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "shuffle")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(isShuffle ? SpotifyColors.green : SpotifyColors.controlInactive)

                    Circle()
                        .fill(SpotifyColors.green)
                        .frame(width: 4, height: 4)
                        .opacity(isShuffle ? 1 : 0)
                }
                .frame(width: 44, height: 44)
            }
            .buttonStyle(SpringPressButtonStyle())

            Spacer()

            // Previous Button: backward.end.fill
            Button {
                pm.previous()
                triggerHaptic(style: .light)
            } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 48, height: 48)
            }
            .buttonStyle(SpringPressButtonStyle())

            Spacer()

            // Large 64x64 Circular Play/Pause Button with soft dynamic halo
            Button {
                pm.togglePlay()
                triggerHaptic(style: .medium)
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 64, height: 64)
                        .shadow(color: Color.white.opacity(pm.isPlaying ? 0.35 : 0.08), radius: 14, y: 0)
                        .shadow(color: Color.black.opacity(0.4), radius: 8, y: 4)

                    Image(systemName: pm.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(Color.black)
                        .offset(x: pm.isPlaying ? 0 : 2)
                }
            }
            .buttonStyle(SpringPressButtonStyle())

            Spacer()

            // Next Button: forward.end.fill
            Button {
                pm.next()
                triggerHaptic(style: .light)
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 48, height: 48)
            }
            .buttonStyle(SpringPressButtonStyle())

            Spacer()

            // Repeat Button: Off / Repeat All / Repeat 1
            Button {
                let nextVal = (repeatMode.rawValue + 1) % SpotifyRepeatMode.allCases.count
                repeatMode = SpotifyRepeatMode(rawValue: nextVal) ?? .off
                switch repeatMode {
                case .off:
                    pm.loop = false
                case .all:
                    pm.loop = false
                case .one:
                    pm.loop = true
                }
                triggerHaptic(style: .light)
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: repeatMode.iconName)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(repeatMode.isActive ? SpotifyColors.green : SpotifyColors.controlInactive)

                    Circle()
                        .fill(SpotifyColors.green)
                        .frame(width: 4, height: 4)
                        .opacity(repeatMode.isActive ? 1 : 0)
                }
                .frame(width: 44, height: 44)
            }
            .buttonStyle(SpringPressButtonStyle())
        }
    }

    // MARK: - Bottom Toolbar

    private func bottomToolbarSection(_ v: Video) -> some View {
        HStack {
            // Spotify Connect / Audio Route Picker
            Button {
                showDevicePickerSheet = true
                triggerHaptic(style: .light)
            } label: {
                let active = connectManager.activeDevice
                let isExternal = active != nil && !active!.isLocal

                HStack(spacing: 7) {
                    Image(systemName: active?.iconName ?? "hifi.speaker.and.homepod")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isExternal ? SpotifyColors.green : SpotifyColors.subtextGray)

                    Text(active?.name ?? "Thiết bị")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isExternal ? SpotifyColors.green : SpotifyColors.subtextGray)
                        .lineLimit(1)

                    if isExternal && pm.isPlaying {
                        SpotifyEqualizerBars(isPlaying: true, color: SpotifyColors.green)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    isExternal ? SpotifyColors.green.opacity(0.14) : Color.white.opacity(0.05),
                    in: Capsule()
                )
            }
            .buttonStyle(.plain)

            Spacer()

            // Share Button
            ShareLink(item: v.shareURL) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(SpotifyColors.subtextGray)
                    .frame(width: 44, height: 44)
            }

            Spacer()

            // Queue Button
            Button {
                showQueueSheet = true
                triggerHaptic(style: .light)
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(SpotifyColors.subtextGray)
                    .frame(width: 44, height: 44)
            }
        }
    }

    // MARK: - Synced Karaoke Lyrics Card Preview

    private func lyricsCardPreview(_ v: Video) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Card Header
            HStack {
                Text("Lời bài hát")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.white)

                Spacer()

                Button {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
                        isLyricsExpanded = true
                    }
                    triggerHaptic(style: .light)
                } label: {
                    HStack(spacing: 4) {
                        Text("MỞ RỘNG")
                            .font(.system(size: 10, weight: .heavy))
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.35), in: Capsule())
                }
            }

            // Lyrics Lines Preview
            if lyricsLoading {
                HStack(spacing: 10) {
                    ProgressView().tint(Color.white)
                    Text("Đang tải lời bài hát...")
                        .font(.subheadline)
                        .foregroundStyle(Color.white.opacity(0.7))
                }
                .padding(.vertical, 16)
            } else if let lyrics, !lyrics.synced.isEmpty {
                let activeIdx = currentLyricIndex(lyrics.synced)
                let start = max(0, activeIdx)
                let slice = Array(lyrics.synced[start..<min(start + 3, lyrics.synced.count)])

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(slice, id: \.self) { line in
                        let isCurrent = (lyrics.synced.firstIndex(of: line) == activeIdx)
                        Button {
                            pm.seek(to: line.time)
                            triggerHaptic(style: .medium)
                        } label: {
                            Text(line.text.isEmpty ? "♪" : line.text)
                                .font(.system(
                                    size: isCurrent ? 22 : 18,
                                    weight: isCurrent ? .heavy : .bold,
                                    design: .rounded
                                ))
                                .foregroundStyle(isCurrent ? Color.white : Color.white.opacity(0.45))
                                .shadow(
                                    color: isCurrent ? Color.white.opacity(0.85) : Color.clear,
                                    radius: isCurrent ? 8 : 0
                                )
                                .shadow(
                                    color: isCurrent ? tintColor.opacity(0.9) : Color.clear,
                                    radius: isCurrent ? 16 : 0
                                )
                                .scaleEffect(isCurrent ? 1.02 : 1.0, anchor: .leading)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        .buttonStyle(LyricLineButtonStyle())
                        .animation(.easeInOut(duration: 0.2), value: activeIdx)
                    }
                }
                .padding(.vertical, 4)
            } else if let plain = lyrics?.plain, !plain.isEmpty {
                Text(plain.prefix(160) + "...")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .lineLimit(3)
                    .padding(.vertical, 4)
            } else {
                Text("Chưa có lời bài hát cho bài này.")
                    .font(.subheadline)
                    .foregroundStyle(Color.white.opacity(0.55))
                    .padding(.vertical, 14)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            // 16pt rounded rectangle contrasting card
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            tintColor.opacity(0.78),
                            tintColor.opacity(0.52)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.35), radius: 12, y: 6)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
                isLyricsExpanded = true
            }
            triggerHaptic(style: .light)
        }
    }

    // MARK: - Full Screen Synced Karaoke Lyrics View

    private func fullLyricsView(_ v: Video) -> some View {
        ZStack {
            // Spotify Canvas Ambient Glow Living Background
            SpotifyCanvasBackground(tintColor: tintColor, isPlaying: pm.isPlaying)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Full-screen Top Bar
                HStack {
                    Button {
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
                            isLyricsExpanded = false
                        }
                        triggerHaptic(style: .light)
                    } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Color.white)
                            .padding(10)
                            .background(Color.black.opacity(0.35), in: Circle())
                    }

                    Spacer()

                    VStack(spacing: 2) {
                        Text(v.title)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.white)
                            .lineLimit(1)
                        Text(v.channelTitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(SpotifyColors.subtextGray)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: 240)

                    Spacer()

                    ShareLink(item: v.shareURL) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Color.white)
                            .padding(10)
                            .background(Color.black.opacity(0.35), in: Circle())
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 8)

                // Lyrics Scroll Body
                if lyricsLoading {
                    VStack(spacing: 12) {
                        ProgressView().tint(Color.white).scaleEffect(1.2)
                        Text("Đang tải lời bài hát...")
                            .font(.headline)
                            .foregroundStyle(Color.white.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let lyrics, !lyrics.synced.isEmpty {
                    syncedLyricsKaraokeList(lyrics.synced)
                } else if let plain = lyrics?.plain, !plain.isEmpty {
                    ScrollView {
                        Text(plain)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.85))
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 36)
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 48))
                            .foregroundStyle(Color.white.opacity(0.4))
                        Text("Không tìm thấy lời bài hát")
                            .font(.headline)
                            .foregroundStyle(Color.white.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // Compact Bottom Player Controls in Lyrics Mode
                miniControlsInLyrics(v)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.45))
            }
        }
    }

    private func syncedLyricsKaraokeList(_ lines: [LyricLine]) -> some View {
        let activeIdx = currentLyricIndex(lines)

        return ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 26) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            let isCurrent = (index == activeIdx)
                            let isPast = (index < activeIdx)
                            let text = line.text.isEmpty ? "♪" : line.text

                            Button {
                                pm.seek(to: line.time)
                                userScrolledAway = false
                                triggerHaptic(style: .medium)
                                withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                                    proxy.scrollTo(index, anchor: .center)
                                }
                            } label: {
                                Text(text)
                                    .font(.system(
                                        size: isCurrent ? 28 : 22,
                                        weight: isCurrent ? .heavy : .bold,
                                        design: .rounded
                                    ))
                                    .foregroundStyle(
                                        isCurrent ? Color.white :
                                        (isPast ? Color.white.opacity(0.65) : Color.white.opacity(0.30))
                                    )
                                    .shadow(
                                        color: isCurrent ? Color.white.opacity(0.85) : Color.clear,
                                        radius: isCurrent ? 8 : 0,
                                        x: 0,
                                        y: 0
                                    )
                                    .shadow(
                                        color: isCurrent ? tintColor.opacity(0.95) : Color.clear,
                                        radius: isCurrent ? 22 : 0,
                                        x: 0,
                                        y: 0
                                    )
                                    .shadow(
                                        color: isCurrent ? Color.black.opacity(0.5) : Color.clear,
                                        radius: isCurrent ? 4 : 0,
                                        x: 0,
                                        y: 2
                                    )
                                    .blur(radius: isCurrent ? 0 : (isPast ? 0 : 0.35))
                                    .scaleEffect(isCurrent ? 1.04 : 1.0, anchor: .leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .multilineTextAlignment(.leading)
                                    .padding(.vertical, isCurrent ? 4 : 0)
                            }
                            .buttonStyle(LyricLineButtonStyle())
                            .id(index)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 60)
                    .padding(.bottom, 110)
                    .animation(.spring(response: 0.38, dampingFraction: 0.8), value: activeIdx)
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { _ in
                            if !userScrolledAway {
                                userScrolledAway = true
                            }
                        }
                )
                // Spotify fade mask at top and bottom
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.10),
                            .init(color: .black, location: 0.88),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                // Floating Re-sync button when user scrolled away
                if userScrolledAway && activeIdx >= 0 {
                    Button {
                        userScrolledAway = false
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                            proxy.scrollTo(activeIdx, anchor: .center)
                        }
                        triggerHaptic(style: .light)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 13, weight: .bold))
                            Text("Đồng bộ lời bài hát")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.white, in: Capsule())
                        .shadow(color: Color.black.opacity(0.45), radius: 10, y: 4)
                    }
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onChange(of: activeIdx) { newIndex in
                guard newIndex >= 0 else { return }
                if !userScrolledAway {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }
            .onAppear {
                if activeIdx >= 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                            proxy.scrollTo(activeIdx, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private func miniControlsInLyrics(_ v: Video) -> some View {
        VStack(spacing: 8) {
            // Interactive slim progress bar
            let total = max(pm.duration, 0)
            let fraction = scrubFraction ?? (total > 0 ? min(max(pm.currentTime / total, 0), 1) : 0)
            let shownTime = scrubFraction.map { $0 * total } ?? pm.currentTime

            HStack(spacing: 8) {
                Text(Fmt.time(shownTime))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(SpotifyColors.subtextGray)
                    .frame(width: 44, alignment: .leading)

                GeometryReader { geo in
                    let width = geo.size.width
                    let progressWidth = max(0, min(width, width * fraction))

                    ZStack(alignment: .leading) {
                        Capsule().fill(SpotifyColors.trackUnfilled).frame(height: 3)
                        Capsule().fill(Color.white).frame(width: progressWidth, height: 3)

                        if isScrubbing {
                            Circle()
                                .fill(Color.white)
                                .frame(width: 10, height: 10)
                                .offset(x: max(0, min(width - 10, progressWidth - 5)))
                        }
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { g in
                                isScrubbing = true
                                scrubFraction = min(max(g.location.x / max(width, 1), 0), 1)
                            }
                            .onEnded { g in
                                let f = min(max(g.location.x / max(width, 1), 0), 1)
                                isScrubbing = false
                                scrubFraction = nil
                                if total > 0 {
                                    pm.seek(to: f * total)
                                }
                            }
                    )
                }
                .frame(height: 14)

                Text("-" + Fmt.time(max(total - shownTime, 0)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(SpotifyColors.subtextGray)
                    .frame(width: 44, alignment: .trailing)
            }

            // Controls
            HStack {
                Button {
                    library.toggleLike(v)
                    triggerHaptic(style: .light)
                } label: {
                    let isLiked = library.isLiked(v.id)
                    Image(systemName: isLiked ? "heart.fill" : "heart")
                        .font(.title3)
                        .foregroundStyle(isLiked ? SpotifyColors.green : SpotifyColors.controlInactive)
                }

                Spacer()

                Button {
                    pm.previous()
                    triggerHaptic(style: .light)
                } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.title3)
                        .foregroundStyle(Color.white)
                }

                Spacer()

                Button {
                    pm.togglePlay()
                    triggerHaptic(style: .medium)
                } label: {
                    ZStack {
                        Circle().fill(Color.white).frame(width: 48, height: 48)
                        Image(systemName: pm.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3.bold())
                            .foregroundStyle(Color.black)
                            .offset(x: pm.isPlaying ? 0 : 1)
                    }
                }

                Spacer()

                Button {
                    pm.next()
                    triggerHaptic(style: .light)
                } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.title3)
                        .foregroundStyle(Color.white)
                }

                Spacer()

                Button {
                    showDevicePickerSheet = true
                    triggerHaptic(style: .light)
                } label: {
                    let active = connectManager.activeDevice
                    let isExternal = active != nil && !active!.isLocal
                    Image(systemName: active?.iconName ?? "hifi.speaker.and.homepod")
                        .font(.title3)
                        .foregroundStyle(isExternal ? SpotifyColors.green : SpotifyColors.controlInactive)
                }

                Spacer()

                Button {
                    showQueueSheet = true
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.title3)
                        .foregroundStyle(SpotifyColors.controlInactive)
                }
            }
        }
    }

    // MARK: - Helpers

    private func currentLyricIndex(_ lines: [LyricLine]) -> Int {
        let t = pm.currentTime + 0.25
        return lines.lastIndex { $0.time <= t } ?? -1
    }

    private func loadAlbumArtworkColor() async {
        guard let v = pm.current else { return }
        if let url = v.thumbnail, let c = await ArtworkColorCache.shared.color(for: url) {
            withAnimation(.easeInOut(duration: 0.65)) {
                tintColor = c
            }
        }
    }

    private func loadTrackLyrics() async {
        lyrics = nil
        guard let v = pm.current else { return }
        lyricsLoading = true
        let result = await LyricsService.shared.lyrics(for: v, duration: pm.duration)
        guard !Task.isCancelled else { return }
        lyrics = result
        lyricsLoading = false
    }

    private func triggerHaptic(style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }
}

// MARK: - Spotify Canvas Ambient Glow Background

private struct SpotifyCanvasBackground: View {
    let tintColor: Color
    let isPlaying: Bool

    @State private var animatePulse = false

    var body: some View {
        ZStack {
            // Base background
            SpotifyColors.backgroundBlack

            // Deep dynamic tint gradient
            LinearGradient(
                stops: [
                    .init(color: tintColor.opacity(0.85), location: 0.0),
                    .init(color: tintColor.opacity(0.35), location: 0.45),
                    .init(color: SpotifyColors.backgroundBlack.opacity(0.95), location: 0.75),
                    .init(color: SpotifyColors.backgroundBlack, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // Canvas Orb 1: Upper glowing radiant aura
            Circle()
                .fill(tintColor.opacity(0.55))
                .frame(width: 360, height: 360)
                .blur(radius: 75)
                .offset(
                    x: animatePulse ? -50 : 50,
                    y: animatePulse ? -100 : -30
                )

            // Canvas Orb 2: Ambient center light pulse (breathes with playback)
            Circle()
                .fill(Color.white.opacity(0.10))
                .frame(width: 280, height: 280)
                .blur(radius: 65)
                .scaleEffect(animatePulse ? (isPlaying ? 1.25 : 1.05) : 0.95)
                .offset(x: 25, y: animatePulse ? 60 : -20)

            // Canvas Orb 3: Lower warm atmosphere
            Circle()
                .fill(tintColor.opacity(0.40))
                .frame(width: 320, height: 320)
                .blur(radius: 85)
                .offset(
                    x: animatePulse ? 70 : -30,
                    y: animatePulse ? 160 : 220
                )

            // Contrast scrim overlay for crisp text readability
            Color.black.opacity(0.25)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 5.5).repeatForever(autoreverses: true)) {
                animatePulse = true
            }
        }
    }
}

// MARK: - Lyric Line Button Style

private struct LyricLineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.70 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Spotify Queue Sheet

struct SpotifyQueueSheet: View {
    @ObservedObject private var pm = PlayerManager.shared
    @Environment(\.dismiss) private var dismiss

    init() {}

    var body: some View {
        NavigationStack {
            ZStack {
                SpotifyColors.backgroundBlack.ignoresSafeArea()

                List {
                    if let c = pm.current {
                        Section {
                            nowPlayingRow(c)
                        } header: {
                            Text("ĐANG PHÁT")
                                .font(.caption.bold())
                                .foregroundStyle(SpotifyColors.subtextGray)
                        }
                        .listRowBackground(SpotifyColors.cardBlack)
                    }

                    Section {
                        if pm.queue.isEmpty {
                            Text("Hàng đợi trống")
                                .foregroundStyle(SpotifyColors.subtextGray)
                                .font(.subheadline)
                        } else {
                            ForEach(pm.queue) { track in
                                queueRow(track)
                            }
                            .onMove { pm.queue.move(fromOffsets: $0, toOffset: $1) }
                            .onDelete { pm.queue.remove(atOffsets: $0) }
                        }
                    } header: {
                        Text("TIẾP THEO TRONG HÀNG ĐỢI")
                            .font(.caption.bold())
                            .foregroundStyle(SpotifyColors.subtextGray)
                    }
                    .listRowBackground(SpotifyColors.cardBlack)

                    if !pm.related.isEmpty {
                        Section {
                            ForEach(pm.related) { v in
                                Button {
                                    pm.play(v)
                                } label: {
                                    queueRow(v)
                                }
                                .buttonStyle(.plain)
                            }
                        } header: {
                            Text("GỢI Ý PHÁT TIẾP")
                                .font(.caption.bold())
                                .foregroundStyle(SpotifyColors.subtextGray)
                        }
                        .listRowBackground(SpotifyColors.cardBlack)
                    }
                }
                .scrollContentBackground(.hidden)
                .listStyle(.insetGrouped)
            }
            .navigationTitle("Hàng đợi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    EditButton().foregroundStyle(SpotifyColors.green)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Xong") {
                        dismiss()
                    }
                    .font(.body.bold())
                    .foregroundStyle(Color.white)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func nowPlayingRow(_ v: Video) -> some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: v.thumbnail, targetSize: CGSize(width: 48, height: 48)) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Color.gray.opacity(0.3)
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(v.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SpotifyColors.green)
                    .lineLimit(1)
                Text(v.channelTitle)
                    .font(.caption)
                    .foregroundStyle(SpotifyColors.subtextGray)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "waveform")
                .font(.subheadline)
                .foregroundStyle(SpotifyColors.green)
        }
    }

    private func queueRow(_ v: Video) -> some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: v.thumbnail, targetSize: CGSize(width: 46, height: 46)) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Color.gray.opacity(0.3)
            }
            .frame(width: 46, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(v.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                Text(v.channelTitle)
                    .font(.caption)
                    .foregroundStyle(SpotifyColors.subtextGray)
                    .lineLimit(1)
            }

            Spacer()
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Spotify Animated Equalizer Bars

struct SpotifyEqualizerBars: View {
    let isPlaying: Bool
    var color: Color = SpotifyColors.green

    @State private var bar1: CGFloat = 0.4
    @State private var bar2: CGFloat = 0.9
    @State private var bar3: CGFloat = 0.6

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            RoundedRectangle(cornerRadius: 1)
                .fill(color)
                .frame(width: 2.5, height: isPlaying ? bar1 * 13 : 4)
            RoundedRectangle(cornerRadius: 1)
                .fill(color)
                .frame(width: 2.5, height: isPlaying ? bar2 * 13 : 4)
            RoundedRectangle(cornerRadius: 1)
                .fill(color)
                .frame(width: 2.5, height: isPlaying ? bar3 * 13 : 4)
        }
        .frame(height: 14)
        .onAppear {
            if isPlaying {
                startAnimation()
            }
        }
        .onChange(of: isPlaying) { playing in
            if playing {
                startAnimation()
            }
        }
    }

    private func startAnimation() {
        withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) {
            bar1 = 0.9
        }
        withAnimation(.easeInOut(duration: 0.35).repeatForever(autoreverses: true).delay(0.1)) {
            bar2 = 0.3
        }
        withAnimation(.easeInOut(duration: 0.50).repeatForever(autoreverses: true).delay(0.2)) {
            bar3 = 1.0
        }
    }
}

// MARK: - Spotify Connect Sheet (Available Devices Picker)

struct SpotifyConnectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var connectManager = SpotifyConnectManager.shared
    @ObservedObject private var pm = PlayerManager.shared

    @State private var isSpinningRefresh = false

    var body: some View {
        NavigationStack {
            ZStack {
                SpotifyColors.backgroundBlack.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        // Current Device Hero Card
                        if let current = connectManager.activeDevice {
                            currentDeviceHero(current)
                        }

                        // Available Devices Section
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text("Chọn một thiết bị")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(Color.white)

                                Spacer()

                                Button {
                                    withAnimation(.easeInOut(duration: 0.6)) {
                                        isSpinningRefresh = true
                                    }
                                    Task {
                                        await connectManager.refreshDevices()
                                        isSpinningRefresh = false
                                    }
                                    triggerHaptic(style: .light)
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(SpotifyColors.subtextGray)
                                        .rotationEffect(.degrees(isSpinningRefresh ? 360 : 0))
                                        .padding(8)
                                        .background(Color.white.opacity(0.06), in: Circle())
                                }
                            }

                            HStack(spacing: 6) {
                                Image(systemName: "wifi")
                                    .font(.system(size: 12))
                                Text("Thiết bị cùng mạng Wi-Fi và Spotify Connect")
                                    .font(.system(size: 12))
                            }
                            .foregroundStyle(SpotifyColors.subtextGray)

                            // List of Devices
                            VStack(spacing: 8) {
                                ForEach(connectManager.devices) { dev in
                                    deviceRow(dev)
                                }
                            }
                        }

                        // AirPlay & Bluetooth Native iOS Section
                        airplaySection

                        // Spotify Connect Help / Info Link
                        HStack {
                            Spacer()
                            Link(destination: URL(string: "https://www.spotify.com/connect/")!) {
                                HStack(spacing: 4) {
                                    Image(systemName: "info.circle")
                                        .font(.system(size: 12))
                                    Text("Tìm hiểu thêm về Spotify Connect")
                                        .font(.system(size: 12, weight: .medium))
                                }
                                .foregroundStyle(SpotifyColors.subtextGray)
                            }
                            Spacer()
                        }
                        .padding(.top, 10)
                        .padding(.bottom, 24)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                }
            }
            .navigationTitle("Nghe trên thiết bị khác")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                        triggerHaptic(style: .light)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(SpotifyColors.subtextGray)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDragIndicator(.visible)
        .onAppear {
            connectManager.startPolling()
        }
        .onDisappear {
            connectManager.stopPolling()
        }
    }

    // Hero card for active device
    private func currentDeviceHero(_ dev: SpotifyDevice) -> some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(SpotifyColors.green.opacity(0.18))
                    .frame(width: 52, height: 52)

                Image(systemName: dev.iconName)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(SpotifyColors.green)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("HIỆN ĐANG PHÁT TRÊN")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(SpotifyColors.green)
                    .tracking(0.8)

                Text(dev.name)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    SpotifyEqualizerBars(isPlaying: pm.isPlaying, color: SpotifyColors.green)
                    Text(dev.protocolType + " • Đang hoạt động")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(SpotifyColors.subtextGray)
                }
            }

            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(SpotifyColors.cardBlack)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(SpotifyColors.green.opacity(0.35), lineWidth: 1)
                )
        )
    }

    // Single device row
    private func deviceRow(_ dev: SpotifyDevice) -> some View {
        let isCurrent = dev.id == connectManager.activeDevice?.id
        let isTransferring = dev.id == connectManager.transferringDeviceId

        return Button {
            Task {
                await connectManager.selectDevice(dev)
            }
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isCurrent ? SpotifyColors.green.opacity(0.16) : Color.white.opacity(0.06))
                        .frame(width: 44, height: 44)

                    Image(systemName: dev.iconName)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(isCurrent ? SpotifyColors.green : Color.white)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(dev.name)
                        .font(.system(size: 15, weight: isCurrent ? .bold : .semibold))
                        .foregroundStyle(isCurrent ? SpotifyColors.green : Color.white)
                        .lineLimit(1)

                    HStack(spacing: 5) {
                        Image(systemName: dev.protocolIcon)
                            .font(.system(size: 10))
                        Text(dev.protocolType)
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(SpotifyColors.subtextGray)
                }

                Spacer()

                if isTransferring {
                    ProgressView()
                        .tint(SpotifyColors.green)
                        .scaleEffect(0.85)
                } else if isCurrent {
                    SpotifyEqualizerBars(isPlaying: pm.isPlaying, color: SpotifyColors.green)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isCurrent ? Color.white.opacity(0.04) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    // AirPlay & Bluetooth section
    private var airplaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Không thấy thiết bị của bạn?")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SpotifyColors.subtextGray)

            ZStack {
                // Invisible RoutePicker covering the entire card to trigger native iOS AirPlay
                RoutePicker()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(0.02)

                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                            .frame(width: 44, height: 44)

                        Image(systemName: "airplayaudio")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(Color.white)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("AirPlay hoặc Bluetooth")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.white)

                        Text("Kết nối thiết bị âm thanh qua hệ thống iOS")
                            .font(.system(size: 12))
                            .foregroundStyle(SpotifyColors.subtextGray)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(SpotifyColors.subtextGray)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(SpotifyColors.cardBlack)
                )
            }
            .frame(height: 60)
        }
    }

    private func triggerHaptic(style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }
}
