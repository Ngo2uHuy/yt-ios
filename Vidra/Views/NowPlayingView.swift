import CoreImage
import SwiftUI
import UIKit

// MARK: - Artwork color cache

@MainActor
final class ArtworkColorCache {
    static let shared = ArtworkColorCache()
    private static let ciContext = CIContext(options: [.workingColorSpace: NSNull()])

    private var cache: [URL: Color] = [:]
    private var keys: [URL] = []
    private var inFlight: [URL: Task<Color?, Never>] = [:]

    func color(for url: URL) async -> Color? {
        if let hit = cache[url] { return hit }
        if let existingTask = inFlight[url] {
            return await existingTask.value
        }

        let task = Task<Color?, Never> {
            guard let uiImage = await ImageCache.shared.load(url: url) else { return nil }

            let rgb = await Task.detached(priority: .utility) { () -> (Double, Double, Double)? in
                let size = CGSize(width: 24, height: 24)
                let renderer = UIGraphicsImageRenderer(size: size)
                let small = renderer.image { _ in
                    uiImage.draw(in: CGRect(origin: .zero, size: size))
                }
                guard let ci = CIImage(image: small) else { return nil }
                guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
                    kCIInputImageKey: ci,
                    kCIInputExtentKey: CIVector(cgRect: ci.extent)
                ]), let output = filter.outputImage else { return nil }
                var px = [UInt8](repeating: 0, count: 4)
                Self.ciContext.render(output, toBitmap: &px, rowBytes: 4,
                                      bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                      format: .RGBA8, colorSpace: nil)
                return (Double(px[0]) / 255.0, Double(px[1]) / 255.0, Double(px[2]) / 255.0)
            }.value
            guard let rgb else { return nil }
            return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
        }

        inFlight[url] = task
        let color = await task.value
        inFlight.removeValue(forKey: url)

        if let color {
            if let idx = keys.firstIndex(of: url) {
                keys.remove(at: idx)
            }
            keys.append(url)
            while keys.count > 100 {
                let old = keys.removeFirst()
                cache.removeValue(forKey: old)
            }
            cache[url] = color
        }
        return color
    }
}

// MARK: - Now playing

struct NowPlayingView: View {
    @ObservedObject private var pm = PlayerManager.shared
    @ObservedObject private var library = Library.shared
    @ObservedObject private var downloads = DownloadManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var tint: Color = Color(white: 0.25)
    @State private var showLyrics = false
    @State private var showQueue = false
    @State private var artDrag: CGFloat = 0
    @State private var addTarget: Video?
    @State private var remapTarget: Video?
    @State private var lyrics: LyricsResult?
    @State private var lyricsLoading = false
    @State private var scrub: Double?

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors: [tint.opacity(0.95), Color.black], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                if let v = pm.current {
                    content(v)
                } else {
                    Text("Chưa có bài hát nào đang phát").foregroundStyle(Color.white.opacity(0.7))
                }
            }
            .navigationBarHidden(true)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showQueue) { QueueSheet().presentationDetents([.medium, .large]) }
        .sheet(item: $addTarget) { v in
            AddToPlaylistView(video: v).presentationDetents([.medium, .large])
        }
        .sheet(item: $remapTarget) { v in
            SpotifyRemapSheet(video: v).presentationDetents([.medium, .large])
        }
        .task(id: pm.current?.id) {
            showLyrics = false
            scrub = nil
            await loadTrackData()
            await loadLyrics()
        }
    }

    // MARK: Layout

    private func content(_ v: Video) -> some View {
        VStack(spacing: 0) {
            topBar(v)
            Group {
                if showLyrics {
                    LyricsView(lyrics: lyrics, loading: lyricsLoading)
                        .transition(.opacity)
                } else {
                    artwork(v)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            titleRow(v)
            scrubber(v)
            controls
            bottomRow
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    private func topBar(_ v: Video) -> some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
            }
            Spacer()
            VStack(spacing: 2) {
                Text("ĐANG PHÁT TỪ").font(.caption2).foregroundStyle(Color.white.opacity(0.6))
                Text(sourceLabel(v)).font(.footnote.weight(.semibold)).lineLimit(1)
            }
            Spacer()
            Menu {
                Menu {
                    ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2], id: \.self) { r in
                        Button {
                            pm.setRate(r)
                        } label: {
                            if pm.rate == r {
                                Label(Fmt.rate(Double(r)), systemImage: "checkmark")
                            } else {
                                Text(Fmt.rate(Double(r)))
                            }
                        }
                    }
                } label: {
                    Label("Tốc độ phát", systemImage: "speedometer")
                }
                SleepMenu()
                if v.source == .spotify {
                    Button { remapTarget = v } label: {
                        Label("Đổi bản YouTube Music", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                Button { addTarget = v } label: {
                    Label("Thêm vào danh sách phát", systemImage: "text.badge.plus")
                }
                Button { DownloadManager.shared.start(v, audioOnly: true) } label: {
                    Label(downloadTitle(v), systemImage: "arrow.down.circle")
                }
                .disabled(downloads.isDownloaded(v.id) || downloads.active[v.id] != nil)
                ShareLink(item: v.shareURL) {
                    Label("Chia sẻ", systemImage: "square.and.arrow.up")
                }
            } label: {
                Image(systemName: "ellipsis").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
            }
        }
        .foregroundStyle(Color.white)
    }

    private func sourceLabel(_ v: Video) -> String {
        switch v.source {
        case .spotify?: return "Spotify – phát qua YouTube Music"
        case .ytMusic?: return "YouTube Music"
        case nil: return "YouTube"
        }
    }

    private func downloadTitle(_ v: Video) -> String {
        if downloads.isDownloaded(v.id) { return "Đã tải xuống" }
        return downloads.active[v.id] != nil ? "Đang tải xuống…" : "Tải xuống"
    }

    private func artwork(_ v: Video) -> some View {
        ZStack {
            AsyncImage(url: v.thumbnail) { $0.resizable().scaledToFill() } placeholder: {
                ZStack {
                    Color.white.opacity(0.1)
                    Image(systemName: "music.note").font(.system(size: 60)).foregroundStyle(Color.white.opacity(0.4))
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: tint.opacity(0.45), radius: 28, y: 14)
            .shadow(color: Color.black.opacity(0.4), radius: 12, y: 6)
            .overlay { stateOverlay }
        }
        .scaleEffect(pm.isPlaying ? 1 : 0.86)
        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: pm.isPlaying)
        .offset(x: artDrag)
        .rotationEffect(.degrees(Double(artDrag) / 40))
        // Swipe the cover sideways to change track.
        .gesture(
            DragGesture(minimumDistance: 15)
                .onChanged { v in
                    if abs(v.translation.width) > abs(v.translation.height) { artDrag = v.translation.width }
                }
                .onEnded { v in
                    if v.translation.width < -80 {
                        pm.next()
                    } else if v.translation.width > 80 {
                        pm.previous()
                    }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { artDrag = 0 }
                }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var stateOverlay: some View {
        if let err = pm.errorText {
            VStack(spacing: 10) {
                Text(err).font(.footnote).multilineTextAlignment(.center)
                Button("Thử lại") { pm.retry() }.buttonStyle(.borderedProminent)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else if pm.isLoading {
            ZStack {
                Color.black.opacity(0.35)
                ProgressView().tint(Color.white).scaleEffect(1.4)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func titleRow(_ v: Video) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(v.title).font(.title3.weight(.bold)).lineLimit(2)
                artistLink(v)
            }
            Spacer(minLength: 8)
            let likeColor: Color = {
                switch v.source {
                case .spotify?: return Color(red: 0.11, green: 0.73, blue: 0.33)
                default: return Color.pink
                }
            }()
            Button { library.toggleLike(v) } label: {
                Image(systemName: library.isLiked(v.id) ? "heart.fill" : "heart")
                    .font(.title2)
                    .foregroundStyle(library.isLiked(v.id) ? likeColor : Color.white)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func artistLink(_ v: Video) -> some View {
        let label = Text(v.channelTitle).font(.body).foregroundStyle(Color.white.opacity(0.7)).lineLimit(1)
        if let cid = v.channelId, cid.hasPrefix("spa:") {
            NavigationLink { SpotifyArtistView(artistId: String(cid.dropFirst(4)), name: v.channelTitle) } label: { label }
        } else {
            label
        }
    }

    // MARK: Scrubber

    private func scrubber(_ v: Video) -> some View {
        let total = max(pm.duration, 0)
        let fraction = scrub ?? (total > 0 ? min(max(pm.currentTime / total, 0), 1) : 0)
        let shownTime = scrub.map { $0 * total } ?? pm.currentTime
        return VStack(spacing: 4) {
            GeometryReader { geo in
                SlimTrack(progress: fraction)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            scrub = min(max(g.location.x / max(geo.size.width, 1), 0), 1)
                        }
                        .onEnded { g in
                            let f = min(max(g.location.x / max(geo.size.width, 1), 0), 1)
                            scrub = nil
                            if total > 0 { pm.seek(to: f * total) }
                        }
                )
            }
            .frame(height: 24)
            HStack {
                Text(Fmt.time(shownTime))
                Spacer()
                Text("-" + Fmt.time(max(total - shownTime, 0)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(Color.white.opacity(0.6))
        }
        .padding(.vertical, 8)
    }

    // MARK: Controls

    private var controls: some View {
        HStack {
            Button {
                pm.queue.shuffle()
            } label: {
                Image(systemName: "shuffle").font(.title3)
            }
            .disabled(pm.queue.count < 2)
            Spacer()
            Button { pm.previous() } label: { Image(systemName: "backward.fill").font(.title) }
            Spacer()
            Button { pm.togglePlay() } label: {
                ZStack {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 64, height: 64)
                        .shadow(color: Color.black.opacity(0.3), radius: 6, y: 3)
                    Image(systemName: pm.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2.bold())
                        .foregroundStyle(Color.black)
                        .offset(x: pm.isPlaying ? 0 : 2)
                }
            }
            Spacer()
            Button { pm.next() } label: { Image(systemName: "forward.fill").font(.title) }
            Spacer()
            Button { pm.loop.toggle() } label: {
                Image(systemName: "repeat").font(.title3)
                    .foregroundStyle(pm.loop ? Color.green : Color.white)
            }
        }
        .foregroundStyle(Color.white)
        .padding(.bottom, 8)
    }

    private var bottomRow: some View {
        HStack {
            RoutePicker().frame(width: 32, height: 32)
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { showLyrics.toggle() }
            } label: {
                Image(systemName: "quote.bubble")
                    .font(.title3)
                    .foregroundStyle(showLyrics ? Color.green : Color.white)
            }
            Spacer()
            Button { showQueue = true } label: {
                Image(systemName: "list.bullet").font(.title3)
            }
            .foregroundStyle(Color.white)
        }
        .padding(.horizontal, 8)
    }

    // MARK: Data

    private func loadTrackData() async {
        guard let v = pm.current else { return }
        if let url = v.thumbnail, let c = await ArtworkColorCache.shared.color(for: url) {
            withAnimation(.easeInOut(duration: 0.6)) { tint = c }
        }
    }

    private func loadLyrics() async {
        lyrics = nil
        guard let v = pm.current else { return }
        lyricsLoading = true
        let result = await LyricsService.shared.lyrics(for: v, duration: pm.duration)
        guard !Task.isCancelled else { return }
        lyrics = result
        lyricsLoading = false
    }
}

// MARK: - Scrubber pieces

private struct SlimTrack: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25)).frame(height: 4)
                Capsule().fill(Color.white).frame(width: geo.size.width * progress, height: 4)
                Circle().fill(Color.white).frame(width: 12, height: 12)
                    .offset(x: min(max(geo.size.width * progress - 6, 0), geo.size.width - 12))
            }
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Lyrics

struct LyricsView: View {
    let lyrics: LyricsResult?
    let loading: Bool

    @ObservedObject private var pm = PlayerManager.shared

    var body: some View {
        if loading {
            ProgressView().tint(Color.white).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let lyrics, !lyrics.synced.isEmpty {
            synced(lyrics.synced)
        } else if let plain = lyrics?.plain, !plain.isEmpty {
            ScrollView {
                Text(plain)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 24)
            }
        } else {
            Text("Không tìm thấy lời bài hát")
                .foregroundStyle(Color.white.opacity(0.6))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func currentIndex(_ lines: [LyricLine]) -> Int {
        let t = pm.currentTime + 0.3
        return lines.lastIndex { $0.time <= t } ?? -1
    }

    private func synced(_ lines: [LyricLine]) -> some View {
        let idx = currentIndex(lines)
        return ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.system(size: i == idx ? 28 : 22, weight: .bold))
                            .foregroundStyle(i == idx ? Color.white : Color.white.opacity(0.32))
                            .blur(radius: i == idx ? 0 : 0.4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { pm.seek(to: line.time) }
                            .id(i)
                    }
                }
                .padding(.vertical, 80)
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: idx)
            }
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.08),
                        .init(color: .black, location: 0.92),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .onChange(of: idx) { newValue in
                guard newValue >= 0 else { return }
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }
}

// MARK: - Queue

private struct QueueSheet: View {
    @ObservedObject private var pm = PlayerManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let c = pm.current {
                    Section("Đang phát") { row(c) }
                }
                Section("Tiếp theo trong hàng đợi") {
                    if pm.queue.isEmpty {
                        Text("Hàng đợi trống").foregroundStyle(.secondary)
                    }
                    ForEach(pm.queue) { v in row(v) }
                        .onMove { pm.queue.move(fromOffsets: $0, toOffset: $1) }
                        .onDelete { pm.queue.remove(atOffsets: $0) }
                }
                if !pm.related.isEmpty {
                    Section("Radio – phát tiếp") {
                        ForEach(pm.related) { v in
                            Button { pm.play(v) } label: { row(v) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Hàng đợi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { EditButton() }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Xong") { dismiss() }
                }
            }
        }
    }

    private func row(_ v: Video) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: v.thumbnail) { $0.resizable().scaledToFill() } placeholder: {
                Color.gray.opacity(0.25)
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(v.title).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(v.channelTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}
