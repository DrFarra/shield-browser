import SwiftUI

struct StartPageView: View {
    let isPrivate: Bool
    let open: (URL, _ newTab: Bool) -> Void
    @EnvironmentObject private var blocker: ContentBlocker
    @ObservedObject private var store = BookmarkStore.shared
    @State private var editing: Bookmark?

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 8) {
                    Image(systemName: isPrivate ? "eyeglasses" : "shield.lefthalf.filled")
                        .font(.system(size: 56))
                        .foregroundStyle(isPrivate ? Color.purple : Color.orange)
                    Text(isPrivate ? "Pestaña privada" : "Shield")
                        .font(.largeTitle.bold())
                    Text(isPrivate
                         ? "No se guarda historial, cookies ni caché al cerrar."
                         : "Navegación sin anuncios ni rastreadores.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 60)

                if !blocker.isReady {
                    HStack(spacing: 6) {
                        ProgressView()
                        Text(blocker.status).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    Text("Favoritos").font(.title3.bold())
                    if store.bookmarks.isEmpty {
                        Text("Abre una página y toca ⋯ → Añadir a favoritos para tenerla aquí.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 18) {
                            ForEach(store.bookmarks) { bookmark in
                                Button { open(bookmark.url, false) } label: {
                                    VStack(spacing: 6) {
                                        SiteInitial(host: bookmark.host, size: 58)
                                        Text(bookmark.title)
                                            .font(.caption)
                                            .lineLimit(1)
                                            .foregroundStyle(.primary)
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.plain)
                                .contextMenu { BookmarkMenu(bookmark: bookmark, editing: $editing, onOpen: open) }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 24)
        }
        .background(isPrivate ? Color.purple.opacity(0.08) : Color(.systemBackground))
        .sheet(item: $editing) { BookmarkEditor(bookmark: $0) }
    }
}
