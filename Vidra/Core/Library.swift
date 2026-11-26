import Foundation

/// Everything is stored locally — no Google account needed.
@MainActor
final class Library: ObservableObject {
    static let shared = Library()

    nonisolated static let fileURL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("library.json")
    private nonisolated static let ioQueue = DispatchQueue(label: "vidra.library.io", qos: .utility)

    @Published var subscriptions: [Channel] = [] { didSet { if !suppressAutoSave { scheduleSave() } } }
    @Published var history: [HistoryItem] = [] { didSet { if !suppressAutoSave { scheduleSave() } } }
    @Published var watchLater: [Video] = [] { didSet { if !suppressAutoSave { scheduleSave() } } }
    @Published var playlists: [LocalPlaylist] = [] { didSet { if !suppressAutoSave { scheduleSave() } } }
    /// Music tracks from any source (YT Music / Spotify).
    @Published var likedTracks: [Video] = [] { didSet { if !suppressAutoSave { scheduleSave() } } }
    /// Followed music artists (Spotify artists "spa:…", etc.).
    @Published var followedArtists: [Channel] = [] { didSet { if !suppressAutoSave { scheduleSave() } } }

    // Not @Published: changes frequently during playback.
    private var positions: [String: Double] = [:]
    private var suppressAutoSave = false
    private var saveTask: Task<Void, Never>?
    private var throttledSaveTask: Task<Void, Never>?
    private var lastThrottledSaveTime: Date = .distantPast

    private struct Snapshot: Codable, Sendable {
        var subscriptions: [Channel]
        var history: [HistoryItem]
        var watchLater: [Video]
        var playlists: [LocalPlaylist]
        var positions: [String: Double]
        var likedTracks: [Video]
        var followedArtists: [Channel]

        init(subscriptions: [Channel], history: [HistoryItem], watchLater: [Video], playlists: [LocalPlaylist],
             positions: [String: Double], likedTracks: [Video], followedArtists: [Channel]) {
            self.subscriptions = subscriptions
            self.history = history
            self.watchLater = watchLater
            self.playlists = playlists
            self.positions = positions.filter { $0.value.isFinite && $0.value >= 0 }
            self.likedTracks = likedTracks
            self.followedArtists = followedArtists
        }

        // Tolerate missing keys so future fields don't wipe existing data.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            subscriptions = try c.decodeIfPresent([Channel].self, forKey: .subscriptions) ?? []
            history = try c.decodeIfPresent([HistoryItem].self, forKey: .history) ?? []
            watchLater = try c.decodeIfPresent([Video].self, forKey: .watchLater) ?? []
            playlists = try c.decodeIfPresent([LocalPlaylist].self, forKey: .playlists) ?? []
            let rawPos = try c.decodeIfPresent([String: Double].self, forKey: .positions) ?? [:]
            positions = rawPos.filter { $0.value.isFinite && $0.value >= 0 }
            likedTracks = try c.decodeIfPresent([Video].self, forKey: .likedTracks) ?? []
            followedArtists = try c.decodeIfPresent([Channel].self, forKey: .followedArtists) ?? []
        }
    }

    private init() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Self.fileURL.path),
              let data = try? Data(contentsOf: Self.fileURL) else { return }
        guard let s = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            let backup = Self.fileURL.deletingLastPathComponent()
                .appendingPathComponent("library.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? fm.moveItem(at: Self.fileURL, to: backup)
            return
        }
        suppressAutoSave = true
        subscriptions = s.subscriptions
        history = s.history
        watchLater = s.watchLater
        playlists = s.playlists
        positions = s.positions
        likedTracks = s.likedTracks
        followedArtists = s.followedArtists
        suppressAutoSave = false
    }

    // MARK: Persistence

    func restoreBackup(from data: Data) -> Bool {
        guard let s = try? JSONDecoder().decode(Snapshot.self, from: data) else { return false }
        suppressAutoSave = true
        subscriptions = s.subscriptions
        history = s.history
        watchLater = s.watchLater
        playlists = s.playlists
        positions = s.positions
        likedTracks = s.likedTracks
        followedArtists = s.followedArtists
        suppressAutoSave = false
        write()
        return true
    }

    func flush() {
        saveTask?.cancel()
        saveTask = nil
        throttledSaveTask?.cancel()
        throttledSaveTask = nil
        let s = Snapshot(subscriptions: subscriptions, history: history, watchLater: watchLater,
                         playlists: playlists, positions: positions,
                         likedTracks: likedTracks, followedArtists: followedArtists)
        let url = Self.fileURL
        Self.ioQueue.sync {
            if let data = try? JSONEncoder().encode(s) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            write()
        }
    }

    private func write() {
        let s = Snapshot(subscriptions: subscriptions, history: history, watchLater: watchLater,
                         playlists: playlists, positions: positions,
                         likedTracks: likedTracks, followedArtists: followedArtists)
        let fileURL = Self.fileURL
        Self.ioQueue.async {
            guard let data = try? JSONEncoder().encode(s) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: Subscriptions

    func isSubscribed(_ id: String) -> Bool { subscriptions.contains { $0.id == id } }

    func toggleSubscription(_ channel: Channel) {
        if let i = subscriptions.firstIndex(where: { $0.id == channel.id }) {
            subscriptions.remove(at: i)
        } else {
            subscriptions.append(channel)
            sortSubscriptions()
        }
    }

    func refreshChannel(_ channel: Channel) {
        guard !channel.title.isEmpty, let i = subscriptions.firstIndex(where: { $0.id == channel.id }),
              subscriptions[i] != channel else { return }
        subscriptions[i] = channel
    }

    /// Google Takeout `subscriptions.csv`: Channel Id,Channel Url,Channel Title
    func importTakeout(_ csv: String) -> Int {
        let cleanCSV = csv.hasPrefix("\u{FEFF}") ? String(csv.dropFirst()) : csv
        var existing = Set(subscriptions.map(\.id))
        var appended: [Channel] = []
        for line in cleanCSV.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            guard parts.count == 3, parts[0].hasPrefix("UC"), existing.insert(parts[0]).inserted else { continue }
            appended.append(Channel(id: parts[0], title: parts[2]))
        }
        guard !appended.isEmpty else { return 0 }
        var combined = subscriptions + appended
        combined.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        subscriptions = combined
        return appended.count
    }

    private func sortSubscriptions() {
        subscriptions.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    // MARK: History & positions

    func addHistory(_ video: Video) {
        guard Pref.saveHistory else { return }
        if history.first?.video.id == video.id { return }
        history.removeAll { $0.video.id == video.id }
        history.insert(HistoryItem(video: video, date: Date()), at: 0)
        if history.count > 1000 { history.removeLast(history.count - 1000) }
    }

    func clearHistory() {
        history = []
        positions = [:]
    }

    func position(_ id: String) -> Double { positions[id] ?? 0 }

    func setPosition(_ id: String, _ seconds: Double?, persist: Bool = false) {
        if let seconds {
            guard seconds.isFinite, seconds >= 0 else { return }
            positions[id] = seconds
        } else {
            positions[id] = nil
        }
        if positions.count > 3000 {
            if Pref.saveHistory && !history.isEmpty {
                let keep = Set(history.map(\.id))
                positions = positions.filter { keep.contains($0.key) || $0.key == id }
            } else {
                // Keep most recent batch rather than wiping all saved positions.
                let trimmed = Array(positions.keys.prefix(1500))
                var nextPos: [String: Double] = [:]
                for k in trimmed { nextPos[k] = positions[k] }
                if let s = seconds { nextPos[id] = s }
                positions = nextPos
            }
        }
        if persist {
            saveTask?.cancel()
            write()
        } else {
            scheduleThrottledSave()
        }
    }

    private func scheduleThrottledSave() {
        guard throttledSaveTask == nil else { return }
        let elapsed = Date().timeIntervalSince(lastThrottledSaveTime)
        if elapsed >= 30 {
            lastThrottledSaveTime = Date()
            write()
            return
        }
        throttledSaveTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(1, 30 - elapsed)) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self.lastThrottledSaveTime = Date()
            self.throttledSaveTask = nil
            self.write()
        }
    }

    // MARK: Music likes & follows

    func isLiked(_ id: String) -> Bool { likedTracks.contains { $0.id == id } }

    func toggleLike(_ track: Video) {
        if isLiked(track.id) {
            likedTracks.removeAll { $0.id == track.id }
        } else {
            likedTracks.insert(track, at: 0)
        }
    }

    func isFollowing(_ id: String) -> Bool { followedArtists.contains { $0.id == id } }

    func toggleFollow(_ artist: Channel) {
        if isFollowing(artist.id) {
            followedArtists.removeAll { $0.id == artist.id }
        } else {
            followedArtists.insert(artist, at: 0)
        }
    }

    // MARK: Watch later

    func isInWatchLater(_ id: String) -> Bool { watchLater.contains { $0.id == id } }

    func toggleWatchLater(_ video: Video) {
        if isInWatchLater(video.id) {
            watchLater.removeAll { $0.id == video.id }
        } else {
            watchLater.insert(video, at: 0)
        }
    }

    // MARK: Playlists

    @discardableResult
    func createPlaylist(_ name: String) -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = LocalPlaylist(name: trimmed.isEmpty ? "Danh sách phát mới" : trimmed)
        playlists.append(p)
        return p.id
    }

    func contains(_ videoId: String, in playlist: UUID) -> Bool {
        playlists.first { $0.id == playlist }?.videos.contains { $0.id == videoId } ?? false
    }

    func add(_ video: Video, to playlist: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == playlist }),
              !playlists[i].videos.contains(where: { $0.id == video.id }) else { return }
        playlists[i].videos.append(video)
    }

    func toggle(_ video: Video, in playlist: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == playlist }) else { return }
        if contains(video.id, in: playlist) {
            playlists[i].videos.removeAll { $0.id == video.id }
        } else {
            playlists[i].videos.append(video)
        }
    }

    func videos(in source: LocalSource) -> [Video] {
        switch source {
        case .liked: return likedTracks
        case .watchLater: return watchLater
        case .playlist(let id): return playlists.first { $0.id == id }?.videos ?? []
        }
    }

    func remove(at offsets: IndexSet, from source: LocalSource) {
        switch source {
        case .liked:
            let valid = offsets.filter { likedTracks.indices.contains($0) }
            likedTracks.remove(atOffsets: IndexSet(valid))
        case .watchLater:
            let valid = offsets.filter { watchLater.indices.contains($0) }
            watchLater.remove(atOffsets: IndexSet(valid))
        case .playlist(let id):
            if let i = playlists.firstIndex(where: { $0.id == id }) {
                let valid = offsets.filter { playlists[i].videos.indices.contains($0) }
                playlists[i].videos.remove(atOffsets: IndexSet(valid))
            }
        }
    }

    func move(from offsets: IndexSet, to dest: Int, in source: LocalSource) {
        switch source {
        case .liked:
            let valid = offsets.filter { likedTracks.indices.contains($0) }
            let clamped = min(max(0, dest), likedTracks.count)
            if !valid.isEmpty { likedTracks.move(fromOffsets: IndexSet(valid), toOffset: clamped) }
        case .watchLater:
            let valid = offsets.filter { watchLater.indices.contains($0) }
            let clamped = min(max(0, dest), watchLater.count)
            if !valid.isEmpty { watchLater.move(fromOffsets: IndexSet(valid), toOffset: clamped) }
        case .playlist(let id):
            if let i = playlists.firstIndex(where: { $0.id == id }) {
                let valid = offsets.filter { playlists[i].videos.indices.contains($0) }
                let clamped = min(max(0, dest), playlists[i].videos.count)
                if !valid.isEmpty { playlists[i].videos.move(fromOffsets: IndexSet(valid), toOffset: clamped) }
            }
        }
    }
}

enum LocalSource: Hashable {
    case liked
    case watchLater
    case playlist(UUID)
}
