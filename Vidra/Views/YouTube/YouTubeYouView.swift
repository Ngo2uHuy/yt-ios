import SwiftUI
import AVKit

// MARK: - YouTube You View (Màn hình "Bạn")

struct YouTubeYouView: View {
    @ObservedObject private var lib = Library.shared
    @ObservedObject private var dl = DownloadManager.shared

    @State private var showSettings = false
    @State private var showSearch = false
    @State private var showHistory = false
    @State private var showDownloads = false
    @State private var showAllPlaylists = false
    @State private var showNewPlaylistAlert = false
    @State private var newPlaylistName = ""
    @State private var showCastSheet = false
    @State private var showNotificationsSheet = false
    @State private var showAccountSheet = false
    @State private var showGoogleAccountAlert = false
    @State private var isIncognitoActive = false
    @State private var showIncognitoToast = false
    @State private var showYourChannelSheet = false
    @State private var showTimeWatchedSheet = false
    @State private var showFeedbackSheet = false
    @State private var showYourMoviesSheet = false
    @State private var showYourVideosSheet = false

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    // 1. Account Info Section
                    accountHeader

                    // 2. Horizontal Quick Action Pills
                    quickActionsScroll

                    // 3. History Section ("Nhật ký xem")
                    historySection

                    // 4. Playlists Section ("Danh sách phát")
                    playlistsSection

                    Divider()
                        .padding(.horizontal)
                        .padding(.vertical, 4)

                    // 5. Utilities List ("Tiện ích")
                    utilitiesList

                    // Bottom padding for mini-player
                    Spacer(minLength: 40)
                }
                .padding(.top, 12)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Top Navigation Bar
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        Button {
                            showCastSheet = true
                        } label: {
                            Image(systemName: "airplayvideo")
                                .font(.system(size: 18))
                                .foregroundStyle(.primary)
                        }

                        Button {
                            showNotificationsSheet = true
                        } label: {
                            Image(systemName: "bell")
                                .font(.system(size: 18))
                                .foregroundStyle(.primary)
                        }

                        Button {
                            showSearch = true
                        } label: {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 18))
                                .foregroundStyle(.primary)
                        }

                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                                .font(.system(size: 18))
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }
            // Navigation destinations
            .navigationDestination(isPresented: $showSettings) {
                SettingsView()
            }
            .navigationDestination(isPresented: $showSearch) {
                SearchView(needsNavigationStack: false)
            }
            .navigationDestination(isPresented: $showHistory) {
                HistoryView()
            }
            .navigationDestination(isPresented: $showDownloads) {
                DownloadsView()
            }
            // Sheets & Alerts
            .sheet(isPresented: $showCastSheet) {
                YouTubeCastSheet()
            }
            .sheet(isPresented: $showNotificationsSheet) {
                YouTubeNotificationsSheet()
            }
            .sheet(isPresented: $showAccountSheet) {
                YouTubeAccountSwitchSheet()
            }
            .sheet(isPresented: $showYourChannelSheet) {
                YouTubeYourChannelSheet()
            }
            .sheet(isPresented: $showTimeWatchedSheet) {
                YouTubeTimeWatchedSheet()
            }
            .sheet(isPresented: $showYourVideosSheet) {
                YouTubeYourVideosSheet()
            }
            .sheet(isPresented: $showYourMoviesSheet) {
                YouTubeYourMoviesSheet()
            }
            .sheet(isPresented: $showFeedbackSheet) {
                YouTubeFeedbackSheet()
            }
            .sheet(isPresented: $showAllPlaylists) {
                YouTubeAllPlaylistsSheet()
            }
            .alert("Tài khoản Google", isPresented: $showGoogleAccountAlert) {
                Button("Đã hiểu", role: .cancel) {}
            } message: {
                Text("Vidra hoạt động ở chế độ cục bộ (Local-first). Bạn không cần đăng nhập Google để trải nghiệm trọn vẹn YouTube không quảng cáo, lưu trữ ngoại tuyến và nghe nhạc nền.")
            }
            .alert("Danh sách phát mới", isPresented: $showNewPlaylistAlert) {
                TextField("Nhập tên danh sách phát", text: $newPlaylistName)
                Button("Tạo") {
                    let trimmed = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        lib.createPlaylist(trimmed)
                        newPlaylistName = ""
                    }
                }
                Button("Huỷ", role: .cancel) {
                    newPlaylistName = ""
                }
            }
            .overlay(alignment: .bottom) {
                if showIncognitoToast {
                    Text(isIncognitoActive ? "Đã bật chế độ ẩn danh" : "Đã tắt chế độ ẩn danh")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color(.systemGray6), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    // MARK: - 1. Account Header

    private var accountHeader: some View {
        Button {
            showYourChannelSheet = true
        } label: {
            HStack(spacing: 16) {
                // Large Avatar (70x70) bo tròn
                ZStack {
                    LinearGradient(
                        colors: [Color.red, Color.purple, Color.blue],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Text("V")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .frame(width: 70, height: 70)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.primary.opacity(0.1), lineWidth: 1.5))
                .shadow(color: Color.black.opacity(0.08), radius: 6, x: 0, y: 3)

                // Name & Handle
                VStack(alignment: .leading, spacing: 4) {
                    Text("Vidra User")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.primary)

                    Text("@vidra_user")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 4) {
                        Text("Xem kênh")
                            .font(.footnote.weight(.medium))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                }

                Spacer()
            }
            .padding(.horizontal)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 2. Quick Action Pills

    private var quickActionsScroll: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // Chuyển đổi tài khoản
                quickPillButton(icon: "person.2", title: "Chuyển đổi tài khoản") {
                    showAccountSheet = true
                }

                // Tài khoản Google
                quickPillButton(icon: "person.crop.circle", title: "Tài khoản Google") {
                    showGoogleAccountAlert = true
                }

                // Bật chế độ ẩn danh
                quickPillButton(
                    icon: isIncognitoActive ? "eyeglasses" : "eye.slash",
                    title: isIncognitoActive ? "Tắt chế độ ẩn danh" : "Bật chế độ ẩn danh",
                    highlight: isIncognitoActive
                ) {
                    withAnimation {
                        isIncognitoActive.toggle()
                        showIncognitoToast = true
                    }
                    Task {
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        withAnimation { showIncognitoToast = false }
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    private func quickPillButton(icon: String, title: String, highlight: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.footnote.weight(.semibold))
                Text(title)
                    .font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                highlight ? Color.primary : Color(.secondarySystemFill),
                in: Capsule()
            )
            .foregroundStyle(
                highlight ? Color(.systemBackground) : Color.primary
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 3. History Section

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: Title & "Xem tất cả"
            HStack {
                Text("Nhật ký xem")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)

                Spacer()

                Button {
                    showHistory = true
                } label: {
                    Text("Xem tất cả")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .overlay(
                            Capsule().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)

            // Horizontal Scroll of recent videos
            if lib.history.isEmpty {
                HStack {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                    Text("Chưa có video nào trong nhật ký xem.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 12)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(lib.history.prefix(15)) { item in
                            YouTubeHistoryCard(video: item.video)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    // MARK: - 4. Playlists Section

    private var playlistsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: Title & "Xem tất cả"
            HStack {
                Text("Danh sách phát")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)

                Spacer()

                Button {
                    showAllPlaylists = true
                } label: {
                    Text("Xem tất cả")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .overlay(
                            Capsule().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)

            // Horizontal Scroll of playlists
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    // Card 1: Xem sau (Watch Later)
                    NavigationLink {
                        LocalVideoList(title: "Xem sau", source: .watchLater)
                    } label: {
                        YouTubePlaylistCard(
                            title: "Xem sau",
                            subtitle: "\(lib.watchLater.count) video",
                            iconName: "clock.fill",
                            thumbnail: lib.watchLater.first?.thumbnail,
                            color: Color.blue
                        )
                    }
                    .buttonStyle(.plain)

                    // Card 2: Video đã thích (Liked Videos)
                    NavigationLink {
                        LocalVideoList(title: "Video đã thích", source: .liked)
                    } label: {
                        YouTubePlaylistCard(
                            title: "Video đã thích",
                            subtitle: "\(lib.likedTracks.count) video",
                            iconName: "hand.thumbsup.fill",
                            thumbnail: lib.likedTracks.first?.thumbnail,
                            color: Color.red
                        )
                    }
                    .buttonStyle(.plain)

                    // Card 3..N: User Custom Playlists
                    ForEach(lib.playlists) { playlist in
                        NavigationLink {
                            LocalVideoList(title: playlist.name, source: .playlist(playlist.id))
                        } label: {
                            YouTubePlaylistCard(
                                title: playlist.name,
                                subtitle: "\(playlist.videos.count) video",
                                iconName: "music.note.list",
                                thumbnail: playlist.videos.first?.thumbnail,
                                color: Color.orange
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    // Card: + Danh sách phát mới
                    Button {
                        showNewPlaylistAlert = true
                    } label: {
                        VStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(.secondarySystemFill))
                                .frame(width: 140, height: 80)
                                .overlay {
                                    VStack(spacing: 4) {
                                        Image(systemName: "plus")
                                            .font(.title2.weight(.medium))
                                            .foregroundStyle(.primary)
                                        Text("Mới")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            Text("Danh sách phát mới")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.primary)
                                .frame(width: 140, alignment: .leading)
                                .lineLimit(1)
                            Text("Tạo danh sách")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(width: 140, alignment: .leading)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal)
            }
        }
    }

    // MARK: - 5. Utilities List

    private var utilitiesList: some View {
        VStack(spacing: 0) {
            // Nội dung tải xuống
            Button {
                showDownloads = true
            } label: {
                YouTubeUtilityRow(
                    icon: "arrow.down.circle",
                    title: "Nội dung tải xuống",
                    subtitle: "\(dl.items.count) video" + (dl.active.isEmpty ? "" : " • Đang tải \(dl.active.count)")
                )
            }
            .buttonStyle(.plain)

            // Video của bạn
            Button {
                showYourVideosSheet = true
            } label: {
                YouTubeUtilityRow(
                    icon: "play.rectangle",
                    title: "Video của bạn",
                    subtitle: "0 video"
                )
            }
            .buttonStyle(.plain)

            // Phim của bạn
            Button {
                showYourMoviesSheet = true
            } label: {
                YouTubeUtilityRow(
                    icon: "film",
                    title: "Phim của bạn",
                    subtitle: "Kho phim và chương trình"
                )
            }
            .buttonStyle(.plain)

            // Thời gian đã xem
            Button {
                showTimeWatchedSheet = true
            } label: {
                YouTubeUtilityRow(
                    icon: "chart.bar.xaxis",
                    title: "Thời gian đã xem",
                    subtitle: "Thống kê thời lượng xem"
                )
            }
            .buttonStyle(.plain)

            // Trợ giúp và phản hồi
            Button {
                showFeedbackSheet = true
            } label: {
                YouTubeUtilityRow(
                    icon: "questionmark.circle",
                    title: "Trợ giúp và phản hồi",
                    subtitle: "Hướng dẫn sử dụng & báo lỗi"
                )
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - YouTube History Card (Horizontal Card)

struct YouTubeHistoryCard: View {
    let video: Video
    @ObservedObject private var lib = Library.shared

    private var progress: Double? {
        guard let total = Fmt.seconds(video.duration), total > 0 else { return nil }
        let p = lib.position(video.id)
        return p > 0 ? min(p / total, 1.0) : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                PlayerManager.shared.play(video)
            } label: {
                // 16:9 Thumbnail
                ZStack(alignment: .bottomTrailing) {
                    Color(.secondarySystemFill)
                        .frame(width: 156, height: 88)
                        .overlay {
                            if let url = video.thumbnail {
                                CachedAsyncImage(url: url, targetSize: CGSize(width: 156, height: 88)) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    Color(.secondarySystemFill)
                                        .overlay(Image(systemName: "play.rectangle.fill").foregroundStyle(.secondary))
                                }
                            } else {
                                Color(.secondarySystemFill)
                                    .overlay(Image(systemName: "play.rectangle.fill").foregroundStyle(.secondary))
                            }
                        }
                        .clipped()

                    // Duration badge
                    if let d = video.duration, !d.isEmpty {
                        Text(d)
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.white)
                            .padding(4)
                    }

                    // Red progress bar
                    if let progress, progress > 0 {
                        GeometryReader { g in
                            Rectangle()
                                .fill(Color.red)
                                .frame(width: g.size.width * min(max(progress, 0), 1), height: 3)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        }
                        .allowsHitTesting(false)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)

            // Title & 3-dots (separate sibling Menu to avoid button conflict)
            HStack(alignment: .top, spacing: 4) {
                Button {
                    PlayerManager.shared.play(video)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(video.title)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

                        Text(video.channelTitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Menu {
                    Button { PlayerManager.shared.playNext(video) } label: {
                        Label("Phát tiếp theo", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                    Button { lib.toggleWatchLater(video) } label: {
                        Label(lib.isInWatchLater(video.id) ? "Bỏ khỏi Xem sau" : "Xem sau", systemImage: "clock")
                    }
                    Menu {
                        Button("Video") { DownloadManager.shared.start(video, audioOnly: false) }
                        Button("Chỉ âm thanh") { DownloadManager.shared.start(video, audioOnly: true) }
                    } label: {
                        Label("Tải xuống", systemImage: "arrow.down.circle")
                    }
                    ShareLink(item: video.shareURL) {
                        Label("Chia sẻ", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .rotationEffect(.degrees(90))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(width: 156)
        }
        .videoMenu(video)
    }
}

// MARK: - YouTube Playlist Card (Horizontal Card)

struct YouTubePlaylistCard: View {
    let title: String
    let subtitle: String
    let iconName: String
    let thumbnail: URL?
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                if let thumbnail {
                    CachedAsyncImage(url: thumbnail, targetSize: CGSize(width: 140, height: 80)) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        placeholderBackground
                    }
                    .frame(width: 140, height: 80)
                    .clipped()
                } else {
                    placeholderBackground
                }

                // Overlay pill with playlist count icon
                HStack(spacing: 3) {
                    Image(systemName: iconName)
                        .font(.system(size: 9))
                    Text(subtitle.components(separatedBy: " ").first ?? "")
                        .font(.system(size: 10, weight: .bold))
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 2.5)
                .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(.white)
                .padding(6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(width: 140, alignment: .leading)

            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 140, alignment: .leading)
        }
    }

    private var placeholderBackground: some View {
        LinearGradient(
            colors: [color.opacity(0.8), color.opacity(0.5)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .frame(width: 140, height: 80)
        .overlay {
            Image(systemName: iconName)
                .font(.title2)
                .foregroundStyle(.white.opacity(0.9))
        }
    }
}

// MARK: - YouTube Utility Row

struct YouTubeUtilityRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(.primary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

// MARK: - YouTube Subscriptions View (Màn hình "Kênh đăng ký")

struct YouTubeSubscriptionsView: View {
    @ObservedObject private var lib = Library.shared
    @State private var feed: [Video] = []
    @State private var loading = false
    @State private var selectedFilter = "Tất cả"
    @State private var showSettings = false
    @State private var showSearch = false
    @State private var showCastSheet = false
    @State private var showNotificationsSheet = false
    @State private var showAllSubscriptions = false
    @State private var selectedVideoForActions: Video? = nil
    @State private var pendingPlaylistVideo: Video? = nil
    @State private var selectedVideoForPlaylists: Video? = nil
    @State private var hiddenVideoIds: Set<String> = []
    @State private var shareTarget: Video? = nil

    private let filters = ["Tất cả", "Hôm nay", "Tiếp tục xem", "Chưa xem", "Trực tiếp", "Bài đăng"]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Top Subscribed Channels Horizontal Bar
                channelsHorizontalBar

                // Feed Filter Chips
                filterChipsRow

                Divider()

                // Subscriptions Video Feed
                feedContent
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Leading: Logo / Title
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
                        Text("Kênh đăng ký")
                            .font(.system(size: 19, weight: .bold, design: .rounded))
                    }
                }

                // Trailing: Cast, Bell, Search
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        Button {
                            showCastSheet = true
                        } label: {
                            Image(systemName: "airplayvideo")
                                .font(.system(size: 18))
                                .foregroundStyle(.primary)
                        }

                        Button {
                            showNotificationsSheet = true
                        } label: {
                            Image(systemName: "bell")
                                .font(.system(size: 18))
                                .foregroundStyle(.primary)
                        }

                        Button {
                            showSearch = true
                        } label: {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 18))
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }
            .navigationDestination(isPresented: $showSearch) {
                SearchView(needsNavigationStack: false)
            }
            .navigationDestination(isPresented: $showAllSubscriptions) {
                SubscriptionsView(needsNavigationStack: false)
            }
            .sheet(isPresented: $showCastSheet) {
                YouTubeCastSheet()
            }
            .sheet(isPresented: $showNotificationsSheet) {
                YouTubeNotificationsSheet()
            }
            .sheet(item: $selectedVideoForActions, onDismiss: {
                if let pending = pendingPlaylistVideo {
                    pendingPlaylistVideo = nil
                    selectedVideoForPlaylists = pending
                }
            }) { video in
                YouTubeVideoActionSheet(
                    video: video,
                    onSaveToPlaylist: {
                        pendingPlaylistVideo = video
                        selectedVideoForActions = nil
                    },
                    onToggleWatchLater: {
                        lib.toggleWatchLater(video)
                    },
                    onDownload: {
                        DownloadManager.shared.start(video, audioOnly: false)
                    },
                    onShare: {
                        shareTarget = video
                    },
                    onNotInterested: {
                        hiddenVideoIds.insert(video.id)
                    },
                    onDontRecommendChannel: {
                        if let cid = video.channelId, !cid.isEmpty {
                            hiddenVideoIds.formUnion(feed.filter { $0.channelId == cid }.map(\.id))
                        }
                    }
                )
                .presentationDetents([.fraction(0.48), .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(item: $selectedVideoForPlaylists) { video in
                YouTubePlaylistPickerSheet(video: video)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(item: $shareTarget) { video in
                ShareLink(item: video.shareURL) {
                    Label("Chia sẻ video", systemImage: "square.and.arrow.up")
                }
                .padding()
                .presentationDetents([.height(140)])
            }
            .task(id: lib.subscriptions.map(\.id)) {
                await loadFeed()
            }
        }
    }

    // MARK: - Channels Horizontal Bar

    private var channelsHorizontalBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                if lib.subscriptions.isEmpty {
                    Text("Chưa đăng ký kênh nào")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 16)
                } else {
                    ForEach(lib.subscriptions) { channel in
                        NavigationLink {
                            ChannelView(channel: channel)
                        } label: {
                            YouTubeChannelAvatarItem(channel: channel)
                        }
                        .buttonStyle(.plain)
                    }

                    // "Tất cả" button at end
                    Button {
                        showAllSubscriptions = true
                    } label: {
                        VStack(spacing: 6) {
                            Circle()
                                .fill(Color(.secondarySystemFill))
                                .frame(width: 56, height: 56)
                                .overlay {
                                    Text("Tất cả")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.blue)
                                }
                            Text("Xem tất cả")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(width: 62)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Filter Chips Row

    private var filterChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(filters, id: \.self) { filter in
                    Button {
                        selectedFilter = filter
                    } label: {
                        Text(filter)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                selectedFilter == filter ? Color.primary : Color(.secondarySystemFill),
                                in: Capsule()
                            )
                            .foregroundStyle(
                                selectedFilter == filter ? Color(.systemBackground) : Color.primary
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Feed Content

    @ViewBuilder
    private var feedContent: some View {
        if lib.subscriptions.isEmpty {
            ScrollView {
                VStack(spacing: 16) {
                    Spacer(minLength: 60)
                    Image(systemName: "person.2.badge.gearshape")
                        .font(.system(size: 64))
                        .foregroundStyle(.secondary)
                    Text("Đừng bỏ lỡ video mới")
                        .font(.title3.bold())
                    Text("Đăng ký các kênh yêu thích của bạn để cập nhật những video mới nhất ngay tại đây.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    Button {
                        showAllSubscriptions = true
                    } label: {
                        Text("Nhập từ Google Takeout")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Color.red, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity)
            }
        } else if loading && feed.isEmpty {
            VStack {
                Spacer()
                ProgressView("Đang tải video mới nhất…")
                    .font(.subheadline)
                    .tint(.red)
                Spacer()
            }
        } else {
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 12) {
                    ForEach(Array(filteredFeed.enumerated()), id: \.element.id) { idx, video in
                        YouTubeVideoCard(
                            video: video,
                            queue: Array(filteredFeed.dropFirst(idx + 1)),
                            onMoreTap: {
                                selectedVideoForActions = video
                            },
                            onCardTap: {
                                PlayerManager.shared.play(video, queue: Array(filteredFeed.dropFirst(idx + 1)))
                            }
                        )
                    }
                }
                .padding(.vertical, 8)
            }
            .refreshable {
                await loadFeed()
            }
        }
    }

    private var filteredFeed: [Video] {
        let base = feed.filter { !hiddenVideoIds.contains($0.id) }
        switch selectedFilter {
        case "Hôm nay":
            return base.filter { video in
                guard let pub = video.published?.lowercased() else { return false }
                let recentMarkers = ["giờ", "phút", "giây", "vừa", "hôm nay", "hour", "minute", "second", "today", "just now"]
                return recentMarkers.contains { pub.contains($0) }
            }
        case "Tiếp tục xem":
            return base.filter { lib.position($0.id) > 0 }
        case "Chưa xem":
            return base.filter { lib.position($0.id) == 0 }
        case "Trực tiếp":
            return base.filter { video in
                let dur = video.duration?.lowercased() ?? ""
                return dur.isEmpty || dur.contains("trực tiếp") || dur.contains("live")
            }
        case "Bài đăng":
            return []
        default:
            return base
        }
    }

    @MainActor
    private func loadFeed() async {
        guard !lib.subscriptions.isEmpty else {
            feed = []
            return
        }
        loading = true
        let items = await Extras.subscriptionFeed(lib.subscriptions)
        if !Task.isCancelled {
            feed = items
        }
        loading = false
    }
}

// MARK: - Subscribed Channel Avatar Item (With Notification Dot)

struct YouTubeChannelAvatarItem: View {
    let channel: Channel

    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .bottomTrailing) {
                // Avatar with circular border
                Avatar(url: channel.avatar, name: channel.title, size: 56)
                    .overlay(Circle().stroke(Color.primary.opacity(0.1), lineWidth: 1))

                // Blue / Green Notification Dot indicating new video
                Circle()
                    .fill(Color.blue)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                    .offset(x: 1, y: 1)
            }

            Text(channel.title)
                .font(.caption2)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(width: 62)
        }
    }
}

// MARK: - Auxiliary Sheets

struct YouTubeCastSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "airplayvideo")
                    .font(.system(size: 60))
                    .foregroundStyle(.blue)
                    .padding(.top, 40)

                Text("Kết nối với thiết bị")
                    .font(.title3.bold())

                Text("Tìm kiếm TV, AirPlay hoặc thiết bị Google Cast trên cùng mạng Wi-Fi của bạn…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                ProgressView()
                    .tint(.blue)

                Spacer()

                Button("Đóng") {
                    dismiss()
                }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 32)
                .padding(.vertical, 12)
                .background(Color(.secondarySystemFill), in: Capsule())
                .foregroundStyle(.primary)
                .padding(.bottom, 24)
            }
            .navigationTitle("Truyền phát")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Xong") { dismiss() }
                }
            }
        }
        .onReceive(PlayerManager.shared.$showWatch) { show in
            if show { dismiss() }
        }
    }
}

struct YouTubeNotificationsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "bell.badge.fill")
                            .font(.title2)
                            .foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Thông báo từ kênh đăng ký")
                                .font(.subheadline.weight(.semibold))
                            Text("Bạn sẽ nhận được thông báo khi có video mới.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Hôm nay") {
                    ForEach(Library.shared.subscriptions.prefix(4)) { channel in
                        HStack(spacing: 12) {
                            Avatar(url: channel.avatar, name: channel.title, size: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(channel.title) vừa đăng tải video mới")
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(2)
                                Text("2 giờ trước")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Thông báo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Đóng") { dismiss() }
                }
            }
        }
    }
}

struct YouTubeAccountSwitchSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Tài khoản đang hoạt động") {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(Color.red)
                            Text("V").font(.headline.bold()).foregroundStyle(.white)
                        }
                        .frame(width: 44, height: 44)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Vidra User (Mặc định)")
                                .font(.subheadline.weight(.semibold))
                            Text("@vidra_user • Cục bộ")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Image(systemName: "checkmark")
                            .font(.subheadline.bold())
                            .foregroundStyle(.blue)
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    Button {
                        dismiss()
                    } label: {
                        Label("Thêm tài khoản khác", systemImage: "plus")
                            .foregroundStyle(.primary)
                    }
                    Button {
                        dismiss()
                    } label: {
                        Label("Sử dụng Vidra không cần tài khoản", systemImage: "person.crop.circle.badge.xmark")
                            .foregroundStyle(.primary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Tài khoản")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Xong") { dismiss() }
                }
            }
        }
        .onReceive(PlayerManager.shared.$showWatch) { show in
            if show { dismiss() }
        }
    }
}

struct YouTubeYourChannelSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                ZStack {
                    LinearGradient(
                        colors: [Color.red, Color.purple, Color.blue],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Text("V")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .frame(width: 90, height: 90)
                .clipShape(Circle())
                .shadow(radius: 6)

                VStack(spacing: 4) {
                    Text("Vidra User")
                        .font(.title2.bold())
                    Text("@vidra_user • Kênh cá nhân Vidra")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Text("\(Library.shared.playlists.count) danh sách phát")
                    Text("•")
                    Text("\(Library.shared.history.count) video đã xem")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)

                Divider().padding(.horizontal)

                VStack(alignment: .leading, spacing: 14) {
                    Text("Giới thiệu")
                        .font(.headline)
                    Text("Kênh người dùng cá nhân của bạn trên ứng dụng Vidra. Toàn bộ lịch sử xem, video yêu thích và danh sách phát đều được lưu trữ bảo mật ngay trên thiết bị của bạn.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

                Spacer()
            }
            .padding(.top, 24)
            .navigationTitle("Kênh của bạn")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Xong") { dismiss() }
                }
            }
        }
        .onReceive(PlayerManager.shared.$showWatch) { show in
            if show { dismiss() }
        }
    }
}

struct YouTubeTimeWatchedSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var lib = Library.shared

    private var estimatedWatchMinutes: Int {
        let historyCount = lib.history.count
        return min(historyCount * 12, 1440)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Số liệu thống kê") {
                    HStack {
                        Text("Hôm nay")
                        Spacer()
                        Text("\(estimatedWatchMinutes / 3) phút")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("7 ngày qua")
                        Spacer()
                        let hours = Double(estimatedWatchMinutes) / 60.0
                        Text(String(format: "%.1f giờ", hours))
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Số video đã xem")
                        Spacer()
                        Text("\(lib.history.count) video")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Công cụ quản lý thời gian xem") {
                    Toggle("Nhắc tôi tạm dừng xem", isOn: .constant(false))
                    Toggle("Nhắc tôi khi đến giờ đi ngủ", isOn: .constant(false))
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Thời gian đã xem")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Xong") { dismiss() }
                }
            }
        }
        .onReceive(PlayerManager.shared.$showWatch) { show in
            if show { dismiss() }
        }
    }
}

struct YouTubeYourVideosSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "video.badge.plus")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
                Text("Chưa có video nào")
                    .font(.title3.bold())
                Text("Các video bạn tải lên hoặc lưu trữ nội bộ sẽ xuất hiện tại đây.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Spacer()
            }
            .navigationTitle("Video của bạn")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Đóng") { dismiss() }
                }
            }
        }
    }
}

struct YouTubeYourMoviesSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "film")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
                Text("Chưa có phim nào")
                    .font(.title3.bold())
                Text("Các bộ phim và chương trình bạn đã lưu sẽ hiển thị ở đây.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Spacer()
            }
            .navigationTitle("Phim của bạn")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Đóng") { dismiss() }
                }
            }
        }
    }
}

struct YouTubeFeedbackSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var feedbackText = ""
    @State private var sent = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Phản hồi & Báo lỗi") {
                    TextEditor(text: $feedbackText)
                        .frame(minHeight: 120)
                }

                Section {
                    Button {
                        sent = true
                        Task {
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                            dismiss()
                        }
                    } label: {
                        HStack {
                            Spacer()
                            Text(sent ? "Đã gửi! Cảm ơn bạn" : "Gửi ý kiến phản hồi")
                                .bold()
                            Spacer()
                        }
                    }
                    .disabled(feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sent)
                }
            }
            .navigationTitle("Trợ giúp và phản hồi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Huỷ") { dismiss() }
                }
            }
        }
    }
}

struct YouTubeAllPlaylistsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var lib = Library.shared

    var body: some View {
        NavigationStack {
            List {
                Section("Danh sách hệ thống") {
                    NavigationLink {
                        LocalVideoList(title: "Xem sau", source: .watchLater)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "clock.fill").foregroundStyle(.blue).frame(width: 24)
                            Text("Xem sau")
                            Spacer()
                            Text("\(lib.watchLater.count)").foregroundStyle(.secondary)
                        }
                    }

                    NavigationLink {
                        LocalVideoList(title: "Video đã thích", source: .liked)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "hand.thumbsup.fill").foregroundStyle(.red).frame(width: 24)
                            Text("Video đã thích")
                            Spacer()
                            Text("\(lib.likedTracks.count)").foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Danh sách cá nhân (\(lib.playlists.count))") {
                    if lib.playlists.isEmpty {
                        Text("Chưa có danh sách phát nào do bạn tạo.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(lib.playlists) { playlist in
                        NavigationLink {
                            LocalVideoList(title: playlist.name, source: .playlist(playlist.id))
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "music.note.list").foregroundStyle(.orange).frame(width: 24)
                                Text(playlist.name)
                                Spacer()
                                Text("\(playlist.videos.count)").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Tất cả danh sách phát")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Xong") { dismiss() }
                }
            }
        }
        .onReceive(PlayerManager.shared.$showWatch) { show in
            if show { dismiss() }
        }
    }
}
