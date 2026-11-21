import UIKit

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
        case "fixed":
            // Página con una barra fija abajo: debe quedar por encima del panel del navegador.
            let html = """
            <meta name=viewport content="width=device-width">
            <body style="font:17px -apple-system;margin:20px">
            <h2>Barra fija abajo</h2>\(String(repeating: "<p>Texto de relleno para poder desplazarse.</p>", count: 30))
            <div style="position:fixed;left:0;right:0;bottom:0;padding:14px;background:#0a7;color:#fff;
            font-weight:600;text-align:center">Aceptar cookies</div>
            """
            tabs.current.webView.loadHTMLString(html, baseURL: URL(string: "https://demo.shield.local/"))
            await wait(4)
        case "downloads":
            seedDownloads()
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

    /// Un par de archivos de ejemplo para la captura de Descargas.
    private static func seedDownloads() {
        let folder = DownloadManager.folder
        let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300)).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }
        try? image.pngData()?.write(to: folder.appendingPathComponent("Atardecer en Asunción.png"))
        try? Data(count: 2_400_000).write(to: folder.appendingPathComponent("Informe anual 2026.pdf"))
        try? Data("Shield".utf8).write(to: folder.appendingPathComponent("notas.txt"))
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
