import SwiftUI

// MARK: - Paging

/// Continuation-based feed over any SoundCloud collection endpoint.
@MainActor
final class SCFeed<Item: Identifiable>: ObservableObject {
    @Published private(set) var items: [Item] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var loaded = false

    private var next: String?
    private let loader: (String?) async throws -> ([Item], String?)

    init(_ loader: @escaping (String?) async throws -> ([Item], String?)) {
        self.loader = loader
    }

    func loadIfNeeded() async { if !loaded { await load(reset: true) } }
    func reload() async { await load(reset: true) }
    func retry() async { await load(reset: items.isEmpty) }

    func more(after item: Item) {
        guard next != nil, !loading, error == nil, item.id == items.last?.id else { return }
        Task { await load(reset: false) }
    }

    private func load(reset: Bool) async {
        guard !loading else { return }
        loading = true
        error = nil
        do {
            let result = try await loader(reset ? nil : next)
            if reset {
                items = result.0
            } else {
                let seen = Set(items.map { $0.id })
                items += result.0.filter { !seen.contains($0.id) }
            }
            next = result.1
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
            loading = false
            if cancelled { return }
            self.error = error.localizedDescription
        }
        loading = false
        loaded = true
    }
}

/// Infinite list with loading / error / empty states; `row` receives the item and the items after it.
struct SCFeedList<Item: Identifiable, Row: View>: View {
    @StateObject private var feed: SCFeed<Item>
    private let header: (([Item]) -> AnyView)?
    private let emptyTitle: String
    private let row: (Item, [Item]) -> Row

    init(header: (([Item]) -> AnyView)? = nil,
         emptyTitle: String = "Không có kết quả",
         loader: @escaping (String?) async throws -> ([Item], String?),
         @ViewBuilder row: @escaping (Item, [Item]) -> Row) {
        _feed = StateObject(wrappedValue: SCFeed<Item>(loader))
        self.header = header
        self.emptyTitle = emptyTitle
        self.row = row
    }

    var body: some View {
        List {
            if let header {
                header(feed.items).listRowSeparator(.hidden)
            }
            ForEach(feed.items) { item in
                row(item, following(item))
                    .listRowSeparator(.hidden)
                    .onAppear { feed.more(after: item) }
            }
            if feed.loading {
                ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden)
            }
            if let error = feed.error {
                VStack(spacing: 8) {
                    Text(error).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Thử lại") { Task { await feed.retry() } }
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
            }
            if feed.loaded && !feed.loading && feed.error == nil && feed.items.isEmpty {
                EmptyState(icon: "magnifyingglass", title: emptyTitle).listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .task { await feed.loadIfNeeded() }
        .refreshable { await feed.reload() }
    }

    private func following(_ item: Item) -> [Item] {
        guard let i = feed.items.firstIndex(where: { $0.id == item.id }) else { return [] }
        return Array(feed.items[(i + 1)...])
    }
}

// MARK: - Shared pieces

private struct SCPlayButtons: View {
    let tracks: [Video]

    var body: some View {
        HStack {
            Button { start(tracks) } label: { Label("Phát", systemImage: "play.fill").frame(maxWidth: .infinity) }
            Button { start(tracks.shuffled()) } label: { Label("Trộn bài", systemImage: "shuffle").frame(maxWidth: .infinity) }
        }
        .buttonStyle(.bordered)
        .tint(Color.orange)
        .disabled(tracks.isEmpty)
    }

    private func start(_ list: [Video]) {
        guard let first = list.first else { return }
        PlayerManager.shared.play(first, queue: Array(list.dropFirst()))
    }
}

private struct SCPlaylistRow: View {
    let playlist: SCPlaylistInfo

    var body: some View {
        NavigationLink {
            SoundCloudPlaylistView(playlistId: playlist.id, title: playlist.title)
        } label: {
            HStack(spacing: 12) {
                AsyncImage(url: playlist.artwork) { $0.resizable().scaledToFill() } placeholder: {
                    ZStack {
                        Color(.secondarySystemFill)
                        Image(systemName: "music.note.list").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.title).font(.headline).lineLimit(2)
                    Text("\(playlist.owner) · \(playlist.trackCount) bài").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

private struct SCUserRow: View {
    let channel: Channel

    var body: some View {
        NavigationLink {
            SoundCloudUserView(userId: channel.id, name: channel.title)
        } label: {
            ChannelRow(channel: channel)
        }
    }
}

private enum SCLikeItem: Identifiable {
    case track(Video)
    case playlist(SCPlaylistInfo)

    var id: String {
        switch self {
        case .track(let v): return "t:\(v.id)"
        case .playlist(let p): return "p:\(p.id)"
        }
    }

    var video: Video? {
        if case .track(let v) = self { return v }
        return nil
    }
}

private struct SCLikeRow: View {
    let item: SCLikeItem
    let rest: [SCLikeItem]

    var body: some View {
        switch item {
        case .track(let v):
            VideoButton(video: v, queue: rest.compactMap { $0.video })
        case .playlist(let p):
            SCPlaylistRow(playlist: p)
        }
    }
}

// MARK: - Home / search

struct SoundCloudHomeView: View {
    let query: String

    var body: some View {
        if query.isEmpty {
            SCDiscoverView()
        } else {
            SCSearchView(query: query)
        }
    }
}

private struct SCDiscoverView: View {
    private static let genres = ["Lo-fi", "EDM", "Hip hop", "Remix", "Chill", "Vinahouse", "Podcast"]
    @State private var genre: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip(nil, "Dành cho bạn")
                    ForEach(Self.genres, id: \.self) { chip($0, $0) }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            if let genre {
                SCFeedList<Video, VideoButton>(
                    loader: { next in
                        let p = try await SoundCloud.shared.search(genre, next: next)
                        return (p.videos, p.continuation)
                    },
                    row: { v, rest in VideoButton(video: v, queue: rest) }
                )
                .id(genre)
            } else {
                SCLibraryList()
            }
        }
    }

    private func chip(_ value: String?, _ title: String) -> some View {
        let selected = genre == value
        return Button { genre = value } label: {
            Text(title)
                .modifier(Pill())
                .overlay(Capsule().stroke(selected ? Color.orange : Color.clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }
}

/// Followed artists and liked tracks, shown when no genre is selected.
private struct SCLibraryList: View {
    @ObservedObject private var lib = Library.shared

    var body: some View {
        let artists = lib.followedArtists.filter { $0.id.hasPrefix("scu:") }
        let liked = lib.likedTracks.filter { $0.source == .soundCloud }
        List {
            if !artists.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(artists) { a in
                                NavigationLink {
                                    SoundCloudUserView(userId: a.id, name: a.title)
                                } label: {
                                    VStack(spacing: 6) {
                                        Avatar(url: a.avatar, name: a.title, size: 64)
                                        Text(a.title).font(.caption).lineLimit(1).frame(width: 72)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                } header: {
                    Text("Nghệ sĩ đang theo dõi").font(.headline)
                }
            }
            if !liked.isEmpty {
                Section {
                    ForEach(liked.prefix(5)) { v in
                        VideoButton(video: v, queue: Array(liked.drop(while: { $0.id != v.id }).dropFirst()))
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    HStack {
                        Text("Bài hát đã thích").font(.headline)
                        Spacer()
                        NavigationLink("Xem tất cả") { LocalVideoList(title: "Bài hát đã thích", source: .liked) }
                            .font(.subheadline)
                    }
                }
            }
            if artists.isEmpty && liked.isEmpty {
                EmptyState(icon: "waveform", title: "Khám phá SoundCloud",
                           message: "Chọn một thể loại ở trên hoặc tìm kiếm bài hát, nghệ sĩ.")
                    .listRowSeparator(.hidden)
            }
            Text("Bài Go+ chỉ phát thử 30 giây.")
                .font(.footnote).foregroundStyle(.secondary)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
    }
}

private enum SCKind: CaseIterable, Identifiable {
    case songs, artists, playlists
    var id: Self { self }

    var title: String {
        switch self {
        case .songs: return "Bài hát"
        case .artists: return "Nghệ sĩ"
        case .playlists: return "Playlist"
        }
    }
}

private struct SCSearchView: View {
    let query: String
    @State private var kind = SCKind.songs

    var body: some View {
        VStack(spacing: 0) {
            Picker("Loại", selection: $kind) {
                ForEach(SCKind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)
            switch kind {
            case .songs:
                SCFeedList<Video, VideoButton>(
                    loader: { [query] next in
                        let p = try await SoundCloud.shared.search(query, next: next)
                        return (p.videos, p.continuation)
                    },
                    row: { v, rest in VideoButton(video: v, queue: rest) }
                )
                .id("songs|\(query)")
            case .artists:
                SCFeedList<Channel, SCUserRow>(
                    loader: { [query] next in
                        let p = try await SoundCloud.shared.searchUsers(query, next: next)
                        return (p.channels, p.continuation)
                    },
                    row: { c, _ in SCUserRow(channel: c) }
                )
                .id("artists|\(query)")
            case .playlists:
                SCFeedList<SCPlaylistInfo, SCPlaylistRow>(
                    loader: { [query] next in
                        let l = try await SoundCloud.shared.searchPlaylists(query, next: next)
                        return (l.playlists, l.next)
                    },
                    row: { p, _ in SCPlaylistRow(playlist: p) }
                )
                .id("playlists|\(query)")
            }
        }
    }
}

// MARK: - User

private enum SCUserTab: CaseIterable, Identifiable {
    case tracks, playlists, likes
    var id: Self { self }

    var title: String {
        switch self {
        case .tracks: return "Bài hát"
        case .playlists: return "Playlist & album"
        case .likes: return "Đã thích"
        }
    }
}

struct SoundCloudUserView: View {
    let userId: String
    let name: String

    @ObservedObject private var lib = Library.shared
    @State private var user: SCUser?
    @State private var userError: String?
    @State private var tab = SCUserTab.tracks
    @State private var expanded = false

    var body: some View {
        content
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .task { if user == nil { await loadUser() } }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .tracks:
            SCFeedList<Video, VideoButton>(
                header: { items in AnyView(headerView(tracks: items)) },
                emptyTitle: "Chưa có bài hát",
                loader: { [userId] next in
                    let l = try await SoundCloud.shared.userTracks(userId, next: next)
                    return (l.tracks, l.next)
                },
                row: { v, rest in VideoButton(video: v, queue: rest) }
            )
        case .playlists:
            SCFeedList<SCPlaylistInfo, SCPlaylistRow>(
                header: { _ in AnyView(headerView(tracks: nil)) },
                emptyTitle: "Chưa có playlist",
                loader: { [userId] next in
                    let l = try await SoundCloud.shared.userPlaylists(userId, next: next)
                    return (l.playlists, l.next)
                },
                row: { p, _ in SCPlaylistRow(playlist: p) }
            )
        case .likes:
            SCFeedList<SCLikeItem, SCLikeRow>(
                header: { items in AnyView(headerView(tracks: items.compactMap { $0.video })) },
                emptyTitle: "Chưa thích gì",
                loader: { [userId] next in
                    let l = try await SoundCloud.shared.userLikes(userId, next: next)
                    let items = l.tracks.map { SCLikeItem.track($0) } + l.playlists.map { SCLikeItem.playlist($0) }
                    return (items, l.next)
                },
                row: { item, rest in SCLikeRow(item: item, rest: rest) }
            )
        }
    }

    private func headerView(tracks: [Video]?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let banner = user?.banner {
                AsyncImage(url: banner) { $0.resizable().scaledToFill() } placeholder: { Color(.secondarySystemFill) }
                    .frame(maxWidth: .infinity)
                    .frame(height: 110)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            HStack(spacing: 14) {
                Avatar(url: user?.avatar, name: user?.name ?? name, size: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text(user?.name ?? name).font(.title3.weight(.bold)).lineLimit(2)
                    if let user {
                        Text("\(Fmt.count(user.followers)) người theo dõi · \(user.trackCount) bài hát")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            followButton
            if let user, !user.bio.isEmpty {
                Text(user.bio)
                    .font(.subheadline)
                    .lineLimit(expanded ? nil : 3)
                    .onTapGesture { expanded.toggle() }
                Button(expanded ? "Thu gọn" : "Xem thêm") { expanded.toggle() }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.orange)
            }
            if let userError {
                HStack {
                    Text(userError).font(.footnote).foregroundStyle(.secondary)
                    Button("Thử lại") { Task { await loadUser() } }.font(.footnote)
                }
            }
            Picker("Mục", selection: $tab) {
                ForEach(SCUserTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if let tracks, tab == .tracks {
                SCPlayButtons(tracks: tracks)
            }
        }
        .padding(.vertical, 4)
    }

    private var followButton: some View {
        let following = lib.isFollowing(userId)
        return Button {
            lib.toggleFollow(Channel(
                id: userId,
                title: user?.name ?? name,
                avatar: user?.avatar,
                subscribers: user.map { "\(Fmt.count($0.followers)) người theo dõi" }
            ))
        } label: {
            Text(following ? "Đang theo dõi" : "Theo dõi").font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .tint(following ? Color.gray : Color.orange)
    }

    private func loadUser() async {
        userError = nil
        do {
            user = try await SoundCloud.shared.user(userId)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { return }
            userError = error.localizedDescription
        }
    }
}

// MARK: - Playlist

struct SoundCloudPlaylistView: View {
    let playlistId: Int
    let title: String

    @State private var data: SCPlaylist?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        List {
            if let data {
                header(data).listRowSeparator(.hidden)
                ForEach(data.tracks) { v in
                    VideoButton(video: v, queue: following(v, in: data.tracks))
                        .listRowSeparator(.hidden)
                }
                if data.tracks.isEmpty {
                    EmptyState(icon: "music.note.list", title: "Playlist trống").listRowSeparator(.hidden)
                }
            }
            if loading {
                ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden)
            }
            if let error {
                VStack(spacing: 8) {
                    Text(error).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Thử lại") { Task { await load() } }
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { if data == nil { await load() } }
        .refreshable { await load() }
    }

    private func header(_ p: SCPlaylist) -> some View {
        VStack(spacing: 12) {
            AsyncImage(url: p.artwork) { $0.resizable().scaledToFill() } placeholder: {
                ZStack {
                    Color(.secondarySystemFill)
                    Image(systemName: "music.note.list").font(.largeTitle).foregroundStyle(.secondary)
                }
            }
            .frame(width: 200, height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(p.title.isEmpty ? title : p.title).font(.title3.weight(.bold)).multilineTextAlignment(.center)
            Text(summary(p)).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            SCPlayButtons(tracks: p.tracks)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private func summary(_ p: SCPlaylist) -> String {
        let total = Int(p.tracks.reduce(0.0) { $0 + (Fmt.seconds($1.duration) ?? 0) })
        let h = total / 3600, m = (total % 3600) / 60
        let length = h > 0 ? "\(h) giờ \(m) phút" : "\(m) phút"
        let owner = p.owner.isEmpty ? "" : "\(p.owner) · "
        return "\(owner)\(p.tracks.count) bài · \(length)"
    }

    private func following(_ v: Video, in list: [Video]) -> [Video] {
        guard let i = list.firstIndex(where: { $0.id == v.id }) else { return [] }
        return Array(list[(i + 1)...])
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        error = nil
        do {
            data = try await SoundCloud.shared.playlist(playlistId)
        } catch {
            if !(Task.isCancelled || (error as? URLError)?.code == .cancelled) {
                self.error = error.localizedDescription
            }
        }
        loading = false
    }
}
