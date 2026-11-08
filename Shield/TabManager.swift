import SwiftUI

/// Pestaña guardada entre sesiones (las privadas nunca se guardan).
struct SavedTab: Codable {
    var url: URL
    var title: String
    var state: Data?
}

private struct SavedSession: Codable {
    var tabs: [SavedTab]
    var selected: Int
}

@MainActor
final class TabManager: ObservableObject {
    @Published private(set) var tabs: [BrowserTab] = []
    @Published var selectedID: UUID?
    /// Pantalla que DemoMode pide abrir (capturas de CI).
    @Published var demoRequest: String?

    private static let sessionFile = "session.json"

    init() {
        if DemoMode.screen == nil { restoreSession() }
        if tabs.isEmpty { newTab() }
    }

    var current: BrowserTab {
        tabs.first { $0.id == selectedID } ?? tabs[0]
    }

    @discardableResult
    func newTab(isPrivate: Bool = false, request: URLRequest? = nil) -> BrowserTab {
        if !tabs.isEmpty { current.captureSnapshot() }
        let tab = makeTab(isPrivate: isPrivate)
        tabs.append(tab)
        selectedID = tab.id
        if let request { tab.webView.load(request) }
        return tab
    }

    private func makeTab(isPrivate: Bool) -> BrowserTab {
        let tab = BrowserTab(isPrivate: isPrivate)
        tab.onOpenInNewTab = { [weak self, weak tab] request in
            let child = self?.newTab(isPrivate: tab?.isPrivate ?? false, request: request)
            child?.opener = tab
        }
        tab.onBackToOpener = { [weak self, weak tab] in
            if let self, let tab { self.goBack(in: tab) }
        }
        return tab
    }

    func select(_ tab: BrowserTab) {
        selectedID = tab.id
    }

    func close(_ tab: BrowserTab) {
        tab.stop()
        tabs.removeAll { $0.id == tab.id }
        if tabs.isEmpty { newTab() }
        if !tabs.contains(where: { $0.id == selectedID }) {
            selectedID = tabs.last?.id
        }
    }

    /// Atrás: historial de la pestaña o, si ya no hay, cerrarla y volver a la que la abrió (como Safari).
    func goBack(in tab: BrowserTab) {
        if tab.webView.canGoBack { tab.goBack(); return }
        guard let opener = tab.opener, tabs.contains(where: { $0 === opener }) else { return }
        close(tab)
        selectedID = opener.id
    }

    func closeAll() {
        tabs.forEach { $0.stop() }
        tabs.removeAll()
        newTab()
    }

    // MARK: - Sesión

    /// Se llama al pasar a segundo plano: iOS puede cerrar la app sin avisar después.
    func saveSession() {
        guard DemoMode.screen == nil else { return }
        var saved: [SavedTab] = []
        var selected = 0
        for tab in tabs where !tab.isPrivate {
            guard let state = tab.saved else { continue }
            if tab.id == selectedID { selected = saved.count }
            saved.append(state)
        }
        Storage.save(SavedSession(tabs: saved, selected: selected), to: Self.sessionFile)
    }

    private func restoreSession() {
        guard let session = Storage.load(SavedSession.self, from: Self.sessionFile) else { return }
        for saved in session.tabs {
            let tab = makeTab(isPrivate: false)
            tab.restore(saved)
            tabs.append(tab)
        }
        if tabs.indices.contains(session.selected) { selectedID = tabs[session.selected].id }
        else { selectedID = tabs.last?.id }
    }
}
