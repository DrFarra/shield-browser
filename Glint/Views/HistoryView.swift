import SwiftUI

/// Todos los VOD vistos, del más reciente al más antiguo.
struct HistoryView: View {
    @Environment(Library.self) private var library
    @Environment(Playback.self) private var playback
    @State private var confirmClear = false

    var body: some View {
        List {
            ForEach(library.watched) { item in
                Button { playback.play(.video(item.id)) } label: {
                    HStack(alignment: .top, spacing: 12) {
                        WatchedThumbnail(item: item)
                            .frame(width: 150)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Text(item.channel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(status(item))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button("Quitar", systemImage: "trash", role: .destructive) {
                        withAnimation { library.removeWatched(item.id) }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Historial")
        .toolbar {
            if !library.watched.isEmpty {
                Button("Borrar") { confirmClear = true }
            }
        }
        .confirmationDialog("¿Borrar todo el historial?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Borrar historial", role: .destructive) { withAnimation { library.clearWatched() } }
        } message: {
            Text("Se olvidará también por dónde ibas en cada vídeo.")
        }
        .overlay {
            if library.watched.isEmpty {
                ContentUnavailableView("Sin vídeos vistos", systemImage: "clock.arrow.circlepath",
                                       description: Text("Los vídeos que veas aparecerán aquí y podrás seguirlos donde los dejaste."))
            }
        }
    }

    private func status(_ item: WatchedVideo) -> String {
        let left = item.length - item.position
        let progress = item.progress > 0.97 ? "Visto" : left > 0 ? "Quedan \(Format.clock(left))" : ""
        return [progress, Format.ago(item.date)].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Miniatura de un vídeo visto con la barra de progreso.
struct WatchedThumbnail: View {
    let item: WatchedVideo

    var body: some View {
        Thumbnail(url: item.thumbnail, corner: 10)
            .overlay(alignment: .bottomTrailing) {
                Text(Format.clock(item.length))
                    .font(.caption2.weight(.medium)).monospacedDigit()
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.black.opacity(0.7), in: Capsule())
                    .padding(.horizontal, 6).padding(.bottom, 9)
            }
            .overlay(alignment: .bottom) { WatchProgress(value: item.progress) }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
