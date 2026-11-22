import SwiftUI

struct Thumbnail: View {
    let url: URL?
    var duration: String?
    var progress: Double?

    var body: some View {
        Color(.secondarySystemFill)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
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
                        Rectangle().fill(Color.red).frame(width: g.size.width * min(progress, 1), height: 3)
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

    private var meta: String {
        [video.views, video.published].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " • ")
    }

    private var progress: Double? {
        guard let total = Fmt.seconds(video.duration), total > 0 else { return nil }
        let p = Library.shared.position(video.id)
        return p > 0 ? p / total : nil
    }

    var body: some View {
        if let source = video.source {
            HStack(spacing: 12) {
                Color(.secondarySystemFill)
                    .frame(width: 56, height: 56)
                    .overlay {
                        AsyncImage(url: video.thumbnail) { $0.resizable().scaledToFill() } placeholder: {
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
                Thumbnail(url: video.thumbnail, duration: video.duration, progress: progress).frame(width: 168)
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
            VStack(alignment: .leading, spacing: 8) {
                Thumbnail(url: video.thumbnail, duration: video.duration, progress: progress)
                VStack(alignment: .leading, spacing: 3) {
                    Text(video.title).font(.body.weight(.semibold)).lineLimit(2)
                    Text([video.channelTitle, meta].filter { !$0.isEmpty }.joined(separator: " • "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                .padding(.horizontal, 4)
            }
        }
    }
}

extension MediaSource {
    var iconName: String {
        switch self {
        case .ytMusic: return "music.note"
        case .soundCloud: return "cloud.fill"
        case .spotify: return "dot.radiowaves.right"
        }
    }

    var tint: Color {
        switch self {
        case .ytMusic: return .red
        case .soundCloud: return .orange
        case .spotify: return .green
        }
    }
}

struct VideoButton: View {
    let video: Video
    var compact = true
    var queue: [Video]?

    var body: some View {
        Button {
            PlayerManager.shared.play(video, queue: queue)
        } label: {
            VideoRow(video: video, compact: compact).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .videoMenu(video)
    }
}

struct VideoMenu: ViewModifier {
    let video: Video
    @ObservedObject private var lib = Library.shared

    func body(content: Content) -> some View {
        content.contextMenu {
            Button { PlayerManager.shared.playNext(video) } label: {
                Label("Phát tiếp theo", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            Button { PlayerManager.shared.queue.append(video) } label: {
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
                if video.source != .soundCloud {
                    Button("Video") { DownloadManager.shared.start(video, audioOnly: false) }
                }
                Button("Chỉ âm thanh") { DownloadManager.shared.start(video, audioOnly: true) }
            } label: {
                Label("Tải xuống", systemImage: "arrow.down.circle")
            }
            ShareLink(item: video.shareURL) { Label("Chia sẻ", systemImage: "square.and.arrow.up") }
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
        AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: {
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
            Text(subscribed ? "Đã đăng ký" : "Đăng ký").font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .tint(subscribed ? .gray : .red)
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

/// Infinite-scroll list over any continuation-based InnerTube endpoint.
struct PagedList: View {
    let loader: (String?) async throws -> Page
    var header: AnyView?
    var compact = true
    var onFirstPage: ((Page) -> Void)?

    @State private var videos: [Video] = []
    @State private var channels: [Channel] = []
    @State private var token: String?
    @State private var loading = false
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        List {
            if let header { header.listRowSeparator(.hidden) }
            ForEach(channels) { c in
                NavigationLink { ChannelView(channel: c) } label: { ChannelRow(channel: c) }
            }
            ForEach(videos) { v in
                VideoButton(video: v, compact: compact)
                    .listRowSeparator(.hidden)
                    .onAppear { if v.id == videos.last?.id { loadMore() } }
            }
            if loading {
                ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden)
            }
            if let error {
                VStack(spacing: 8) {
                    Text(error).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Thử lại") { Task { await load(reset: videos.isEmpty) } }
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
            }
            if loaded && !loading && error == nil && videos.isEmpty && channels.isEmpty {
                EmptyState(icon: "magnifyingglass", title: "Không có kết quả").listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .task {
            guard !loaded else { return }
            await load(reset: true)
        }
        .refreshable { await load(reset: true) }
    }

    private func loadMore() {
        guard token != nil, !loading, error == nil else { return }
        Task { await load(reset: false) }
    }

    private func load(reset: Bool) async {
        guard !loading else { return }
        loading = true
        error = nil
        do {
            let page = try await loader(reset ? nil : token)
            if reset {
                videos = page.videos
                channels = page.channels
                onFirstPage?(page)
            } else {
                let seen = Set(videos.map(\.id))
                videos += page.videos.filter { !seen.contains($0.id) }
            }
            token = page.continuation
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
            loading = false
            // Leave `loaded` false so the next appearance retries.
            if cancelled { return }
            self.error = error.localizedDescription
        }
        loading = false
        loaded = true
    }
}
