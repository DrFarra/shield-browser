import Foundation

/// Una página visitada. Se guarda una entrada por URL con su última visita y cuántas veces se abrió.
struct HistoryEntry: Codable, Identifiable, Hashable {
    var url: URL
    var title: String
    var lastVisit: Date
    var visitCount: Int

    var id: URL { url }
    var host: String { HistoryStore.normalizedHost(url) }
    var displayTitle: String { title.isEmpty ? host : title }

    func matches(_ query: String) -> Bool {
        title.localizedCaseInsensitiveContains(query) || url.absoluteString.localizedCaseInsensitiveContains(query)
    }
}

/// Historial de navegación (sólo pestañas normales), guardado en Application Support/history.json.
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    /// De la visita más reciente a la más antigua.
    @Published private(set) var entries: [HistoryEntry] = []

    private let fileURL: URL
    private let limit = 5000
    private var saveTask: Task<Void, Never>?
    private var rankedHosts: [String]?

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = saved
        }
    }

    nonisolated static func normalizedHost(_ url: URL) -> String {
        var host = url.host()?.lowercased() ?? ""
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    // MARK: - Escritura

    func record(_ url: URL, title: String?) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        var entry = HistoryEntry(url: url, title: "", lastVisit: Date(), visitCount: 0)
        if let index = entries.firstIndex(where: { $0.url == url }) {
            entry = entries.remove(at: index)
        }
        entry.lastVisit = Date()
        entry.visitCount += 1
        if let title, !title.isEmpty { entry.title = title }
        entries.insert(entry, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        changed()
    }

    /// El título suele llegar después de terminar la carga.
    func updateTitle(_ title: String, for url: URL) {
        guard !title.isEmpty, let index = entries.firstIndex(where: { $0.url == url }),
              entries[index].title != title else { return }
        entries[index].title = title
        changed()
    }

    func remove(_ entry: HistoryEntry) {
        entries.removeAll { $0.url == entry.url }
        changed()
    }

    /// Borra lo visitado desde `date`, o todo si es nil.
    func clear(since date: Date? = nil) {
        if let date { entries.removeAll { $0.lastVisit >= date } } else { entries.removeAll() }
        changed()
    }

    private func changed() {
        rankedHosts = nil
        saveTask?.cancel()
        let snapshot = entries
        let fileURL = fileURL
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 600_000_000)   // agrupa varias escrituras seguidas
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        }
    }

    // MARK: - Sugerencias

    /// Páginas que coinciden con lo escrito: primero el dominio, luego título o dirección.
    func suggestions(for query: String, limit: Int = 8) -> [HistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return Array(entries.prefix(limit)) }
        let scored: [(entry: HistoryEntry, score: Int)] = entries.compactMap { entry in
            let host = entry.host
            let score = host.hasPrefix(q) ? 3
                : host.contains(q) ? 2
                : entry.matches(q) ? 1 : 0
            return score > 0 ? (entry, score) : nil
        }
        return scored.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.entry.visitCount != $1.entry.visitCount { return $0.entry.visitCount > $1.entry.visitCount }
            return $0.entry.lastVisit > $1.entry.lastVisit
        }
        .prefix(limit)
        .map(\.entry)
    }

    /// Lo que falta para completar un dominio visitado: "you" → "tube.com".
    func completion(for typed: String) -> String? {
        var t = typed.lowercased()
        if t.hasPrefix("www.") { t.removeFirst(4) }
        guard !t.isEmpty, !t.contains(" "), !t.contains("/") else { return nil }
        if rankedHosts == nil {
            var visits: [String: Int] = [:]
            for entry in entries {
                let host = entry.host
                visits[host, default: 0] += entry.visitCount
                let base = URLBuilder.baseDomain(host)
                if base != host { visits[base, default: 0] += entry.visitCount }
            }
            rankedHosts = visits.sorted {
                $0.value != $1.value ? $0.value > $1.value : $0.key.count < $1.key.count
            }.map(\.key)
        }
        guard let host = rankedHosts?.first(where: { $0.hasPrefix(t) && $0.count > t.count }) else { return nil }
        return String(host.dropFirst(t.count))
    }
}
