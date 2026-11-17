import Foundation
import Observation

/// Canal guardado en el iPhone (seguidos e historial de búsqueda).
struct ChannelRef: Codable, Hashable, Identifiable {
    let login: String
    var displayName: String
    var avatar: String?
    var id: String { login }
}

extension Twitch.Channel {
    var ref: ChannelRef { ChannelRef(login: login, displayName: name, avatar: profileImageURL) }
}

/// Seguidos e historial, guardados en el iPhone: no hace falta cuenta de Twitch.
@MainActor @Observable
final class Library {
    private(set) var follows: [ChannelRef] = Library.load("follows") { didSet { Library.save(follows, "follows") } }
    private(set) var recents: [ChannelRef] = Library.load("recentSearches") { didSet { Library.save(recents, "recentSearches") } }

    func isFollowing(_ login: String) -> Bool { follows.contains { $0.login == login } }

    func toggleFollow(_ channel: ChannelRef) {
        if isFollowing(channel.login) {
            follows.removeAll { $0.login == channel.login }
        } else {
            follows.insert(channel, at: 0)
        }
    }

    func addRecent(_ channel: ChannelRef) {
        recents.removeAll { $0.login == channel.login }
        recents.insert(channel, at: 0)
        if recents.count > 25 { recents.removeLast(recents.count - 25) }
    }

    func removeRecent(_ login: String) { recents.removeAll { $0.login == login } }
    func clearRecents() { recents = [] }

    private static func load(_ key: String) -> [ChannelRef] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([ChannelRef].self, from: data)) ?? []
    }

    private static func save(_ value: [ChannelRef], _ key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
    }
}

/// Pestaña elegida y la pila de navegación de cada una, para poder abrir un
/// canal desde el reproductor.
@MainActor @Observable
final class Router {
    enum Tab: Hashable { case home, browse, search }
    var tab: Tab = .home
    var home: [Route] = []
    var browse: [Route] = []
    var search: [Route] = []

    func open(_ route: Route) {
        switch tab {
        case .home: home.append(route)
        case .browse: browse.append(route)
        case .search: search.append(route)
        }
    }
}

enum Route: Hashable {
    case channel(String)
    case game(String)
}
