import SwiftUI

/// Iconos de los sitios, guardados por dominio en Caches/Favicons.
/// Se piden al propio sitio (nunca a un servicio de terceros) y sin cookies.
@MainActor
final class FaviconStore: ObservableObject {
    static let shared = FaviconStore()

    /// Cambia cuando llega un icono mejor, para que las vistas lo vuelvan a pedir.
    @Published private(set) var version = 0

    private var memory: [String: UIImage] = [:]
    private var failed: Set<String> = []
    private var inflight: [String: Task<UIImage?, Never>] = [:]
    private let folder: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 8
        return URLSession(configuration: config)
    }()

    private func file(_ host: String) -> URL { folder.appendingPathComponent(host + ".png") }

    func icon(for host: String) async -> UIImage? {
        guard !host.isEmpty else { return nil }
        if let image = memory[host] { return image }
        if let data = try? Data(contentsOf: file(host)), let image = UIImage(data: data) {
            memory[host] = image
            return image
        }
        if failed.contains(host) { return nil }
        if let task = inflight[host] { return await task.value }
        let candidates = ["https://\(host)/apple-touch-icon.png", "https://\(host)/favicon.ico"]
            .compactMap(URL.init(string:))
        let task = Task { await Self.firstImage(candidates) }
        inflight[host] = task
        let image = await task.value
        inflight[host] = nil
        if let image { store(image, for: host) } else { failed.insert(host) }
        return image
    }

    /// Iconos que declara la página cargada (<link rel="icon"> / apple-touch-icon), del mejor al peor.
    func update(host: String, candidates: [URL]) {
        guard !host.isEmpty, !candidates.isEmpty else { return }
        // Un apple-touch-icon guardado ya es de buena calidad.
        if let current = memory[host] ?? (try? Data(contentsOf: file(host))).flatMap(UIImage.init(data:)),
           current.size.width * current.scale >= 120 { return }
        Task {
            guard let image = await Self.firstImage(candidates) else { return }
            if let current = memory[host], current.size.width * current.scale >= image.size.width * image.scale { return }
            store(image, for: host)
            version += 1
        }
    }

    private func store(_ image: UIImage, for host: String) {
        memory[host] = image
        failed.remove(host)
        if let data = image.pngData() { try? data.write(to: file(host), options: .atomic) }
    }

    private nonisolated static func firstImage(_ urls: [URL]) async -> UIImage? {
        for url in urls {
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = UIImage(data: data),
                  image.size.width * image.scale >= 16 else { continue }
            return image
        }
        return nil
    }

    /// JavaScript que devuelve los iconos declarados por la página.
    static let script = """
    JSON.stringify(Array.from(document.querySelectorAll('link[rel~="icon"], link[rel^="apple-touch-icon"]'))
      .map(function (l) { return { href: l.href, rel: l.rel || '', sizes: (l.sizes && l.sizes.value) || '', type: l.type || '' }; }))
    """

    /// Ordena los iconos declarados: apple-touch-icon y los más grandes primero; sin SVG.
    static func rank(_ json: String) -> [URL] {
        guard let data = json.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { return [] }
        func size(_ item: [String: String]) -> Int {
            if item["rel"]?.contains("apple-touch-icon") == true { return 10_000 }
            return (item["sizes"] ?? "").split(separator: " ")
                .compactMap { Int($0.lowercased().split(separator: "x").first ?? "") }.max() ?? 32
        }
        return items
            .filter { !($0["type"] ?? "").contains("svg") && !($0["href"] ?? "").lowercased().hasSuffix(".svg") }
            .sorted { size($0) > size($1) }
            .compactMap { $0["href"].flatMap(URL.init(string:)) }
            .filter { ["http", "https"].contains($0.scheme ?? "") }
    }
}

/// Icono del sitio en un cuadrado redondeado; si no hay, inicial sobre un color propio del dominio.
struct SiteIcon: View {
    let host: String
    var size: CGFloat = 32

    @ObservedObject private var store = FaviconStore.shared
    @State private var image: UIImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
        ZStack {
            if let image {
                // Los apple-touch-icon están pensados para ocupar todo el cuadrado.
                if image.size.width * image.scale >= 120 {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Color(.secondarySystemBackground)
                    Image(uiImage: image).resizable().interpolation(.high).scaledToFit()
                        .frame(width: size * 0.56, height: size * 0.56)
                }
            } else {
                Self.color(for: host)
                Text(String(host.prefix(1)).uppercased())
                    .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .task(id: "\(host)#\(store.version)") { image = await store.icon(for: host) }
        .accessibilityHidden(true)
    }

    private static let palette: [Color] = [
        Color(red: 0.31, green: 0.36, blue: 0.85), Color(red: 0.13, green: 0.59, blue: 0.55),
        Color(red: 0.85, green: 0.33, blue: 0.47), Color(red: 0.92, green: 0.45, blue: 0.16),
        Color(red: 0.20, green: 0.55, blue: 0.85), Color(red: 0.55, green: 0.36, blue: 0.80),
        Color(red: 0.27, green: 0.60, blue: 0.33), Color(red: 0.42, green: 0.45, blue: 0.52),
    ]

    /// Color estable por dominio (no usa hashValue, que cambia entre ejecuciones).
    static func color(for host: String) -> Color {
        let sum = host.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[sum % palette.count]
    }
}
