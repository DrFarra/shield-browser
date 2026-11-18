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
    @State private var interacting = false

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
        .onScrollPhaseChange { _, phase in
            interacting = phase == .interacting
        }
        .onScrollGeometryChange(for: Bool.self) { geo in
            // Volteada: el último mensaje está al principio del contenido
            geo.contentOffset.y + geo.contentInsets.top < 30
        } action: { _, atNewest in
            if atNewest {
                chat.paused = false
            } else if interacting {
                chat.paused = true
            }
        }
        .overlay(alignment: .bottom) {
            if chat.pendingCount > 0 {
                Button {
                    chat.paused = false
                    withAnimation { position.scrollTo(edge: .top) }
                } label: {
                    Label(chat.pendingCount == 1 ? "1 mensaje nuevo" : "\(chat.pendingCount) mensajes nuevos",
                          systemImage: "arrow.down")
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
        .animation(.snappy, value: chat.pendingCount > 0)
        // Al girar el iPhone se cambia de chat (debajo del vídeo ↔ panel lateral):
        // el que aparece arranca siempre siguiendo el último mensaje
        .onAppear { chat.paused = false }
        .onDisappear { chat.paused = false }
    }
}

struct ChatRow: View {
    let message: ChatMessage

    var body: some View {
        rendered
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rendered: Text {
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
                if let image = emotes.image(url) {
                    text = Text("\(text)\(Text(Image(uiImage: image)).baselineOffset(-5))")
                } else {
                    text = Text("\(text)\(Text(verbatim: name))")
                }
            }
        }
        return text
    }
}
