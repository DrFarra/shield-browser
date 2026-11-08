import Foundation

struct Bookmark: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var url: URL

    var host: String { HistoryStore.normalizedHost(url) }
}

/// Favoritos: se muestran en la página de inicio y en la lista de Favoritos.
@MainActor
final class BookmarkStore: ObservableObject {
    static let shared = BookmarkStore()
    private static let file = "bookmarks.json"

    @Published private(set) var bookmarks: [Bookmark] = []

    private init() {
        bookmarks = Storage.load([Bookmark].self, from: Self.file) ?? Self.defaults
    }

    /// Primer arranque: los accesos que antes estaban fijos en la página de inicio.
    private static let defaults: [Bookmark] = [
        ("YouTube", "https://m.youtube.com"), ("Wikipedia", "https://es.wikipedia.org"),
        ("Reddit", "https://www.reddit.com"), ("X", "https://x.com"),
        ("GitHub", "https://github.com"), ("Marca", "https://www.marca.com"),
    ].compactMap { name, link in URL(string: link).map { Bookmark(title: name, url: $0) } }

    func contains(_ url: URL?) -> Bool {
        guard let url else { return false }
        return bookmarks.contains { $0.url == url }
    }

    /// Guarda cambios de uno existente o añade uno nuevo al final.
    func upsert(_ bookmark: Bookmark) {
        if let index = bookmarks.firstIndex(where: { $0.id == bookmark.id }) {
            bookmarks[index] = bookmark
        } else {
            bookmarks.append(bookmark)
        }
        save()
    }

    func remove(_ bookmark: Bookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        save()
    }

    func remove(url: URL) {
        bookmarks.removeAll { $0.url == url }
        save()
    }

    func remove(atOffsets offsets: IndexSet) {
        bookmarks.remove(atOffsets: offsets)
        save()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        bookmarks.move(fromOffsets: source, toOffset: destination)
        save()
    }

    private func save() { Storage.save(bookmarks, to: Self.file) }
}
