import AVFoundation
import SwiftUI

@main
struct GlintApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var library = Library()
    @State private var playback = Playback()
    @State private var router = Router()

    init() {
        // Sonido con el iPhone en silencio, audio en segundo plano y Picture in Picture
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        // Miniaturas y avatares en caché para que las listas no vuelvan a descargarlos
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .environment(playback)
                .environment(router)
                .preferredColorScheme(.dark)
                .tint(.glint)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { LiveAlerts.schedule() }
        }
        .backgroundTask(.appRefresh(LiveAlerts.taskID)) {
            await LiveAlerts.check()
        }
    }
}

struct RootView: View {
    @Environment(Router.self) private var router
    @Environment(Playback.self) private var playback
    @Environment(Library.self) private var library

    var body: some View {
        @Bindable var router = router
        // Hueco para que la tarjeta mini no tape el final de las listas
        let inset: CGFloat = playback.media != nil ? 76 : 0

        ZStack {
            TabView(selection: $router.tab) {
                Tab("Inicio", systemImage: "play.square.stack", value: Router.Tab.home) {
                    NavigationStack(path: $router.home) { HomeView().appDestinations() }
                        .safeAreaPadding(.bottom, inset)
                }
                Tab("Explorar", systemImage: "square.grid.2x2", value: Router.Tab.browse) {
                    NavigationStack(path: $router.browse) { BrowseView().appDestinations() }
                        .safeAreaPadding(.bottom, inset)
                }
                Tab(value: Router.Tab.search, role: .search) {
                    NavigationStack(path: $router.search) { SearchView().appDestinations() }
                        .safeAreaPadding(.bottom, inset)
                }
            }

            PlayerHost()
        }
        .onAppear {
            playback.library = library
            if let login = AppDelegate.pendingLogin {
                AppDelegate.pendingLogin = nil
                playback.play(.live(login))
            }
        }
        // Toque en un aviso de "está en directo"
        .onReceive(NotificationCenter.default.publisher(for: .openLive)) { note in
            guard let login = note.object as? String else { return }
            AppDelegate.pendingLogin = nil
            playback.play(.live(login))
        }
        .task { await Demo.run(router: router, playback: playback, library: library) }
    }
}
