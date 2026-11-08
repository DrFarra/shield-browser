import SwiftUI

@MainActor
final class TabManager: ObservableObject {
    @Published private(set) var tabs: [BrowserTab] = []
    @Published var selectedID: UUID?

    init() {
        newTab()
    }

    var current: BrowserTab {
        tabs.first { $0.id == selectedID } ?? tabs[0]
    }

    @discardableResult
    func newTab(isPrivate: Bool = false, request: URLRequest? = nil) -> BrowserTab {
        let tab = BrowserTab(isPrivate: isPrivate)
        tab.onOpenInNewTab = { [weak self, weak tab] request in
            let child = self?.newTab(isPrivate: tab?.isPrivate ?? false, request: request)
            child?.opener = tab
        }
        tab.onBackToOpener = { [weak self, weak tab] in
            if let self, let tab { self.goBack(in: tab) }
        }
        tabs.append(tab)
        selectedID = tab.id
        if let request { tab.webView.load(request) }
        return tab
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
}
