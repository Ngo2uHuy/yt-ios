import SwiftUI

enum MusicProvider: String, CaseIterable, Identifiable {
    case ytMusic, soundCloud, spotify
    var id: String { rawValue }

    var title: String {
        switch self {
        case .ytMusic: return "YT Music"
        case .soundCloud: return "SoundCloud"
        case .spotify: return "Spotify"
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
                Picker("Nguồn", selection: $provider) {
                    ForEach(MusicProvider.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                content
            }
            .navigationTitle("Nhạc")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $text, prompt: provider == .soundCloud ? "Tìm hoặc dán link SoundCloud" : "Tìm bài hát, nghệ sĩ")
            .onSubmit(of: .search) { submit() }
            .onChange(of: text) { if $0.isEmpty { query = "" } }
            .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") {}
            }
        }
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
        case .soundCloud:
            SoundCloudHomeView(query: query)
        case .spotify:
            SpotifyHomeView(query: query)
        }
    }

    private func submit() {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        if q.contains("soundcloud.com") {
            Task {
                do {
                    if let v = try await SoundCloud.shared.resolveLink(q) {
                        PlayerManager.shared.play(v)
                    } else {
                        message = "Link này không phải một bài hát"
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
                Text("Vidra đọc danh sách bài từ Spotify (playlist phải ở chế độ công khai) rồi phát bản tương ứng từ YouTube Music. Âm thanh gốc của Spotify có DRM nên không phát trực tiếp được.")
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
