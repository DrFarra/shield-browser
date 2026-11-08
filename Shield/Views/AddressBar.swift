import SwiftUI
import UIKit

/// Campo de la barra de direcciones. Al tocarlo selecciona toda la dirección (escribir
/// la reemplaza) y completa en línea los dominios del historial, como Safari.
struct AddressField: UIViewRepresentable {
    /// Lo que escribió el usuario, sin la parte autocompletada (para las sugerencias).
    @Binding var query: String
    @Binding var isEditing: Bool
    let currentURL: String
    let onSubmit: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.edited(_:)), for: .editingChanged)
        field.placeholder = "Buscar o escribir dirección"
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.keyboardType = .webSearch
        field.returnKeyType = .go
        field.textContentType = .URL
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.clearButtonMode = .whileEditing
        field.tintColor = .systemOrange
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if isEditing != field.isFirstResponder {
            // Fuera del ciclo de actualización: el delegado modifica el estado de SwiftUI.
            DispatchQueue.main.async {
                if isEditing { field.becomeFirstResponder() } else { field.resignFirstResponder() }
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: AddressField
        init(_ parent: AddressField) { self.parent = parent }

        func textFieldDidBeginEditing(_ field: UITextField) {
            field.text = parent.currentURL
            parent.query = ""
            if !parent.isEditing { parent.isEditing = true }
            // Hay que esperar a que UIKit coloque el cursor tras el toque.
            DispatchQueue.main.async { field.selectAll(nil) }
        }

        func textFieldDidEndEditing(_ field: UITextField) {
            if parent.isEditing { parent.isEditing = false }
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            let text = (field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return false }
            parent.onSubmit(text)
            return false
        }

        func textFieldShouldClear(_ field: UITextField) -> Bool {
            parent.query = ""
            return true
        }

        /// Teclados con composición (chino, japonés…): sin autocompletar.
        @objc func edited(_ field: UITextField) {
            parent.query = field.text ?? ""
        }

        func textField(_ field: UITextField, shouldChangeCharactersIn range: NSRange,
                       replacementString string: String) -> Bool {
            guard field.markedTextRange == nil else { return true }
            let current = (field.text ?? "") as NSString
            let typed = current.replacingCharacters(in: range, with: string)
            parent.query = typed

            // Sólo se completa al escribir al final, nunca al borrar.
            let atEnd = range.location + range.length == current.length
            let suffix = !string.isEmpty && atEnd ? HistoryStore.shared.completion(for: typed) : nil
            field.text = typed + (suffix ?? "")

            let caret = suffix == nil ? range.location + (string as NSString).length : (typed as NSString).length
            if let start = field.position(from: field.beginningOfDocument, offset: caret) {
                field.selectedTextRange = field.textRange(from: start, to: suffix == nil ? start : field.endOfDocument)
            }
            return false
        }
    }
}

/// Sugerencias mientras se escribe: ir a la dirección o buscar, y páginas del historial.
struct SuggestionsView: View {
    let query: String
    let onOpen: (String) -> Void
    @ObservedObject private var history = HistoryStore.shared

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = history.suggestions(for: q)
        List {
            if !q.isEmpty {
                Section {
                    Button { onOpen(q) } label: { primaryRow(q) }
                        .buttonStyle(.plain)
                }
            }
            if !matches.isEmpty {
                Section(q.isEmpty ? "Recientes" : "Historial") {
                    ForEach(matches) { entry in
                        Button { onOpen(entry.url.absoluteString) } label: { SiteRow(entry: entry) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.never)
        .overlay {
            if q.isEmpty && matches.isEmpty {
                ContentUnavailableView("Escribe una dirección o búsqueda", systemImage: "magnifyingglass",
                                       description: Text("Las páginas que visites aparecerán aquí."))
            }
        }
    }

    private func primaryRow(_ q: String) -> some View {
        let address = URLBuilder.address(from: q)
        return HStack(spacing: 12) {
            Image(systemName: address == nil ? "magnifyingglass" : "globe")
                .font(.body.weight(.semibold))
                .foregroundStyle(.orange)
                .frame(width: 32, height: 32)
                .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(q).lineLimit(1)
                Text(address == nil ? "Buscar en \(ShieldSettings.searchEngine.name)" : "Ir a la página")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.left").font(.caption).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

/// Fila de una página: inicial del sitio, título y dominio.
struct SiteRow: View {
    let entry: HistoryEntry
    var time: Date?

    var body: some View {
        HStack(spacing: 12) {
            SiteInitial(host: entry.host)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayTitle).lineLimit(1)
                Text(entry.host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let time {
                Text(time.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}
