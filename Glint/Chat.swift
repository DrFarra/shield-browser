import Observation
import SwiftUI
import UIKit

struct ChatMessage: Identifiable {
    enum Part {
        case text(String)
        case emote(id: String, name: String)
    }

    let id = UUID()
    let name: String
    let color: Color
    let parts: [Part]
    let isAction: Bool
}

/// Chat de solo lectura: IRC de Twitch como usuario anónimo (justinfan), que
/// no necesita cuenta.
@MainActor @Observable
final class ChatClient {
    private(set) var messages: [ChatMessage] = []
    private(set) var pendingCount = 0
    /// Mientras el usuario lee mensajes antiguos, los nuevos esperan aparte.
    var paused = false { didSet { if !paused, oldValue { flush() } } }

    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var incoming: [ChatMessage] = []
    @ObservationIgnored private var held: [ChatMessage] = []
    @ObservationIgnored private var flushTask: Task<Void, Never>?

    func connect(_ channel: String) {
        disconnect()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.run(channel.lowercased())
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func disconnect() {
        loop?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        messages = []
        incoming = []
        held = []
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
                    incoming.append(parsed)
                }
            }
            scheduleFlush()
        }
        ws.cancel()
    }

    // Agrupa los mensajes cada 0,25 s: en canales grandes llegan decenas por segundo.
    private func scheduleFlush() {
        guard flushTask == nil, !incoming.isEmpty else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            self?.flushTask = nil
            self?.flush()
        }
    }

    private func flush() {
        if paused {
            held.append(contentsOf: incoming)
            if held.count > 300 { held.removeFirst(held.count - 300) }
            pendingCount = held.count
        } else {
            messages.append(contentsOf: held + incoming)
            if messages.count > 150 { messages.removeFirst(messages.count - 150) }
            held = []
            pendingCount = 0
        }
        incoming = []
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
            parts.append(.emote(id: r.id, name: string(scalars[r.start...r.end])))
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

/// Imágenes de emotes de Twitch, descargadas una vez y compartidas.
@MainActor @Observable
final class EmoteImages {
    static let shared = EmoteImages()
    private(set) var images: [String: UIImage] = [:]
    @ObservationIgnored private var requested: Set<String> = []

    func image(_ id: String) -> UIImage? {
        if let image = images[id] { return image }
        if requested.insert(id).inserted {
            Task { await load(id) }
        }
        return nil
    }

    private func load(_ id: String) async {
        guard let url = URL(string: "https://static-cdn.jtvnw.net/emoticons/v2/\(id)/static/dark/2.0"),
              let result = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: result.0, scale: 2.5) else { return }
        images[id] = image
    }
}
