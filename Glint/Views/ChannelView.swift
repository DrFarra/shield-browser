import SwiftUI

struct ChannelView: View {
    let login: String
    @Environment(Playback.self) private var playback
    @State private var channel: Twitch.Channel?
    @State private var failure: String?
    @State private var showFullBio = false
    @State private var clips: [Twitch.Clip] = []

    var body: some View {
        ScrollView {
            if let channel {
                content(channel)
            } else if let failure {
                ErrorState(message: failure) { await load() }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 120)
            }
        }
        .navigationTitle(channel?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { if channel == nil { await load() } }
    }

    private func content(_ channel: Twitch.Channel) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            header(channel)

            if let stream = channel.stream {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader("En directo")
                    StreamCard(stream: stream.withBroadcaster(channel))
                }
                .padding(.horizontal, 16)
            }

            if !clips.isEmpty {
                ClipsRow(title: "Clips del mes", clips: clips)
                    .padding(.horizontal, 16)
            }

            let videos = channel.videos?.nodes ?? []
            if !videos.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader("Emisiones anteriores")
                    ForEach(videos) { VideoRow(video: $0) }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.bottom, 24)
    }

    private func header(_ channel: Twitch.Channel) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Color.surface
                .frame(height: 120)
                .overlay {
                    if channel.bannerImageURL != nil { RemoteImage(url: channel.bannerImageURL) }
                }
                .overlay {
                    LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                }
                .clipped()
                .overlay(alignment: .bottomLeading) {
                    Avatar(url: channel.profileImageURL, size: 76, live: channel.stream != nil)
                        .background(Circle().fill(.black).padding(-3))
                        .padding(.leading, 16)
                        .offset(y: 38)
                }
                .padding(.bottom, 30)

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.name).font(.title2.bold())
                    if let followers = channel.followers?.totalCount {
                        Text("\(Format.count(followers)) seguidores").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                FollowButton(channel: channel.ref)
            }
            .padding(.horizontal, 16)

            if let bio = channel.description, !bio.isEmpty {
                Text(bio)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(showFullBio ? nil : 2)
                    .padding(.horizontal, 16)
                    .onTapGesture { withAnimation(.snappy) { showFullBio.toggle() } }
            }
        }
    }

    private func load() async {
        do {
            async let clipList = try? Twitch.clips(channel: login)
            channel = try await Twitch.channel(login, withVideos: true)
            clips = await clipList ?? []
            failure = channel == nil ? "Este canal no existe" : nil
        } catch {
            failure = error.localizedDescription
        }
    }
}

extension Twitch.Stream {
    /// La consulta de canal no repite el emisor dentro del directo.
    func withBroadcaster(_ channel: Twitch.Channel) -> Twitch.Stream {
        guard broadcaster == nil else { return self }
        return Twitch.Stream(id: id, title: title, viewersCount: viewersCount, createdAt: createdAt,
                             previewImageURL: previewImageURL, game: game,
                             broadcaster: Twitch.Broadcaster(login: channel.login, displayName: channel.displayName,
                                                             profileImageURL: channel.profileImageURL, userID: channel.userID),
                             archiveVideo: archiveVideo)
    }
}
