import AVKit
import SwiftUI

// MARK: - YouTube Watch View

/// Trang xem video (Watch View) chuẩn phong cách ứng dụng YouTube iOS hiện đại
/// với Ambient Mode (Cinematic Lighting), Video Player Area, Channel Bar,
/// Action Pills cuộn ngang, Comments Teaser Box, và Recommended Videos.
struct YouTubeWatchView: View {
    @Environment(\.verticalSizeClass) private var vsc
    @Environment(\.dismiss) private var dismiss
    @State private var currentVideo: Video? = PlayerManager.shared.current
    @AppStorage("youtube_ambient_mode") private var ambientMode = true
    @State private var ambientColor: Color = Color(red: 0.15, green: 0.18, blue: 0.25)

    var body: some View {
        NavigationStack {
            Group {
                if vsc == .compact {
                    // Chế độ xoay ngang: Toàn màn hình tràn viền
                    PlayerArea(onClose: { minimizeToMiniPlayer() })
                        .ignoresSafeArea()
                } else {
                    // Chế độ dọc: Trình phát ở trên cùng với hiệu ứng Ambient Mode
                    ZStack(alignment: .top) {
                        Color(.systemBackground).ignoresSafeArea()

                        // Hiệu ứng ánh sáng chiếu rạp Ambient Mode
                        if ambientMode {
                            YouTubeAmbientLightingView(color: ambientColor, isEnabled: ambientMode)
                                .ignoresSafeArea(edges: .top)
                        }

                        VStack(spacing: 0) {
                            // Video Player Area tương thích PlayerManager.shared
                            PlayerArea(onClose: { minimizeToMiniPlayer() })
                                .aspectRatio(16 / 9, contentMode: .fit)

                            // Nội dung chi tiết video có thể cuộn
                            YouTubeWatchDetails(
                                ambientColor: ambientColor,
                                ambientMode: $ambientMode
                            )
                        }
                    }
                }
            }
            .background(vsc == .compact ? Color.black : Color(.systemBackground))
            .toolbar(.hidden, for: .navigationBar)
            .task(id: currentVideo?.id) {
                guard ambientMode else { return }
                await updateAmbientColor(for: currentVideo?.thumbnail)
            }
            .onReceive(PlayerManager.shared.$current) { v in
                if currentVideo?.id != v?.id {
                    currentVideo = v
                }
            }
        }
    }

    /// Thu nhỏ trình phát thành floating mini-player ở góc dưới màn hình
    private func minimizeToMiniPlayer() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
        PlayerManager.shared.showWatch = false
        dismiss()
    }

    /// Trích xuất màu sắc chủ đạo từ thumbnail video để làm ánh sáng Ambient Mode
    private func updateAmbientColor(for url: URL?) async {
        guard let url else {
            withAnimation(.easeInOut(duration: 0.8)) {
                ambientColor = Color(red: 0.15, green: 0.18, blue: 0.25)
            }
            return
        }
        if let extracted = await ArtworkColorCache.shared.color(for: url) {
            withAnimation(.easeInOut(duration: 0.8)) {
                ambientColor = extracted
            }
        }
    }
}

// MARK: - Ambient Mode (Cinematic Lighting)

/// Hiệu ứng ánh sáng môi trường (Cinematic Ambient Lighting) phát sáng mềm mại
/// bao quanh và phía sau player, tạo cảm giác đắm chìm như rạp chiếu phim chuẩn YouTube app.
struct YouTubeAmbientLightingView: View {
    let color: Color
    let isEnabled: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if isEnabled {
            ZStack {
                // Ánh sáng hắt lên đỉnh màn hình (tràn qua thanh trạng thái / Dynamic Island)
                LinearGradient(
                    colors: [
                        color.opacity(colorScheme == .dark ? 0.60 : 0.28),
                        color.opacity(colorScheme == .dark ? 0.85 : 0.40),
                        color.opacity(colorScheme == .dark ? 0.40 : 0.18),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 280)
                .blur(radius: 50)
                .allowsHitTesting(false)

                // Ánh sáng toả tròn mờ ảo ngay sau player
                RadialGradient(
                    colors: [
                        color.opacity(colorScheme == .dark ? 0.75 : 0.35),
                        color.opacity(colorScheme == .dark ? 0.45 : 0.20),
                        color.opacity(colorScheme == .dark ? 0.15 : 0.05),
                        Color.clear
                    ],
                    center: .center,
                    startRadius: 20,
                    endRadius: 240
                )
                .frame(height: 260)
                .blur(radius: 55)
                .padding(.top, 40)
                .allowsHitTesting(false)

                // Ánh sáng hắt xuống dưới vùng tiêu đề và thanh kênh
                VStack {
                    Spacer().frame(height: 210)
                    LinearGradient(
                        colors: [
                            color.opacity(colorScheme == .dark ? 0.55 : 0.22),
                            color.opacity(colorScheme == .dark ? 0.25 : 0.10),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 220)
                    .blur(radius: 60)
                    Spacer()
                }
                .allowsHitTesting(false)
            }
            .drawingGroup()
            .animation(.easeInOut(duration: 0.8), value: color)
        }
    }
}

// MARK: - Watch Details View

struct YouTubeWatchDetails: View {
    let ambientColor: Color
    @Binding var ambientMode: Bool

    @ObservedObject private var pm = PlayerManager.shared
    @ObservedObject private var lib = Library.shared
    @ObservedObject private var dl = DownloadManager.shared
    @AppStorage(Pref.autoplayKey) private var autoplay = true

    @State private var votes: Votes?
    @State private var userLiked = false
    @State private var userDisliked = false
    @State private var topComment: Comment?
    @State private var topCommentCount: String?
    @State private var showComments = false
    @State private var showPlaylists = false
    @State private var showDescription = false
    @State private var playlistTarget: Video?
    @State private var channelDetail: Channel?
    @State private var toastMessage: String?
    @State private var toastTask: Task<Void, Never>?

    var body: some View {
        if let v = pm.current {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 14) {
                    // 1. Tiêu đề video và dòng thông tin metadata
                    videoTitleSection(v)

                    // 2. Hàng kênh (Channel Bar) với Avatar 40x40, Verified Badge, Subscribers, Nút Đăng ký
                    channelBar(v)

                    // 3. Hàng nút thao tác kiểu viên thuốc cuộn ngang (Action Pills)
                    actionPills(v)

                    // 4. Hộp tóm tắt bình luận (Comments Teaser Box)
                    commentsTeaser(v)

                    // 5. Danh sách video tiếp theo / hàng đợi (Up Next & Recommendations)
                    recommendedSection(v)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 32)
            }
            .environment(\.openURL, OpenURLAction { url in handleURL(url) })
            .task(id: v.id) {
                votes = nil
                userLiked = lib.isLiked(v.id)
                userDisliked = false
                topComment = nil
                topCommentCount = nil
                loadVideoMeta(v)
            }
            .onChange(of: pm.commentsToken) { token in
                if let token, topComment == nil {
                    Task {
                        if let res = try? await InnerTube.shared.comments(token), let first = res.items.first {
                            self.topComment = first
                            self.topCommentCount = res.items.count > 0 ? "\(res.items.count)+" : nil
                        }
                    }
                }
            }
            .sheet(isPresented: $showComments) {
                NavigationStack {
                    CommentsView(
                        token: pm.commentsToken,
                        channelTitle: v.channelTitle,
                        channelAvatar: channelDetail?.avatar
                    )
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .commentsSheetBackgroundInteraction()
            }
            .sheet(isPresented: $showPlaylists) {
                AddToPlaylistView(video: v)
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showDescription) {
                YouTubeDescriptionSheet(video: v, votes: votes, info: pm.info)
                    .presentationDetents([.medium, .large])
            }
            .overlay(alignment: .bottom) {
                if let toast = toastMessage {
                    Text(toast)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .shadow(radius: 6)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - 1. Video Title & Metadata

    private func videoTitleSection(_ v: Video) -> some View {
        Button {
            showDescription = true
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 6) {
                    Text(v.title.isEmpty ? "Đang tải video…" : v.title)
                        .font(.title3.bold())
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 4)

                    Image(systemName: "chevron.down")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }

                // Dòng metadata: [Số lượt xem] lượt xem • [Ngày đăng] • #hashtags ...thêm
                HStack(spacing: 5) {
                    Text(metaLine(v))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text("…thêm")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func metaLine(_ v: Video) -> String {
        var parts: [String] = []

        // Lượt xem
        if let count = pm.info?.viewCount {
            parts.append("\(Fmt.count(count)) lượt xem")
        } else if let s = v.views, !s.isEmpty {
            parts.append(s)
        }

        // Ngày phát hành / đăng tải
        if let p = v.published, !p.isEmpty {
            parts.append(p)
        }

        // Trực tiếp
        if pm.info?.isLive == true {
            parts.append("🔴 Trực tiếp")
        }

        // Hashtags từ mô tả
        let tags = extractHashtags(pm.info?.description)
        if !tags.isEmpty {
            parts.append(tags.joined(separator: " "))
        }

        return parts.isEmpty ? "YouTube Video" : parts.joined(separator: " • ")
    }

    private func extractHashtags(_ text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        let pattern = #"#[\w\p{L}]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsString = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: min(nsString.length, 500)))
        return matches.prefix(2).map { nsString.substring(with: $0.range) }
    }

    // MARK: - 2. Channel Bar

    @ViewBuilder
    private func channelBar(_ v: Video) -> some View {
        if let id = v.channelId, !id.isEmpty {
            let known = lib.subscriptions.first { $0.id == id }
            let channel = Channel(
                id: id,
                title: v.channelTitle,
                avatar: known?.avatar ?? channelDetail?.avatar,
                subscribers: known?.subscribers ?? channelDetail?.subscribers
            )

            HStack(spacing: 12) {
                NavigationLink {
                    ChannelView(channel: channel)
                } label: {
                    HStack(spacing: 12) {
                        // Avatar to tròn 40x40
                        Avatar(url: channel.avatar, name: v.channelTitle, size: 40)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(v.channelTitle)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

                                // Huy hiệu xác minh (verified badge)
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            // Số người đăng ký
                            Text(channel.subscribers ?? "Kênh YouTube")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                // Nút Đăng ký chuẩn YouTube iOS
                subscribeButton(channel)
            }
            .padding(.vertical, 4)
        } else if !v.channelTitle.isEmpty {
            HStack(spacing: 12) {
                Avatar(url: nil, name: v.channelTitle, size: 40)
                Text(v.channelTitle)
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func subscribeButton(_ channel: Channel) -> some View {
        let isSubscribed = lib.isSubscribed(channel.id)

        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                lib.toggleSubscription(channel)
            }
        } label: {
            HStack(spacing: 5) {
                if isSubscribed {
                    Image(systemName: "bell.fill")
                        .font(.caption2)
                    Text("Đã đăng ký")
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                } else {
                    Text("Đăng ký")
                }
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                isSubscribed ? Color(.secondarySystemFill) : Color.primary,
                in: Capsule()
            )
            .foregroundStyle(
                isSubscribed ? Color.primary : Color(.systemBackground)
            )
            .shadow(color: isSubscribed ? Color.clear : Color.black.opacity(0.12), radius: 4, y: 2)
        }
        .buttonStyle(SpringPressButtonStyle())
    }

    // MARK: - 3. Action Pills (Hàng nút kiểu viên thuốc cuộn ngang)

    private func actionPills(_ v: Video) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // Nút ghép Thích / Không thích: [ 👍 1.2M | 👎 ]
                likeDislikePill(v)

                // Nút Chia sẻ (ShareLink)
                ShareLink(item: v.shareURL) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrowshape.turn.up.right.fill")
                            .font(.subheadline)
                        Text("Chia sẻ")
                            .font(.subheadline.weight(.medium))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemFill), in: Capsule())
                }
                .buttonStyle(SpringPressButtonStyle())
                .foregroundStyle(.primary)

                // Nút Phối lại (Remix)
                Button {
                    triggerRemix(v)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "music.note.waveform")
                            .font(.subheadline)
                        Text("Phối lại")
                            .font(.subheadline.weight(.medium))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemFill), in: Capsule())
                }
                .buttonStyle(SpringPressButtonStyle())
                .foregroundStyle(.primary)

                // Nút Tải xuống (Download với tiến trình)
                downloadPill(v)

                // Nút Cắt clip (Clip)
                Button {
                    showToast("Đang mở công cụ tạo đoạn video ngắn")
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "scissors")
                            .font(.subheadline)
                        Text("Clip")
                            .font(.subheadline.weight(.medium))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemFill), in: Capsule())
                }
                .buttonStyle(SpringPressButtonStyle())
                .foregroundStyle(.primary)

                // Nút Lưu vào danh sách phát (Save)
                Button {
                    showPlaylists = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.square.on.square")
                            .font(.subheadline)
                        Text("Lưu")
                            .font(.subheadline.weight(.medium))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemFill), in: Capsule())
                }
                .buttonStyle(SpringPressButtonStyle())
                .foregroundStyle(.primary)

                // Nút Xem sau
                Button {
                    lib.toggleWatchLater(v)
                    showToast(lib.isInWatchLater(v.id) ? "Đã thêm vào Xem sau" : "Đã xoá khỏi Xem sau")
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: lib.isInWatchLater(v.id) ? "clock.fill" : "clock")
                            .font(.subheadline)
                        Text("Xem sau")
                            .font(.subheadline.weight(.medium))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemFill), in: Capsule())
                }
                .buttonStyle(SpringPressButtonStyle())
                .foregroundStyle(.primary)

                // Nút Chỉ âm thanh (Audio-Only)
                Button {
                    pm.toggleAudioOnly()
                    showToast(pm.audioOnly ? "Đã bật chế độ chỉ âm thanh" : "Đã tắt chế độ chỉ âm thanh")
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: pm.audioOnly ? "headphones.circle.fill" : "headphones")
                            .font(.subheadline)
                        Text("Chỉ âm thanh")
                            .font(.subheadline.weight(.medium))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(pm.audioOnly ? Color.red.opacity(0.18) : Color(.secondarySystemFill), in: Capsule())
                    .overlay(Capsule().strokeBorder(pm.audioOnly ? Color.red : Color.clear, lineWidth: 1))
                }
                .buttonStyle(SpringPressButtonStyle())
                .foregroundStyle(pm.audioOnly ? Color.red : Color.primary)

                // Nút Ánh sáng Ambient Mode (Cinematic Lighting)
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        ambientMode.toggle()
                    }
                    showToast(ambientMode ? "Đã bật ánh sáng xung quanh" : "Đã tắt ánh sáng xung quanh")
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: ambientMode ? "sparkles.tv.fill" : "sparkles.tv")
                            .font(.subheadline)
                        Text(ambientMode ? "Ánh sáng: Bật" : "Ánh sáng: Tắt")
                            .font(.subheadline.weight(.medium))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemFill), in: Capsule())
                }
                .buttonStyle(SpringPressButtonStyle())
                .foregroundStyle(.primary)

                // Hẹn giờ tắt (Sleep menu)
                SleepMenu()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemFill), in: Capsule())
                    .foregroundStyle(.primary)
            }
            .padding(.vertical, 4)
        }
    }

    /// Nút ghép Thích / Không thích: [ 👍 1.2M | 👎 ]
    private func likeDislikePill(_ v: Video) -> some View {
        HStack(spacing: 0) {
            // Nút Thích
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                if userLiked {
                    userLiked = false
                    if lib.isLiked(v.id) { lib.toggleLike(v) }
                } else {
                    userLiked = true
                    userDisliked = false
                    if !lib.isLiked(v.id) { lib.toggleLike(v) }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: userLiked ? "hand.thumbsup.fill" : "hand.thumbsup")
                        .font(.subheadline)
                        .foregroundStyle(userLiked ? Color.blue : Color.primary)
                    Text(displayLikeCount)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(userLiked ? Color.blue : Color.primary)
                }
                .padding(.leading, 14)
                .padding(.trailing, 10)
                .padding(.vertical, 8)
            }
            .buttonStyle(SpringPressButtonStyle())

            // Vạch dọc phân cách mờ
            Rectangle()
                .fill(Color.primary.opacity(0.15))
                .frame(width: 1, height: 16)

            // Nút Không thích hiển thị chính xác lượt Dislike từ Return YouTube Dislike API
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                if userDisliked {
                    userDisliked = false
                } else {
                    userDisliked = true
                    userLiked = false
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: userDisliked ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                        .font(.subheadline)
                    if !displayDislikeCount.isEmpty {
                        Text(displayDislikeCount)
                            .font(.subheadline.weight(.medium))
                    }
                }
                .foregroundStyle(userDisliked ? Color.blue : Color.primary)
                .padding(.leading, 10)
                .padding(.trailing, 14)
                .padding(.vertical, 8)
            }
            .buttonStyle(SpringPressButtonStyle())
        }
        .background(Color(.secondarySystemFill), in: Capsule())
    }

    private var displayLikeCount: String {
        let base = votes?.likes ?? 0
        let total = base + (userLiked ? 1 : 0)
        return total > 0 ? Fmt.count(total) : "Thích"
    }

    private var displayDislikeCount: String {
        if let d = votes?.dislikes {
            let total = d + (userDisliked ? 1 : 0)
            return total > 0 ? Fmt.count(total) : ""
        }
        return userDisliked ? "1" : ""
    }

    /// Nút Tải xuống hiển thị tiến trình phần trăm thời gian thực
    @ViewBuilder
    private func downloadPill(_ v: Video) -> some View {
        if let a = dl.active[v.id] {
            Button {
                dl.cancel(v.id)
                showToast("Đã huỷ tải xuống")
            } label: {
                HStack(spacing: 6) {
                    ProgressView(value: a.progress)
                        .frame(width: 24)
                        .tint(.red)
                    Text("\(Int(a.progress * 100))%")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.15), in: Capsule())
                .foregroundStyle(Color.red)
            }
            .buttonStyle(.plain)
        } else if dl.isDownloaded(v.id) {
            Button {
                showToast("Video đã tải xuống trong bộ nhớ máy")
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.blue)
                    Text("Đã tải")
                        .font(.subheadline.weight(.medium))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemFill), in: Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
        } else {
            Menu {
                Button {
                    dl.start(v, audioOnly: false)
                    showToast("Đang tải video (chất lượng cao)…")
                } label: {
                    Label("Tải video", systemImage: "video")
                }

                Button {
                    dl.start(v, audioOnly: true)
                    showToast("Đang tải âm thanh (M4A)…")
                } label: {
                    Label("Chỉ tải âm thanh", systemImage: "waveform")
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.subheadline)
                    Text("Tải xuống")
                        .font(.subheadline.weight(.medium))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemFill), in: Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
        }
    }

    private func triggerRemix(_ v: Video) {
        showToast("Tính năng phối lại âm thanh đã sẵn sàng")
    }

    // MARK: - 4. Comments Teaser Box (Hộp tóm tắt bình luận)

    private func commentsTeaser(_ v: Video) -> some View {
        Button {
            showComments = true
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                // Tiêu đề: "Bình luận [Số lượng]"
                HStack {
                    Text("Bình luận")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)

                    if let count = topCommentCount {
                        Text(count)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }

                // Nội dung trích đoạn kèm Avatar
                if let top = topComment {
                    HStack(alignment: .top, spacing: 10) {
                        Avatar(url: top.avatar, name: top.author, size: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(top.author)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            Text(top.text)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                    }
                } else if pm.commentsToken == nil {
                    Text("Bình luận đã bị tắt cho video này.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color(.tertiarySystemFill))
                            .frame(width: 24, height: 24)
                        Text("Nhấn để xem các bình luận…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(.secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(pm.commentsToken == nil)
    }

    // MARK: - 5. Up Next & Recommendations

    private func recommendedSection(_ v: Video) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Hàng đợi phát (Queue) nếu có
            if !pm.queue.isEmpty {
                HStack {
                    Text("Hàng đợi (\(pm.queue.count))")
                        .font(.headline)
                    Spacer()
                    Button("Xoá hàng đợi") {
                        pm.clearQueue()
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
                }
                .padding(.top, 4)

                ForEach(pm.queue) { q in
                    YouTubeWatchVideoRow(video: q, isCurrentQueue: true) {
                        pm.play(q)
                    }
                }
            }

            // Thanh tiêu đề Tiếp theo & Toggle Tự phát
            HStack {
                Text(v.source == nil ? "Tiếp theo" : "Radio – Phát tiếp")
                    .font(.headline)
                Spacer()
                Toggle("Tự phát", isOn: $autoplay)
                    .fixedSize()
                    .font(.subheadline)
            }
            .padding(.top, 6)

            // Danh sách đề xuất liên quan (Related Videos)
            if pm.related.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Đang tải video đề xuất…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ForEach(pm.related) { r in
                    YouTubeWatchVideoRow(video: r) {
                        pm.play(r)
                    }
                }
            }
        }
    }

    // MARK: - Video Metadata Loading

    private nonisolated static func fetchVotes(for video: Video) async -> Votes? {
        if video.source == nil || video.source == .ytMusic {
            return await Extras.votes(video.id)
        }
        return nil
    }

    private nonisolated static func fetchTopComment(token: String?) async -> (Comment?, String?) {
        guard let token else { return (nil, nil) }
        if let res = try? await InnerTube.shared.comments(token), let first = res.items.first {
            return (first, res.items.count > 0 ? "\(res.items.count)+" : nil)
        }
        return (nil, nil)
    }

    private nonisolated static func fetchChannel(id: String?, known: Channel?) async -> Channel? {
        if let known { return known }
        guard let id, !id.isEmpty else { return nil }
        let page = try? await InnerTube.shared.channelVideos(id, continuation: nil)
        return page?.channel
    }

    private func loadVideoMeta(_ v: Video) {
        let token = pm.commentsToken
        let chId = v.channelId
        let knownSub = chId.flatMap { id in lib.subscriptions.first(where: { $0.id == id }) }

        Task {
            async let votesRes = Self.fetchVotes(for: v)
            async let commentRes = Self.fetchTopComment(token: token)
            async let channelRes = Self.fetchChannel(id: chId, known: knownSub)

            let vRes = await votesRes
            let cRes = await commentRes
            let chRes = await channelRes
            guard pm.current?.id == v.id else { return }
            self.votes = vRes
            self.topComment = cRes.0
            self.topCommentCount = cRes.1
            if let chRes {
                self.channelDetail = chRes
            }
        }
    }

    private func showToast(_ msg: String) {
        toastTask?.cancel()
        withAnimation { toastMessage = msg }
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { toastMessage = nil }
        }
    }

    private func handleURL(_ url: URL) -> OpenURLAction.Result {
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
}

// MARK: - YouTube Compact Video Card

/// Thẻ video đề xuất chuẩn phong cách YouTube iOS:
/// Thumbnail 16:9 sắc nét, nhãn thời lượng, thanh tiến trình màu đỏ, tiêu đề 2 dòng, tên kênh và menu 3 chấm.
struct YouTubeWatchVideoRow: View {
    let video: Video
    var isCurrentQueue = false
    var onSelect: () -> Void

    @ObservedObject private var lib = Library.shared
    @ObservedObject private var dl = DownloadManager.shared
    @State private var showAddToPlaylist = false

    private var progress: Double? {
        guard let total = Fmt.seconds(video.duration), total > 0 else { return nil }
        let p = Library.shared.position(video.id)
        return p > 0 ? p / total : nil
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 12) {
                // Thumbnail với badge thời lượng và progress bar
                Thumbnail(
                    url: video.thumbnail,
                    duration: video.duration,
                    progress: progress
                )
                .frame(width: 150)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                // Thông tin video
                VStack(alignment: .leading, spacing: 4) {
                    Text(video.title.isEmpty ? "Video YouTube" : video.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    if !video.channelTitle.isEmpty {
                        Text(video.channelTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    HStack(spacing: 4) {
                        if let v = video.views, !v.isEmpty {
                            Text(v)
                        }
                        if video.views != nil && video.published != nil {
                            Text("•")
                        }
                        if let p = video.published, !p.isEmpty {
                            Text(p)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                Spacer(minLength: 0)

                // Nút tuỳ chọn 3 chấm (Menu)
                Menu {
                    Button {
                        PlayerManager.shared.playNext(video)
                    } label: {
                        Label("Phát tiếp theo", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }

                    Button {
                        lib.toggleWatchLater(video)
                    } label: {
                        Label(lib.isInWatchLater(video.id) ? "Xoá khỏi Xem sau" : "Lưu vào Xem sau",
                              systemImage: lib.isInWatchLater(video.id) ? "clock.fill" : "clock")
                    }

                    Button {
                        showAddToPlaylist = true
                    } label: {
                        Label("Lưu vào danh sách phát", systemImage: "plus.square.on.square")
                    }

                    ShareLink(item: video.shareURL) {
                        Label("Chia sẻ", systemImage: "arrowshape.turn.up.right")
                    }

                    Button {
                        dl.start(video, audioOnly: false)
                    } label: {
                        Label("Tải xuống video", systemImage: "arrow.down.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showAddToPlaylist) {
            AddToPlaylistView(video: video)
                .presentationDetents([.medium, .large])
        }
    }
}

// MARK: - YouTube Description Bottom Sheet

/// Bottom Sheet mô tả đầy đủ chuẩn phong cách YouTube iOS:
/// Bao gồm số lượt xem đầy đủ, ngày phát hành, thống kê lượt thích, và nội dung mô tả có thể nhấn timestamp.
struct YouTubeDescriptionSheet: View {
    let video: Video
    let votes: Votes?
    let info: VideoInfo?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Tiêu đề
                    Text(video.title)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    // Hộp thông số thống kê (Lượt thích, Không thích, Lượt xem, Ngày đăng)
                    HStack(spacing: 0) {
                        statCell(
                            title: votes != nil ? Fmt.count(votes!.likes) : "Thích",
                            subtitle: "Lượt thích"
                        )
                        Divider().frame(height: 28)
                        statCell(
                            title: votes != nil ? Fmt.count(votes!.dislikes) : "–",
                            subtitle: "Không thích"
                        )
                        Divider().frame(height: 28)
                        statCell(
                            title: info?.viewCount != nil ? Fmt.count(info!.viewCount!) : (video.views ?? "–"),
                            subtitle: "Lượt xem"
                        )
                        Divider().frame(height: 28)
                        statCell(
                            title: video.published ?? "Gần đây",
                            subtitle: "Ngày đăng"
                        )
                    }
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))

                    // Kênh phát hành
                    HStack(spacing: 10) {
                        Avatar(url: nil, name: video.channelTitle, size: 32)
                        Text(video.channelTitle)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                    }

                    Divider()

                    // Nội dung mô tả với timestamp tương tác
                    if let desc = info?.description, !desc.isEmpty {
                        Text(linkified(desc))
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    } else {
                        Text("Không có mô tả cho video này.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Mô tả")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Đóng") { dismiss() }
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
    }

    private func statCell(title: String, subtitle: String) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.subheadline.bold())
                .foregroundStyle(.primary)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func linkified(_ s: String) -> AttributedString {
        var a = AttributedString(s)
        let full = NSRange(location: 0, length: (s as NSString).length)

        // Nhận diện URLs
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for m in detector.matches(in: s, range: full) {
                guard let url = m.url, let r = Range(m.range, in: s), let ar = Range(r, in: a) else { continue }
                a[ar].link = url
            }
        }

        // Nhận diện mốc thời gian (Timestamps: mm:ss hoặc hh:mm:ss)
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

// MARK: - YouTube Native Comments Sheet

struct CommentsView: View {
    let token: String?
    var channelTitle: String? = nil
    var channelAvatar: URL? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var comments: [Comment] = []
    @State private var nextToken: String?
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var hasStarted = false
    @State private var expandedReplies: Set<String> = []
    @State private var loadingReplies: Set<String> = []
    @State private var selectedFilter: CommentFilter = .top

    enum CommentFilter: String, CaseIterable {
        case top = "Hàng đầu"
        case newest = "Mới nhất"
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            Divider()

            if isLoading && comments.isEmpty {
                VStack(spacing: 12) {
                    ProgressView().tint(.primary).scaleEffect(1.2)
                    Text("Đang tải bình luận…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = errorText, comments.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.title).foregroundStyle(.red)
                    Text(err).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
                    Button("Thử lại") {
                        Task { await loadComments(reset: true) }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if comments.isEmpty && hasStarted {
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Chưa có bình luận nào").font(.subheadline.weight(.semibold))
                    Text("Hãy là người đầu tiên bình luận về video này.").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                commentsScrollView
            }
        }
        .background(Color(.systemBackground))
        .navigationBarHidden(true)
        .task {
            guard !hasStarted else { return }
            hasStarted = true
            nextToken = token
            await loadComments(reset: false)
        }
    }

    private var headerBar: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Bình luận")
                    .font(.headline.weight(.bold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .background(Color(.secondarySystemFill), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            // Bộ lọc: Hàng đầu / Mới nhất
            HStack(spacing: 8) {
                ForEach(CommentFilter.allCases, id: \.self) { filter in
                    Button {
                        selectedFilter = filter
                    } label: {
                        Text(filter.rawValue)
                            .font(.system(size: 13, weight: .semibold))
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
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private var commentsScrollView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(comments) { c in
                    VStack(alignment: .leading, spacing: 10) {
                        // Thẻ bình luận chính
                        CommentRowView(
                            comment: c,
                            channelTitle: channelTitle,
                            channelAvatar: channelAvatar
                        )

                        // Nút hiển thị / ẩn danh sách câu trả lời (Replies)
                        if c.replyCount > 0 || !c.replies.isEmpty || c.repliesToken != nil {
                            Button {
                                toggleReplies(for: c)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: expandedReplies.contains(c.id) ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 11, weight: .bold))
                                    Text(expandedReplies.contains(c.id)
                                        ? "Ẩn câu trả lời"
                                        : (c.replyCount > 0 ? "Xem \(c.replyCount) câu trả lời" : "Xem câu trả lời"))
                                        .font(.caption.weight(.bold))
                                }
                                .foregroundStyle(Color.blue)
                            }
                            .padding(.leading, 46)
                        }

                        // Danh sách phân cấp các câu trả lời khi mở rộng
                        if expandedReplies.contains(c.id) {
                            if loadingReplies.contains(c.id) {
                                HStack {
                                    ProgressView()
                                        .scaleEffect(0.85)
                                    Text("Đang tải câu trả lời…")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.leading, 46)
                            } else {
                                VStack(alignment: .leading, spacing: 14) {
                                    ForEach(c.replies) { reply in
                                        ReplyRowView(
                                            reply: reply,
                                            channelTitle: channelTitle,
                                            channelAvatar: channelAvatar
                                        )
                                    }
                                }
                                .padding(.leading, 46)
                            }
                        }
                    }
                    .onAppear {
                        if c.id == comments.last?.id {
                            Task { await loadComments(reset: false) }
                        }
                    }
                }

                if isLoading && !comments.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView().tint(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 12)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .refreshable {
            await loadComments(reset: true)
        }
    }

    private func toggleReplies(for comment: Comment) {
        if expandedReplies.contains(comment.id) {
            expandedReplies.remove(comment.id)
        } else {
            expandedReplies.insert(comment.id)
            if comment.replies.isEmpty, let token = comment.repliesToken {
                loadReplies(for: comment.id, token: token)
            }
        }
    }

    private func loadReplies(for commentId: String, token: String) {
        loadingReplies.insert(commentId)
        Task {
            if let res = try? await InnerTube.shared.comments(token) {
                if let idx = comments.firstIndex(where: { $0.id == commentId }) {
                    comments[idx].replies = res.items
                }
            }
            loadingReplies.remove(commentId)
        }
    }

    private func loadComments(reset: Bool) async {
        if reset {
            nextToken = token
            comments.removeAll()
            expandedReplies.removeAll()
        }
        guard let t = nextToken, !isLoading else { return }
        isLoading = true
        errorText = nil
        do {
            let res = try await InnerTube.shared.comments(t)
            let seen = Set(comments.map(\.id))
            let newItems = res.items.filter { !seen.contains($0.id) }
            comments.append(contentsOf: newItems)
            nextToken = res.next
        } catch {
            if comments.isEmpty {
                errorText = error.localizedDescription
            }
        }
        isLoading = false
    }
}

// MARK: - CommentRowView

private struct CommentRowView: View {
    let comment: Comment
    let channelTitle: String?
    let channelAvatar: URL?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Avatar(url: comment.avatar, name: comment.author, size: 34)

            VStack(alignment: .leading, spacing: 5) {
                // Nhãn bình luận được ghim (Pinned Badge)
                if comment.isPinned {
                    HStack(spacing: 4) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10))
                        Text("Được ghim bởi \(channelTitle ?? "chủ kênh")")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(.secondary)
                }

                // Dòng tên tác giả + Huy hiệu tác giả (Channel Badge) + Ngày đăng
                HStack(spacing: 6) {
                    if comment.isChannelOwner || (channelTitle != nil && comment.author == channelTitle) {
                        HStack(spacing: 3) {
                            Text(comment.author)
                                .font(.system(size: 12, weight: .bold))
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.12), in: Capsule())
                    } else {
                        Text("@\(comment.author)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }

                    Text("• \(comment.published)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                // Nội dung bình luận
                Text(comment.text)
                    .font(.subheadline)
                    .foregroundStyle(.primary)

                // Hàng nút tương tác: Like, Dislike, Nút thả tim của chủ kênh
                HStack(spacing: 16) {
                    HStack(spacing: 4) {
                        Image(systemName: "hand.thumbsup")
                            .font(.system(size: 12))
                        if !comment.likes.isEmpty {
                            Text(comment.likes)
                                .font(.system(size: 11, weight: .medium))
                        }
                    }
                    .foregroundStyle(.secondary)

                    Image(systemName: "hand.thumbsdown")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    // Nút thả tim của chủ kênh (Creator Heart)
                    if comment.isHeartedByCreator {
                        HStack(spacing: -5) {
                            Avatar(url: channelAvatar, name: channelTitle ?? "Kênh", size: 16)
                                .clipShape(Circle())
                            Image(systemName: "heart.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.red)
                        }
                    }

                    Text("Phản hồi")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }
        }
    }
}

// MARK: - ReplyRowView

private struct ReplyRowView: View {
    let reply: Comment
    let channelTitle: String?
    let channelAvatar: URL?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(url: reply.avatar, name: reply.author, size: 26)

            VStack(alignment: .leading, spacing: 4) {
                // Tên tác giả + Huy hiệu nếu là chủ kênh
                HStack(spacing: 6) {
                    if reply.isChannelOwner || (channelTitle != nil && reply.author == channelTitle) {
                        HStack(spacing: 3) {
                            Text(reply.author)
                                .font(.system(size: 11, weight: .bold))
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 9))
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.primary.opacity(0.12), in: Capsule())
                    } else {
                        Text("@\(reply.author)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }

                    Text("• \(reply.published)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                // Nội dung câu trả lời
                Text(reply.text)
                    .font(.footnote)
                    .foregroundStyle(.primary)

                // Nút thích & Thả tim của chủ kênh
                HStack(spacing: 14) {
                    HStack(spacing: 4) {
                        Image(systemName: "hand.thumbsup")
                            .font(.system(size: 11))
                        if !reply.likes.isEmpty {
                            Text(reply.likes)
                                .font(.system(size: 10, weight: .medium))
                        }
                    }
                    .foregroundStyle(.secondary)

                    Image(systemName: "hand.thumbsdown")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    if reply.isHeartedByCreator {
                        HStack(spacing: -5) {
                            Avatar(url: channelAvatar, name: channelTitle ?? "Kênh", size: 14)
                                .clipShape(Circle())
                            Image(systemName: "heart.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.red)
                        }
                    }
                }
                .padding(.top, 1)
            }
        }
    }
}

// MARK: - Compatibility Extensions

private extension View {
    @ViewBuilder
    func commentsSheetBackgroundInteraction() -> some View {
        if #available(iOS 16.4, *) {
            self.presentationBackgroundInteraction(.enabled(upThrough: .medium))
        } else {
            self
        }
    }
}
