import SwiftUI

/// Lista de favoritos: abrir, reordenar, editar y eliminar.
struct BookmarksView: View {
    let onOpen: (URL, _ newTab: Bool) -> Void

    @ObservedObject private var store = BookmarkStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var editing: Bookmark?

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.bookmarks) { bookmark in
                    Button {
                        onOpen(bookmark.url, false)
                        dismiss()
                    } label: {
                        BookmarkRow(bookmark: bookmark)
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button(role: .destructive) { store.remove(bookmark) } label: {
                            Label("Eliminar", systemImage: "trash")
                        }
                        Button { editing = bookmark } label: { Label("Editar", systemImage: "pencil") }
                            .tint(.orange)
                    }
                    .contextMenu { BookmarkMenu(bookmark: bookmark, editing: $editing, onOpen: onOpen) }
                }
                .onMove { store.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { store.remove(atOffsets: $0) }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if store.bookmarks.isEmpty {
                    ContentUnavailableView("Sin favoritos", systemImage: "star",
                                           description: Text("Añade la página que estás viendo desde el menú ⋯ → Añadir a favoritos."))
                }
            }
            .navigationTitle("Favoritos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton().disabled(store.bookmarks.isEmpty) }
                ToolbarItem(placement: .topBarTrailing) { Button("Listo") { dismiss() }.bold() }
            }
            .sheet(item: $editing) { BookmarkEditor(bookmark: $0) }
        }
    }
}

/// Acciones de un favorito (lista y página de inicio).
struct BookmarkMenu: View {
    let bookmark: Bookmark
    @Binding var editing: Bookmark?
    let onOpen: (URL, _ newTab: Bool) -> Void

    var body: some View {
        Button { onOpen(bookmark.url, true) } label: {
            Label("Abrir en pestaña nueva", systemImage: "plus.square.on.square")
        }
        Button { UIPasteboard.general.url = bookmark.url } label: {
            Label("Copiar enlace", systemImage: "doc.on.doc")
        }
        Button { editing = bookmark } label: { Label("Editar", systemImage: "pencil") }
        Divider()
        Button(role: .destructive) { BookmarkStore.shared.remove(bookmark) } label: {
            Label("Eliminar", systemImage: "trash")
        }
    }
}

private struct BookmarkRow: View {
    let bookmark: Bookmark

    var body: some View {
        HStack(spacing: 12) {
            SiteInitial(host: bookmark.host)
            VStack(alignment: .leading, spacing: 2) {
                Text(bookmark.title).lineLimit(1)
                Text(bookmark.host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// Inicial del sitio en un cuadrado naranja (no se descargan favicons: menos rastreo).
struct SiteInitial: View {
    let host: String
    var size: CGFloat = 32

    var body: some View {
        Text(String(host.prefix(1)).uppercased())
            .font(size > 40 ? .title2.bold() : .subheadline.bold())
            .foregroundStyle(.orange)
            .frame(width: size, height: size)
            .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: size * 0.25))
    }
}

/// Crear o editar un favorito. Si el id no existe en la lista, se añade.
struct BookmarkEditor: View {
    let bookmark: Bookmark
    @State private var name: String
    @State private var address: String
    @Environment(\.dismiss) private var dismiss

    init(bookmark: Bookmark) {
        self.bookmark = bookmark
        _name = State(initialValue: bookmark.title)
        _address = State(initialValue: bookmark.url.absoluteString)
    }

    private var isNew: Bool { !BookmarkStore.shared.bookmarks.contains { $0.id == bookmark.id } }
    private var url: URL? { URLBuilder.address(from: address) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nombre", text: $name)
                    TextField("Dirección", text: $address)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    if url == nil { Text("Escribe una dirección válida, por ejemplo ejemplo.com.") }
                }
            }
            .navigationTitle(isNew ? "Añadir a favoritos" : "Editar favorito")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        guard let url else { return }
                        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        BookmarkStore.shared.upsert(Bookmark(id: bookmark.id,
                                                             title: title.isEmpty ? HistoryStore.normalizedHost(url) : title,
                                                             url: url))
                        dismiss()
                    }
                    .bold()
                    .disabled(url == nil)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
