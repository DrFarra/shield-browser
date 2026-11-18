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
        case "resume", "quality":
            // Comprueba que un VOD empieza donde se dejó y que cambiar de calidad no lo reinicia
            if let video = try? await Twitch.channel("ibai", withVideos: true)?.videos?.nodes.first {
                library.recordWatch(video, position: 3000)
                playback.play(.video(video.id))
                try? await Task.sleep(for: .seconds(12))
                if screen == "quality", let low = playback.engine.qualities.dropFirst(2).first {
                    playback.engine.setQuality(low.name)
                    try? await Task.sleep(for: .seconds(10))
                }
                playback.engine.togglePlay()
            }
        case "scrub":
            if let video = try? await Twitch.channel("ibai", withVideos: true)?.videos?.nodes.first {
                library.removeWatched(video.id)
                playback.play(.video(video.id))
                try? await Task.sleep(for: .seconds(12))
                playback.engine.togglePlay()
                playback.engine.demoScrub = playback.engine.duration * 0.6
            }
        case "chatstyles":
            if let login {
                playback.play(.live(login))
                try? await Task.sleep(for: .seconds(8))
                playback.chat.injectForDemo([
                    "@display-name=Lumen_88;login=lumen_88;color=#9ACD32;msg-id=resub;system-msg=Lumen_88\\ssubscribed\\sat\\sTier\\s1.\\sThey've\\ssubscribed\\sfor\\s14\\smonths! :tmi.twitch.tv USERNOTICE #demo :14 meses ya, qué rápido",
                    "@display-name=NubeRoja;login=nuberoja;msg-id=submysterygift;system-msg=NubeRoja\\sis\\sgifting\\s5\\sTier\\s1\\sSubs\\sto\\sthe\\scommunity! :tmi.twitch.tv USERNOTICE #demo",
                    "@display-name=Tomi;login=tomi;color=#FF7F50;reply-parent-display-name=Lumen_88;reply-parent-msg-body=14\\smeses\\sya,\\squé\\srápido :tomi!tomi@tomi.tmi.twitch.tv PRIVMSG #demo :@Lumen_88 felicidades!",
                    "@display-name=PixelNorte;login=pixelnorte;msg-id=raid;system-msg=230\\sraiders\\sfrom\\sPixelNorte\\shave\\sjoined! :tmi.twitch.tv USERNOTICE #demo",
                    "@display-name=Sara;login=sara;color=#DA70D6 :sara!sara@sara.tmi.twitch.tv PRIVMSG #demo :el clip está acá https://clips.twitch.tv/ejemplo",
                    "@display-name=ModeradorX;login=moderadorx;color=#1E90FF;msg-id=announcement;system-msg= :tmi.twitch.tv USERNOTICE #demo :Sorteo a las 22:00, atentos",
                    "@display-name=Marco;login=marco;color=#20B2AA;msg-id=highlighted-message :marco!marco@marco.tmi.twitch.tv PRIVMSG #demo :mensaje destacado con puntos del canal",
                    "@display-name=Vale;login=vale;bits=500;color=#FFD700 :vale!vale@vale.tmi.twitch.tv PRIVMSG #demo :Cheer500 vamos!",
                ])
                // Se pausa el chat para que los mensajes reales no los saquen de pantalla antes de la captura
                try? await Task.sleep(for: .seconds(2))
                playback.chat.paused = true
            }
        case "muted", "mutedbar":
            // VOD con tramos silenciados: se empieza dentro de uno para ver la barra y el botón de saltar
            if let video = try? await Twitch.video("2928776581") {
                library.recordWatch(video, position: 5070)
                playback.play(.video(video.id))
                try? await Task.sleep(for: .seconds(12))
                playback.engine.togglePlay()
                // Con el dedo en otro punto, el tramo ámbar de la barra queda a la vista
                if screen == "mutedbar" { playback.engine.demoScrub = playback.engine.duration * 0.6 }
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
