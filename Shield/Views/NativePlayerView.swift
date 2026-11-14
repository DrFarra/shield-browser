import AVKit
import SwiftUI
import WebKit

/// Reproductor del iPhone (AVPlayer) para cualquier vídeo de la web, con
/// descarga, Picture in Picture y AirPlay. Se envían el Referer, el User-Agent
/// y las cookies de la página para que el servidor acepte la petición.
struct NativePlayerView: View {
    let video: NativeVideo
    let webView: WKWebView
    let onClose: () -> Void
    var onUseWebPlayer: () -> Void = {}

    @State private var drag: CGFloat = 0
    @State private var player: AVPlayer?
    @State private var downloadStarted = false
    @State private var failure: String?
    @State private var statusObservation: NSKeyValueObservation?

    var body: some View {
        let progress = min(max(drag / 300, 0), 1)
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Button { onClose() } label: {
                    Image(systemName: "chevron.down").font(.title3.bold())
                }
                Text(video.title.isEmpty ? (video.url.host() ?? "Vídeo") : video.title)
                    .font(.subheadline)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Menu {
                    Button { startDownload() } label: {
                        Label("Descargar vídeo", systemImage: "arrow.down.circle")
                    }
                    ShareLink(item: video.url) { Label("Compartir enlace del vídeo", systemImage: "link") }
                    Divider()
                    Button {
                        onUseWebPlayer()
                        onClose()
                    } label: {
                        Label("Usar el reproductor de la web", systemImage: "globe")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                }
                Button { startDownload() } label: {
                    Image(systemName: downloadStarted ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                        .font(.title2)
                        .foregroundStyle(downloadStarted ? Color.green : Color.shield)
                }
                .disabled(downloadStarted)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .gesture(DragGesture()
                .onChanged { dragChanged($0.translation.height) }
                .onEnded { dragEnded($0.translation.height, velocity: $0.velocity.height) })

            ZStack {
                if let player {
                    PlayerController(player: player, onDrag: dragChanged, onDragEnd: dragEnded)
                } else if failure == nil {
                    ProgressView().tint(.white)
                }
                if let failure {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                        Text(failure).multilineTextAlignment(.center)
                        Button("Descargar de todos modos") { startDownload() }
                            .buttonStyle(.borderedProminent).tint(.shield)
                    }
                    .foregroundStyle(.white)
                    .padding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if downloadStarted {
                Text("Descargando… lo verás en Descargas y en Fotos")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.vertical, 8)
            }
        }
        // Arrastrar hacia abajo: el vídeo sigue al dedo, encoge y deja ver la web.
        .offset(y: drag)
        .scaleEffect(1 - progress * 0.12)
        .background(Color.black.opacity(1 - progress * 0.7).ignoresSafeArea())
        .accessibilityAction(.escape) { onClose() }
        .task { await load() }
        .onDisappear {
            player?.pause()
            // Devuelve el sonido al vídeo de la web y deja de forzar la pausa.
            webView.evaluateJavaScript("window.__shieldRelease && window.__shieldRelease(); 0",
                                       completionHandler: nil)
        }
    }

    private func dragChanged(_ y: CGFloat) { drag = max(y, 0) }

    private func dragEnded(_ y: CGFloat, velocity: CGFloat) {
        if y > 120 || velocity > 900 {
            onClose()
        } else {
            withAnimation(.snappy(duration: 0.25)) { drag = 0 }
        }
    }

    private func startDownload() {
        guard !downloadStarted else { return }
        downloadStarted = true
        DownloadManager.shared.download(video.asMedia, from: webView)
    }

    private func load() async {
        let newPlayer = await video.makePlayer(for: webView)
        statusObservation = newPlayer.currentItem?.observe(\.status) { item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? "error desconocido"
            Task { @MainActor in
                failure = "No se pudo reproducir aquí (\(message))."
                player = nil
            }
        }
        player = newPlayer
        newPlayer.play()
    }
}

extension NativeVideo {
    /// AVPlayer con el Referer, el User-Agent y las cookies de la página.
    @MainActor
    func makePlayer(for webView: WKWebView) async -> AVPlayer {
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let userAgent = try? await webView.evaluateJavaScript("navigator.userAgent") as? String
        var headers: [String: String] = [:]
        if let page = pageURL ?? webView.url { headers["Referer"] = page.absoluteString }
        if let userAgent { headers["User-Agent"] = userAgent }

        let asset = AVURLAsset(url: url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": headers,
            AVURLAssetHTTPCookiesKey: cookies,
        ])
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        if startTime > 1 {
            _ = await player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600))
        }
        // La web puede haber desactivado la sesión de audio al pausar su vídeo.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.isMuted = false
        return player
    }
}

/// Reproductor del iPhone colocado dentro de la página, justo encima del vídeo
/// de la web: es una subvista del scroll, así que se desplaza con el contenido.
@MainActor
final class InlinePlayerView: UIView {
    private let controller = AVPlayerViewController()
    private let menuButton = UIButton(configuration: .glass())
    private let video: NativeVideo
    private weak var tab: BrowserTab?
    private var statusObservation: NSKeyValueObservation?
    private var hideMenu: Task<Void, Never>?

    init(video: NativeVideo, tab: BrowserTab) {
        self.video = video
        self.tab = tab
        super.init(frame: .zero)
        backgroundColor = .black
        clipsToBounds = true
        controller.allowsPictureInPicturePlayback = true
        controller.updatesNowPlayingInfoCenter = true
        controller.view.frame = bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(controller.view)

        menuButton.configuration?.image = UIImage(systemName: "ellipsis")
        menuButton.tintColor = .white
        menuButton.accessibilityLabel = "Opciones del vídeo"
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.menu = UIMenu(children: [
            UIAction(title: "Descargar vídeo", image: UIImage(systemName: "arrow.down.circle")) { [weak self] _ in
                guard let self, let tab = self.tab else { return }
                DownloadManager.shared.download(self.video.asMedia, from: tab.webView)
            },
            UIAction(title: "Usar el reproductor de la web", image: UIImage(systemName: "globe")) { [weak self] _ in
                self?.tab?.setNativePlayer(false)
                self?.tab?.closeInlinePlayer()
            },
            UIAction(title: "Cerrar", image: UIImage(systemName: "xmark")) { [weak self] _ in
                self?.tab?.closeInlinePlayer()
            },
        ])
        menuButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(menuButton)
        // Bajo el botón de volumen del sistema, único hueco libre de sus controles.
        NSLayoutConstraint.activate([
            menuButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            menuButton.topAnchor.constraint(equalTo: topAnchor, constant: 56),
        ])
        let tap = UITapGestureRecognizer(target: self, action: #selector(flashMenu))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        addGestureRecognizer(tap)
        flashMenu()

        Task { [weak self] in
            guard let webView = self?.tab?.webView else { return }
            let player = await video.makePlayer(for: webView)
            guard let self, self.superview != nil else { return }
            self.statusObservation = player.currentItem?.observe(\.status) { [weak self] item, _ in
                guard item.status == .failed else { return }
                Task { @MainActor in self?.failed() }
            }
            self.controller.player = player
            player.play()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) no se usa") }

    /// Si aquí no se puede reproducir, se abre la capa completa, que explica el fallo y ofrece descargar.
    private func failed() {
        guard let tab else { return }
        tab.closeInlinePlayer()
        tab.nativeVideo = video
    }

    /// El botón de opciones aparece al tocar el vídeo, como los controles del sistema.
    @objc private func flashMenu() {
        hideMenu?.cancel()
        UIView.animate(withDuration: 0.2) { self.menuButton.alpha = 1 }
        hideMenu = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            UIView.animate(withDuration: 0.3) { self?.menuButton.alpha = 0 }
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let root = window?.rootViewController {
            // Con un controlador padre el botón de pantalla completa del sistema funciona.
            if controller.parent == nil {
                root.addChild(controller)
                controller.didMove(toParent: root)
            }
        } else {
            controller.player?.pause()   // pestaña en segundo plano
        }
    }

    func close() {
        hideMenu?.cancel()
        statusObservation = nil
        controller.player?.pause()
        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        removeFromSuperview()
    }
}

extension InlinePlayerView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

private struct PlayerController: UIViewControllerRepresentable {
    let player: AVPlayer
    let onDrag: (CGFloat) -> Void
    let onDragEnd: (CGFloat, CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.updatesNowPlayingInfoCenter = true
        controller.entersFullScreenWhenPlaybackBegins = false
        controller.delegate = context.coordinator
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.delegate = context.coordinator
        controller.view.addGestureRecognizer(pan)
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        context.coordinator.parent = self
        if controller.player !== player { controller.player = player }
    }

    /// Gesto de arrastrar hacia abajo para cerrar, conviviendo con los controles del sistema.
    final class Coordinator: NSObject, UIGestureRecognizerDelegate, AVPlayerViewControllerDelegate {
        var parent: PlayerController
        private var fullScreen = false   // a pantalla completa el gesto de salir es el del sistema

        init(_ parent: PlayerController) { self.parent = parent }

        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            // En coordenadas de la ventana: la vista se mueve con el dedo.
            let y = gesture.translation(in: nil).y
            switch gesture.state {
            case .changed: parent.onDrag(y)
            case .ended: parent.onDragEnd(y, gesture.velocity(in: nil).y)
            case .cancelled, .failed: parent.onDragEnd(0, 0)
            default: break
            }
        }

        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard !fullScreen, let pan = gesture as? UIPanGestureRecognizer else { return false }
            let v = pan.velocity(in: nil)
            return v.y > abs(v.x)   // sólo hacia abajo: la barra de progreso es horizontal
        }

        func gestureRecognizer(_ gesture: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        func playerViewController(_ playerViewController: AVPlayerViewController,
                                  willBeginFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
            fullScreen = true
        }

        func playerViewController(_ playerViewController: AVPlayerViewController,
                                  willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
            coordinator.animate(alongsideTransition: nil) { [weak self] context in
                if !context.isCancelled { self?.fullScreen = false }
            }
        }
    }
}
