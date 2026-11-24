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
            pip.delegate = context.coordinator
            context.coordinator.pip = pip
            PlayerManager.shared.pipController = pip
        }
        context.coordinator.view = view
        context.coordinator.observeLifecycle()
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
        if uiView.playerLayer.videoGravity != gravity {
            uiView.playerLayer.videoGravity = gravity
        }
    }

    final class Coordinator: NSObject, AVPictureInPictureControllerDelegate {
        var pip: AVPictureInPictureController?
        weak var view: PlayerUIView?
        private var tokens: [NSObjectProtocol] = []

        func observeLifecycle() {
            let nc = NotificationCenter.default
            tokens.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.enteredBackground() }
            })
            tokens.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.view?.playerLayer.player = PlayerManager.shared.player }
            })
        }

        /// Detaching the layer is Apple's documented way to keep audio going in background (QA1668).
        @MainActor private func enteredBackground() {
            guard let view, !(pip?.isPictureInPictureActive ?? false) else { return }
            view.playerLayer.player = nil
        }

        func pictureInPictureController(_ controller: AVPictureInPictureController,
                                        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
            Task { @MainActor in PlayerManager.shared.showWatch = true }
            completionHandler(true)
        }

        deinit {
            tokens.forEach { NotificationCenter.default.removeObserver($0) }
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

    var body: some View {
        ZStack {
            Color.black
            VideoSurface(player: pm.player)
            if pm.showsArtwork, let v = pm.current {
                AsyncImage(url: v.thumbnail) { $0.resizable().scaledToFit() } placeholder: { Color.black }
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
        }
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
                        .onChanged { v in adjust(v, isLeft: isLeft, height: g.size.height) }
                        .onEnded { _ in
                            dragStart = nil
                            hideHUD()
                        }
                )
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
                    Button { pm.togglePiP() } label: { Image(systemName: "pip.enter") }
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

                if let s = scrub, let board = pm.storyboard {
                    StoryboardThumb(board: board, time: s, duration: pm.duration)
                }
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
                        Slider(
                            value: Binding(get: { scrub ?? pm.currentTime }, set: { scrub = $0 }),
                            in: 0...max(pm.duration, 1),
                            onEditingChanged: { editing in
                                if editing {
                                    hideTask?.cancel()
                                } else {
                                    if let s = scrub { pm.seek(to: s) }
                                    scrub = nil
                                    scheduleHide()
                                }
                            }
                        )
                        .tint(.red)
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
