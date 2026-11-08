import SwiftUI
import WebKit

struct BrowserView: View {
    @EnvironmentObject private var tabs: TabManager

    var body: some View {
        TabContent(tab: tabs.current)
            .id(tabs.current.id)
    }
}

/// Pantalla de una pestaña: la web ocupa toda la pantalla y el panel de
/// navegación flota encima, con la página desplazándose por debajo (como Safari).
private struct TabContent: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject private var tabs: TabManager
    @EnvironmentObject private var blocker: ContentBlocker

    @State private var query = ""
    @State private var addressFocused = false
    @State private var panelHeight: CGFloat = 110
    @State private var showTabs = false
    @State private var showSettings = false
    @State private var showShieldPanel = false
    @State private var showMedia = false
    @State private var showDownloads = false
    @State private var showHistory = false
    @State private var showBookmarks = false
    @State private var editingBookmark: Bookmark?
    @ObservedObject private var downloads = DownloadManager.shared
    @ObservedObject private var bookmarks = BookmarkStore.shared

    var body: some View {
        ZStack(alignment: .bottom) {
            content
            VStack(spacing: 8) {
                if let popup = tab.blockedPopup, !addressFocused {
                    PopupBanner(url: popup, onOpen: tab.openBlockedPopup) { tab.blockedPopup = nil }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                panel
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 2)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
            .animation(.snappy(duration: 0.25), value: tab.blockedPopup)
        }
        .animation(.snappy(duration: 0.25), value: addressFocused)
        .background(Color(.systemBackground))
        .sheet(isPresented: $showTabs) { TabsView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showMedia) { MediaView(tab: tab) }
        .fullScreenCover(item: $tab.nativeVideo) { video in
            NativePlayerView(video: video, webView: tab.webView) {
                tab.setNativePlayer(false)
            }
        }
        .sheet(isPresented: $showDownloads) { NavigationStack { DownloadsView() } }
        .sheet(isPresented: $showHistory) { HistoryView { openURL($0, newTab: $1) } }
        .sheet(isPresented: $showBookmarks) { BookmarksView { openURL($0, newTab: $1) } }
        .sheet(item: $editingBookmark) { BookmarkEditor(bookmark: $0) }
        .sheet(isPresented: $showShieldPanel) {
            ShieldPanel(tab: tab)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .onAppear { tab.restoreIfNeeded() }
        .onReceive(tabs.$demoRequest) { showDemo($0) }
    }

    // MARK: - Contenido

    @ViewBuilder private var content: some View {
        ZStack {
            WebViewContainer(webView: tab.webView, bottomInset: panelHeight)
                .ignoresSafeArea()
                .opacity(tab.url == nil ? 0 : 1)
            if tab.url == nil {
                StartPageView(isPrivate: tab.isPrivate) { openURL($0, newTab: $1) }
                    .safeAreaPadding(.bottom, panelHeight)
            }
            if addressFocused {
                SuggestionsView(query: query) { open($0) }
                    .safeAreaPadding(.bottom, panelHeight)
                    .background(Color(.systemGroupedBackground))
                    .transition(.opacity)
            }
        }
    }

    // MARK: - Panel inferior

    private var panel: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                addressCapsule
                if addressFocused {
                    Button("Cancelar") { addressFocused = false }
                        .fontWeight(.medium)
                        .tint(.shield)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            if !addressFocused {
                toolbar.transition(.opacity)
            }
        }
        .padding(6)
        .glassEffect(tab.isPrivate ? .regular.tint(Color.privateTab.opacity(0.35)) : .regular,
                     in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var addressCapsule: some View {
        HStack(spacing: 2) {
            if !addressFocused {
                Button { showShieldPanel = true } label: {
                    Image(systemName: tab.shieldsActive ? "shield.lefthalf.filled" : "shield.slash")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(tab.shieldsActive ? Color.shield : Color.secondary)
                        .frame(width: 40, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Escudos")
            }

            ZStack {
                AddressField(query: $query, isEditing: $addressFocused,
                             currentURL: tab.url?.absoluteString ?? "") { open($0) }
                    .padding(.leading, addressFocused ? 14 : 0)
                    .opacity(addressFocused ? 1 : 0)
                if !addressFocused {
                    HStack(spacing: 5) {
                        if tab.url?.scheme == "https" {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        Text(displayHost)
                            .font(.system(size: 16, weight: tab.url == nil ? .regular : .medium))
                            .foregroundStyle(tab.url == nil ? Color.secondary : Color.primary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { addressFocused = true }
                }
            }

            if !addressFocused {
                Button { if tab.isLoading { tab.stop() } else { tab.reload() } } label: {
                    Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(tab.url == nil ? Color.secondary.opacity(0.5) : Color.primary)
                        .frame(width: 40, height: 44)
                        .contentShape(Rectangle())
                }
                .disabled(tab.url == nil)
                .accessibilityLabel(tab.isLoading ? "Detener" : "Recargar")
            }
        }
        .frame(height: 44)
        .background(Color.primary.opacity(0.07), in: Capsule())
        .overlay(alignment: .bottom) {
            if tab.isLoading {
                ProgressLine(progress: tab.progress)
            }
        }
        .clipShape(Capsule())
    }

    private var toolbar: some View {
        HStack(spacing: 0) {
            ToolbarIcon("chevron.backward", label: "Atrás", enabled: tab.canGoBack || tab.opener != nil) {
                tabs.goBack(in: tab)
            }
            ToolbarIcon("chevron.forward", label: "Adelante", enabled: tab.canGoForward) { tab.goForward() }
            ToolbarIcon("arrow.down.circle", label: "Descargar vídeos e imágenes", enabled: tab.url != nil) {
                showMedia = true
            }
            .overlay(alignment: .center) { mediaBadge.offset(x: 13, y: -11) }
            Button {
                tab.captureSnapshot()
                showTabs = true
            } label: {
                Text("\(tabs.tabs.count)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .frame(width: 22, height: 22)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(lineWidth: 1.8))
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(.primary)
            .accessibilityLabel("Pestañas, \(tabs.tabs.count) abiertas")
            menu
        }
    }

    @ViewBuilder private var mediaBadge: some View {
        let count = downloads.activeCount > 0 ? downloads.activeCount : tab.videoCount
        if count > 0 {
            Text("\(count)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .frame(minWidth: 16, minHeight: 16)
                .background(downloads.activeCount > 0 ? Color.blue : Color.shield, in: Capsule())
                .allowsHitTesting(false)
        }
    }

    private var menu: some View {
        Menu {
            Section {
                Button { tabs.newTab() } label: { Label("Nueva pestaña", systemImage: "plus.square.on.square") }
                Button { tabs.newTab(isPrivate: true) } label: {
                    Label("Nueva pestaña privada", systemImage: "eyeglasses")
                }
            }
            if let url = tab.url {
                Section {
                    if bookmarks.contains(url) {
                        Button { bookmarks.remove(url: url) } label: {
                            Label("Quitar de favoritos", systemImage: "star.slash")
                        }
                    } else {
                        Button {
                            editingBookmark = Bookmark(title: tab.title.isEmpty ? (url.host() ?? "") : tab.title, url: url)
                        } label: {
                            Label("Añadir a favoritos", systemImage: "star")
                        }
                    }
                    Button { tab.findInPage() } label: {
                        Label("Buscar en la página", systemImage: "text.magnifyingglass")
                    }
                    Button { tab.toggleDesktopMode() } label: {
                        Label(tab.desktopMode ? "Ver versión móvil" : "Ver versión de escritorio",
                              systemImage: tab.desktopMode ? "iphone" : "desktopcomputer")
                    }
                    ShareLink(item: url) { Label("Compartir", systemImage: "square.and.arrow.up") }
                }
            }
            Section {
                Button { showBookmarks = true } label: { Label("Favoritos", systemImage: "star.square.on.square") }
                Button { showHistory = true } label: { Label("Historial", systemImage: "clock.arrow.circlepath") }
                Button { showDownloads = true } label: { Label("Descargas", systemImage: "arrow.down.circle") }
                Button { showSettings = true } label: { Label("Ajustes", systemImage: "gearshape") }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 19, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 40)
                .contentShape(Rectangle())
        }
        .menuOrder(.fixed)
        .foregroundStyle(.primary)
        .accessibilityLabel("Más")
    }

    private var displayHost: String {
        guard let url = tab.url else {
            return blocker.isReady ? "Buscar o escribir dirección" : blocker.status
        }
        return HistoryStore.normalizedHost(url).isEmpty ? url.absoluteString : HistoryStore.normalizedHost(url)
    }

    // MARK: - Acciones

    /// Favoritos, historial y página de inicio: en esta pestaña o en una nueva.
    private func openURL(_ url: URL, newTab: Bool) {
        if newTab {
            tabs.newTab(isPrivate: tab.isPrivate, request: URLRequest(url: url))
        } else {
            tab.load(url.absoluteString)
        }
    }

    /// Abre lo escrito o la sugerencia elegida en la pestaña actual.
    private func open(_ text: String) {
        addressFocused = false
        tab.load(text)
    }

    /// Capturas de CI: abre la pantalla pedida por DemoMode.
    private func showDemo(_ screen: String?) {
        guard let screen else { return }
        tabs.demoRequest = nil
        switch screen {
        case "tabs": tab.captureSnapshot(); showTabs = true
        case "history": showHistory = true
        case "bookmarks": showBookmarks = true
        case "settings": showSettings = true
        case "shield": showShieldPanel = true
        case "media": showMedia = true
        case "suggest":
            addressFocused = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { query = "wi" }
        default: break
        }
    }
}

/// Botón de la barra: icono neutro que ocupa su parte del ancho.
private struct ToolbarIcon: View {
    let icon: String
    let label: String
    let enabled: Bool
    let action: () -> Void

    init(_ icon: String, label: String, enabled: Bool = true, action: @escaping () -> Void) {
        self.icon = icon
        self.label = label
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 40)
                .contentShape(Rectangle())
        }
        .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.45))
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

/// Línea de progreso de carga en el borde inferior de la dirección.
private struct ProgressLine: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(Color.shield)
                .frame(width: max(24, geo.size.width * progress), height: 2.5)
                .animation(.easeOut(duration: 0.2), value: progress)
        }
        .frame(height: 2.5)
        .padding(.horizontal, 16)
        .allowsHitTesting(false)
    }
}

/// Aviso de pop-up bloqueado, encima del panel.
private struct PopupBanner: View {
    let url: URL
    let onOpen: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.shield, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text("Pop-up bloqueado").font(.subheadline.weight(.semibold))
                Text(url.host() ?? url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button("Abrir", action: onOpen)
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(.shield)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Cerrar aviso")
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// Panel de escudos del sitio actual.
private struct ShieldPanel: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject private var blocker: ContentBlocker
    @Environment(\.dismiss) private var dismiss

    private var host: String { tab.url.map(HistoryStore.normalizedHost) ?? "" }
    private var canToggle: Bool { !host.isEmpty && ShieldSettings.globalShields }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(tab.shieldsActive ? Color.shield.opacity(0.14) : Color.secondary.opacity(0.12))
                                .frame(width: 84, height: 84)
                            Image(systemName: tab.shieldsActive ? "shield.lefthalf.filled" : "shield.slash")
                                .font(.system(size: 38, weight: .semibold))
                                .foregroundStyle(tab.shieldsActive ? Color.shield : Color.secondary)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        Text(tab.shieldsActive ? "Protección activa" : "Protección desactivada")
                            .font(.title3.weight(.semibold))
                        Text(host.isEmpty ? "Abre una página para ver qué se bloquea." : host)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)

                    HStack(spacing: 12) {
                        StatTile(value: tab.popupsBlocked, label: "Pop-ups y capas trampa", icon: "hand.raised.fill")
                        StatTile(value: tab.cosmeticBlocked, label: "Anuncios eliminados", icon: "rectangle.slash")
                    }

                    Toggle(isOn: Binding(get: { tab.shieldsActive }, set: { _ in tab.toggleShieldsForCurrentSite() })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Escudos en este sitio").font(.body.weight(.medium))
                            Text(ShieldSettings.globalShields ? "Desactívalos si la página no funciona bien."
                                                              : "Los escudos están desactivados en Ajustes.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tint(.shield)
                    .disabled(!canToggle)
                    .padding(14)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                    Text("Además, \(blocker.ruleCount.formatted()) reglas bloquean anuncios y rastreadores antes de que se descarguen.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .background(Color(.systemGroupedBackground))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() } }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct StatTile: View {
    let value: Int
    let label: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.shield)
            Text(value.formatted())
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// La web a pantalla completa; `bottomInset` deja sitio para el panel flotante.
struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView
    var bottomInset: CGFloat = 0

    func makeUIView(context: Context) -> WKWebView { webView }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let scroll = webView.scrollView
        guard scroll.contentInset.bottom != bottomInset else { return }
        scroll.contentInset.bottom = bottomInset
        scroll.verticalScrollIndicatorInsets.bottom = bottomInset
    }
}
