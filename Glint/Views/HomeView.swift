import SwiftUI

struct HomeView: View {
    @Environment(Library.self) private var library
    @Environment(Playback.self) private var playback
    @AppStorage("spanishOnly") private var spanishOnly = true
    @State private var streams: [Twitch.Stream] = []
    @State private var followed: [Twitch.Channel] = []
    @State private var failure: String?

    private var liveFollowed: [Twitch.Stream] {
        followed.compactMap(\.stream).sorted { ($0.viewersCount ?? 0) > ($1.viewersCount ?? 0) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if !library.follows.isEmpty {
                    followingSection
                }

                if !library.watched.isEmpty {
                    continueSection
                }

                VStack(alignment: .leading, spacing: 16) {
                    SectionHeader(title: "Populares") { LanguageToggle() }
                    if let failure, streams.isEmpty {
                        ErrorState(message: failure) { await loadStreams() }
                    } else if streams.isEmpty {
                        ForEach(0..<3, id: \.self) { _ in Thumbnail(url: nil).redacted(reason: .placeholder) }
                    }
                    ForEach(streams) { stream in
                        StreamCard(stream: stream)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .navigationTitle("Inicio")
        .refreshable {
            await loadStreams()
            await loadFollowed()
        }
        .task(id: spanishOnly) { await loadStreams() }
        .task(id: library.follows) { await loadFollowed() }
    }

    @ViewBuilder
    private var followingSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader("Siguiendo")
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(followedSorted) { channel in
                        NavigationLink(value: Route.channel(channel.login)) {
                            VStack(spacing: 6) {
                                Avatar(url: channel.profileImageURL, size: 58, live: channel.stream != nil)
                                    .saturation(channel.stream == nil ? 0 : 1)
                                    .opacity(channel.stream == nil ? 0.6 : 1)
                                Text(channel.name)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .foregroundStyle(channel.stream == nil ? .secondary : .primary)
                            }
                            .frame(width: 70)
                        }
                        .buttonStyle(PressStyle())
                    }
                }
            }
            .scrollIndicators(.hidden)
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .padding(.horizontal, -16)

            if !liveFollowed.isEmpty {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(liveFollowed) { stream in
                            StreamCard(stream: stream, compact: true).frame(width: 280)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned)
                .contentMargins(.horizontal, 16, for: .scrollContent)
                .padding(.horizontal, -16)
            }
        }
    }

    /// VOD empezados, para retomarlos donde se dejaron.
    private var continueSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Seguir viendo") {
                NavigationLink("Historial", value: Route.history)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.glint)
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(library.watched.prefix(12)) { item in
                        Button { playback.play(.video(item.id)) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                WatchedThumbnail(item: item)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).font(.footnote.weight(.semibold)).lineLimit(1)
                                    Text(item.channel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .frame(width: 220)
                        }
                        .buttonStyle(PressStyle())
                        .foregroundStyle(.primary)
                        .contextMenu {
                            Button("Quitar del historial", systemImage: "trash", role: .destructive) {
                                withAnimation { library.removeWatched(item.id) }
                            }
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .padding(.horizontal, -16)
        }
    }

    /// En directo primero; el resto en el orden en que se siguieron.
    private var followedSorted: [Twitch.Channel] {
        let order = Dictionary(uniqueKeysWithValues: library.follows.enumerated().map { ($1.login, $0) })
        return followed.sorted { a, b in
            if (a.stream != nil) != (b.stream != nil) { return a.stream != nil }
            return order[a.login, default: 0] < order[b.login, default: 0]
        }
    }

    private func loadStreams() async {
        do {
            streams = try await Twitch.topStreams(spanishOnly: spanishOnly)
            failure = nil
        } catch {
            if !(error is CancellationError) { failure = error.localizedDescription }
        }
    }

    private func loadFollowed() async {
        if let channels = try? await Twitch.channels(library.follows.map(\.login)) {
            followed = channels
        }
    }
}
