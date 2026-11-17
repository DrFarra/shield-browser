import Foundation
import Observation

/// Canal guardado en el iPhone (seguidos e historial de búsqueda).
struct ChannelRef: Codable, Hashable, Identifiable {
    let login: String
    var displayName: String
    var avatar: String?
    var id: String { login }
}

/// VOD visto, con el punto donde lo dejaste.
struct WatchedVideo: Codable, Identifiable {
    let id: String
    var title: String
    var thumbnail: String?
    var channel: String
    var length: Double
    var position: Double
    var date: Date

    var progress: Double { length > 0 ? min(1, position / length) : 0 }
    /// Se reanuda salvo que estuviera casi al final.
    var resumePosition: Double? { position > 10 && position < length - 60 ? position : nil }
}

extension Twitch.Channel {
    var ref: ChannelRef { ChannelRef(login: login, displayName: name, avatar: profileImageURL) }
}

/// Seguidos e historial, guardados en el iPhone: no hace falta cuenta de Twitch.
@MainActor @Observable
final class Library {
    private(set) var follows: [ChannelRef] = Library.load("follows") { didSet { Library.save(follows, "follows") } }
    private(set) var recents: [ChannelRef] = Library.load("recentSearches") { didSet { Library.save(recents, "recentSearches") } }
    private(set) var watched: [WatchedVideo] = Library.load("watchedVideos") { didSet { Library.save(watched, "watchedVideos") } }

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

    func watched(_ id: String) -> WatchedVideo? { watched.first { $0.id == id } }

    /// Lo más reciente primero; se guardan los últimos 100.
    func recordWatch(_ video: Twitch.Video, position: Double) {
        let entry = WatchedVideo(id: video.id, title: video.title ?? "", thumbnail: video.previewThumbnailURL,
                                 channel: video.owner?.name ?? "", length: Double(video.lengthSeconds ?? 0),
                                 position: position, date: .now)
        watched.removeAll { $0.id == video.id }
        watched.insert(entry, at: 0)
        if watched.count > 100 { watched.removeLast(watched.count - 100) }
    }

    func removeWatched(_ id: String) { watched.removeAll { $0.id == id } }
    func clearWatched() { watched = [] }

    private static func load<T: Decodable>(_ key: String) -> [T] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([T].self, from: data)) ?? []
    }

    private static func save<T: Encodable>(_ value: [T], _ key: String) {
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
    case history
}
