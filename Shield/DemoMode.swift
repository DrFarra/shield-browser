import Foundation

/// Sólo para las capturas automáticas en CI (tools/screenshots.sh):
/// la app se abre con `-shieldDemo <pantalla>` y se prepara sola.
enum DemoMode {
    static let screen: String? = {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-shieldDemo"), index + 1 < args.count else { return nil }
        return args[index + 1]
    }()

    @MainActor
    static func run(_ tabs: TabManager) async {
        guard let screen else { return }
        seedHistory()
        switch screen {
        case "page", "shield", "suggest", "media":
            tabs.current.load("https://es.wikipedia.org/wiki/Paraguay")
            await wait(8)
        case "tabs":
            tabs.current.load("https://es.wikipedia.org/wiki/Asunción")
            await wait(8)
            tabs.newTab(request: URLRequest(url: URL(string: "https://github.com")!))
            await wait(8)
            tabs.newTab(request: URLRequest(url: URL(string: "https://www.bbc.com/mundo")!))
            await wait(8)
            tabs.newTab(isPrivate: true)
            await wait(1)
        default:
            break
        }
        tabs.demoRequest = screen
    }

    private static func wait(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    @MainActor
    private static func seedHistory() {
        let store = HistoryStore.shared
        guard store.entries.isEmpty else { return }
        let pages = [
            ("https://es.wikipedia.org/wiki/Asunción", "Asunción - Wikipedia, la enciclopedia libre"),
            ("https://github.com/trending", "Trending repositories on GitHub today"),
            ("https://www.abc.com.py", "ABC Color - Noticias de Paraguay"),
            ("https://www.bbc.com/mundo", "BBC News Mundo"),
            ("https://m.youtube.com", "YouTube"),
            ("https://www.wikipedia.org", "Wikipedia"),
        ]
        for (link, title) in pages.reversed() {
            if let url = URL(string: link) { store.record(url, title: title) }
        }
    }
}
