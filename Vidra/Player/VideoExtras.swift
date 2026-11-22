import AVFoundation
import MediaPlayer
import SwiftUI

// MARK: - Chapters

struct Chapter: Identifiable {
    let start: Double
    let title: String
    var id: Double { start }

    /// Chapters come from timestamp lines in the description (same rule YouTube uses:
    /// first at 0:00, at least three, ascending).
    static func parse(_ description: String) -> [Chapter] {
        guard let re = try? NSRegularExpression(
            pattern: #"^\s*[\[(]?((?:\d{1,2}:)?\d{1,2}:\d{2})[\])]?\s*[-–—:|]?\s*(.+?)\s*$"#,
            options: .anchorsMatchLines
        ) else { return [] }
        let ns = description as NSString
        var out: [Chapter] = []
        for m in re.matches(in: description, range: NSRange(location: 0, length: ns.length)) {
            guard let t = Fmt.seconds(ns.substring(with: m.range(at: 1))) else { continue }
            out.append(Chapter(start: t, title: ns.substring(with: m.range(at: 2))))
        }
        let ascending = zip(out, out.dropFirst()).allSatisfy { $0.start < $1.start }
        guard out.count >= 3, out.first?.start == 0, ascending else { return [] }
        return out
    }

    static func at(_ time: Double, in chapters: [Chapter]) -> Chapter? {
        chapters.last { $0.start <= time }
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
              let c = Int(f[3]), let r = Int(f[4]), c > 0, r > 0 else { return nil }
        var url = parts[0]
            .replacingOccurrences(of: "$L", with: String(level))
            .replacingOccurrences(of: "$N", with: f[6])
        url += (url.contains("?") ? "&" : "?") + "sigh=" + f[7]
        template = url
        width = w
        height = h
        count = n
        cols = c
        rows = r
        interval = (Double(f[5]) ?? 0) / 1000
    }

    func frame(at time: Double, duration: Double) -> (url: URL, col: Int, row: Int)? {
        let per = interval > 0 ? interval : (count > 0 ? duration / Double(count) : 0)
        guard per > 0 else { return nil }
        let index = min(Int(time / per), max(count - 1, 0))
        let perPage = cols * rows
        let within = index % perPage
        guard let url = URL(string: template.replacingOccurrences(of: "$M", with: String(index / perPage))) else { return nil }
        return (url, within % cols, within / cols)
    }
}

struct StoryboardThumb: View {
    let board: Storyboard
    let time: Double
    let duration: Double

    var body: some View {
        if let f = board.frame(at: time, duration: duration) {
            let w = CGFloat(board.width), h = CGFloat(board.height)
            // Sprite sheet at native size, shifted so the wanted cell sits in the clip window.
            AsyncImage(url: f.url) { img in
                img.offset(x: -w * CGFloat(f.col), y: -h * CGFloat(f.row))
            } placeholder: {
                Color.black
            }
            .frame(width: w, height: h, alignment: .topLeading)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white, lineWidth: 1.5))
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

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

@MainActor
enum SystemVolume {
    static weak var view: MPVolumeView?

    static var value: Float { AVAudioSession.sharedInstance().outputVolume }

    static func set(_ value: Float) {
        guard let slider = view?.subviews.compactMap({ $0 as? UISlider }).first else { return }
        slider.value = max(0, min(1, value))
    }
}

struct GestureHUD: Equatable {
    let icon: String
    let value: Float
}
