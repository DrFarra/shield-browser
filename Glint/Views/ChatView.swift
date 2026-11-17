import SwiftUI

/// Chat en vivo. Sigue al último mensaje; si subes para leer, se pausa y avisa
/// de cuántos mensajes nuevos hay en vez de arrastrarte hacia abajo.
struct ChatView: View {
    let chat: ChatClient
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var interacting = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(chat.messages) { ChatRow(message: $0) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        .scrollIndicators(.hidden)
        .onScrollPhaseChange { _, phase in
            interacting = phase == .interacting
        }
        .onScrollGeometryChange(for: Bool.self) { geo in
            geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 30
        } action: { _, atBottom in
            if atBottom {
                chat.paused = false
            } else if interacting {
                chat.paused = true
            }
        }
        .overlay(alignment: .bottom) {
            if chat.pendingCount > 0 {
                Button {
                    chat.paused = false
                    withAnimation { position.scrollTo(edge: .bottom) }
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
                Text("Conectando al chat…")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .animation(.snappy, value: chat.pendingCount > 0)
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
            case .emote(let id, let name):
                if let image = emotes.image(id) {
                    text = Text("\(text)\(Text(Image(uiImage: image)).baselineOffset(-6))")
                } else {
                    text = Text("\(text)\(Text(verbatim: name))")
                }
            }
        }
        return text
    }
}
