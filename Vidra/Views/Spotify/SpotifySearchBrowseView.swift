import SwiftUI

// MARK: - Color Hex Extension

private extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Spotify Category Model

struct SpotifyCategory: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let colorHex: String
    let searchKeyword: String
    let imageURL: URL?
    let iconName: String

    var color: Color {
        Color(hex: colorHex)
    }

    static let allCategories: [SpotifyCategory] = [
        SpotifyCategory(
            id: "pop",
            title: "Pop",
            colorHex: "#8D67AB",
            searchKeyword: "nhạc Pop hot nhất",
            imageURL: URL(string: "https://images.unsplash.com/photo-1514525253161-7a46d19cd819?w=300&q=80"),
            iconName: "music.mic"
        ),
        SpotifyCategory(
            id: "hip-hop",
            title: "Hip-Hop",
            colorHex: "#BA5D07",
            searchKeyword: "Hip Hop Rap thịnh hành",
            imageURL: URL(string: "https://images.unsplash.com/photo-1508700115892-45ecd05ae2ad?w=300&q=80"),
            iconName: "headphones"
        ),
        SpotifyCategory(
            id: "rock",
            title: "Rock",
            colorHex: "#E91429",
            searchKeyword: "Rock kinh điển",
            imageURL: URL(string: "https://images.unsplash.com/photo-1498038432885-c6f3f1b912ee?w=300&q=80"),
            iconName: "guitars.fill"
        ),
        SpotifyCategory(
            id: "indie",
            title: "Indie",
            colorHex: "#8400E7",
            searchKeyword: "Indie Việt hot",
            imageURL: URL(string: "https://images.unsplash.com/photo-1465847899084-d164df4dedc6?w=300&q=80"),
            iconName: "music.note"
        ),
        SpotifyCategory(
            id: "dance-edm",
            title: "Dance & EDM",
            colorHex: "#006450",
            searchKeyword: "EDM Festival Remix",
            imageURL: URL(string: "https://images.unsplash.com/photo-1470225620780-dba8ba36b745?w=300&q=80"),
            iconName: "waveform"
        ),
        SpotifyCategory(
            id: "chill",
            title: "Chill & Thư giãn",
            colorHex: "#509BF5",
            searchKeyword: "Lofi Chill thư giãn",
            imageURL: URL(string: "https://images.unsplash.com/photo-1511671782779-c97d3d27a1d4?w=300&q=80"),
            iconName: "cup.and.saucer.fill"
        ),
        SpotifyCategory(
            id: "mood",
            title: "Tâm trạng",
            colorHex: "#27856A",
            searchKeyword: "nhạc tâm trạng buồn chill",
            imageURL: URL(string: "https://images.unsplash.com/photo-1518609878373-06d740f60d8b?w=300&q=80"),
            iconName: "heart.fill"
        ),
        SpotifyCategory(
            id: "vpop",
            title: "Nhạc Việt",
            colorHex: "#E13300",
            searchKeyword: "V-Pop thịnh hành",
            imageURL: URL(string: "https://images.unsplash.com/photo-1511735111819-9a3f7709049c?w=300&q=80"),
            iconName: "star.fill"
        ),
        SpotifyCategory(
            id: "charts",
            title: "Bảng xếp hạng",
            colorHex: "#1E3264",
            searchKeyword: "Top 50 ca khúc thịnh hành",
            imageURL: URL(string: "https://images.unsplash.com/photo-1501386761578-eac5c94b800a?w=300&q=80"),
            iconName: "chart.bar.fill"
        ),
        SpotifyCategory(
            id: "podcast",
            title: "Podcast",
            colorHex: "#AF2896",
            searchKeyword: "Podcast Việt Nam",
            imageURL: URL(string: "https://images.unsplash.com/photo-1590602847861-f357a9332bbc?w=300&q=80"),
            iconName: "mic.fill"
        ),
        SpotifyCategory(
            id: "kpop",
            title: "K-Pop",
            colorHex: "#148A08",
            searchKeyword: "K-Pop Hot Hits",
            imageURL: URL(string: "https://images.unsplash.com/photo-1534447677768-be436bb09401?w=300&q=80"),
            iconName: "sparkles"
        ),
        SpotifyCategory(
            id: "rnb",
            title: "R&B",
            colorHex: "#DC148C",
            searchKeyword: "R&B Soul thư giãn",
            imageURL: URL(string: "https://images.unsplash.com/photo-1459749411175-04bf5292ceea?w=300&q=80"),
            iconName: "speaker.wave.3.fill"
        ),
        SpotifyCategory(
            id: "acoustic",
            title: "Acoustic",
            colorHex: "#537AA1",
            searchKeyword: "Acoustic mộc mạc",
            imageURL: URL(string: "https://images.unsplash.com/photo-1510915361894-db8b60106cb1?w=300&q=80"),
            iconName: "guitars"
        ),
        SpotifyCategory(
            id: "focus",
            title: "Focus & Học tập",
            colorHex: "#503750",
            searchKeyword: "Nhạc tập trung làm việc học bài",
            imageURL: URL(string: "https://images.unsplash.com/photo-1434030216411-0b793f4b4173?w=300&q=80"),
            iconName: "brain.head.profile"
        ),
        SpotifyCategory(
            id: "gaming",
            title: "Gaming & Anime",
            colorHex: "#E8115B",
            searchKeyword: "Gaming music Anime OST",
            imageURL: URL(string: "https://images.unsplash.com/photo-1538481199705-c710c4e965fc?w=300&q=80"),
            iconName: "gamecontroller.fill"
        ),
        SpotifyCategory(
            id: "romance",
            title: "Lãng mạn",
            colorHex: "#8C1932",
            searchKeyword: "Nhạc tình yêu lãng mạn",
            imageURL: URL(string: "https://images.unsplash.com/photo-1518895949257-7621c3c786d7?w=300&q=80"),
            iconName: "heart.circle.fill"
        )
    ]
}

// MARK: - Search Filter Pill

enum SpotifySearchFilter: String, CaseIterable, Identifiable {
    case all = "Tất cả"
    case songs = "Bài hát"
    case artists = "Nghệ sĩ"
    case albums = "Album"
    case playlists = "Playlist"

    var id: String { rawValue }
}

// MARK: - Search & Browse ViewModel

@MainActor
final class SpotifySearchBrowseViewModel: ObservableObject {
    @Published var searchText: String = "" {
        didSet {
            scheduleSearch()
        }
    }
    @Published var selectedFilter: SpotifySearchFilter = .all
    @Published var isLoading: Bool = false
    @Published var errorMessage: String? = nil

    @Published var tracks: [Video] = []
    @Published var artists: [SpotifyCard] = []
    @Published var albums: [SpotifyCard] = []
    @Published var playlists: [SpotifyCard] = []
    @Published var isFallbackSearch: Bool = false

    // Top Result calculation
    @Published var topTrack: Video? = nil
    @Published var topArtist: SpotifyCard? = nil

    private var searchTask: Task<Void, Never>? = nil

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isEmptyResult: Bool {
        !isLoading && isSearching && tracks.isEmpty && artists.isEmpty && albums.isEmpty && playlists.isEmpty
    }

    func clear() {
        searchTask?.cancel()
        searchText = ""
        tracks = []
        artists = []
        albums = []
        playlists = []
        topTrack = nil
        topArtist = nil
        errorMessage = nil
        isLoading = false
    }

    func scheduleSearch() {
        searchTask?.cancel()
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            tracks = []
            artists = []
            albums = []
            playlists = []
            topTrack = nil
            topArtist = nil
            errorMessage = nil
            isLoading = false
            return
        }

        searchTask = Task {
            // Debounce 300ms
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await performSearch(query: q)
        }
    }

    func performSearch(query: String) async {
        guard !Task.isCancelled else { return }
        isLoading = true
        errorMessage = nil

        // If Spotify is logged in, try Spotify API first
        if SpotifyAuth.shared.isLoggedIn {
            do {
                let res = try await SpotifyAPI.shared.search(query)
                guard !Task.isCancelled else { return }

                if !res.isEmpty {
                    self.tracks = res.tracks
                    self.artists = res.artists
                    self.albums = res.albums
                    self.playlists = res.playlists
                    self.isFallbackSearch = false

                    // Pick Top Result: If query matches artist closely, prefer artist
                    let cleanQ = query.lowercased()
                    if let firstArt = res.artists.first,
                       firstArt.title.lowercased().contains(cleanQ) || cleanQ.contains(firstArt.title.lowercased()) {
                        self.topArtist = firstArt
                        self.topTrack = nil
                    } else {
                        self.topTrack = res.tracks.first
                        self.topArtist = nil
                    }

                    self.isLoading = false
                    return
                }
            } catch {
                // If cancelled, exit cleanly
                if Task.isCancelled { return }
                // Otherwise fall back to InnerTube musicSearch
            }
        }

        // Fallback / standard music search via InnerTube
        do {
            async let musicTask = InnerTube.shared.musicSearch(query, continuation: nil)
            async let generalTask = try? InnerTube.shared.search(query, params: nil, continuation: nil)
            let page = try await musicTask
            let general = await generalTask
            guard !Task.isCancelled else { return }

            self.isFallbackSearch = true
            self.tracks = page.videos

            let rawChannels = page.channels.isEmpty ? (general?.channels ?? []) : page.channels
            var seenArtists = Set<String>()
            self.artists = rawChannels.compactMap { ch in
                guard seenArtists.insert(ch.id).inserted else { return nil }
                return SpotifyCard(
                    id: ch.id,
                    kind: .artist,
                    title: ch.title,
                    subtitle: ch.subscribers.map { "\($0) người theo dõi" } ?? "Nghệ sĩ",
                    image: ch.avatar
                )
            }

            let rawPlaylists = page.playlists.isEmpty ? (general?.playlists ?? []) : page.playlists
            var seenPlaylists = Set<String>()
            self.playlists = rawPlaylists.compactMap { p in
                guard seenPlaylists.insert(p.id).inserted else { return nil }
                return SpotifyCard(
                    id: p.id,
                    kind: .playlist,
                    title: p.title,
                    subtitle: p.videoCount.map { "\($0) bài hát" } ?? "Playlist",
                    image: p.thumbnail
                )
            }
            self.albums = []

            // Determine top result
            let cleanQ = query.lowercased()
            if let firstArt = self.artists.first,
               firstArt.title.lowercased().contains(cleanQ) || cleanQ.contains(firstArt.title.lowercased()) {
                self.topArtist = firstArt
                self.topTrack = nil
            } else {
                self.topTrack = page.videos.first
                self.topArtist = nil
            }
        } catch {
            if Task.isCancelled { return }
            self.errorMessage = "Không thể tải kết quả: \(error.localizedDescription)"
        }

        self.isLoading = false
    }
}

// MARK: - Spotify Category Card (Authentic Spotify Look)

struct SpotifyCategoryCard: View {
    let category: SpotifyCategory

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Category vibrant background color
            category.color

            // Rotated / tilted thumbnail image cut off at the bottom-right corner
            GeometryReader { geo in
                CachedAsyncImage(url: category.imageURL, targetSize: CGSize(width: 80, height: 80)) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    ZStack {
                        Color.black.opacity(0.2)
                        Image(systemName: category.iconName)
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .frame(width: 68, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .shadow(color: Color.black.opacity(0.38), radius: 6, x: 3, y: 3)
                .rotationEffect(.degrees(24))
                .position(x: geo.size.width - 16, y: geo.size.height - 14)
            }

            // Bold Category Title in white at top-left
            Text(category.title)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .padding(.top, 12)
                .padding(.leading, 12)
                .padding(.trailing, 44) // reserve space so text doesn't overlap tilted image
        }
        .frame(height: 100)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Category Detail View (Browse by Genre)

@MainActor
final class SpotifyCategoryDetailModel: ObservableObject {
    @Published var tracks: [Video] = []
    @Published var isLoading: Bool = false
    @Published var error: String? = nil

    func load(category: SpotifyCategory, force: Bool = false) async {
        guard force || tracks.isEmpty else { return }
        guard !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let page = try await InnerTube.shared.musicSearch(category.searchKeyword, continuation: nil)
            guard !Task.isCancelled else { return }
            self.tracks = page.videos
        } catch {
            guard !(error is CancellationError), !Task.isCancelled else { return }
            if tracks.isEmpty {
                self.error = error.localizedDescription
            }
        }
    }
}

struct SpotifyCategoryDetailView: View {
    let category: SpotifyCategory
    @StateObject private var model = SpotifyCategoryDetailModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Vibrant Gradient Header
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(
                        colors: [
                            category.color.opacity(0.85),
                            category.color.opacity(0.4),
                            Color(red: 0.07, green: 0.07, blue: 0.07)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 220)

                    HStack(alignment: .bottom, spacing: 16) {
                        CachedAsyncImage(url: category.imageURL, targetSize: CGSize(width: 120, height: 120)) { img in
                            img.resizable().scaledToFill()
                        } placeholder: {
                            ZStack {
                                category.color
                                Image(systemName: category.iconName).font(.largeTitle).foregroundStyle(.white)
                            }
                        }
                        .frame(width: 100, height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .shadow(color: Color.black.opacity(0.5), radius: 8, y: 4)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("THỂ LOẠI")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white.opacity(0.7))
                            Text(category.title)
                                .font(.system(size: 28, weight: .bold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }

                // Controls: Play & Shuffle buttons
                HStack(spacing: 16) {
                    Button {
                        if let first = model.tracks.first {
                            PlayerManager.shared.play(first, queue: Array(model.tracks.dropFirst()))
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color(red: 0.11, green: 0.73, blue: 0.33))
                                .frame(width: 52, height: 52)
                                .shadow(color: Color(red: 0.11, green: 0.73, blue: 0.33).opacity(0.4), radius: 8, y: 3)
                            Image(systemName: "play.fill")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(.black)
                                .offset(x: 2)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(model.tracks.isEmpty)

                    Button {
                        let shuffled = model.tracks.shuffled()
                        if let first = shuffled.first {
                            PlayerManager.shared.play(first, queue: Array(shuffled.dropFirst()))
                        }
                    } label: {
                        Image(systemName: "shuffle")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(Color(red: 0.11, green: 0.73, blue: 0.33))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.tracks.isEmpty)

                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

                // Songs List
                if model.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else if let error = model.error {
                    VStack(spacing: 8) {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Thử lại") {
                            Task { await model.load(category: category) }
                        }
                        .tint(Color(red: 0.11, green: 0.73, blue: 0.33))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                } else {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(model.tracks.enumerated()), id: \.element.id) { index, video in
                            SpotifySongRow(
                                video: video,
                                index: index + 1,
                                queue: spotifyRestQueue(model.tracks, after: video)
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
            }
            .padding(.bottom, 40)
        }
        .background(Color(red: 0.07, green: 0.07, blue: 0.07).ignoresSafeArea())
        .navigationTitle(category.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.load(category: category)
        }
        .refreshable {
            await model.load(category: category, force: true)
        }
    }
}

// MARK: - Song Row Component (Spotify Standard with duration & 3-dots menu)

struct SpotifySongRow: View {
    let video: Video
    var index: Int? = nil
    var queue: [Video] = []

    @State private var showRemapSheet: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            // Optional Track Number
            if let index {
                Text("\(index)")
                    .font(.system(size: 14, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 22, alignment: .trailing)
            }

            // Artwork
            CachedAsyncImage(url: video.thumbnail, targetSize: CGSize(width: 64, height: 64)) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                ZStack {
                    Color(red: 0.18, green: 0.18, blue: 0.18)
                    Image(systemName: "music.note")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 46, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            // Title & Artist
            VStack(alignment: .leading, spacing: 3) {
                Text(video.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(video.channelTitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Color(white: 0.65))
                        .lineLimit(1)

                    if let dur = video.duration, !dur.isEmpty {
                        Text("•")
                            .font(.caption2)
                            .foregroundStyle(Color(white: 0.4))
                        Text(dur)
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(Color(white: 0.5))
                    }
                }
            }

            Spacer(minLength: 8)

            // 3-dots Menu Button
            Menu {
                if video.source == .spotify {
                    Button {
                        showRemapSheet = true
                    } label: {
                        Label("Đổi nguồn âm thanh", systemImage: "arrow.triangle.2.circlepath")
                    }
                }

                Button {
                    PlayerManager.shared.playNext(video)
                } label: {
                    Label("Phát tiếp theo", systemImage: "text.line.first.and.arrowtriangle.forward")
                }

                Button {
                    PlayerManager.shared.appendToQueue(video)
                } label: {
                    Label("Thêm vào hàng đợi", systemImage: "text.badge.plus")
                }

                Button {
                    Library.shared.toggleLike(video)
                } label: {
                    Label(
                        Library.shared.isLiked(video.id) ? "Bỏ khỏi Bài hát đã thích" : "Lưu vào Bài hát đã thích",
                        systemImage: Library.shared.isLiked(video.id) ? "heart.fill" : "heart"
                    )
                }

                if !Library.shared.playlists.isEmpty {
                    Menu {
                        ForEach(Library.shared.playlists) { p in
                            Button(p.name) {
                                Library.shared.add(video, to: p.id)
                            }
                        }
                    } label: {
                        Label("Thêm vào danh sách phát", systemImage: "plus.circle")
                    }
                }

                ShareLink(item: video.shareURL) {
                    Label("Chia sẻ", systemImage: "square.and.arrow.up")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16))
                    .foregroundStyle(Color(white: 0.65))
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            PlayerManager.shared.play(video, queue: queue)
        }
        .sheet(isPresented: $showRemapSheet) {
            SpotifyRemapSheet(video: video)
        }
    }
}

// MARK: - Artist Row Component (Spotify Circular Avatar)

struct SpotifyArtistRow: View {
    let card: SpotifyCard

    var body: some View {
        HStack(spacing: 14) {
            CachedAsyncImage(url: card.image, targetSize: CGSize(width: 80, height: 80)) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                ZStack {
                    Color(red: 0.22, green: 0.22, blue: 0.22)
                    Image(systemName: "person.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(width: 54, height: 54)
            .clipShape(Circle())
            .shadow(color: Color.black.opacity(0.3), radius: 4, y: 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(card.title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("Nghệ sĩ")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(white: 0.6))
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(white: 0.35))
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Main View: SpotifySearchBrowseView

struct SpotifySearchBrowseView: View {
    @StateObject private var model = SpotifySearchBrowseViewModel()
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Top Search Bar Section (Fixed prominent Spotify header)
            searchHeaderBar

            // Content Area: Either Search Results or Browse All Grid
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if model.isSearching {
                        searchResultsSection
                    } else {
                        browseCategoriesSection
                    }
                }
                .padding(.bottom, 32)
            }
        }
        .background(Color(red: 0.07, green: 0.07, blue: 0.07).ignoresSafeArea())
        .navigationBarHidden(true)
    }

    // MARK: - Top Search Bar

    private var searchHeaderBar: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Spotify Title Header
            if !isSearchFocused && !model.isSearching {
                HStack {
                    Text("Tìm kiếm")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(.white)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Search Bar Input: Solid white bar with black text (Spotify iOS style)
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.black)

                    TextField("Bạn muốn nghe gì?", text: $model.searchText)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.black)
                        .tint(Color.black)
                        .focused($isSearchFocused)
                        .submitLabel(.search)
                        .autocorrectionDisabled()

                    if !model.searchText.isEmpty {
                        Button {
                            model.clear()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(Color.gray)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Cancel Button when focused / typing
                if isSearchFocused || model.isSearching {
                    Button {
                        isSearchFocused = false
                        model.clear()
                    } label: {
                        Text("Hủy")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 16)
            .animation(.spring(response: 0.28, dampingFraction: 0.8), value: isSearchFocused)
            .animation(.spring(response: 0.28, dampingFraction: 0.8), value: model.isSearching)

            // Filter Pills when user is searching
            if model.isSearching {
                filterPillsBar
            }
        }
        .padding(.bottom, 12)
        .background(Color(red: 0.07, green: 0.07, blue: 0.07))
    }

    // MARK: - Filter Pills

    private var filterPillsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SpotifySearchFilter.allCases) { filter in
                    let isSelected = model.selectedFilter == filter
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            model.selectedFilter = filter
                        }
                    } label: {
                        Text(filter.rawValue)
                            .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                isSelected
                                    ? Color(red: 0.11, green: 0.73, blue: 0.33)
                                    : Color(white: 0.16)
                            )
                            .foregroundStyle(isSelected ? Color.black : Color.white)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Browse All Grid (Khám phá tất cả)

    private var browseCategoriesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Khám phá tất cả")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.top, 6)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 14),
                    GridItem(.flexible(), spacing: 14)
                ],
                spacing: 14
            ) {
                ForEach(SpotifyCategory.allCategories) { category in
                    NavigationLink {
                        SpotifyCategoryDetailView(category: category)
                    } label: {
                        SpotifyCategoryCard(category: category)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Search Results Section

    @ViewBuilder
    private var searchResultsSection: some View {
        if model.isLoading {
            ProgressView()
                .tint(Color(red: 0.11, green: 0.73, blue: 0.33))
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        } else if let error = model.errorMessage {
            VStack(spacing: 8) {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Thử lại") {
                    model.scheduleSearch()
                }
                .tint(Color(red: 0.11, green: 0.73, blue: 0.33))
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
        } else if model.isEmptyResult {
            VStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 44))
                    .foregroundStyle(Color(white: 0.4))
                Text("Không tìm thấy kết quả")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                Text("Hãy kiểm tra lại chính tả hoặc thử tìm kiếm bằng từ khoá khác.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
        } else {
            VStack(alignment: .leading, spacing: 24) {
                switch model.selectedFilter {
                case .all:
                    // 1. Top Result Card
                    topResultCard

                    // 2. Songs Section
                    if !model.tracks.isEmpty {
                        songsSection(limit: 5)
                    }

                    // 3. Artists Section
                    if !model.artists.isEmpty {
                        artistsSection(limit: 4)
                    }

                    // 4. Albums & Playlists
                    if !model.albums.isEmpty {
                        albumsSection
                    }
                    if !model.playlists.isEmpty {
                        playlistsSection
                    }

                case .songs:
                    if model.tracks.isEmpty {
                        emptySectionMessage("Không tìm thấy bài hát phù hợp.")
                    } else {
                        songsSection(limit: nil)
                    }

                case .artists:
                    if model.artists.isEmpty {
                        emptySectionMessage("Không tìm thấy nghệ sĩ phù hợp.")
                    } else {
                        artistsSection(limit: nil)
                    }

                case .albums:
                    if model.albums.isEmpty {
                        emptySectionMessage("Không tìm thấy album phù hợp.")
                    } else {
                        albumsSection
                    }

                case .playlists:
                    if model.playlists.isEmpty {
                        emptySectionMessage("Không tìm thấy playlist phù hợp.")
                    } else {
                        playlistsSection
                    }
                }
            }
            .padding(.top, 6)
        }
    }

    private func emptySectionMessage(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32))
                .foregroundStyle(Color(white: 0.45))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
        .padding(.horizontal, 24)
    }

    // MARK: - Top Result Card (Thẻ Kết quả hàng đầu)

    @ViewBuilder
    private var topResultCard: some View {
        if let track = model.topTrack {
            VStack(alignment: .leading, spacing: 10) {
                Text("Kết quả hàng đầu")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)

                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .center, spacing: 14) {
                        CachedAsyncImage(url: track.thumbnail, targetSize: CGSize(width: 100, height: 100)) { img in
                            img.resizable().scaledToFill()
                        } placeholder: {
                            Color(red: 0.18, green: 0.18, blue: 0.18)
                        }
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .shadow(color: Color.black.opacity(0.4), radius: 6, y: 3)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(track.title)
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.white)
                                .lineLimit(2)

                            HStack(spacing: 6) {
                                Text("BÀI HÁT")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.9))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Color.black.opacity(0.4))
                                    .clipShape(Capsule())

                                Text("•  \(track.channelTitle)")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Color(white: 0.7))
                                    .lineLimit(1)
                            }
                        }

                        Spacer(minLength: 4)

                        // Floating Spotify Green Play Button
                        Button {
                            PlayerManager.shared.play(track, queue: spotifyRestQueue(model.tracks, after: track))
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Color(red: 0.11, green: 0.73, blue: 0.33))
                                    .frame(width: 48, height: 48)
                                    .shadow(color: Color.black.opacity(0.4), radius: 6, y: 3)
                                Image(systemName: "play.fill")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(.black)
                                    .offset(x: 1.5)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(14)
                .background(Color(red: 0.12, green: 0.12, blue: 0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 16)
                .onTapGesture {
                    PlayerManager.shared.play(track, queue: spotifyRestQueue(model.tracks, after: track))
                }
            }
        } else if let artist = model.topArtist {
            VStack(alignment: .leading, spacing: 10) {
                Text("Kết quả hàng đầu")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)

                NavigationLink {
                    artistDestination(artist)
                } label: {
                    HStack(alignment: .center, spacing: 14) {
                        CachedAsyncImage(url: artist.image, targetSize: CGSize(width: 100, height: 100)) { img in
                            img.resizable().scaledToFill()
                        } placeholder: {
                            ZStack {
                                Color(red: 0.22, green: 0.22, blue: 0.22)
                                Image(systemName: "person.fill").foregroundStyle(.white.opacity(0.6))
                            }
                        }
                        .frame(width: 72, height: 72)
                        .clipShape(Circle())
                        .shadow(color: Color.black.opacity(0.4), radius: 6, y: 3)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(artist.title)
                                .font(.system(size: 19, weight: .bold))
                                .foregroundStyle(.white)
                                .lineLimit(1)

                            Text("NGHỆ SĨ")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white.opacity(0.9))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.black.opacity(0.4))
                                .clipShape(Capsule())
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color(white: 0.4))
                    }
                    .padding(14)
                    .background(Color(red: 0.12, green: 0.12, blue: 0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 16)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Songs Section

    private func songsSection(limit: Int?) -> some View {
        let displayTracks: [Video] = {
            if let limit {
                return Array(model.tracks.prefix(limit))
            }
            return model.tracks
        }()

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Bài hát")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)

                Spacer()

                if limit != nil && model.tracks.count > (limit ?? 0) {
                    Button {
                        withAnimation { model.selectedFilter = .songs }
                    } label: {
                        Text("Xem tất cả")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(white: 0.6))
                    }
                }
            }
            .padding(.horizontal, 16)

            LazyVStack(spacing: 4) {
                ForEach(displayTracks) { track in
                    SpotifySongRow(
                        video: track,
                        queue: spotifyRestQueue(model.tracks, after: track)
                    )
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Artists Section

    private func artistsSection(limit: Int?) -> some View {
        let displayArtists: [SpotifyCard] = {
            if let limit {
                return Array(model.artists.prefix(limit))
            }
            return model.artists
        }()

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Nghệ sĩ")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)

                Spacer()

                if limit != nil && model.artists.count > (limit ?? 0) {
                    Button {
                        withAnimation { model.selectedFilter = .artists }
                    } label: {
                        Text("Xem tất cả")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(white: 0.6))
                    }
                }
            }
            .padding(.horizontal, 16)

            LazyVStack(spacing: 6) {
                ForEach(displayArtists) { card in
                    NavigationLink {
                        artistDestination(card)
                    } label: {
                        SpotifyArtistRow(card: card)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Albums Section

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Album")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(model.albums) { card in
                        SpotifyCardLink(card: card, width: 140)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Playlists Section

    private var playlistsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Danh sách phát")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(model.playlists) { card in
                        if model.isFallbackSearch || card.id.hasPrefix("PL") || card.id.hasPrefix("OLAK") || card.id.hasPrefix("RD") {
                            NavigationLink {
                                SpotifyPlaylistDetailView(
                                    title: card.title,
                                    cover: card.image,
                                    subtitle: card.subtitle,
                                    creator: "YouTube Music",
                                    continuationLoader: { token in
                                        try await InnerTube.shared.playlist(card.id, continuation: token)
                                    }
                                )
                            } label: {
                                SpotifyCardView(card: card, width: 140)
                            }
                            .buttonStyle(.plain)
                        } else {
                            SpotifyCardLink(card: card, width: 140)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func artistDestination(_ card: SpotifyCard) -> some View {
        if card.id.hasPrefix("spa:") {
            SpotifyArtistView(artistId: String(card.id.dropFirst(4)), name: card.title)
        } else if !model.isFallbackSearch && SpotifyAuth.shared.isLoggedIn && !card.id.hasPrefix("UC") {
            SpotifyArtistView(artistId: card.id, name: card.title)
        } else if card.id.hasPrefix("UC") {
            ChannelView(channel: Channel(id: card.id, title: card.title, avatar: card.image))
        } else {
            SpotifyPlaylistDetailView(
                title: card.title,
                cover: card.image,
                subtitle: card.subtitle,
                creator: card.title,
                continuationLoader: { token in
                    try await InnerTube.shared.search(card.title, params: nil, continuation: token)
                }
            )
        }
    }
}

// MARK: - Queue Helper

private func spotifyRestQueue(_ list: [Video], after video: Video) -> [Video] {
    guard let i = list.firstIndex(where: { $0.id == video.id }) else { return [] }
    return Array(list[(i + 1)...])
}
