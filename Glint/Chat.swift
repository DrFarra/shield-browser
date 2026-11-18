import ImageIO
import Observation
import SwiftUI
import UIKit

struct ChatMessage: Identifiable {
    enum Part {
        case text(String)
        case emote(url: String, name: String)
    }

    let id = UUID()
    let name: String
    let color: Color
    let parts: [Part]
    let isAction: Bool

    var emoteURLs: [String] {
        parts.compactMap { part in
            if case .emote(let url, _) = part { return url }
            return nil
        }
    }
}

/// Chat de solo lectura: IRC de Twitch como usuario anónimo (justinfan), que
/// no necesita cuenta. En un VOD reproduce el chat original al ritmo del vídeo.
///
/// Para que corra suave: cada mensaje espera a que sus emotes estén descargados
/// (así nunca se ve el nombre del emote y luego la imagen), y los mensajes salen a
/// ritmo constante en vez de a ráfagas.
@MainActor @Observable
final class ChatClient {
    private(set) var messages: [ChatMessage] = []
    private(set) var pendingCount = 0
    /// Mientras el usuario lee mensajes antiguos, los nuevos esperan aparte.
    var paused = false { didSet { if !paused, oldValue { releaseHeld() } } }

    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var pump: Task<Void, Never>?
    /// Recibidos, en orden de llegada, esperando a sus emotes.
    @ObservationIgnored private var staged: [(message: ChatMessage, arrived: Date)] = []
    /// Listos para mostrarse; se van soltando poco a poco.
    @ObservationIgnored private var ready: [ChatMessage] = []
    @ObservationIgnored private var held: [ChatMessage] = []
    /// Emotes de 7TV, BTTV y FFZ del canal: nombre → URL.
    @ObservationIgnored private var extraEmotes: [String: String] = [:]
    @ObservationIgnored private var emoteTask: Task<Void, Never>?
    /// Lista de emotes de 7TV/BTTV/FFZ ya descargada. Hasta entonces los mensajes del
    /// directo esperan en `waiting`: si no, se quedarían con el emote como texto.
    @ObservationIgnored private var emotesLoaded = false
    @ObservationIgnored private var waiting: [(message: ChatMessage, arrived: Date)] = []

    func loadEmotes(channelID: String?) {
        emoteTask?.cancel()
        emoteTask = Task { [weak self] in
            let emotes = await ThirdPartyEmotes.load(channelID: channelID)
            guard !Task.isCancelled, let self else { return }
            extraEmotes = emotes
            markEmotesLoaded()
        }
    }

    private func markEmotesLoaded() {
        guard !emotesLoaded else { return }
        emotesLoaded = true
        for item in waiting { stage(expand(item.message)) }
        waiting = []
    }

    func connect(_ channel: String) {
        disconnect()
        startPump()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.run(channel.lowercased())
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// Chat de un VOD: pide los mensajes por tramos (~30 s por delante, con sus
    /// emotes ya descargándose) y los suelta cuando el vídeo llega a su segundo.
    func replay(videoID: String, position: @escaping () -> Double) {
        disconnect()
        startPump()
        loop = Task { [weak self] in
            var queue: [(time: Double, message: ChatMessage)] = []
            var cursor = 0.0, fetchedUntil = -1.0, last = -100.0
            var finished = false, jumped = false
            var jumpDeadline: Date?
            // Los mensajes se convierten a emotes al pedirlos: primero hace falta la lista de emotes
            let start = Date()
            while self?.emotesLoaded == false, Date().timeIntervalSince(start) < 3, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
            self?.markEmotesLoaded()
            while !Task.isCancelled {
                guard let self else { return }
                let now = position()
                if now < last - 2 || now > last + 20 {
                    // Salto en el vídeo: se pide el chat desde ahí, con 20 s de contexto
                    queue = []
                    cursor = max(0, now - 20)
                    fetchedUntil = cursor - 1
                    finished = false
                    jumped = true
                    jumpDeadline = nil
                }
                last = now
                if !finished, fetchedUntil < now + 30,
                   let page = try? await Twitch.comments(video: videoID, at: Int(cursor)) {
                    let fresh = page.comments.filter { Double($0.contentOffsetSeconds ?? 0) > fetchedUntil }
                    let items = fresh.map { (time: Double($0.contentOffsetSeconds ?? 0), message: message(from: $0)) }
                    for item in items { EmoteImages.shared.prefetch(item.message.emoteURLs) }
                    queue += items
                    if let end = fresh.last?.contentOffsetSeconds {
                        fetchedUntil = Double(end)
                        cursor = fetchedUntil + 1
                    } else if page.more {
                        cursor += 30
                    } else {
                        finished = true
                    }
                }
                let due = queue.prefix { $0.time <= now }.count
                let batchReady = queue.prefix(due).allSatisfy { item in
                    item.message.emoteURLs.allSatisfy { EmoteImages.shared.isReady($0) }
                }
                if jumped, fetchedUntil >= now || finished {
                    jumpDeadline = jumpDeadline ?? Date(timeIntervalSinceNow: 1.2)
                }
                if jumped, let deadline = jumpDeadline, batchReady || Date() > deadline {
                    // Se cambia el chat entero de una vez, con sus emotes ya cargados:
                    // sin vaciarlo antes ni ver cómo se rellena
                    jumpDeadline = nil
                    staged = []
                    ready = []
                    held = []
                    pendingCount = 0
                    messages = queue.prefix(due).map { $0.message }
                    queue.removeFirst(due)
                    jumped = false
                } else if !jumped {
                    for item in queue.prefix(due) { stage(item.message) }
                    queue.removeFirst(due)
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func disconnect() {
        loop?.cancel()
        pump?.cancel()
        emoteTask?.cancel()
        extraEmotes = [:]
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        messages = []
        staged = []
        ready = []
        held = []
        waiting = []
        emotesLoaded = false
        pendingCount = 0
        paused = false
    }

    private func run(_ channel: String) async {
        let ws = URLSession.shared.webSocketTask(with: URL(string: "wss://irc-ws.chat.twitch.tv:443")!)
        socket = ws
        ws.resume()
        for line in ["CAP REQ :twitch.tv/tags twitch.tv/commands", "PASS SCHMOOPIIE",
                     "NICK justinfan\(Int.random(in: 10_000...99_999))", "JOIN #\(channel)"] {
            try? await ws.send(.string(line))
        }
        while !Task.isCancelled {
            guard let message = try? await ws.receive() else { break }
            guard case .string(let text) = message else { continue }
            for line in text.components(separatedBy: "\r\n") where !line.isEmpty {
                if line.hasPrefix("PING") {
                    try? await ws.send(.string("PONG :tmi.twitch.tv"))
                } else if let parsed = Self.parse(line) {
                    receive(parsed)
                }
            }
        }
        ws.cancel()
    }

    // MARK: - Ritmo del chat

    /// Mensaje del directo recién llegado, todavía sin emotes de 7TV/BTTV/FFZ.
    private func receive(_ message: ChatMessage) {
        if emotesLoaded {
            stage(expand(message))
        } else {
            waiting.append((message: message, arrived: Date()))
        }
    }

    private func stage(_ message: ChatMessage) {
        EmoteImages.shared.prefetch(message.emoteURLs)
        staged.append((message: message, arrived: Date()))
    }

    private func startPump() {
        pump?.cancel()
        pump = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                self?.step()
            }
        }
    }

    private func step() {
        // Si la lista de emotes no llega en 3 s, el chat sigue sin ellos
        if !emotesLoaded, let first = waiting.first, first.arrived.timeIntervalSinceNow < -3 {
            markEmotesLoaded()
        }
        let images = EmoteImages.shared
        // Sale cuando sus emotes ya están; si una imagen tarda más de 1,2 s, sale igual para no atascar el chat
        while let first = staged.first,
              first.message.emoteURLs.allSatisfy({ images.isReady($0) }) || first.arrived.timeIntervalSinceNow < -1.2 {
            ready.append(first.message)
            staged.removeFirst()
        }
        guard !ready.isEmpty else { return }
        // Un quinto de lo pendiente cada 0,1 s: una ráfaga de 20 mensajes entra en ~0,5 s, sin saltos
        let count = max(1, ready.count / 5)
        let batch = ready.prefix(count)
        ready.removeFirst(count)
        if paused {
            held += batch
            if held.count > 300 { held.removeFirst(held.count - 300) }
            pendingCount = held.count
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                messages += batch
                if messages.count > 200 { messages.removeFirst(messages.count - 200) }
            }
        }
    }

    private func releaseHeld() {
        messages += held
        if messages.count > 200 { messages.removeFirst(messages.count - 200) }
        held = []
        pendingCount = 0
    }

    // MARK: - Mensajes

    private func message(from comment: Twitch.Comment) -> ChatMessage {
        let login = comment.commenter?.login ?? ""
        let parts: [ChatMessage.Part] = (comment.message?.fragments ?? []).map { fragment in
            if let id = fragment.emote?.emoteID {
                return .emote(url: Self.twitchEmoteURL(id), name: fragment.text ?? "")
            }
            return .text(fragment.text ?? "")
        }
        return expand(ChatMessage(name: comment.commenter?.name ?? "?",
                                  color: Self.color(comment.message?.userColor.map { Substring($0) }, name: login),
                                  parts: parts, isAction: false))
    }

    /// Cambia las palabras que son emotes de 7TV/BTTV/FFZ por su imagen.
    private func expand(_ message: ChatMessage) -> ChatMessage {
        guard !extraEmotes.isEmpty else { return message }
        var parts: [ChatMessage.Part] = []
        var changed = false
        for part in message.parts {
            guard case .text(let text) = part else {
                parts.append(part)
                continue
            }
            var run = ""
            for (i, word) in text.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
                let separator = i == 0 ? "" : " "
                if let url = extraEmotes[String(word)] {
                    run += separator
                    if !run.isEmpty { parts.append(.text(run)) }
                    run = ""
                    parts.append(.emote(url: url, name: String(word)))
                    changed = true
                } else {
                    run += separator + word
                }
            }
            if !run.isEmpty { parts.append(.text(run)) }
        }
        return changed ? ChatMessage(name: message.name, color: message.color, parts: parts, isAction: message.isAction) : message
    }

    nonisolated static func twitchEmoteURL(_ id: String) -> String {
        "https://static-cdn.jtvnw.net/emoticons/v2/\(id)/static/dark/2.0"
    }

    // MARK: - IRC

    nonisolated static func parse(_ line: String) -> ChatMessage? {
        var rest = Substring(line)
        var tags: [Substring: Substring] = [:]
        if rest.hasPrefix("@"), let space = rest.firstIndex(of: " ") {
            for pair in rest[rest.index(after: rest.startIndex)..<space].split(separator: ";") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if kv.count == 2 { tags[kv[0]] = kv[1] }
            }
            rest = rest[rest.index(after: space)...]
        }
        guard let command = rest.range(of: " PRIVMSG #") else { return nil }
        let afterChannel = rest[command.upperBound...]
        guard let colon = afterChannel.range(of: " :") else { return nil }
        var text = String(afterChannel[colon.upperBound...])
        let login = String(rest.dropFirst().prefix { $0 != "!" })
        let display = tags["display-name"].map(String.init) ?? ""
        let name = display.isEmpty ? login : display

        var isAction = false
        if text.hasPrefix("\u{1}ACTION "), text.hasSuffix("\u{1}") {
            text = String(text.dropFirst(8).dropLast())
            isAction = true
        }

        return ChatMessage(name: name, color: color(tags["color"], name: login),
                           parts: parts(text, emotes: tags["emotes"] ?? ""), isAction: isAction)
    }

    /// "25:0-4,12-16/1902:6-10" → trozos de texto y emotes (posiciones en escalares Unicode).
    nonisolated static func parts(_ text: String, emotes: Substring) -> [ChatMessage.Part] {
        var ranges: [(start: Int, end: Int, id: String)] = []
        for spec in emotes.split(separator: "/") {
            let pieces = spec.split(separator: ":")
            guard pieces.count == 2 else { continue }
            for r in pieces[1].split(separator: ",") {
                let bounds = r.split(separator: "-")
                if bounds.count == 2, let s = Int(bounds[0]), let e = Int(bounds[1]) {
                    ranges.append((s, e, String(pieces[0])))
                }
            }
        }
        guard !ranges.isEmpty else { return [.text(text)] }
        let scalars = Array(text.unicodeScalars)
        func string(_ slice: ArraySlice<Unicode.Scalar>) -> String { String(String.UnicodeScalarView(slice)) }
        var parts: [ChatMessage.Part] = []
        var cursor = 0
        for r in ranges.sorted(by: { $0.start < $1.start }) where r.start >= cursor && r.start <= r.end && r.end < scalars.count {
            if r.start > cursor { parts.append(.text(string(scalars[cursor..<r.start]))) }
            parts.append(.emote(url: twitchEmoteURL(r.id), name: string(scalars[r.start...r.end])))
            cursor = r.end + 1
        }
        if cursor < scalars.count { parts.append(.text(string(scalars[cursor...]))) }
        return parts
    }

    /// Color del nombre, aclarado si es demasiado oscuro para leerse sobre negro.
    nonisolated static func color(_ hex: Substring?, name: String) -> Color {
        var rgb: (Double, Double, Double)
        if let hex, hex.count == 7, let value = Int(hex.dropFirst(), radix: 16) {
            rgb = (Double(value >> 16 & 0xFF) / 255, Double(value >> 8 & 0xFF) / 255, Double(value & 0xFF) / 255)
        } else {
            let palette: [(Double, Double, Double)] = [(0.98, 0.45, 0.45), (0.45, 0.75, 1), (0.55, 0.9, 0.55),
                                                       (1, 0.75, 0.35), (0.8, 0.6, 1), (0.4, 0.9, 0.85), (1, 0.55, 0.8)]
            rgb = palette[Int(name.unicodeScalars.reduce(0) { $0 &+ $1.value }) % palette.count]
        }
        let luminance = 0.299 * rgb.0 + 0.587 * rgb.1 + 0.114 * rgb.2
        if luminance < 0.45 {
            rgb = ((rgb.0 + 1) / 2, (rgb.1 + 1) / 2, (rgb.2 + 1) / 2)
        }
        return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
    }
}

/// Imágenes de emotes (Twitch, 7TV, BTTV, FFZ), descargadas una vez y compartidas.
/// Las animadas se muestran con su primer fotograma. No avisa a las vistas al
/// terminar una descarga: el chat solo muestra mensajes con sus emotes ya listos,
/// así una imagen nueva no redibuja (ni mueve) los mensajes que ya están en pantalla.
@MainActor
final class EmoteImages {
    static let shared = EmoteImages()
    private var images: [String: UIImage] = [:]
    private var failed: Set<String> = []
    private var loading: Set<String> = []

    func image(_ url: String) -> UIImage? { images[url] }

    /// Descargada, o falló (entonces se muestra su nombre).
    func isReady(_ url: String) -> Bool { images[url] != nil || failed.contains(url) }

    func prefetch(_ urls: [String]) {
        for url in urls where !isReady(url) && loading.insert(url).inserted {
            Task { await load(url) }
        }
    }

    private func load(_ link: String) async {
        defer { loading.remove(link) }
        guard let url = URL(string: link),
              let data = try? await URLSession.shared.data(from: url).0,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            failed.insert(link)
            return
        }
        // Todas a la altura de una línea de texto, sea cual sea su tamaño original
        images[link] = UIImage(cgImage: image, scale: max(1, CGFloat(image.height) / 22), orientation: .up)
    }
}
