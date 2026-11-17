import Foundation

/// Solo para las capturas automáticas en CI (tools/glint_screenshots.sh):
/// la app se abre con `-glintDemo <pantalla>` y se prepara sola.
enum Demo {
    static let screen: String? = {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-glintDemo"), index + 1 < args.count else { return nil }
        return args[index + 1]
    }()

    @MainActor
    static func run(router: Router, playback: Playback, library: Library) async {
        guard let screen else { return }
        if library.recents.isEmpty, let channels = try? await Twitch.channels(["ibai", "rubius", "elxokas", "auronplay", "illojuan"]) {
            for channel in channels.reversed() { library.addRecent(channel.ref) }
            for channel in channels.prefix(3) { library.toggleFollow(channel.ref) }
        }
        if library.watched.isEmpty, let videos = try? await Twitch.channel("ibai", withVideos: true)?.videos?.nodes.prefix(3) {
            for (i, video) in videos.reversed().enumerated() {
                library.recordWatch(video, position: Double(video.lengthSeconds ?? 0) * [0.1, 0.35, 0.7][i])
            }
        }
        let login = (try? await Twitch.topStreams(spanishOnly: true))?.first?.broadcaster?.login
        switch screen {
        case "browse":
            router.tab = .browse
        case "search":
            router.tab = .search
        case "clip":
            if let login, let clip = try? await Twitch.clips(channel: login).first {
                playback.play(.clip(clip.slug))
            }
        case "history":
            router.home.append(.history)
        case "channel":
            if let login { router.home.append(.channel(login)) }
        case "player":
            if let login { playback.play(.live(login)) }
        case "paused":
            if let login {
                playback.play(.live(login))
                try? await Task.sleep(for: .seconds(8))
                playback.engine.togglePlay()
            }
        case "mini":
            if let login {
                playback.play(.live(login))
                try? await Task.sleep(for: .seconds(6))
                playback.minimized = true
            }
        case "vod":
            if let login, let video = try? await Twitch.channel(login, withVideos: true)?.videos?.nodes.first {
                playback.play(.video(video.id))
            }
        default:
            break
        }
    }
}
