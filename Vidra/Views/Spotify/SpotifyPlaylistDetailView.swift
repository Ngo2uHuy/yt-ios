import SwiftUI
import UIKit

// MARK: - Spotify Theme Constants & Helpers

enum SpotifyTheme {
    static let darkBackground = Color(red: 18 / 255, green: 18 / 255, blue: 18 / 255) // #121212
    static let green = Color(red: 29 / 255, green: 185 / 255, blue: 84 / 255)         // #1DB954
    static let secondaryText = Color(red: 179 / 255, green: 179 / 255, blue: 179 / 255) // #B3B3B3
    static let cardBackground = Color(white: 0.14)
    static let subtleHighlight = Color(white: 0.22)
    static let divider = Color(white: 0.12)
}

// MARK: - Dynamic Color Extraction

private enum SpotifyColorExtractor {
    /// Palette of authentic ambient Spotify playlist backdrop colors.
    private static let fallbackPalette: [Color] = [
        Color(red: 0.12, green: 0.32, blue: 0.24), // Forest Green
        Color(red: 0.10, green: 0.22, blue: 0.36), // Deep Navy
        Color(red: 0.28, green: 0.14, blue: 0.34), // Royal Purple
        Color(red: 0.38, green: 0.12, blue: 0.18), // Crimson Ruby
        Color(red: 0.32, green: 0.24, blue: 0.12), // Amber Bronze
        Color(red: 0.10, green: 0.30, blue: 0.32), // Deep Teal
        Color(red: 0.20, green: 0.18, blue: 0.30)  // Slate Violet
    ]

    /// Instant deterministic ambient tone so the top gradient renders immediately without flicker.
    static func initialColor(for string: String) -> Color {
        let hash = abs(string.hashValue)
        return fallbackPalette[hash % fallbackPalette.count]
    }

    /// Asynchronously extracts a dominant, moody ambient color from the artwork image.
    static func extractColor(from url: URL?) async -> Color? {
        guard let url else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data) else { return nil }

        return await Task.detached(priority: .utility) {
            guard let cgImage = image.cgImage else { return nil }
            let size = CGSize(width: 8, height: 8)
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            var rawData = [UInt8](repeating: 0, count: 8 * 8 * 4)

            guard let context = CGContext(
                data: &rawData,
                width: Int(size.width),
                height: Int(size.height),
                bitsPerComponent: 8,
                bytesPerRow: Int(size.width) * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }

            context.draw(cgImage, in: CGRect(origin: .zero, size: size))

            var totalR: Double = 0
            var totalG: Double = 0
            var totalB: Double = 0
            let count = 64.0

            for i in stride(from: 0, to: rawData.count, by: 4) {
                totalR += Double(rawData[i])
                totalG += Double(rawData[i + 1])
                totalB += Double(rawData[i + 2])
            }

            var r = (totalR / count) / 255.0
            var g = (totalG / count) / 255.0
            var b = (totalB / count) / 255.0

            // Boost contrast and clamp brightness to prevent overly light pastel tones.
            let maxC = max(r, max(g, b))
            if maxC > 0 {
                let boost = min(1.2, 0.7 / maxC)
                r = min(1.0, r * boost)
                g = min(1.0, g * boost)
                b = min(1.0, b * boost)
            }

            return Color(red: max(0.08, r), green: max(0.08, g), blue: max(0.08, b))
        }.value
    }
}

// MARK: - Scroll Offset Tracking

private struct SpotifyScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Playlist Metadata Model

struct SpotifyPlaylistMetadata: Sendable {
    var title: String
    var description: String
    var coverURL: URL?
    var creatorName: String
    var creatorAvatarURL: URL?
    var likesCount: Int?
    var isAlbum: Bool
    var releaseYear: String?

    init(
        title: String,
        description: String = "",
        coverURL: URL? = nil,
        creatorName: String = "Spotify",
        creatorAvatarURL: URL? = nil,
        likesCount: Int? = 1_420_850,
        isAlbum: Bool = false,
        releaseYear: String? = nil
    ) {
        self.title = title
        self.description = description
        self.coverURL = coverURL
        self.creatorName = creatorName
        self.creatorAvatarURL = creatorAvatarURL
        self.likesCount = likesCount
        self.isAlbum = isAlbum
        self.releaseYear = releaseYear
    }
}

// MARK: - ViewModel

@MainActor
final class SpotifyPlaylistDetailModel: ObservableObject {
    @Published var tracks: [Video] = []
    @Published var metadata: SpotifyPlaylistMetadata
    @Published var dominantColor: Color
    @Published var loading = false
    @Published var loaded = false
    @Published var error: String?

    // Recommended songs
    @Published var recommendedTracks: [Video] = []
    @Published var loadingRecommendations = false
    @Published var addedRecommendedTrackIds: Set<String> = []

    private var nextOffset: String?
    private let loader: ((Int) async throws -> Page)?
    private let playlistId: String?
    private let albumId: String?

    init(
        metadata: SpotifyPlaylistMetadata,
        playlistId: String? = nil,
        albumId: String? = nil,
        loader: (((Int) async throws -> Page))? = nil
    ) {
        self.metadata = metadata
        self.playlistId = playlistId
        self.albumId = albumId
        self.loader = loader
        self.dominantColor = SpotifyColorExtractor.initialColor(for: metadata.title)
    }

    func load(reset: Bool = false) async {
        guard !loading else { return }
        loading = true
        error = nil

        // If loading for the first time, extract image color and fetch rich metadata if available
        if !loaded || reset {
            Task {
                if let extracted = await SpotifyColorExtractor.extractColor(from: metadata.coverURL) {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        self.dominantColor = extracted
                    }
                }
            }

            if let pid = playlistId {
                await fetchPlaylistMetadata(id: pid)
            } else if let aid = albumId {
                await fetchAlbumMetadata(id: aid)
            }
        }

        do {
            let offset = reset ? 0 : (Int(nextOffset ?? "") ?? 0)
            let page: Page

            if let customLoader = loader {
                page = try await customLoader(offset)
            } else if let pid = playlistId {
                page = try await SpotifyAPI.shared.playlistTracks(id: pid, offset: offset)
            } else if let aid = albumId {
                page = try await SpotifyAPI.shared.albumTracks(id: aid, offset: offset)
            } else {
                page = Page()
            }

            if reset {
                tracks = page.videos
            } else {
                let seen = Set(tracks.map(\.id))
                tracks += page.videos.filter { !seen.contains($0.id) }
            }

            nextOffset = page.continuation
            loaded = true

            // Automatically load recommended songs if not yet loaded
            if recommendedTracks.isEmpty && !tracks.isEmpty {
                Task {
                    await self.loadRecommendations()
                }
            }
        } catch {
            if !Task.isCancelled {
                self.error = error.localizedDescription
            }
            loaded = true
        }
        loading = false
    }

    func loadRecommendations(refresh: Bool = false) async {
        guard !loadingRecommendations else { return }
        loadingRecommendations = true
        if refresh {
            recommendedTracks = []
        }

        let seeds = Array(tracks.shuffled().prefix(4))
        let hint = "\(metadata.title) \(metadata.creatorName)"
        let recs = await InnerTube.shared.recommendedSongs(for: seeds.isEmpty ? tracks : seeds, queryHint: hint, limit: 8)

        // Exclude tracks already in playlist
        let existingIds = Set(tracks.map(\.id))
        let filtered = recs.filter { !existingIds.contains($0.id) }

        withAnimation(.easeInOut(duration: 0.35)) {
            self.recommendedTracks = filtered
            self.loadingRecommendations = false
        }
    }

    func addRecommendedTrack(_ track: Video) {
        guard !tracks.contains(where: { $0.id == track.id }) else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            tracks.append(track)
            addedRecommendedTrackIds.insert(track.id)
        }
        let gen = UIImpactFeedbackGenerator(style: .medium)
        gen.impactOccurred()
    }

    func loadMoreIfNeeded(current: Video) {
        guard nextOffset != nil, !loading, error == nil, current.id == tracks.last?.id else { return }
        Task { await self.load(reset: false) }
    }

    private func fetchPlaylistMetadata(id: String) async {
        guard let j = try? await SpotifyAPI.shared.playlistInfo(id: id) else { return }
        let name = j["name"].string ?? metadata.title
        let desc = j["description"].string ?? metadata.description
        let image = SpotifyMap.image(j["images"]) ?? metadata.coverURL
        let owner = j["owner"]["display_name"].string ?? metadata.creatorName
        let followers = j["followers"]["total"].int ?? metadata.likesCount

        metadata = SpotifyPlaylistMetadata(
            title: name,
            description: desc,
            coverURL: image,
            creatorName: owner,
            creatorAvatarURL: metadata.creatorAvatarURL,
            likesCount: followers,
            isAlbum: false
        )
    }

    private func fetchAlbumMetadata(id: String) async {
        guard let j = try? await SpotifyAPI.shared.albumDetails(id: id) else { return }
        let name = j["name"].string ?? metadata.title
        let artists = j["artists"].array.compactMap { $0["name"].string }.joined(separator: ", ")
        let image = SpotifyMap.image(j["images"]) ?? metadata.coverURL
        var year: String?
        if let date = j["release_date"].string, date.count >= 4 {
            year = String(date.prefix(4))
        }

        metadata = SpotifyPlaylistMetadata(
            title: name,
            description: j["label"].string ?? metadata.description,
            coverURL: image,
            creatorName: artists.isEmpty ? metadata.creatorName : artists,
            creatorAvatarURL: metadata.creatorAvatarURL,
            likesCount: metadata.likesCount,
            isAlbum: true,
            releaseYear: year
        )
    }
}

// MARK: - Main View

struct SpotifyPlaylistDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: SpotifyPlaylistDetailModel
    @ObservedObject private var player = PlayerManager.shared
    @ObservedObject private var library = Library.shared

    @State private var scrollOffsetY: CGFloat = 0
    @State private var isLikedPlaylist = false
    @State private var isShuffle = false
    @State private var isDownloadingAll = false
    @State private var showOptionsActionSheet = false
    @State private var showShareSheet = false
    @AppStorage(Pref.endlessRadioKey) private var isEndlessRadio = true

    // Initializer with playlist ID
    init(playlistId: String, name: String, cover: URL? = nil, subtitle: String = "") {
        let meta = SpotifyPlaylistMetadata(
            title: name,
            description: subtitle,
            coverURL: cover,
            creatorName: "Spotify",
            isAlbum: false
        )
        _model = StateObject(wrappedValue: SpotifyPlaylistDetailModel(metadata: meta, playlistId: playlistId))
    }

    // Initializer with album ID
    init(albumId: String, name: String, cover: URL? = nil, subtitle: String = "") {
        let meta = SpotifyPlaylistMetadata(
            title: name,
            description: subtitle,
            coverURL: cover,
            creatorName: subtitle.isEmpty ? "Nghệ sĩ" : subtitle,
            isAlbum: true
        )
        _model = StateObject(wrappedValue: SpotifyPlaylistDetailModel(metadata: meta, albumId: albumId))
    }

    // Generic initializer with custom loader / metadata
    init(
        title: String,
        cover: URL? = nil,
        subtitle: String = "",
        creator: String = "Spotify",
        likesCount: Int? = nil,
        isAlbum: Bool = false,
        loader: @escaping (Int) async throws -> Page
    ) {
        let meta = SpotifyPlaylistMetadata(
            title: title,
            description: subtitle,
            coverURL: cover,
            creatorName: creator,
            likesCount: likesCount,
            isAlbum: isAlbum
        )
        _model = StateObject(wrappedValue: SpotifyPlaylistDetailModel(metadata: meta, loader: loader))
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Dark Spotify background
            SpotifyTheme.darkBackground.ignoresSafeArea()

            // Dynamic stretchy gradient pinned to top
            stretchyGradientBackground

            // Scrollable Content
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    // Geometry reader offset tracker
                    GeometryReader { geo in
                        let minY = geo.frame(in: .named("SpotifyScroll")).minY
                        Color.clear.preference(key: SpotifyScrollOffsetKey.self, value: minY)
                    }
                    .frame(height: 0)

                    // Large 200x200 Parallax Cover Art
                    artworkHeader
                        .padding(.top, 40)
                        .padding(.bottom, 16)

                    // Metadata Section (Title, Description, Creator, Stats)
                    metadataSection
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)

                    // Main Action Bar (Play 56pt, Heart, Download, Ellipsis, Shuffle)
                    mainActionBar
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)

                    // Track List
                    trackListSection

                    // Recommended Songs Section
                    if !model.tracks.isEmpty {
                        recommendedSongsSection
                    }

                    // Extra bottom padding for floating mini player bar
                    Spacer().frame(height: 110)
                }
            }
            .coordinateSpace(name: "SpotifyScroll")
            .onPreferenceChange(SpotifyScrollOffsetKey.self) { val in
                scrollOffsetY = val
            }

            // Sticky Navigation Bar with back button, fading title, and mini green play button
            stickyNavigationBar
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            if !model.loaded {
                await model.load(reset: true)
            }
        }
        .refreshable {
            await model.load(reset: true)
        }
    }

    // MARK: - Stretchy Ambient Gradient

    private var stretchyGradientBackground: some View {
        let stretch = max(0, scrollOffsetY)
        let gradientHeight: CGFloat = 430 + stretch

        return LinearGradient(
            stops: [
                .init(color: model.dominantColor.opacity(0.88), location: 0.0),
                .init(color: model.dominantColor.opacity(0.55), location: 0.45),
                .init(color: SpotifyTheme.darkBackground.opacity(0.95), location: 0.85),
                .init(color: SpotifyTheme.darkBackground, location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: gradientHeight)
        .offset(y: -stretch)
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
    }

    // MARK: - Artwork Header (Parallax + Stretch)

    private var artworkHeader: some View {
        let stretch = max(0, scrollOffsetY)
        let scale = 1.0 + (stretch / 380.0)
        let translateY = min(0, scrollOffsetY) * 0.28
        let opacity = max(0.0, 1.0 - (-min(0, scrollOffsetY) / 220.0))

        return Color(.secondarySystemFill)
            .frame(width: 200, height: 200)
            .overlay {
                CachedAsyncImage(url: model.metadata.coverURL, targetSize: CGSize(width: 300, height: 300)) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    ZStack {
                        Color(white: 0.2)
                        Image(systemName: model.metadata.isAlbum ? "opticaldisc" : "music.note.list")
                            .font(.system(size: 54, weight: .light))
                            .foregroundStyle(SpotifyTheme.secondaryText)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .shadow(color: Color.black.opacity(0.65), radius: 22, x: 0, y: 12)
            .scaleEffect(scale, anchor: .bottom)
            .offset(y: translateY)
            .opacity(opacity)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Metadata Section

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Playlist / Album Title
            Text(model.metadata.title)
                .font(.title2.bold())
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            // Playlist Description / Subtitle
            if !model.metadata.description.isEmpty {
                Text(model.metadata.description)
                    .font(.subheadline)
                    .foregroundStyle(SpotifyTheme.secondaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Creator Row + Total Stats
            HStack(spacing: 6) {
                // Creator Avatar
                if let avatar = model.metadata.creatorAvatarURL {
                    CachedAsyncImage(url: avatar, targetSize: CGSize(width: 32, height: 32)) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        creatorDefaultAvatar
                    }
                    .frame(width: 22, height: 22)
                    .clipShape(Circle())
                } else {
                    creatorDefaultAvatar
                }

                // Creator Name
                Text(model.metadata.creatorName)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)

                // Dot separator
                Text("•")
                    .font(.caption)
                    .foregroundStyle(SpotifyTheme.secondaryText)

                // Likes / Saves or Year
                if let year = model.metadata.releaseYear {
                    Text(year)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(SpotifyTheme.secondaryText)
                } else if let count = model.metadata.likesCount {
                    Text("\(Fmt.count(count)) lượt lưu")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(SpotifyTheme.secondaryText)
                }

                // Total Duration
                if !model.tracks.isEmpty {
                    Text("•")
                        .font(.caption)
                        .foregroundStyle(SpotifyTheme.secondaryText)

                    Text(formattedTotalDuration)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(SpotifyTheme.secondaryText)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var creatorDefaultAvatar: some View {
        ZStack {
            Circle()
                .fill(SpotifyTheme.green)
            Image(systemName: "dot.radiowaves.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.black)
        }
        .frame(width: 22, height: 22)
    }

    private var formattedTotalDuration: String {
        let totalSecs = model.tracks.compactMap { Fmt.seconds($0.duration) }.reduce(0, +)
        guard totalSecs > 0 else { return "\(model.tracks.count) bài" }
        let hours = Int(totalSecs) / 3600
        let minutes = (Int(totalSecs) % 3600) / 60
        if hours > 0 {
            return "\(hours) giờ \(minutes) phút"
        } else {
            return "\(minutes) phút"
        }
    }

    // MARK: - Main Action Bar

    private var mainActionBar: some View {
        let isPlayingThisPlaylist = isCurrentlyPlayingThisPlaylist

        return HStack(spacing: 20) {
            // 1. Heart / Like Button
            Button {
                togglePlaylistLike()
            } label: {
                Image(systemName: isLikedPlaylist ? "heart.fill" : "heart")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(isLikedPlaylist ? SpotifyTheme.green : SpotifyTheme.secondaryText)
            }
            .buttonStyle(.plain)

            // 2. Download Button
            Button {
                downloadAllTracks()
            } label: {
                Image(systemName: isDownloadingAll ? "arrow.down.circle.fill" : "arrow.down.circle")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(isDownloadingAll ? SpotifyTheme.green : SpotifyTheme.secondaryText)
            }
            .buttonStyle(.plain)

            // 3. Ellipsis Options Menu
            Menu {
                Button {
                    togglePlaylistLike()
                } label: {
                    Label(
                        isLikedPlaylist ? "Xóa khỏi thư viện" : "Thêm vào thư viện",
                        systemImage: isLikedPlaylist ? "heart.slash" : "heart"
                    )
                }

                Button {
                    downloadAllTracks()
                } label: {
                    Label("Tải toàn bộ danh sách", systemImage: "arrow.down.circle")
                }

                Button {
                    playAll(shuffle: true)
                } label: {
                    Label("Trộn bài tất cả", systemImage: "shuffle")
                }

                Button {
                    if let first = model.tracks.first {
                        player.playNext(first)
                    }
                } label: {
                    Label("Phát tiếp theo", systemImage: "text.line.first.and.arrowtriangle.forward")
                }

                if let shareURL = model.tracks.first?.shareURL {
                    ShareLink(item: shareURL) {
                        Label("Chia sẻ playlist", systemImage: "square.and.arrow.up")
                    }
                }

                Button {
                    isEndlessRadio.toggle()
                    UserDefaults.standard.set(isEndlessRadio, forKey: Pref.endlessRadioKey)
                } label: {
                    Label(
                        isEndlessRadio ? "Tắt Endless Radio" : "Bật Endless Radio",
                        systemImage: "dot.radiowaves.left.and.right"
                    )
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(SpotifyTheme.secondaryText)
                    .frame(width: 32, height: 32)
            }

            // 4. Shuffle Toggle Button
            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                    isShuffle.toggle()
                }
                let gen = UIImpactFeedbackGenerator(style: .light)
                gen.impactOccurred()
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "shuffle")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(isShuffle ? SpotifyTheme.green : SpotifyTheme.secondaryText)

                    Circle()
                        .fill(isShuffle ? SpotifyTheme.green : Color.clear)
                        .frame(width: 4, height: 4)
                }
            }
            .buttonStyle(.plain)

            // 5. Endless Radio Quick Toggle Button
            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                    isEndlessRadio.toggle()
                    UserDefaults.standard.set(isEndlessRadio, forKey: Pref.endlessRadioKey)
                }
                let gen = UIImpactFeedbackGenerator(style: .light)
                gen.impactOccurred()
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(isEndlessRadio ? SpotifyTheme.green : SpotifyTheme.secondaryText)

                    Circle()
                        .fill(isEndlessRadio ? SpotifyTheme.green : Color.clear)
                        .frame(width: 4, height: 4)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            // 5. Large 56pt Circular Spotify Green Play Button
            Button {
                togglePlayAll()
            } label: {
                ZStack {
                    Circle()
                        .fill(SpotifyTheme.green)
                        .frame(width: 56, height: 56)
                        .shadow(color: SpotifyTheme.green.opacity(0.4), radius: 10, x: 0, y: 4)

                    Image(systemName: isPlayingThisPlaylist ? "pause.fill" : "play.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.black)
                        .offset(x: isPlayingThisPlaylist ? 0 : 2)
                }
            }
            .buttonStyle(SpotifyScaleButtonStyle())
            .disabled(model.tracks.isEmpty)
        }
    }

    // MARK: - Track List Section

    private var trackListSection: some View {
        LazyVStack(spacing: 0) {
            if model.loading && model.tracks.isEmpty {
                VStack(spacing: 16) {
                    ProgressView()
                        .tint(SpotifyTheme.green)
                        .scaleEffect(1.2)
                    Text("Đang tải danh sách bài hát…")
                        .font(.footnote)
                        .foregroundStyle(SpotifyTheme.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            }

            if let error = model.error, model.tracks.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32))
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(SpotifyTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button {
                        Task { await model.load(reset: true) }
                    } label: {
                        Text("Thử lại")
                            .font(.subheadline.bold())
                            .foregroundStyle(.black)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 10)
                            .background(SpotifyTheme.green, in: Capsule())
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            }

            ForEach(Array(model.tracks.enumerated()), id: \.element.id) { index, track in
                SpotifyTrackRow(
                    index: index + 1,
                    track: track,
                    isPlaying: player.current?.id == track.id,
                    isAlbumMode: model.metadata.isAlbum,
                    onTap: {
                        playTrack(at: index)
                    }
                )
                .onAppear {
                    model.loadMoreIfNeeded(current: track)
                }
            }

            if model.loading && !model.tracks.isEmpty {
                ProgressView()
                    .tint(SpotifyTheme.green)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            }

            if model.loaded && !model.loading && model.error == nil && model.tracks.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "music.note")
                        .font(.system(size: 40))
                        .foregroundStyle(SpotifyTheme.secondaryText)
                    Text("Danh sách bài hát trống")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("Không tìm thấy bài hát nào trong playlist này.")
                        .font(.caption)
                        .foregroundStyle(SpotifyTheme.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 50)
            }
        }
    }

    // MARK: - Recommended Songs Section

    private var recommendedSongsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Subtle Section Divider
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.5)
                .padding(.vertical, 8)

            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text("Bài hát đề xuất")
                    .font(.title3.bold())
                    .foregroundStyle(.white)

                Text("Dựa trên các bài hát trong danh sách phát này")
                    .font(.subheadline)
                    .foregroundStyle(SpotifyTheme.secondaryText)
            }

            // Recommendations List or Loader
            if model.loadingRecommendations && model.recommendedTracks.isEmpty {
                HStack(spacing: 12) {
                    ProgressView().tint(SpotifyTheme.green)
                    Text("Đang tìm bài hát phù hợp...")
                        .font(.footnote)
                        .foregroundStyle(SpotifyTheme.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 16)
            } else {
                VStack(spacing: 8) {
                    ForEach(model.recommendedTracks) { track in
                        recommendedTrackRow(track)
                    }
                }

                // Refresh Recommendations Button
                HStack {
                    Spacer()
                    Button {
                        Task { await model.loadRecommendations(refresh: true) }
                        let gen = UIImpactFeedbackGenerator(style: .light)
                        gen.impactOccurred()
                    } label: {
                        HStack(spacing: 6) {
                            if model.loadingRecommendations {
                                ProgressView().tint(.white).scaleEffect(0.8)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 12, weight: .bold))
                            }
                            Text("LÀM MỚI")
                                .font(.system(size: 11, weight: .heavy))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(
                            Capsule()
                                .stroke(Color.white.opacity(0.35), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.top, 10)
            }

            // Endless Radio Feature Banner
            endlessRadioBanner
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    private func recommendedTrackRow(_ track: Video) -> some View {
        let isAdded = model.addedRecommendedTrackIds.contains(track.id)
        let isCurrent = player.current?.id == track.id

        return HStack(spacing: 12) {
            // Artwork
            CachedAsyncImage(url: track.thumbnail, targetSize: CGSize(width: 48, height: 48)) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Color.gray.opacity(0.2)
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            // Title & Channel
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isCurrent ? SpotifyTheme.green : .white)
                    .lineLimit(1)

                Text(track.channelTitle)
                    .font(.system(size: 13))
                    .foregroundStyle(SpotifyTheme.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                player.play(track)
            }

            Spacer()

            // Add (+) Button
            Button {
                if !isAdded {
                    model.addRecommendedTrack(track)
                }
            } label: {
                if isAdded {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(SpotifyTheme.green)
                } else {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 24))
                        .foregroundStyle(Color.white.opacity(0.75))
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private var endlessRadioBanner: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(SpotifyTheme.green.opacity(0.18))
                    .frame(width: 40, height: 40)

                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(SpotifyTheme.green)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Chế độ Endless Radio")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)

                    Text(isEndlessRadio ? "BẬT" : "TẮT")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(isEndlessRadio ? .black : .white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(isEndlessRadio ? SpotifyTheme.green : Color.white.opacity(0.2), in: Capsule())
                }

                Text("Tự động phát tiếp các bài hát tương tự khi hết playlist")
                    .font(.system(size: 12))
                    .foregroundStyle(SpotifyTheme.secondaryText)
            }

            Spacer()

            Toggle("", isOn: $isEndlessRadio)
                .labelsHidden()
                .tint(SpotifyTheme.green)
                .onChange(of: isEndlessRadio) { val in
                    UserDefaults.standard.set(val, forKey: Pref.endlessRadioKey)
                }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(isEndlessRadio ? SpotifyTheme.green.opacity(0.25) : Color.white.opacity(0.08), lineWidth: 0.8)
                )
        )
        .padding(.top, 12)
    }

    // MARK: - Sticky Top Navigation Bar

    private var stickyNavigationBar: some View {
        let scrollY = -min(0, scrollOffsetY)
        let navOpacity = min(max((scrollY - 140) / 70.0, 0), 1.0)
        let showMiniPlay = scrollY > 280

        return ZStack {
            // Blurred background that fades in on scroll
            Rectangle()
                .fill(SpotifyTheme.darkBackground.opacity(navOpacity * 0.98))
                .overlay {
                    Rectangle()
                        .fill(model.dominantColor.opacity(navOpacity * 0.25))
                }
                .ignoresSafeArea(edges: .top)
                .frame(height: 52)
                .opacity(navOpacity)

            HStack(spacing: 12) {
                // Back Button
                Button {
                    dismiss()
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.black.opacity(0.45))
                            .frame(width: 34, height: 34)

                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)

                // Sticky Title
                Text(model.metadata.title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .opacity(navOpacity)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Mini Green 40pt Play Button (signature Spotify iOS behavior)
                if showMiniPlay {
                    Button {
                        togglePlayAll()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(SpotifyTheme.green)
                                .frame(width: 40, height: 40)
                                .shadow(color: SpotifyTheme.green.opacity(0.3), radius: 6, y: 2)

                            Image(systemName: isCurrentlyPlayingThisPlaylist ? "pause.fill" : "play.fill")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(.black)
                                .offset(x: isCurrentlyPlayingThisPlaylist ? 0 : 1.5)
                        }
                    }
                    .buttonStyle(SpotifyScaleButtonStyle())
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
        }
        .animation(.easeInOut(duration: 0.2), value: showMiniPlay)
    }

    // MARK: - Actions & Helpers

    private var isCurrentlyPlayingThisPlaylist: Bool {
        guard let currentId = player.current?.id else { return false }
        return model.tracks.contains { $0.id == currentId } && player.isPlaying
    }

    private func togglePlayAll() {
        let gen = UIImpactFeedbackGenerator(style: .medium)
        gen.impactOccurred()

        if isCurrentlyPlayingThisPlaylist {
            player.player.pause()
        } else if let currentId = player.current?.id,
                  let match = model.tracks.first(where: { $0.id == currentId }) {
            player.play(match)
        } else {
            playAll(shuffle: isShuffle)
        }
    }

    private func playAll(shuffle: Bool) {
        guard !model.tracks.isEmpty else { return }
        let list = shuffle ? model.tracks.shuffled() : model.tracks
        guard let first = list.first else { return }
        player.play(first, queue: Array(list.dropFirst()))
    }

    private func playTrack(at index: Int) {
        guard model.tracks.indices.contains(index) else { return }
        let track = model.tracks[index]
        let queue: [Video]
        if isShuffle {
            var rest = model.tracks
            rest.remove(at: index)
            queue = rest.shuffled()
        } else {
            queue = Array(model.tracks[(index + 1)...])
        }
        player.play(track, queue: queue)
    }

    private func togglePlaylistLike() {
        let gen = UIImpactFeedbackGenerator(style: .light)
        gen.impactOccurred()
        withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) {
            isLikedPlaylist.toggle()
        }
    }

    private func downloadAllTracks() {
        let gen = UIImpactFeedbackGenerator(style: .medium)
        gen.impactOccurred()
        withAnimation {
            isDownloadingAll.toggle()
        }
        guard isDownloadingAll else { return }
        for track in model.tracks {
            DownloadManager.shared.start(track, audioOnly: true)
        }
    }
}

// MARK: - Spotify Track Row Component

struct SpotifyTrackRow: View {
    let index: Int
    let track: Video
    let isPlaying: Bool
    var isAlbumMode: Bool = false
    let onTap: () -> Void

    @ObservedObject private var player = PlayerManager.shared
    @ObservedObject private var library = Library.shared
    @State private var showRemap = false

    private var isExplicit: Bool {
        let t = track.title.lowercased()
        return t.contains("explicit") || t.contains("[e]") || t.contains("(e)")
    }

    var body: some View {
        Button {
            onTap()
        } label: {
            HStack(spacing: 12) {
                // Leading: 44x44 Cover Thumbnail or Index number
                leadingIndicator

                // Center: Track Title & Artist Line
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(isPlaying ? SpotifyTheme.green : Color.white)
                        .lineLimit(1)

                    HStack(spacing: 5) {
                        // Explicit 'E' Badge
                        if isExplicit {
                            Text("E")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Color.black)
                                .padding(.horizontal, 3.5)
                                .padding(.vertical, 1)
                                .background(SpotifyTheme.secondaryText, in: RoundedRectangle(cornerRadius: 2))
                        }

                        // Artist Name
                        Text(track.channelTitle)
                            .font(.subheadline)
                            .foregroundStyle(SpotifyTheme.secondaryText)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                // Trailing 3-Dots Options Menu
                Menu {
                    Button {
                        library.toggleLike(track)
                    } label: {
                        Label(
                            library.isLiked(track.id) ? "Bỏ thích" : "Thích bài hát",
                            systemImage: library.isLiked(track.id) ? "heart.slash" : "heart"
                        )
                    }

                    Button {
                        player.playNext(track)
                    } label: {
                        Label("Phát tiếp theo", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }

                    Button {
                        player.queue.append(track)
                    } label: {
                        Label("Thêm vào hàng đợi", systemImage: "text.badge.plus")
                    }

                    Menu {
                        Button("Chỉ âm thanh") {
                            DownloadManager.shared.start(track, audioOnly: true)
                        }
                        Button("Video") {
                            DownloadManager.shared.start(track, audioOnly: false)
                        }
                    } label: {
                        Label("Tải xuống", systemImage: "arrow.down.circle")
                    }

                    if track.source == .spotify {
                        Button {
                            showRemap = true
                        } label: {
                            Label("Đổi nguồn âm thanh", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }

                    ShareLink(item: track.shareURL) {
                        Label("Chia sẻ", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(SpotifyTheme.secondaryText)
                        .frame(width: 36, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(isPlaying ? Color.white.opacity(0.04) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(SpotifyRowHighlightButtonStyle())
        .sheet(isPresented: $showRemap) {
            SpotifyRemapSheet(video: track)
        }
    }

    @ViewBuilder
    private var leadingIndicator: some View {
        ZStack {
            // 44x44 Thumbnail
            Color(.secondarySystemFill)
                .frame(width: 44, height: 44)
                .overlay {
                    CachedAsyncImage(url: track.thumbnail, targetSize: CGSize(width: 64, height: 64)) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: "music.note")
                            .font(.caption)
                            .foregroundStyle(SpotifyTheme.secondaryText)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            // Animated Equalizer / Playing Indicator overlay when currently playing
            if isPlaying {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.black.opacity(0.6))
                    Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(SpotifyTheme.green)
                }
                .frame(width: 44, height: 44)
            }
        }
    }
}

// MARK: - Button Styles

private struct SpotifyScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

private struct SpotifyRowHighlightButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.white.opacity(0.08) : Color.clear)
    }
}
