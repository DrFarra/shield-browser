import SwiftUI
import WebKit

@MainActor
final class BrowserTab: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    let isPrivate: Bool
    let webView: WKWebView

    @Published var title = ""
    @Published var url: URL?
    @Published var progress: Double = 0
    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var cosmeticBlocked = 0
    @Published private(set) var shieldsActive = true
    @Published var media: [MediaItem] = []
    @Published var blockedPopup: URL?
    @Published var popupsBlocked = 0
    /// Últimas direcciones bloqueadas al tocar en esta página (para poder abrirlas a mano).
    @Published private(set) var blockedURLs: [URL] = []
    /// Color de fondo de la página: rellena el hueco bajo el panel para que no quede un recuadro.
    @Published private(set) var pageColor: Color?
    /// Diagnóstico del último enlace tocado: dirección y qué hizo Shield / la web con él.
    @Published private(set) var lastLink: (url: String, notes: [String])?
    /// Vídeo en la capa a pantalla completa (cuando no se puede colocar dentro de la página).
    @Published var nativeVideo: NativeVideo?
    /// Vídeo que espera a que shield.js diga en qué parte de la página está.
    private var pendingVideo: NativeVideo?
    private var inlinePlayer: InlinePlayerView?
    /// Miniatura para la vista de pestañas.
    @Published var snapshot: UIImage?
    /// Pedir la versión de escritorio de las páginas en esta pestaña.
    @Published private(set) var desktopMode = false

    /// Lo asigna TabManager para abrir ventanas nuevas como pestañas.
    var onOpenInNewTab: ((URLRequest) -> Void)?
    /// Pestaña desde la que se abrió esta (enlace en pestaña nueva).
    weak var opener: BrowserTab?
    var onBackToOpener: (() -> Void)?
    /// Lo asigna TabManager: si es la pestaña que se está viendo.
    var isForeground: () -> Bool = { true }

    /// Para frenar redirecciones a anuncios que la web lanza sola (ver `isAdRedirect`).
    private var backAt: Date?
    private var lastTapAt = Date.distantPast

    private var observations: [NSKeyValueObservation] = []
    private var appliedShields: Bool?
    private var approvedPopups: [String: Date] = [:]
    private var popupBannerTask: Task<Void, Never>?
    /// Sólo shield.js la conoce (la borra de window antes de que corran los scripts de la web).
    private let linkToken = UUID().uuidString
    /// Pestaña restaurada al abrir la app: se carga cuando se muestra por primera vez.
    private var pendingRestore: SavedTab?

    init(isPrivate: Bool) {
        self.isPrivate = isPrivate
        let config = WKWebViewConfiguration()
        config.websiteDataStore = isPrivate ? .nonPersistent() : .default()
        config.allowsInlineMediaPlayback = true
        config.ignoresViewportScaleLimits = true                     // zoom aunque la web lo bloquee, como Safari
        config.mediaTypesRequiringUserActionForPlayback = .all      // sin autoplay
        config.upgradeKnownHostsToHTTPS = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false // bloquea pop-ups
        config.preferences.isFraudulentWebsiteWarningEnabled = true
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = true
        webView.scrollView.keyboardDismissMode = .interactive
        webView.isFindInteractionEnabled = true
        config.userContentController.add(ScriptMessageProxy(self), name: "shield")

        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(pullToRefresh(_:)), for: .valueChanged)
        webView.scrollView.refreshControl = refresh

        // Deslizar desde el borde sin historial: cerrar y volver a la pestaña de origen.
        let edge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(edgeSwipe(_:)))
        edge.edges = .left
        edge.delegate = self
        webView.addGestureRecognizer(edge)

        observe()
        applyShields(for: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(rulesReady),
                                               name: .shieldRulesReady, object: nil)
    }

    // MARK: - Navegación

    func load(_ input: String) {
        guard let target = URLBuilder.url(from: input) else { return }
        backAt = nil
        applyShields(for: target.host())
        webView.load(URLRequest(url: target))
    }

    func reload() {
        applyShields(for: webView.url?.host(), force: true)
        webView.reload()
    }

    func goBack() {
        backAt = Date()
        webView.goBack()
    }
    func goForward() { webView.goForward() }
    func stop() { webView.stopLoading() }

    func toggleDesktopMode() {
        desktopMode.toggle()
        reload()   // la nueva preferencia se aplica al decidir la navegación
    }

    func findInPage() {
        webView.findInteraction?.presentFindNavigator(showingReplace: false)
    }

    func captureSnapshot() {
        guard webView.url != nil else { snapshot = nil; return }
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = 360
        Task {
            if let image = try? await webView.takeSnapshot(configuration: config) { snapshot = image }
        }
    }

    // MARK: - Sesión

    /// Estado para volver a abrir la pestaña (con su historial atrás/adelante).
    var saved: SavedTab? {
        if let pendingRestore { return pendingRestore }
        guard let url = webView.url else { return nil }
        return SavedTab(url: url, title: title, state: webView.interactionState as? Data)
    }

    func restore(_ tab: SavedTab) {
        pendingRestore = tab
        url = tab.url
        title = tab.title
    }

    func restoreIfNeeded() {
        guard let tab = pendingRestore else { return }
        pendingRestore = nil
        applyShields(for: tab.url.host())
        if let state = tab.state {
            webView.interactionState = state
        } else {
            webView.load(URLRequest(url: tab.url))
        }
    }

    @objc private func pullToRefresh(_ sender: UIRefreshControl) {
        reload()
        sender.endRefreshing()
    }

    @objc private func edgeSwipe(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard gesture.state == .ended else { return }
        if gesture.translation(in: webView).x > 80 || gesture.velocity(in: webView).x > 500 {
            onBackToOpener?()
        }
    }

    @objc private func rulesReady() {
        applyShields(for: webView.url?.host(), force: true)
    }

    // MARK: - Escudos

    /// Activa o desactiva las listas de bloqueo según el sitio.
    func applyShields(for host: String?, force: Bool = false) {
        let enabled = ShieldSettings.shieldsEnabled(for: host)
        shieldsActive = enabled
        guard force || appliedShields != enabled else { return }
        appliedShields = enabled
        let controller = webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        controller.removeAllUserScripts()
        if enabled {
            for list in ContentBlocker.shared.ruleLists { controller.add(list) }
            let flag = "window.__shieldNativePlayer = \(ShieldSettings.nativePlayer); window.__shieldToken = '\(linkToken)';"
            controller.addUserScript(WKUserScript(source: flag, injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: false))
            controller.addUserScript(ContentBlocker.shared.userScript)
        }
    }

    /// Activa/desactiva el reproductor nativo en la página actual y las siguientes.
    func setNativePlayer(_ on: Bool) {
        webView.evaluateJavaScript("window.__shieldSetNative && window.__shieldSetNative(\(on)); 0",
                                   completionHandler: nil)
        applyShields(for: webView.url?.host(), force: true)
    }

    func toggleShieldsForCurrentSite() {
        guard let host = webView.url?.host() else { return }
        ShieldSettings.setShields(!ShieldSettings.shieldsEnabled(for: host), for: host)
        reload()
    }

    // MARK: - KVO

    private func observe() {
        observations = [
            webView.observe(\.title) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.title = wv.title ?? ""
                    if !self.isPrivate, let url = wv.url { HistoryStore.shared.updateTitle(self.title, for: url) }
                }
            },
            webView.observe(\.url) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    self?.url = wv.url
                    if !wv.isLoading { self?.recordVisit() }   // webs que cambian de página sin recargar
                }
            },
            webView.observe(\.estimatedProgress) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.progress = wv.estimatedProgress }
            },
            webView.observe(\.isLoading) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.isLoading = wv.isLoading }
            },
            webView.observe(\.canGoBack) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.canGoBack = wv.canGoBack }
            },
            webView.observe(\.canGoForward) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.canGoForward = wv.canGoForward }
            },
        ]
    }

    private func recordVisit() {
        guard !isPrivate, let url = webView.url else { return }
        HistoryStore.shared.record(url, title: webView.title)
    }

    fileprivate func didReceive(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if let hidden = body["hidden"] as? Int, hidden > cosmeticBlocked {
            ShieldStats.add(hidden - cosmeticBlocked)
            cosmeticBlocked = hidden
        }
        if let url = body["allowPopup"] as? String {
            approvedPopups[url] = Date()
        }
        if let url = (body["popupBlocked"] as? String).flatMap({ URL(string: $0) }) {
            noteBlockedPopup(url)
        }
        if let what = body["linkLog"] as? String {
            let href = body["href"] as? String ?? ""
            if lastLink?.url == href, let notes = lastLink?.notes, notes.last != what {
                lastLink = (href, Array((notes + [what]).suffix(4)))
            } else if lastLink?.url != href {
                lastLink = (href, [what])
            }
        }
        if let link = body["openLink"] as? String, body["token"] as? String != linkToken {
            noteLink(link, "La app rechazó abrirlo: la página no tenía la clave de Shield")
        }
        if let link = body["openLink"] as? String, body["token"] as? String == linkToken,
           let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            if body["newTab"] as? Bool == true {
                onOpenInNewTab?(URLRequest(url: url))
            } else if message.frameInfo.isMainFrame {
                backAt = nil
                applyShields(for: url.host())
                webView.load(URLRequest(url: url))
            }
        }
        if body["layerBlocked"] != nil {
            popupsBlocked += 1
            ShieldStats.add(1)
        }
        if body["tap"] != nil { lastTapAt = Date() }
        if body["back"] != nil { backAt = Date() }   // atrás dentro de la misma página (popstate)
        if let video = NativeVideo(body) {
            closeInlinePlayer(release: false)
            pendingVideo = video
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard let self, self.pendingVideo?.id == video.id else { return }
                self.pendingVideo = nil
                self.nativeVideo = video      // sin posición utilizable: capa completa
            }
        }
        if body["nativeTrack"] != nil {
            if let rect = body["rect"] as? [String: Any] {
                placeInlinePlayer(rect)
            } else if body["gone"] as? Bool == true, pendingVideo == nil {
                closeInlinePlayer()
            }
        }
        if let list = body["media"] as? [[String: Any]] {
            addMedia(list.compactMap(MediaItem.init))
        }
    }

    // MARK: - Reproductor dentro de la página

    /// Coloca (o recoloca) el reproductor sobre el vídeo de la web. `rect` viene en píxeles CSS de la página.
    private func placeInlinePlayer(_ rect: [String: Any]) {
        func value(_ key: String) -> CGFloat { CGFloat((rect[key] as? NSNumber)?.doubleValue ?? 0) }
        let zoom = webView.scrollView.zoomScale
        let frame = CGRect(x: value("x") * zoom, y: value("y") * zoom,
                           width: value("w") * zoom, height: value("h") * zoom)
        // Vídeos ocultos o diminutos: no se pueden ver dentro de la página.
        guard frame.width >= 120, frame.height >= 68 else {
            if pendingVideo == nil { closeInlinePlayer() }   // ya estaba puesto y el vídeo se ocultó
            return
        }
        if let video = pendingVideo {
            pendingVideo = nil
            let player = InlinePlayerView(video: video, tab: self)
            player.frame = frame
            webView.scrollView.addSubview(player)
            inlinePlayer = player
        }
        inlinePlayer?.frame = frame
    }

    /// Quita el reproductor de la página y devuelve el control al vídeo de la web.
    func closeInlinePlayer(release: Bool = true) {
        pendingVideo = nil
        guard let player = inlinePlayer else { return }
        inlinePlayer = nil
        player.close()
        if release {
            webView.evaluateJavaScript("window.__shieldRelease && window.__shieldRelease(); 0",
                                       completionHandler: nil)
        }
    }

    // MARK: - Pop-ups

    private func isApprovedPopup(_ url: URL) -> Bool {
        approvedPopups = approvedPopups.filter { Date().timeIntervalSince($0.value) < 5 }
        return approvedPopups.removeValue(forKey: url.absoluteString) != nil
    }

    private func noteBlockedPopup(_ url: URL) {
        popupsBlocked += 1
        if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            blockedURLs = Array(([url] + blockedURLs.filter { $0 != url }).prefix(8))
        }
        ShieldStats.add(1)
        guard ShieldSettings.popupNotice else { return }
        blockedPopup = url
        popupBannerTask?.cancel()
        popupBannerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { self?.blockedPopup = nil }
        }
    }

    /// El usuario decide abrir un pop-up bloqueado desde el aviso.
    func openBlockedPopup() {
        guard let url = blockedPopup, ["http", "https"].contains(url.scheme ?? "") else { return }
        blockedPopup = nil
        onOpenInNewTab?(URLRequest(url: url))
    }

    // MARK: - Contenido multimedia

    private func addMedia(_ items: [MediaItem]) {
        var known = Set(media.map(\.id))
        var added: [MediaItem] = []
        for item in items where !known.contains(item.id) {
            known.insert(item.id)
            added.append(item)
        }
        guard !added.isEmpty else { return }
        media = Array((media + added).prefix(400))
    }

    /// Pide a la página (y a sus iframes) que vuelva a buscar vídeos e imágenes.
    func scanMedia() {
        webView.evaluateJavaScript("window.__shieldScan && window.__shieldScan(); 0", completionHandler: nil)
    }

    var videoCount: Int { media.filter { $0.kind != .image }.count }
}

// MARK: - WKNavigationDelegate

extension BrowserTab: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        preferences.preferredContentMode = desktopMode ? .desktop : .mobile
        guard let url = navigationAction.request.url else { return (.cancel, preferences) }
        let scheme = url.scheme?.lowercased() ?? ""
        if ["http", "https", "about", "data", "blob", "file"].contains(scheme) {
            if navigationAction.navigationType == .backForward { backAt = Date() }
            if isAdRedirect(navigationAction) {
                noteLink(url.absoluteString, "Shield frenó la navegación: parecía una redirección a un anuncio")
                noteBlockedPopup(url)
                return (.cancel, preferences)
            }
            if navigationAction.targetFrame?.isMainFrame ?? true {
                applyShields(for: url.host())
            }
            return (.allow, preferences)
        }
        // tel:, mailto:, maps:, itms-apps: … → abrir con la app del sistema
        if navigationAction.navigationType == .linkActivated {
            _ = await UIApplication.shared.open(url)
        }
        return (.cancel, preferences)
    }

    /// La página se manda sola a otro sitio (script, no un toque) justo cuando el usuario no
    /// la controla: en una pestaña en segundo plano ("tab-under": al volver, había un anuncio)
    /// o tras darle a atrás sin tocar nada (trampas que convierten "atrás" en publicidad).
    /// shortcut: ventana de 10 s tras "atrás" sin toques; si bloquea algo legítimo, sale en el panel con "Abrir".
    private func noteLink(_ href: String, _ what: String) {
        let notes = lastLink?.url == href ? (lastLink?.notes ?? []) : []
        lastLink = (href, Array((notes + [what]).suffix(4)))
    }

    private func isAdRedirect(_ action: WKNavigationAction) -> Bool {
        guard shieldsActive, action.navigationType == .other,
              action.targetFrame?.isMainFrame ?? false,
              let current = webView.url, ["http", "https"].contains(current.scheme ?? ""),
              !URLBuilder.sameSite(action.request.url, current) else { return false }
        if !isForeground() { return true }
        guard let backAt, Date().timeIntervalSince(backAt) < 10 else { return false }
        return lastTapAt < backAt
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        cosmeticBlocked = 0
        popupsBlocked = 0
        blockedURLs = []
        media = []
        closeInlinePlayer(release: false)
    }

    /// Enlaces a archivos que la web no puede mostrar (zip, pdf forzado, etc.) → descarga.
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard navigationResponse.isForMainFrame else { return .allow }
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment") {
            return .download
        }
        return navigationResponse.canShowMIMEType ? .allow : .download
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        DownloadManager.shared.adopt(download, name: navigationResponse.response.suggestedFilename)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        DownloadManager.shared.adopt(download, name: navigationAction.request.url?.lastPathComponent)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageColor = Color(uiColor: webView.underPageBackgroundColor)
        recordVisit()
        guard !isPrivate, let url = webView.url else { return }
        Task {
            guard let json = try? await webView.evaluateJavaScript(FaviconStore.script) as? String else { return }
            FaviconStore.shared.update(host: HistoryStore.normalizedHost(url), candidates: FaviconStore.rank(json))
        }
    }

    /// iOS cierra el proceso de la web para liberar memoria (sitios con muchos vídeos/imágenes):
    /// sin esto la página se queda en blanco, sobre todo al volver atrás.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isLoading = false
        if webView.url != nil {
            webView.reload()
        } else if let url {
            webView.load(URLRequest(url: url))
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
    }
}

// MARK: - WKUIDelegate

extension BrowserTab: WKUIDelegate {
    /// Ventanas nuevas (target="_blank" / window.open). Sólo se abren como
    /// pestaña si el usuario tocó de verdad un enlace visible; el resto son
    /// pop-ups/pop-unders de anuncios y se bloquean con un aviso para abrirlos.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil, let url = navigationAction.request.url else { return nil }
        let request = navigationAction.request
        // Permitido: shield.js lo aprobó (toque real sobre un enlace visible) o es del mismo sitio.
        if isApprovedPopup(url) ||
            (navigationAction.navigationType == .linkActivated && URLBuilder.sameSite(url, webView.url)) {
            onOpenInNewTab?(request)
            return nil
        }
        // El permiso del script puede llegar unos milisegundos después que la petición.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self else { return }
            if self.isApprovedPopup(url) {
                self.onOpenInNewTab?(request)
            } else if self.blockedPopup != url {
                self.noteBlockedPopup(url)
            }
        }
        return nil
    }
}

extension BrowserTab: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        !webView.canGoBack && opener != nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

/// Evita el ciclo de retención WKUserContentController → handler.
private final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var tab: BrowserTab?
    init(_ tab: BrowserTab) { self.tab = tab }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { tab?.didReceive(message) }
    }
}
