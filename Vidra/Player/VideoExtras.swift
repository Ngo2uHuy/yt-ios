import AVFoundation
import MediaPlayer
import SwiftUI

// MARK: - Chapters

struct Chapter: Identifiable {
    let start: Double
    let title: String
    var id: Double { start }

    private static let regex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^\s*[\[(]?((?:\d{1,2}:)?\d{1,2}:\d{2})[\])]?\s*[-–—:|]?\s*(.+?)\s*$"#,
        options: .anchorsMatchLines
    )

    /// Chapters come from timestamp lines in the description (same rule YouTube uses:
    /// first at 0:00, at least three ascending entries).
    static func parse(_ description: String) -> [Chapter] {
        guard let re = regex else { return [] }
        let ns = description as NSString
        var out: [Chapter] = []
        var started = false
        for m in re.matches(in: description, range: NSRange(location: 0, length: ns.length)) {
            guard let t = Fmt.seconds(ns.substring(with: m.range(at: 1))) else { continue }
            let rawTitle = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawTitle.isEmpty else { continue }
            if !started {
                if t == 0 {
                    started = true
                    out = [Chapter(start: t, title: rawTitle)]
                }
            } else if let prev = out.last {
                if t > prev.start {
                    out.append(Chapter(start: t, title: rawTitle))
                } else if out.count >= 3 {
                    // Ignore out-of-order footer timestamps once a valid chapter block was parsed.
                    break
                } else {
                    started = false
                    out.removeAll()
                }
            }
        }
        return out.count >= 3 ? out : []
    }

    static func at(_ time: Double, in chapters: [Chapter]) -> Chapter? {
        guard time.isFinite else { return nil }
        return chapters.last { $0.start <= time }
    }
}

// MARK: - Seek preview (storyboard sprites)

/// Parses `storyboards.playerStoryboardSpecRenderer.spec`:
/// `baseURL|w#h#count#cols#rows#intervalMs#name#sigh|…` — one segment per quality level.
struct Storyboard {
    let template: String
    let width: Int
    let height: Int
    let count: Int
    let cols: Int
    let rows: Int
    let interval: Double

    init?(spec: String) {
        let parts = spec.split(separator: "|").map(String.init)
        guard parts.count >= 2 else { return nil }
        let level = parts.count - 2 // highest-resolution level
        let f = parts[parts.count - 1].split(separator: "#", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 8, let w = Int(f[0]), let h = Int(f[1]), let n = Int(f[2]),
              let c = Int(f[3]), let r = Int(f[4]), w > 0, h > 0, n > 0, c > 0, r > 0 else { return nil }
        var url = parts[0]
            .replacingOccurrences(of: "$L", with: String(level))
            .replacingOccurrences(of: "$N", with: f[6])
        if !f[7].isEmpty {
            let encodedSigh = f[7].addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? f[7]
            url += (url.contains("?") ? "&" : "?") + "sigh=" + encodedSigh
        }
        template = url
        width = w
        height = h
        count = n
        cols = c
        rows = r
        interval = max(0, (Double(f[5]) ?? 0) / 1000)
    }

    func frame(at time: Double, duration: Double) -> (url: URL, col: Int, row: Int)? {
        guard time.isFinite else { return nil }
        let safeDur = (duration.isFinite && duration > 0) ? duration : 0
        let per = interval > 0 ? interval : (count > 0 ? safeDur / Double(count) : 0)
        guard per.isFinite, per > 0 else { return nil }
        let safeTime = max(0, time)
        let rawIndex = safeTime / per
        guard rawIndex.isFinite else { return nil }
        let index = max(0, min(Int(rawIndex), max(count - 1, 0)))
        let perPage = cols * rows
        guard perPage > 0 else { return nil }
        let within = index % perPage
        guard let url = URL(string: template.replacingOccurrences(of: "$M", with: String(index / perPage))) else { return nil }
        return (url, within % cols, within / cols)
    }
}

struct StoryboardThumb: View {
    let board: Storyboard
    let time: Double
    let duration: Double

    @State private var loadedURL: URL?
    @State private var loadedImage: UIImage?

    var body: some View {
        let f = board.frame(at: time, duration: duration)
        let w = CGFloat(board.width), h = CGFloat(board.height)
        if let f {
            ZStack(alignment: .topLeading) {
                Color.black
                if loadedURL == f.url, let img = loadedImage {
                    Image(uiImage: img)
                        .offset(x: -w * CGFloat(f.col), y: -h * CGFloat(f.row))
                }
            }
            .frame(width: w, height: h, alignment: .topLeading)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white, lineWidth: 1.5))
            .task(id: f.url) {
                let sheetSize = CGSize(width: w * CGFloat(board.cols), height: h * CGFloat(board.rows))
                if let img = await ImageCache.shared.load(url: f.url, targetSize: sheetSize, scale: 1.0) {
                    loadedURL = f.url
                    loadedImage = img
                }
            }
        }
    }
}

// MARK: - System volume (swipe gesture)

/// iOS only exposes system volume through MPVolumeView's slider; having one in the
/// hierarchy also suppresses the system volume HUD while we show our own.
struct SystemVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let v = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        v.alpha = 0.01
        SystemVolume.view = v
        return v
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        if SystemVolume.view !== uiView { SystemVolume.view = uiView }
    }
}

@MainActor
enum SystemVolume {
    static weak var view: MPVolumeView?

    static var value: Float { AVAudioSession.sharedInstance().outputVolume }

    static func set(_ value: Float) {
        guard let v = view, let slider = findSlider(in: v) else { return }
        slider.value = max(0, min(1, value))
    }

    private static func findSlider(in root: UIView) -> UISlider? {
        for sub in root.subviews {
            if let slider = sub as? UISlider { return slider }
            if let found = findSlider(in: sub) { return found }
        }
        return nil
    }
}

struct GestureHUD: Equatable {
    let icon: String
    let value: Float
}
