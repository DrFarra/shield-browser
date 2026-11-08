import SwiftUI

/// Pestañas en cuadrícula con miniatura, como Safari.
struct TabsView: View {
    @EnvironmentObject private var tabs: TabManager
    @Environment(\.dismiss) private var dismiss
    @State private var confirmCloseAll = false

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(tabs.tabs) { tab in
                            TabCard(tab: tab, selected: tab.id == tabs.selectedID) {
                                withAnimation(.snappy) { tabs.close(tab) }
                            }
                            .id(tab.id)
                            .onTapGesture {
                                tabs.select(tab)
                                dismiss()
                            }
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                        }
                    }
                    .padding(16)
                }
                .onAppear { proxy.scrollTo(tabs.selectedID, anchor: .center) }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(tabs.tabs.count == 1 ? "1 pestaña" : "\(tabs.tabs.count) pestañas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cerrar todas", role: .destructive) { confirmCloseAll = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Listo") { dismiss() }.bold()
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { tabs.newTab(isPrivate: true); dismiss() } label: {
                        Label("Privada", systemImage: "eyeglasses")
                    }
                    Spacer()
                    Button { tabs.newTab(); dismiss() } label: {
                        Image(systemName: "plus").font(.title2)
                    }
                    .accessibilityLabel("Nueva pestaña")
                    Spacer()
                    Color.clear.frame(width: 44)   // centra el botón +
                }
            }
            .confirmationDialog("¿Cerrar \(tabs.tabs.count) pestañas?", isPresented: $confirmCloseAll,
                                titleVisibility: .visible) {
                Button("Cerrar todas", role: .destructive) { tabs.closeAll(); dismiss() }
            }
        }
    }
}

private struct TabCard: View {
    @ObservedObject var tab: BrowserTab
    let selected: Bool
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if tab.isPrivate {
                    Image(systemName: "eyeglasses").font(.caption).foregroundStyle(.purple)
                }
                Text(tab.title.isEmpty ? (tab.url?.host() ?? "Nueva pestaña") : tab.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cerrar pestaña")
            }
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .frame(height: 32)
            .background(.bar)

            preview
                .frame(maxWidth: .infinity)
                .frame(height: 190)
                .clipped()
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(selected ? Color.orange : Color.primary.opacity(0.08), lineWidth: selected ? 3 : 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder private var preview: some View {
        if let image = tab.snapshot {
            // Rellena el ancho y muestra la parte de arriba de la página.
            Color.clear.overlay(alignment: .top) {
                Image(uiImage: image).resizable().scaledToFill()
            }
        } else if let url = tab.url {
            SiteInitial(host: HistoryStore.normalizedHost(url), size: 56)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Image(systemName: tab.isPrivate ? "eyeglasses" : "shield.lefthalf.filled")
                .font(.largeTitle)
                .foregroundStyle(tab.isPrivate ? Color.purple : Color.orange)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
