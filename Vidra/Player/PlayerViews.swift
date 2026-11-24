import AVKit
import SwiftUI

final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspect

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.backgroundColor = .black
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
        if AVPictureInPictureController.isPictureInPictureSupported(),
           let pip = AVPictureInPictureController(playerLayer: view.playerLayer) {
            pip.canStartPictureInPictureAutomaticallyFromInline = Pref.autoPiP
            pip.requiresLinearPlayback = false
            pip.delegate = context.coordinator
            context.coordinator.pip = pip
            PlayerManager.shared.pipController = pip
        }
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
        if uiView.playerLayer.videoGravity != gravity {
            uiView.playerLayer.videoGravity = gravity
        }
        if let pip = context.coordinator.pip {
            pip.canStartPictureInPictureAutomaticallyFromInline = Pref.autoPiP
            pip.requiresLinearPlayback = false
            PlayerManager.shared.pipController = pip
        } else if AVPictureInPictureController.isPictureInPictureSupported(),
                  let newPip = AVPictureInPictureController(playerLayer: uiView.playerLayer) {
            newPip.canStartPictureInPictureAutomaticallyFromInline = Pref.autoPiP
            newPip.requiresLinearPlayback = false
            newPip.delegate = context.coordinator
            context.coordinator.pip = newPip
            PlayerManager.shared.pipController = newPip
        }
    }

    final class Coordinator: NSObject, AVPictureInPictureControllerDelegate {
        var pip: AVPictureInPictureController?
        weak var view: PlayerUIView?

        func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
            Task { @MainActor in
                PlayerManager.shared.isPiPActive = true
            }
        }

        func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
            Task { @MainActor in
                PlayerManager.shared.isPiPActive = true
            }
        }

        func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
            Task { @MainActor in
                PlayerManager.shared.isPiPActive = false
            }
        }

        func pictureInPictureControllerWillStopPictureInPicture(_ controller: AVPictureInPictureController) {
            Task { @MainActor in
                PlayerManager.shared.isPiPActive = false
            }
        }

        func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
            Task { @MainActor in
                PlayerManager.shared.isPiPActive = false
            }
        }

        func pictureInPictureController(_ controller: AVPictureInPictureController,
                                        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
            Task { @MainActor in
                PlayerManager.shared.showWatch = true
                completionHandler(true)
            }
        }

        // MARK: - 10-Second Skip & Play/Pause Controls

        func pictureInPictureController(_ controller: AVPictureInPictureController,
                                        skipByInterval skipInterval: CMTime,
                                        completion completionHandler: @escaping () -> Void) {
            let seconds = CMTimeGetSeconds(skipInterval)
            Task { @MainActor in
                PlayerManager.shared.seek(by: seconds)
                completionHandler()
            }
        }

        func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
            Task { @MainActor in
                if playing {
                    PlayerManager.shared.resume()
                } else {
                    PlayerManager.shared.pause()
                }
            }
        }

        func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
            MainActor.assumeIsolated {
                let dur = PlayerManager.shared.duration
                guard dur > 0 else { return CMTimeRange(start: .zero, duration: .indefinite) }
                return CMTimeRange(start: .zero, duration: CMTime(seconds: dur, preferredTimescale: 600))
            }
        }

        func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
            MainActor.assumeIsolated {
                !PlayerManager.shared.isPlaying
            }
        }
    }
}

struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = .systemBlue
        v.prioritizesVideoDevices = true
        return v
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

struct PlayerArea: View {
    var onClose: () -> Void

    @ObservedObject private var pm = PlayerManager.shared
    @AppStorage(Pref.maxHeightKey) private var maxHeight = 1080
    @Environment(\.verticalSizeClass) private var vsc
    @State private var controlsVisible = true
    @State private var scrub: Double?
    @State private var hideTask: Task<Void, Never>?
    @State private var hud: GestureHUD?
    @State private var hudTask: Task<Void, Never>?
    @State private var dragStart: Float?
    @State private var flash: String?

    // Gestures state: Pinch-to-zoom, interactive swipe-down to minimize, and horizontal swipe-seek
    @State private var videoGravity: AVLayerVideoGravity = .resizeAspect
    @State private var dragOffsetY: CGFloat = 0
    @State private var hasTriggeredHorizontalSwipe = false

    var body: some View {
        ZStack {
            Color.black
            VideoSurface(player: pm.player, gravity: videoGravity)
            if pm.showsArtwork, let v = pm.current {
                CachedAsyncImage(url: v.thumbnail, targetSize: CGSize(width: 480, height: 270)) { $0.resizable().scaledToFit() } placeholder: { Color.black }
                    .overlay(alignment: .topLeading) {
                        Label("Âm thanh", systemImage: "headphones")
                            .font(.caption)
                            .padding(6)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(8)
                            .padding(.top, 36)
                    }
                    .allowsHitTesting(false)
            }
            SystemVolumeView().frame(width: 1, height: 1).allowsHitTesting(false)
            HStack(spacing: 0) {
                tapZone(delta: -10, isLeft: true)
                tapZone(delta: 10, isLeft: false)
            }
            if controlsVisible { controls.transition(.opacity) }
            gestureFeedback
            if pm.isLoading && pm.errorText == nil {
                ProgressView().tint(.white).scaleEffect(1.4).allowsHitTesting(false)
            }
            if let err = pm.errorText { errorView(err) }
            if let cue = pm.activeCueText, !cue.isEmpty {
                Text(cue)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 6))
                    .padding(.horizontal, 16)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, controlsVisible ? 60 : 20)
                    .allowsHitTesting(false)
            }
            if let toast = pm.toast {
                Text(toast)
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 52)
                    .allowsHitTesting(false)
            }
            if !controlsVisible && pm.duration > 0 && pm.info?.isLive != true {
                GeometryReader { g in
                    let prog = min(max(pm.currentTime / max(pm.duration, 1), 0), 1)
                    Rectangle()
                        .fill(Color.red)
                        .frame(width: g.size.width * CGFloat(prog), height: 2)
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)
            }
        }
        .offset(y: vsc != .compact ? dragOffsetY : 0)
        .scaleEffect(vsc != .compact ? max(0.85, 1.0 - dragOffsetY / 1200) : 1.0)
        .simultaneousGesture(
            // Cử chỉ chụm 2 ngón tay phóng to/thu nhỏ (Pinch to Zoom to Fill / Original 16:9)
            MagnificationGesture()
                .onEnded { scale in
                    if scale > 1.12 && videoGravity != .resizeAspectFill {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            videoGravity = .resizeAspectFill
                        }
                        #if canImport(UIKit)
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        #endif
                        showFlash("Thu phóng vừa màn hình (Fill)")
                    } else if scale < 0.90 && videoGravity != .resizeAspect {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            videoGravity = .resizeAspect
                        }
                        #if canImport(UIKit)
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        #endif
                        showFlash("Tỷ lệ chuẩn 16:9 (Fit)")
                    }
                }
        )
        .foregroundStyle(.white)
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
        .onAppear { scheduleHide() }
        .onChange(of: maxHeight) { _ in pm.qualityChanged() }
    }

    private func tapZone(delta: Double, isLeft: Bool) -> some View {
        GeometryReader { g in
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    pm.seek(by: delta)
                    showFlash(delta > 0 ? "+\(Int(delta))s" : "\(Int(delta))s")
                }
                .onTapGesture {
                    controlsVisible.toggle()
                    if controlsVisible { scheduleHide() }
                }
                .onLongPressGesture(minimumDuration: 0.4, perform: {
                    pm.setBoost(true)
                }, onPressingChanged: { pressing in
                    if !pressing { pm.setBoost(false) }
                })
                .simultaneousGesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { v in handleDrag(v, isLeft: isLeft, height: g.size.height) }
                        .onEnded { v in handleDragEnd(v, isLeft: isLeft, height: g.size.height) }
                )
        }
    }

    /// Xử lý cử chỉ vuốt đa hướng:
    /// - Vuốt xuống ở chế độ dọc: Thu nhỏ video thành Mini-player
    /// - Vuốt ngang: Tua nhanh 10 giây (+10s / -10s)
    /// - Vuốt dọc ở chế độ xoay ngang: Điều chỉnh độ sáng (nửa trái) / Âm lượng (nửa phải)
    private func handleDrag(_ v: DragGesture.Value, isLeft: Bool, height: CGFloat) {
        let dx = v.translation.width
        let dy = v.translation.height

        // 1. Chế độ xoay ngang (Landscape compact): Vuốt dọc chỉnh độ sáng / âm lượng
        if vsc == .compact && abs(dy) > abs(dx) {
            adjust(v, isLeft: isLeft, height: height)
            return
        }

        // 2. Chế độ dọc: Vuốt dọc xuống để thu nhỏ thành mini-player
        if vsc != .compact && dy > 0 && dy > abs(dx) * 1.2 {
            dragOffsetY = dy
            return
        }

        // 3. Vuốt ngang để tua nhanh 10s (+10s hoặc -10s)
        if abs(dx) > 50 && abs(dx) > abs(dy) * 1.4 && !hasTriggeredHorizontalSwipe {
            hasTriggeredHorizontalSwipe = true
            let seekDelta: Double = dx > 0 ? 10 : -10
            pm.seek(by: seekDelta)
            #if canImport(UIKit)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            #endif
            showFlash(dx > 0 ? "+10s ⏩" : "-10s ⏪")
        }
    }

    private func handleDragEnd(_ v: DragGesture.Value, isLeft: Bool, height: CGFloat) {
        dragStart = nil
        hideHUD()
        hasTriggeredHorizontalSwipe = false

        // Kiểm tra ngưỡng vuốt xuống để thu nhỏ player
        if vsc != .compact {
            if dragOffsetY > 70 || v.predictedEndTranslation.height > 200 {
                #if canImport(UIKit)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                #endif
                onClose()
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    dragOffsetY = 0
                }
            }
        }
    }

    /// Full-screen only (in portrait a vertical drag belongs to the sheet's swipe-to-minimize):
    /// left half = brightness, right half = volume.
    private func adjust(_ v: DragGesture.Value, isLeft: Bool, height: CGFloat) {
        guard vsc == .compact, abs(v.translation.height) > abs(v.translation.width) else { return }
        let start = dragStart ?? (isLeft ? Float(UIScreen.main.brightness) : SystemVolume.value)
        dragStart = start
        let value = max(0, min(1, start - Float(v.translation.height / max(height * 0.8, 1))))
        if isLeft {
            UIScreen.main.brightness = CGFloat(value)
        } else {
            SystemVolume.set(value)
        }
        hudTask?.cancel()
        hud = GestureHUD(icon: isLeft ? "sun.max.fill" : (value == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill"), value: value)
    }

    private func hideHUD() {
        hudTask?.cancel()
        hudTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if !Task.isCancelled { hud = nil }
        }
    }

    private func showFlash(_ text: String) {
        flash = text
        Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            if flash == text { flash = nil }
        }
    }

    @ViewBuilder
    private var gestureFeedback: some View {
        if let hud {
            HStack(spacing: 10) {
                Image(systemName: hud.icon)
                ProgressView(value: Double(hud.value)).tint(.white).frame(width: 110)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .allowsHitTesting(false)
        }
        if let flash {
            Text(flash)
                .font(.headline)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .allowsHitTesting(false)
        }
        if pm.boosting {
            Label("2x", systemImage: "forward.fill")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 14)
                .allowsHitTesting(false)
        }
    }

    private var controls: some View {
        ZStack {
            Color.black.opacity(0.4).allowsHitTesting(false)
            VStack {
                HStack(spacing: 20) {
                    Button(action: onClose) { Image(systemName: "chevron.down") }
                    Spacer()
                    RoutePicker().frame(width: 28, height: 28)
                    if AVPictureInPictureController.isPictureInPictureSupported() {
                        Button { pm.togglePiP() } label: {
                            Image(systemName: pm.isPiPActive ? "pip.exit" : "pip.enter")
                        }
                    }
                    settingsMenu
                }
                .font(.title3)
                .padding(.horizontal)
                .padding(.top, 10)

                Spacer()

                HStack(spacing: 34) {
                    Button { pm.previous() } label: { Image(systemName: "backward.end.fill").font(.title3) }
                    Button { pm.seek(by: -10) } label: { Image(systemName: "gobackward.10").font(.title2) }
                    Button { pm.togglePlay(); scheduleHide() } label: {
                        Image(systemName: pm.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 42))
                    }
                    Button { pm.seek(by: 10) } label: { Image(systemName: "goforward.10").font(.title2) }
                    Button { pm.next() } label: { Image(systemName: "forward.end.fill").font(.title3) }
                }

                Spacer()

                if let chapter = Chapter.at(scrub ?? pm.currentTime, in: pm.chapters) {
                    Text(chapter.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                }

                HStack(spacing: 8) {
                    if pm.info?.isLive == true {
                        Circle().fill(.red).frame(width: 8, height: 8)
                        Text("TRỰC TIẾP")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.red)
                        Spacer()
                        Button { toggleOrientation() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    } else {
                        Text(Fmt.time(scrub ?? pm.currentTime))
                        YouTubeInteractiveScrubber(
                            scrub: $scrub,
                            currentTime: pm.currentTime,
                            duration: pm.duration,
                            chapters: pm.chapters,
                            storyboard: pm.storyboard,
                            segments: pm.segments,
                            onSeek: { s in pm.seek(to: s) },
                            onScrubStart: { hideTask?.cancel() },
                            onScrubEnd: { scheduleHide() }
                        )
                        Text(Fmt.time(pm.duration))
                        Button { toggleOrientation() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    }
                }
                .font(.caption.monospacedDigit())
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
        }
    }

    private var settingsMenu: some View {
        Menu {
            Picker(selection: Binding(get: { pm.rate }, set: { pm.setRate($0) })) {
                ForEach([0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3] as [Float], id: \.self) {
                    Text(Fmt.rate(Double($0))).tag($0)
                }
            } label: {
                Label("Tốc độ: \(Fmt.rate(Double(pm.rate)))", systemImage: "speedometer")
            }
            .pickerStyle(.menu)

            Picker(selection: $maxHeight) {
                Text("Tự động (Cao nhất)").tag(0)
                Text("4K (2160p)").tag(2160)
                Text("2K (1440p)").tag(1440)
                Text("1080p (FHD)").tag(1080)
                Text("720p (HD)").tag(720)
                Text("480p (SD)").tag(480)
                Text("360p").tag(360)
            } label: {
                Label(qualityLabel(maxHeight), systemImage: "slider.horizontal.3")
            }
            .pickerStyle(.menu)

            Toggle(isOn: Binding(get: { pm.audioOnly }, set: { _ in pm.toggleAudioOnly() })) {
                Label("Chỉ âm thanh", systemImage: "headphones")
            }
            Toggle(isOn: $pm.loop) { Label("Lặp lại", systemImage: "repeat.1") }
            if !pm.captionTracks.isEmpty {
                Menu {
                    Button {
                        pm.selectCaption(nil)
                    } label: {
                        if pm.selectedCaption == nil {
                            Label("Tắt", systemImage: "checkmark")
                        } else {
                            Text("Tắt")
                        }
                    }
                    ForEach(pm.captionTracks) { track in
                        Button {
                            pm.selectCaption(track)
                        } label: {
                            if pm.selectedCaption?.id == track.id {
                                Label(track.name.isEmpty ? track.languageCode : track.name, systemImage: "checkmark")
                            } else {
                                Text(track.name.isEmpty ? track.languageCode : track.name)
                            }
                        }
                    }
                } label: {
                    Label(pm.selectedCaption != nil ? "Phụ đề: \(pm.selectedCaption?.name ?? "Bật")" : "Phụ đề", systemImage: "captions.bubble")
                }
            }
            SleepMenu()
        } label: {
            Image(systemName: "gearshape")
        }
    }

    private func qualityLabel(_ h: Int) -> String {
        switch h {
        case 0: return "Chất lượng: Tự động"
        case 2160: return "Chất lượng: 4K (2160p)"
        case 1440: return "Chất lượng: 2K (1440p)"
        case 1080: return "Chất lượng: 1080p"
        case 720: return "Chất lượng: 720p"
        case 480: return "Chất lượng: 480p"
        case 360: return "Chất lượng: 360p"
        default: return "Chất lượng: \(h)p"
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.title)
            Text(message).font(.footnote).multilineTextAlignment(.center)
            Button("Thử lại") { pm.retry() }.buttonStyle(.bordered).tint(.white)
        }
        .padding()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled, pm.isPlaying, scrub == nil else { return }
            controlsVisible = false
        }
    }

    private func toggleOrientation() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let mask: UIInterfaceOrientationMask = scene.interfaceOrientation.isLandscape ? .portrait : .landscapeRight
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }
}

struct SleepMenu: View {
    @ObservedObject private var pm = PlayerManager.shared

    var body: some View {
        Menu {
            ForEach([5, 10, 15, 30, 45, 60, 90], id: \.self) { m in
                Button("\(m) phút") { pm.setSleep(m) }
            }
            Button("Hết video này") { pm.stopAfterCurrent = true }
            if pm.sleepAt != nil || pm.stopAfterCurrent {
                Button("Tắt hẹn giờ", role: .destructive) {
                    pm.setSleep(nil)
                    pm.stopAfterCurrent = false
                }
            }
        } label: {
            Label(title, systemImage: "moon.zzz")
        }
    }

    private var title: String {
        if let d = pm.sleepAt { return "Tắt lúc \(d.formatted(date: .omitted, time: .shortened))" }
        return pm.stopAfterCurrent ? "Dừng sau video này" : "Hẹn giờ tắt"
    }
}

// MARK: - YouTube Interactive Scrubber

struct YouTubeInteractiveScrubber: View {
    @Binding var scrub: Double?
    let currentTime: Double
    let duration: Double
    var chapters: [Chapter] = []
    var storyboard: Storyboard? = nil
    var segments: [SponsorSegment] = []
    var onSeek: (Double) -> Void
    var onScrubStart: () -> Void
    var onScrubEnd: () -> Void

    @State private var isDragging = false
    @State private var lastChapterIndex: Int? = nil

    var body: some View {
        let total = max(duration, 1)
        let effectiveTime = scrub ?? currentTime
        let progress = min(max(effectiveTime / total, 0), 1)

        GeometryReader { geo in
            let width = geo.size.width
            let trackHeight: CGFloat = isDragging ? 5 : 3
            let thumbRadius: CGFloat = isDragging ? 7 : 5

            ZStack(alignment: .leading) {
                // Background track
                Capsule()
                    .fill(Color.white.opacity(0.3))
                    .frame(height: trackHeight)

                // Active red track
                Capsule()
                    .fill(Color.red)
                    .frame(width: max(0, width * CGFloat(progress)), height: trackHeight)

                // SponsorBlock highlighted segments on track
                ForEach(segments.indices, id: \.self) { idx in
                    let seg = segments[idx]
                    if seg.end > seg.start && seg.start < total {
                        let segStart = max(0, seg.start / total)
                        let segEnd = min(1.0, seg.end / total)
                        let segWidth = max(2, width * CGFloat(segEnd - segStart))
                        Capsule()
                            .fill(Color.green.opacity(0.85))
                            .frame(width: segWidth, height: trackHeight)
                            .offset(x: width * CGFloat(segStart))
                    }
                }

                // Chapter tick notches along the track
                ForEach(chapters.indices, id: \.self) { idx in
                    let ch = chapters[idx]
                    if ch.start > 0 && ch.start < total {
                        let chFrac = ch.start / total
                        Rectangle()
                            .fill(Color.black.opacity(0.85))
                            .frame(width: 2, height: trackHeight + 3)
                            .offset(x: max(0, min(width - 2, width * CGFloat(chFrac) - 1)))
                    }
                }

                // Red thumb knob with glow
                Circle()
                    .fill(Color.red)
                    .frame(width: thumbRadius * 2, height: thumbRadius * 2)
                    .shadow(color: Color.red.opacity(0.6), radius: isDragging ? 4 : 2)
                    .offset(x: min(max(0, width * CGFloat(progress) - thumbRadius), width - thumbRadius * 2))
                    .scaleEffect(isDragging ? 1.25 : 1.0)
                    .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isDragging)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .overlay(alignment: .top) {
                if isDragging || scrub != nil {
                    floatingPreview(width: width, progress: progress, effectiveTime: effectiveTime, total: total)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !isDragging {
                            isDragging = true
                            onScrubStart()
                            #if canImport(UIKit)
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            #endif
                        }
                        let frac = min(max(g.location.x / max(width, 1), 0), 1)
                        let target = frac * total
                        scrub = target

                        // Haptic feedback when crossing chapter boundaries
                        let currentIdx = chapters.lastIndex(where: { $0.start <= target })
                        if currentIdx != lastChapterIndex {
                            if lastChapterIndex != nil {
                                #if canImport(UIKit)
                                UISelectionFeedbackGenerator().selectionChanged()
                                #endif
                            }
                            lastChapterIndex = currentIdx
                        }
                    }
                    .onEnded { g in
                        isDragging = false
                        lastChapterIndex = nil
                        let frac = min(max(g.location.x / max(width, 1), 0), 1)
                        let target = frac * total
                        scrub = nil
                        onSeek(target)
                        onScrubEnd()
                    }
            )
        }
        .frame(height: 28)
    }

    @ViewBuilder
    private func floatingPreview(width: CGFloat, progress: Double, effectiveTime: Double, total: Double) -> some View {
        let thumbX = width * CGFloat(progress)
        let previewWidth: CGFloat = storyboard != nil ? CGFloat(storyboard!.width) : 130
        let clampedCenterX = min(max(previewWidth / 2 + 6, thumbX), width - previewWidth / 2 - 6)
        let currentChapter = Chapter.at(effectiveTime, in: chapters)
        let currentSponsor = segments.first(where: { effectiveTime >= $0.start && effectiveTime <= $0.end })

        VStack(spacing: 4) {
            if let sb = storyboard {
                StoryboardThumb(board: sb, time: effectiveTime, duration: total)
                    .shadow(color: Color.black.opacity(0.6), radius: 6, y: 3)
            }

            VStack(spacing: 2) {
                if let currentChapter {
                    Text(currentChapter.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                if let currentSponsor {
                    Text("🛡️ \(currentSponsor.label)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.green)
                        .lineLimit(1)
                }
                Text(Fmt.time(effectiveTime))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.8))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            TrianglePointer()
                .fill(Color.black.opacity(0.8))
                .frame(width: 10, height: 5)
        }
        .frame(width: previewWidth)
        .position(x: clampedCenterX, y: storyboard != nil ? -(CGFloat(storyboard!.height) / 2 + 28) : -26)
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
        .animation(.easeOut(duration: 0.15), value: effectiveTime)
    }
}

private struct TrianglePointer: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
