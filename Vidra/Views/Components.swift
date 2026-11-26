import SwiftUI

struct Thumbnail: View {
    let url: URL?
    var duration: String?
    var progress: Double?
    var targetSize: CGSize? = nil

    var body: some View {
        Color(.secondarySystemFill)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    let frameSize = targetSize ?? (geo.size.width > 0 && geo.size.height > 0 ? geo.size : nil)
                    CachedAsyncImage(url: url, targetSize: frameSize) {
                        $0.resizable().scaledToFill()
                    } placeholder: {
                        Color.clear
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                if let duration, !duration.isEmpty {
                    Text(duration)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.white)
                        .padding(4)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let progress, progress > 0 {
                    GeometryReader { g in
                        Rectangle().fill(Color.red).frame(width: g.size.width * min(max(progress, 0), 1), height: 3)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct VideoRow: View {
    let video: Video
    var compact = true
    @ObservedObject private var lib = Library.shared
    @State private var showRemap = false

    private var meta: String {
        [video.views, video.published].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " • ")
    }

    private var progress: Double? {
        guard let total = Fmt.seconds(video.duration), total > 0 else { return nil }
        let p = lib.position(video.id)
        return p > 0 ? p / total : nil
    }

    private var artworkURL: URL? {
        DownloadManager.shared.localArtwork(for: video.id) ?? video.thumbnail
    }

    var body: some View {
        Group {
            if let source = video.source {
                HStack(spacing: 12) {
                    Color(.secondarySystemFill)
                        .frame(width: 56, height: 56)
                        .overlay {
                            CachedAsyncImage(url: artworkURL, targetSize: CGSize(width: 80, height: 80)) {
                                $0.resizable().scaledToFill()
                            } placeholder: {
                                Image(systemName: "music.note").foregroundStyle(.secondary)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(video.title).font(.subheadline.weight(.medium)).lineLimit(1)
                        Text([video.channelTitle, video.duration ?? "", video.published ?? ""].filter { !$0.isEmpty }
                            .joined(separator: " • "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: source.iconName).font(.caption).foregroundStyle(source.tint)
                }
            } else if compact {
                HStack(alignment: .top, spacing: 10) {
                    Thumbnail(url: artworkURL, duration: video.duration, progress: progress).frame(width: 168)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(video.title).font(.subheadline.weight(.medium)).lineLimit(2)
                        if !video.channelTitle.isEmpty {
                            Text(video.channelTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if !meta.isEmpty {
                            Text(meta).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Thumbnail(url: artworkURL, duration: video.duration, progress: progress)
                    HStack(alignment: .top, spacing: 12) {
                        let known = lib.subscriptions.first { $0.id == video.channelId }
                        Avatar(url: known?.avatar, name: video.channelTitle, size: 36)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(video.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                            Text([video.channelTitle, meta].filter { !$0.isEmpty }.joined(separator: " • "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        Menu {
                            VideoMenuItems(video: video, onRemap: { showRemap = true })
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 6)
                }
                .padding(.bottom, 6)
            }
        }
        .sheet(isPresented: $showRemap) {
            SpotifyRemapSheet(video: video)
        }
    }
}

extension MediaSource {
    var iconName: String {
        switch self {
        case .ytMusic: return "music.note"
        case .spotify: return "dot.radiowaves.right"
        }
    }

    var tint: Color {
        switch self {
        case .ytMusic: return .red
        case .spotify: return .green
        }
    }
}

struct VideoButton: View {
    let video: Video
    var compact = true
    var queue: [Video]? = nil
    var showWatchSheet: Bool = true

    var body: some View {
        Button {
            PlayerManager.shared.play(video, queue: queue ?? [], showWatchSheet: showWatchSheet)
        } label: {
            VideoRow(video: video, compact: compact).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .videoMenu(video)
    }
}

struct VideoMenuItems: View {
    let video: Video
    var onRemap: () -> Void
    @ObservedObject private var lib = Library.shared

    var body: some View {
        if video.source == .spotify {
            Button { onRemap() } label: {
                Label("Đổi nguồn âm thanh", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        Button { PlayerManager.shared.playNext(video) } label: {
            Label("Phát tiếp theo", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        Button { PlayerManager.shared.appendToQueue(video) } label: {
            Label("Thêm vào hàng đợi", systemImage: "text.badge.plus")
        }
        Button { lib.toggleWatchLater(video) } label: {
            Label(lib.isInWatchLater(video.id) ? "Bỏ khỏi Xem sau" : "Xem sau", systemImage: "clock")
        }
        if !lib.playlists.isEmpty {
            Menu {
                ForEach(lib.playlists) { p in Button(p.name) { lib.add(video, to: p.id) } }
            } label: {
                Label("Thêm vào danh sách phát", systemImage: "music.note.list")
            }
        }
        Menu {
            Button("Video") { DownloadManager.shared.start(video, audioOnly: false) }
            Button("Chỉ âm thanh") { DownloadManager.shared.start(video, audioOnly: true) }
        } label: {
            Label("Tải xuống", systemImage: "arrow.down.circle")
        }
        ShareLink(item: video.shareURL) { Label("Chia sẻ", systemImage: "square.and.arrow.up") }
    }
}

struct VideoMenu: ViewModifier {
    let video: Video
    @State private var showRemap = false

    func body(content: Content) -> some View {
        content.contextMenu {
            VideoMenuItems(video: video, onRemap: { showRemap = true })
        }
        .sheet(isPresented: $showRemap) {
            SpotifyRemapSheet(video: video)
        }
    }
}

extension View {
    func videoMenu(_ video: Video) -> some View { modifier(VideoMenu(video: video)) }
}

struct Avatar: View {
    let url: URL?
    let name: String
    var size: CGFloat = 40

    var body: some View {
        CachedAsyncImage(url: url, targetSize: CGSize(width: size, height: size)) {
            $0.resizable().scaledToFill()
        } placeholder: {
            ZStack {
                Color.red.opacity(0.2)
                Text(name.prefix(1).uppercased()).font(.system(size: size * 0.45, weight: .semibold))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

struct ChannelRow: View {
    let channel: Channel

    var body: some View {
        HStack(spacing: 12) {
            Avatar(url: channel.avatar, name: channel.title, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.title).font(.headline).lineLimit(1)
                if let s = channel.subscribers { Text(s).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

struct SubscribeButton: View {
    let channel: Channel
    @ObservedObject private var lib = Library.shared

    var body: some View {
        let subscribed = lib.isSubscribed(channel.id)
        Button {
            lib.toggleSubscription(channel)
        } label: {
            HStack(spacing: 5) {
                if subscribed {
                    Image(systemName: "bell.fill").font(.caption2)
                }
                Text(subscribed ? "Đã đăng ký" : "Đăng ký")
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 4)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .tint(subscribed ? Color(.secondarySystemFill) : Color.primary)
        .foregroundStyle(subscribed ? Color.primary : Color(.systemBackground))
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    var message = ""

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            if !message.isEmpty {
                Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(32)
    }
}

struct Pill: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color(.secondarySystemFill), in: Capsule())
    }
}

struct ChannelPlaylistRow: View {
    let playlist: ChannelPlaylist

    var body: some View {
        HStack(spacing: 12) {
            Color(.secondarySystemFill)
                .frame(width: 88, height: 50)
                .overlay {
                    CachedAsyncImage(url: playlist.thumbnail, targetSize: CGSize(width: 120, height: 70)) {
                        $0.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: "music.note.list").foregroundStyle(.secondary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.title).font(.subheadline.weight(.medium)).lineLimit(2)
                if let c = playlist.videoCount {
                    Text(c).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct SpotifyRemapSheet: View {
    let video: Video
    @Environment(\.dismiss) private var dismiss
    @State private var query: String
    @State private var results: [Video] = []
    @State private var loading = false
    @State private var error: String?
    @State private var searchTask: Task<Void, Never>?

    init(video: Video) {
        self.video = video
        _query = State(initialValue: "\(video.title) \(video.channelTitle)".trimmingCharacters(in: .whitespaces))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Bài hát Spotify:").font(.caption).foregroundStyle(.secondary)
                        Text(video.title).font(.headline)
                        Text(video.channelTitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("Tìm kiếm nguồn âm thanh thay thế") {
                    HStack {
                        TextField("Tìm kiếm bài hát", text: $query)
                            .onSubmit { search() }
                        Button("Tìm") { search() }
                            .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || loading)
                    }
                }

                if loading {
                    ProgressView().frame(maxWidth: .infinity)
                }

                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }

                if !results.isEmpty {
                    Section("Chọn bản phát đúng") {
                        ForEach(results) { item in
                            Button {
                                select(item)
                            } label: {
                                HStack(spacing: 12) {
                                    Color(.secondarySystemFill)
                                        .frame(width: 50, height: 50)
                                        .overlay {
                                            CachedAsyncImage(url: item.thumbnail, targetSize: CGSize(width: 80, height: 80)) {
                                                $0.resizable().scaledToFill()
                                            } placeholder: {
                                                Image(systemName: "music.note").foregroundStyle(.secondary)
                                            }
                                        }
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.title).font(.subheadline.weight(.medium)).lineLimit(1)
                                        Text([item.channelTitle, item.duration ?? ""].filter { !$0.isEmpty }.joined(separator: " • "))
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.right.circle").font(.title3).foregroundStyle(.green)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Đổi nguồn âm thanh")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Đóng") { dismiss() }
                }
            }
            .task { search() }
            .onDisappear { searchTask?.cancel() }
        }
    }

    @MainActor
    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searchTask?.cancel()
        loading = true
        error = nil
        searchTask = Task { @MainActor in
            do {
                let page = try await InnerTube.shared.musicSearch(q, continuation: nil)
                guard !Task.isCancelled else { return }
                results = page.videos
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            if !Task.isCancelled { loading = false }
        }
    }

    @MainActor
    private func select(_ candidate: Video) {
        Task { @MainActor in
            await TrackMatcher.shared.setCustomMatch(for: video.id, youtubeId: candidate.id)
            if PlayerManager.shared.current?.id == video.id {
                PlayerManager.shared.retry()
            } else {
                PlayerManager.shared.play(video, queue: [])
            }
            dismiss()
        }
    }
}

/// Infinite-scroll list over any continuation-based InnerTube endpoint.
struct PagedList: View {
    let loader: (String?) async throws -> Page
    var header: AnyView?
    var compact = true
    var queueFromRemaining = false
    var onFirstPage: ((Page) -> Void)?
    var onVideosChanged: (([Video]) -> Void)?

    @State private var videos: [Video] = []
    @State private var channels: [Channel] = []
    @State private var playlists: [ChannelPlaylist] = []
    @State private var token: String?
    @State private var loading = false
    @State private var error: String?
    @State private var loaded = false
    @State private var activeTask: Task<Void, Never>?

    var body: some View {
        List {
            if let header { header.listRowSeparator(.hidden) }
            ForEach(channels) { c in
                NavigationLink { ChannelView(channel: c) } label: { ChannelRow(channel: c) }
                    .onAppear { if c.id == channels.last?.id { loadMore() } }
            }
            ForEach(playlists) { p in
                NavigationLink { RemotePlaylistView(id: p.id) } label: { ChannelPlaylistRow(playlist: p) }
                    .onAppear { if p.id == playlists.last?.id { loadMore() } }
            }
            ForEach(Array(videos.enumerated()), id: \.element.id) { idx, v in
                VideoButton(
                    video: v,
                    compact: compact,
                    queue: queueFromRemaining ? Array(videos.dropFirst(idx + 1)) : []
                )
                .listRowSeparator(.hidden)
                .onAppear { if v.id == videos.last?.id { loadMore() } }
            }
            if loading {
                ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden)
            }
            if let error {
                VStack(spacing: 8) {
                    Text(error).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Thử lại") {
                        Task { await load(reset: videos.isEmpty && channels.isEmpty && playlists.isEmpty) }
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
            }
            if loaded && !loading && error == nil && videos.isEmpty && channels.isEmpty && playlists.isEmpty {
                EmptyState(icon: "magnifyingglass", title: "Không có kết quả").listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .task {
            guard !loaded else { return }
            await load(reset: true)
        }
        .refreshable {
            activeTask?.cancel()
            loading = false
            await load(reset: true)
        }
        .onDisappear { activeTask?.cancel() }
    }

    @MainActor
    private func loadMore() {
        guard token != nil, !loading, error == nil else { return }
        activeTask?.cancel()
        activeTask = Task { @MainActor in await load(reset: false) }
    }

    @MainActor
    private func load(reset: Bool) async {
        guard !loading else { return }
        loading = true
        error = nil
        do {
            let page = try await loader(reset ? nil : token)
            guard !Task.isCancelled else {
                loading = false
                return
            }
            if reset {
                var sv = Set<String>()
                videos = page.videos.filter { sv.insert($0.id).inserted }
                var sc = Set<String>()
                channels = page.channels.filter { sc.insert($0.id).inserted }
                var sp = Set<String>()
                playlists = page.playlists.filter { sp.insert($0.id).inserted }
                onFirstPage?(page)
            } else {
                var seenV = Set(videos.map(\.id))
                videos += page.videos.filter { seenV.insert($0.id).inserted }
                var seenC = Set(channels.map(\.id))
                channels += page.channels.filter { seenC.insert($0.id).inserted }
                var seenP = Set(playlists.map(\.id))
                playlists += page.playlists.filter { seenP.insert($0.id).inserted }
            }
            onVideosChanged?(videos)
            token = page.continuation
            loaded = true
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
            loading = false
            if cancelled { return }
            self.error = error.localizedDescription
            return
        }
        loading = false
    }
}
