import Foundation

/// Acceso a Twitch sin iniciar sesión: la API GraphQL pública de la web y los
/// servidores HLS (usher). Es lo mismo que usan streamlink y otros clientes.
enum Twitch {
    static let clientID = "kimne78kx3ncx6brgo4mv6wki5h1ko"

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - Modelos (nombres de campo iguales a los de GraphQL)

    struct Connection<T: Decodable>: Decodable {
        let edges: [Edge]?
        var nodes: [T] { edges?.compactMap(\.node) ?? [] }

        struct Edge: Decodable {
            let node: T?
            // Un nodo que no encaja (borrado, tipo distinto) no tumba la lista entera
            init(from decoder: Decoder) throws {
                node = try? decoder.container(keyedBy: Key.self).decode(T.self, forKey: .node)
            }
            enum Key: String, CodingKey { case node }
        }
    }

    struct SearchConnection<T: Decodable>: Decodable {
        let edges: [Edge]?
        var items: [T] { edges?.compactMap(\.item) ?? [] }

        struct Edge: Decodable {
            let item: T?
            init(from decoder: Decoder) throws {
                item = try? decoder.container(keyedBy: Key.self).decode(T.self, forKey: .item)
            }
            enum Key: String, CodingKey { case item }
        }
    }

    struct Count: Decodable { let totalCount: Int? }
    struct VideoRef: Decodable { let id: String }

    struct Broadcaster: Decodable {
        let login: String
        let displayName: String?
        let profileImageURL: String?
        var name: String { displayName ?? login }
    }

    struct Game: Decodable, Identifiable {
        let name: String
        let displayName: String?
        let boxArtURL: String?
        let viewersCount: Int?
        var id: String { name }
        var title: String { displayName ?? name }
    }

    struct Stream: Decodable, Identifiable {
        let id: String
        let title: String?
        let viewersCount: Int?
        let createdAt: Date?
        let previewImageURL: String?
        let game: Game?
        let broadcaster: Broadcaster?
        let archiveVideo: VideoRef?
    }

    struct Video: Decodable, Identifiable {
        let id: String
        let title: String?
        let lengthSeconds: Int?
        let createdAt: Date?
        let viewCount: Int?
        let previewThumbnailURL: String?
        let game: Game?
        let owner: Broadcaster?
    }

    struct Channel: Decodable, Identifiable {
        let login: String
        let displayName: String?
        let description: String?
        let profileImageURL: String?
        let bannerImageURL: String?
        let followers: Count?
        let stream: Stream?
        let videos: Connection<Video>?
        var id: String { login }
        var name: String { displayName ?? login }
    }

    // MARK: - Consultas

    private static let streamFields = """
        id title viewersCount createdAt previewImageURL(width: 640, height: 360) \
        game { name displayName } \
        broadcaster { login displayName profileImageURL(width: 70) } \
        archiveVideo { id }
        """
    private static let gameFields = "name displayName boxArtURL(width: 285, height: 380) viewersCount"
    private static let videoFields = """
        id title lengthSeconds createdAt viewCount previewThumbnailURL(width: 320, height: 180) \
        game { name displayName } owner { login displayName profileImageURL(width: 70) }
        """

    private static func languageOption(_ spanishOnly: Bool) -> String {
        spanishOnly ? ", options: {broadcasterLanguages: [ES]}" : ""
    }

    static func topStreams(spanishOnly: Bool) async throws -> [Stream] {
        struct R: Decodable { let streams: Connection<Stream> }
        let r: R = try await query("query { streams(first: 40\(languageOption(spanishOnly))) { edges { node { \(streamFields) } } } }")
        return r.streams.nodes
    }

    static func topGames() async throws -> [Game] {
        struct R: Decodable { let games: Connection<Game> }
        let r: R = try await query("query { games(first: 60) { edges { node { \(gameFields) } } } }")
        return r.games.nodes
    }

    static func streams(inGame name: String, spanishOnly: Bool) async throws -> (game: Game?, streams: [Stream]) {
        struct G: Decodable {
            let name: String; let displayName: String?; let boxArtURL: String?; let viewersCount: Int?
            let streams: Connection<Stream>?
        }
        struct R: Decodable { let game: G? }
        let r: R = try await query("""
            query($name: String!) { game(name: $name) { \(gameFields) \
            streams(first: 40\(languageOption(spanishOnly))) { edges { node { \(streamFields) } } } } }
            """, ["name": name])
        guard let g = r.game else { return (nil, []) }
        return (Game(name: g.name, displayName: g.displayName, boxArtURL: g.boxArtURL, viewersCount: g.viewersCount),
                g.streams?.nodes ?? [])
    }

    static func channel(_ login: String, withVideos: Bool = false) async throws -> Channel? {
        struct R: Decodable { let user: Channel? }
        let videos = withVideos ? "videos(first: 30, type: ARCHIVE, sort: TIME) { edges { node { \(videoFields) } } }" : ""
        let r: R = try await query("""
            query($login: String!) { user(login: $login) { login displayName description \
            profileImageURL(width: 300) bannerImageURL followers { totalCount } \
            stream { \(streamFields) } \(videos) } }
            """, ["login": login])
        return r.user
    }

    /// Varios canales de una vez (seguidos, historial) con su estado en directo.
    static func channels(_ logins: [String]) async throws -> [Channel] {
        guard !logins.isEmpty else { return [] }
        struct R: Decodable { let users: [Channel?] }
        let r: R = try await query("""
            query($logins: [String!]) { users(logins: $logins) { login displayName profileImageURL(width: 70) \
            stream { \(streamFields) } } }
            """, ["logins": Array(logins.prefix(100))])
        return r.users.compactMap { $0 }
    }

    static func search(_ text: String) async throws -> (channels: [Channel], games: [Game]) {
        struct S: Decodable { let channels: SearchConnection<Channel>?; let games: SearchConnection<Game>? }
        struct R: Decodable { let searchFor: S? }
        let r: R = try await query("""
            query($q: String!) { searchFor(userQuery: $q, platform: "web") { \
            channels { edges { item { ... on User { login displayName profileImageURL(width: 70) \
            followers { totalCount } stream { id viewersCount game { name displayName } } } } } } \
            games { edges { item { ... on Game { \(gameFields) } } } } } }
            """, ["q": text])
        return (r.searchFor?.channels?.items ?? [], r.searchFor?.games?.items ?? [])
    }

    static func video(_ id: String) async throws -> Video? {
        struct R: Decodable { let video: Video? }
        let r: R = try await query("query($id: ID!) { video(id: $id) { \(videoFields) } }", ["id": id])
        return r.video
    }

    // MARK: - Reproducción

    struct Quality: Identifiable, Hashable {
        let name: String
        let url: URL
        var id: String { name }
        var label: String { name == "Audio Only" ? "Solo audio" : name.replacingOccurrences(of: " (source)", with: " · Original") }
    }

    struct Playlist {
        let url: URL
        let qualities: [Quality]
    }

    static func livePlaylist(_ login: String) async throws -> Playlist {
        struct T: Decodable { let value: String; let signature: String }
        struct R: Decodable { let streamPlaybackAccessToken: T? }
        let r: R = try await query("""
            query($login: String!) { streamPlaybackAccessToken(channelName: $login, \
            params: {platform: "web", playerBackend: "mediaplayer", playerType: "site"}) { value signature } }
            """, ["login": login])
        guard let t = r.streamPlaybackAccessToken else { throw Failure(message: "Twitch no dio acceso a este directo") }
        let url = "https://usher.ttvnw.net/api/channel/hls/\(login.lowercased()).m3u8?\(commonParams)&fast_bread=true&sig=\(t.signature)&token=\(escape(t.value))"
        return try await playlist(url)
    }

    static func videoPlaylist(_ id: String) async throws -> Playlist {
        struct T: Decodable { let value: String; let signature: String }
        struct R: Decodable { let videoPlaybackAccessToken: T? }
        let r: R = try await query("""
            query($id: ID!) { videoPlaybackAccessToken(id: $id, \
            params: {platform: "web", playerBackend: "mediaplayer", playerType: "site"}) { value signature } }
            """, ["id": id])
        guard let t = r.videoPlaybackAccessToken else { throw Failure(message: "Twitch no dio acceso a este vídeo") }
        let url = "https://usher.ttvnw.net/vod/\(id).m3u8?\(commonParams)&nauthsig=\(t.signature)&nauth=\(escape(t.value))"
        return try await playlist(url)
    }

    // shortcut: solo H.264, el único códec que AVPlayer reproduce seguro en todos los iPhone; añadir h265 si hace falta 1440p
    private static var commonParams: String {
        "allow_source=true&allow_audio_only=true&playlist_include_framerate=true&supported_codecs=h264&p=\(Int.random(in: 100_000...999_999))"
    }

    private static func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }

    private static func playlist(_ string: String) async throws -> Playlist {
        guard let url = URL(string: string) else { throw Failure(message: "Dirección de vídeo no válida") }
        let (data, response) = try await URLSession.shared.data(from: url)
        switch (response as? HTTPURLResponse)?.statusCode ?? 200 {
        case 200: break
        case 403: throw Failure(message: "No disponible: es solo para suscriptores o está bloqueado en tu país")
        case 404: throw Failure(message: "El directo terminó o el vídeo ya no existe")
        case let code: throw Failure(message: "Twitch respondió con un error (\(code))")
        }
        return Playlist(url: url, qualities: qualities(in: String(decoding: data, as: UTF8.self)))
    }

    /// Calidades de una lista maestra HLS, en el orden de Twitch (de mayor a menor).
    static func qualities(in playlist: String) -> [Quality] {
        var names: [String: String] = [:]
        var pending: String?
        var result: [Quality] = []
        for line in playlist.components(separatedBy: .newlines) {
            if line.hasPrefix("#EXT-X-MEDIA:"), let group = attribute("GROUP-ID", in: line) {
                names[group] = attribute("NAME", in: line) ?? group
            } else if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let group = attribute("VIDEO", in: line) ?? attribute("RESOLUTION", in: line) ?? "?"
                pending = names[group] ?? group
            } else if !line.hasPrefix("#"), let name = pending, let url = URL(string: line) {
                result.append(Quality(name: name, url: url))
                pending = nil
            }
        }
        return result
    }

    private static func attribute(_ key: String, in line: String) -> String? {
        for prefix in [":\(key)=", ",\(key)="] {
            guard let r = line.range(of: prefix) else { continue }
            var value = line[r.upperBound...]
            if value.hasPrefix("\"") {
                value = value.dropFirst()
                return String(value.prefix { $0 != "\"" })
            }
            return String(value.prefix { $0 != "," })
        }
        return nil
    }

    // MARK: - GraphQL

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        decoder.dateDecodingStrategy = .custom { d in
            let s = try d.singleValueContainer().decode(String.self)
            guard let date = plain.date(from: s) ?? fractional.date(from: s) else {
                throw DecodingError.dataCorrupted(.init(codingPath: d.codingPath, debugDescription: s))
            }
            return date
        }
        return decoder
    }()

    private struct Response<T: Decodable>: Decodable {
        let data: T?
        let errors: [Message]?
        struct Message: Decodable { let message: String }
    }

    static func query<T: Decodable>(_ query: String, _ variables: [String: Any] = [:]) async throws -> T {
        var request = URLRequest(url: URL(string: "https://gql.twitch.tv/gql")!)
        request.httpMethod = "POST"
        request.setValue(clientID, forHTTPHeaderField: "Client-ID")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try decoder.decode(Response<T>.self, from: data)
        if let value = response.data { return value }
        throw Failure(message: response.errors?.first?.message ?? "Twitch no respondió")
    }
}
