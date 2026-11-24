import SwiftUI

struct WatchView: View {
    var body: some View {
        YouTubeWatchView()
    }
}

struct WatchDetails: View {
    @ObservedObject private var pm = PlayerManager.shared
    @ObservedObject private var lib = Library.shared
    @ObservedObject private var dl = DownloadManager.shared
    @AppStorage(Pref.autoplayKey) private var autoplay = true
    @State private var votes: Votes?
    @State private var expanded = false
    @State private var showComments = false
    @State private var showPlaylists = false

    var body: some View {
        if let v = pm.current {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(v.title.isEmpty ? "Đang tải…" : v.title).font(.headline)
                        Text(metaLine(v)).font(.caption).foregroundStyle(.secondary)
                    }
                    channelRow(v)
                    actions(v)
                    description
                    if !pm.queue.isEmpty {
                        HStack {
                            Text("Hàng đợi (\(pm.queue.count))").font(.headline)
                            Spacer()
                            Button("Xoá") { pm.clearQueue() }.font(.subheadline)
                        }
                        ForEach(pm.queue) { q in VideoButton(video: q) }
                    }
                    HStack {
                        Text(v.source == nil ? "Tiếp theo" : "Radio – phát tiếp").font(.headline)
                        Spacer()
                        Toggle("Tự phát", isOn: $autoplay).fixedSize().font(.subheadline)
                    }
                    if pm.related.isEmpty {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                    ForEach(pm.related) { r in VideoButton(video: r) }
                }
                .padding()
            }
            .environment(\.openURL, OpenURLAction { url in handle(url) })
            .task(id: v.id) {
                votes = nil
                expanded = false
                guard v.source == nil || v.source == .ytMusic else { return }
                votes = await Extras.votes(v.id)
            }
            .sheet(isPresented: $showComments) {
                NavigationStack { CommentsView(token: pm.commentsToken) }
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showPlaylists) {
                AddToPlaylistView(video: v).presentationDetents([.medium, .large])
            }
        }
    }

    private func metaLine(_ v: Video) -> String {
        var parts: [String] = []
        if let n = pm.info?.viewCount { parts.append("\(n.formatted()) lượt xem") } else if let s = v.views { parts.append(s) }
        if let p = v.published { parts.append(p) }
        if pm.info?.isLive == true { parts.append("🔴 Trực tiếp") }
        return parts.joined(separator: " • ")
    }

    @ViewBuilder
    private func channelRow(_ v: Video) -> some View {
        if let id = v.channelId {
            let known = lib.subscriptions.first { $0.id == id }
            let channel = Channel(id: id, title: v.channelTitle, avatar: known?.avatar)
            HStack {
                NavigationLink { ChannelView(channel: channel) } label: {
                    HStack {
                        Avatar(url: channel.avatar, name: v.channelTitle, size: 36)
                        Text(v.channelTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                SubscribeButton(channel: channel)
            }
        } else if !v.channelTitle.isEmpty {
            Text(v.channelTitle).font(.subheadline.weight(.semibold))
        }
    }

    private func actions(_ v: Video) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let votes {
                    HStack(spacing: 8) {
                        Label(Fmt.count(votes.likes), systemImage: "hand.thumbsup.fill")
                        Divider().frame(height: 12)
                        Label(Fmt.count(votes.dislikes), systemImage: "hand.thumbsdown.fill")
                    }
                    .modifier(Pill())
                }
                Button { lib.toggleWatchLater(v) } label: {
                    Label("Xem sau", systemImage: lib.isInWatchLater(v.id) ? "clock.fill" : "clock").modifier(Pill())
                }
                Button { showPlaylists = true } label: {
                    Label("Lưu", systemImage: "text.badge.plus").modifier(Pill())
                }
                downloadButton(v)
                ShareLink(item: v.shareURL) { Label("Chia sẻ", systemImage: "square.and.arrow.up").modifier(Pill()) }
                Button { showComments = true } label: {
                    Label("Bình luận", systemImage: "text.bubble").modifier(Pill())
                }
                .disabled(pm.commentsToken == nil)
                Button { pm.toggleAudioOnly() } label: {
                    Label("Chỉ âm thanh", systemImage: pm.audioOnly ? "headphones.circle.fill" : "headphones").modifier(Pill())
                }
                Button { pm.loop.toggle() } label: {
                    Label("Lặp", systemImage: pm.loop ? "repeat.1.circle.fill" : "repeat.1").modifier(Pill())
                }
                SleepMenu().modifier(Pill())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
        }
    }

    @ViewBuilder
    private func downloadButton(_ v: Video) -> some View {
        if let a = dl.active[v.id] {
            Button { dl.cancel(v.id) } label: {
                Label("\(Int(a.progress * 100))%", systemImage: "xmark.circle").modifier(Pill())
            }
        } else if dl.isDownloaded(v.id) {
            Label("Đã tải", systemImage: "checkmark.circle.fill").modifier(Pill())
        } else {
            Menu {
                Button("Video") { dl.start(v, audioOnly: false) }
                Button("Chỉ âm thanh") { dl.start(v, audioOnly: true) }
            } label: {
                Label("Tải xuống", systemImage: "arrow.down.circle").modifier(Pill())
            }
        }
    }

    @ViewBuilder
    private var description: some View {
        if let text = pm.info?.description, !text.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(Self.linkified(text)).font(.subheadline).lineLimit(expanded ? nil : 3)
                Button(expanded ? "Thu gọn" : "Xem thêm") { expanded.toggle() }.font(.caption.weight(.semibold))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    /// Timestamps seek in place; YouTube links open in-app; other links go to Safari.
    private func handle(_ url: URL) -> OpenURLAction.Result {
        if url.scheme == "vidra-seek", let t = Double(url.absoluteString.dropFirst("vidra-seek:".count)) {
            pm.seek(to: t)
            return .handled
        }
        if case .video(let id)? = YTLink.parse(url.absoluteString) {
            pm.play(Video(id: id, title: "", channelTitle: ""))
            return .handled
        }
        return .systemAction
    }

    static func linkified(_ s: String) -> AttributedString {
        var a = AttributedString(s)
        let full = NSRange(location: 0, length: (s as NSString).length)
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for m in detector.matches(in: s, range: full) {
                guard let url = m.url, let r = Range(m.range, in: s), let ar = Range(r, in: a) else { continue }
                a[ar].link = url
            }
        }
        if let re = try? NSRegularExpression(pattern: #"(?<![\d:/=])(?:\d{1,2}:)?\d{1,2}:\d{2}(?![\d:])"#) {
            for m in re.matches(in: s, range: full) {
                guard let r = Range(m.range, in: s), let ar = Range(r, in: a),
                      a[ar].link == nil, let secs = Fmt.seconds(String(s[r])) else { continue }
                a[ar].link = URL(string: "vidra-seek:\(Int(secs))")
            }
        }
        return a
    }
}

struct CommentsView: View {
    let token: String?

    @State private var comments: [Comment] = []
    @State private var next: String?
    @State private var loading = false
    @State private var error: String?
    @State private var started = false

    var body: some View {
        List {
            ForEach(comments) { c in
                HStack(alignment: .top, spacing: 10) {
                    Avatar(url: c.avatar, name: c.author, size: 32)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(c.author) • \(c.published)").font(.caption).foregroundStyle(.secondary)
                        Text(c.text).font(.subheadline)
                        if !c.likes.isEmpty {
                            Label(c.likes, systemImage: "hand.thumbsup").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onAppear { if c.id == comments.last?.id { Task { await load() } } }
            }
            if loading { ProgressView().frame(maxWidth: .infinity) }
            if let error { Text(error).foregroundStyle(.secondary) }
            if started && !loading && comments.isEmpty && error == nil {
                Text("Không có bình luận").foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Bình luận")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !started else { return }
            started = true
            next = token
            await load()
        }
    }

    private func load() async {
        guard let t = next, !loading else { return }
        loading = true
        do {
            let r = try await InnerTube.shared.comments(t)
            let seen = Set(comments.map(\.id))
            comments += r.items.filter { !seen.contains($0.id) }
            next = r.next
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

struct AddToPlaylistView: View {
    let video: Video
    @ObservedObject private var lib = Library.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Tên danh sách mới", text: $name)
                        Button("Tạo") {
                            lib.add(video, to: lib.createPlaylist(name))
                            name = ""
                        }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section {
                    ForEach(lib.playlists) { p in
                        Button { lib.toggle(video, in: p.id) } label: {
                            HStack {
                                Text(p.name)
                                Spacer()
                                if lib.contains(video.id, in: p.id) { Image(systemName: "checkmark").foregroundStyle(.red) }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            .navigationTitle("Lưu vào danh sách phát")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Xong") { dismiss() } }
        }
    }
}
