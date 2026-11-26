import SwiftUI
import UniformTypeIdentifiers

// MARK: - Home

struct HomeView: View {
    @ObservedObject private var lib = Library.shared
    @State private var category: String?
    @State private var feed: [Video] = []
    @State private var loading = false
    @State private var loadedKey = ""

    private let categories = ["Thịnh hành", "Âm nhạc", "Tin tức", "Trò chơi", "Bóng đá",
                              "Podcast", "Phim", "Học tập", "Công nghệ", "Nấu ăn", "Du lịch"]

    private var subsKey: String {
        lib.subscriptions.map(\.id).joined(separator: ",")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                chips
                Divider()
                content
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    HStack(spacing: 6) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.red)
                                .frame(width: 28, height: 20)
                            Image(systemName: "play.fill")
                                .font(.system(size: 9, weight: .black))
                                .foregroundStyle(.white)
                        }
                        Text("Vidra")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .tracking(-0.3)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
                }
            }
            .onAppear {
                if lib.subscriptions.isEmpty && category == nil { category = categories[0] }
            }
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("Kênh đăng ký", selected: category == nil) { category = nil }
                ForEach(categories, id: \.self) { c in
                    chip(c, selected: category == c) { category = c }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selected ? Color.primary : Color(.secondarySystemFill), in: Capsule())
                .foregroundStyle(selected ? Color(.systemBackground) : Color.primary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        if let category {
            PagedList(loader: { token in
                try await InnerTube.shared.search(category, params: nil, continuation: token)
            }, compact: false)
            .id(category)
        } else if lib.subscriptions.isEmpty {
            ScrollView {
                EmptyState(icon: "person.2", title: "Chưa đăng ký kênh nào",
                           message: "Tìm kênh rồi bấm Đăng ký, hoặc nhập danh sách từ Google Takeout ở tab Đăng ký.")
            }
        } else {
            List(feed) { v in
                VideoButton(video: v, compact: false).listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .overlay { if loading && feed.isEmpty { ProgressView() } }
            .refreshable { await loadFeed() }
            .task(id: subsKey) {
                guard loadedKey != subsKey else { return }
                await loadFeed()
            }
        }
    }

    @MainActor
    private func loadFeed() async {
        loading = true
        let key = subsKey
        let result = await Extras.subscriptionFeed(lib.subscriptions)
        guard !Task.isCancelled else {
            loading = false
            return
        }
        loading = false
        feed = result
        loadedKey = key
    }
}

// MARK: - Search

enum SearchFilter: String, CaseIterable, Identifiable {
    case all, videos, channels, newest
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "Tất cả"
        case .videos: return "Video"
        case .channels: return "Kênh"
        case .newest: return "Mới nhất"
        }
    }

    var params: String? {
        switch self {
        case .all: return nil
        case .videos: return "EgIQAQ=="
        case .channels: return "EgIQAg=="
        case .newest: return "CAISAhAB"
        }
    }
}

struct SearchView: View {
    var needsNavigationStack: Bool = true

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var pm = PlayerManager.shared
    @State private var text = ""
    @State private var query = ""
    @State private var filter = SearchFilter.all
    @State private var suggestions: [String] = []
    @State private var linkPlaylist: String?
    @State private var showPlaylist = false
    @State private var linkChannel: Channel?
    @State private var showChannel = false
    @State private var loadingLink = false
    @State private var linkError: String?
    @State private var linkTask: Task<Void, Never>?
    @AppStorage("recentSearches") private var recentRaw = ""

    private var recents: [String] {
        var seen = Set<String>()
        return recentRaw.split(separator: "\n").map(String.init).filter { seen.insert($0).inserted }
    }

    var body: some View {
        if needsNavigationStack {
            NavigationStack {
                searchBody
            }
            .onChange(of: pm.showWatch) { showing in
                if showing { dismiss() }
            }
        } else {
            searchBody
        }
    }

    private var searchBody: some View {
        VStack(spacing: 0) {
            if loadingLink {
                ProgressView("Đang tải liên kết…")
                    .padding(.vertical, 8)
            }
            Group {
                if query.isEmpty { recentList } else { results }
            }
        }
        .navigationTitle("Tìm kiếm")
        .searchable(text: $text, prompt: "Tìm video, kênh hoặc dán link")
        .searchSuggestions {
            ForEach(suggestions, id: \.self) { s in
                Button { text = s; submit(s) } label: { Label(s, systemImage: "magnifyingglass") }
                    .foregroundStyle(.primary)
            }
        }
        .onSubmit(of: .search) { submit(text) }
        .onChange(of: text) {
            if $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { query = "" }
        }
        .task(id: text) {
            let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard q.count > 1, YTLink.parse(q) == nil, Spotify.parseLink(q) == nil else {
                suggestions = []
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            suggestions = await InnerTube.shared.suggestions(q)
        }
        .onDisappear { linkTask?.cancel() }
        .navigationDestination(isPresented: $showPlaylist) {
            if let id = linkPlaylist { RemotePlaylistView(id: id) }
        }
        .navigationDestination(isPresented: $showChannel) {
            if let c = linkChannel { ChannelView(channel: c) }
        }
        .alert(linkError ?? "", isPresented: Binding(get: { linkError != nil }, set: { if !$0 { linkError = nil } })) {
            Button("OK") {}
        }
    }

    private var recentList: some View {
        List {
            if recents.isEmpty {
                EmptyState(icon: "magnifyingglass", title: "Tìm kiếm không quảng cáo",
                           message: "Có thể dán link video, danh sách phát hoặc kênh YouTube.")
                    .listRowSeparator(.hidden)
            } else {
                Section {
                    ForEach(recents, id: \.self) { r in
                        Button { text = r; submit(r) } label: { Label(r, systemImage: "clock.arrow.circlepath") }
                            .foregroundStyle(.primary)
                    }
                } header: {
                    HStack {
                        Text("Gần đây")
                        Spacer()
                        Button("Xoá") { recentRaw = "" }
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private var results: some View {
        PagedList(
            loader: { [query, filter] token in
                try await InnerTube.shared.search(query, params: filter.params, continuation: token)
            },
            header: AnyView(
                Picker("Lọc", selection: $filter) {
                    ForEach(SearchFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            )
        )
        .id("\(query)|\(filter.rawValue)")
    }

    private func submit(_ raw: String) {
        let q = raw.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        suggestions = []
        switch YTLink.parse(q) {
        case .video(let id)?:
            PlayerManager.shared.play(Video(id: id, title: "", channelTitle: ""), queue: [])
            return
        case .playlist(let id)?:
            linkPlaylist = id
            showPlaylist = true
            return
        case .channel(let id)?:
            linkChannel = Channel(id: id, title: "")
            showChannel = true
            return
        case nil:
            break
        }
        if let parsed = Spotify.parseLink(q) {
            linkTask?.cancel()
            loadingLink = true
            linkTask = Task {
                defer { loadingLink = false }
                do {
                    let (_, tracks) = try await Spotify.fetch(q)
                    guard !Task.isCancelled, let first = tracks.first else { return }
                    if parsed.kind == "track" {
                        let v = Video(id: "sp:\(parsed.id)", title: first.title, channelTitle: first.artist, source: .spotify)
                        PlayerManager.shared.play(v, queue: [])
                    } else {
                        let matched = await Spotify.matchAll(tracks) { _ in }
                        guard !Task.isCancelled else { return }
                        let playable = matched.compactMap { $0 }
                        if let firstPlay = playable.first {
                            PlayerManager.shared.play(firstPlay, queue: Array(playable.dropFirst()))
                        } else {
                            linkError = "Không tìm thấy bài hát phù hợp trên YouTube Music"
                        }
                    }
                } catch {
                    if !(error is CancellationError) {
                        linkError = error.localizedDescription
                    }
                }
            }
            return
        }
        query = q
        var r = recents.filter { $0 != q }
        r.insert(q, at: 0)
        recentRaw = r.prefix(30).joined(separator: "\n")
    }
}

// MARK: - Channel & remote playlist

enum ChannelTab: String, CaseIterable, Identifiable {
    case videos = "Video"
    case playlists = "Danh sách phát"
    var id: String { rawValue }
}

struct ChannelView: View {
    @State var channel: Channel
    @ObservedObject private var lib = Library.shared
    @State private var tab = ChannelTab.videos

    var body: some View {
        Group {
            switch tab {
            case .videos:
                PagedList(
                    loader: { [id = channel.id] token in
                        try await InnerTube.shared.channelVideos(id, continuation: token)
                    },
                    header: AnyView(header),
                    compact: false,
                    onFirstPage: { applyChannelMetadata($0) }
                )
                .id("videos-\(channel.id)")
            case .playlists:
                PagedList(
                    loader: { [id = channel.id] token in
                        try await InnerTube.shared.channelPlaylists(id, continuation: token)
                    },
                    header: AnyView(header),
                    compact: false,
                    onFirstPage: { applyChannelMetadata($0) }
                )
                .id("playlists-\(channel.id)")
            }
        }
        .navigationTitle(channel.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func applyChannelMetadata(_ page: Page) {
        guard let c = page.channel else { return }
        channel = Channel(
            id: c.id,
            title: c.title.isEmpty ? channel.title : c.title,
            avatar: c.avatar ?? channel.avatar,
            subscribers: c.subscribers
        )
        lib.refreshChannel(channel)
    }

    private var header: some View {
        VStack(spacing: 10) {
            Avatar(url: channel.avatar, name: channel.title, size: 80)
            Text(channel.title).font(.title3.bold())
            if let s = channel.subscribers { Text(s).font(.caption).foregroundStyle(.secondary) }
            SubscribeButton(channel: channel)
            Picker("Tab", selection: $tab) {
                ForEach(ChannelTab.allCases) { t in Text(t.rawValue).tag(t) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

struct RemotePlaylistView: View {
    let id: String
    @ObservedObject private var lib = Library.shared
    @State private var title = "Danh sách phát"
    @State private var loadedVideos: [Video] = []
    @State private var saved = false

    var body: some View {
        PagedList(
            loader: { token in try await InnerTube.shared.playlist(id, continuation: token) },
            queueFromRemaining: true,
            onFirstPage: { p in
                if let t = p.title, !t.isEmpty { title = t }
                loadedVideos = p.videos
            },
            onVideosChanged: { all in
                loadedVideos = all
            }
        )
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    let pid = lib.createPlaylist(title)
                    loadedVideos.forEach { lib.add($0, to: pid) }
                    saved = true
                } label: {
                    Image(systemName: saved ? "checkmark" : "square.and.arrow.down")
                }
                .disabled(loadedVideos.isEmpty || saved)
                Button {
                    guard let f = loadedVideos.first else { return }
                    PlayerManager.shared.play(f, queue: Array(loadedVideos.dropFirst()))
                } label: {
                    Image(systemName: "play.fill")
                }
                .disabled(loadedVideos.isEmpty)
            }
        }
    }
}

// MARK: - Subscriptions

struct SubscriptionsView: View {
    var needsNavigationStack: Bool = true

    @ObservedObject private var lib = Library.shared
    @State private var importing = false
    @State private var message: String?

    var body: some View {
        if needsNavigationStack {
            NavigationStack {
                subsList
            }
        } else {
            subsList
        }
    }

    private var subsList: some View {
        List {
            if lib.subscriptions.isEmpty {
                EmptyState(icon: "person.2", title: "Chưa có kênh",
                           message: "Bấm ⤓ để nhập tệp subscriptions.csv từ Google Takeout (takeout.google.com → YouTube).")
                    .listRowSeparator(.hidden)
            }
            ForEach(lib.subscriptions) { c in
                NavigationLink { ChannelView(channel: c) } label: { ChannelRow(channel: c) }
            }
            .onDelete { lib.subscriptions.remove(atOffsets: $0) }
        }
        .listStyle(.plain)
        .navigationTitle("Kênh đăng ký (\(lib.subscriptions.count))")
        .toolbar {
            Button { importing = true } label: { Image(systemName: "square.and.arrow.down") }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .plainText, .data]) { result in
            guard case .success(let url) = result else { return }
            Task {
                let text = await Task.detached(priority: .userInitiated) { () -> String? in
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    return try? String(contentsOf: url, encoding: .utf8)
                }.value
                guard let csv = text else {
                    message = "Không đọc được tệp"
                    return
                }
                message = "Đã nhập \(lib.importTakeout(csv)) kênh"
            }
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        }
    }
}

// MARK: - Library

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "Tất cả"
    case playlists = "Danh sách phát"
    case liked = "Đã thích"
    case downloads = "Đã tải"
    case artists = "Nghệ sĩ & kênh"
    var id: String { rawValue }
}

/// Routes an artist/channel to the right page by id prefix.
struct ArtistDestination: View {
    let channel: Channel

    var body: some View {
        if channel.id.hasPrefix("spa:") {
            SpotifyArtistView(artistId: String(channel.id.dropFirst(4)), name: channel.title)
        } else {
            ChannelView(channel: channel)
        }
    }
}

struct LibraryView: View {
    @ObservedObject private var lib = Library.shared
    @ObservedObject private var dl = DownloadManager.shared
    @AppStorage("librarySortAZ") private var sortAZ = false
    @State private var filter = LibraryFilter.all
    @State private var search = ""
    @State private var newName = ""
    @State private var showNew = false

    private func matches(_ text: String) -> Bool {
        search.isEmpty || text.localizedCaseInsensitiveContains(search)
    }

    private var playlists: [LocalPlaylist] {
        let list = lib.playlists.filter { matches($0.name) }
        return sortAZ ? list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } : list
    }

    private var artists: [Channel] {
        var seen = Set<String>()
        let list = (lib.followedArtists + lib.subscriptions)
            .filter { seen.insert($0.id).inserted && matches($0.title) }
        return sortAZ ? list.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending } : list
    }

    var body: some View {
        NavigationStack {
            List {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(LibraryFilter.allCases) { f in
                            Button { filter = f } label: {
                                Text(f.rawValue)
                                    .font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(filter == f ? Color.primary : Color(.secondarySystemFill), in: Capsule())
                                    .foregroundStyle(filter == f ? Color(.systemBackground) : Color.primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                .listRowSeparator(.hidden)

                if filter == .all && search.isEmpty {
                    Section {
                        NavigationLink { HistoryView() } label: {
                            Label("Lịch sử", systemImage: "clock.arrow.circlepath")
                        }
                        NavigationLink { LocalVideoList(title: "Bài hát đã thích", source: .liked) } label: {
                            Label("Bài hát đã thích (\(lib.likedTracks.count))", systemImage: "heart.fill")
                        }
                        NavigationLink { LocalVideoList(title: "Xem sau", source: .watchLater) } label: {
                            Label("Xem sau (\(lib.watchLater.count))", systemImage: "clock")
                        }
                        NavigationLink { DownloadsView() } label: {
                            Label("Tải xuống (\(dl.items.count))", systemImage: "arrow.down.circle")
                        }
                    }
                }

                if filter == .all || filter == .playlists {
                    Section("Danh sách phát") {
                        ForEach(playlists) { p in
                            NavigationLink { LocalVideoList(title: p.name, source: .playlist(p.id)) } label: {
                                HStack(spacing: 12) {
                                    Color(.secondarySystemFill)
                                        .frame(width: 48, height: 48)
                                        .overlay {
                                            CachedAsyncImage(url: p.videos.first?.thumbnail, targetSize: CGSize(width: 48, height: 48)) { $0.resizable().scaledToFill() } placeholder: {
                                                Image(systemName: "music.note.list").foregroundStyle(.secondary)
                                            }
                                        }
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(p.name).lineLimit(1)
                                        Text("\(p.videos.count) mục").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .onDelete { offsets in
                            let ids = Set(offsets.map { playlists[$0].id })
                            lib.playlists.removeAll { ids.contains($0.id) }
                        }
                        Button { newName = ""; showNew = true } label: {
                            Label("Tạo danh sách phát", systemImage: "plus")
                        }
                    }
                }

                if filter == .liked {
                    let liked = lib.likedTracks.filter { matches($0.title) || matches($0.channelTitle) }
                    ForEach(Array(liked.enumerated()), id: \.element.id) { idx, v in
                        VideoButton(video: v, queue: Array(liked.dropFirst(idx + 1)))
                    }
                }

                if filter == .downloads {
                    let filtered = dl.items.filter { matches($0.video.title) }
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, item in
                        VideoButton(video: item.video, queue: Array(filtered.dropFirst(idx + 1).map(\.video)))
                    }
                }

                if filter == .all || filter == .artists {
                    Section("Nghệ sĩ & kênh") {
                        ForEach(filter == .all ? Array(artists.prefix(8)) : artists) { c in
                            NavigationLink { ArtistDestination(channel: c) } label: { ChannelRow(channel: c) }
                        }
                        if filter == .all && artists.count > 8 {
                            Button("Xem tất cả (\(artists.count))") { filter = .artists }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $search, prompt: "Tìm trong thư viện")
            .navigationTitle("Thư viện")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Menu {
                        Picker("Sắp xếp", selection: $sortAZ) {
                            Text("Gần đây").tag(false)
                            Text("Tên A–Z").tag(true)
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
                }
            }
            .alert("Danh sách phát mới", isPresented: $showNew) {
                TextField("Tên", text: $newName)
                Button("Tạo") {
                    if !newName.trimmingCharacters(in: .whitespaces).isEmpty { lib.createPlaylist(newName) }
                }
                Button("Huỷ", role: .cancel) {}
            }
        }
    }
}

struct LocalVideoList: View {
    let title: String
    let source: LocalSource
    @ObservedObject private var lib = Library.shared

    var body: some View {
        let videos = lib.videos(in: source)
        List {
            if videos.isEmpty {
                EmptyState(icon: "tray", title: "Trống").listRowSeparator(.hidden)
            } else {
                HStack(spacing: 10) {
                    Button { play(videos) } label: {
                        Label("Phát tất cả", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.borderless)
                    Button { play(videos.shuffled()) } label: {
                        Label("Ngẫu nhiên", systemImage: "shuffle")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.borderless)
                }
                .listRowSeparator(.hidden)
            }
            ForEach(Array(videos.enumerated()), id: \.element.id) { idx, v in
                VideoButton(video: v, queue: Array(videos.dropFirst(idx + 1)))
            }
            .onDelete { lib.remove(at: $0, from: source) }
            .onMove { lib.move(from: $0, to: $1, in: source) }
        }
        .listStyle(.plain)
        .navigationTitle(title)
        .toolbar { EditButton() }
    }

    private func play(_ list: [Video]) {
        guard let first = list.first else { return }
        PlayerManager.shared.play(first, queue: Array(list.dropFirst()))
    }
}

struct HistoryView: View {
    @ObservedObject private var lib = Library.shared
    @State private var filter = ""
    @State private var confirm = false

    var body: some View {
        let items = filter.isEmpty ? lib.history : lib.history.filter {
            $0.video.title.localizedCaseInsensitiveContains(filter) || $0.video.channelTitle.localizedCaseInsensitiveContains(filter)
        }
        List {
            ForEach(items) { h in VideoButton(video: h.video) }
                .onDelete { offsets in
                    let ids = Set(offsets.map { items[$0].id })
                    lib.history.removeAll { ids.contains($0.id) }
                }
        }
        .listStyle(.plain)
        .searchable(text: $filter, prompt: "Tìm trong lịch sử")
        .navigationTitle("Lịch sử")
        .toolbar {
            Button("Xoá hết", role: .destructive) { confirm = true }.disabled(lib.history.isEmpty)
        }
        .confirmationDialog("Xoá toàn bộ lịch sử xem?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Xoá", role: .destructive) { lib.clearHistory() }
        }
    }
}

struct DownloadsView: View {
    @ObservedObject private var dl = DownloadManager.shared

    var body: some View {
        List {
            if !dl.active.isEmpty {
                Section("Đang tải") {
                    ForEach(dl.active.values.sorted { $0.id < $1.id }) { a in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(a.video.title).font(.subheadline.weight(.medium)).lineLimit(1)
                                ProgressView(value: a.progress).tint(a.isPaused ? .orange : .red)
                                HStack {
                                    Text(a.isPaused ? "Đã tạm dừng" : "\(Int(a.progress * 100))%")
                                    Spacer()
                                    if a.totalBytes > 0 {
                                        Text("\(ByteCountFormatter.string(fromByteCount: a.downloadedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: a.totalBytes, countStyle: .file))")
                                    }
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }

                            Button {
                                if a.isPaused {
                                    dl.resume(a.id)
                                } else {
                                    dl.pause(a.id)
                                }
                            } label: {
                                Image(systemName: a.isPaused ? "play.circle.fill" : "pause.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(a.isPaused ? .green : .orange)
                            }
                            .buttonStyle(.borderless)

                            Button {
                                dl.cancel(a.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            Section {
                if dl.items.isEmpty && dl.active.isEmpty {
                    EmptyState(icon: "arrow.down.circle", title: "Chưa có video tải xuống",
                               message: "Nhấn giữ một video hoặc dùng nút Tải xuống khi đang xem.")
                }
                ForEach(Array(dl.items.enumerated()), id: \.element.id) { idx, item in
                    VStack(alignment: .leading, spacing: 4) {
                        VideoButton(
                            video: item.video,
                            queue: Array(dl.items.dropFirst(idx + 1).map(\.video))
                        )
                        Text((item.audioOnly ? "Âm thanh • " : "Video • ")
                             + ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete { offsets in dl.delete(at: offsets) }
            } footer: {
                Text("Tệp nằm trong ứng dụng Tệp › Trên iPhone › Vidra › Downloads. Xem được khi không có mạng.")
            }
        }
        .listStyle(.plain)
        .navigationTitle("Tải xuống")
    }
}

// MARK: - Settings

struct SettingsView: View {
    @AppStorage(Pref.maxHeightKey) private var maxHeight = 1080
    @AppStorage(Pref.defaultRateKey) private var defaultRate = 1.0
    @AppStorage(Pref.autoplayKey) private var autoplay = true
    @AppStorage(Pref.autoPiPKey) private var autoPiP = true
    @AppStorage(Pref.sponsorBlockKey) private var sponsorBlock = true
    @AppStorage(Pref.saveHistoryKey) private var saveHistory = true
    @AppStorage(Pref.hideShortsKey) private var hideShorts = true
    @AppStorage(Pref.musicAudioOnlyKey) private var musicAudioOnly = true
    @State private var confirmClear = false
    @State private var importingLibrary = false
    @State private var importMessage: String?
    @ObservedObject private var spotifyAuth = SpotifyAuth.shared
    @ObservedObject private var spotifyRemote = SpotifyRemote.shared
    @ObservedObject private var modeManager = AppModeManager.shared

    var body: some View {
        Form {
            Section("Chế độ ứng dụng") {
                Picker("Chế độ giao diện", selection: Binding(
                    get: { modeManager.currentMode },
                    set: { modeManager.switchTo($0) }
                )) {
                    ForEach(AppMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.iconName).tag(mode)
                    }
                }
            }

            Section("Tài khoản Spotify") {
                if spotifyAuth.isLoggedIn {
                    HStack(spacing: 12) {
                        Avatar(url: spotifyAuth.profile?.image, name: spotifyAuth.profile?.name ?? "S", size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(spotifyAuth.profile?.name ?? "Người dùng Spotify")
                                .font(.headline)
                            HStack(spacing: 4) {
                                Circle().fill(Color.green).frame(width: 8, height: 8)
                                Text("Đã kết nối").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)

                    Toggle("Phát trực tiếp qua app Spotify (App Remote)", isOn: Binding(
                        get: { spotifyRemote.isEnabled },
                        set: { spotifyRemote.isEnabled = $0 }
                    ))

                    if !spotifyRemote.isSpotifyInstalled {
                        Text("Chưa phát hiện app Spotify trên máy. Vidra sẽ tự động phát trực tiếp qua nguồn âm thanh thay thế.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button("Đăng xuất Spotify", role: .destructive) {
                        spotifyAuth.logout()
                    }
                } else {
                    NavigationLink {
                        SpotifySetupView()
                            .navigationTitle("Kết nối Spotify")
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Kết nối tài khoản Spotify")
                                    .foregroundStyle(.primary)
                                Text("Đồng bộ thư viện, playlist và bài hát đã thích")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "music.note")
                                .foregroundStyle(.green)
                        }
                    }
                }
            }

            Section("Phát lại") {
                Picker("Chất lượng tối đa", selection: $maxHeight) {
                    Text("Tự động (Cao nhất)").tag(0)
                    Text("4K (2160p)").tag(2160)
                    Text("2K (1440p)").tag(1440)
                    Text("1080p (FHD)").tag(1080)
                    Text("720p (HD)").tag(720)
                    Text("480p (SD)").tag(480)
                    Text("360p").tag(360)
                }
                Picker("Tốc độ mặc định", selection: $defaultRate) {
                    ForEach([0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { Text(Fmt.rate($0)).tag($0) }
                }
                Toggle("Tự động phát video tiếp theo", isOn: $autoplay)
                Toggle("Tự bật Hình trong hình khi rời app", isOn: $autoPiP)
                Toggle("Ẩn Shorts trong bảng tin", isOn: $hideShorts)
                Toggle("Nhạc: chỉ phát âm thanh (tiết kiệm dữ liệu)", isOn: $musicAudioOnly)
            }
            Section {
                Toggle("Tự bỏ qua đoạn quảng cáo tài trợ", isOn: $sponsorBlock)
            } header: {
                Text("SponsorBlock")
            } footer: {
                Text("Dùng dữ liệu cộng đồng sponsor.ajay.app để bỏ qua đoạn tài trợ, tự quảng bá, kêu gọi đăng ký và đoạn không phải nhạc.")
            }
            Section("Quyền riêng tư & dữ liệu") {
                Toggle("Lưu lịch sử xem", isOn: $saveHistory)
                ShareLink(item: Library.fileURL) { Label("Xuất dữ liệu (JSON)", systemImage: "square.and.arrow.up") }
                Button {
                    importingLibrary = true
                } label: {
                    Label("Nhập dữ liệu sao lưu (JSON)", systemImage: "square.and.arrow.down")
                }
                Button("Xoá bộ nhớ đệm ảnh") {
                    ImageCache.shared.clear()
                    ArtworkColorCache.shared.clear()
                    URLCache.shared.removeAllCachedResponses()
                    importMessage = "Đã xoá bộ nhớ đệm ảnh"
                }
                Button("Xoá lịch sử xem", role: .destructive) { confirmClear = true }
            }
            Section {
                Text("Vidra không liên kết với YouTube hay Google. Chỉ dùng cho mục đích cá nhân.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Cài đặt")
        .onChange(of: maxHeight) { _ in PlayerManager.shared.qualityChanged() }
        .onChange(of: defaultRate) { _ in PlayerManager.shared.syncSettings() }
        .onChange(of: sponsorBlock) { _ in PlayerManager.shared.syncSettings() }
        .onChange(of: musicAudioOnly) { _ in
            if PlayerManager.shared.current?.source != nil {
                PlayerManager.shared.retry()
            }
        }
        .task {
            if spotifyAuth.isLoggedIn && spotifyAuth.profile == nil {
                await spotifyAuth.loadProfile()
            }
        }
        .onAppear { Library.shared.flush() }
        .confirmationDialog("Xoá toàn bộ lịch sử xem?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Xoá", role: .destructive) { Library.shared.clearHistory() }
        }
        .fileImporter(isPresented: $importingLibrary, allowedContentTypes: [.json, .plainText, .data]) { result in
            guard case .success(let url) = result else { return }
            Task {
                let fileData = await Task.detached(priority: .userInitiated) { () -> Data? in
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    return try? Data(contentsOf: url)
                }.value
                guard let data = fileData, Library.shared.restoreBackup(from: data) else {
                    importMessage = "Không đọc được file sao lưu hoặc file không hợp lệ"
                    return
                }
                importMessage = "Đã khôi phục dữ liệu thư viện thành công!"
            }
        }
        .alert(importMessage ?? "", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
            Button("OK") {}
        }
    }
}
