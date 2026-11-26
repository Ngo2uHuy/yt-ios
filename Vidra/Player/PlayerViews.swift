import AVKit
import SwiftUI

final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspect
    var enablePiP: Bool = true

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.backgroundColor = .black
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
        context.coordinator.view = view
        configurePiP(on: view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
        if uiView.playerLayer.videoGravity != gravity {
            uiView.playerLayer.videoGravity = gravity
        }
        configurePiP(on: uiView, coordinator: context.coordinator)
    }

    static func dismantleUIView(_ uiView: PlayerUIView, coordinator: Coordinator) {
        if let pip = coordinator.pip {
            if PlayerManager.shared.pipController === pip {
                PlayerManager.shared.pipController = nil
            }
            coordinator.pip = nil
        }
        uiView.playerLayer.player = nil
    }

    private func configurePiP(on view: PlayerUIView, coordinator: Coordinator) {
        guard enablePiP, AVPictureInPictureController.isPictureInPictureSupported() else {
            if let existing = coordinator.pip {
                if PlayerManager.shared.pipController === existing {
                    PlayerManager.shared.pipController = nil
                }
                coordinator.pip = nil
            }
            return
        }
        let autoPiP = Pref.autoPiP
        if let pip = coordinator.pip {
            if pip.canStartPictureInPictureAutomaticallyFromInline != autoPiP {
                pip.canStartPictureInPictureAutomaticallyFromInline = autoPiP
            }
            if PlayerManager.shared.pipController !== pip {
                PlayerManager.shared.pipController = pip
            }
        } else if let pip = AVPictureInPictureController(playerLayer: view.playerLayer) {
            pip.canStartPictureInPictureAutomaticallyFromInline = autoPiP
            pip.requiresLinearPlayback = false
            pip.delegate = coordinator
            coordinator.pip = pip
            PlayerManager.shared.pipController = pip
        }
    }

    final class Coordinator: NSObject, AVPictureInPictureControllerDelegate {
        var pip: AVPictureInPictureController?
        weak var view: PlayerUIView?

        func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
            Task { @MainActor in PlayerManager.shared.isPiPActive = true }
        }

        func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
            Task { @MainActor in PlayerManager.shared.isPiPActive = true }
        }

        func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
            Task { @MainActor in PlayerManager.shared.isPiPActive = false }
        }

        func pictureInPictureControllerWillStopPictureInPicture(_ controller: AVPictureInPictureController) {
            Task { @MainActor in PlayerManager.shared.isPiPActive = false }
        }

        func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
            Task { @MainActor in PlayerManager.shared.isPiPActive = false }
        }

        func pictureInPictureController(_ controller: AVPictureInPictureController,
                                        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
            Task { @MainActor in
                PlayerManager.shared.showWatch = true
                try? await Task.sleep(nanoseconds: 100_000_000)
                completionHandler(true)
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

    private enum DragAxis { case none, horizontal, vertical }

    @ObservedObject private var pm = PlayerManager.shared
    @AppStorage(Pref.maxHeightKey) private var maxHeight = 1080
    @Environment(\.verticalSizeClass) private var vsc
    @State private var controlsVisible = true
    @State private var scrub: Double?
    @State private var hideTask: Task<Void, Never>?
    @State private var flashTask: Task<Void, Never>?
    @State private var hud: GestureHUD?
    @State private var hudTask: Task<Void, Never>?
    @State private var dragStart: Float?
    @State private var dragStartSideIsLeft: Bool?
    @State private var dragAxis: DragAxis = .none
    @State private var isDragging = false
    @State private var flash: String?

    @State private var videoGravity: AVLayerVideoGravity = .resizeAspect
    @State private var dragOffsetY: CGFloat = 0
    @State private var hasTriggeredHorizontalSwipe = false

    var body: some View {
        ZStack {
            Color.black
            VideoSurface(player: pm.player, gravity: videoGravity, enablePiP: !pm.showsArtwork)
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
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    GeometryReader { g in
                        let prog = min(max(pm.currentTime / max(pm.duration, 1), 0), 1)
                        Rectangle()
                            .fill(Color.red)
                            .frame(width: max(0, g.size.width * CGFloat(prog)), height: 2)
                    }
                    .frame(height: 2)
                }
                .allowsHitTesting(false)
            }
        }
        .offset(y: vsc != .compact ? dragOffsetY : 0)
        .scaleEffect(vsc != .compact ? max(0.85, 1.0 - dragOffsetY / 1200) : 1.0)
        .simultaneousGesture(
            MagnificationGesture()
                .onEnded { scale in
                    guard !isDragging else { return }
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
        .onDisappear { resetTransientState() }
        .onChange(of: pm.isPlaying) { playing in
            if playing && controlsVisible {
                scheduleHide()
            } else if !playing {
                hideTask?.cancel()
            }
        }
        .onChange(of: pm.current?.id) { _ in
            scrub = nil
            dragOffsetY = 0
            dragAxis = .none
            isDragging = false
            dragStart = nil
            dragStartSideIsLeft = nil
            hasTriggeredHorizontalSwipe = false
            flash = nil
            hud = nil
            controlsVisible = true
            scheduleHide()
        }
        .onChange(of: maxHeight) { _ in pm.qualityChanged() }
    }

    private func resetTransientState() {
        hideTask?.cancel()
        flashTask?.cancel()
        hudTask?.cancel()
        scrub = nil
        dragOffsetY = 0
        dragAxis = .none
        isDragging = false
        dragStart = nil
        dragStartSideIsLeft = nil
        hasTriggeredHorizontalSwipe = false
        pm.setBoost(false)
    }

    private var canSeekNow: Bool {
        pm.info?.isLive != true && pm.duration.isFinite && pm.duration > 0
    }

    private func tapZone(delta: Double, isLeft: Bool) -> some View {
        GeometryReader { g in
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    guard canSeekNow else { return }
                    pm.seek(by: delta)
                    showFlash(delta > 0 ? "+\(Int(delta))s" : "\(Int(delta))s")
                }
                .onTapGesture {
                    controlsVisible.toggle()
                    if controlsVisible { scheduleHide() } else { hideTask?.cancel() }
                }
                .onLongPressGesture(minimumDuration: 0.4, perform: {
                    guard !isDragging else { return }
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

    private func handleDrag(_ v: DragGesture.Value, isLeft: Bool, height: CGFloat) {
        isDragging = true
        let dx = v.translation.width
        let dy = v.translation.height

        if dragAxis == .none {
            if abs(dx) > 16 || abs(dy) > 16 {
                dragAxis = abs(dx) > abs(dy) * 1.2 ? .horizontal : .vertical
                dragStartSideIsLeft = isLeft
            } else {
                return
            }
        }

        if dragAxis == .vertical {
            if vsc == .compact {
                adjust(v, isLeft: dragStartSideIsLeft ?? isLeft, height: height)
            } else if dy > 0 {
                dragOffsetY = dy
            }
            return
        }

        if dragAxis == .horizontal && canSeekNow && abs(dx) > 50 && !hasTriggeredHorizontalSwipe {
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
        isDragging = false
        let axis = dragAxis
        dragAxis = .none
        dragStart = nil
        dragStartSideIsLeft = nil
        hideHUD()
        hasTriggeredHorizontalSwipe = false

        if axis == .vertical && vsc != .compact {
            if dragOffsetY > 70 || v.predictedEndTranslation.height > 200 {
                #if canImport(UIKit)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                #endif
                dragOffsetY = 0
                onClose()
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    dragOffsetY = 0
                }
            }
        } else if dragOffsetY != 0 {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                dragOffsetY = 0
            }
        }
    }

    private func adjust(_ v: DragGesture.Value, isLeft: Bool, height: CGFloat) {
        guard vsc == .compact else { return }
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
        flashTask?.cancel()
        flash = text
        flashTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            if !Task.isCancelled { flash = nil }
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
                    Button { pm.previous(); scheduleHide() } label: { Image(systemName: "backward.end.fill").font(.title3) }
                    Button { pm.seek(by: -10); scheduleHide() } label: { Image(systemName: "gobackward.10").font(.title2) }
                        .disabled(!canSeekNow)
                        .opacity(canSeekNow ? 1 : 0.4)
                    Button { pm.togglePlay(); scheduleHide() } label: {
                        Image(systemName: pm.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 42))
                    }
                    Button { pm.seek(by: 10); scheduleHide() } label: { Image(systemName: "goforward.10").font(.title2) }
                        .disabled(!canSeekNow)
                        .opacity(canSeekNow ? 1 : 0.4)
                    Button { pm.next(); scheduleHide() } label: { Image(systemName: "forward.end.fill").font(.title3) }
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
            Picker(selection: Binding(get: { pm.rate }, set: { pm.setRate($0); scheduleHide() })) {
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

            Toggle(isOn: Binding(get: { pm.audioOnly }, set: { _ in pm.toggleAudioOnly(); scheduleHide() })) {
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
        .simultaneousGesture(TapGesture().onEnded { hideTask?.cancel() })
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
            guard !Task.isCancelled, pm.isPlaying, scrub == nil, !isDragging else { return }
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

    private var canSeek: Bool {
        duration.isFinite && duration > 0
    }

    var body: some View {
        let total = canSeek ? duration : 0
        let effectiveTime = (canSeek ? (scrub ?? currentTime) : currentTime)
        let progress = total > 0 ? min(max(effectiveTime / total, 0), 1) : 0

        GeometryReader { geo in
            let width = geo.size.width
            let trackHeight: CGFloat = isDragging ? 5 : 3
            let thumbRadius: CGFloat = isDragging ? 7 : 5

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.3))
                    .frame(height: trackHeight)

                Capsule()
                    .fill(Color.red)
                    .frame(width: max(0, width * CGFloat(progress)), height: trackHeight)

                if total > 0 {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
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

                    ForEach(Array(chapters.enumerated()), id: \.offset) { _, ch in
                        if ch.start > 0 && ch.start < total {
                            let chFrac = ch.start / total
                            Rectangle()
                                .fill(Color.black.opacity(0.85))
                                .frame(width: 2, height: trackHeight + 3)
                                .offset(x: max(0, min(max(0, width - 2), width * CGFloat(chFrac) - 1)))
                        }
                    }
                }

                Circle()
                    .fill(Color.red)
                    .frame(width: thumbRadius * 2, height: thumbRadius * 2)
                    .shadow(color: Color.red.opacity(0.6), radius: isDragging ? 4 : 2)
                    .offset(x: min(max(0, width * CGFloat(progress) - thumbRadius), max(0, width - thumbRadius * 2)))
                    .scaleEffect(isDragging ? 1.25 : 1.0)
                    .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isDragging)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .overlay(alignment: .top) {
                if canSeek && (isDragging || scrub != nil) {
                    floatingPreview(width: width, progress: progress, effectiveTime: effectiveTime, total: total)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard canSeek, width > 0 else { return }
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
                        scrub = nil
                        if canSeek && width > 0 {
                            let frac = min(max(g.location.x / max(width, 1), 0), 1)
                            onSeek(frac * total)
                        }
                        onScrubEnd()
                    }
            )
        }
        .frame(height: 28)
        .onDisappear {
            if isDragging || scrub != nil {
                isDragging = false
                lastChapterIndex = nil
                scrub = nil
                onScrubEnd()
            }
        }
        .onChange(of: canSeek) { valid in
            if !valid {
                isDragging = false
                lastChapterIndex = nil
                scrub = nil
            }
        }
    }

    @ViewBuilder
    private func floatingPreview(width: CGFloat, progress: Double, effectiveTime: Double, total: Double) -> some View {
        let thumbX = width * CGFloat(progress)
        let previewWidth: CGFloat = storyboard != nil ? CGFloat(storyboard!.width) : 130
        let minX = min(width / 2, previewWidth / 2 + 6)
        let maxX = max(width / 2, width - previewWidth / 2 - 6)
        let clampedCenterX = min(max(minX, thumbX), maxX)
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
        .allowsHitTesting(false)
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
