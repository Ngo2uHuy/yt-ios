import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - YouTube Root View

struct YouTubeRootView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedTab: YouTubeTab = .home
    @State private var visitedTabs: Set<YouTubeTab> = [.home]
    @State private var showWatch: Bool = false
    @State private var showCreateSheet: Bool = false
    @State private var hasCurrentTrack: Bool = (PlayerManager.shared.current != nil)
    private let pm = PlayerManager.shared

    var body: some View {
        ZStack(alignment: .bottom) {
            // Preserve feed tab states once visited; unmount Shorts when leaving its tab
            ZStack {
                if visitedTabs.contains(.home) {
                    YouTubeHomeView()
                        .opacity(selectedTab == .home ? 1 : 0)
                        .allowsHitTesting(selectedTab == .home)
                        .accessibilityHidden(selectedTab != .home)
                        .zIndex(selectedTab == .home ? 1 : 0)
                }

                if visitedTabs.contains(.subscriptions) {
                    YouTubeSubscriptionsView()
                        .opacity(selectedTab == .subscriptions ? 1 : 0)
                        .allowsHitTesting(selectedTab == .subscriptions)
                        .accessibilityHidden(selectedTab != .subscriptions)
                        .zIndex(selectedTab == .subscriptions ? 1 : 0)
                }

                if visitedTabs.contains(.you) {
                    YouTubeYouView()
                        .opacity(selectedTab == .you ? 1 : 0)
                        .allowsHitTesting(selectedTab == .you)
                        .accessibilityHidden(selectedTab != .you)
                        .zIndex(selectedTab == .you ? 1 : 0)
                }

                if selectedTab == .shorts {
                    YouTubeShortsView(isTab: true)
                        .zIndex(2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Floating MiniPlayer + 5-Tab Bottom Bar
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if selectedTab != .shorts && hasCurrentTrack {
                        YouTubeMiniPlayerBar()
                    }

                    YouTubeBottomBar(
                        selectedTab: $selectedTab,
                        unreadSubscriptionsCount: 0,
                        hasYouDot: false,
                        onCreateTap: {
                            showCreateSheet = true
                        }
                    )
                    .environment(\.colorScheme, selectedTab == .shorts ? .dark : colorScheme)
                }
            }
        }
        .ignoresSafeArea(.keyboard)
        .onChange(of: selectedTab) { tab in
            if tab != .create {
                visitedTabs.insert(tab)
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            YouTubeCreateSheet()
                .presentationDetents([.fraction(0.44), .medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showWatch) {
            YouTubeWatchView()
        }
        .onReceive(pm.$current) { v in
            let has = (v != nil)
            if hasCurrentTrack != has {
                hasCurrentTrack = has
            }
        }
        .onReceive(pm.$showWatch) { show in
            if showWatch != show { showWatch = show }
        }
        .onChange(of: showWatch) { show in
            if pm.showWatch != show {
                pm.showWatch = show
            }
        }
    }
}

// MARK: - YouTube MiniPlayer Integration

extension View {
    func withYouTubeMiniPlayer() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            YouTubeMiniPlayerBar()
        }
    }
}

struct YouTubeMiniPlayerBar: View {
    @ObservedObject private var pm = PlayerManager.shared

    var body: some View {
        if let v = pm.current {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    // 16:9 Thumbnail with Duration Overlay
                    ZStack(alignment: .bottomTrailing) {
                        Thumbnail(url: v.thumbnail)
                            .frame(width: 76, height: 43)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                        if let dur = v.duration, !dur.isEmpty {
                            Text(dur)
                                .font(.system(size: 9, weight: .bold).monospacedDigit())
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
                                .foregroundStyle(.white)
                                .padding(2)
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(v.title.isEmpty ? "Đang tải…" : v.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(YTColor.textPrimary)
                            .lineLimit(1)

                        Text(v.channelTitle)
                            .font(.system(size: 11))
                            .foregroundStyle(YTColor.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    // Nút Play/Pause
                    Button {
                        #if canImport(UIKit)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        #endif
                        pm.togglePlay()
                    } label: {
                        Image(systemName: pm.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(YTColor.textPrimary)
                            .frame(width: 36, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    // Nút Đóng
                    Button {
                        #if canImport(UIKit)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        #endif
                        pm.close()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(YTColor.textSecondary)
                            .frame(width: 36, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)

                // YouTube Red Progress Bar along bottom edge
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.primary.opacity(0.12))
                            .frame(height: 2)

                        let prog = pm.duration > 0 ? min(max(pm.currentTime / pm.duration, 0), 1) : 0
                        Rectangle()
                            .fill(YTColor.brandRed)
                            .frame(width: g.size.width * CGFloat(prog), height: 2)
                    }
                }
                .frame(height: 2)
            }
            .background(
                ZStack {
                    YTColor.surfaceSecondary.opacity(0.94)
                    Rectangle()
                        .fill(.regularMaterial)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.35), radius: 8, x: 0, y: 4)
            .padding(.horizontal, 8)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
            .onTapGesture {
                pm.showWatch = true
            }
            .gesture(
                DragGesture(minimumDistance: 20).onEnded { val in
                    let dx = val.translation.width, dy = val.translation.height
                    if abs(dx) > abs(dy) {
                        if dx < -50 { pm.next() } else if dx > 50 { pm.previous() }
                    } else if dy < -30 {
                        pm.showWatch = true
                    }
                }
            )
        }
    }
}
