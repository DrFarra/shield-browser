import SwiftUI
import QuickLook
import QuickLookThumbnailing

struct DownloadsView: View {
    /// Como hoja propia lleva botón "Listo"; dentro de otra pantalla, no.
    var showsDone = false

    @ObservedObject private var manager = DownloadManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var files: [URL] = []
    @State private var preview: URL?
    @State private var message: String?
    @State private var confirmDeleteAll = false

    var body: some View {
        let pending = manager.items.filter { !isFinished($0) }
        List {
            if !pending.isEmpty {
                Section("En curso") {
                    ForEach(pending) { item in
                        DownloadRow(item: item) { manager.remove(item) }
                            .swipeActions {
                                Button(item.isRunning ? "Cancelar" : "Quitar", role: .destructive) { manager.remove(item) }
                            }
                    }
                }
            }
            if !files.isEmpty {
                Section {
                    ForEach(files, id: \.self) { url in
                        Button { preview = url } label: {
                            FileRow(url: url, note: note(for: url)) { actions(for: url) }
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button("Borrar", role: .destructive) { delete(url) }
                            ShareLink(item: url) { Label("Compartir", systemImage: "square.and.arrow.up") }
                                .tint(.blue)
                        }
                        .contextMenu { actions(for: url) }
                    }
                } header: {
                    Text("Guardadas")
                } footer: {
                    Text("\(files.count == 1 ? "1 archivo" : "\(files.count) archivos") · \(totalSize). También en Archivos → En mi iPhone → Shield.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if pending.isEmpty && files.isEmpty {
                ContentUnavailableView("Sin descargas", systemImage: "arrow.down.circle",
                                       description: Text("Los vídeos, imágenes y archivos que descargues aparecerán aquí."))
            }
        }
        .navigationTitle("Descargas")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if !files.isEmpty {
                    Button("Borrar todo", role: .destructive) { confirmDeleteAll = true }
                }
            }
            if showsDone {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Listo") { dismiss() }.bold()
                }
            }
        }
        .confirmationDialog("¿Borrar \(files.count) descargas?", isPresented: $confirmDeleteAll,
                            titleVisibility: .visible) {
            Button("Borrar todo", role: .destructive) {
                files.forEach { try? FileManager.default.removeItem(at: $0) }
                reload()
            }
        } message: {
            Text("Lo que ya guardaste en Fotos no se borra.")
        }
        .quickLookPreview($preview, in: files)
        .onAppear(perform: reload)
        .onChange(of: manager.finishedCount) { _, _ in reload() }
        .alert("Fotos", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    @ViewBuilder private func actions(for url: URL) -> some View {
        if DownloadManager.canSaveToPhotos(url) {
            Button { save(url) } label: { Label("Guardar en Fotos", systemImage: "photo") }
        }
        ShareLink(item: url) { Label("Compartir", systemImage: "square.and.arrow.up") }
        Divider()
        Button(role: .destructive) { delete(url) } label: { Label("Borrar", systemImage: "trash") }
    }

    private var totalSize: String {
        let bytes = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func isFinished(_ item: DownloadItem) -> Bool {
        if case .finished = item.state { return true }
        return false
    }

    private func note(for url: URL) -> String? {
        manager.items.first { $0.state == .finished(url) }?.note
    }

    private func reload() {
        let folder = DownloadManager.folder
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        files = urls
            .filter { !$0.hasDirectoryPath }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return a > b
            }
    }

    private func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        reload()
    }

    private func save(_ url: URL) {
        Task {
            message = await DownloadManager.saveToPhotos(url) ?? "Guardado en Fotos ✓"
        }
    }
}

private struct DownloadRow: View {
    @ObservedObject var item: DownloadItem
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            FileIcon(symbol: item.kind == .image ? "photo" : item.kind == .file ? "doc" : "film")
            VStack(alignment: .leading, spacing: 5) {
                Text(item.name).font(.subheadline.weight(.medium)).lineLimit(1)
                switch item.state {
                case .running:
                    ProgressView(value: item.progress).tint(.shield)
                    Text(item.progress > 0 ? "Descargando · \(Int(item.progress * 100)) %" : "Conectando…")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                case .failed(let reason):
                    Label(reason, systemImage: "exclamationmark.circle.fill")
                        .font(.caption).foregroundStyle(.red).lineLimit(2)
                case .finished:
                    EmptyView()
                }
            }
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(item.isRunning ? "Cancelar descarga" : "Quitar de la lista")
        }
        .padding(.vertical, 2)
    }
}

private struct FileRow<Actions: View>: View {
    let url: URL
    let note: String?
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 12) {
            FileThumbnail(url: url)
            VStack(alignment: .leading, spacing: 3) {
                Text(url.lastPathComponent).font(.subheadline.weight(.medium)).lineLimit(2)
                Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let note {
                    Text(note).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            Menu(content: actions) {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Opciones")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// "12,4 MB · ayer"
    private var details: String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
        let size = ByteCountFormatter.string(fromByteCount: Int64(values?.fileSize ?? 0), countStyle: .file)
        guard let date = values?.creationDate else { return size }
        return size + " · " + date.formatted(.relative(presentation: .named))
    }
}

private struct FileIcon: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.title3)
            .foregroundStyle(Color.shield)
            .frame(width: 52, height: 52)
            .background(Color.shield.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Miniatura real del archivo (foto, fotograma del vídeo, primera página del PDF…).
private struct FileThumbnail: View {
    let url: URL
    @State private var image: UIImage?
    @Environment(\.displayScale) private var scale

    private var isVideo: Bool { DownloadManager.isVideo(url) || url.pathExtension.lowercased() == "ts" }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                if isVideo {
                    Image(systemName: "play.fill").font(.caption).foregroundStyle(.white)
                        .shadow(radius: 2)
                }
            } else {
                FileIcon(symbol: DownloadManager.isImage(url) ? "photo" : isVideo ? "film" : "doc")
            }
        }
        .task(id: url) {
            // Sólo donde la miniatura aporta algo: en texto y demás sale un recuadro en blanco.
            guard DownloadManager.canSaveToPhotos(url) || url.pathExtension.lowercased() == "pdf" else { return }
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 52, height: 52),
                                                       scale: scale, representationTypes: .thumbnail)
            image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).uiImage
        }
    }
}
