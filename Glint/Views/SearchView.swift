import SwiftUI

struct SearchView: View {
    @Environment(Library.self) private var library
    @Environment(Router.self) private var router
    @State private var query = ""
    @State private var channels: [Twitch.Channel] = []
    @State private var games: [Twitch.Game] = []
    @State private var searching = false
    /// Estado en directo de los canales del historial.
    @State private var liveRecents: [String: Twitch.Stream] = [:]

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        List {
            if trimmed.isEmpty {
                recentSection
            } else {
                resultSections
            }
        }
        .listStyle(.plain)
        .navigationTitle("Buscar")
        .searchable(text: $query, prompt: "Canales y categorías")
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .task(id: trimmed) { await search() }
        .task(id: library.recents) { await loadRecentStatus() }
        .overlay {
            if !trimmed.isEmpty, !searching, channels.isEmpty, games.isEmpty {
                ContentUnavailableView.search(text: trimmed)
            } else if trimmed.isEmpty, library.recents.isEmpty {
                ContentUnavailableView("Busca un canal", systemImage: "magnifyingglass",
                                       description: Text("Los canales que abras aparecerán aquí para volver a ellos con un toque."))
            }
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        if !library.recents.isEmpty {
            Section {
                ForEach(library.recents) { channel in
                    ChannelRow(name: channel.displayName, avatar: channel.avatar, stream: liveRecents[channel.login], followers: nil) {
                        open(channel)
                    }
                    .swipeActions {
                        Button("Quitar", systemImage: "xmark", role: .destructive) {
                            withAnimation { library.removeRecent(channel.login) }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Recientes")
                    Spacer()
                    Button("Borrar") { withAnimation { library.clearRecents() } }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.glint)
                }
            }
        }
    }

    @ViewBuilder
    private var resultSections: some View {
        if !channels.isEmpty {
            Section("Canales") {
                ForEach(channels) { channel in
                    ChannelRow(name: channel.name, avatar: channel.profileImageURL, stream: channel.stream,
                               followers: channel.followers?.totalCount) {
                        open(channel.ref)
                    }
                }
            }
        }
        if !games.isEmpty {
            Section("Categorías") {
                ForEach(games.prefix(8)) { game in
                    Button { router.search.append(.game(game.name)) } label: {
                        HStack(spacing: 12) {
                            Color.surface.frame(width: 36, height: 48)
                                .overlay { RemoteImage(url: game.boxArtURL) }
                                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(game.title).font(.body.weight(.medium))
                                if let viewers = game.viewersCount, viewers > 0 {
                                    Text("\(Format.count(viewers)) espectadores").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func open(_ channel: ChannelRef) {
        library.addRecent(channel)
        router.search.append(.channel(channel.login))
    }

    private func search() async {
        guard !trimmed.isEmpty else {
            channels = []
            games = []
            return
        }
        searching = true
        defer { searching = false }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled, let result = try? await Twitch.search(trimmed), !Task.isCancelled else { return }
        // Los que están en directo, primero
        channels = result.channels.enumerated().sorted { a, b in
            if (a.element.stream != nil) != (b.element.stream != nil) { return a.element.stream != nil }
            return a.offset < b.offset
        }.map(\.element)
        games = result.games
    }

    private func loadRecentStatus() async {
        guard let channels = try? await Twitch.channels(library.recents.map(\.login)) else { return }
        liveRecents = Dictionary(channels.compactMap { c in c.stream.map { (c.login, $0) } }, uniquingKeysWith: { a, _ in a })
    }
}

/// Fila de canal con avatar, estado en directo y lo que está emitiendo.
struct ChannelRow: View {
    let name: String
    let avatar: String?
    let stream: Twitch.Stream?
    let followers: Int?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Avatar(url: avatar, size: 44, live: stream != nil)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.body.weight(.semibold))
                    if let stream {
                        HStack(spacing: 5) {
                            Circle().fill(Color.live).frame(width: 6, height: 6)
                            Text([stream.game?.title, stream.viewersCount.map(Format.count)].compactMap { $0 }.joined(separator: " · "))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else if let followers {
                        Text("\(Format.count(followers)) seguidores").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Sin conexión").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
