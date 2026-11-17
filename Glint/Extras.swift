import BackgroundTasks
import Foundation
import Observation
import UIKit
import UserNotifications

// MARK: - Emotes de 7TV, BTTV y FFZ

/// Emotes de las extensiones que usa medio Twitch: nombre → URL de la imagen.
enum ThirdPartyEmotes {
    private static var globals: [String: String]?

    static func load(channelID: String?) async -> [String: String] {
        async let global = loadGlobals()
        var result = await global
        guard let id = channelID else { return result }
        async let seven = sevenTV("https://7tv.io/v3/users/twitch/\(id)", channel: true)
        async let bttv = betterTTV("https://api.betterttv.net/3/cached/users/twitch/\(id)", channel: true)
        async let ffz = frankerFaceZ("https://api.betterttv.net/3/cached/frankerfacez/users/twitch/\(id)")
        for set in await [ffz, bttv, seven] { result.merge(set) { _, channel in channel } }
        return result
    }

    private static func loadGlobals() async -> [String: String] {
        if let globals { return globals }
        async let seven = sevenTV("https://7tv.io/v3/emote-sets/global", channel: false)
        async let bttv = betterTTV("https://api.betterttv.net/3/cached/emotes/global", channel: false)
        async let ffz = frankerFaceZ("https://api.betterttv.net/3/cached/frankerfacez/emotes/global")
        var result: [String: String] = [:]
        for set in await [ffz, bttv, seven] { result.merge(set) { _, new in new } }
        if !result.isEmpty { globals = result }
        return result
    }

    private static func json(_ url: String) async -> Any? {
        guard let url = URL(string: url), let data = try? await URLSession.shared.data(from: url).0 else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func sevenTV(_ url: String, channel: Bool) async -> [String: String] {
        let root = await json(url) as? [String: Any]
        let set = channel ? root?["emote_set"] as? [String: Any] : root
        var result: [String: String] = [:]
        for emote in set?["emotes"] as? [[String: Any]] ?? [] {
            guard let name = emote["name"] as? String,
                  let host = (emote["data"] as? [String: Any])?["host"] as? [String: Any],
                  let base = host["url"] as? String else { continue }
            result[name] = "https:\(base)/2x.webp"
        }
        return result
    }

    private static func betterTTV(_ url: String, channel: Bool) async -> [String: String] {
        let root = await json(url)
        let emotes: [[String: Any]]
        if channel, let dict = root as? [String: Any] {
            emotes = (dict["channelEmotes"] as? [[String: Any]] ?? []) + (dict["sharedEmotes"] as? [[String: Any]] ?? [])
        } else {
            emotes = root as? [[String: Any]] ?? []
        }
        var result: [String: String] = [:]
        for emote in emotes {
            if let code = emote["code"] as? String, let id = emote["id"] as? String {
                result[code] = "https://cdn.betterttv.net/emote/\(id)/2x"
            }
        }
        return result
    }

    private static func frankerFaceZ(_ url: String) async -> [String: String] {
        var result: [String: String] = [:]
        for emote in await json(url) as? [[String: Any]] ?? [] {
            guard let code = emote["code"] as? String, let images = emote["images"] as? [String: Any],
                  let image = (images["2x"] ?? images["1x"]) as? String else { continue }
            result[code] = image
        }
        return result
    }
}

// MARK: - Miniaturas al buscar en un VOD

/// Hojas de miniaturas de Twitch: una imagen cada `interval` segundos, en rejillas.
@MainActor @Observable
final class Storyboard {
    struct Info: Decodable {
        let count: Int
        let width: Int
        let height: Int
        let cols: Int
        let rows: Int
        let interval: Double
        let images: [String]
        let quality: String?
    }

    let info: Info
    let base: URL
    private var sheets: [Int: CGImage] = [:]
    @ObservationIgnored private var requested: Set<Int> = []

    init(info: Info, base: URL) {
        self.info = info
        self.base = base
        // Son pocas hojas (~400 KB cada una): se bajan todas para que la miniatura salga al instante
        for sheet in info.images.indices { load(sheet) }
    }

    static func load(videoID: String) async -> Storyboard? {
        struct V: Decodable { let seekPreviewsURL: String? }
        struct R: Decodable { let video: V? }
        guard let r: R = try? await Twitch.query("query($id: ID!) { video(id: $id) { seekPreviewsURL } }", ["id": videoID]),
              let link = r.video?.seekPreviewsURL, let url = URL(string: link),
              let data = try? await URLSession.shared.data(from: url).0,
              let infos = try? JSONDecoder().decode([Info].self, from: data),
              let info = infos.first(where: { $0.quality == "high" }) ?? infos.first else { return nil }
        return Storyboard(info: info, base: url.deletingLastPathComponent())
    }

    /// Miniatura del segundo `time`; nil mientras se descarga su hoja.
    func frame(at time: Double) -> UIImage? {
        guard info.count > 0, info.interval > 0, info.cols > 0, info.rows > 0 else { return nil }
        let index = min(info.count - 1, max(0, Int(time / info.interval)))
        let perSheet = info.cols * info.rows
        let sheet = index / perSheet
        guard sheet < info.images.count else { return nil }
        guard let image = sheets[sheet] else {
            load(sheet)
            return nil
        }
        let cell = index % perSheet
        let rect = CGRect(x: cell % info.cols * info.width, y: cell / info.cols * info.height,
                          width: info.width, height: info.height)
        return image.cropping(to: rect).map { UIImage(cgImage: $0) }
    }

    private func load(_ sheet: Int) {
        guard requested.insert(sheet).inserted else { return }
        let url = base.appendingPathComponent(info.images[sheet])
        Task {
            guard let data = try? await URLSession.shared.data(from: url).0,
                  let image = UIImage(data: data)?.cgImage else {
                requested.remove(sheet)
                return
            }
            sheets[sheet] = image
        }
    }
}

// MARK: - Avisos de directo

extension Notification.Name {
    static let openLive = Notification.Name("glint.openLive")
}

/// Comprueba en segundo plano si algún canal seguido empezó directo y avisa.
/// iOS decide cuándo se ejecuta (suele ser cada 15–60 min).
enum LiveAlerts {
    static let taskID = "com.emilio.glint.live"
    private static let knownKey = "knownLiveStreams"

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func check() async {
        schedule()
        guard let data = UserDefaults.standard.data(forKey: "follows"),
              let follows = try? JSONDecoder().decode([ChannelRef].self, from: data), !follows.isEmpty,
              let channels = try? await Twitch.channels(follows.map(\.login)) else { return }
        let live = channels.filter { $0.stream != nil }
        let firstRun = UserDefaults.standard.object(forKey: knownKey) == nil
        let known = Set(UserDefaults.standard.stringArray(forKey: knownKey) ?? [])
        UserDefaults.standard.set(live.compactMap { $0.stream?.id }, forKey: knownKey)
        // La primera vez solo se apunta quién está en directo, para no avisar de golpe de todos
        guard !firstRun else { return }
        for channel in live where !known.contains(channel.stream?.id ?? "") {
            await notify(channel)
        }
    }

    private static func notify(_ channel: Twitch.Channel) async {
        let content = UNMutableNotificationContent()
        content.title = "\(channel.name) está en directo"
        content.body = [channel.stream?.title, channel.stream?.game?.title].compactMap { $0 }.joined(separator: "\n")
        content.sound = .default
        content.threadIdentifier = "live"
        content.userInfo = ["login": channel.login]
        if let preview = channel.stream?.previewImageURL, let url = URL(string: preview),
           let data = try? await URLSession.shared.data(from: url).0 {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(channel.login)-\(UUID().uuidString).jpg")
            if (try? data.write(to: file)) != nil,
               let attachment = try? UNNotificationAttachment(identifier: "preview", url: file) {
                content.attachments = [attachment]
            }
        }
        let request = UNNotificationRequest(identifier: channel.stream?.id ?? UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

/// Recibe el toque en un aviso de directo y lo abre en el reproductor.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Si la app se abrió desde un aviso antes de que la interfaz estuviera lista.
    static var pendingLogin: String?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let login = response.notification.request.content.userInfo["login"] as? String {
            DispatchQueue.main.async {
                AppDelegate.pendingLogin = login
                NotificationCenter.default.post(name: .openLive, object: login)
            }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
