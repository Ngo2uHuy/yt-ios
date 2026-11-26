import Foundation
import Network

/// Lightweight in-memory loopback HLS server & authenticated byte-range proxy.
/// Proxies `#EXT-X-MAP` and `#EXT-X-BYTERANGE` segment fetches through `127.0.0.1` so `AVPlayer`
/// receives consistent `YTClient` User-Agent headers, retry recovery, HTTP 206 compliance, and
/// fast cancellation on seek.
final class HLSServer: @unchecked Sendable {
    static let shared = HLSServer()

    struct ProxyTarget: Sendable {
        let url: URL
        let userAgent: String
        let totalSize: Int64?
    }

    private final class ConnectionSession: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<Void, Never>?
        private var cancelled = false

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func setTask(_ newTask: Task<Void, Never>?) {
            lock.lock()
            let prev = task
            task = cancelled ? nil : newTask
            let wasCancelled = cancelled
            lock.unlock()
            prev?.cancel()
            if wasCancelled { newTask?.cancel() }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let t = task
            task = nil
            lock.unlock()
            t?.cancel()
        }
    }

    private final class PortWaiter: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<UInt16, Never>?

        init(_ continuation: CheckedContinuation<UInt16, Never>) {
            self.continuation = continuation
        }

        func resolve(_ port: UInt16) {
            lock.lock()
            let cont = continuation
            continuation = nil
            lock.unlock()
            cont?.resume(returning: port)
        }
    }

    private var listener: NWListener?
    private var _port: UInt16 = 0
    private var portWaiters: [PortWaiter] = []
    private var nextTagSeq: UInt64 = 0
    private var nextProxySeq: UInt64 = 0
    private var restartScheduled = false

    typealias DynamicRouteHandler = @Sendable () -> (contentType: String, data: Data)?
    private var routes: [String: (contentType: String, data: Data)] = [:]
    private var dynamicRoutes: [String: DynamicRouteHandler] = [:]
    private var proxyTargets: [String: ProxyTarget] = [:]
    private var routeKeys: [String] = []
    private var dynamicRouteKeys: [String] = []
    private var proxyKeys: [String] = []

    private let lock = NSLock()
    private let acceptQueue = DispatchQueue(label: "vidra.hls.accept", qos: .userInitiated)
    private let connQueue = DispatchQueue(label: "vidra.hls.conn", qos: .userInitiated, attributes: .concurrent)

    private static let proxySession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 45
        cfg.httpMaximumConnectionsPerHost = 12
        cfg.httpShouldUsePipelining = true
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    var port: UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return _port
    }

    init() {
        start()
    }

    func ensureRunning() {
        lock.lock()
        let needsStart = listener == nil || _port == 0
        lock.unlock()
        if needsStart { start() }
    }

    func nextTag(prefix: String) -> String {
        let safe = prefix
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        lock.lock()
        nextTagSeq &+= 1
        let seq = nextTagSeq
        lock.unlock()
        return "\(safe)_\(seq)"
    }

    func start() {
        lock.lock()
        if listener != nil {
            lock.unlock()
            return
        }
        restartScheduled = false
        lock.unlock()

        do {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.noDelay = true
            let params = NWParameters(tls: nil, tcp: tcpOptions)
            params.allowLocalEndpointReuse = true
            params.requiredInterfaceType = .loopback
            let l = try NWListener(using: params, on: .any)
            l.stateUpdateHandler = { [weak self, weak l] state in
                guard let self, let l else { return }
                switch state {
                case .ready:
                    if let assignedPort = l.port?.rawValue {
                        self.lock.lock()
                        guard self.listener === l else {
                            self.lock.unlock()
                            return
                        }
                        self._port = assignedPort
                        let waiters = self.portWaiters
                        self.portWaiters.removeAll()
                        self.lock.unlock()
                        for w in waiters { w.resolve(assignedPort) }
                    }
                case .failed(let err):
                    print("HLSServer listener failed: \(err)")
                    self.resetListenerAndScheduleRestart(for: l)
                case .cancelled:
                    self.resetListenerAndScheduleRestart(for: l)
                default:
                    break
                }
            }
            l.newConnectionHandler = { [weak self] connection in
                self?.handle(connection: connection)
            }
            lock.lock()
            guard listener == nil else {
                lock.unlock()
                l.cancel()
                return
            }
            listener = l
            lock.unlock()
            l.start(queue: acceptQueue)
        } catch {
            print("HLSServer failed to start: \(error)")
        }
    }

    private func resetListenerAndScheduleRestart(for failedListener: NWListener) {
        lock.lock()
        guard listener === failedListener else {
            lock.unlock()
            return
        }
        listener = nil
        _port = 0
        let shouldSchedule = !restartScheduled
        restartScheduled = true
        lock.unlock()

        failedListener.cancel()
        guard shouldSchedule else { return }
        acceptQueue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.start()
        }
    }

    /// Waits until the loopback server has bound an ephemeral port (with a 2.0s safety timeout).
    func ensurePort() async -> UInt16 {
        ensureRunning()
        let immediate = port
        if immediate > 0 { return immediate }

        return await withCheckedContinuation { cont in
            let waiter = PortWaiter(cont)
            lock.lock()
            if _port > 0 {
                let p = _port
                lock.unlock()
                waiter.resolve(p)
                return
            }
            portWaiters.append(waiter)
            lock.unlock()

            acceptQueue.asyncAfter(deadline: .now() + 2.0) { [weak self, weak waiter] in
                guard let waiter else { return }
                guard let self else {
                    waiter.resolve(0)
                    return
                }
                self.lock.lock()
                self.portWaiters.removeAll { $0 === waiter }
                let current = self._port
                self.lock.unlock()
                waiter.resolve(current)
            }
        }
    }

    /// Registers a short `/s/<token>` local proxy URL for an upstream media URL + client User-Agent.
    func registerProxy(url: URL, userAgent: String, totalSize: Int64? = nil) async -> URL? {
        let p = await ensurePort()
        guard p > 0 else { return nil }
        lock.lock()
        nextProxySeq &+= 1
        let path = "/s/p\(nextProxySeq)"
        proxyTargets[path] = ProxyTarget(url: url, userAgent: userAgent, totalSize: totalSize)
        proxyKeys.append(path)
        while proxyKeys.count > 300 {
            let old = proxyKeys.removeFirst()
            proxyTargets.removeValue(forKey: old)
        }
        lock.unlock()
        return URL(string: "http://127.0.0.1:\(p)\(path)")
    }

    /// Registers a dynamic route whose content is computed on each request (e.g. live sliding-window HLS).
    func registerDynamic(path: String, handler: @escaping DynamicRouteHandler) async -> URL? {
        let p = await ensurePort()
        guard p > 0 else { return nil }
        lock.lock()
        dynamicRoutes[path] = handler
        let decoded = path.removingPercentEncoding ?? path
        if decoded != path { dynamicRoutes[decoded] = handler }
        if let existing = dynamicRouteKeys.firstIndex(of: path) {
            dynamicRouteKeys.remove(at: existing)
        }
        dynamicRouteKeys.append(path)
        while dynamicRouteKeys.count > 40 {
            let old = dynamicRouteKeys.removeFirst()
            dynamicRoutes.removeValue(forKey: old)
            dynamicRoutes.removeValue(forKey: old.removingPercentEncoding ?? old)
        }
        lock.unlock()
        return URL(string: "http://127.0.0.1:\(p)\(path)")
    }

    /// Registers an in-memory route (e.g. `/hls/abc_1/master.m3u8`) and returns its local loopback URL.
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
        while routeKeys.count > 400 {
            let old = routeKeys.removeFirst()
            routes.removeValue(forKey: old)
            routes.removeValue(forKey: old.removingPercentEncoding ?? old)
        }
        lock.unlock()
        return URL(string: "http://127.0.0.1:\(p)\(path)")
    }

    // MARK: - HTTP Connection Handling

    private func handle(connection: NWConnection) {
        let session = ConnectionSession()
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled:
                session.cancel()
            default:
                break
            }
        }
        connection.start(queue: connQueue)
        receiveRequest(on: connection, session: session, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, session: ConnectionSession, buffer: Data) {
        guard !session.isCancelled else {
            connection.cancel()
            return
        }
        if let headerRange = buffer.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
            let headerData = buffer[..<headerRange.lowerBound]
            let remainder = Data(buffer[headerRange.upperBound...])
            processHTTPRequest(headerData: Data(headerData), trailingBuffer: remainder, on: connection, session: session)
            return
        }
        if buffer.count > 65_536 {
            sendError(status: 431, text: "Request Header Fields Too Large", isHead: false, keepAlive: false, connection: connection, session: session, trailingBuffer: Data())
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            if error != nil {
                session.cancel()
                connection.cancel()
                return
            }
            var combined = buffer
            if let data, !data.isEmpty { combined.append(data) }

            if let headerRange = combined.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
                let headerData = combined[..<headerRange.lowerBound]
                let remainder = Data(combined[headerRange.upperBound...])
                self.processHTTPRequest(headerData: Data(headerData), trailingBuffer: remainder, on: connection, session: session)
            } else if isComplete || data == nil || data?.isEmpty == true {
                connection.cancel()
            } else {
                self.receiveRequest(on: connection, session: session, buffer: combined)
            }
        }
    }

    private func processHTTPRequest(
        headerData: Data,
        trailingBuffer: Data,
        on connection: NWConnection,
        session: ConnectionSession
    ) {
        guard let req = String(data: headerData, encoding: .utf8) else {
            sendError(status: 400, text: "Bad Request", isHead: false, keepAlive: false, connection: connection, session: session, trailingBuffer: trailingBuffer)
            return
        }
        let lines = req.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else {
            sendError(status: 400, text: "Bad Request", isHead: false, keepAlive: false, connection: connection, session: session, trailingBuffer: trailingBuffer)
            return
        }
        let parts = firstLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let method = parts.first ?? ""
        let isHead = method == "HEAD"
        guard parts.count >= 2, method == "GET" || isHead else {
            sendError(status: 405, text: "Method Not Allowed", isHead: isHead, keepAlive: false, connection: connection, session: session, trailingBuffer: trailingBuffer)
            return
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[name] = val
            }
        }
        let keepAlive = !(headers["connection"]?.lowercased().contains("close") ?? false)

        let targetSpec = parts[1]
        let qMark = targetSpec.firstIndex(of: "?")
        let rawPath = qMark.map { String(targetSpec[..<$0]) } ?? targetSpec
        let rawQuery = qMark.map { String(targetSpec[targetSpec.index(after: $0)...]) }
        let decodedPath = rawPath.removingPercentEncoding ?? rawPath

        // 1. Proxied upstream byte-range / live segment route
        if rawPath.hasPrefix("/s/") || decodedPath.hasPrefix("/s/") {
            lock.lock()
            let key = proxyTargets[rawPath] != nil ? rawPath : decodedPath
            let target = proxyTargets[key]
            if target != nil, let idx = proxyKeys.firstIndex(of: key) {
                proxyKeys.remove(at: idx)
                proxyKeys.append(key)
            }
            lock.unlock()

            guard let target else {
                sendError(status: 404, text: "Not Found", isHead: isHead, keepAlive: keepAlive, connection: connection, session: session, trailingBuffer: trailingBuffer)
                return
            }

            let rangeHeader = headers["range"]
            let task = Task { [weak self] in
                guard let self else { return }
                await self.serveProxy(
                    target: target,
                    rawQuery: rawQuery,
                    rangeHeader: rangeHeader,
                    isHead: isHead,
                    keepAlive: keepAlive,
                    connection: connection,
                    session: session,
                    trailingBuffer: trailingBuffer
                )
            }
            session.setTask(task)
            return
        }

        // 2. Dynamic / static playlist routes (true LRU touch on access)
        var found: (contentType: String, data: Data)?
        var dynamicHandler: DynamicRouteHandler?

        lock.lock()
        if let handler = dynamicRoutes[decodedPath] ?? dynamicRoutes[rawPath] {
            dynamicHandler = handler
            let k = dynamicRoutes[decodedPath] != nil ? decodedPath : rawPath
            if let idx = dynamicRouteKeys.firstIndex(of: k) {
                dynamicRouteKeys.remove(at: idx)
                dynamicRouteKeys.append(k)
            }
        } else if let entry = routes[decodedPath] ?? routes[rawPath] {
            found = entry
            let k = routes[decodedPath] != nil ? decodedPath : rawPath
            if let idx = routeKeys.firstIndex(of: k) {
                routeKeys.remove(at: idx)
                routeKeys.append(k)
            }
        }
        lock.unlock()

        if let dynamicHandler {
            found = dynamicHandler()
        }

        guard let entry = found else {
            sendError(status: 404, text: "Not Found", isHead: isHead, keepAlive: keepAlive, connection: connection, session: session, trailingBuffer: trailingBuffer)
            return
        }

        serveInMemory(
            contentType: entry.contentType,
            body: entry.data,
            rangeHeader: headers["range"],
            isHead: isHead,
            keepAlive: keepAlive,
            connection: connection,
            session: session,
            trailingBuffer: trailingBuffer
        )
    }

    private func serveInMemory(
        contentType: String,
        body: Data,
        rangeHeader: String?,
        isHead: Bool,
        keepAlive: Bool,
        connection: NWConnection,
        session: ConnectionSession,
        trailingBuffer: Data
    ) {
        let total = Int64(body.count)
        var statusLine = "HTTP/1.1 200 OK"
        var extraHeaders = ""
        var payload = body

        if let rangeHeader, !rangeHeader.isEmpty {
            guard total > 0, let parsed = parseRange(rangeHeader, totalLength: total) else {
                var resp = "HTTP/1.1 416 Range Not Satisfiable\r\n"
                resp += "Content-Range: bytes */\(total)\r\n"
                resp += "Content-Length: 0\r\n"
                resp += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
                sendResponse(Data(resp.utf8), keepAlive: keepAlive, on: connection, session: session, trailingBuffer: trailingBuffer)
                return
            }
            statusLine = "HTTP/1.1 206 Partial Content"
            extraHeaders = "Content-Range: bytes \(parsed.start)-\(parsed.end)/\(total)\r\n"
            let lo = body.index(body.startIndex, offsetBy: Int(parsed.start))
            let hi = body.index(body.startIndex, offsetBy: Int(parsed.end))
            payload = Data(body[lo...hi])
        }

        var resp = "\(statusLine)\r\n"
        resp += "Content-Type: \(contentType)\r\n"
        resp += "Accept-Ranges: bytes\r\n"
        resp += extraHeaders
        resp += "Content-Length: \(payload.count)\r\n"
        resp += "Cache-Control: no-cache\r\n"
        resp += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"

        var out = Data(resp.utf8)
        if !isHead { out.append(payload) }
        sendResponse(out, keepAlive: keepAlive, on: connection, session: session, trailingBuffer: trailingBuffer)
    }

    private func serveProxy(
        target: ProxyTarget,
        rawQuery: String?,
        rangeHeader: String?,
        isHead: Bool,
        keepAlive: Bool,
        connection: NWConnection,
        session: ConnectionSession,
        trailingBuffer: Data
    ) async {
        guard !session.isCancelled, !Task.isCancelled else { return }

        var upstreamURL = target.url
        if let rawQuery, !rawQuery.isEmpty,
           var comps = URLComponents(url: target.url, resolvingAgainstBaseURL: false) {
            let extra = URLComponents(string: "http://x/?\(rawQuery)")?.queryItems ?? []
            var items = comps.queryItems ?? []
            for item in extra {
                items.removeAll { $0.name == item.name }
                items.append(item)
            }
            comps.queryItems = items
            if let merged = comps.url { upstreamURL = merged }
        }

        // Normalize open-ended Range into a bounded 4 MB chunk so unbounded probes remain streaming-safe.
        var effectiveRange = rangeHeader
        var parsedRequestRange: (start: Int64, end: Int64?)?
        if let rangeHeader, !rangeHeader.isEmpty {
            parsedRequestRange = parseOpenRange(rangeHeader, knownTotal: target.totalSize)
            if let r = parsedRequestRange, r.end == nil {
                let cappedEnd = r.start + 4 * 1024 * 1024 - 1
                effectiveRange = "bytes=\(r.start)-\(cappedEnd)"
                parsedRequestRange = (r.start, cappedEnd)
            } else if let r = parsedRequestRange, let end = r.end, end - r.start >= 16 * 1024 * 1024 {
                let cappedEnd = r.start + 8 * 1024 * 1024 - 1
                effectiveRange = "bytes=\(r.start)-\(cappedEnd)"
                parsedRequestRange = (r.start, cappedEnd)
            }
        }

        var lastStatus = 0
        for attempt in 0..<3 {
            if session.isCancelled || Task.isCancelled { return }
            if attempt > 0 {
                let delayNs: UInt64 = attempt == 1 ? 150_000_000 : 400_000_000
                try? await Task.sleep(nanoseconds: delayNs)
                if session.isCancelled || Task.isCancelled { return }
            }

            var req = URLRequest(url: upstreamURL)
            req.httpMethod = isHead ? "HEAD" : "GET"
            req.setValue(target.userAgent, forHTTPHeaderField: "User-Agent")
            if let effectiveRange { req.setValue(effectiveRange, forHTTPHeaderField: "Range") }

            do {
                let (data, response) = try await Self.proxySession.data(for: req)
                if session.isCancelled || Task.isCancelled { return }
                guard let http = response as? HTTPURLResponse else {
                    lastStatus = 502
                    continue
                }
                lastStatus = http.statusCode

                if http.statusCode == 416 {
                    let cr = http.value(forHTTPHeaderField: "Content-Range") ?? "bytes */*"
                    var resp = "HTTP/1.1 416 Range Not Satisfiable\r\n"
                    resp += "Content-Range: \(cr)\r\n"
                    resp += "Content-Length: 0\r\n"
                    resp += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
                    sendResponse(Data(resp.utf8), keepAlive: keepAlive, on: connection, session: session, trailingBuffer: trailingBuffer)
                    return
                }

                if http.statusCode == 206 || http.statusCode == 200 {
                    let upstreamCT = http.value(forHTTPHeaderField: "Content-Type") ?? "video/mp4"
                    var outStatus = http.statusCode == 206 ? "HTTP/1.1 206 Partial Content" : "HTTP/1.1 200 OK"
                    var contentRangeHeader = http.value(forHTTPHeaderField: "Content-Range")
                    var body = data

                    if http.statusCode == 200, let r = parsedRequestRange {
                        if isHead {
                            let declaredTotal = http.expectedContentLength > 0 ? http.expectedContentLength : target.totalSize
                            if let total = declaredTotal, total > r.start {
                                let end = min(r.end ?? (total - 1), total - 1)
                                outStatus = "HTTP/1.1 206 Partial Content"
                                contentRangeHeader = "bytes \(r.start)-\(end)/\(total)"
                            }
                        } else if Int64(data.count) > r.start {
                            let total = Int64(data.count)
                            let end = min(r.end ?? (total - 1), total - 1)
                            let lo = data.index(data.startIndex, offsetBy: Int(r.start))
                            let hi = data.index(data.startIndex, offsetBy: Int(end))
                            body = Data(data[lo...hi])
                            outStatus = "HTTP/1.1 206 Partial Content"
                            contentRangeHeader = "bytes \(r.start)-\(end)/\(total)"
                        } else {
                            sendError(status: 416, text: "Range Not Satisfiable", isHead: isHead, keepAlive: keepAlive, connection: connection, session: session, trailingBuffer: trailingBuffer)
                            return
                        }
                    } else if http.statusCode == 206, contentRangeHeader == nil, let r = parsedRequestRange {
                        let end = r.end ?? (r.start + Int64(max(body.count, 1)) - 1)
                        let totalPart = target.totalSize.map(String.init) ?? "*"
                        contentRangeHeader = "bytes \(r.start)-\(end)/\(totalPart)"
                    }

                    if !isHead, body.isEmpty, parsedRequestRange != nil {
                        lastStatus = 502
                        continue
                    }

                    let contentLength: Int64 = isHead
                        ? (http.expectedContentLength >= 0 ? http.expectedContentLength : Int64(body.count))
                        : Int64(body.count)

                    var resp = "\(outStatus)\r\n"
                    resp += "Content-Type: \(upstreamCT)\r\n"
                    resp += "Accept-Ranges: bytes\r\n"
                    if let contentRangeHeader {
                        resp += "Content-Range: \(contentRangeHeader)\r\n"
                    }
                    resp += "Content-Length: \(contentLength)\r\n"
                    resp += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"

                    var out = Data(resp.utf8)
                    if !isHead { out.append(body) }
                    sendResponse(out, keepAlive: keepAlive, on: connection, session: session, trailingBuffer: trailingBuffer)
                    return
                }

                if http.statusCode == 404 || http.statusCode == 410 {
                    break
                }
            } catch is CancellationError {
                return
            } catch let urlErr as URLError where urlErr.code == .cancelled {
                return
            } catch {
                lastStatus = 502
            }
        }

        let errCode = (lastStatus == 403 || lastStatus == 404 || lastStatus == 410) ? lastStatus : 502
        let errText = errCode == 403 ? "Forbidden" : (errCode == 404 ? "Not Found" : "Bad Gateway")
        sendError(status: errCode, text: errText, isHead: isHead, keepAlive: keepAlive, connection: connection, session: session, trailingBuffer: trailingBuffer)
    }

    private func sendError(
        status: Int,
        text: String,
        isHead: Bool,
        keepAlive: Bool,
        connection: NWConnection,
        session: ConnectionSession,
        trailingBuffer: Data
    ) {
        let bodyBytes = Data(text.utf8)
        let shouldKeep = keepAlive && (status == 404 || status == 416)
        var msg = "HTTP/1.1 \(status) \(text)\r\n"
        msg += "Content-Type: text/plain; charset=utf-8\r\n"
        msg += "Content-Length: \(bodyBytes.count)\r\n"
        msg += "Connection: \(shouldKeep ? "keep-alive" : "close")\r\n\r\n"
        var out = Data(msg.utf8)
        if !isHead { out.append(bodyBytes) }
        sendResponse(out, keepAlive: shouldKeep, on: connection, session: session, trailingBuffer: trailingBuffer)
    }

    private func sendResponse(
        _ data: Data,
        keepAlive: Bool,
        on connection: NWConnection,
        session: ConnectionSession,
        trailingBuffer: Data
    ) {
        guard !session.isCancelled else {
            connection.cancel()
            return
        }
        if keepAlive {
            connection.send(content: data, contentContext: .defaultMessage, isComplete: false, completion: .contentProcessed { [weak self] error in
                if error != nil || session.isCancelled {
                    connection.cancel()
                    return
                }
                self?.receiveRequest(on: connection, session: session, buffer: trailingBuffer)
            })
        } else {
            connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
                self?.connQueue.asyncAfter(deadline: .now() + 0.15) {
                    connection.cancel()
                }
            })
        }
    }

    private func parseRange(_ header: String, totalLength: Int64) -> (start: Int64, end: Int64)? {
        guard totalLength > 0, let parsed = parseOpenRange(header, knownTotal: totalLength) else { return nil }
        let s = parsed.start
        let e = min(parsed.end ?? (totalLength - 1), totalLength - 1)
        guard s >= 0, s <= e else { return nil }
        return (s, e)
    }

    private func parseOpenRange(_ header: String, knownTotal: Int64?) -> (start: Int64, end: Int64?)? {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = trimmed.dropFirst(6).split(separator: ",", maxSplits: 1).first.map(String.init) ?? ""
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }

        if parts[0].isEmpty {
            // Suffix byte range: bytes=-N
            guard let suffix = Int64(parts[1]), suffix > 0, let total = knownTotal, total > 0 else { return nil }
            return (max(0, total - suffix), total - 1)
        }
        guard let start = Int64(parts[0]), start >= 0 else { return nil }
        if parts[1].isEmpty {
            return (start, knownTotal.map { max(start, $0 - 1) })
        }
        guard let end = Int64(parts[1]), end >= start else { return nil }
        if let total = knownTotal, total > 0 {
            guard start < total else { return nil }
            return (start, min(end, total - 1))
        }
        return (start, end)
    }
}

// MARK: - SIDX Parser

struct SIDXSegment: Sendable {
    let duration: Double
    let size: Int
    let offset: Int
}

enum SIDXParser {
    /// Parses the ISO Base Media File Format `sidx` (Segment Index) box from raw binary data,
    /// properly applying `first_offset`, validating `reference_type`, and rejecting truncated data.
    static func parse(data: Data, indexStart: Int, indexEnd: Int) -> [SIDXSegment]? {
        let sidxTag: UInt32 = 0x73696478 // 'sidx'
        var base: Int?
        var boxSize64: UInt64 = 0
        var headerLen = 8

        // 1. Walk top-level ISO BMFF boxes properly so we never false-match inside payload bytes.
        var pos = data.startIndex
        while pos + 8 <= data.endIndex {
            guard let rawSize = u32(in: data, at: pos), let boxType = u32(in: data, at: pos + 4) else { break }
            var bSize = UInt64(rawSize)
            var hLen = 8
            if rawSize == 1 {
                guard pos + 16 <= data.endIndex, let large = u64(in: data, at: pos + 8) else { break }
                bSize = large
                hLen = 16
            } else if rawSize == 0 {
                bSize = UInt64(data.endIndex - pos)
            }
            guard bSize >= UInt64(hLen) else { break }
            if boxType == sidxTag {
                base = pos
                boxSize64 = bSize
                headerLen = hLen
                break
            }
            if pos + Int(min(bSize, UInt64(Int.max - pos))) <= pos { break }
            pos += Int(min(bSize, UInt64(data.endIndex - pos)))
        }

        // Fallback scan if caller provided an offset-misaligned buffer.
        if base == nil, let found = data.range(of: Data([0x73, 0x69, 0x64, 0x78])), found.lowerBound - data.startIndex >= 4 {
            let candidate = found.lowerBound - 4
            if let rawSize = u32(in: data, at: candidate), rawSize >= 20 || rawSize == 1 {
                base = candidate
                headerLen = rawSize == 1 ? 16 : 8
                boxSize64 = rawSize == 1 ? (u64(in: data, at: candidate + 8) ?? 0) : UInt64(rawSize)
            }
        }

        guard let sidxBase = base, boxSize64 >= UInt64(headerLen + 12) else { return nil }
        let sidxOffsetFromStart = sidxBase - data.startIndex
        let boxEndFromStart = sidxOffsetFromStart + Int(min(boxSize64, UInt64(Int.max - sidxOffsetFromStart)))
        let sidxEndOffset = min(data.endIndex, sidxBase + Int(min(boxSize64, UInt64(data.endIndex - sidxBase))))

        var offset = sidxBase + headerLen
        func readU16() -> UInt16? {
            guard offset + 2 <= sidxEndOffset, let v = u16(in: data, at: offset) else { return nil }
            offset += 2
            return v
        }
        func readU32() -> UInt32? {
            guard offset + 4 <= sidxEndOffset, let v = u32(in: data, at: offset) else { return nil }
            offset += 4
            return v
        }
        func readU64() -> UInt64? {
            guard offset + 8 <= sidxEndOffset, let v = u64(in: data, at: offset) else { return nil }
            offset += 8
            return v
        }

        guard let versionAndFlags = readU32() else { return nil }
        let version = UInt8((versionAndFlags >> 24) & 0xFF)

        _ = readU32() // reference_id
        guard let timescale = readU32(), timescale > 0 else { return nil }
        let firstOffset: UInt64
        if version == 0 {
            guard readU32() != nil, let fo = readU32() else { return nil }
            firstOffset = UInt64(fo)
        } else {
            guard readU64() != nil, let fo = readU64() else { return nil }
            firstOffset = fo
        }
        _ = readU16() // reserved
        guard let count = readU16(), count > 0 else { return nil }

        // Require complete table inside `data` so partial fetches never poison cache.
        guard offset + Int(count) * 12 <= sidxEndOffset else { return nil }

        let baseAfterSidx = boxEndFromStart > 0 ? (indexStart + boxEndFromStart) : (indexEnd + 1)
        var currentOffset = baseAfterSidx + Int(min(firstOffset, UInt64(Int.max - baseAfterSidx)))
        var segments: [SIDXSegment] = []
        segments.reserveCapacity(Int(count))

        for _ in 0..<count {
            guard let d1 = readU32(), let d2 = readU32(), readU32() != nil else { return nil }
            // reference_type == 1 indicates a hierarchical sub-sidx reference, not a media segment.
            guard (d1 & 0x8000_0000) == 0 else { return nil }
            let size = Int(d1 & 0x7FFF_FFFF)
            guard size > 0, d2 > 0 else { return nil }
            let dur = Double(d2) / Double(timescale)
            segments.append(SIDXSegment(duration: dur, size: size, offset: currentOffset))
            currentOffset += size
        }
        return segments.isEmpty ? nil : segments
    }

    private static func u16(in data: Data, at pos: Int) -> UInt16? {
        guard pos >= data.startIndex, pos + 2 <= data.endIndex else { return nil }
        return (UInt16(data[pos]) << 8) | UInt16(data[pos + 1])
    }

    private static func u32(in data: Data, at pos: Int) -> UInt32? {
        guard pos >= data.startIndex, pos + 4 <= data.endIndex else { return nil }
        return (UInt32(data[pos]) << 24)
            | (UInt32(data[pos + 1]) << 16)
            | (UInt32(data[pos + 2]) << 8)
            | UInt32(data[pos + 3])
    }

    private static func u64(in data: Data, at pos: Int) -> UInt64? {
        guard let hi = u32(in: data, at: pos), let lo = u32(in: data, at: pos + 4) else { return nil }
        return (UInt64(hi) << 32) | UInt64(lo)
    }
}

// MARK: - HLS Builder

enum HLSBuilder {
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 30
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    private static let sidxLock = NSLock()
    private static var sidxCache: [String: [SIDXSegment]] = [:]
    private static var sidxKeys: [String] = []
    private static var inFlightSidx: [String: Task<[SIDXSegment]?, Never>] = [:]

    private static func getOrFetchSegments(
        id: String,
        format: DirectFormat,
        idx: (start: Int, end: Int)
    ) async -> [SIDXSegment]? {
        guard idx.end >= idx.start else { return nil }
        let key = "\(id)_\(format.cacheIdentifier)_\(idx.start)-\(idx.end)"

        sidxLock.lock()
        if let cached = sidxCache[key] {
            if let pos = sidxKeys.firstIndex(of: key) {
                sidxKeys.remove(at: pos)
                sidxKeys.append(key)
            }
            sidxLock.unlock()
            return cached
        }
        if let existingTask = inFlightSidx[key] {
            sidxLock.unlock()
            return await existingTask.value
        }

        let fetchTask = Task<[SIDXSegment]?, Never> {
            defer {
                sidxLock.lock()
                inFlightSidx.removeValue(forKey: key)
                sidxLock.unlock()
            }
            guard let bytes = await fetchRange(format.url, start: idx.start, end: idx.end, userAgent: format.effectiveUserAgent),
                  let segs = SIDXParser.parse(data: bytes, indexStart: idx.start, indexEnd: idx.end) else {
                return nil
            }
            sidxLock.lock()
            if sidxCache[key] == nil {
                while sidxKeys.count >= 120 {
                    let oldKey = sidxKeys.removeFirst()
                    sidxCache.removeValue(forKey: oldKey)
                }
                sidxKeys.append(key)
            } else if let pos = sidxKeys.firstIndex(of: key) {
                sidxKeys.remove(at: pos)
                sidxKeys.append(key)
            }
            sidxCache[key] = segs
            sidxLock.unlock()
            return segs
        }
        inFlightSidx[key] = fetchTask
        sidxLock.unlock()
        return await fetchTask.value
    }

    /// Builds an audio-only HLS Playlist for YouTube DASH audio via the local byte-range proxy.
    static func buildAudio(id: String, audio: DirectFormat, startTimeSecs: Int? = nil) async -> URL? {
        guard let aInit = audio.initRange, let aIdx = audio.indexRange else { return nil }
        guard let aSegs = await getOrFetchSegments(id: id, format: audio, idx: aIdx),
              let proxyURL = await HLSServer.shared.registerProxy(url: audio.url, userAgent: audio.effectiveUserAgent, totalSize: audio.size) else {
            return nil
        }

        let aPlaylist = makeMediaPlaylist(proxyURL: proxyURL, initRange: aInit, segments: aSegs, startSec: startTimeSecs.map(Double.init))
        let tag = HLSServer.shared.nextTag(prefix: id)
        let aPath = "/hls/\(tag)/audio.m3u8"

        guard let aData = aPlaylist.data(using: .utf8) else { return nil }
        return await HLSServer.shared.register(path: aPath, contentType: "application/vnd.apple.mpegurl", data: aData)
    }

    /// Builds a compliant Apple HLS Master Playlist for separate YouTube DASH video and audio tracks,
    /// enforcing codec uniformity across ABR variants and routing all ranges through `HLSServer` proxy.
    static func buildMaster(
        id: String,
        video: DirectFormat,
        audio: DirectFormat,
        variants: [DirectFormat] = [],
        startTimeSecs: Int? = nil
    ) async -> URL? {
        guard let aInit = audio.initRange, let aIdx = audio.indexRange else { return nil }

        // Enforce single codec family in master playlist so ABR transitions never crash hardware decoders.
        let primaryFamily = codecFamily(from: video.mime)
        var validVariants: [DirectFormat] = []
        var seenEdges = Set<Int>()
        for variant in [video] + variants where variant.initRange != nil && variant.indexRange != nil {
            if let pf = primaryFamily, let vf = codecFamily(from: variant.mime), pf != vf { continue }
            let key = variant.shortEdge > 0 ? variant.shortEdge : (variant.height ?? variant.bitrate)
            if seenEdges.insert(key).inserted {
                validVariants.append(variant)
            }
        }
        guard !validVariants.isEmpty else { return nil }

        async let aSegsTask = getOrFetchSegments(id: id, format: audio, idx: aIdx)
        var fetchedVariants: [(format: DirectFormat, fileName: String, segments: [SIDXSegment])] = []

        await withTaskGroup(of: (DirectFormat, String, [SIDXSegment]?)?.self) { group in
            for (idxNum, v) in validVariants.enumerated() {
                guard let vIdx = v.indexRange else { continue }
                let edge = v.shortEdge > 0 ? v.shortEdge : (v.height ?? 720)
                let fileName = "video_\(edge)_\(idxNum).m3u8"
                group.addTask {
                    guard let segs = await getOrFetchSegments(id: id, format: v, idx: vIdx) else { return nil }
                    return (v, fileName, segs)
                }
            }
            for await res in group {
                if let (v, fileName, segs) = res, let segs {
                    fetchedVariants.append((v, fileName, segs))
                }
            }
        }

        guard let aSegs = await aSegsTask, !fetchedVariants.isEmpty else { return nil }

        guard let aProxy = await HLSServer.shared.registerProxy(url: audio.url, userAgent: audio.effectiveUserAgent, totalSize: audio.size) else {
            return nil
        }

        let tag = HLSServer.shared.nextTag(prefix: id)
        let aPath = "/hls/\(tag)/audio.m3u8"
        let mPath = "/hls/\(tag)/master.m3u8"

        let aPlaylist = makeMediaPlaylist(proxyURL: aProxy, initRange: aInit, segments: aSegs, startSec: startTimeSecs.map(Double.init))
        guard let aData = aPlaylist.data(using: .utf8),
              await HLSServer.shared.register(path: aPath, contentType: "application/vnd.apple.mpegurl", data: aData) != nil else {
            return nil
        }

        // Order highest quality first so AVPlayer starts quickly on target quality while keeping ABR ladder intact.
        let sortedVariants = fetchedVariants.sorted {
            ($0.format.shortEdge, $0.format.fps ?? 30, $0.format.bitrate)
                > ($1.format.shortEdge, $1.format.fps ?? 30, $1.format.bitrate)
        }

        let aCodec = extractCodec(from: audio.mime) ?? "mp4a.40.2"
        var master = "#EXTM3U\n"
        master += "#EXT-X-VERSION:7\n"
        master += "#EXT-X-INDEPENDENT-SEGMENTS\n\n"
        master += "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"Main\",DEFAULT=YES,AUTOSELECT=YES,URI=\"audio.m3u8\"\n\n"

        var registeredCount = 0
        for item in sortedVariants {
            let v = item.format
            guard let vInit = v.initRange,
                  let vProxy = await HLSServer.shared.registerProxy(url: v.url, userAgent: v.effectiveUserAgent, totalSize: v.size) else {
                continue
            }
            let vPlaylist = makeMediaPlaylist(proxyURL: vProxy, initRange: vInit, segments: item.segments, startSec: startTimeSecs.map(Double.init))
            let vPath = "/hls/\(tag)/\(item.fileName)"
            guard let vData = vPlaylist.data(using: .utf8),
                  await HLSServer.shared.register(path: vPath, contentType: "application/vnd.apple.mpegurl", data: vData) != nil else {
                continue
            }

            let vCodec = extractCodec(from: v.mime) ?? "avc1.4d401f"
            let height = v.height ?? 720
            let width = v.width ?? (height * 16 / 9)
            let bandwidth = max(v.bitrate + audio.bitrate, 150_000)
            let fpsPart = (v.fps ?? 0) > 0 ? ",FRAME-RATE=\(v.fps!)" : ""

            master += "#EXT-X-STREAM-INF:BANDWIDTH=\(bandwidth),RESOLUTION=\(width)x\(height)\(fpsPart),CODECS=\"\(vCodec),\(aCodec)\",AUDIO=\"audio\"\n"
            master += "\(item.fileName)\n"
            registeredCount += 1
        }

        guard registeredCount > 0, let mData = master.data(using: .utf8) else { return nil }
        return await HLSServer.shared.register(path: mPath, contentType: "application/vnd.apple.mpegurl", data: mData)
    }

    private static func fetchLiveInfo(url: URL, userAgent: String) async -> (seq: Int, segDur: Double)? {
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (_, response) = try? await session.data(for: req),
              let resp = response as? HTTPURLResponse,
              (200..<300).contains(resp.statusCode) else {
            return nil
        }
        guard let seqStr = resp.value(forHTTPHeaderField: "X-Head-Seqnum") ?? resp.value(forHTTPHeaderField: "X-Sequence-Num"),
              let seq = Int(seqStr), seq > 0 else {
            return nil
        }
        let targetDur = resp.value(forHTTPHeaderField: "X-Target-Duration").flatMap(Double.init)
            ?? resp.value(forHTTPHeaderField: "X-Segment-Duration").flatMap(Double.init)
            ?? 2.0
        return (seq, max(targetDur, 1.0))
    }

    /// Builds a compliant Apple Live HLS Master Playlist for YouTube live broadcasts when official HLS is unavailable.
    static func buildLiveMaster(id: String, video: DirectFormat, audio: DirectFormat) async -> URL? {
        guard let vLive = await fetchLiveInfo(url: video.url, userAgent: video.effectiveUserAgent) else { return nil }
        let aLive = await fetchLiveInfo(url: audio.url, userAgent: audio.effectiveUserAgent) ?? vLive
        let startTime = Date()

        guard let vProxy = await HLSServer.shared.registerProxy(url: video.url, userAgent: video.effectiveUserAgent),
              let aProxy = await HLSServer.shared.registerProxy(url: audio.url, userAgent: audio.effectiveUserAgent) else {
            return nil
        }

        let tag = HLSServer.shared.nextTag(prefix: "live_\(id)")
        let vPath = "/hls/\(tag)/video.m3u8"
        let aPath = "/hls/\(tag)/audio.m3u8"
        let mPath = "/hls/\(tag)/master.m3u8"

        let vBase = vProxy.absoluteString
        let aBase = aProxy.absoluteString

        _ = await HLSServer.shared.registerDynamic(path: vPath) {
            makeLiveMediaPlaylist(baseURL: vBase, baseSeq: vLive.seq, segDur: vLive.segDur, startTime: startTime)
        }
        _ = await HLSServer.shared.registerDynamic(path: aPath) {
            makeLiveMediaPlaylist(baseURL: aBase, baseSeq: aLive.seq, segDur: aLive.segDur, startTime: startTime)
        }

        let vCodec = extractCodec(from: video.mime) ?? "avc1.4d401f"
        let aCodec = extractCodec(from: audio.mime) ?? "mp4a.40.2"
        let height = video.height ?? 720
        let width = video.width ?? (height * 16 / 9)
        let bandwidth = max(video.bitrate + audio.bitrate, 800_000)

        var master = "#EXTM3U\n"
        master += "#EXT-X-VERSION:7\n"
        master += "#EXT-X-INDEPENDENT-SEGMENTS\n\n"
        master += "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"Main\",DEFAULT=YES,AUTOSELECT=YES,URI=\"audio.m3u8\"\n"
        master += "#EXT-X-STREAM-INF:BANDWIDTH=\(bandwidth),RESOLUTION=\(width)x\(height),CODECS=\"\(vCodec),\(aCodec)\",AUDIO=\"audio\"\n"
        master += "video.m3u8\n"

        guard let mData = master.data(using: .utf8) else { return nil }
        return await HLSServer.shared.register(path: mPath, contentType: "application/vnd.apple.mpegurl", data: mData)
    }

    /// Builds a compliant Apple Live HLS Audio Playlist for YouTube live broadcasts.
    static func buildLiveAudio(id: String, audio: DirectFormat) async -> URL? {
        guard let aLive = await fetchLiveInfo(url: audio.url, userAgent: audio.effectiveUserAgent),
              let aProxy = await HLSServer.shared.registerProxy(url: audio.url, userAgent: audio.effectiveUserAgent) else {
            return nil
        }
        let startTime = Date()
        let tag = HLSServer.shared.nextTag(prefix: "live_\(id)")
        let aPath = "/hls/\(tag)/audio.m3u8"
        let aBase = aProxy.absoluteString

        return await HLSServer.shared.registerDynamic(path: aPath) {
            makeLiveMediaPlaylist(baseURL: aBase, baseSeq: aLive.seq, segDur: aLive.segDur, startTime: startTime)
        }
    }

    private static func makeLiveMediaPlaylist(baseURL: String, baseSeq: Int, segDur: Double, startTime: Date) -> (String, Data) {
        let elapsed = Date().timeIntervalSince(startTime)
        let currentSeq = baseSeq + max(0, Int(elapsed / segDur))
        let windowStart = max(0, currentSeq - 5)
        let targetDur = max(1, Int(ceil(segDur)))
        let sep = baseURL.contains("?") ? "&" : "?"

        var lines: [String] = []
        lines.append("#EXTM3U")
        lines.append("#EXT-X-VERSION:7")
        lines.append("#EXT-X-TARGETDURATION:\(targetDur)")
        lines.append("#EXT-X-MEDIA-SEQUENCE:\(windowStart)")
        lines.append("#EXT-X-INDEPENDENT-SEGMENTS")
        for s in windowStart...currentSeq {
            lines.append(String(format: "#EXTINF:%.3f,", segDur))
            lines.append("\(baseURL)\(sep)sq=\(s)")
        }
        let data = lines.joined(separator: "\n").data(using: .utf8) ?? Data()
        return ("application/vnd.apple.mpegurl", data)
    }

    private static func fetchRange(_ url: URL, start: Int, end: Int, userAgent: String) async -> Data? {
        guard end >= start else { return nil }
        let expected = end - start + 1
        for attempt in 0..<2 {
            if Task.isCancelled { return nil }
            if attempt > 0 { try? await Task.sleep(nanoseconds: 200_000_000) }
            var req = URLRequest(url: url)
            req.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await session.data(for: req),
                  let http = response as? HTTPURLResponse else { continue }
            if http.statusCode == 206 {
                guard data.count >= expected else { continue }
                return data
            } else if http.statusCode == 200, data.count > end {
                let lo = data.index(data.startIndex, offsetBy: start)
                let hi = data.index(data.startIndex, offsetBy: end)
                return Data(data[lo...hi])
            } else if http.statusCode == 403 || http.statusCode == 404 || http.statusCode == 410 {
                return nil
            }
        }
        return nil
    }

    private static func makeMediaPlaylist(
        proxyURL: URL,
        initRange: (start: Int, end: Int),
        segments: [SIDXSegment],
        startSec: Double? = nil
    ) -> String {
        let initLen = max(1, initRange.end - initRange.start + 1)
        let maxDur = segments.map(\.duration).max() ?? 10
        let targetDur = max(1, Int(ceil(maxDur)))
        let totalDur = segments.reduce(0.0) { $0 + $1.duration }
        let urlStr = proxyURL.absoluteString

        var lines: [String] = []
        lines.reserveCapacity(segments.count * 3 + 10)
        lines.append("#EXTM3U")
        lines.append("#EXT-X-VERSION:7")
        lines.append("#EXT-X-TARGETDURATION:\(targetDur)")
        lines.append("#EXT-X-MEDIA-SEQUENCE:0")
        lines.append("#EXT-X-PLAYLIST-TYPE:VOD")
        lines.append("#EXT-X-INDEPENDENT-SEGMENTS")
        if let s = startSec, s > 0.5, totalDur > 2, s < totalDur - 1 {
            lines.append(String(format: "#EXT-X-START:TIME-OFFSET=%.3f,PRECISE=YES", s))
        }
        lines.append("#EXT-X-MAP:URI=\"\(urlStr)\",BYTERANGE=\"\(initLen)@\(initRange.start)\"")

        for s in segments {
            lines.append(String(format: "#EXTINF:%.6f,", s.duration))
            lines.append("#EXT-X-BYTERANGE:\(s.size)@\(s.offset)")
            lines.append(urlStr)
        }
        lines.append("#EXT-X-ENDLIST\n")
        return lines.joined(separator: "\n")
    }

    private static func extractCodec(from mime: String) -> String? {
        if let r = mime.range(of: "codecs=\"") {
            let sub = mime[r.upperBound...]
            if let end = sub.firstIndex(of: "\"") { return String(sub[..<end]) }
        }
        if let r = mime.range(of: "codecs=") {
            let sub = mime[r.upperBound...].trimmingCharacters(in: .whitespaces)
            return String(sub.prefix { $0 != ";" && $0 != " " && $0 != "\"" })
        }
        return nil
    }

    private static func codecFamily(from mime: String) -> String? {
        guard let c = extractCodec(from: mime)?.lowercased() else { return nil }
        if c.hasPrefix("avc1") { return "avc1" }
        if c.hasPrefix("av01") { return "av01" }
        if c.hasPrefix("hvc1") || c.hasPrefix("hev1") { return "hevc" }
        if c.hasPrefix("vp09") || c.hasPrefix("vp9") { return "vp09" }
        return String(c.prefix(4))
    }
}
