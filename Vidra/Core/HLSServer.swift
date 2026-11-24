import Foundation
import Network

/// Lightweight in-memory loopback HLS server.
/// Apple's AVPlayer natively excels at playing fragmented MP4 (fMP4) via HLS with `#EXT-X-MAP` and `#EXT-X-BYTERANGE`.
/// Since YouTube only serves unthrottled streams via separate DASH video and audio tracks on iOS,
/// HLSServer serves dynamically constructed HL master and media playlists on 127.0.0.1, allowing AVPlayer
/// to play 1080p/720p video + audio in hardware with zero latency, full AirPlay, and PiP support.
final class HLSServer: @unchecked Sendable {
    static let shared = HLSServer()

    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private var routes: [String: (contentType: String, data: Data)] = [:]
    private var routeKeys: [String] = [] // LRU tracking
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "vidra.hls.server", qos: .userInitiated)

    init() {
        start()
    }

    func start() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredInterfaceType = .loopback
            let l = try NWListener(using: params, on: .any)
            l.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if let assignedPort = l.port?.rawValue {
                        self.lock.lock()
                        self.port = assignedPort
                        self.lock.unlock()
                    }
                default:
                    break
                }
            }
            l.newConnectionHandler = { [weak self] connection in
                self?.handle(connection: connection)
            }
            l.start(queue: queue)
            listener = l
        } catch {
            print("HLSServer failed to start: \(error)")
        }
    }

    /// Waits until the loopback server has bound an ephemeral port (with a 1.0s safety timeout to prevent deadlocks).
    func ensurePort() async -> UInt16 {
        for _ in 0..<20 {
            lock.lock()
            let p = port
            lock.unlock()
            if p > 0 { return p }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        lock.lock()
        let p = port
        lock.unlock()
        return p
    }

    /// Registers an in-memory route (e.g. `/hls/abc/master.m3u8`) and returns its local loopback URL.
    func register(path: String, contentType: String, data: Data) async -> URL? {
        let p = await ensurePort()
        guard p > 0 else { return nil }
        lock.lock()
        routes[path] = (contentType, data)
        let decoded = path.removingPercentEncoding ?? path
        if decoded != path { routes[decoded] = (contentType, data) }
        if let existing = routeKeys.firstIndex(of: path) {
            routeKeys.remove(at: existing)
        }
        routeKeys.append(path)
        // Keep at most 40 recent playlist paths in memory (~100 KB total)
        while routeKeys.count > 40 {
            let old = routeKeys.removeFirst()
            routes.removeValue(forKey: old)
            routes.removeValue(forKey: old.removingPercentEncoding ?? old)
        }
        lock.unlock()
        return URL(string: "http://127.0.0.1:\(p)\(path)")
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4096) { [weak self] data, _, _, _ in
            guard let self, let data, let req = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            // Parse HTTP request line, e.g. "GET /hls/xyz/master.m3u8 HTTP/1.1"
            let firstLine = req.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.components(separatedBy: " ")
            let isHead = parts.first == "HEAD"
            guard parts.count >= 2, parts[0] == "GET" || isHead else {
                self.send(status: 400, text: "Bad Request", connection: connection)
                return
            }
            let rawPath = parts[1].components(separatedBy: "?").first ?? parts[1]
            let decodedPath = rawPath.removingPercentEncoding ?? rawPath

            self.lock.lock()
            let matched = self.routes[rawPath] ?? self.routes[decodedPath]
            self.lock.unlock()

            guard let (contentType, body) = matched else {
                self.send(status: 404, text: "Not Found", connection: connection)
                return
            }

            var resp = "HTTP/1.1 200 OK\r\n"
            resp += "Content-Type: \(contentType)\r\n"
            resp += "Content-Length: \(body.count)\r\n"
            resp += "Cache-Control: no-cache, no-store, must-revalidate\r\n"
            resp += "Pragma: no-cache\r\n"
            resp += "Expires: 0\r\n"
            resp += "Connection: close\r\n"
            resp += "Access-Control-Allow-Origin: *\r\n\r\n"

            var responseData = resp.data(using: .utf8) ?? Data()
            if !isHead {
                responseData.append(body)
            }

            connection.send(content: responseData, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func send(status: Int, text: String, connection: NWConnection) {
        let msg = "HTTP/1.1 \(status) \(text)\r\nContent-Length: \(text.count)\r\nConnection: close\r\n\r\n\(text)"
        connection.send(content: msg.data(using: .utf8), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

// MARK: - SIDX Parser

struct SIDXSegment {
    let duration: Double
    let size: Int
    let offset: Int
}

enum SIDXParser {
    /// Parses the ISO Base Media File Format `sidx` (Segment Index) box from raw binary data.
    static func parse(data: Data, indexEnd: Int) -> [SIDXSegment]? {
        let sidxBytes: [UInt8] = [0x73, 0x69, 0x64, 0x78] // 'sidx'
        guard let sidxRange = data.range(of: Data(sidxBytes)), sidxRange.lowerBound >= 4 else { return nil }
        let base = sidxRange.lowerBound - 4
        guard data.count >= base + 12 else { return nil }

        let version = data[base + 8]
        var pos = base + 12

        func readU16() -> UInt16? {
            guard pos + 2 <= data.count else { return nil }
            defer { pos += 2 }
            return (UInt16(data[pos]) << 8) | UInt16(data[pos + 1])
        }
        func readU32() -> UInt32? {
            guard pos + 4 <= data.count else { return nil }
            defer { pos += 4 }
            return (UInt32(data[pos]) << 24) |
                   (UInt32(data[pos + 1]) << 16) |
                   (UInt32(data[pos + 2]) << 8) |
                   UInt32(data[pos + 3])
        }
        func readU64() -> UInt64? {
            guard let high = readU32(), let low = readU32() else { return nil }
            return (UInt64(high) << 32) | UInt64(low)
        }

        _ = readU32() // reference_id
        guard let timescale = readU32(), timescale > 0 else { return nil }
        if version == 0 {
            _ = readU32() // earliest_pts
            _ = readU32() // first_offset
        } else {
            _ = readU64() // earliest_pts
            _ = readU64() // first_offset
        }
        _ = readU16() // reserved
        guard let count = readU16(), count > 0 else { return nil }

        var currentOffset = indexEnd + 1
        var segments: [SIDXSegment] = []
        segments.reserveCapacity(Int(count))

        for _ in 0..<count {
            guard let d1 = readU32(), let d2 = readU32(), let _ = readU32() else { break }
            let size = Int(d1 & 0x7FFFFFFF)
            let dur = Double(d2) / Double(timescale)
            segments.append(SIDXSegment(duration: dur, size: size, offset: currentOffset))
            currentOffset += size
        }
        return segments.isEmpty ? nil : segments
    }
}

// MARK: - HLS Builder

enum HLSBuilder {
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 6
        return URLSession(configuration: cfg)
    }()

    private static let sidxLock = NSLock()
    private static var sidxCache: [String: [SIDXSegment]] = [:]
    private static var sidxKeys: [String] = []

    private static func getOrFetchSegments(id: String, trackType: String, url: URL, idx: (start: Int, end: Int)) async -> [SIDXSegment]? {
        let key = "\(id)_\(trackType)"
        sidxLock.lock()
        if let cached = sidxCache[key] {
            if let pos = sidxKeys.firstIndex(of: key) {
                sidxKeys.remove(at: pos)
                sidxKeys.append(key)
            }
            sidxLock.unlock()
            return cached
        }
        sidxLock.unlock()

        guard let bytes = await fetchRange(url, start: idx.start, end: idx.end),
              let segs = SIDXParser.parse(data: bytes, indexEnd: idx.end) else {
            return nil
        }

        sidxLock.lock()
        while sidxKeys.count >= 50 {
            let oldKey = sidxKeys.removeFirst()
            sidxCache.removeValue(forKey: oldKey)
        }
        sidxKeys.append(key)
        sidxCache[key] = segs
        sidxLock.unlock()
        return segs
    }

    /// Builds an audio-only HLS Playlist for YouTube DASH audio.
    /// YouTube returns HTTP 403 Forbidden for progressive requests on DASH formats;
    /// serving via HLS with explicit byte ranges ensures AVPlayer only sends Range requests (HTTP 206).
    static func buildAudio(id: String, audio: DirectFormat, startTimeSecs: Int? = nil) async -> URL? {
        guard let aInit = audio.initRange, let aIdx = audio.indexRange else { return nil }
        guard let aSegs = await getOrFetchSegments(id: id, trackType: "a", url: audio.url, idx: aIdx) else {
            return nil
        }

        let aPlaylist = makeMediaPlaylist(url: audio.url, initRange: aInit, segments: aSegs, startSec: startTimeSecs.map(Double.init))
        let tag = "\(id)_\(Int(Date().timeIntervalSince1970 * 1000))".replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "/", with: "_")
        let aPath = "/hls/\(tag)/audio.m3u8"

        guard let aData = aPlaylist.data(using: .utf8) else { return nil }
        return await HLSServer.shared.register(path: aPath, contentType: "application/vnd.apple.mpegurl", data: aData)
    }

    /// Builds a compliant Apple HLS Master Playlist for separate YouTube DASH video and audio tracks.
    static func buildMaster(id: String, video: DirectFormat, audio: DirectFormat, startTimeSecs: Int? = nil) async -> URL? {
        guard let vInit = video.initRange, let vIdx = video.indexRange,
              let aInit = audio.initRange, let aIdx = audio.indexRange else {
            return nil
        }

        let vKey = "v_\(video.height ?? 0)"
        async let vSegsRes = getOrFetchSegments(id: id, trackType: vKey, url: video.url, idx: vIdx)
        async let aSegsRes = getOrFetchSegments(id: id, trackType: "a", url: audio.url, idx: aIdx)

        guard let vSegs = await vSegsRes, let aSegs = await aSegsRes else {
            return nil
        }

        let startD = startTimeSecs.map(Double.init)
        let vPlaylist = makeMediaPlaylist(url: video.url, initRange: vInit, segments: vSegs, startSec: startD)
        let aPlaylist = makeMediaPlaylist(url: audio.url, initRange: aInit, segments: aSegs, startSec: startD)

        let tag = "\(id)_\(Int(Date().timeIntervalSince1970 * 1000))".replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "/", with: "_")
        let vPath = "/hls/\(tag)/video.m3u8"
        let aPath = "/hls/\(tag)/audio.m3u8"
        let mPath = "/hls/\(tag)/master.m3u8"

        guard let vData = vPlaylist.data(using: .utf8),
              let aData = aPlaylist.data(using: .utf8) else { return nil }

        _ = await HLSServer.shared.register(path: vPath, contentType: "application/vnd.apple.mpegurl", data: vData)
        _ = await HLSServer.shared.register(path: aPath, contentType: "application/vnd.apple.mpegurl", data: aData)

        let vCodec = extractCodec(from: video.mime) ?? "avc1.4d401f"
        let aCodec = extractCodec(from: audio.mime) ?? "mp4a.40.2"
        let width = video.width ?? (video.height.map { $0 * 16 / 9 } ?? 1280)
        let height = video.height ?? 720
        let bandwidth = max(video.bitrate + audio.bitrate, 800_000)

        var master = "#EXTM3U\n"
        master += "#EXT-X-VERSION:7\n"
        master += "#EXT-X-INDEPENDENT-SEGMENTS\n"
        if let s = startTimeSecs, s > 0 {
            master += String(format: "#EXT-X-START:TIME-OFFSET=%.3f,PRECISE=YES\n", Double(s))
        }
        master += "\n"
        master += "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"Main\",DEFAULT=YES,AUTOSELECT=YES,URI=\"audio.m3u8\"\n"
        master += "#EXT-X-STREAM-INF:BANDWIDTH=\(bandwidth),RESOLUTION=\(width)x\(height),CODECS=\"\(vCodec),\(aCodec)\",AUDIO=\"audio\"\n"
        master += "video.m3u8\n"

        guard let mData = master.data(using: .utf8) else { return nil }
        return await HLSServer.shared.register(path: mPath, contentType: "application/vnd.apple.mpegurl", data: mData)
    }

    private static func fetchRange(_ url: URL, start: Int, end: Int) async -> Data? {
        var req = URLRequest(url: url)
        req.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        req.setValue(YTClient.ios.userAgent, forHTTPHeaderField: "User-Agent")
        return try? await session.data(for: req).0
    }

    private static func makeMediaPlaylist(url: URL, initRange: (start: Int, end: Int), segments: [SIDXSegment], startSec: Double? = nil) -> String {
        let initLen = initRange.end - initRange.start + 1
        let maxDur = segments.map(\.duration).max() ?? 10
        let targetDur = Int(ceil(maxDur))
        let urlStr = url.absoluteString

        var lines: [String] = []
        lines.reserveCapacity(segments.count * 3 + 10)
        lines.append("#EXTM3U")
        lines.append("#EXT-X-VERSION:7")
        lines.append("#EXT-X-TARGETDURATION:\(targetDur)")
        lines.append("#EXT-X-MEDIA-SEQUENCE:0")
        lines.append("#EXT-X-PLAYLIST-TYPE:VOD")
        lines.append("#EXT-X-INDEPENDENT-SEGMENTS")
        if let s = startSec, s > 0 {
            lines.append(String(format: "#EXT-X-START:TIME-OFFSET=%.3f,PRECISE=YES", s))
        }
        lines.append("#EXT-X-MAP:URI=\"\(urlStr)\",BYTERANGE=\"\(initLen)@\(initRange.start)\"")

        for s in segments {
            lines.append(String(format: "#EXTINF:%.3f,", s.duration))
            lines.append("#EXT-X-BYTERANGE:\(s.size)@\(s.offset)")
            lines.append(urlStr)
        }
        lines.append("#EXT-X-ENDLIST\n")
        return lines.joined(separator: "\n")
    }

    private static func extractCodec(from mime: String) -> String? {
        guard let r = mime.range(of: "codecs=\"") else { return nil }
        let sub = mime[r.upperBound...]
        guard let end = sub.firstIndex(of: "\"") else { return nil }
        return String(sub[..<end])
    }
}
