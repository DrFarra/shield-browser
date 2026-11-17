import SwiftUI

struct RemoteImage: View {
    let url: String?

    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:)), transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Rectangle().fill(Color.surface)
            }
        }
    }
}

struct Avatar: View {
    let url: String?
    var size: CGFloat = 36
    var live = false

    var body: some View {
        RemoteImage(url: url)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .padding(live ? 2.5 : 0)
            .overlay {
                if live { Circle().strokeBorder(Color.live, lineWidth: 2) }
            }
    }
}

/// Píldora de espectadores sobre las miniaturas.
struct ViewerPill: View {
    let viewers: Int?

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Color.live).frame(width: 6, height: 6)
            Text(viewers.map(Format.count) ?? "En directo")
                .monospacedDigit()
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.black.opacity(0.65), in: Capsule())
    }
}

/// Miniatura de un directo con su información. Tocar la imagen reproduce;
/// tocar el avatar abre el canal.
struct StreamCard: View {
    let stream: Twitch.Stream
    var compact = false
    @Environment(Playback.self) private var playback

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                if let login = stream.broadcaster?.login { playback.play(.live(login)) }
            } label: {
                Thumbnail(url: freshPreview)
                    .overlay(alignment: .topLeading) { ViewerPill(viewers: stream.viewersCount).padding(8) }
                    .overlay(alignment: .bottomTrailing) {
                        if let uptime = Format.uptime(since: stream.createdAt) {
                            Text(uptime)
                                .font(.caption2.weight(.medium)).monospacedDigit()
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(.black.opacity(0.65), in: Capsule())
                                .padding(8)
                        }
                    }
            }
            .buttonStyle(PressStyle())

            HStack(alignment: .top, spacing: 10) {
                if let b = stream.broadcaster {
                    NavigationLink(value: Route.channel(b.login)) {
                        Avatar(url: b.profileImageURL, size: compact ? 28 : 34)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(stream.title ?? "")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(compact ? 1 : 2)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(.primary)
    }

    private var subtitle: String {
        [stream.broadcaster?.name, stream.game?.title].compactMap { $0 }.joined(separator: " · ")
    }

    // La URL de la vista previa no cambia; se renueva cada 5 minutos para no ver una imagen vieja.
    private var freshPreview: String? {
        stream.previewImageURL.map { "\($0)?t=\(Int(Date().timeIntervalSince1970 / 300))" }
    }
}

struct Thumbnail: View {
    let url: String?
    var corner: CGFloat = 14

    var body: some View {
        Color.surface
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay { RemoteImage(url: url) }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

struct VideoRow: View {
    let video: Twitch.Video
    @Environment(Playback.self) private var playback
    @Environment(Library.self) private var library

    var body: some View {
        Button { playback.play(.video(video.id)) } label: {
            HStack(alignment: .top, spacing: 12) {
                Thumbnail(url: video.previewThumbnailURL, corner: 10)
                    .frame(width: 150)
                    .overlay(alignment: .bottomTrailing) {
                        Text(Format.clock(Double(video.lengthSeconds ?? 0)))
                            .font(.caption2.weight(.medium)).monospacedDigit()
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.black.opacity(0.7), in: Capsule())
                            .padding(6)
                    }
                    .overlay(alignment: .bottom) {
                        if let watched = library.watched(video.id) { WatchProgress(value: watched.progress) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(video.title ?? "")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text([Format.ago(video.createdAt), video.viewCount.map { "\(Format.count($0)) vistas" }]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let game = video.game?.title {
                        Text(game).font(.caption).foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .foregroundStyle(.primary)
    }
}

/// Barra fina de "hasta dónde lo viste" al pie de una miniatura.
struct WatchProgress: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.3))
                Rectangle().fill(Color.glint).frame(width: geo.size.width * value)
            }
        }
        .frame(height: 3)
    }
}

struct FollowButton: View {
    let channel: ChannelRef
    var compact = false
    @Environment(Library.self) private var library

    var body: some View {
        let following = library.isFollowing(channel.login)
        Button {
            withAnimation(.snappy) { library.toggleFollow(channel) }
            // Al seguir el primer canal se piden permisos para avisar cuando empiece directo
            if library.isFollowing(channel.login) { LiveAlerts.requestPermission() }
        } label: {
            Label(following ? "Siguiendo" : "Seguir", systemImage: following ? "heart.fill" : "heart")
                .labelStyle(.titleAndIcon)
                .font((compact ? Font.footnote : .subheadline).weight(.semibold))
                .frame(minWidth: compact ? 0 : 120)
                .padding(.horizontal, compact ? 12 : 16)
                .padding(.vertical, compact ? 7 : 9)
                .foregroundStyle(following ? Color.primary : Color.black)
                .background(following ? AnyShapeStyle(Color.surface) : AnyShapeStyle(Color.glint), in: Capsule())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(PressStyle())
        .sensoryFeedback(.selection, trigger: following)
    }
}

struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.weight(.bold))
            Spacer()
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.title = title
        self.trailing = EmptyView()
    }
}

/// Selector Español / Todos para las listas de directos.
struct LanguageToggle: View {
    @AppStorage("spanishOnly") private var spanishOnly = true

    var body: some View {
        Picker("Idioma", selection: $spanishOnly) {
            Text("Español").tag(true)
            Text("Todos").tag(false)
        }
        .pickerStyle(.segmented)
        .frame(width: 170)
    }
}

/// Encoge un poco al tocar, sin el parpadeo de opacidad del estilo por defecto.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct ErrorState: View {
    let message: String
    var retry: (() async -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label("Sin conexión con Twitch", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            if let retry {
                Button("Reintentar") { Task { await retry() } }.buttonStyle(.bordered)
            }
        }
    }
}

extension View {
    func appDestinations() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .channel(let login): ChannelView(login: login)
            case .game(let name): CategoryView(name: name)
            case .history: HistoryView()
            }
        }
    }
}

/// Tarjeta de clip para las filas horizontales.
struct ClipCard: View {
    let clip: Twitch.Clip
    @Environment(Playback.self) private var playback

    var body: some View {
        Button { playback.play(.clip(clip.slug)) } label: {
            VStack(alignment: .leading, spacing: 8) {
                Thumbnail(url: clip.thumbnailURL, corner: 12)
                    .overlay(alignment: .topLeading) {
                        if let views = clip.viewCount {
                            Label(Format.count(views), systemImage: "eye.fill")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 7).padding(.vertical, 4)
                                .background(.black.opacity(0.65), in: Capsule())
                                .padding(8)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Text(Format.clock(Double(clip.durationSeconds ?? 0)))
                            .font(.caption2.weight(.medium)).monospacedDigit()
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.black.opacity(0.65), in: Capsule())
                            .padding(8)
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(clip.title ?? "")
                        .font(.footnote.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text([clip.broadcaster?.name, Format.ago(clip.createdAt)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: 240)
        }
        .buttonStyle(PressStyle())
        .foregroundStyle(.primary)
    }
}

/// Fila horizontal de clips con su título.
struct ClipsRow: View {
    let title: String
    let clips: [Twitch.Clip]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(clips) { ClipCard(clip: $0) }
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
