import AVFoundation
import SwiftUI
import UIKit

@main
struct VidraApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // .playback keeps sound going with the silent switch on, screen locked or app in background.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        URLCache.shared = URLCache(memoryCapacity: 16 << 20, diskCapacity: 256 << 20)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    SpotifyRemote.shared.handleURL(url)
                }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                HLSServer.shared.ensureRunning()
                if PlayerManager.shared.current != nil && !PlayerManager.shared.isUsingSpotifyRemote {
                    try? AVAudioSession.sharedInstance().setActive(true)
                }
            } else if phase == .background {
                var bgId: UIBackgroundTaskIdentifier = .invalid
                bgId = UIApplication.shared.beginBackgroundTask(withName: "vidra.flush") {
                    if bgId != .invalid {
                        UIApplication.shared.endBackgroundTask(bgId)
                        bgId = .invalid
                    }
                }
                PlayerManager.shared.savePosition(persist: true)
                Library.shared.flush()
                DownloadManager.shared.flushIndex()
                Task { @MainActor in
                    await TrackMatcher.shared.flush()
                    if bgId != .invalid {
                        UIApplication.shared.endBackgroundTask(bgId)
                        bgId = .invalid
                    }
                }
            }
        }
    }
}

struct ContentView: View {
    @ObservedObject private var modeManager = AppModeManager.shared

    var body: some View {
        Group {
            switch modeManager.currentMode {
            case .youtube:
                YouTubeRootView()
            case .spotify:
                SpotifyRootView()
            }
        }
        .overlay {
            DownloadErrorAlertObserver()
        }
    }
}

private struct DownloadErrorAlertObserver: View {
    @ObservedObject private var downloads = DownloadManager.shared

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
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
            let accentColor: Color = {
                switch v.source {
                case .spotify?: return Color(red: 0.11, green: 0.73, blue: 0.33)
                default: return Color.red
                }
            }()
            VStack(spacing: 0) {
                GeometryReader { g in
                    let frac = (pm.duration > 0 && pm.currentTime.isFinite)
                        ? min(max(pm.currentTime / pm.duration, 0), 1)
                        : 0
                    Rectangle()
                        .fill(accentColor)
                        .frame(width: max(0, g.size.width * frac))
                }
                .frame(height: 2.5)
                HStack(spacing: 12) {
                    if v.source != nil {
                        CachedAsyncImage(url: v.thumbnail, targetSize: CGSize(width: 44, height: 44)) { $0.resizable().scaledToFill() } placeholder: {
                            ZStack {
                                Color(.secondarySystemFill)
                                Image(systemName: "music.note").foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    } else {
                        Thumbnail(url: v.thumbnail).frame(width: 76)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(v.title.isEmpty ? "Đang tải…" : v.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(v.channelTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button { pm.togglePlay() } label: {
                        Image(systemName: pm.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3.bold())
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                    }
                    Button { pm.next() } label: {
                        Image(systemName: "forward.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 36, height: 40)
                            .contentShape(Rectangle())
                    }
                    Button { pm.close() } label: {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 36, height: 40)
                            .contentShape(Rectangle())
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
            .background(.regularMaterial)
            .overlay(alignment: .top) {
                Divider().opacity(0.3)
            }
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
