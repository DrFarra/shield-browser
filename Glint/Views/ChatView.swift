import SwiftUI

/// Chat en vivo. Sigue al último mensaje; si subes para leer, se pausa y avisa
/// de cuántos mensajes nuevos hay en vez de arrastrarte hacia abajo.
///
/// La lista va dada la vuelta (lo más nuevo arriba, y luego se voltea la vista
/// entera): así cada mensaje nuevo entra en la posición 0 y el scroll no tiene que
/// recolocarse, que era lo que hacía vibrar el chat al cabo de un rato.
struct ChatView: View {
    let chat: ChatClient
    @State private var position = ScrollPosition(edge: .top)
    @State private var phase: ScrollPhase = .idle
    @State private var atNewest = true

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(chat.messages.reversed()) { message in
                    ChatRow(message: message)
                        .scaleEffect(x: 1, y: -1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .scaleEffect(x: 1, y: -1)
        .scrollPosition($position)
        .scrollIndicators(.hidden)
        // En cuanto el dedo toca el chat se congela, para que nada se mueva bajo el dedo.
        // Al soltar: si quedó abajo del todo vuelve a seguir el directo; si no, sigue en pausa.
        .onScrollPhaseChange { _, newPhase in
            phase = newPhase
            if newPhase == .interacting {
                chat.paused = true
            } else if newPhase == .idle, atNewest {
                chat.paused = false
            }
        }
        .onScrollGeometryChange(for: Bool.self) { geo in
            // Volteada: el último mensaje está al principio del contenido
            geo.contentOffset.y + geo.contentInsets.top < 30
        } action: { _, newest in
            atNewest = newest
            if newest, phase == .idle { chat.paused = false }
        }
        .overlay(alignment: .bottom) {
            if chat.paused, !atNewest || chat.pendingCount > 0 {
                Button {
                    chat.paused = false
                    withAnimation { position.scrollTo(edge: .top) }
                } label: {
                    Label(pillTitle, systemImage: "arrow.down")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Capsule())
                .padding(.bottom, 10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay {
            if chat.messages.isEmpty {
                Text("Esperando mensajes…")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .animation(.snappy, value: chat.paused && (!atNewest || chat.pendingCount > 0))
        // Al girar el iPhone se cambia de chat (debajo del vídeo ↔ panel lateral):
        // el que aparece arranca siempre siguiendo el último mensaje
        .onAppear { chat.paused = false }
        .onDisappear { chat.paused = false }
    }

    private var pillTitle: String {
        switch chat.pendingCount {
        case 0: "Volver al chat en vivo"
        case 1: "1 mensaje nuevo"
        default: "\(chat.pendingCount) mensajes nuevos"
        }
    }
}

struct ChatRow: View {
    let message: ChatMessage
    @Environment(\.openURL) private var openURL

    private static let linkColor = Color(red: 0.45, green: 0.72, blue: 1)

    var body: some View {
        Group {
            // Los mensajes con emotes animados se redibujan ~20 veces por segundo con el
            // fotograma que toca; todos los fotogramas miden lo mismo, así que nada se mueve
            if message.emoteURLs.contains(where: { EmoteImages.shared.isAnimated($0) }) {
                TimelineView(.animation(minimumInterval: 1 / 20)) { context in
                    content(at: context.date)
                }
            } else {
                content(at: nil)
            }
        }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // Tocar un mensaje con enlace lo abre; mantener pulsado da a elegir
            .onTapGesture {
                if let url = message.links.first { openURL(url) }
            }
            .contextMenu {
                ForEach(message.links, id: \.self) { url in
                    Button("Abrir \(url.host() ?? "enlace")", systemImage: "safari") { openURL(url) }
                    Button("Copiar enlace", systemImage: "doc.on.doc") { UIPasteboard.general.url = url }
                }
            }
    }

    @ViewBuilder
    private func content(at time: Date?) -> some View {
        let line = rendered(at: time)
        switch message.kind {
        case .event(let event):
            // Tarjeta con icono y barra de color: no se confunde con un mensaje normal
            VStack(alignment: .leading, spacing: 5) {
                Label {
                    Text(verbatim: event.text).font(.footnote.weight(.semibold))
                } icon: {
                    Image(systemName: event.style.icon).foregroundStyle(event.style.tint)
                }
                if !message.parts.isEmpty {
                    line.font(.subheadline)
                }
            }
            .padding(.vertical, 8)
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(event.style.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .leading) {
                Capsule().fill(event.style.tint).frame(width: 3).padding(.vertical, 7).padding(.leading, 4)
            }
            .padding(.vertical, 2)
        case .highlighted:
            withReply(line.font(.subheadline))
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.glint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .normal:
            withReply(line.font(.subheadline))
        }
    }

    private func withReply(_ text: some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let reply = message.reply {
                Label {
                    Text(verbatim: reply).lineLimit(1)
                } icon: {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            text
        }
    }

    private func rendered(at time: Date?) -> Text {
        let emotes = EmoteImages.shared
        var text = Text(verbatim: message.name).bold().foregroundStyle(message.color)
        text = Text("\(text)\(Text(verbatim: message.isAction ? " " : ": ").foregroundStyle(.secondary))")
        for part in message.parts {
            switch part {
            case .text(let string):
                var piece = Text(verbatim: string)
                if message.isAction { piece = piece.italic().foregroundStyle(message.color) }
                text = Text("\(text)\(piece)")
            case .emote(let url, let name):
                if let image = emotes.image(url, at: time) {
                    text = Text("\(text)\(Text(Image(uiImage: image)).baselineOffset(-5))")
                } else {
                    text = Text("\(text)\(Text(verbatim: name))")
                }
            case .mention(let name):
                text = Text("\(text)\(Text(verbatim: name).bold().foregroundStyle(Color.glint))")
            case .link(let display, _):
                text = Text("\(text)\(Text(verbatim: display).underline().foregroundStyle(Self.linkColor))")
            }
        }
        return text
    }
}

extension ChatMessage.Event.Style {
    var icon: String {
        switch self {
        case .sub: "star.fill"
        case .gift: "gift.fill"
        case .raid: "person.3.fill"
        case .announcement: "megaphone.fill"
        case .bits: "diamond.fill"
        case .other: "sparkles"
        }
    }

    var tint: Color {
        switch self {
        case .sub: .glint
        case .gift: Color(red: 1, green: 0.47, blue: 0.7)
        case .raid: Color(red: 1, green: 0.62, blue: 0.25)
        case .announcement: Color(red: 0.45, green: 0.68, blue: 1)
        case .bits: Color(red: 0.72, green: 0.52, blue: 1)
        case .other: Color(red: 1, green: 0.85, blue: 0.35)
        }
    }
}
