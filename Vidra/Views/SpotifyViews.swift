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
    @ObservedObject private var auth = SpotifyAuth.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Kết nối Spotify").font(.title2.bold())
                    Text("Xem thư viện, playlist và nghệ sĩ của bạn. Vidra phát bản tương ứng từ YouTube Music vì âm thanh Spotify có DRM.")
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

                TextField("Client ID", text: $auth.clientId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
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

struct SpotifyLibraryView: View {
    @ObservedObject private var auth = SpotifyAuth.shared
    @StateObject private var model = SpotifyLibraryModel()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                header

                if model.loading && !model.loaded {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 24)
                }

                if let error = model.error {
                    VStack(spacing: 8) {
                        Text(error).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Thử lại") { Task { await model.load() } }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                }

                SpotifyTrackSection(title: "Bài hát đã thích", tracks: model.liked,
                                    loader: { try await SpotifyAPI.shared.likedSongs(offset: $0) })
                SpotifyShelf(title: "Playlist của bạn", cards: model.playlists)
                SpotifyShelf(title: "Album đã lưu", cards: model.albums)
                SpotifyShelf(title: "Nghệ sĩ đang theo dõi", cards: model.artists)
                SpotifyTrackSection(title: "Top bài hát gần đây", tracks: model.top,
                                    loader: { try await SpotifyAPI.shared.topTracks(offset: $0) })
                SpotifyTrackSection(title: "Nghe gần đây", tracks: model.recent, limit: 10)
                SpotifyShelf(title: "Mới phát hành", cards: model.releases)

                NavigationLink {
                    SpotifyImportView()
                } label: {
                    Label("Nhập playlist bằng link (không cần đăng nhập)", systemImage: "link")
                        .font(.subheadline)
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
        }
        .task {
            await auth.loadProfile()
            if !model.loaded { await model.load() }
        }
        .refreshable { await model.load() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Avatar(url: auth.profile?.image, name: auth.profile?.name ?? "S", size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("Thư viện Spotify").font(.caption).foregroundStyle(.secondary)
                Text(auth.profile?.name ?? "Đang tải…").font(.headline).lineLimit(1)
            }
            Spacer()
            Menu {
                Button(role: .destructive) {
                    auth.logout()
                } label: {
                    Label("Đăng xuất", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
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
                    AsyncImage(url: card.image) { $0.resizable().scaledToFill() } placeholder: {
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
                    AsyncImage(url: cover) { $0.resizable().scaledToFill() } placeholder: {
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
            HStack(spacing: 12) {
                Button {
                    playAll(shuffle: false)
                } label: {
                    Label("Phát", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button {
                    playAll(shuffle: true)
                } label: {
                    Label("Trộn bài", systemImage: "shuffle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .tint(.green)
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
        SpotifyTrackListView(
            title: name, cover: cover, subtitle: subtitle,
            failureHint: "Không tải được playlist này. Spotify chặn playlist do Spotify tạo (Daily Mix, Discover Weekly...) và một số playlist khác với ứng dụng mới.",
            loader: { try await SpotifyAPI.shared.playlistTracks(id: playlistId, offset: $0) })
    }
}

struct SpotifyAlbumView: View {
    let albumId: String
    let name: String
    var cover: URL?
    var subtitle = ""

    var body: some View {
        SpotifyTrackListView(
            title: name, cover: cover, subtitle: subtitle,
            loader: { try await SpotifyAPI.shared.albumTracks(id: albumId, offset: $0) })
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
                    AsyncImage(url: model.info?.image) { $0.resizable().scaledToFill() } placeholder: {
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
