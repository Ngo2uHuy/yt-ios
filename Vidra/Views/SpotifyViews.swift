import SwiftUI

// MARK: - Helpers

private func spotifyRun<T>(_ op: @escaping () async throws -> T) async -> Result<T, Error> {
    do {
        return .success(try await op())
    } catch {
        return .failure(error)
    }
}

private func spotifyIsCancelled(_ error: Error) -> Bool {
    Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
}

private func spotifyRest(_ list: [Video], after video: Video) -> [Video] {
    guard let i = list.firstIndex(where: { $0.id == video.id }) else { return [] }
    return Array(list[(i + 1)...])
}

// MARK: - Entry point

struct SpotifyHomeView: View {
    let query: String
    @ObservedObject private var auth = SpotifyAuth.shared

    var body: some View {
        if auth.isLoggedIn {
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if q.isEmpty {
                SpotifyLibraryView()
            } else {
                SpotifySearchView(query: q).id(q)
            }
        } else {
            SpotifySetupView()
        }
    }
}

// MARK: - Setup / login

struct SpotifySetupView: View {
    var showModeSwitch: Bool = false
    @ObservedObject private var auth = SpotifyAuth.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if showModeSwitch {
                    HStack {
                        Text("Thư viện Spotify").font(.title2.bold())
                        Spacer()
                        AppModeSwitchPill()
                    }
                    .padding(.bottom, 4)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Kết nối Spotify").font(.title2.bold())
                    Text("Đồng bộ thư viện, playlist và phát nhạc trực tiếp chất lượng cao qua Spotify App Remote (hoặc nguồn âm thanh thay thế).")
                        .font(.subheadline).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Cách lấy Client ID (miễn phí)").font(.headline)
                    HStack(alignment: .top, spacing: 6) {
                        Text("1.")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Mở trang dashboard và đăng nhập:")
                            if let url = URL(string: "https://developer.spotify.com/dashboard") {
                                Link("developer.spotify.com/dashboard", destination: url)
                            }
                        }
                    }
                    step("2.", "Nhấn \"Create app\", đặt tên bất kỳ.")
                    HStack(alignment: .top, spacing: 6) {
                        Text("3.")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Ở mục Redirect URI nhập đúng:")
                            Text(SpotifyAuth.redirectURI)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    step("4.", "Tick chọn \"Web API\" rồi lưu.")
                    step("5.", "Vào Settings, sao chép Client ID và dán vào ô bên dưới.")
                    step("6.", "App ở Development Mode: vào User Management, thêm email tài khoản Spotify của bạn.")
                }
                .font(.subheadline)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))

                HStack(spacing: 8) {
                    TextField("Client ID", text: $auth.clientId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if let clip = UIPasteboard.general.string, !clip.isEmpty, clip != auth.clientId {
                        Button("Dán") {
                            auth.clientId = clip.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        .font(.subheadline.bold())
                        .tint(.green)
                    }
                }
                .padding(12)
                .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 10))

                Button {
                    Task { await auth.login() }
                } label: {
                    HStack {
                        if auth.isWorking { ProgressView() }
                        Text("Đăng nhập Spotify").font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(auth.isWorking || auth.clientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if let error = auth.error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }

                Divider()

                NavigationLink {
                    SpotifyImportView()
                } label: {
                    Label("Nhập playlist bằng link (không cần đăng nhập)", systemImage: "link")
                        .font(.subheadline)
                }
            }
            .padding()
        }
        .onChange(of: auth.isLoggedIn) { loggedIn in
            if loggedIn {
                dismiss()
            }
        }
    }

    private func step(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(number)
            Text(text)
        }
    }
}

// MARK: - Library home

@MainActor
final class SpotifyLibraryModel: ObservableObject {
    @Published var liked: [Video] = []
    @Published var playlists: [SpotifyCard] = []
    @Published var albums: [SpotifyCard] = []
    @Published var artists: [SpotifyCard] = []
    @Published var top: [Video] = []
    @Published var recent: [Video] = []
    @Published var releases: [SpotifyCard] = []
    @Published var loading = false
    @Published var loaded = false
    @Published var error: String?

    private var failure: String?
    private var cancelled = false

    private func take<T>(_ result: Result<T, Error>) -> T? {
        switch result {
        case .success(let value):
            return value
        case .failure(let e):
            if spotifyIsCancelled(e) {
                cancelled = true
            } else if failure == nil {
                failure = e.localizedDescription
            }
            return nil
        }
    }

    func load() async {
        guard !loading else { return }
        loading = true
        error = nil
        failure = nil
        cancelled = false

        async let rLiked = spotifyRun { try await SpotifyAPI.shared.likedSongs() }
        async let rPlaylists = spotifyRun { try await SpotifyAPI.shared.myPlaylists() }
        async let rAlbums = spotifyRun { try await SpotifyAPI.shared.savedAlbums() }
        async let rArtists = spotifyRun { try await SpotifyAPI.shared.followedArtists() }
        async let rTop = spotifyRun { try await SpotifyAPI.shared.topTracks() }
        async let rRecent = spotifyRun { try await SpotifyAPI.shared.recentlyPlayed() }
        async let rReleases = spotifyRun { try await SpotifyAPI.shared.newReleases() }

        if let p = take(await rLiked) { liked = p.videos }
        if let l = take(await rPlaylists) { playlists = l.cards }
        if let l = take(await rAlbums) { albums = l.cards }
        if let l = take(await rArtists) { artists = l.cards }
        if let p = take(await rTop) { top = p.videos }
        if let v = take(await rRecent) { recent = v }
        if let l = take(await rReleases) { releases = l.cards }

        let empty = liked.isEmpty && playlists.isEmpty && albums.isEmpty && artists.isEmpty
            && top.isEmpty && recent.isEmpty && releases.isEmpty
        if empty { error = failure }
        loading = false
        // Stay unloaded when cancelled (e.g. while navigating away) so the next appearance retries.
        loaded = !cancelled
    }
}

// MARK: - Spotify Library Filter & Sort Models

enum SpotifyLibraryFilter: String, CaseIterable, Identifiable, Sendable {
    case playlists = "Playlists"
    case artists = "Nghệ sĩ"
    case albums = "Albums"
    case downloaded = "Đã tải xuống"

    var id: String { rawValue }
}

enum SpotifyLibrarySort: String, CaseIterable, Identifiable, Sendable {
    case recentPlayed = "Mới phát gần đây"
    case recentlyAdded = "Mới thêm gần đây"
    case alphabetical = "Thứ tự A-Z"

    var id: String { rawValue }
}

// MARK: - Authentic Spotify Your Library View

struct SpotifyLibraryView: View {
    @ObservedObject private var auth = SpotifyAuth.shared
    @ObservedObject private var lib = Library.shared
    @ObservedObject private var dl = DownloadManager.shared
    @StateObject private var model = SpotifyLibraryModel()

    @State private var selectedFilter: SpotifyLibraryFilter?
    @State private var isGridView: Bool = false
    @State private var sortOption: SpotifyLibrarySort = .recentPlayed
    @State private var searchQuery: String = ""
    @State private var isSearchActive: Bool = false

    @State private var showNewPlaylistAlert: Bool = false
    @State private var newPlaylistName: String = ""
    @State private var showSpotifyConnect: Bool = false
    @State private var showImportSheet: Bool = false

    init(initialFilter: SpotifyLibraryFilter? = nil) {
        _selectedFilter = State(initialValue: initialFilter)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                // 1. Top Header: User Profile, Title, Search, "+", Mode Switch
                libraryHeader

                // 2. Search Bar (when toggled)
                if isSearchActive {
                    librarySearchBar
                }

                // 3. Filter Chips: "Tất cả", "Playlists", "Bài hát đã thích", "Nghệ sĩ", "Đã tải xuống"
                filterChipsRow

                // 4. Sort & Layout Bar
                sortAndLayoutToolbar

                // 5. Library Content (List or Grid)
                if isGridView {
                    gridLayoutContent
                } else {
                    listLayoutContent
                }

                // 6. Spotify Account Sync Banner (If not logged in, non-blocking)
                if !auth.isLoggedIn {
                    spotifySyncBanner
                }
            }
            .padding(.bottom, 36)
        }
        .background(SpotifyColor.background.ignoresSafeArea())
        .task {
            if auth.isLoggedIn {
                await auth.loadProfile()
                if !model.loaded { await model.load() }
            }
        }
        .refreshable {
            if auth.isLoggedIn {
                await model.load()
            }
        }
        .sheet(isPresented: $showSpotifyConnect) {
            SpotifySetupView(showModeSwitch: false)
        }
        .sheet(isPresented: $showImportSheet) {
            SpotifyImportView()
        }
        .alert("Tạo danh sách phát mới", isPresented: $showNewPlaylistAlert) {
            TextField("Tên danh sách phát", text: $newPlaylistName)
            Button("Tạo") {
                let trimmed = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    lib.createPlaylist(trimmed)
                    newPlaylistName = ""
                }
            }
            Button("Hủy", role: .cancel) {
                newPlaylistName = ""
            }
        } message: {
            Text("Nhập tên cho danh sách phát Spotify mới của bạn.")
        }
    }

    // MARK: - 1. Top Header

    private var libraryHeader: some View {
        HStack(spacing: 12) {
            // User Avatar
            Button {
                if auth.isLoggedIn {
                    showSpotifyConnect = true
                } else {
                    showSpotifyConnect = true
                }
            } label: {
                if let img = auth.profile?.image {
                    CachedAsyncImage(url: img, targetSize: CGSize(width: 34, height: 34)) { $0.resizable().scaledToFill() } placeholder: {
                        avatarPlaceholder
                    }
                    .frame(width: 34, height: 34)
                    .clipShape(Circle())
                } else {
                    avatarPlaceholder
                }
            }
            .buttonStyle(.plain)

            // Title
            Text("Thư viện")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(SpotifyColor.textPrimary)

            Spacer()

            // Search Icon Button
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                    isSearchActive.toggle()
                    if !isSearchActive { searchQuery = "" }
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(SpotifyColor.textPrimary)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)

            // Plus Icon Button (New Playlist)
            Button {
                showNewPlaylistAlert = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundColor(SpotifyColor.textPrimary)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)

            // Quick App Mode Switch Pill
            AppModeSwitchPill()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var avatarPlaceholder: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.28, green: 0.14, blue: 0.65), Color(red: 0.11, green: 0.73, blue: 0.33)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .frame(width: 34, height: 34)
            .clipShape(Circle())

            Text(String(auth.profile?.name.prefix(1) ?? "V"))
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
        }
    }

    // MARK: - 2. Search Bar

    private var librarySearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(SpotifyColor.textSecondary)

            TextField("Tìm kiếm trong Thư viện", text: $searchQuery)
                .foregroundColor(SpotifyColor.textPrimary)
                .font(.system(size: 14))

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(SpotifyColor.textSecondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(SpotifyColor.surfaceHighlight, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
    }

    // MARK: - 3. Filter Chips

    private var filterChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if selectedFilter != nil {
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                            selectedFilter = nil
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .bold))
                            Text("Tất cả")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(SpotifyColor.surfaceHighlight))
                        .foregroundColor(SpotifyColor.textPrimary)
                    }
                    .buttonStyle(.plain)
                }

                ForEach(SpotifyLibraryFilter.allCases) { filter in
                    let isSelected = selectedFilter == filter
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                            if selectedFilter == filter {
                                selectedFilter = nil
                            } else {
                                selectedFilter = filter
                            }
                        }
                    } label: {
                        Text(filter.rawValue)
                            .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                Capsule()
                                    .fill(isSelected ? SpotifyColor.brandGreen : SpotifyColor.surfaceHighlight)
                            )
                            .foregroundColor(isSelected ? .black : SpotifyColor.textPrimary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }

    // MARK: - 4. Sort & Layout Bar

    private var sortAndLayoutToolbar: some View {
        HStack {
            // Sort Dropdown
            Menu {
                ForEach(SpotifyLibrarySort.allCases) { sort in
                    Button {
                        sortOption = sort
                    } label: {
                        if sortOption == sort {
                            Label(sort.rawValue, systemImage: "checkmark")
                        } else {
                            Text(sort.rawValue)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 12, weight: .bold))
                    Text(sortOption.rawValue)
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(SpotifyColor.textPrimary)
            }

            Spacer()

            // Grid vs List Toggle
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                    isGridView.toggle()
                }
            } label: {
                Image(systemName: isGridView ? "rectangle.grid.2x2" : "list.bullet")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(SpotifyColor.textPrimary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
    }

    // MARK: - 5. List Layout Content

    private var listLayoutContent: some View {
        VStack(spacing: 12) {
            // 1. Pinned: Liked Songs ("Bài hát đã thích")
            if shouldShowLikedSongs {
                NavigationLink {
                    SpotifyPlaylistDetailView(
                        title: "Bài hát đã thích",
                        subtitle: "Thư viện bài hát yêu thích của bạn",
                        creator: auth.profile?.name ?? "Bạn",
                        likesCount: lib.likedTracks.count,
                        loader: { offset in
                            if auth.isLoggedIn {
                                return try await SpotifyAPI.shared.likedSongs(offset: offset)
                            } else {
                                let all = lib.likedTracks
                                let slice = Array(all.dropFirst(offset).prefix(50))
                                return Page(videos: slice, continuation: offset + 50 < all.count ? "\(offset + 50)" : nil)
                            }
                        }
                    )
                } label: {
                    HStack(spacing: 14) {
                        // Purple Gradient Square with White Heart
                        ZStack {
                            LinearGradient(
                                colors: [Color(red: 0.28, green: 0.14, blue: 0.65), Color(red: 0.45, green: 0.58, blue: 0.72)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            Image(systemName: "heart.fill")
                                .font(.system(size: 22))
                                .foregroundColor(.white)
                        }
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Bài hát đã thích")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(SpotifyColor.textPrimary)

                            HStack(spacing: 4) {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(SpotifyColor.brandGreen)
                                Text("Playlist • \(lib.likedTracks.count) bài hát")
                                    .font(.system(size: 13))
                                    .foregroundColor(SpotifyColor.textSecondary)
                            }
                        }

                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            // 2. Pinned: Downloaded Songs ("Đã tải xuống")
            if shouldShowDownloaded {
                NavigationLink {
                    SpotifyPlaylistDetailView(
                        title: "Đã tải xuống",
                        subtitle: "Các bài hát ngoại tuyến trên thiết bị",
                        creator: "Vidra Ngoại Tuyến",
                        likesCount: dl.items.count,
                        loader: { offset in
                            let all = dl.items.map(\.video)
                            let slice = Array(all.dropFirst(offset).prefix(50))
                            return Page(videos: slice, continuation: offset + 50 < all.count ? "\(offset + 50)" : nil)
                        }
                    )
                } label: {
                    HStack(spacing: 14) {
                        // Green Gradient Square with Download Arrow
                        ZStack {
                            LinearGradient(
                                colors: [Color(red: 0.08, green: 0.35, blue: 0.22), Color(red: 0.11, green: 0.73, blue: 0.33)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.white)
                        }
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Đã tải xuống")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(SpotifyColor.textPrimary)

                            HStack(spacing: 4) {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(SpotifyColor.brandGreen)
                                Text("Ngoại tuyến • \(dl.items.count) bài hát")
                                    .font(.system(size: 13))
                                    .foregroundColor(SpotifyColor.textSecondary)
                            }
                        }

                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // When specifically filtered to "Đã tải xuống", list individual downloaded songs
                if selectedFilter == .downloaded && !filteredDownloads.isEmpty {
                    ForEach(filteredDownloads) { item in
                        Button {
                            PlayerManager.shared.play(item.video, queue: filteredDownloads.map(\.video))
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    Color.spotifyDarkGray
                                    if let thumb = item.video.thumbnail {
                                        CachedAsyncImage(url: thumb, targetSize: CGSize(width: 48, height: 48)) { $0.resizable().scaledToFill() } placeholder: {
                                            Color.clear
                                        }
                                    } else {
                                        Image(systemName: "arrow.down.circle")
                                            .foregroundColor(SpotifyColor.textSecondary)
                                    }
                                }
                                .frame(width: 48, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.video.title)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(SpotifyColor.textPrimary)
                                        .lineLimit(1)
                                    Text(item.video.channelTitle)
                                        .font(.system(size: 12))
                                        .foregroundColor(SpotifyColor.textSecondary)
                                        .lineLimit(1)
                                }

                                Spacer()

                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.system(size: 15))
                                    .foregroundColor(SpotifyColor.brandGreen)
                            }
                            .padding(.horizontal, 16)
                            .padding(.leading, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // 3. User Local Playlists
            if shouldShowPlaylists {
                ForEach(filteredPlaylists) { playlist in
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
                        HStack(spacing: 14) {
                            ZStack {
                                SpotifyColor.surfaceHighlight
                                if let firstThumb = playlist.videos.first?.thumbnail {
                                    CachedAsyncImage(url: firstThumb, targetSize: CGSize(width: 60, height: 60)) { $0.resizable().scaledToFill() } placeholder: {
                                        Color.clear
                                    }
                                } else {
                                    Image(systemName: "music.note.list")
                                        .font(.system(size: 24))
                                        .foregroundColor(SpotifyColor.textSecondary)
                                }
                            }
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                            VStack(alignment: .leading, spacing: 4) {
                                Text(playlist.name)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(SpotifyColor.textPrimary)
                                    .lineLimit(1)

                                Text("Playlist • \(playlist.videos.count) bài hát")
                                    .font(.system(size: 13))
                                    .foregroundColor(SpotifyColor.textSecondary)
                            }

                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            // 4. Albums
            if shouldShowAlbums {
                ForEach(filteredAlbums) { card in
                    NavigationLink {
                        SpotifyPlaylistDetailView(
                            albumId: card.id,
                            name: card.title,
                            cover: card.image,
                            subtitle: card.subtitle
                        )
                    } label: {
                        HStack(spacing: 14) {
                            ZStack {
                                SpotifyColor.surfaceHighlight
                                if let img = card.image {
                                    CachedAsyncImage(url: img, targetSize: CGSize(width: 60, height: 60)) { $0.resizable().scaledToFill() } placeholder: {
                                        Color.clear
                                    }
                                } else {
                                    Image(systemName: "opticaldisc")
                                        .font(.system(size: 24))
                                        .foregroundColor(SpotifyColor.textSecondary)
                                }
                            }
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                            VStack(alignment: .leading, spacing: 4) {
                                Text(card.title)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(SpotifyColor.textPrimary)
                                    .lineLimit(1)

                                Text("Album • \(card.subtitle.isEmpty ? "Nghệ sĩ" : card.subtitle)")
                                    .font(.system(size: 13))
                                    .foregroundColor(SpotifyColor.textSecondary)
                                    .lineLimit(1)
                            }

                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            // 5. Followed Artists / Channels
            if shouldShowArtists {
                ForEach(filteredArtists) { channel in
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
                        HStack(spacing: 14) {
                            // Circular Artist Avatar
                            Avatar(url: channel.avatar, name: channel.title, size: 60)
                                .clipShape(Circle())

                            VStack(alignment: .leading, spacing: 4) {
                                Text(channel.title)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(SpotifyColor.textPrimary)
                                    .lineLimit(1)

                                Text("Nghệ sĩ")
                                    .font(.system(size: 13))
                                    .foregroundColor(SpotifyColor.textSecondary)
                            }

                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            // 6. Remote Spotify Playlists (if connected)
            if auth.isLoggedIn && !filteredRemotePlaylists.isEmpty && shouldShowPlaylists {
                ForEach(filteredRemotePlaylists) { card in
                    SpotifyCardLink(card: card, width: nil)
                        .padding(.horizontal, 16)
                }
            }
        }
    }

    // MARK: - 6. Grid Layout Content

    private var gridLayoutContent: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 18) {
            // Pinned Liked Songs Card
            if shouldShowLikedSongs {
                NavigationLink {
                    SpotifyPlaylistDetailView(
                        title: "Bài hát đã thích",
                        subtitle: "Thư viện bài hát yêu thích của bạn",
                        creator: auth.profile?.name ?? "Bạn",
                        likesCount: lib.likedTracks.count,
                        loader: { offset in
                            if auth.isLoggedIn {
                                return try await SpotifyAPI.shared.likedSongs(offset: offset)
                            } else {
                                let all = lib.likedTracks
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
                                .font(.system(size: 38))
                                .foregroundColor(.white)
                        }
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Bài hát đã thích")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(SpotifyColor.textPrimary)
                                .lineLimit(1)

                            Text("Playlist • \(lib.likedTracks.count) bài hát")
                                .font(.system(size: 12))
                                .foregroundColor(SpotifyColor.textSecondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            // Pinned Downloaded Songs Card
            if shouldShowDownloaded {
                NavigationLink {
                    SpotifyPlaylistDetailView(
                        title: "Đã tải xuống",
                        subtitle: "Các bài hát ngoại tuyến trên thiết bị",
                        creator: "Vidra Ngoại Tuyến",
                        likesCount: dl.items.count,
                        loader: { offset in
                            let all = dl.items.map(\.video)
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
                                .font(.system(size: 38))
                                .foregroundColor(.white)
                        }
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Đã tải xuống")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(SpotifyColor.textPrimary)
                                .lineLimit(1)

                            Text("Ngoại tuyến • \(dl.items.count) bài hát")
                                .font(.system(size: 12))
                                .foregroundColor(SpotifyColor.textSecondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            // Playlists in Grid
            if shouldShowPlaylists {
                ForEach(filteredPlaylists) { playlist in
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
                                SpotifyColor.surfaceHighlight
                                if let firstThumb = playlist.videos.first?.thumbnail {
                                    CachedAsyncImage(url: firstThumb, targetSize: CGSize(width: 180, height: 180)) { $0.resizable().scaledToFill() } placeholder: {
                                        Color.clear
                                    }
                                } else {
                                    Image(systemName: "music.note.list")
                                        .font(.system(size: 32))
                                        .foregroundColor(SpotifyColor.textSecondary)
                                }
                            }
                            .aspectRatio(1, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.name)
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(SpotifyColor.textPrimary)
                                    .lineLimit(1)

                                Text("Playlist • \(playlist.videos.count) bài hát")
                                    .font(.system(size: 12))
                                    .foregroundColor(SpotifyColor.textSecondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            // Albums in Grid
            if shouldShowAlbums {
                ForEach(filteredAlbums) { card in
                    NavigationLink {
                        SpotifyPlaylistDetailView(
                            albumId: card.id,
                            name: card.title,
                            cover: card.image,
                            subtitle: card.subtitle
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            ZStack {
                                SpotifyColor.surfaceHighlight
                                if let img = card.image {
                                    CachedAsyncImage(url: img, targetSize: CGSize(width: 180, height: 180)) { $0.resizable().scaledToFill() } placeholder: {
                                        Color.clear
                                    }
                                } else {
                                    Image(systemName: "opticaldisc")
                                        .font(.system(size: 32))
                                        .foregroundColor(SpotifyColor.textSecondary)
                                }
                            }
                            .aspectRatio(1, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(card.title)
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(SpotifyColor.textPrimary)
                                    .lineLimit(1)

                                Text("Album • \(card.subtitle.isEmpty ? "Nghệ sĩ" : card.subtitle)")
                                    .font(.system(size: 12))
                                    .foregroundColor(SpotifyColor.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            // Artists in Grid (Circular)
            if shouldShowArtists {
                ForEach(filteredArtists) { channel in
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
                            Avatar(url: channel.avatar, name: channel.title, size: 140)
                                .clipShape(Circle())

                            Text(channel.title)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(SpotifyColor.textPrimary)
                                .lineLimit(1)

                            Text("Nghệ sĩ")
                                .font(.system(size: 12))
                                .foregroundColor(SpotifyColor.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - 7. Spotify Sync Banner (Non-blocking)

    private var spotifySyncBanner: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "dot.radiowaves.right")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(SpotifyColor.brandGreen)

                Text("Đồng bộ tài khoản Spotify")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(SpotifyColor.textPrimary)
            }

            Text("Kết nối tài khoản Spotify của bạn để đưa danh sách phát trực tuyến, nghệ sĩ theo dõi và album yêu thích về ứng dụng Vidra.")
                .font(.system(size: 13))
                .foregroundColor(SpotifyColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button {
                    showSpotifyConnect = true
                } label: {
                    Text("Đăng nhập Spotify")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(SpotifyColor.brandGreen, in: Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    showImportSheet = true
                } label: {
                    Text("Nhập bằng link")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(SpotifyColor.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(SpotifyColor.surfaceHighlight, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(SpotifyColor.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    // MARK: - Helpers & Filtering

    private var shouldShowLikedSongs: Bool {
        (selectedFilter == nil || selectedFilter == .playlists) &&
        (searchQuery.isEmpty || "bài hát đã thích".contains(searchQuery.lowercased()))
    }

    private var shouldShowDownloaded: Bool {
        (selectedFilter == nil || selectedFilter == .downloaded) &&
        (searchQuery.isEmpty || "đã tải xuống".contains(searchQuery.lowercased()))
    }

    private var shouldShowPlaylists: Bool {
        selectedFilter == nil || selectedFilter == .playlists
    }

    private var shouldShowArtists: Bool {
        selectedFilter == nil || selectedFilter == .artists
    }

    private var shouldShowAlbums: Bool {
        selectedFilter == nil || selectedFilter == .albums
    }

    private var filteredPlaylists: [LocalPlaylist] {
        var list = lib.playlists
        if !searchQuery.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(searchQuery) }
        }
        switch sortOption {
        case .recentPlayed:
            let historyIds = lib.history.map(\.video.id)
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

    private var filteredRemotePlaylists: [SpotifyCard] {
        var list = model.playlists
        if !searchQuery.isEmpty {
            list = list.filter { $0.title.localizedCaseInsensitiveContains(searchQuery) || $0.subtitle.localizedCaseInsensitiveContains(searchQuery) }
        }
        switch sortOption {
        case .recentPlayed, .recentlyAdded:
            return list
        case .alphabetical:
            return list.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        }
    }

    private var filteredArtists: [Channel] {
        var list = lib.subscriptions
        if !searchQuery.isEmpty {
            list = list.filter { $0.title.localizedCaseInsensitiveContains(searchQuery) }
        }
        switch sortOption {
        case .recentPlayed:
            let historyChannelIds = lib.history.compactMap(\.video.channelId)
            let historyChannelTitles = lib.history.map(\.video.channelTitle)
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

    private var filteredAlbums: [SpotifyCard] {
        var list = model.albums
        if list.isEmpty {
            let grouped = Dictionary(grouping: lib.likedTracks.filter { !($0.published ?? "").isEmpty }) { $0.published ?? "" }
            list = grouped.compactMap { (albumName, tracks) -> SpotifyCard? in
                guard !albumName.isEmpty, let first = tracks.first else { return nil }
                return SpotifyCard(
                    id: "local_album_\(albumName)",
                    kind: .album,
                    title: albumName,
                    subtitle: first.channelTitle,
                    image: first.thumbnail
                )
            }
        }
        if !searchQuery.isEmpty {
            list = list.filter { $0.title.localizedCaseInsensitiveContains(searchQuery) || $0.subtitle.localizedCaseInsensitiveContains(searchQuery) }
        }
        switch sortOption {
        case .recentPlayed:
            let historyTitles = lib.history.map(\.video.title)
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

    private var filteredDownloads: [DownloadItem] {
        var list = dl.items
        if !searchQuery.isEmpty {
            list = list.filter { $0.video.title.localizedCaseInsensitiveContains(searchQuery) || $0.video.channelTitle.localizedCaseInsensitiveContains(searchQuery) }
        }
        switch sortOption {
        case .recentPlayed:
            let historyIds = lib.history.map(\.video.id)
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
}

private struct SpotifyTrackSection: View {
    let title: String
    let tracks: [Video]
    var limit = 5
    var loader: ((Int) async throws -> Page)?

    var body: some View {
        if !tracks.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title).font(.title3.bold())
                    Spacer()
                    if let loader {
                        NavigationLink {
                            SpotifyTrackListView(title: title, loader: loader)
                        } label: {
                            Text("Xem tất cả").font(.subheadline)
                        }
                    }
                }
                .padding(.horizontal)
                ForEach(tracks.prefix(limit)) { v in
                    VideoButton(video: v, queue: spotifyRest(tracks, after: v))
                        .padding(.horizontal)
                }
            }
        }
    }
}

private struct SpotifyShelf: View {
    let title: String
    let cards: [SpotifyCard]

    var body: some View {
        if !cards.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.title3.bold()).padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(cards) { c in SpotifyCardLink(card: c, width: 140) }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }
}

// MARK: - Cards

struct SpotifyCardView: View {
    let card: SpotifyCard
    var width: CGFloat?

    private var placeholderIcon: String {
        switch card.kind {
        case .artist: return "person.fill"
        case .album: return "opticaldisc"
        case .playlist: return "music.note.list"
        }
    }

    var body: some View {
        VStack(alignment: card.kind == .artist ? .center : .leading, spacing: 6) {
            Color(.secondarySystemFill)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    let cardSize = CGSize(width: width ?? 140, height: width ?? 140)
                    CachedAsyncImage(url: card.image, targetSize: cardSize) { $0.resizable().scaledToFill() } placeholder: {
                        Image(systemName: placeholderIcon).font(.title).foregroundStyle(.secondary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: card.kind == .artist ? 1000 : 8))
            Text(card.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(card.kind == .artist ? .center : .leading)
            if !card.subtitle.isEmpty && card.kind != .artist {
                Text(card.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(width: width)
        .contentShape(Rectangle())
    }
}

struct SpotifyCardLink: View {
    let card: SpotifyCard
    var width: CGFloat?

    var body: some View {
        NavigationLink {
            destination
        } label: {
            SpotifyCardView(card: card, width: width)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var destination: some View {
        switch card.kind {
        case .playlist:
            SpotifyPlaylistView(playlistId: card.id, name: card.title, cover: card.image, subtitle: card.subtitle)
        case .album:
            SpotifyAlbumView(albumId: card.id, name: card.title, cover: card.image, subtitle: card.subtitle)
        case .artist:
            SpotifyArtistView(artistId: card.id, name: card.title)
        }
    }
}

// MARK: - Search

@MainActor
final class SpotifySearchModel: ObservableObject {
    @Published var result = SpotifySearchResult()
    @Published var loading = false
    @Published var loaded = false
    @Published var error: String?

    func search(_ query: String) async {
        loading = true
        error = nil
        do {
            result = try await SpotifyAPI.shared.search(query)
            loaded = true
        } catch {
            loading = false
            if spotifyIsCancelled(error) { return }
            self.error = error.localizedDescription
            loaded = true
            return
        }
        loading = false
    }
}

struct SpotifySearchView: View {
    let query: String
    @StateObject private var model = SpotifySearchModel()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if model.loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 24)
                }
                if let error = model.error {
                    VStack(spacing: 8) {
                        Text(error).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Thử lại") { Task { await model.search(query) } }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                }
                if model.loaded && !model.loading && model.error == nil && model.result.isEmpty {
                    EmptyState(icon: "magnifyingglass", title: "Không có kết quả")
                }

                SpotifyTrackSection(title: "Bài hát", tracks: model.result.tracks, limit: 10)
                SpotifyShelf(title: "Nghệ sĩ", cards: model.result.artists)
                SpotifyShelf(title: "Album", cards: model.result.albums)
                SpotifyShelf(title: "Playlist", cards: model.result.playlists)
            }
            .padding(.vertical, 8)
        }
        .task(id: query) { await model.search(query) }
    }
}

// MARK: - Track list (shared by playlists, albums, liked songs, top tracks)

@MainActor
final class SpotifyTrackModel: ObservableObject {
    @Published var tracks: [Video] = []
    @Published var loading = false
    @Published var loaded = false
    @Published var error: String?

    private var next: String?
    private let loader: (Int) async throws -> Page

    init(loader: @escaping (Int) async throws -> Page) {
        self.loader = loader
    }

    func load(reset: Bool) async {
        guard !loading else { return }
        loading = true
        error = nil
        do {
            let offset = reset ? 0 : (Int(next ?? "") ?? 0)
            let page = try await loader(offset)
            if reset {
                tracks = page.videos
            } else {
                let seen = Set(tracks.map(\.id))
                tracks += page.videos.filter { !seen.contains($0.id) }
            }
            next = page.continuation
            loaded = true
        } catch {
            loading = false
            if spotifyIsCancelled(error) { return }
            self.error = error.localizedDescription
            loaded = true
            return
        }
        loading = false
    }

    func loadMoreIfNeeded(current: Video) {
        guard next != nil, !loading, error == nil, current.id == tracks.last?.id else { return }
        Task { await self.load(reset: false) }
    }
}

struct SpotifyTrackListView: View {
    let title: String
    var cover: URL?
    var subtitle: String
    var failureHint: String?
    @StateObject private var model: SpotifyTrackModel

    init(title: String, cover: URL? = nil, subtitle: String = "", failureHint: String? = nil,
         loader: @escaping (Int) async throws -> Page) {
        self.title = title
        self.cover = cover
        self.subtitle = subtitle
        self.failureHint = failureHint
        _model = StateObject(wrappedValue: SpotifyTrackModel(loader: loader))
    }

    var body: some View {
        List {
            header.listRowSeparator(.hidden)
            ForEach(model.tracks) { v in
                VideoButton(video: v, queue: spotifyRest(model.tracks, after: v))
                    .listRowSeparator(.hidden)
                    .onAppear { model.loadMoreIfNeeded(current: v) }
            }
            if model.loading {
                ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden)
            }
            if let error = model.error {
                VStack(spacing: 8) {
                    Text(failureHint ?? error).font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if failureHint != nil {
                        Text(error).font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                    }
                    Button("Thử lại") { Task { await model.load(reset: model.tracks.isEmpty) } }
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
            }
            if model.loaded && !model.loading && model.error == nil && model.tracks.isEmpty {
                EmptyState(icon: "music.note.list", title: "Danh sách trống").listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !model.loaded else { return }
            await model.load(reset: true)
        }
        .refreshable { await model.load(reset: true) }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Color(.secondarySystemFill)
                .frame(width: 180, height: 180)
                .overlay {
                    CachedAsyncImage(url: cover, targetSize: CGSize(width: 180, height: 180)) { $0.resizable().scaledToFill() } placeholder: {
                        Image(systemName: "music.note").font(.largeTitle).foregroundStyle(.secondary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .shadow(radius: 8, y: 4)
            VStack(spacing: 2) {
                Text(title).font(.title3.bold()).multilineTextAlignment(.center)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            HStack(spacing: 16) {
                Button {
                    playAll(shuffle: true)
                } label: {
                    Image(systemName: "shuffle")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(Color(red: 0.11, green: 0.73, blue: 0.33))
                }
                Spacer()
                Button {
                    playAll(shuffle: false)
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color(red: 0.11, green: 0.73, blue: 0.33))
                            .frame(width: 52, height: 52)
                            .shadow(color: Color(red: 0.11, green: 0.73, blue: 0.33).opacity(0.4), radius: 8, y: 3)
                        Image(systemName: "play.fill")
                            .font(.title3.bold())
                            .foregroundStyle(.black)
                            .offset(x: 2)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .disabled(model.tracks.isEmpty)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    @MainActor
    private func playAll(shuffle: Bool) {
        let list = shuffle ? model.tracks.shuffled() : model.tracks
        guard let first = list.first else { return }
        PlayerManager.shared.play(first, queue: Array(list.dropFirst()))
    }
}

struct SpotifyPlaylistView: View {
    let playlistId: String
    let name: String
    var cover: URL?
    var subtitle = ""

    var body: some View {
        SpotifyPlaylistDetailView(playlistId: playlistId, name: name, cover: cover, subtitle: subtitle)
    }
}

struct SpotifyAlbumView: View {
    let albumId: String
    let name: String
    var cover: URL?
    var subtitle = ""

    var body: some View {
        SpotifyPlaylistDetailView(albumId: albumId, name: name, cover: cover, subtitle: subtitle)
    }
}

// MARK: - Artist

@MainActor
final class SpotifyArtistModel: ObservableObject {
    @Published var info: SpotifyArtistInfo?
    @Published var top: [Video] = []
    @Published var albums: [SpotifyCard] = []
    @Published var loading = false
    @Published var loaded = false
    @Published var error: String?

    private var nextAlbums: String?
    private var loadingMore = false
    private var failure: String?
    private var cancelled = false

    private func take<T>(_ result: Result<T, Error>) -> T? {
        switch result {
        case .success(let value):
            return value
        case .failure(let e):
            if spotifyIsCancelled(e) {
                cancelled = true
            } else if failure == nil {
                failure = e.localizedDescription
            }
            return nil
        }
    }

    func load(_ id: String) async {
        guard !loading else { return }
        loading = true
        error = nil
        failure = nil
        cancelled = false

        async let rInfo = spotifyRun { try await SpotifyAPI.shared.artistInfo(id: id) }
        async let rTop = spotifyRun { try await SpotifyAPI.shared.artistTopTracks(id: id) }
        async let rAlbums = spotifyRun { try await SpotifyAPI.shared.artistAlbums(id: id) }

        if let i = take(await rInfo) { info = i }
        if let t = take(await rTop) { top = t }
        if let l = take(await rAlbums) {
            albums = l.cards
            nextAlbums = l.next
        }
        if top.isEmpty && albums.isEmpty { error = failure }
        loading = false
        loaded = !cancelled
    }

    func loadMoreAlbums(_ id: String, current: SpotifyCard) {
        guard !loadingMore, let next = nextAlbums, current.id == albums.last?.id else { return }
        loadingMore = true
        Task {
            if let l = try? await SpotifyAPI.shared.artistAlbums(id: id, offset: Int(next) ?? 0) {
                let seen = Set(self.albums.map(\.id))
                self.albums += l.cards.filter { !seen.contains($0.id) }
                self.nextAlbums = l.next
            }
            self.loadingMore = false
        }
    }
}

struct SpotifyArtistView: View {
    let artistId: String
    let name: String
    @StateObject private var model = SpotifyArtistModel()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                header

                if model.loading && !model.loaded {
                    ProgressView().frame(maxWidth: .infinity)
                }
                if let error = model.error {
                    VStack(spacing: 8) {
                        Text(error).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Thử lại") { Task { await model.load(artistId) } }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                }

                if !model.top.isEmpty {
                    HStack(spacing: 12) {
                        Button {
                            playTop(shuffle: false)
                        } label: {
                            Label("Phát", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        Button {
                            playTop(shuffle: true)
                        } label: {
                            Label("Trộn bài", systemImage: "shuffle").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .tint(.green)
                    .padding(.horizontal)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Bài hát nổi bật").font(.title3.bold()).padding(.horizontal)
                        ForEach(model.top) { v in
                            VideoButton(video: v, queue: spotifyRest(model.top, after: v))
                                .padding(.horizontal)
                        }
                    }
                }

                if !model.albums.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Album và đĩa đơn").font(.title3.bold()).padding(.horizontal)
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                                  spacing: 16) {
                            ForEach(model.albums) { c in
                                SpotifyCardLink(card: c)
                                    .onAppear { model.loadMoreAlbums(artistId, current: c) }
                            }
                        }
                        .padding(.horizontal)
                    }
                }

                if model.loaded && model.error == nil && model.top.isEmpty && model.albums.isEmpty {
                    EmptyState(icon: "person.fill", title: "Chưa có nội dung")
                }
            }
            .padding(.bottom, 24)
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !model.loaded else { return }
            await model.load(artistId)
        }
        .refreshable { await model.load(artistId) }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Color(.secondarySystemFill)
                .frame(height: 240)
                .frame(maxWidth: .infinity)
                .overlay {
                    CachedAsyncImage(url: model.info?.image, targetSize: CGSize(width: 400, height: 240)) { $0.resizable().scaledToFill() } placeholder: {
                        Image(systemName: "person.fill").font(.system(size: 56)).foregroundStyle(.secondary)
                    }
                }
                .clipped()
            VStack(spacing: 2) {
                Text(model.info?.name ?? name).font(.title.bold()).multilineTextAlignment(.center)
                if let followers = model.info?.followers {
                    Text("\(Fmt.count(followers)) người theo dõi").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
        }
    }

    @MainActor
    private func playTop(shuffle: Bool) {
        let list = shuffle ? model.top.shuffled() : model.top
        guard let first = list.first else { return }
        PlayerManager.shared.play(first, queue: Array(list.dropFirst()))
    }
}
