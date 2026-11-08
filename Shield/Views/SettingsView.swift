import SwiftUI
import WebKit

struct SettingsView: View {
    @EnvironmentObject private var blocker: ContentBlocker
    @EnvironmentObject private var tabs: TabManager
    @Environment(\.dismiss) private var dismiss

    @AppStorage(ShieldSettings.searchEngineKey) private var engine = SearchEngine.duckDuckGo.rawValue
    @AppStorage(ShieldSettings.globalShieldsKey) private var globalShields = true
    @AppStorage(DownloadManager.autoSaveKey) private var autoSaveToPhotos = true
    @AppStorage(ShieldSettings.nativePlayerKey) private var nativePlayer = true
    @State private var confirmClear = false
    @State private var confirmResetSites = false
    @State private var cleared = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(selection: $engine) {
                        ForEach(SearchEngine.allCases) { Text($0.name).tag($0.rawValue) }
                    } label: {
                        SettingsLabel("Motor de búsqueda", icon: "magnifyingglass", color: .blue)
                    }
                    .pickerStyle(.navigationLink)
                }

                Section {
                    Toggle(isOn: $globalShields) {
                        SettingsLabel("Bloquear anuncios y rastreadores", icon: "shield.lefthalf.filled", color: .shield)
                    }
                    .onChange(of: globalShields) { _, _ in tabs.tabs.forEach { $0.reload() } }
                    LabeledContent {
                        Text(blocker.ruleCount.formatted())
                    } label: {
                        SettingsLabel("Reglas activas", icon: "list.bullet.rectangle", color: .gray)
                    }
                    Button { confirmResetSites = true } label: {
                        SettingsLabel("Restablecer excepciones por sitio", icon: "arrow.counterclockwise", color: .gray)
                    }
                    .foregroundStyle(.primary)
                } header: {
                    Text("Protección")
                } footer: {
                    Text("EasyList, EasyPrivacy, EasyList Español, Peter Lowe y HaGeZi. Las listas se actualizan con cada versión de la app."
                         + (blocker.droppedRules > 0 ? " \(blocker.droppedRules) reglas no compatibles se omitieron." : ""))
                }

                Section {
                    Toggle(isOn: $nativePlayer) {
                        SettingsLabel("Reproductor del iPhone", icon: "play.rectangle.fill", color: .red)
                    }
                    .onChange(of: nativePlayer) { _, on in tabs.tabs.forEach { $0.setNativePlayer(on) } }
                    Toggle(isOn: $autoSaveToPhotos) {
                        SettingsLabel("Guardar descargas en Fotos", icon: "photo.on.rectangle", color: .orange)
                    }
                    NavigationLink { DownloadsView() } label: {
                        SettingsLabel("Descargas", icon: "arrow.down", color: .blue)
                    }
                } header: {
                    Text("Vídeos y descargas")
                } footer: {
                    Text("Los vídeos se abren en el reproductor del iPhone, con descarga, Picture in Picture y AirPlay. Las descargas también están en Archivos → En mi iPhone → Shield.")
                }

                Section {
                    Button(role: .destructive) { confirmClear = true } label: {
                        SettingsLabel("Borrar historial y datos de sitios", icon: "trash.fill", color: .red)
                    }
                    .foregroundStyle(.red)
                } header: {
                    Text("Privacidad")
                } footer: {
                    Text(cleared ? "Historial, cookies y caché borrados." : "Las pestañas privadas nunca guardan historial, cookies ni caché.")
                }

                Section {
                    LabeledContent("Versión", value: version)
                    LabeledContent("Motor", value: "WebKit")
                }
            }
            .tint(.shield)
            .navigationTitle("Ajustes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() } }
            }
            .confirmationDialog("Se borrarán el historial, las cookies y la caché. Tendrás que volver a iniciar sesión en los sitios.",
                                isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Borrar historial y datos", role: .destructive) { clearData() }
            }
            .confirmationDialog("Los escudos volverán a estar activos en todos los sitios.",
                                isPresented: $confirmResetSites, titleVisibility: .visible) {
                Button("Restablecer", role: .destructive) { ShieldSettings.resetSiteExceptions() }
            }
        }
    }

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        return "\(short) (\(build))"
    }

    private func clearData() {
        HistoryStore.shared.clear()
        WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                                modifiedSince: .distantPast) { cleared = true }
    }
}

/// Fila con icono en cuadro de color, como la app Ajustes.
struct SettingsLabel: View {
    let title: String
    let icon: String
    let color: Color

    init(_ title: String, icon: String, color: Color) {
        self.title = title
        self.icon = icon
        self.color = color
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 29, height: 29)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }
}
