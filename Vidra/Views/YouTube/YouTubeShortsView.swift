import AVFoundation
import AVKit
import SwiftUI
import UIKit

// MARK: - YouTubeShortsView

struct YouTubeShortsView: View {
    var initialVideos: [Video] = []
    var initialIndex: Int = 0
    var isTab: Bool = false

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var pm = PlayerManager.shared
    @ObservedObject private var lib = Library.shared

    @State private var shorts: [Video] = []
    @State private var currentIndex: Int = 0
    @State private var continuationToken: String?
    @State private var isLoadingInitial = true
    @State private var isLoadingMore = false
    @State private var errorMessage: String?

    // Audio & playback state
    @State private var isMuted = false
    @State private var showPlayPauseIcon = false
    @State private var showHeartAnimation = false
    @State private var lastHeartPosition: CGPoint = .zero

    // Sheets & modals
    @State private var showComments = false
    @State private var activeCommentsVideo: Video?
    @State private var toastMessage: String?
    @State private var showToast = false

    // iOS 16 fallback swipe state
    @State private var dragOffset: CGFloat = 0
    @State private var fetchTask: Task<Void, Never>?
    @State private var hudHideTask: Task<Void, Never>?
    @State private var toastHideTask: Task<Void, Never>?
    @State private var heartHideTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()

                if isLoadingInitial && shorts.isEmpty {
                    initialLoadingView
                } else if let error = errorMessage, shorts.isEmpty {
                    errorStateView(error)
                } else {
                    pagingContainer(geometry: geometry)
                }

                // Top Navigation Bar
                topHeaderBar

                // Interactive HUD Overlays
                centerActionHUDs
                    .allowsHitTesting(false)

                // Toast Notification
                if showToast, let toastMessage {
                    toastOverlay(toastMessage)
                }
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showComments) {
            let activeId = activeCommentsVideo?.id ?? pm.current?.id
            let tokenForActive = (pm.current?.id == activeId) ? pm.commentsToken : nil
            NavigationStack {
                CommentsView(
                    token: tokenForActive,
                    channelTitle: activeCommentsVideo?.channelTitle,
                    channelAvatar: nil
                )
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .task {
            await initializeShorts()
        }
        .onDisappear {
            fetchTask?.cancel()
            hudHideTask?.cancel()
            toastHideTask?.cancel()
            heartHideTask?.cancel()
            pm.pause()
            pm.loop = false
            pm.setMuted(false)
            pm.clearAllPreloads()
        }
    }

    // MARK: - Initialization & Data Loading

    @MainActor
    private func initializeShorts() async {
        pm.loop = true
        isMuted = pm.player.isMuted

        if !initialVideos.isEmpty {
            shorts = initialVideos
            currentIndex = min(max(0, initialIndex), shorts.count - 1)
            isLoadingInitial = false
            playVideo(at: currentIndex)
            return
        }

        await fetchInitialShorts()
    }

    @MainActor
    private func fetchInitialShorts() async {
        isLoadingInitial = true
        errorMessage = nil

        do {
            let page = try await InnerTube.shared.search("#shorts", params: nil, continuation: nil)
            let fetchedVideos = page.videos.filter { $0.source == nil }

            if fetchedVideos.isEmpty {
                // Fallback to trending search if #shorts returned no items
                let fallback = try await InnerTube.shared.search("shorts", params: nil, continuation: nil)
                shorts = fallback.videos
                continuationToken = fallback.continuation
            } else {
                shorts = fetchedVideos
                continuationToken = page.continuation
            }

            isLoadingInitial = false

            if !shorts.isEmpty {
                currentIndex = 0
                playVideo(at: 0)
            }
        } catch {
            errorMessage = error.localizedDescription
            isLoadingInitial = false
        }
    }

    @MainActor
    private func fetchMoreShortsIfNeeded(forIndex index: Int) {
        guard let token = continuationToken, !isLoadingMore, index >= shorts.count - 3 else {
            return
        }

        isLoadingMore = true
        fetchTask?.cancel()
        fetchTask = Task { @MainActor in
            defer { isLoadingMore = false }
            do {
                let page = try await InnerTube.shared.search("#shorts", params: nil, continuation: token)
                guard !Task.isCancelled else { return }
                let existing = Set(shorts.map(\.id))
                let newVideos = page.videos.filter { !existing.contains($0.id) }
                if !newVideos.isEmpty {
                    shorts.append(contentsOf: newVideos)
                }
                continuationToken = page.continuation
            } catch {
                // Continuation error handled gracefully
            }
        }
    }

    // MARK: - Playback Control & Preloading Engine

    private func playVideo(at index: Int) {
        guard shorts.indices.contains(index) else { return }
        let video = shorts[index]

        pm.loop = true
        pm.setMuted(isMuted)

        if pm.current?.id != video.id {
            pm.play(video, queue: [], showWatchSheet: false, preserveMute: true)
        } else if !pm.isPlaying {
            pm.resume()
        }

        updatePreloadsAndRecycleMemory(for: index)
        fetchMoreShortsIfNeeded(forIndex: index)
    }

    /// Pre-buffer các video tiếp theo để đạt độ trễ 0s khi vuốt dọc,
    /// đồng thời giải phóng bộ nhớ của các video đã cuộn qua để tránh tràn RAM.
    private func updatePreloadsAndRecycleMemory(for index: Int) {
        guard !shorts.isEmpty else { return }

        // 1. Nạp trước (pre-buffer) video kế tiếp và video sau đó
        let nextIndex = index + 1
        if shorts.indices.contains(nextIndex) {
            pm.preload(video: shorts[nextIndex])
        }
        let nextNextIndex = index + 2
        if shorts.indices.contains(nextNextIndex) {
            pm.preload(video: shorts[nextNextIndex])
        }

        // 2. Phạm vi hoạt động cần giữ trong bộ nhớ: [index - 1 ... index + 2]
        let lower = max(0, index - 1)
        let upper = min(shorts.count - 1, index + 2)
        let keepWindowIds = Set(shorts[lower...upper].map(\.id))

        // 3. Hủy bỏ bộ đệm và AVPlayerItem của các video đã cuộn qua để tránh tràn RAM
        pm.purgePreloads(keeping: keepWindowIds)

        // 4. Giải phóng bộ nhớ ảnh thumbnail của các video ở xa (> 4 vị trí)
        for i in shorts.indices {
            if abs(i - index) > 4, let thumb = shorts[i].thumbnail {
                ImageCache.shared.remove(for: thumb)
            }
        }
    }

    @MainActor
    private func togglePlayPause() {
        pm.togglePlay()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
            showPlayPauseIcon = true
        }
        hudHideTask?.cancel()
        hudHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                showPlayPauseIcon = false
            }
        }
    }

    private func toggleMute() {
        isMuted.toggle()
        pm.setMuted(isMuted)
        showToast(message: isMuted ? "Đã tắt tiếng" : "Đã bật tiếng")
    }

    @MainActor
    private func showToast(message: String) {
        toastMessage = message
        withAnimation(.easeInOut(duration: 0.2)) {
            showToast = true
        }
        toastHideTask?.cancel()
        toastHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                showToast = false
            }
        }
    }

    // MARK: - Paging Container

    @ViewBuilder
    private func pagingContainer(geometry: GeometryProxy) -> some View {
        if #available(iOS 17.0, *) {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(shorts.enumerated()), id: \.element.id) { index, video in
                        let isWithinWindow = abs(index - currentIndex) <= 2
                        ShortsCardView(
                            video: video,
                            isActive: index == currentIndex,
                            isWithinRetentionWindow: isWithinWindow,
                            isMuted: isMuted,
                            isTab: isTab,
                            onTogglePlay: { togglePlayPause() },
                            onDoubleTap: { location in handleDoubleTap(at: location, for: video) },
                            onToggleMute: toggleMute,
                            onOpenComments: {
                                activeCommentsVideo = video
                                showComments = true
                            },
                            onRemixTapped: {
                                showToast(message: "Tính năng Phối lại Shorts")
                            }
                        )
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .id(video.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: Binding(
                get: { shorts.indices.contains(currentIndex) ? shorts[currentIndex].id : nil },
                set: { newId in
                    if let newId, let newIdx = shorts.firstIndex(where: { $0.id == newId }), newIdx != currentIndex {
                        currentIndex = newIdx
                        playVideo(at: newIdx)
                    }
                }
            ))
        } else {
            // iOS 16 fallback: vertical paging gesture over active neighbor window
            verticalDragPager(geometry: geometry)
        }
    }

    private func verticalDragPager(geometry: GeometryProxy) -> some View {
        let lower = max(0, currentIndex - 1)
        let upper = min(shorts.count - 1, currentIndex + 1)

        return ZStack {
            if !shorts.isEmpty {
                ForEach(lower...upper, id: \.self) { index in
                    let video = shorts[index]
                    ShortsCardView(
                        video: video,
                        isActive: index == currentIndex,
                        isWithinRetentionWindow: true,
                        isMuted: isMuted,
                        isTab: isTab,
                        onTogglePlay: { togglePlayPause() },
                        onDoubleTap: { location in handleDoubleTap(at: location, for: video) },
                        onToggleMute: toggleMute,
                        onOpenComments: {
                            activeCommentsVideo = video
                            showComments = true
                        },
                        onRemixTapped: {
                            showToast(message: "Tính năng Phối lại Shorts")
                        }
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .offset(y: CGFloat(index - currentIndex) * geometry.size.height + dragOffset)
                    .id(video.id)
                }
            }
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
        .clipped()
        .gesture(
            DragGesture(minimumDistance: 16)
                .onChanged { value in
                    if abs(value.translation.height) > abs(value.translation.width) {
                        dragOffset = value.translation.height
                    }
                }
                .onEnded { value in
                    guard abs(value.translation.height) > abs(value.translation.width) else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { dragOffset = 0 }
                        return
                    }
                    let threshold = geometry.size.height * 0.16
                    let predicted = value.predictedEndTranslation.height
                    var newIndex = currentIndex

                    if value.translation.height < -threshold || predicted < -250 {
                        newIndex = min(currentIndex + 1, shorts.count - 1)
                    } else if value.translation.height > threshold || predicted > 250 {
                        newIndex = max(currentIndex - 1, 0)
                    }

                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        dragOffset = 0
                        if newIndex != currentIndex {
                            currentIndex = newIndex
                            playVideo(at: newIndex)
                        }
                    }
                }
        )
    }

    @MainActor
    private func handleDoubleTap(at location: CGPoint, for video: Video) {
        lastHeartPosition = location
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) {
            showHeartAnimation = true
        }
        heartHideTask?.cancel()
        heartHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                showHeartAnimation = false
            }
        }
    }

    // MARK: - Top Header Bar

    private var topHeaderBar: some View {
        HStack(spacing: 16) {
            if !isTab {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Color.black.opacity(0.35), in: Circle())
                }
            }

            Text("Shorts")
                .font(.system(size: 22, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 4, x: 0, y: 1)

            Spacer()

            // Mute / Unmute Toggle Button
            Button(action: toggleMute) {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.black.opacity(0.35), in: Circle())
            }

            // Camera / Remix Shortcut
            Button {
                showToast(message: "Tạo video Shorts")
            } label: {
                Image(systemName: "camera.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.black.opacity(0.35), in: Circle())
            }

            // Options Button
            Button {
                showToast(message: "Tùy chọn Shorts")
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.black.opacity(0.35), in: Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, isTab ? 42 : 50)
    }

    // MARK: - Center HUD Overlays

    @ViewBuilder
    private var centerActionHUDs: some View {
        // Play / Pause central pulsing icon
        if showPlayPauseIcon {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.55))
                    .frame(width: 80, height: 80)
                Image(systemName: pm.isPlaying ? "play.fill" : "pause.fill")
                    .font(.system(size: 36, weight: .black))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.scale.combined(with: .opacity))
        }

        // Double-tap heart animation
        if showHeartAnimation {
            Image(systemName: "heart.fill")
                .font(.system(size: 85))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.red, Color(red: 1.0, green: 0.2, blue: 0.5)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .shadow(color: .red.opacity(0.8), radius: 16, x: 0, y: 4)
                .scaleEffect(showHeartAnimation ? 1.25 : 0.4)
                .position(lastHeartPosition == .zero ? CGPoint(x: UIScreen.main.bounds.midX, y: UIScreen.main.bounds.midY) : lastHeartPosition)
                .transition(.scale.combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var centerActionHUDsHitSafe: some View { EmptyView() }

    // MARK: - Toast Banner

    private func toastOverlay(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.85), in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
                .padding(.bottom, 100)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Loading & Error States

    private var initialLoadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(.white)
                .scaleEffect(1.3)
            Text("Đang tải Shorts…")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorStateView(_ error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.red)
            Text("Không thể tải Shorts")
                .font(.headline)
                .foregroundStyle(.white)
            Text(error)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                Task { @MainActor in await fetchInitialShorts() }
            } label: {
                Text("Thử lại")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Color.white, in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - ShortsCardView

struct ShortsCardView: View {
    let video: Video
    let isActive: Bool
    var isWithinRetentionWindow: Bool = true
    let isMuted: Bool
    var isTab: Bool = false

    var onTogglePlay: () -> Void
    var onDoubleTap: (CGPoint) -> Void
    var onToggleMute: () -> Void
    var onOpenComments: () -> Void
    var onRemixTapped: () -> Void

    @ObservedObject private var pm = PlayerManager.shared
    @ObservedObject private var lib = Library.shared

    @State private var isLiked = false
    @State private var isDisliked = false
    @State private var likeCount = 0
    @State private var commentCountString = "Bình luận"
    @State private var isCaptionExpanded = false
    @State private var discRotation: Double = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            // Fullscreen Video / Thumbnail Surface
            videoSurfaceLayer

            // Gradient Shadows for UI contrast
            gradientOverlays

            // Interactive Gestures layer
            gesturesTapLayer

            // Bottom Content: Left info + Right action column
            HStack(alignment: .bottom, spacing: 12) {
                bottomInfoOverlay
                    .frame(maxWidth: .infinity, alignment: .leading)

                rightActionBar
                    .frame(width: 64)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, isTab ? 88 : 36)

            // Bottom Thin Playback Progress Indicator
            bottomProgressIndicator
                .padding(.bottom, isTab ? 68 : 0)
        }
        .clipped()
        .task(id: isWithinRetentionWindow ? video.id : "") {
            isLiked = lib.isLiked(video.id)
            guard isWithinRetentionWindow else { return }
            await loadVideoStats()
        }
        .onChange(of: lib.isLiked(video.id)) { liked in
            if isLiked != liked {
                isLiked = liked
                if liked { isDisliked = false }
            }
        }
    }

    // MARK: - Video Surface Layer

    @ViewBuilder
    private var videoSurfaceLayer: some View {
        ZStack {
            Color.black

            // High-resolution background thumbnail placeholder using cached downsampling
            CachedAsyncImage(url: video.thumbnail, targetSize: CGSize(width: 540, height: 960)) { img in
                img
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } placeholder: {
                Color.black
            }

            // Realtime Video Surface
            if isActive {
                VideoSurface(player: pm.player, gravity: .resizeAspectFill, enablePiP: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if pm.isLoading {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.2)
                }
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Gradients for Overlay Contrast

    private var gradientOverlays: some View {
        VStack {
            LinearGradient(
                colors: [Color.black.opacity(0.65), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 140)

            Spacer()

            LinearGradient(
                colors: [Color.clear, Color.black.opacity(0.4), Color.black.opacity(0.85)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 320)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: - Gesture Detection Layer

    private var gesturesTapLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { location in
                if !isLiked {
                    isLiked = true
                    isDisliked = false
                    likeCount += 1
                    if !lib.isLiked(video.id) { lib.toggleLike(video) }
                }
                onDoubleTap(location)
            }
            .onTapGesture(count: 1) {
                onTogglePlay()
            }
    }

    // MARK: - Right Action Bar (Cột nút tương tác dọc bên phải)

    private var rightActionBar: some View {
        VStack(spacing: 18) {
            // 1. Like Button
            actionButton(
                icon: isLiked ? "hand.thumbsup.fill" : "hand.thumbsup",
                label: formatLikeCount(likeCount),
                tint: isLiked ? .red : .white
            ) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                isLiked.toggle()
                if isLiked {
                    isDisliked = false
                    likeCount += 1
                    if !lib.isLiked(video.id) { lib.toggleLike(video) }
                } else {
                    likeCount = max(0, likeCount - 1)
                    if lib.isLiked(video.id) { lib.toggleLike(video) }
                }
            }

            // 2. Dislike Button
            actionButton(
                icon: isDisliked ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                label: "Không thích",
                tint: isDisliked ? .red : .white
            ) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                isDisliked.toggle()
                if isDisliked {
                    if isLiked {
                        isLiked = false
                        likeCount = max(0, likeCount - 1)
                        if lib.isLiked(video.id) { lib.toggleLike(video) }
                    }
                }
            }

            // 3. Comments Button
            actionButton(
                icon: "ellipsis.message.fill",
                label: commentCountString,
                tint: .white
            ) {
                onOpenComments()
            }

            // 4. Share Button (Nút Chia sẻ)
            ShareLink(item: video.shareURL) {
                VStack(spacing: 4) {
                    Image(systemName: "arrowshape.turn.up.right.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 3, x: 0, y: 1)
                    Text("Chia sẻ")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 3, x: 0, y: 1)
                }
            }
            .buttonStyle(.plain)

            // 5. Remix Button (Nút Phối lại)
            actionButton(
                icon: "square.2.layers.3d",
                label: "Phối lại",
                tint: .white
            ) {
                onRemixTapped()
            }

            // 6. Sound Disc (Đĩa xoay âm thanh)
            SoundDiscView(
                thumbnailURL: video.thumbnail,
                isPlaying: isActive && pm.isPlaying
            )
        }
    }

    private func actionButton(
        icon: String,
        label: String,
        tint: Color = .white,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .foregroundStyle(tint)
                    .shadow(color: .black.opacity(0.5), radius: 3, x: 0, y: 1)
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.5), radius: 3, x: 0, y: 1)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Bottom Info Overlay (Lớp phủ thông tin bên dưới)

    private var bottomInfoOverlay: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Channel Info Row
            channelHeaderRow

            // Caption / Description
            captionView

            // Sound Track / Original Audio Bar
            soundTrackRow
        }
    }

    private var channelHeaderRow: some View {
        HStack(spacing: 10) {
            let channelId = video.channelId ?? ""
            let knownChannel = lib.subscriptions.first { $0.id == channelId }
            let isSubscribed = lib.isSubscribed(channelId)

            // Channel Avatar (36x36)
            Avatar(url: knownChannel?.avatar ?? video.thumbnail, name: video.channelTitle, size: 36)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 1))
                .shadow(color: .black.opacity(0.4), radius: 4)

            // Channel Handle / Title
            Text("@\(formatHandle(video.channelTitle))")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .shadow(color: .black.opacity(0.6), radius: 3, x: 0, y: 1)

            // Subscribe Pill Button
            if !channelId.isEmpty {
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    let channel = Channel(
                        id: channelId,
                        title: video.channelTitle,
                        avatar: knownChannel?.avatar
                    )
                    lib.toggleSubscription(channel)
                } label: {
                    Text(isSubscribed ? "Đã đăng ký" : "Đăng ký")
                        .font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            isSubscribed ? Color.white.opacity(0.2) : Color.white,
                            in: Capsule()
                        )
                        .foregroundStyle(isSubscribed ? Color.white : Color.black)
                        .shadow(color: .black.opacity(0.3), radius: 3)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var captionView: some View {
        VStack(alignment: .leading, spacing: 4) {
            let title = video.title.isEmpty ? "Shorts" : video.title

            if isCaptionExpanded {
                Text(title)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.7), radius: 3)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isCaptionExpanded = false
                    }
                } label: {
                    Text("Thu gọn")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                }
            } else {
                HStack(alignment: .bottom, spacing: 4) {
                    Text(title)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.7), radius: 3)

                    if title.count > 45 {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isCaptionExpanded = true
                            }
                        } label: {
                            Text("…thêm")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white.opacity(0.9))
                        }
                    }
                }
            }
        }
    }

    private var soundTrackRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "music.note")
                .font(.system(size: 12))
                .foregroundStyle(.white)

            Text("Âm thanh gốc - \(video.channelTitle)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(1)

            MusicWaveBars(isPlaying: isActive && pm.isPlaying)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.35), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
    }

    // MARK: - Bottom Scrubber Line

    private var bottomProgressIndicator: some View {
        GeometryReader { geo in
            let progress = (pm.duration > 0 && isActive) ? min(max(pm.currentTime / pm.duration, 0), 1) : 0
            Rectangle()
                .fill(Color.white.opacity(0.75))
                .frame(width: geo.size.width * CGFloat(progress), height: 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .frame(height: 2)
        .allowsHitTesting(false)
    }

    // MARK: - Helpers & Data Fetching

    @MainActor
    private func loadVideoStats() async {
        // Fetch votes (Likes/Dislikes)
        if let votes = await Extras.votes(video.id), !Task.isCancelled {
            likeCount = votes.likes + (isLiked ? 1 : 0)
        } else if !Task.isCancelled {
            likeCount = parseEstimatedLikes(video.views) + (isLiked ? 1 : 0)
        }
    }

    private func formatHandle(_ name: String) -> String {
        name.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "@", with: "")
            .lowercased()
    }

    private func formatLikeCount(_ count: Int) -> String {
        if count <= 0 { return "Thích" }
        if count < 1_000 { return "\(count)" }
        if count < 1_000_000 {
            let thousands = Double(count) / 1_000.0
            return String(format: "%.1fK", thousands).replacingOccurrences(of: ".0K", with: "K")
        }
        let millions = Double(count) / 1_000_000.0
        return String(format: "%.1fM", millions).replacingOccurrences(of: ".0M", with: "M")
    }

    private func parseEstimatedLikes(_ views: String?) -> Int {
        guard let views else { return 0 }
        let lower = views.lowercased()
        let numText = lower.components(separatedBy: CharacterSet(charactersIn: "0123456789.,").inverted).joined()
            .replacingOccurrences(of: ",", with: ".")
        if let v = Double(numText), v > 0 {
            if lower.contains("m") || lower.contains("tr") {
                return max(10, Int(v * 1_000_000 / 15))
            } else if lower.contains("k") || lower.contains("n") {
                return max(10, Int(v * 1_000 / 15))
            }
            return max(10, Int(v / 15))
        }
        return 0
    }
}

// MARK: - SoundDiscView (Đĩa xoay âm thanh)

struct SoundDiscView: View {
    let thumbnailURL: URL?
    let isPlaying: Bool

    @State private var angle: Double = 0

    var body: some View {
        ZStack {
            // Outer Vinyl Disc
            Circle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(colors: [
                            Color(white: 0.15),
                            Color.black,
                            Color(white: 0.2),
                            Color.black
                        ]),
                        center: .center,
                        startRadius: 4,
                        endRadius: 20
                    )
                )
                .frame(width: 40, height: 40)
                .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 4)

            // Inner Album Cover / Artwork
            CachedAsyncImage(url: thumbnailURL, targetSize: CGSize(width: 24, height: 24)) { image in
                image
                    .resizable()
                    .scaledToFill()
                    .frame(width: 22, height: 22)
                    .clipShape(Circle())
            } placeholder: {
                Circle()
                    .fill(Color.red.opacity(0.8))
                    .frame(width: 22, height: 22)
                    .overlay(Image(systemName: "music.note").font(.system(size: 10)).foregroundStyle(.white))
            }
        }
        .rotationEffect(.degrees(isPlaying ? angle : 0))
        .onAppear {
            if isPlaying {
                startSpinning()
            }
        }
        .onChange(of: isPlaying) { playing in
            if playing {
                startSpinning()
            } else {
                angle = 0
            }
        }
    }

    private func startSpinning() {
        withAnimation(.linear(duration: 4.5).repeatForever(autoreverses: false)) {
            angle += 360
        }
    }
}

// MARK: - MusicWaveBars (Hiệu ứng sóng âm nhạc)

struct MusicWaveBars: View {
    let isPlaying: Bool

    @State private var bar1Height: CGFloat = 4
    @State private var bar2Height: CGFloat = 8
    @State private var bar3Height: CGFloat = 6

    var body: some View {
        HStack(spacing: 2) {
            Capsule()
                .fill(Color.white)
                .frame(width: 2.5, height: isPlaying ? bar1Height : 4)
            Capsule()
                .fill(Color.white)
                .frame(width: 2.5, height: isPlaying ? bar2Height : 4)
            Capsule()
                .fill(Color.white)
                .frame(width: 2.5, height: isPlaying ? bar3Height : 4)
        }
        .frame(height: 12)
        .onAppear {
            if isPlaying {
                animateBars()
            }
        }
        .onChange(of: isPlaying) { playing in
            if playing {
                animateBars()
            } else {
                withAnimation(.easeOut(duration: 0.2)) {
                    bar1Height = 4
                    bar2Height = 4
                    bar3Height = 4
                }
            }
        }
    }

    private func animateBars() {
        withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) {
            bar1Height = 11
        }
        withAnimation(.easeInOut(duration: 0.35).repeatForever(autoreverses: true).delay(0.1)) {
            bar2Height = 9
        }
        withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true).delay(0.2)) {
            bar3Height = 12
        }
    }
}
