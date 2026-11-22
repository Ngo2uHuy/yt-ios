import AVFoundation
import SwiftUI

@main
struct VidraApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // .playback keeps sound going with the silent switch on, screen locked or app in background.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                PlayerManager.shared.savePosition()
                Library.shared.flush()
            }
        }
    }
}

struct ContentView: View {
    @ObservedObject private var pm = PlayerManager.shared
    @ObservedObject private var downloads = DownloadManager.shared

    var body: some View {
        TabView {
            HomeView().withMiniPlayer()
                .tabItem { Label("Trang chủ", systemImage: "house.fill") }
            SearchView().withMiniPlayer()
                .tabItem { Label("Tìm kiếm", systemImage: "magnifyingglass") }
            MusicView().withMiniPlayer()
                .tabItem { Label("Nhạc", systemImage: "music.note") }
            SubscriptionsView().withMiniPlayer()
                .tabItem { Label("Đăng ký", systemImage: "person.2.fill") }
            LibraryView().withMiniPlayer()
                .tabItem { Label("Thư viện", systemImage: "books.vertical.fill") }
        }
        .tint(.red)
        .sheet(isPresented: $pm.showWatch) {
            // Music gets the dedicated now-playing screen; videos get the video player.
            if pm.current?.source != nil { NowPlayingView() } else { WatchView() }
        }
        .alert(
            "Tải xuống thất bại",
            isPresented: Binding(get: { downloads.lastError != nil }, set: { if !$0 { downloads.lastError = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(downloads.lastError ?? "")
        }
    }
}

extension View {
    func withMiniPlayer() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayerBar() }
    }
}

struct MiniPlayerBar: View {
    @ObservedObject private var pm = PlayerManager.shared

    var body: some View {
        if let v = pm.current {
            VStack(spacing: 0) {
                GeometryReader { g in
                    Rectangle()
                        .fill(Color.red)
                        .frame(width: pm.duration > 0 ? g.size.width * min(pm.currentTime / pm.duration, 1) : 0)
                }
                .frame(height: 2)
                HStack(spacing: 12) {
                    Thumbnail(url: v.thumbnail).frame(width: 80)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(v.title.isEmpty ? "Đang tải…" : v.title).font(.subheadline.weight(.medium)).lineLimit(1)
                        Text(v.channelTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button { pm.togglePlay() } label: {
                        Image(systemName: pm.isPlaying ? "pause.fill" : "play.fill").font(.title3).frame(width: 36, height: 36)
                    }
                    Button { pm.next() } label: { Image(systemName: "forward.fill").frame(width: 32, height: 36) }
                    Button { pm.close() } label: { Image(systemName: "xmark").frame(width: 32, height: 36) }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .background(.bar)
            .contentShape(Rectangle())
            .onTapGesture { pm.showWatch = true }
            // Swipe sideways to skip, swipe up to open.
            .gesture(
                DragGesture(minimumDistance: 20).onEnded { v in
                    let dx = v.translation.width, dy = v.translation.height
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
