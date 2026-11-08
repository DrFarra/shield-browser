import SwiftUI

/// Historial agrupado por día, con búsqueda, borrado por deslizamiento y borrado por periodo.
struct HistoryView: View {
    /// Abre la página: en la pestaña actual o en una nueva.
    let onOpen: (URL, _ newTab: Bool) -> Void

    @ObservedObject private var history = HistoryStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var confirmClear = false

    private struct Day: Identifiable {
        let id: Date
        var entries: [HistoryEntry]
    }

    /// Las entradas ya vienen de la más reciente a la más antigua.
    private var days: [Day] {
        let calendar = Calendar.current
        let q = search.trimmingCharacters(in: .whitespaces)
        var result: [Day] = []
        for entry in history.entries where q.isEmpty || entry.matches(q) {
            let day = calendar.startOfDay(for: entry.lastVisit)
            if result.last?.id == day { result[result.count - 1].entries.append(entry) }
            else { result.append(Day(id: day, entries: [entry])) }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            let days = days
            List {
                ForEach(days) { day in
                    Section(title(for: day.id)) {
                        ForEach(day.entries) { entry in
                            Button {
                                onOpen(entry.url, false)
                                dismiss()
                            } label: {
                                SiteRow(entry: entry, time: entry.lastVisit)
                            }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button(role: .destructive) { history.remove(entry) } label: {
                                    Label("Eliminar", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                Button { onOpen(entry.url, true); dismiss() } label: {
                                    Label("Abrir en pestaña nueva", systemImage: "plus.square.on.square")
                                }
                                Button { UIPasteboard.general.url = entry.url } label: {
                                    Label("Copiar enlace", systemImage: "doc.on.doc")
                                }
                                ShareLink(item: entry.url) { Label("Compartir", systemImage: "square.and.arrow.up") }
                                Divider()
                                Button(role: .destructive) { history.remove(entry) } label: {
                                    Label("Eliminar del historial", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if days.isEmpty {
                    if search.isEmpty {
                        ContentUnavailableView("Sin historial", systemImage: "clock",
                                               description: Text("Las páginas que visites aparecerán aquí. Las pestañas privadas no se guardan."))
                    } else {
                        ContentUnavailableView.search(text: search)
                    }
                }
            }
            .searchable(text: $search, prompt: "Buscar en el historial")
            .navigationTitle("Historial")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Borrar", role: .destructive) { confirmClear = true }
                        .disabled(history.entries.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Listo") { dismiss() }.bold()
                }
            }
            .confirmationDialog("Borrar historial", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("La última hora", role: .destructive) { history.clear(since: Date().addingTimeInterval(-3600)) }
                Button("Hoy", role: .destructive) { history.clear(since: Calendar.current.startOfDay(for: Date())) }
                Button("Hoy y ayer", role: .destructive) {
                    let today = Calendar.current.startOfDay(for: Date())
                    history.clear(since: Calendar.current.date(byAdding: .day, value: -1, to: today))
                }
                Button("Todo el historial", role: .destructive) { history.clear() }
            } message: {
                Text("Las cookies y la caché se borran desde Ajustes.")
            }
        }
    }

    private func title(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Hoy" }
        if calendar.isDateInYesterday(day) { return "Ayer" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide)).capitalized
    }
}
