import SwiftUI

/// Página de inicio: protección, favoritos y lo visitado hace poco.
struct StartPageView: View {
    let isPrivate: Bool
    let open: (URL, _ newTab: Bool) -> Void

    var body: some View {
        if isPrivate {
            PrivateStartPage()
        } else {
            NormalStartPage(open: open)
        }
    }
}

private struct NormalStartPage: View {
    let open: (URL, _ newTab: Bool) -> Void
    @EnvironmentObject private var blocker: ContentBlocker
    @ObservedObject private var store = BookmarkStore.shared
    @ObservedObject private var history = HistoryStore.shared
    @AppStorage(ShieldStats.totalKey) private var totalBlocked = 0
    @State private var editing: Bookmark?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                protectionCard
                favorites
                recents
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(Color(.systemGroupedBackground))
        .sheet(item: $editing) { BookmarkEditor(bookmark: $0) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            BrandBadge(size: 40)
            Text("Shield")
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Spacer()
        }
        .padding(.top, 20)
    }

    private var protectionCard: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Label(ShieldSettings.globalShields ? "Protección activa" : "Protección desactivada",
                      systemImage: ShieldSettings.globalShields ? "checkmark.shield.fill" : "shield.slash")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ShieldSettings.globalShields ? Color.shield : Color.secondary)
                if blocker.isReady {
                    Text("\(blocker.ruleCount.formatted()) reglas contra anuncios y rastreadores")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(blocker.status).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 0) {
                Text(totalBlocked.formatted(.number.notation(.compactName)))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text("bloqueados")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder private var favorites: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle("Favoritos")
            if store.bookmarks.isEmpty {
                Text("Abre una página y toca ⋯ → Añadir a favoritos para tenerla aquí.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: columns, alignment: .center, spacing: 18) {
                    ForEach(store.bookmarks) { bookmark in
                        Button { open(bookmark.url, false) } label: {
                            VStack(spacing: 7) {
                                SiteIcon(host: bookmark.host, size: 60)
                                    .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
                                Text(bookmark.title)
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu { BookmarkMenu(bookmark: bookmark, editing: $editing, onOpen: open) }
                    }
                }
            }
        }
    }

    @ViewBuilder private var recents: some View {
        let recent = Array(history.entries.prefix(4))
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle("Visitado recientemente")
                VStack(spacing: 0) {
                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, entry in
                        Button { open(entry.url, false) } label: {
                            SiteRow(entry: entry)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        if index < recent.count - 1 {
                            Divider().padding(.leading, 58)
                        }
                    }
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.title3.weight(.bold))
    }
}

/// Insignia de la marca: el mismo dibujo que el icono de la app.
struct BrandBadge: View {
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: "shield.lefthalf.filled")
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [Color(red: 1, green: 0.59, blue: 0.24), Color(red: 0.87, green: 0.24, blue: 0.09)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .accessibilityHidden(true)
    }
}

private struct PrivateStartPage: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 14) {
                    Image(systemName: "eyeglasses")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 76, height: 76)
                        .background(Color.privateTab.gradient, in: Circle())
                    Text("Navegación privada")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("Shield no recordará lo que visites en esta pestaña.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 72)

                VStack(alignment: .leading, spacing: 16) {
                    PrivateFact(icon: "clock.badge.xmark", text: "No se guarda en el historial ni en las sugerencias.")
                    PrivateFact(icon: "trash", text: "Cookies, caché y sesiones se borran al cerrar la pestaña.")
                    PrivateFact(icon: "shield.lefthalf.filled", text: "El bloqueo de anuncios y rastreadores sigue activo.")
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground).opacity(0.7),
                            in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .padding(.horizontal, 24)
        }
        .scrollIndicators(.hidden)
        .background {
            LinearGradient(colors: [Color.privateTab.opacity(0.22), Color(.systemGroupedBackground)],
                           startPoint: .top, endPoint: .center)
                .ignoresSafeArea()
        }
    }
}

private struct PrivateFact: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.privateTab)
                .frame(width: 24)
            Text(text).font(.subheadline)
        }
    }
}
