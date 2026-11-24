import SwiftUI

// MARK: - Spotify Design Colors

private extension Color {
    static let spotifyBlack = Color(red: 0.07, green: 0.07, blue: 0.07)       // #121212
    static let spotifyCard = Color(red: 0.16, green: 0.16, blue: 0.16)        // #282828
    static let spotifyCardHover = Color(red: 0.22, green: 0.22, blue: 0.22)   // #383838
    static let spotifyGreen = Color(red: 0.11, green: 0.73, blue: 0.33)       // #1DB954
    static let spotifySubtext = Color(red: 0.70, green: 0.70, blue: 0.70)     // #B3B3B3
}

// MARK: - Models

enum SpotifyFeedKind: Hashable, Sendable {
    case playlist
    case album
    case artist
    case track
}

struct SpotifyQuickItem: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let image: URL?
    let gradient: LinearGradient?
    let systemIcon: String?
    let playlistId: String?
    let isLikedSongs: Bool
    let track: Video?

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: SpotifyQuickItem, rhs: SpotifyQuickItem) -> Bool {
        lhs.id == rhs.id
    }

    init(
        id: String,
        title: String,
        image: URL? = nil,
        gradient: LinearGradient? = nil,
        systemIcon: String? = nil,
        playlistId: String? = nil,
        isLikedSongs: Bool = false,
        track: Video? = nil
    ) {
        self.id = id
        self.title = title
        self.image = image
        self.gradient = gradient
        self.systemIcon = systemIcon
        self.playlistId = playlistId
        self.isLikedSongs = isLikedSongs
        self.track = track
    }
}

struct SpotifyFeedCard: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let image: URL?
    let kind: SpotifyFeedKind
    let playlistId: String?
    let artistId: String?
    let albumId: String?
    let track: Video?

    init(
        id: String,
        title: String,
        subtitle: String,
        image: URL? = nil,
        kind: SpotifyFeedKind = .playlist,
        playlistId: String? = nil,
        artistId: String? = nil,
        albumId: String? = nil,
        track: Video? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.image = image
        self.kind = kind
        self.playlistId = playlistId
        self.artistId = artistId
        self.albumId = albumId
        self.track = track
    }
}

// MARK: - ViewModel

@MainActor
final class SpotifyHomeFeedModel: ObservableObject {
    @Published var quickItems: [SpotifyQuickItem] = []
    @Published var madeForYou: [SpotifyFeedCard] = []
    @Published var recentlyPlayed: [SpotifyFeedCard] = []
    @Published var topCharts: [SpotifyFeedCard] = []
    @Published var popularArtists: [SpotifyFeedCard] = []
    @Published var isLoading = false
    @Published var selectedQuickItemId: String? = nil

    private var hasLoadedOnce = false

    init() {
        buildCuratedQuickItems()
        buildCuratedCarousels()
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        // 1. Build Quick Access items (Liked Songs + Dynamic/Curated Playlists)
        buildQuickItemsFromState()

        // 2. Fetch live data if Spotify account is authenticated
        if SpotifyAuth.shared.isLoggedIn {
            await loadSpotifyUserFeed()
        }

        // 3. Populate Recent from Library history if available
        populateRecentlyPlayedFromLibrary()

        hasLoadedOnce = true
    }

    // MARK: - Quick Items Setup

    private func buildCuratedQuickItems() {
        let likedGradient = LinearGradient(
            colors: [Color(red: 0.28, green: 0.14, blue: 0.65), Color(red: 0.45, green: 0.58, blue: 0.72)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        quickItems = [
            SpotifyQuickItem(
                id: "liked-songs",
                title: "Bài hát đã thích",
                gradient: likedGradient,
                systemIcon: "heart.fill",
                isLikedSongs: true
            ),
            SpotifyQuickItem(
                id: "top-hits-vietnam",
                title: "Top Hits Việt Nam",
                image: URL(string: "https://i.scdn.co/image/ab67706f00000002b8b93eb12b6f10ad95272a2e"),
                playlistId: "37i9dQZF1DX4g8Gs5vgUmY"
            ),
            SpotifyQuickItem(
                id: "todays-top-hits",
                title: "Today's Top Hits",
                image: URL(string: "https://i.scdn.co/image/ab67706f00000002fe24d7084be6aa2288d6cdc6"),
                playlistId: "37i9dQZF1DXcBWIGoYBM5M"
            ),
            SpotifyQuickItem(
                id: "chill-hits",
                title: "Chill Hits",
                image: URL(string: "https://i.scdn.co/image/ab67706f00000002b55b69cf0c9a40538a79ef6e"),
                playlistId: "37i9dQZF1DX4WYpdgoIcn6"
            ),
            SpotifyQuickItem(
                id: "deep-focus",
                title: "Deep Focus",
                image: URL(string: "https://i.scdn.co/image/ab67706f00000002e4eadd417a05b2546e866934"),
                playlistId: "37i9dQZF1DWZeKCadgRdKQ"
            ),
            SpotifyQuickItem(
                id: "discover-weekly",
                title: "Discover Weekly",
                image: URL(string: "https://i.scdn.co/image/ab67706f000000027ea4b505212b9deeb6f42c29"),
                playlistId: "37i9dQZEVXcQ9JaivNaQdX"
            )
        ]
    }

    private func buildQuickItemsFromState() {
        buildCuratedQuickItems()

        // Check if user has personal Spotify playlists or history items to replace placeholders
        if !Library.shared.history.isEmpty {
            var items = quickItems
            let recentTracks = Library.shared.history.prefix(2).map(\.video)
            for (idx, v) in recentTracks.enumerated() {
                let targetIndex = 4 + idx
                if targetIndex < items.count {
                    items[targetIndex] = SpotifyQuickItem(
                        id: "history-\(v.id)",
                        title: v.title,
                        image: v.thumbnail,
                        track: v
                    )
                }
            }
            quickItems = items
        }
    }

    // MARK: - Carousels Setup

    private func buildCuratedCarousels() {
        // "Dành cho bạn" (Made For You)
        madeForYou = [
            SpotifyFeedCard(
                id: "daily-mix-1",
                title: "Daily Mix 1",
                subtitle: "Sơn Tùng M-TP, Vũ., GREY D và nhiều hơn nữa",
                image: URL(string: "https://images.unsplash.com/photo-1511671782779-c97d3d27a1d4?w=500&auto=format&fit=crop&q=60"),
                kind: .playlist,
                playlistId: "37i9dQZF1E36rW21zOcv1r"
            ),
            SpotifyFeedCard(
                id: "daily-mix-2",
                title: "Daily Mix 2",
                subtitle: "Chillies, Ngọt, Thịnh Suy và hơn thế nữa",
                image: URL(string: "https://images.unsplash.com/photo-1470225620780-dba8ba36b745?w=500&auto=format&fit=crop&q=60"),
                kind: .playlist,
                playlistId: "37i9dQZF1E35CqZq2k9a8b"
            ),
            SpotifyFeedCard(
                id: "daily-mix-3",
                title: "Daily Mix 3",
                subtitle: "Taylor Swift, Billie Eilish, Sabrina Carpenter",
                image: URL(string: "https://images.unsplash.com/photo-1514525253161-7a46d19cd819?w=500&auto=format&fit=crop&q=60"),
                kind: .playlist,
                playlistId: "37i9dQZF1E38g4h6k8m0n2"
            ),
            SpotifyFeedCard(
                id: "discover-weekly-card",
                title: "Khám phá hàng tuần",
                subtitle: "Bản phối bài hát mới tinh chỉnh theo gu của bạn mỗi thứ Hai.",
                image: URL(string: "https://i.scdn.co/image/ab67706f000000027ea4b505212b9deeb6f42c29"),
                kind: .playlist,
                playlistId: "37i9dQZEVXcQ9JaivNaQdX"
            ),
            SpotifyFeedCard(
                id: "release-radar",
                title: "Radar Phát hành",
                subtitle: "Đón nhận những ca khúc mới nhất từ nghệ sĩ bạn theo dõi.",
                image: URL(string: "https://images.unsplash.com/photo-1498038432885-c6f3f1b912ee?w=500&auto=format&fit=crop&q=60"),
                kind: .playlist,
                playlistId: "37i9dQZEVXbo6pC7KjQ7xQ"
            )
        ]

        // "Đã phát gần đây" (Recently Played fallback)
        recentlyPlayed = [
            SpotifyFeedCard(
                id: "recent-1",
                title: "Đừng Làm Trái Tim Anh Đau",
                subtitle: "Đĩa đơn • Sơn Tùng M-TP",
                image: URL(string: "https://i.scdn.co/image/ab67616d0000b2737604f3ae5d5543c7b6c507c5"),
                kind: .track,
                track: Video(
                    id: "sp:dunglamtraitimanhdau",
                    title: "Đừng Làm Trái Tim Anh Đau",
                    channelTitle: "Sơn Tùng M-TP",
                    duration: "05:14",
                    source: .spotify,
                    artwork: URL(string: "https://i.scdn.co/image/ab67616d0000b2737604f3ae5d5543c7b6c507c5")
                )
            ),
            SpotifyFeedCard(
                id: "recent-2",
                title: "Chúng Ta Của Tương Lai",
                subtitle: "Đĩa đơn • Sơn Tùng M-TP",
                image: URL(string: "https://i.scdn.co/image/ab67616d0000b27367803625709cf932c02c98d6"),
                kind: .track,
                track: Video(
                    id: "sp:chungtacuatuonglai",
                    title: "Chúng Ta Của Tương Lai",
                    channelTitle: "Sơn Tùng M-TP",
                    duration: "04:12",
                    source: .spotify,
                    artwork: URL(string: "https://i.scdn.co/image/ab67616d0000b27367803625709cf932c02c98d6")
                )
            ),
            SpotifyFeedCard(
                id: "recent-3",
                title: "Từng Quen",
                subtitle: "Đĩa đơn • Wren Evans",
                image: URL(string: "https://i.scdn.co/image/ab67616d0000b2734e5a953e5361099e2f099c27"),
                kind: .track,
                track: Video(
                    id: "sp:tungquen",
                    title: "Từng Quen",
                    channelTitle: "Wren Evans",
                    duration: "02:56",
                    source: .spotify,
                    artwork: URL(string: "https://i.scdn.co/image/ab67616d0000b2734e5a953e5361099e2f099c27")
                )
            ),
            SpotifyFeedCard(
                id: "recent-4",
                title: "Sau Lời Từ Khước",
                subtitle: "OST Mai • Phan Mạnh Quỳnh",
                image: URL(string: "https://i.scdn.co/image/ab67616d0000b2730b7a86f91d84f88e3678b0f4"),
                kind: .track,
                track: Video(
                    id: "sp:sauloitukhuc",
                    title: "Sau Lời Từ Khước",
                    channelTitle: "Phan Mạnh Quỳnh",
                    duration: "03:45",
                    source: .spotify,
                    artwork: URL(string: "https://i.scdn.co/image/ab67616d0000b2730b7a86f91d84f88e3678b0f4")
                )
            ),
            SpotifyFeedCard(
                id: "recent-5",
                title: "Lạ Lùng",
                subtitle: "Vũ.",
                image: URL(string: "https://i.scdn.co/image/ab67616d0000b273934dca9505ba49626e6d19e9"),
                kind: .track,
                track: Video(
                    id: "sp:lalung",
                    title: "Lạ Lùng",
                    channelTitle: "Vũ.",
                    duration: "04:21",
                    source: .spotify,
                    artwork: URL(string: "https://i.scdn.co/image/ab67616d0000b273934dca9505ba49626e6d19e9")
                )
            )
        ]

        // "Bảng xếp hạng hàng đầu" (Top Charts)
        topCharts = [
            SpotifyFeedCard(
                id: "chart-vn-50",
                title: "Top 50 - Việt Nam",
                subtitle: "Bản cập nhật hàng ngày các bài hát được nghe nhiều nhất",
                image: URL(string: "https://charts-images.scdn.co/assets/locale_en/regional/daily/region_vn_default.jpg"),
                kind: .playlist,
                playlistId: "37i9dQZEVXbLdGJwSPpHGv"
            ),
            SpotifyFeedCard(
                id: "chart-global-50",
                title: "Top 50 - Toàn cầu",
                subtitle: "Cập nhật hàng ngày ca khúc phổ biến nhất thế giới",
                image: URL(string: "https://charts-images.scdn.co/assets/locale_en/regional/daily/region_global_default.jpg"),
                kind: .playlist,
                playlistId: "37i9dQZEVXbMDoHDwVN2tF"
            ),
            SpotifyFeedCard(
                id: "chart-viral-vn",
                title: "Top Bài Hát Viral - Việt Nam",
                subtitle: "Những ca khúc đang lan truyền mạnh mẽ nhất hiện nay",
                image: URL(string: "https://charts-images.scdn.co/assets/locale_en/viral/daily/region_vn_default.jpg"),
                kind: .playlist,
                playlistId: "37i9dQZEVXbKZ46OFpmOFv"
            ),
            SpotifyFeedCard(
                id: "chart-us-50",
                title: "Top 50 - Hoa Kỳ",
                subtitle: "Bảng xếp hạng các ca khúc thịnh hành tại Mỹ",
                image: URL(string: "https://charts-images.scdn.co/assets/locale_en/regional/daily/region_us_default.jpg"),
                kind: .playlist,
                playlistId: "37i9dQZEVXbLRQDuF5jeBp"
            ),
            SpotifyFeedCard(
                id: "chart-global-albums",
                title: "Top Albums - Toàn cầu",
                subtitle: "Các album thịnh hành nhất toàn cầu tuần này",
                image: URL(string: "https://charts-images.scdn.co/assets/locale_en/albums/weekly/region_global_default.jpg"),
                kind: .playlist,
                playlistId: "37i9dQZEVXbJGoaP3T48oh"
            )
        ]

        // "Nghệ sĩ phổ biến" (Popular Artists)
        popularArtists = [
            SpotifyFeedCard(
                id: "artist-sontung",
                title: "Sơn Tùng M-TP",
                subtitle: "Nghệ sĩ",
                image: URL(string: "https://i.scdn.co/image/ab6761610000e5ebc636f1837ff9373e97034c44"),
                kind: .artist,
                artistId: "57byqZ0bYvCq2k8WnNqXU6"
            ),
            SpotifyFeedCard(
                id: "artist-vu",
                title: "Vũ.",
                subtitle: "Nghệ sĩ",
                image: URL(string: "https://i.scdn.co/image/ab6761610000e5eb1dca889f0a59bc8fb03a4c1d"),
                kind: .artist,
                artistId: "5Xl4U9j8V6d483XWfH04uF"
            ),
            SpotifyFeedCard(
                id: "artist-den",
                title: "Đen",
                subtitle: "Nghệ sĩ",
                image: URL(string: "https://i.scdn.co/image/ab6761610000e5eb604439c63dae8df2617f0525"),
                kind: .artist,
                artistId: "1B8W2vE2n6h2G1u3t2e2f3"
            ),
            SpotifyFeedCard(
                id: "artist-hieuthuhai",
                title: "HIEUTHUHAI",
                subtitle: "Nghệ sĩ",
                image: URL(string: "https://i.scdn.co/image/ab6761610000e5eb542031cba37b19dc6e8cb4fa"),
                kind: .artist,
                artistId: "7s7Q4vA3p2F3j5k6l7m8n9"
            ),
            SpotifyFeedCard(
                id: "artist-taylor",
                title: "Taylor Swift",
                subtitle: "Nghệ sĩ",
                image: URL(string: "https://i.scdn.co/image/ab6761610000e5ebd703d1eec84aa0418e6e5819"),
                kind: .artist,
                artistId: "06HL4z0CvFAxyc27GXpf02"
            ),
            SpotifyFeedCard(
                id: "artist-billie",
                title: "Billie Eilish",
                subtitle: "Nghệ sĩ",
                image: URL(string: "https://i.scdn.co/image/ab6761610000e5ebb53820a440156d64d9942a03"),
                kind: .artist,
                artistId: "6qqNVTkY8uBg9cP3Jd7DAH"
            ),
            SpotifyFeedCard(
                id: "artist-theweeknd",
                title: "The Weeknd",
                subtitle: "Nghệ sĩ",
                image: URL(string: "https://i.scdn.co/image/ab6761610000e5eb214f3cf1cbe7139c1e26ff77"),
                kind: .artist,
                artistId: "1Xyo4u8uXC1ZmMpatF05PJ"
            )
        ]
    }

    // MARK: - Live Spotify Fetch

    private func loadSpotifyUserFeed() async {
        do {
            async let rRecent = SpotifyAPI.shared.recentlyPlayed()
            async let rPlaylists = SpotifyAPI.shared.myPlaylists()
            async let rTop = SpotifyAPI.shared.topTracks()
            async let rArtists = SpotifyAPI.shared.followedArtists()

            let (recentVideos, userPlaylists, topPage, followed) = try await (rRecent, rPlaylists, rTop, rArtists)

            if !recentVideos.isEmpty {
                recentlyPlayed = recentVideos.prefix(8).map { v in
                    SpotifyFeedCard(
                        id: v.id,
                        title: v.title,
                        subtitle: v.channelTitle,
                        image: v.thumbnail,
                        kind: .track,
                        track: v
                    )
                }
            }

            if !userPlaylists.cards.isEmpty {
                let cards = userPlaylists.cards.prefix(4).map { c in
                    SpotifyFeedCard(
                        id: c.id,
                        title: c.title,
                        subtitle: c.subtitle,
                        image: c.image,
                        kind: .playlist,
                        playlistId: c.id
                    )
                }
                madeForYou = cards + madeForYou
            }

            if !followed.cards.isEmpty {
                let userArtists = followed.cards.map { c in
                    SpotifyFeedCard(
                        id: c.id,
                        title: c.title,
                        subtitle: "Nghệ sĩ",
                        image: c.image,
                        kind: .artist,
                        artistId: c.id
                    )
                }
                popularArtists = userArtists + popularArtists
            }

            _ = topPage
        } catch {
            // Keep curated items gracefully on network or rate limit errors
        }
    }

    private func populateRecentlyPlayedFromLibrary() {
        guard !Library.shared.history.isEmpty, recentlyPlayed.count <= 5 else { return }
        let libRecent = Library.shared.history.prefix(6).map { item in
            SpotifyFeedCard(
                id: item.video.id,
                title: item.video.title,
                subtitle: item.video.channelTitle,
                image: item.video.thumbnail,
                kind: .track,
                track: item.video
            )
        }
        recentlyPlayed = libRecent
    }

    // MARK: - Playback Triggers

    func playQuickItem(_ item: SpotifyQuickItem) {
        selectedQuickItemId = item.id

        if let track = item.track {
            PlayerManager.shared.play(track)
            return
        }

        if item.isLikedSongs {
            if !Library.shared.likedTracks.isEmpty {
                let tracks = Library.shared.likedTracks
                if let first = tracks.first {
                    PlayerManager.shared.play(first, queue: Array(tracks.dropFirst()))
                }
            } else {
                Task {
                    if let liked = try? await SpotifyAPI.shared.likedSongs(), !liked.videos.isEmpty {
                        PlayerManager.shared.play(liked.videos[0], queue: Array(liked.videos.dropFirst()))
                    } else {
                        // Play a fallback top hit
                        playFallbackSong(title: "Bài hát đã thích")
                    }
                }
            }
            return
        }

        if let playlistId = item.playlistId {
            Task {
                if let page = try? await SpotifyAPI.shared.playlistTracks(id: playlistId), !page.videos.isEmpty {
                    PlayerManager.shared.play(page.videos[0], queue: Array(page.videos.dropFirst()))
                } else {
                    playFallbackSong(title: item.title)
                }
            }
        }
    }

    func playFeedCard(_ card: SpotifyFeedCard) {
        if let track = card.track {
            PlayerManager.shared.play(track)
            return
        }

        if let playlistId = card.playlistId {
            Task {
                if let page = try? await SpotifyAPI.shared.playlistTracks(id: playlistId), !page.videos.isEmpty {
                    PlayerManager.shared.play(page.videos[0], queue: Array(page.videos.dropFirst()))
                } else {
                    playFallbackSong(title: card.title)
                }
            }
            return
        }

        if let artistId = card.artistId {
            Task {
                if let top = try? await SpotifyAPI.shared.artistTopTracks(id: artistId), !top.isEmpty {
                    PlayerManager.shared.play(top[0], queue: Array(top.dropFirst()))
                } else {
                    playFallbackSong(title: card.title)
                }
            }
            return
        }

        playFallbackSong(title: card.title)
    }

    private func playFallbackSong(title: String) {
        Task {
            if let search = try? await InnerTube.shared.musicSearch(title, continuation: nil),
               let first = search.videos.first {
                PlayerManager.shared.play(first, queue: Array(search.videos.dropFirst()))
            }
        }
    }
}

// MARK: - Main Home Feed View

struct SpotifyHomeFeedView: View {
    @StateObject private var model = SpotifyHomeFeedModel()
    @ObservedObject private var auth = SpotifyAuth.shared
    @State private var libraryFilter: SpotifyLibraryFilter? = nil
    @State private var librarySort: SpotifyLibrarySort = .recentPlayed
    @State private var showLoginSheet = false

    private var greetingText: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:
            return "Chào buổi sáng"
        case 12..<18:
            return "Chào buổi chiều"
        default:
            return "Chào buổi tối"
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.spotifyBlack
                .ignoresSafeArea()

            // Top ambient atmosphere gradient
            LinearGradient(
                colors: [
                    Color(red: 0.16, green: 0.28, blue: 0.22).opacity(0.85),
                    Color(red: 0.10, green: 0.14, blue: 0.12).opacity(0.50),
                    Color.spotifyBlack
                ],
                startPoint: .top,
                endPoint: .init(x: 0.5, y: 0.35)
            )
            .ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    // 1. Top Bar & Filter Chips
                    topHeaderSection

                    // 2. Greeting & Top Action Buttons
                    greetingHeaderSection

                    // 2.1 Banner đăng nhập khi chưa kết nối Spotify
                    if !auth.isLoggedIn {
                        spotifyLoginBanner
                    }

                    // 3. Quick Access Grid (2 columns x 3 rows)
                    quickAccessGridSection

                    // 3.1 Your Library Shelf & Quick Filter
                    yourLibrarySection

                    // 4. Horizontal Carousels
                    madeForYouCarouselSection
                    recentlyPlayedCarouselSection
                    topChartsCarouselSection
                    popularArtistsCarouselSection

                    // Bottom safe spacer
                    Spacer(minLength: 40)
                }
                .padding(.bottom, 24)
            }
            .refreshable {
                await model.load()
            }
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $showLoginSheet) {
            NavigationStack {
                SpotifySetupView()
                    .navigationTitle("Đăng nhập Spotify")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Đóng") {
                                showLoginSheet = false
                            }
                        }
                    }
            }
        }
        .task {
            await auth.loadProfile()
            await model.load()
        }
        .onChange(of: auth.isLoggedIn) { loggedIn in
            if loggedIn {
                Task {
                    await auth.loadProfile()
                    await model.load()
                }
            }
        }
    }

    // MARK: - Login Banner

    private var spotifyLoginBanner: some View {
        Button {
            showLoginSheet = true
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.spotifyGreen)
                        .frame(width: 44, height: 44)
                    Image(systemName: "music.note")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.black)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Đăng nhập tài khoản Spotify")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Đồng bộ bài hát yêu thích, playlist và nghệ sĩ của bạn")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.spotifySubtext)
                        .lineLimit(1)
                }

                Spacer()

                Text("Kết nối")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.spotifyGreen)
                    .foregroundStyle(.black)
                    .clipShape(Capsule())
            }
            .padding(12)
            .background(Color.spotifyCard)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.spotifyGreen.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }

    // MARK: - Header Sections

    private var topHeaderSection: some View {
        HStack(spacing: 8) {
            // Profile Avatar / Login Button
            if auth.isLoggedIn {
                NavigationLink {
                    SpotifyLibraryView()
                } label: {
                    if let img = auth.profile?.image {
                        CachedAsyncImage(url: img, targetSize: CGSize(width: 48, height: 48)) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.white)
                        }
                        .frame(width: 34, height: 34)
                        .clipShape(Circle())
                    } else {
                        ZStack {
                            Circle()
                                .fill(Color(red: 0.35, green: 0.20, blue: 0.45))
                                .frame(width: 34, height: 34)
                            Text(String(auth.profile?.name.prefix(1) ?? "S"))
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    showLoginSheet = true
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.spotifyCard)
                            .frame(width: 34, height: 34)
                        Image(systemName: "person.badge.plus")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.spotifyGreen)
                    }
                }
                .buttonStyle(.plain)
            }

            // Quick Filter Chips: "Tất cả", "Playlists", "Nghệ sĩ", "Albums", "Đã tải xuống"
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    let isAllSelected = libraryFilter == nil
                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                            libraryFilter = nil
                        }
                    } label: {
                        Text("Tất cả")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                Capsule()
                                    .fill(isAllSelected ? Color.spotifyGreen : Color.spotifyCard)
                            )
                            .foregroundStyle(isAllSelected ? Color.black : Color.white)
                    }
                    .buttonStyle(.plain)

                    ForEach(SpotifyLibraryFilter.allCases) { filter in
                        let isSelected = libraryFilter == filter
                        Button {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                                if libraryFilter == filter {
                                    libraryFilter = nil
                                } else {
                                    libraryFilter = filter
                                }
                            }
                        } label: {
                            Text(filter.rawValue)
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(
                                    Capsule()
                                        .fill(isSelected ? Color.spotifyGreen : Color.spotifyCard)
                                )
                                .foregroundStyle(isSelected ? Color.black : Color.white)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.leading, 4)

            // Sort Menu: "Mới phát gần đây", "Mới thêm gần đây", "Thứ tự A-Z"
            Menu {
                ForEach(SpotifyLibrarySort.allCases) { sort in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            librarySort = sort
                        }
                    } label: {
                        if librarySort == sort {
                            Label(sort.rawValue, systemImage: "checkmark")
                        } else {
                            Text(sort.rawValue)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 10, weight: .bold))
                    Text(librarySort.rawValue)
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(Color.spotifySubtext)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.spotifyCard, in: Capsule())
            }

            Spacer(minLength: 2)

            // Nút chuyển lại chế độ YouTube
            AppModeSwitchPill()
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private var greetingHeaderSection: some View {
        HStack {
            Text(greetingText)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)

            Spacer()

            HStack(spacing: 16) {
                Button {
                    // Notification center action
                } label: {
                    Image(systemName: "bell")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(.white)
                }

                Button {
                    // History quick shortcut
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(.white)
                }

                NavigationLink {
                    SettingsView()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    // MARK: - Quick Access Grid (2 cols x 3 rows)

    private var quickAccessGridSection: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8)
            ],
            spacing: 8
        ) {
            ForEach(model.quickItems) { item in
                SpotifyQuickAccessCard(
                    item: item,
                    isSelected: model.selectedQuickItemId == item.id,
                    onPlay: {
                        model.playQuickItem(item)
                    },
                    onTap: {
                        model.selectedQuickItemId = item.id
                    }
                )
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Library Quick Filter & Shelf

    private var yourLibrarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with Title, Sort Menu, and View All link
            HStack {
                Text("Thư viện của bạn")
                    .font(.title2.bold())
                    .foregroundStyle(.white)

                Spacer()

                // Sort Dropdown Menu
                Menu {
                    ForEach(SpotifyLibrarySort.allCases) { sort in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                librarySort = sort
                            }
                        } label: {
                            if librarySort == sort {
                                Label(sort.rawValue, systemImage: "checkmark")
                            } else {
                                Text(sort.rawValue)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 11, weight: .bold))
                        Text(librarySort.rawValue)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.spotifyCard, in: Capsule())
                }

                NavigationLink {
                    SpotifyLibraryView(initialFilter: libraryFilter)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.spotifySubtext)
                        .padding(.leading, 4)
                }
            }
            .padding(.horizontal, 16)

            // Quick Filter Chips row
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if libraryFilter != nil {
                        Button {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                                libraryFilter = nil
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .bold))
                                Text("Tất cả")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.spotifyCard))
                            .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                    }

                    ForEach(SpotifyLibraryFilter.allCases) { filter in
                        let isSelected = (libraryFilter == filter)
                        Button {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                                if libraryFilter == filter {
                                    libraryFilter = nil
                                } else {
                                    libraryFilter = filter
                                }
                            }
                        } label: {
                            Text(filter.rawValue)
                                .font(.system(size: 12, weight: isSelected ? .bold : .semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule()
                                        .fill(isSelected ? Color.spotifyGreen : Color.spotifyCard)
                                )
                                .foregroundStyle(isSelected ? Color.black : Color.white)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }

            // Horizontal Carousel of Sorted Items
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    // Pinned Liked Songs Card (if playlists or all)
                    if libraryFilter == nil || libraryFilter == .playlists {
                        NavigationLink {
                            SpotifyPlaylistDetailView(
                                title: "Bài hát đã thích",
                                subtitle: "Thư viện bài hát yêu thích của bạn",
                                creator: auth.profile?.name ?? "Bạn",
                                likesCount: Library.shared.likedTracks.count,
                                loader: { offset in
                                    if auth.isLoggedIn {
                                        return try await SpotifyAPI.shared.likedSongs(offset: offset)
                                    } else {
                                        let all = Library.shared.likedTracks
                                        let slice = Array(all.dropFirst(offset).prefix(50))
                                        return Page(videos: slice, continuation: offset + 50 < all.count ? "\(offset + 50)" : nil)
                                    }
                                }
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                ZStack {
                                    LinearGradient(
                                        colors: [Color(red: 0.28, green: 0.14, blue: 0.65), Color(red: 0.45, green: 0.58, blue: 0.72)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                    Image(systemName: "heart.fill")
                                        .font(.system(size: 32, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                                .frame(width: 130, height: 130)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Bài hát đã thích")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    Text("\(Library.shared.likedTracks.count) bài hát")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.spotifySubtext)
                                }
                                .frame(width: 130, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    // Pinned Downloaded Songs Card (if downloaded or all)
                    if libraryFilter == nil || libraryFilter == .downloaded {
                        NavigationLink {
                            SpotifyPlaylistDetailView(
                                title: "Đã tải xuống",
                                subtitle: "Các bài hát ngoại tuyến trên thiết bị",
                                creator: "Vidra Ngoại Tuyến",
                                likesCount: DownloadManager.shared.items.count,
                                loader: { offset in
                                    let all = DownloadManager.shared.items.map(\.video)
                                    let slice = Array(all.dropFirst(offset).prefix(50))
                                    return Page(videos: slice, continuation: offset + 50 < all.count ? "\(offset + 50)" : nil)
                                }
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                ZStack {
                                    LinearGradient(
                                        colors: [Color(red: 0.08, green: 0.35, blue: 0.22), Color(red: 0.11, green: 0.73, blue: 0.33)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                    Image(systemName: "arrow.down.circle.fill")
                                        .font(.system(size: 32, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                                .frame(width: 130, height: 130)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Đã tải xuống")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    Text("\(DownloadManager.shared.items.count) bài hát")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.spotifySubtext)
                                }
                                .frame(width: 130, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    // Playlists
                    if libraryFilter == nil || libraryFilter == .playlists {
                        ForEach(homeSortedPlaylists) { playlist in
                            NavigationLink {
                                SpotifyPlaylistDetailView(
                                    title: playlist.name,
                                    subtitle: "Danh sách phát của bạn",
                                    creator: "Bạn",
                                    likesCount: playlist.videos.count,
                                    loader: { offset in
                                        let all = playlist.videos
                                        let slice = Array(all.dropFirst(offset).prefix(50))
                                        return Page(videos: slice, continuation: offset + 50 < all.count ? "\(offset + 50)" : nil)
                                    }
                                )
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    ZStack {
                                        Color.spotifyCard
                                        if let firstThumb = playlist.videos.first?.thumbnail {
                                            CachedAsyncImage(url: firstThumb, targetSize: CGSize(width: 260, height: 260)) { img in
                                                img.resizable().scaledToFill()
                                            } placeholder: {
                                                Color.spotifyDarkGray
                                            }
                                        } else {
                                            Image(systemName: "music.note.list")
                                                .font(.system(size: 28))
                                                .foregroundStyle(Color.spotifySubtext)
                                        }
                                    }
                                    .frame(width: 130, height: 130)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(playlist.name)
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(.white)
                                            .lineLimit(1)
                                        Text("Playlist • \(playlist.videos.count) bài")
                                            .font(.system(size: 11))
                                            .foregroundStyle(Color.spotifySubtext)
                                    }
                                    .frame(width: 130, alignment: .leading)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Artists
                    if libraryFilter == nil || libraryFilter == .artists {
                        ForEach(homeSortedArtists) { channel in
                            NavigationLink {
                                SpotifyPlaylistDetailView(
                                    title: channel.title,
                                    cover: channel.avatar,
                                    subtitle: "Nghệ sĩ",
                                    creator: channel.title,
                                    loader: { offset in
                                        try await InnerTube.shared.search(channel.title, params: nil, continuation: offset > 0 ? "\(offset)" : nil)
                                    }
                                )
                            } label: {
                                VStack(alignment: .center, spacing: 8) {
                                    Avatar(url: channel.avatar, name: channel.title, size: 130)
                                        .clipShape(Circle())

                                    VStack(alignment: .center, spacing: 2) {
                                        Text(channel.title)
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(.white)
                                            .lineLimit(1)
                                        Text("Nghệ sĩ")
                                            .font(.system(size: 11))
                                            .foregroundStyle(Color.spotifySubtext)
                                    }
                                    .frame(width: 130)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Albums
                    if libraryFilter == nil || libraryFilter == .albums {
                        ForEach(homeSortedAlbums) { album in
                            NavigationLink {
                                SpotifyPlaylistDetailView(
                                    albumId: album.id,
                                    name: album.title,
                                    cover: album.image,
                                    subtitle: album.subtitle
                                )
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    ZStack {
                                        Color.spotifyCard
                                        if let img = album.image {
                                            CachedAsyncImage(url: img, targetSize: CGSize(width: 260, height: 260)) { i in
                                                i.resizable().scaledToFill()
                                            } placeholder: {
                                                Color.spotifyDarkGray
                                            }
                                        } else {
                                            Image(systemName: "opticaldisc")
                                                .font(.system(size: 28))
                                                .foregroundStyle(Color.spotifySubtext)
                                        }
                                    }
                                    .frame(width: 130, height: 130)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(album.title)
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(.white)
                                            .lineLimit(1)
                                        Text("Album • \(album.subtitle.isEmpty ? "Nghệ sĩ" : album.subtitle)")
                                            .font(.system(size: 11))
                                            .foregroundStyle(Color.spotifySubtext)
                                            .lineLimit(1)
                                    }
                                    .frame(width: 130, alignment: .leading)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Downloaded Tracks (if filtered to downloaded)
                    if libraryFilter == .downloaded {
                        ForEach(homeSortedDownloads) { item in
                            Button {
                                PlayerManager.shared.play(item.video, queue: homeSortedDownloads.map(\.video))
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    ZStack {
                                        Color.spotifyCard
                                        if let thumb = item.video.thumbnail {
                                            CachedAsyncImage(url: thumb, targetSize: CGSize(width: 260, height: 260)) { img in
                                                img.resizable().scaledToFill()
                                            } placeholder: {
                                                Color.spotifyDarkGray
                                            }
                                        } else {
                                            Image(systemName: "arrow.down.circle")
                                                .font(.system(size: 28))
                                                .foregroundStyle(Color.spotifySubtext)
                                        }
                                    }
                                    .frame(width: 130, height: 130)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.video.title)
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(.white)
                                            .lineLimit(1)
                                        Text(item.video.channelTitle)
                                            .font(.system(size: 11))
                                            .foregroundStyle(Color.spotifySubtext)
                                            .lineLimit(1)
                                    }
                                    .frame(width: 130, alignment: .leading)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Link to Full Library
                    NavigationLink {
                        SpotifyLibraryView(initialFilter: libraryFilter)
                    } label: {
                        VStack(alignment: .center, spacing: 8) {
                            ZStack {
                                Color.spotifyCard
                                Image(systemName: "arrow.right.circle.fill")
                                    .font(.system(size: 32))
                                    .foregroundStyle(Color.spotifyGreen)
                            }
                            .frame(width: 130, height: 130)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                            Text("Mở Thư viện")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var homeSortedPlaylists: [LocalPlaylist] {
        let list = Library.shared.playlists
        switch librarySort {
        case .recentPlayed:
            let historyIds = Library.shared.history.map(\.video.id)
            return list.sorted { p1, p2 in
                let idx1 = p1.videos.compactMap { historyIds.firstIndex(of: $0.id) }.min() ?? Int.max
                let idx2 = p2.videos.compactMap { historyIds.firstIndex(of: $0.id) }.min() ?? Int.max
                if idx1 != idx2 { return idx1 < idx2 }
                return p1.name.localizedCompare(p2.name) == .orderedAscending
            }
        case .recentlyAdded:
            return list
        case .alphabetical:
            return list.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        }
    }

    private var homeSortedArtists: [Channel] {
        let list = Library.shared.subscriptions
        switch librarySort {
        case .recentPlayed:
            let historyChannelIds = Library.shared.history.compactMap(\.video.channelId)
            let historyChannelTitles = Library.shared.history.map(\.video.channelTitle)
            return list.sorted { c1, c2 in
                let idx1 = historyChannelIds.firstIndex(of: c1.id) ?? historyChannelTitles.firstIndex(of: c1.title) ?? Int.max
                let idx2 = historyChannelIds.firstIndex(of: c2.id) ?? historyChannelTitles.firstIndex(of: c2.title) ?? Int.max
                if idx1 != idx2 { return idx1 < idx2 }
                return c1.title.localizedCompare(c2.title) == .orderedAscending
            }
        case .recentlyAdded:
            return list
        case .alphabetical:
            return list.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        }
    }

    private var homeSortedAlbums: [SpotifyCard] {
        let grouped = Dictionary(grouping: Library.shared.likedTracks.filter { !($0.published ?? "").isEmpty }) { $0.published ?? "" }
        let list = grouped.compactMap { (albumName, tracks) -> SpotifyCard? in
            guard !albumName.isEmpty, let first = tracks.first else { return nil }
            return SpotifyCard(
                id: "local_album_\(albumName)",
                kind: .album,
                title: albumName,
                subtitle: first.channelTitle,
                image: first.thumbnail
            )
        }
        switch librarySort {
        case .recentPlayed:
            let historyTitles = Library.shared.history.map(\.video.title)
            return list.sorted { a1, a2 in
                let idx1 = historyTitles.firstIndex(where: { $0.localizedCaseInsensitiveContains(a1.title) }) ?? Int.max
                let idx2 = historyTitles.firstIndex(where: { $0.localizedCaseInsensitiveContains(a2.title) }) ?? Int.max
                if idx1 != idx2 { return idx1 < idx2 }
                return a1.title.localizedCompare(a2.title) == .orderedAscending
            }
        case .recentlyAdded:
            return list
        case .alphabetical:
            return list.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        }
    }

    private var homeSortedDownloads: [DownloadItem] {
        let list = DownloadManager.shared.items
        switch librarySort {
        case .recentPlayed:
            let historyIds = Library.shared.history.map(\.video.id)
            return list.sorted { d1, d2 in
                let idx1 = historyIds.firstIndex(of: d1.video.id) ?? Int.max
                let idx2 = historyIds.firstIndex(of: d2.video.id) ?? Int.max
                if idx1 != idx2 { return idx1 < idx2 }
                return d1.video.title.localizedCompare(d2.video.title) == .orderedAscending
            }
        case .recentlyAdded:
            return Array(list.reversed())
        case .alphabetical:
            return list.sorted { $0.video.title.localizedCompare($1.video.title) == .orderedAscending }
        }
    }

    // MARK: - Carousels

    private var madeForYouCarouselSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dành cho bạn")
                .font(.title2.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(model.madeForYou) { card in
                        NavigationLink {
                            destinationForCard(card)
                        } label: {
                            SpotifySquareCardView(
                                card: card,
                                onPlayTap: { model.playFeedCard(card) }
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var recentlyPlayedCarouselSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Đã phát gần đây")
                .font(.title2.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(model.recentlyPlayed) { card in
                        NavigationLink {
                            destinationForCard(card)
                        } label: {
                            SpotifySquareCardView(
                                card: card,
                                onPlayTap: { model.playFeedCard(card) }
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var topChartsCarouselSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bảng xếp hạng hàng đầu")
                .font(.title2.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(model.topCharts) { card in
                        NavigationLink {
                            destinationForCard(card)
                        } label: {
                            SpotifySquareCardView(
                                card: card,
                                onPlayTap: { model.playFeedCard(card) }
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var popularArtistsCarouselSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nghệ sĩ phổ biến")
                .font(.title2.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(model.popularArtists) { card in
                        NavigationLink {
                            destinationForCard(card)
                        } label: {
                            SpotifyArtistCircleCardView(
                                card: card,
                                onPlayTap: { model.playFeedCard(card) }
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Navigation Destination Builder

    @ViewBuilder
    private func destinationForCard(_ card: SpotifyFeedCard) -> some View {
        switch card.kind {
        case .playlist:
            SpotifyPlaylistDetailView(
                playlistId: card.playlistId ?? card.id,
                name: card.title,
                cover: card.image,
                subtitle: card.subtitle
            )
        case .album:
            SpotifyAlbumView(
                albumId: card.albumId ?? card.id,
                name: card.title,
                cover: card.image,
                subtitle: card.subtitle
            )
        case .artist:
            SpotifyArtistView(
                artistId: card.artistId ?? card.id,
                name: card.title
            )
        case .track:
            if let track = card.track {
                SpotifyTrackDetailWrapperView(track: track)
            } else {
                SpotifyPlaylistDetailView(
                    playlistId: card.id,
                    name: card.title,
                    cover: card.image,
                    subtitle: card.subtitle
                )
            }
        }
    }
}

// MARK: - Quick Access Card View (56x56 art, 4pt corners, #282828 background)

struct SpotifyQuickAccessCard: View {
    let item: SpotifyQuickItem
    let isSelected: Bool
    let onPlay: () -> Void
    let onTap: () -> Void

    var body: some View {
        NavigationLink {
            destination
        } label: {
            HStack(spacing: 0) {
                // Artwork 56x56
                ZStack {
                    if let gradient = item.gradient {
                        Rectangle()
                            .fill(gradient)
                        if let icon = item.systemIcon {
                            Image(systemName: icon)
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    } else if let url = item.image {
                        CachedAsyncImage(url: url, targetSize: CGSize(width: 112, height: 112)) { img in
                            img.resizable().scaledToFill()
                        } placeholder: {
                            Color.spotifyDarkGray
                                .overlay(
                                    Image(systemName: "music.note")
                                        .font(.title3)
                                        .foregroundStyle(Color.spotifySubtext)
                                )
                        }
                    } else {
                        Color.spotifyDarkGray
                            .overlay(
                                Image(systemName: "music.note.list")
                                    .font(.title3)
                                    .foregroundStyle(Color.spotifySubtext)
                            )
                    }
                }
                .frame(width: 56, height: 56)
                .clipped()

                // Title
                Text(item.title)
                    .font(.footnote.bold())
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 10)

                Spacer(minLength: 0)

                // Play Button (Always visible on selection or tap)
                Button {
                    onPlay()
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.spotifyGreen)
                            .frame(width: 32, height: 32)
                            .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 2)
                        Image(systemName: "play.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.black)
                            .offset(x: 1)
                    }
                }
                .padding(.trailing, 8)
                .opacity(isSelected ? 1.0 : 0.0)
                .animation(.easeInOut(duration: 0.18), value: isSelected)
            }
            .frame(height: 56)
            .background(Color.spotifyCard)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture().onEnded {
            onTap()
        })
    }

    @ViewBuilder
    private var destination: some View {
        if item.isLikedSongs {
            SpotifyPlaylistDetailView(
                title: "Bài hát đã thích",
                subtitle: "\(Library.shared.likedTracks.count) bài hát",
                creator: "Bạn",
                likesCount: Library.shared.likedTracks.count,
                loader: { offset in
                    if SpotifyAuth.shared.isLoggedIn {
                        return try await SpotifyAPI.shared.likedSongs(offset: offset)
                    } else {
                        let all = Library.shared.likedTracks
                        let slice = Array(all.dropFirst(offset).prefix(50))
                        return Page(videos: slice, continuation: offset + 50 < all.count ? "\(offset + 50)" : nil)
                    }
                }
            )
        } else if let track = item.track {
            SpotifyTrackDetailWrapperView(track: track)
        } else {
            SpotifyPlaylistDetailView(
                playlistId: item.playlistId ?? item.id,
                name: item.title,
                cover: item.image,
                subtitle: "Playlist Spotify"
            )
        }
    }
}

// MARK: - Square Carousel Card View (148x148, 4pt corners)

struct SpotifySquareCardView: View {
    let card: SpotifyFeedCard
    let onPlayTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Square Cover Art
            ZStack(alignment: .bottomTrailing) {
                Color.spotifyDarkGray
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        if let url = card.image {
                            CachedAsyncImage(url: url, targetSize: CGSize(width: 200, height: 200)) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Image(systemName: "music.note")
                                    .font(.largeTitle)
                                    .foregroundStyle(Color.spotifySubtext)
                            }
                        } else {
                            Image(systemName: "music.note")
                                .font(.largeTitle)
                                .foregroundStyle(Color.spotifySubtext)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                // Green Play Button Overlay
                Button {
                    onPlayTap()
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.spotifyGreen)
                            .frame(width: 38, height: 38)
                            .shadow(color: .black.opacity(0.4), radius: 4, x: 0, y: 2)
                        Image(systemName: "play.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.black)
                            .offset(x: 1)
                    }
                }
                .padding(8)
            }
            .frame(width: 148, height: 148)

            // Title
            Text(card.title)
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: 148, alignment: .leading)

            // Subtitle
            if !card.subtitle.isEmpty {
                Text(card.subtitle)
                    .font(.caption)
                    .foregroundStyle(Color.spotifySubtext)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: 148, alignment: .leading)
            }
        }
        .frame(width: 148)
        .contentShape(Rectangle())
    }
}

// MARK: - Circular Artist Card View

struct SpotifyArtistCircleCardView: View {
    let card: SpotifyFeedCard
    let onPlayTap: () -> Void

    var body: some View {
        VStack(alignment: .center, spacing: 8) {
            // Circular Avatar
            ZStack(alignment: .bottomTrailing) {
                Color.spotifyDarkGray
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        if let url = card.image {
                            CachedAsyncImage(url: url, targetSize: CGSize(width: 140, height: 140)) { img in
                                img.resizable().scaledToFill()
                            } placeholder: {
                                Image(systemName: "person.fill")
                                    .font(.system(size: 44))
                                    .foregroundStyle(Color.spotifySubtext)
                            }
                        } else {
                            Image(systemName: "person.fill")
                                .font(.system(size: 44))
                                .foregroundStyle(Color.spotifySubtext)
                        }
                    }
                    .clipShape(Circle())
            }
            .frame(width: 136, height: 136)

            // Artist Name
            Text(card.title)
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .lineLimit(1)
                .multilineTextAlignment(.center)
                .frame(width: 136)

            // Subtitle
            Text(card.subtitle.isEmpty ? "Nghệ sĩ" : card.subtitle)
                .font(.caption)
                .foregroundStyle(Color.spotifySubtext)
                .lineLimit(1)
                .multilineTextAlignment(.center)
                .frame(width: 136)
        }
        .frame(width: 136)
        .contentShape(Rectangle())
    }
}

// MARK: - Track Detail Wrapper (When clicking a single track)

private struct SpotifyTrackDetailWrapperView: View {
    let track: Video

    var body: some View {
        VStack(spacing: 20) {
            Color.spotifyDarkGray
                .frame(width: 220, height: 220)
                .overlay {
                    CachedAsyncImage(url: track.thumbnail, targetSize: CGSize(width: 250, height: 250)) {
                        $0.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: "music.note").font(.system(size: 60)).foregroundStyle(.secondary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(radius: 12, y: 6)
                .padding(.top, 40)

            VStack(spacing: 4) {
                Text(track.title)
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text(track.channelTitle)
                    .font(.subheadline)
                    .foregroundStyle(Color.spotifySubtext)
            }
            .padding(.horizontal)

            Button {
                PlayerManager.shared.play(track)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                        .font(.headline)
                    Text("Phát ngay")
                        .font(.headline)
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 32)
                .padding(.vertical, 14)
                .background(Capsule().fill(Color.spotifyGreen))
            }
            .padding(.top, 8)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.spotifyBlack.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
    }
}


