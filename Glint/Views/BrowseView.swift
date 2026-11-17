import SwiftUI

struct BrowseView: View {
    @State private var games: [Twitch.Game] = []
    @State private var failure: String?

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12)]

    var body: some View {
        ScrollView {
            if let failure, games.isEmpty {
                ErrorState(message: failure) { await load() }
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                ForEach(games) { game in
                    NavigationLink(value: Route.game(game.name)) {
                        GameTile(game: game)
                    }
                    .buttonStyle(PressStyle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .navigationTitle("Explorar")
        .refreshable { await load() }
        .task { if games.isEmpty { await load() } }
    }

    private func load() async {
        do {
            games = try await Twitch.topGames()
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }
}

struct GameTile: View {
    let game: Twitch.Game

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.surface
                .aspectRatio(3 / 4, contentMode: .fit)
                .overlay { RemoteImage(url: game.boxArtURL) }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(game.title)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
            if let viewers = game.viewersCount {
                Text("\(Format.count(viewers)) espectadores")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.primary)
    }
}

struct CategoryView: View {
    let name: String
    @AppStorage("spanishOnly") private var spanishOnly = true
    @State private var game: Twitch.Game?
    @State private var streams: [Twitch.Stream] = []
    @State private var clips: [Twitch.Clip] = []
    @State private var loaded = false
    @State private var failure: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                header
                if let failure, streams.isEmpty {
                    ErrorState(message: failure) { await load() }
                } else if loaded, streams.isEmpty {
                    ContentUnavailableView("Nadie en directo", systemImage: "video.slash",
                                           description: Text(spanishOnly ? "Prueba con «Todos» los idiomas." : ""))
                }
                if !clips.isEmpty {
                    ClipsRow(title: "Clips de la semana", clips: clips)
                }
                if !streams.isEmpty {
                    SectionHeader("En directo")
                }
                ForEach(streams) { StreamCard(stream: $0) }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .navigationTitle(game?.title ?? name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task(id: spanishOnly) { await load() }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 16) {
            Color.surface
                .frame(width: 84, height: 112)
                .overlay { RemoteImage(url: game?.boxArtURL) }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text(game?.title ?? name).font(.title2.bold()).lineLimit(2)
                if let viewers = game?.viewersCount {
                    Text("\(Format.count(viewers)) espectadores").font(.subheadline).foregroundStyle(.secondary)
                }
                LanguageToggle()
            }
        }
        .padding(.top, 8)
    }

    private func load() async {
        do {
            async let clipList = try? Twitch.clips(game: name, spanishOnly: spanishOnly)
            let result = try await Twitch.streams(inGame: name, spanishOnly: spanishOnly)
            clips = await clipList ?? []
            game = result.game ?? game
            streams = result.streams
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        loaded = true
    }
}
