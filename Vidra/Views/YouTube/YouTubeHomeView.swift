import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - YouTube Home Feed View

/// 100% Faithful YouTube iOS Home Feed Screen.
/// Includes top navigation header, horizontal category chips, full-bleed 16:9 video cards,
/// pagination, pull-to-refresh, and native YouTube bottom sheet actions.
struct YouTubeHomeView: View {
    @ObservedObject private var lib = Library.shared

    // Feed state
    @State private var selectedCategory: String = "Tất cả"
    @State private var videos: [Video] = []
    @State private var continuationToken: String? = nil
    @State private var isLoading: Bool = false
    @State private var isLoadingMore: Bool = false
    @State private var errorMessage: String? = nil
    @State private var loadTask: Task<Void, Never>? = nil
    @State private var nextPageTask: Task<Void, Never>? = nil
    @State private var scrollToTopToken: Int = 0

    // Sheets & Dialogs
    @State private var selectedVideoForActions: Video? = nil
    @State private var pendingPlaylistVideo: Video? = nil
    @State private var selectedVideoForPlaylists: Video? = nil
    @State private var showSearchSheet: Bool = false
    @State private var showCastAlert: Bool = false
    @State private var showNotificationsSheet: Bool = false
    @State private var showExploreSheet: Bool = false

    // Hidden items (User feedback actions: "Not interested" / "Don't recommend channel")
    @State private var hiddenVideoIds: Set<String> = []
    @State private var hiddenChannelIds: Set<String> = []
    @State private var hiddenChannelTitles: Set<String> = []

    // Toast feedback
    @State private var toastMessage: String? = nil
    @State private var undoAction: (() -> Void)? = nil
    @State private var toastTimer: Task<Void, Never>? = nil

    // User preference for card style (full-bleed 0 or card 12pt)
    @AppStorage("yt_feed_corner_radius") private var cardCornerRadiusSetting: Double = 0.0

    init() {}

    private var visibleVideos: [Video] {
        videos.filter { video in
            if hiddenVideoIds.contains(video.id) { return false }
            if let channelId = video.channelId, hiddenChannelIds.contains(channelId) { return false }
            if hiddenChannelTitles.contains(video.channelTitle) { return false }
            return true
        }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                YTColor.background
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    // Top YouTube Header
                    YouTubeHeader(
                        title: "YouTube",
                        countryCode: "VN",
                        showModeSwitch: true,
                        showCast: true,
                        showNotifications: true,
                        showSearch: true,
                        notificationCount: 3,
                        onCast: {
                            showCastAlert = true
                        },
                        onNotifications: {
                            showNotificationsSheet = true
                        },
                        onSearch: {
                            showSearchSheet = true
                        },
                        onLogoTap: {
                            scrollToTopAndRefresh()
                        }
                    )

                    // Horizontal Category Chips Bar
                    YouTubeCategoryChips(
                        selectedCategory: $selectedCategory,
                        showExploreButton: true,
                        onExploreTap: {
                            showExploreSheet = true
                        },
                        onSelect: { category in
                            Task {
                                await switchCategory(category)
                            }
                        }
                    )

                    // Divider below chips
                    Rectangle()
                        .fill(YTColor.separator)
                        .frame(height: 0.5)

                    // Main Feed Content
                    feedContent
                }

                // Toast Banner Notification with Undo
                if let toast = toastMessage {
                    toastBanner(message: toast)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 60)
                }
            }
            .navigationBarHidden(true)
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
                        let inWL = lib.isInWatchLater(video.id)
                        showToast(inWL ? "Đã lưu vào danh sách Xem sau" : "Đã xóa khỏi danh sách Xem sau")
                    },
                    onDownload: {
                        DownloadManager.shared.start(video, audioOnly: false)
                        showToast("Đang tải xuống video…")
                    },
                    onShare: {
                        shareVideo(video)
                    },
                    onNotInterested: {
                        hideVideo(video)
                    },
                    onDontRecommendChannel: {
                        hideChannel(video)
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
            .sheet(isPresented: $showSearchSheet) {
                SearchView()
            }
            .onReceive(PlayerManager.shared.$showWatch) { show in
                if show && showSearchSheet {
                    showSearchSheet = false
                }
            }
            .sheet(isPresented: $showNotificationsSheet) {
                YouTubeNotificationsView()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showExploreSheet) {
                YouTubeExploreSheet(onSelectCategory: { cat in
                    showExploreSheet = false
                    selectedCategory = cat
                    Task { await switchCategory(cat) }
                })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .alert("Kết nối thiết bị", isPresented: $showCastAlert) {
                Button("Tìm kiếm AirPlay / Chromecast", role: .none) {}
                Button("Hủy", role: .cancel) {}
            } message: {
                Text("Tìm kiếm các TV và loa không dây đang sẵn sàng kết nối cùng mạng Wi-Fi.")
            }
            .task {
                if videos.isEmpty {
                    await loadInitialFeed()
                }
            }
        }
    }

    // MARK: - Feed Content

    @ViewBuilder
    private var feedContent: some View {
        if isLoading && videos.isEmpty {
            // YouTube Shimmer Skeleton Placeholder
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 24) {
                    ForEach(0..<4, id: \.self) { _ in
                        YouTubeVideoCardSkeleton(cornerRadius: CGFloat(cardCornerRadiusSetting))
                    }
                }
                .padding(.top, 8)
            }
        } else if let error = errorMessage, videos.isEmpty {
            // Error State
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 48))
                    .foregroundStyle(YTColor.brandRed)

                Text("Không thể tải nội dung")
                    .font(.headline)
                    .foregroundStyle(YTColor.textPrimary)

                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(YTColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Button {
                    Task { await loadInitialFeed() }
                } label: {
                    Text("Thử lại")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(YTColor.background)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(YTColor.textPrimary, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 8)

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if selectedCategory == "Đã xem" && visibleVideos.isEmpty {
            // Empty History State
            VStack(spacing: 14) {
                Spacer()
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 44))
                    .foregroundStyle(YTColor.textSecondary)

                Text("Chưa có video nào đã xem")
                    .font(.headline)
                    .foregroundStyle(YTColor.textPrimary)

                Text("Các video bạn đã xem trên Vidra sẽ được lưu cục bộ và xuất hiện tại đây.")
                    .font(.subheadline)
                    .foregroundStyle(YTColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Active Feed List
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        Color.clear
                            .frame(height: 1)
                            .id("FEED_TOP")

                        ForEach(Array(visibleVideos.enumerated()), id: \.element.id) { idx, video in
                            YouTubeVideoCard(
                                video: video,
                                cornerRadius: CGFloat(cardCornerRadiusSetting),
                                onMoreTap: {
                                    selectedVideoForActions = video
                                },
                                onCardTap: {
                                    PlayerManager.shared.play(video, queue: Array(visibleVideos.dropFirst(idx + 1)))
                                    PlayerManager.shared.showWatch = true
                                }
                            )
                            .onAppear {
                                if video.id == visibleVideos.last?.id {
                                    loadNextPage()
                                }
                            }

                            // Full-bleed or card separator
                            if cardCornerRadiusSetting == 0 {
                                Rectangle()
                                    .fill(YTColor.separator.opacity(0.35))
                                    .frame(height: 4)
                                    .padding(.bottom, 12)
                            } else {
                                Spacer().frame(height: 16)
                            }
                        }

                        // Pagination Loader
                        if isLoadingMore {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .tint(YTColor.brandRed)
                                Text("Đang tải thêm video…")
                                    .font(.caption)
                                    .foregroundStyle(YTColor.textSecondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                        }
                    }
                    .padding(.top, cardCornerRadiusSetting == 0 ? 0 : 8)
                }
                .refreshable {
                    await refreshFeed()
                }
                .onChange(of: scrollToTopToken) { _ in
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo("FEED_TOP", anchor: .top)
                    }
                }
            }
        }
    }

    // MARK: - Actions & Data Fetching

    private func scrollToTopAndRefresh() {
        scrollToTopToken += 1
        Task {
            await refreshFeed()
        }
    }

    private func switchCategory(_ category: String) async {
        selectedCategory = category
        await loadInitialFeed()
    }

    private func loadInitialFeed() async {
        loadTask?.cancel()
        nextPageTask?.cancel()
        isLoadingMore = false
        videos = []
        continuationToken = nil
        errorMessage = nil

        let targetCategory = selectedCategory
        let task = Task {
            isLoading = true
            defer {
                if !Task.isCancelled {
                    isLoading = false
                }
            }

            do {
                if targetCategory == "Đã xem" {
                    videos = lib.history.map(\.video)
                    return
                }

                let query = queryForCategory(targetCategory)
                let page = try await InnerTube.shared.search(query, params: nil, continuation: nil)
                guard !Task.isCancelled, selectedCategory == targetCategory else { return }

                videos = page.videos
                continuationToken = page.continuation
            } catch {
                guard !(error is CancellationError), !Task.isCancelled, selectedCategory == targetCategory else { return }
                errorMessage = error.localizedDescription
            }
        }
        loadTask = task
        await task.value
    }

    private func refreshFeed() async {
        let targetCategory = selectedCategory
        do {
            if targetCategory == "Đã xem" {
                videos = lib.history.map(\.video)
                return
            }

            let query = queryForCategory(targetCategory)
            let page = try await InnerTube.shared.search(query, params: nil, continuation: nil)
            guard !Task.isCancelled, selectedCategory == targetCategory else { return }
            videos = page.videos
            continuationToken = page.continuation
            errorMessage = nil
        } catch {
            guard !(error is CancellationError), !Task.isCancelled else { return }
            if videos.isEmpty {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func loadNextPage() {
        guard !isLoadingMore, !isLoading, let token = continuationToken else { return }
        let targetCategory = selectedCategory
        isLoadingMore = true

        nextPageTask?.cancel()
        nextPageTask = Task {
            defer { isLoadingMore = false }
            do {
                let query = queryForCategory(targetCategory)
                let page = try await InnerTube.shared.search(query, params: nil, continuation: token)
                guard !Task.isCancelled, selectedCategory == targetCategory else { return }

                let existing = Set(videos.map(\.id))
                let newVideos = page.videos.filter { !existing.contains($0.id) }
                videos.append(contentsOf: newVideos)
                continuationToken = page.continuation
            } catch {
                // Silently ignore pagination failures; user can scroll to retrigger
            }
        }
    }

    private func queryForCategory(_ category: String) -> String {
        switch category {
        case "Tất cả": return "Thịnh hành"
        case "Âm nhạc": return "Âm nhạc thịnh hành"
        case "Trò chơi": return "Gaming"
        case "Tin tức": return "Tin tức mới nhất"
        case "Bóng đá": return "Bóng đá highlights"
        case "Podcasts": return "Podcast"
        case "Hoạt hình": return "Hoạt hình"
        case "Mới tải lên": return "Video mới tải lên"
        case "Học tập": return "Kiến thức học tập"
        case "Công nghệ": return "Công nghệ review"
        case "Nấu ăn": return "Món ăn ngon nấu ăn"
        case "Du lịch": return "Du lịch khám phá"
        default: return category
        }
    }

    // MARK: - Hide & User Feedback

    private func hideVideo(_ video: Video) {
        hiddenVideoIds.insert(video.id)
        showToast("Đã ẩn video khỏi bảng tin", undo: {
            hiddenVideoIds.remove(video.id)
        })
    }

    private func hideChannel(_ video: Video) {
        if let cId = video.channelId, !cId.isEmpty {
            hiddenChannelIds.insert(cId)
        }
        if !video.channelTitle.isEmpty {
            hiddenChannelTitles.insert(video.channelTitle)
        }
        showToast("Sẽ không đề xuất video từ kênh này nữa", undo: {
            if let cId = video.channelId { hiddenChannelIds.remove(cId) }
            if !video.channelTitle.isEmpty { hiddenChannelTitles.remove(video.channelTitle) }
        })
    }

    private func showToast(_ message: String, undo: (() -> Void)? = nil) {
        toastTimer?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            toastMessage = message
            undoAction = undo
        }
        toastTimer = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                toastMessage = nil
                undoAction = nil
            }
        }
    }

    private func shareVideo(_ video: Video) {
        #if canImport(UIKit)
        let av = UIActivityViewController(activityItems: [video.shareURL], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
           let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController ?? scene.windows.first?.rootViewController {
            var top = root
            while let presented = top.presentedViewController { top = presented }
            if let popover = av.popoverPresentationController {
                popover.sourceView = top.view
                popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            top.present(av, animated: true)
        }
        #endif
    }

    // MARK: - Toast Banner View

    private func toastBanner(message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(YTColor.brandRed)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white)
                .lineLimit(2)

            Spacer(minLength: 4)

            if let undo = undoAction {
                Button("Hoàn tác") {
                    undo()
                    withAnimation {
                        toastMessage = nil
                        undoAction = nil
                    }
                }
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color(red: 0.2, green: 0.6, blue: 1.0))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(red: 0.16, green: 0.16, blue: 0.16))
                .shadow(color: .black.opacity(0.35), radius: 10, y: 5)
        )
        .padding(.horizontal, 16)
    }
}

// MARK: - YouTube Video Card Component

/// Official YouTube iOS Video Feed Card.
/// Supports 16:9 full-bleed layout, corner radius 0 or 12pt,
/// duration badge, playback progress bar, circular channel avatar, 2-line title, and 3-dots action menu.
struct YouTubeVideoCard: View {
    let video: Video
    var cornerRadius: CGFloat = 0
    var queue: [Video]? = nil
    var onMoreTap: (() -> Void)? = nil
    var onCardTap: (() -> Void)? = nil

    @ObservedObject private var lib = Library.shared
    @State private var isPressed: Bool = false

    init(
        video: Video,
        cornerRadius: CGFloat = 0,
        queue: [Video]? = nil,
        onMoreTap: (() -> Void)? = nil,
        onCardTap: (() -> Void)? = nil
    ) {
        self.video = video
        self.cornerRadius = cornerRadius
        self.queue = queue
        self.onMoreTap = onMoreTap
        self.onCardTap = onCardTap
    }

    /// Watch progress calculation: (last playback seconds) / (total video duration)
    private var watchProgress: Double? {
        guard let total = Fmt.seconds(video.duration), total > 0 else { return nil }
        let pos = lib.position(video.id)
        return pos > 0 ? min(pos / total, 1.0) : nil
    }

    /// Known avatar from user subscriptions if subscribed
    private var channelAvatarURL: URL? {
        lib.subscriptions.first { $0.id == video.channelId }?.avatar
    }

    /// Formatted subtitle: "Channel name • Views • Publish date"
    private var formattedSubtitle: String {
        var parts: [String] = []

        if !video.channelTitle.isEmpty {
            parts.append(video.channelTitle)
        }

        if let views = video.views, !views.isEmpty {
            let trimmed = views.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().contains("lượt") || trimmed.lowercased().contains("view") {
                parts.append(trimmed)
            } else {
                parts.append("\(trimmed) lượt xem")
            }
        }

        if let pub = video.published, !pub.isEmpty {
            parts.append(pub)
        }

        return parts.joined(separator: " • ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 1. Thumbnail Container (16:9 full bleed or card)
            Button {
                if let onCardTap {
                    onCardTap()
                } else {
                    PlayerManager.shared.play(video, queue: queue)
                }
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    Color(.secondarySystemFill)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .overlay {
                            CachedAsyncImage(url: video.thumbnail, targetSize: CGSize(width: 480, height: 270)) { image in
                                image
                                    .resizable()
                                    .scaledToFill()
                            } placeholder: {
                                ZStack {
                                    Color(.secondarySystemFill)
                                    Image(systemName: "play.rectangle.fill")
                                        .font(.system(size: 38))
                                        .foregroundStyle(YTColor.textSecondary.opacity(0.45))
                                }
                            }
                        }
                        .clipped()

                    // Video duration badge: Black badge bottom-right, monospaced digits, 4pt padding
                    if let duration = video.duration, !duration.isEmpty {
                        Text(duration)
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2.5)
                            .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .foregroundStyle(.white)
                            .padding(8)
                    }

                    // Red progress bar at bottom of thumbnail if watched partially
                    if let progress = watchProgress, progress > 0 {
                        GeometryReader { geo in
                            Rectangle()
                                .fill(YTColor.brandRed)
                                .frame(width: geo.size.width * min(max(progress, 0), 1), height: 3.5)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        }
                        .allowsHitTesting(false)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .buttonStyle(SpringPressButtonStyle())

            // 2. Info Row below thumbnail
            HStack(alignment: .top, spacing: 12) {
                // Channel circular avatar (36x36)
                NavigationLink {
                    if let channelId = video.channelId {
                        ChannelView(channel: Channel(id: channelId, title: video.channelTitle, avatar: channelAvatarURL))
                    } else {
                        EmptyView()
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(YTColor.cardBackground)
                            .frame(width: 36, height: 36)

                        if let avatar = channelAvatarURL {
                            CachedAsyncImage(url: avatar, targetSize: CGSize(width: 36, height: 36)) { img in
                                img.resizable().scaledToFill()
                            } placeholder: {
                                channelInitialsView
                            }
                            .clipShape(Circle())
                            .frame(width: 36, height: 36)
                        } else {
                            channelInitialsView
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(video.channelId == nil)

                // Title and Metadata column
                VStack(alignment: .leading, spacing: 4) {
                    // Video title: 2 lines max
                    Text(video.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(YTColor.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    // Subtitle: "Channel • Views • Publish date"
                    if !formattedSubtitle.isEmpty {
                        Text(formattedSubtitle)
                            .font(.caption)
                            .foregroundStyle(YTColor.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if let onCardTap {
                        onCardTap()
                    } else {
                        PlayerManager.shared.play(video, queue: queue)
                    }
                }

                Spacer(minLength: 4)

                // 3-dots vertical button (ellipsis) opening YouTube bottom sheet
                Button {
                    onMoreTap?()
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(YTColor.textSecondary)
                        .frame(width: 28, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SpringPressButtonStyle())
                .accessibilityLabel("Tùy chọn video")
            }
            .padding(.horizontal, cornerRadius == 0 ? 12 : 4)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
        .padding(.horizontal, cornerRadius == 0 ? 0 : 12)
        .background(YTColor.background)
    }

    private var channelInitialsView: some View {
        let char = video.channelTitle.trimmingCharacters(in: .whitespaces).prefix(1).uppercased()
        return ZStack {
            Circle()
                .fill(Color(red: 0.22, green: 0.22, blue: 0.22))
            Text(char.isEmpty ? "Y" : char)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 36, height: 36)
    }
}

// MARK: - YouTube Bottom Sheet Options

/// Standard YouTube iOS video action bottom sheet.
struct YouTubeVideoActionSheet: View {
    let video: Video
    var onSaveToPlaylist: () -> Void
    var onToggleWatchLater: () -> Void
    var onDownload: () -> Void
    var onShare: () -> Void
    var onNotInterested: () -> Void
    var onDontRecommendChannel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var lib = Library.shared

    init(
        video: Video,
        onSaveToPlaylist: @escaping () -> Void,
        onToggleWatchLater: @escaping () -> Void,
        onDownload: @escaping () -> Void,
        onShare: @escaping () -> Void,
        onNotInterested: @escaping () -> Void,
        onDontRecommendChannel: @escaping () -> Void
    ) {
        self.video = video
        self.onSaveToPlaylist = onSaveToPlaylist
        self.onToggleWatchLater = onToggleWatchLater
        self.onDownload = onDownload
        self.onShare = onShare
        self.onNotInterested = onNotInterested
        self.onDontRecommendChannel = onDontRecommendChannel
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header summary preview
            HStack(spacing: 12) {
                // Thumbnail preview
                CachedAsyncImage(url: video.thumbnail, targetSize: CGSize(width: 68, height: 38)) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Color(.secondarySystemFill)
                }
                .frame(width: 68, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(video.title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(YTColor.textPrimary)
                        .lineLimit(1)

                    Text(video.channelTitle)
                        .font(.caption2)
                        .foregroundStyle(YTColor.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Rectangle()
                .fill(YTColor.separator)
                .frame(height: 0.5)

            // YouTube Options List
            ScrollView {
                VStack(spacing: 4) {
                    // 1. Lưu vào Danh sách phát
                    actionRow(
                        icon: "folder.badge.plus",
                        title: "Lưu vào Danh sách phát"
                    ) {
                        dismiss()
                        onSaveToPlaylist()
                    }

                    // 2. Xem sau
                    let isInWL = lib.isInWatchLater(video.id)
                    actionRow(
                        icon: isInWL ? "clock.badge.checkmark.fill" : "clock",
                        title: isInWL ? "Xóa khỏi danh sách Xem sau" : "Xem sau",
                        tint: isInWL ? YTColor.brandRed : YTColor.textPrimary
                    ) {
                        dismiss()
                        onToggleWatchLater()
                    }

                    // 3. Tải xuống
                    actionRow(
                        icon: "arrow.down.to.line",
                        title: "Tải xuống video"
                    ) {
                        dismiss()
                        onDownload()
                    }

                    // 4. Chia sẻ
                    actionRow(
                        icon: "square.and.arrow.up",
                        title: "Chia sẻ"
                    ) {
                        dismiss()
                        onShare()
                    }

                    Rectangle()
                        .fill(YTColor.separator.opacity(0.5))
                        .frame(height: 0.5)
                        .padding(.vertical, 4)

                    // 5. Không quan tâm
                    actionRow(
                        icon: "hand.thumbsdown",
                        title: "Không quan tâm"
                    ) {
                        dismiss()
                        onNotInterested()
                    }

                    // 6. Không đề xuất kênh này
                    actionRow(
                        icon: "person.crop.circle.badge.xmark",
                        title: "Không đề xuất kênh này"
                    ) {
                        dismiss()
                        onDontRecommendChannel()
                    }
                }
                .padding(.top, 6)
            }
        }
        .background(YTColor.background)
    }

    private func actionRow(
        icon: String,
        title: String,
        tint: Color = YTColor.textPrimary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)

                Text(title)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(YTColor.textPrimary)

                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - YouTube Playlist Picker Sheet

/// Sheet letting users add the video to local playlists or create a new playlist.
struct YouTubePlaylistPickerSheet: View {
    let video: Video
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var lib = Library.shared
    @State private var newPlaylistName: String = ""
    @State private var showCreateField: Bool = false

    init(video: Video) {
        self.video = video
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List {
                    // Watch later quick toggle
                    Section {
                        let inWL = lib.isInWatchLater(video.id)
                        Button {
                            lib.toggleWatchLater(video)
                        } label: {
                            HStack {
                                Image(systemName: inWL ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(inWL ? YTColor.brandRed : YTColor.textSecondary)
                                    .font(.system(size: 20))

                                Image(systemName: "clock")
                                    .foregroundStyle(YTColor.textPrimary)

                                Text("Xem sau")
                                    .foregroundStyle(YTColor.textPrimary)
                                Spacer()
                            }
                        }
                    }

                    // Local playlists
                    Section(header: Text("Danh sách phát của bạn").font(.caption).foregroundStyle(YTColor.textSecondary)) {
                        if lib.playlists.isEmpty {
                            Text("Chưa có danh sách phát nào")
                                .font(.footnote)
                                .foregroundStyle(YTColor.textSecondary)
                        } else {
                            ForEach(lib.playlists) { playlist in
                                let containsVideo = lib.contains(video.id, in: playlist.id)
                                Button {
                                    lib.toggle(video, in: playlist.id)
                                } label: {
                                    HStack {
                                        Image(systemName: containsVideo ? "checkmark.square.fill" : "square")
                                            .foregroundStyle(containsVideo ? YTColor.brandRed : YTColor.textSecondary)
                                            .font(.system(size: 20))

                                        Image(systemName: "music.note.list")
                                            .foregroundStyle(YTColor.textPrimary)

                                        Text(playlist.name)
                                            .foregroundStyle(YTColor.textPrimary)
                                        Spacer()
                                        Text("\(playlist.videos.count) video")
                                            .font(.caption2)
                                            .foregroundStyle(YTColor.textSecondary)
                                    }
                                }
                            }
                        }
                    }

                    // Create new playlist section
                    Section {
                        if showCreateField {
                            HStack {
                                TextField("Tên danh sách mới…", text: $newPlaylistName)
                                    .font(.subheadline)
                                Button("Tạo") {
                                    let trimmed = newPlaylistName.trimmingCharacters(in: .whitespaces)
                                    guard !trimmed.isEmpty else { return }
                                    let newId = lib.createPlaylist(trimmed)
                                    lib.add(video, to: newId)
                                    newPlaylistName = ""
                                    showCreateField = false
                                }
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(YTColor.brandRed)
                            }
                        } else {
                            Button {
                                showCreateField = true
                            } label: {
                                Label("Tạo danh sách phát mới", systemImage: "plus")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(YTColor.brandRed)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle("Lưu video vào…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Xong") { dismiss() }
                        .font(.headline)
                        .foregroundStyle(YTColor.brandRed)
                }
            }
        }
    }
}

// MARK: - YouTube Explore Sheet

/// Sheet presenting trending topics when user taps the "Khám phá" leading chip.
struct YouTubeExploreSheet: View {
    let onSelectCategory: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private let topics: [(name: String, icon: String, color: Color)] = [
        ("Âm nhạc", "music.note", Color.red),
        ("Trò chơi", "gamecontroller.fill", Color.blue),
        ("Tin tức", "newspaper.fill", Color.green),
        ("Bóng đá", "sportscourt.fill", Color.orange),
        ("Podcasts", "mic.fill", Color.purple),
        ("Hoạt hình", "sparkles.tv.fill", Color.pink),
        ("Học tập", "graduationcap.fill", Color.teal),
        ("Công nghệ", "laptopcomputer", Color.indigo),
        ("Nấu ăn", "fork.knife", Color.brown),
        ("Du lịch", "airplane", Color.cyan)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(topics, id: \.name) { topic in
                        Button {
                            onSelectCategory(topic.name)
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(topic.color.opacity(0.18))
                                        .frame(width: 36, height: 36)
                                    Image(systemName: topic.icon)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(topic.color)
                                }
                                Text(topic.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(YTColor.textPrimary)
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(YTColor.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Khám phá")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Đóng") { dismiss() }
                        .foregroundStyle(YTColor.textPrimary)
                }
            }
        }
    }
}

// MARK: - YouTube Notifications Preview Sheet

struct YouTubeNotificationsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    notificationRow(
                        avatarText: "V",
                        title: "Vidra đã cập nhật phiên bản mới với giao diện YouTube iOS chuẩn!",
                        time: "Vừa xong"
                    )
                    notificationRow(
                        avatarText: "Y",
                        title: "Kênh bạn đăng ký có video mới: 'Top 10 mẹo dùng YouTube trên iPhone'",
                        time: "2 giờ trước"
                    )
                    notificationRow(
                        avatarText: "S",
                        title: "Khám phá các bản nhạc thịnh hành nhất trong tuần trên Vidra",
                        time: "1 ngày trước"
                    )
                }
            }
            .listStyle(.plain)
            .navigationTitle("Thông báo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Đóng") { dismiss() }
                        .foregroundStyle(YTColor.textPrimary)
                }
            }
        }
    }

    private func notificationRow(avatarText: String, title: String, time: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(YTColor.brandRed)
                    .frame(width: 38, height: 38)
                Text(avatarText)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(YTColor.textPrimary)
                    .lineLimit(3)

                Text(time)
                    .font(.caption2)
                    .foregroundStyle(YTColor.textSecondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Skeleton Shimmer Card

/// Shimmer placeholder during feed initial loading.
struct YouTubeVideoCardSkeleton: View {
    var cornerRadius: CGFloat = 0

    @State private var phase: CGFloat = 0

    init(cornerRadius: CGFloat = 0) {
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Thumbnail skeleton (16:9)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(.secondarySystemFill))
                .aspectRatio(16 / 9, contentMode: .fit)

            // Info row skeleton
            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .fill(Color(.secondarySystemFill))
                    .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.secondarySystemFill))
                        .frame(height: 14)
                        .frame(maxWidth: .infinity)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.secondarySystemFill))
                        .frame(width: 180, height: 11)
                }
            }
            .padding(.horizontal, cornerRadius == 0 ? 12 : 4)
        }
        .padding(.horizontal, cornerRadius == 0 ? 0 : 12)
        .opacity(0.8)
    }
}
