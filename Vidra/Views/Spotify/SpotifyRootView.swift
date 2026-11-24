import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Spotify Navigation Tabs

enum SpotifyTab: Int, CaseIterable, Identifiable {
    case home = 0
    case search = 1
    case library = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .home: return "Trang chủ"
        case .search: return "Tìm kiếm"
        case .library: return "Thư viện"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .search: return "magnifyingglass"
        case .library: return "books.vertical.fill"
        }
    }
}

// MARK: - Spotify Root Navigation View

/// The main Spotify-mode root navigation container featuring a 3-tab layout, floating MiniPlayer, and full-screen player.
struct SpotifyRootView: View {
    @State private var selectedTab: SpotifyTab = .home
    @State private var showNowPlaying = false
    private let pm = PlayerManager.shared

    init() {
        #if canImport(UIKit)
        setupTabBarAppearance()
        #endif
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                // Tab 1: Trang chủ (SpotifyHomeFeedView)
                NavigationStack {
                    SpotifyHomeFeedView()
                }
                .withSpotifyMiniPlayer(onTap: { showNowPlaying = true })
                .tabItem {
                    Label(SpotifyTab.home.title, systemImage: SpotifyTab.home.icon)
                }
                .tag(SpotifyTab.home)

                // Tab 2: Tìm kiếm (SpotifySearchBrowseView)
                NavigationStack {
                    SpotifySearchBrowseView()
                }
                .withSpotifyMiniPlayer(onTap: { showNowPlaying = true })
                .tabItem {
                    Label(SpotifyTab.search.title, systemImage: SpotifyTab.search.icon)
                }
                .tag(SpotifyTab.search)

                // Tab 3: Thư viện (SpotifyLibraryView)
                NavigationStack {
                    SpotifyLibraryView()
                }
                .withSpotifyMiniPlayer(onTap: { showNowPlaying = true })
                .tabItem {
                    Label(SpotifyTab.library.title, systemImage: SpotifyTab.library.icon)
                }
                .tag(SpotifyTab.library)
            }
            .tint(SpotifyColor.textPrimary)
        }
        .preferredColorScheme(.dark)
        // Sheet mở trình phát toàn màn hình khi bấm vào MiniPlayer
        .sheet(isPresented: $showNowPlaying) {
            SpotifyNowPlayingFullView()
        }
        // Tự động mở Now Playing khi phát bài mới từ bất kỳ danh sách nào
        .onReceive(pm.$showWatch) { show in
            if show {
                showNowPlaying = true
                pm.showWatch = false
            }
        }
    }

    #if canImport(UIKit)
    private func setupTabBarAppearance() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(red: 18 / 255.0, green: 18 / 255.0, blue: 18 / 255.0, alpha: 0.98)

        let itemAppearance = UITabBarItemAppearance()
        itemAppearance.normal.iconColor = UIColor(red: 179 / 255.0, green: 179 / 255.0, blue: 179 / 255.0, alpha: 1.0)
        itemAppearance.normal.titleTextAttributes = [
            .foregroundColor: UIColor(red: 179 / 255.0, green: 179 / 255.0, blue: 179 / 255.0, alpha: 1.0),
            .font: UIFont.systemFont(ofSize: 10, weight: .medium)
        ]
        itemAppearance.selected.iconColor = UIColor.white
        itemAppearance.selected.titleTextAttributes = [
            .foregroundColor: UIColor.white,
            .font: UIFont.systemFont(ofSize: 10, weight: .bold)
        ]

        appearance.stackedLayoutAppearance = itemAppearance
        appearance.inlineLayoutAppearance = itemAppearance
        appearance.compactInlineLayoutAppearance = itemAppearance

        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }
    #endif
}

// MARK: - Component: SpotifyMiniPlayerBar

/// Floating pill-style MiniPlayer bar positioned immediately above the tab bar.
struct SpotifyMiniPlayerBar: View {
    @ObservedObject private var pm = PlayerManager.shared
    @ObservedObject private var library = Library.shared
    @State private var ambientTint: Color = SpotifyColor.surface
    var onTap: (() -> Void)?

    init(onTap: (() -> Void)? = nil) {
        self.onTap = onTap
    }

    var body: some View {
        if let video = pm.current {
            let isLiked = library.isLiked(video.id)

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    // 1. Ảnh bìa vuông 44x44
                    CachedAsyncImage(url: video.thumbnail, targetSize: CGSize(width: 88, height: 88)) { image in
                        image
                            .resizable()
                            .scaledToFill()
                    } placeholder: {
                        ZStack {
                            SpotifyColor.surfaceHighlight
                            Image(systemName: "music.note")
                                .font(.system(size: 15))
                                .foregroundColor(SpotifyColor.textSecondary)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: Color.black.opacity(0.35), radius: 4, x: 0, y: 2)

                    // 2. Tên bài hát & Nghệ sĩ
                    VStack(alignment: .leading, spacing: 2) {
                        Text(video.title.isEmpty ? "Đang tải…" : video.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(SpotifyColor.textPrimary)
                            .lineLimit(1)

                        Text(video.channelTitle.isEmpty ? "Nghệ sĩ" : video.channelTitle)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundColor(SpotifyColor.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    // 3. Biểu tượng Spotify Connect thiết bị phát
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(SpotifyColor.brandGreen)
                        .padding(.trailing, 2)

                    // 4. Nút trái tim (Heart Toggle) với hiệu ứng nảy
                    Button {
                        #if canImport(UIKit)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        #endif
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) {
                            library.toggleLike(video)
                        }
                    } label: {
                        Image(systemName: isLiked ? "heart.fill" : "heart")
                            .font(.system(size: 19))
                            .foregroundColor(isLiked ? SpotifyColor.brandGreen : SpotifyColor.textPrimary)
                            .scaleEffect(isLiked ? 1.08 : 1.0)
                            .frame(width: 36, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(SpringPressButtonStyle())

                    // 5. Nút play/pause
                    Button {
                        #if canImport(UIKit)
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        #endif
                        pm.togglePlay()
                    } label: {
                        Image(systemName: pm.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(SpotifyColor.textPrimary)
                            .frame(width: 36, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(SpringPressButtonStyle())
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)

                // 6. Thanh tiến trình xanh lá 2pt ở viền đáy
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.white.opacity(0.12))
                            .frame(height: 2)

                        let progress = pm.duration > 0 ? min(max(pm.currentTime / pm.duration, 0.0), 1.0) : 0.0
                        Rectangle()
                            .fill(SpotifyColor.brandGreen)
                            .frame(width: geo.size.width * CGFloat(progress), height: 2)
                    }
                }
                .frame(height: 2)
            }
            .background(
                ZStack {
                    Color(red: 24 / 255.0, green: 24 / 255.0, blue: 24 / 255.0).opacity(0.95)
                    Rectangle().fill(.ultraThinMaterial)
                    LinearGradient(
                        colors: [ambientTint.opacity(0.6), Color.clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.16), Color.white.opacity(0.04)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            )
            .shadow(color: Color.black.opacity(0.45), radius: 10, x: 0, y: 5)
            .contentShape(Rectangle())
            .onTapGesture {
                onTap?()
            }
            .task(id: video.thumbnail) {
                if let url = video.thumbnail, let c = await ArtworkColorCache.shared.color(for: url) {
                    withAnimation(.easeInOut(duration: 0.5)) {
                        ambientTint = c
                    }
                } else {
                    ambientTint = SpotifyColor.surface
                }
            }
            .gesture(
                DragGesture(minimumDistance: 20).onEnded { value in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    if abs(dx) > abs(dy) {
                        if dx < -50 {
                            pm.next()
                        } else if dx > 50 {
                            pm.previous()
                        }
                    } else if dy < -30 {
                        onTap?()
                    }
                }
            )
        }
    }
}

// MARK: - MiniPlayer Inset Extension

extension View {
    /// Insets the floating Spotify mini player directly above the bottom tab bar.
    func withSpotifyMiniPlayer(onTap: @escaping () -> Void) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            SpotifyFloatingMiniPlayerContainer(onTap: onTap)
        }
    }
}

/// Floating container for the mini player with edge padding and animated transition.
private struct SpotifyFloatingMiniPlayerContainer: View {
    @ObservedObject private var pm = PlayerManager.shared
    var onTap: () -> Void

    var body: some View {
        if pm.current != nil {
            SpotifyMiniPlayerBar(onTap: onTap)
                .padding(.horizontal, 8)
                .padding(.bottom, 2)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
