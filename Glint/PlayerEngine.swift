import AVKit
import Observation
import UIKit

/// Envoltorio de AVPlayer con una sola línea de tiempo para todo el directo.
///
/// El HLS en directo de Twitch solo guarda ~30 s. Para ir más atrás se cambia al
/// VOD que Twitch graba mientras se emite (lista EVENT que va creciendo), en el
/// mismo punto de la emisión. Volver al final de la barra regresa al directo.
@MainActor @Observable
final class PlayerEngine {
    enum Mode { case live, archive, vod }

    let player = AVPlayer()
    private(set) var mode: Mode = .vod
    /// Segundos desde el inicio de la emisión (o del vídeo).
    private(set) var position: Double = 0
    /// Duración del vídeo, o lo que lleva la emisión.
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    private(set) var isBuffering = true
    private(set) var qualities: [Twitch.Quality] = []
    private(set) var error: String?
    /// Nombre de la calidad elegida; nil = automática.
    private(set) var quality: String? = UserDefaults.standard.string(forKey: "quality")
    private(set) var rate: Float = 1
    /// Se está cambiando de conexión para saltarse un anuncio.
    private(set) var skippingAd = false
    var fill = false { didSet { layer?.videoGravity = fill ? .resizeAspectFill : .resizeAspect } }

    /// Miniaturas para la barra de un VOD.
    private(set) var storyboard: Storyboard?
    /// Tramos del VOD con el audio silenciado.
    private(set) var muted: [Range<Double>] = []

    /// Tramo silenciado en el que está la reproducción ahora mismo.
    var currentMuted: Range<Double>? {
        guard mode == .vod, !muted.isEmpty else { return nil }
        return muted.first { $0.contains(position) && $0.upperBound - position > 2 }
    }
    /// Solo para las capturas de CI: simula el dedo en la barra.
    var demoScrub: Double?

    var isLive: Bool { mode != .vod }
    var atLiveEdge: Bool { mode == .live && duration - position < 15 }
    var canRewind: Bool { mode != .live || archiveID != nil }

    @ObservationIgnored private var login = ""
    @ObservationIgnored private var videoID = ""
    /// Un clip se reproduce como un vídeo corto (modo .vod) desde su MP4.
    @ObservationIgnored private var clipSlug: String?
    /// Mientras se cambia de vídeo y se salta a su punto, la posición no se toca
    /// (si no, por un momento valdría 0 y se guardaría ese 0 en el historial).
    @ObservationIgnored private var settling = false
    /// Tipo de reproductor con el que se pide el directo (ver Twitch.adFreePlayerTypes).
    @ObservationIgnored private var playerAttempt = 0
    @ObservationIgnored private var adTask: Task<Void, Never>?
    /// Reconexiones seguidas por el mismo anuncio; vuelve a 0 cuando la lista sale limpia.
    @ObservationIgnored private var adReconnects = 0
    @ObservationIgnored private var startedAt: Date?
    @ObservationIgnored private var archiveID: String?
    @ObservationIgnored private var master: URL?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObserver: NSKeyValueObservation?
    @ObservationIgnored private var itemObserver: NSKeyValueObservation?
    @ObservationIgnored private weak var layer: AVPlayerLayer?
    @ObservationIgnored private var pip: AVPictureInPictureController?

    init() {
        player.allowsExternalPlayback = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        statusObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in self?.syncStatus() }
        }
    }

    // MARK: - Cargar

    func startLive(login: String, startedAt: Date?, archiveID: String?) {
        self.login = login
        self.startedAt = startedAt
        self.archiveID = archiveID
        rate = 1
        load(.live, at: nil)
    }

    func startVOD(id: String, length: Double, at offset: Double? = nil) {
        videoID = id
        clipSlug = nil
        Task { [weak self] in
            async let mutedRanges = try? Twitch.mutedSegments(id)
            let board = await Storyboard.load(videoID: id)
            let ranges = await mutedRanges ?? []
            if self?.videoID == id, self?.clipSlug == nil {
                self?.storyboard = board
                self?.muted = ranges
            }
        }
        startedAt = nil
        archiveID = nil
        duration = length
        load(.vod, at: offset)
    }

    /// El VOD de la emisión puede aparecer unos minutos después de empezar.
    func updateArchive(_ id: String?) {
        if let id { archiveID = id }
    }

    func goLive() {
        rate = 1
        player.defaultRate = 1
        load(.live, at: nil)
    }

    func retry() {
        load(mode, at: mode == .live ? nil : position)
    }

    func startClip(slug: String, length: Double) {
        clipSlug = slug
        videoID = ""
        startedAt = nil
        archiveID = nil
        duration = length
        load(.vod, at: nil)
    }

    func stop() {
        loadTask?.cancel()
        adTask?.cancel()
        skippingAd = false
        playerAttempt = 0
        adReconnects = 0
        storyboard = nil
        muted = []
        player.replaceCurrentItem(with: nil)
        itemObserver = nil
        qualities = []
        error = nil
        position = 0
        duration = 0
        fill = false
        if pip?.isPictureInPictureActive == true { pip?.stopPictureInPicture() }
    }

    private func load(_ newMode: Mode, at offset: Double?) {
        loadTask?.cancel()
        error = nil
        isBuffering = true
        loadTask = Task {
            do {
                let playlist: Twitch.Playlist
                switch newMode {
                case .live: playlist = try await adFreeLivePlaylist()
                case .archive: playlist = try await Twitch.videoPlaylist(archiveID ?? "")
                case .vod:
                    if let clipSlug {
                        playlist = try await Twitch.clipPlaylist(clipSlug)
                    } else {
                        playlist = try await Twitch.videoPlaylist(videoID)
                    }
                }
                try Task.checkCancellation()
                master = playlist.url
                qualities = playlist.qualities
                mode = newMode
                if let offset { position = offset }
                skippingAd = false
                if newMode == .live { watchForAds() } else { adTask?.cancel() }
                await replaceItem(at: offset)
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
                isBuffering = false
            }
        }
    }

    // MARK: - Anuncios

    /// Lista del directo sin anuncio: si la que da Twitch empieza con uno, se pide con
    /// otro tipo de reproductor antes de empezar a reproducir.
    private func adFreeLivePlaylist() async throws -> Twitch.Playlist {
        var playlist = try await Twitch.livePlaylist(login, attempt: playerAttempt)
        for _ in 1..<Twitch.adFreePlayerTypes.count {
            guard let probe = playlist.qualities.first?.url,
                  let text = try? await Twitch.text(probe), Twitch.hasAds(text) else { break }
            playerAttempt += 1
            playlist = try await Twitch.livePlaylist(login, attempt: playerAttempt)
        }
        return playlist
    }

    /// Mientras se ve un directo, mira cada pocos segundos si ha empezado un anuncio a mitad
    /// de emisión; si es así, vuelve a conectar con otro tipo de reproductor (un parón de un
    /// segundo en vez del anuncio entero). Si todos traen el anuncio, se deja estar.
    private func watchForAds() {
        adTask?.cancel()
        adTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, mode == .live,
                      let url = qualities.first(where: { $0.name == quality })?.url ?? qualities.first?.url,
                      let text = try? await Twitch.text(url), !Task.isCancelled else { continue }
                if !Twitch.hasAds(text) {
                    adReconnects = 0
                } else if adReconnects < Twitch.adFreePlayerTypes.count - 1 {
                    adReconnects += 1
                    playerAttempt += 1
                    skippingAd = true
                    load(.live, at: nil)
                    return
                }
            }
        }
    }

    private var streamURL: URL? {
        qualities.first { $0.name == quality }?.url ?? master
    }

    private func replaceItem(at offset: Double?) async {
        guard let url = streamURL else { return }
        let item = AVPlayerItem(url: url)
        itemObserver = item.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? "No se pudo reproducir"
            Task { @MainActor in self?.error = message }
        }
        settling = true
        defer { settling = false }
        player.pause()
        player.replaceCurrentItem(with: item)
        if let offset, offset > 0 {
            await item.readyToPlay()
            guard player.currentItem === item else { return }
            // Los VOD de Twitch son listas EVENT: a veces el primer salto no se aplica, así que se comprueba
            let target = CMTime(seconds: offset, preferredTimescale: 600)
            let tolerance = CMTime(seconds: 1, preferredTimescale: 600)
            for _ in 0..<5 {
                await player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance)
                if abs(player.currentTime().seconds - offset) < 5 { break }
                try? await Task.sleep(for: .milliseconds(300))
            }
            position = offset
        }
        player.defaultRate = mode == .live ? 1 : rate
        player.play()
    }

    // MARK: - Controles

    func togglePlay() {
        if isPlaying { player.pause() } else { player.play() }
    }

    func skip(_ seconds: Double) {
        seek(to: position + seconds)
    }

    func seek(to target: Double) {
        let target = min(max(0, target), duration)
        switch mode {
        case .vod:
            seekItem(to: target)
        case .archive:
            // Pegado al final: el VOD va ~30 s por detrás, mejor el directo.
            if duration - target < 45 { goLive() } else { seekItem(to: target) }
        case .live:
            guard let range = player.currentItem?.seekableTimeRanges.last?.timeRangeValue else { return }
            let back = duration - target
            let end = range.end.seconds
            if back < range.duration.seconds - 2 || archiveID == nil {
                position = target
                seekItem(to: max(range.start.seconds, end - max(back, 6)), updatePosition: false)
            } else {
                load(.archive, at: target)
            }
        }
    }

    private func seekItem(to t: Double, updatePosition: Bool = true) {
        if updatePosition { position = t }
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    func setQuality(_ name: String?) {
        quality = name
        UserDefaults.standard.set(name, forKey: "quality")
        let resume = mode == .live ? nil : position
        Task { await replaceItem(at: resume) }
    }

    func setRate(_ value: Float) {
        rate = value
        player.defaultRate = value
        if isPlaying { player.rate = value }
    }

    // MARK: - Imagen y Picture in Picture

    func attach(_ layer: AVPlayerLayer) {
        layer.player = player
        layer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        self.layer = layer
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        pip = AVPictureInPictureController(playerLayer: layer)
        pip?.canStartPictureInPictureAutomaticallyFromInline = true
    }

    var supportsPiP: Bool { pip != nil }

    func togglePiP() {
        guard let pip else { return }
        if pip.isPictureInPictureActive { pip.stopPictureInPicture() } else { pip.startPictureInPicture() }
    }

    // MARK: - Estado

    private func tick() {
        guard !settling, let item = player.currentItem else { return }
        let t = player.currentTime().seconds
        guard t.isFinite else { return }
        let elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        switch mode {
        case .vod:
            position = t
            if item.duration.seconds.isFinite, item.duration.seconds > 0 { duration = item.duration.seconds }
        case .archive:
            position = t
            duration = max(elapsed, t)
        case .live:
            let end = item.seekableTimeRanges.last?.timeRangeValue.end.seconds ?? t
            duration = elapsed
            position = max(0, elapsed - max(0, end - t))
        }
    }

    private func syncStatus() {
        isPlaying = player.timeControlStatus != .paused
        isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        UIApplication.shared.isIdleTimerDisabled = isPlaying
    }
}

private extension AVPlayerItem {
    /// Espera a que el vídeo pueda empezar (máx. 15 s). Se consulta el estado
    /// directamente porque el aviso por KVO no siempre llega con estas listas.
    func readyToPlay() async {
        for _ in 0..<300 where status == .unknown {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
