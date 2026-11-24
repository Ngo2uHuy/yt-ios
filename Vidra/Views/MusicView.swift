import SwiftUI

enum MusicProvider: String, CaseIterable, Identifiable {
    case ytMusic, spotify
    var id: String { rawValue }

    var title: String {
        switch self {
        case .ytMusic: return "YT Music"
        case .spotify: return "Spotify"
        }
    }

    var icon: String {
        switch self {
        case .ytMusic: return "play.circle.fill"
        case .spotify: return "dot.radiowaves.right"
        }
    }

    var brandColor: Color {
        switch self {
        case .ytMusic: return Color.red
        case .spotify: return Color(red: 0.11, green: 0.73, blue: 0.33)
        }
    }
}

struct MusicView: View {
    @AppStorage("musicProvider") private var provider = MusicProvider.ytMusic
    @State private var text = ""
    @State private var query = ""
    @State private var message: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                providerBar
                content
            }
            .navigationTitle("Nhạc")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $text, prompt: "Tìm bài hát, nghệ sĩ")
            .onSubmit(of: .search) { submit() }
            .onChange(of: text) { if $0.isEmpty { query = "" } }
            .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") {}
            }
        }
    }

    private var providerBar: some View {
        HStack(spacing: 8) {
            ForEach(MusicProvider.allCases) { p in
                let selected = provider == p
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        provider = p
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: p.icon)
                            .font(.system(size: 13, weight: .semibold))
                        Text(p.title)
                            .font(.subheadline.weight(selected ? .bold : .medium))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background {
                        if selected {
                            Capsule().fill(p.brandColor)
                                .shadow(color: p.brandColor.opacity(0.35), radius: 5, y: 2)
                        } else {
                            Capsule().fill(Color(.secondarySystemFill))
                        }
                    }
                    .foregroundStyle(selected ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch provider {
        case .ytMusic:
            if query.isEmpty {
                PagedList(loader: { _ in try await InnerTube.shared.musicHome() }).id("ytm-home")
            } else {
                PagedList(loader: { [query] token in
                    try await InnerTube.shared.musicSearch(query, continuation: token)
                })
                .id("ytm|\(query)")
            }
        case .spotify:
            SpotifyHomeView(query: query)
        }
    }

    private func submit() {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        if let parsed = Spotify.parseLink(q) {
            provider = .spotify
            Task {
                do {
                    let (_, tracks) = try await Spotify.fetch(q)
                    guard let first = tracks.first else { return }
                    if parsed.kind == "track" {
                        let v = Video(id: "sp:\(parsed.id)", title: first.title, channelTitle: first.artist, source: .spotify)
                        PlayerManager.shared.play(v)
                    } else {
                        let matched = await Spotify.matchAll(tracks) { _ in }
                        let playable = matched.compactMap { $0 }
                        if let firstPlay = playable.first {
                            PlayerManager.shared.play(firstPlay, queue: Array(playable.dropFirst()))
                        }
                    }
                } catch {
                    message = error.localizedDescription
                }
            }
            return
        }
        if case .video(let id)? = YTLink.parse(q) {
            PlayerManager.shared.play(Video(id: id, title: "", channelTitle: "", source: .ytMusic))
            return
        }
        query = q
    }
}

struct SpotifyImportView: View {
    @StateObject private var importer = SpotifyImporter()
    @State private var link = ""

    var body: some View {
        List {
            Section {
                TextField("Link playlist / album / bài hát Spotify", text: $link)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                HStack {
                    PasteButton(payloadType: String.self) { strings in
                        Task { @MainActor in link = strings.first ?? "" }
                    }
                    .labelStyle(.titleAndIcon)
                    Spacer()
                    Button("Nhập") { importer.run(link) }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .disabled(importer.running || Spotify.parseLink(link) == nil)
                }
            } footer: {
                Text("Vidra đọc danh sách bài từ Spotify và hỗ trợ phát nhạc chất lượng cao, đồng bộ danh sách phát yêu thích của bạn.")
            }

            if importer.running {
                Section {
                    if importer.total > 0 {
                        ProgressView(value: Double(importer.done), total: Double(importer.total)) {
                            Text("Đang ghép bài \(importer.done)/\(importer.total)")
                        }
                        .tint(.green)
                    } else {
                        ProgressView("Đang đọc danh sách…")
                    }
                }
            }

            if let error = importer.error {
                Section { Text(error).foregroundStyle(.red) }
            }

            if let r = importer.result {
                Section("Kết quả") {
                    NavigationLink {
                        LocalVideoList(title: "Spotify: \(r.name)", source: .playlist(r.playlist))
                    } label: {
                        Label("Mở “\(r.name)” – \(r.matched) bài", systemImage: "music.note.list")
                    }
                    if !r.missed.isEmpty {
                        DisclosureGroup("Không tìm thấy \(r.missed.count) bài") {
                            ForEach(r.missed, id: \.self) { Text($0).font(.caption) }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}
