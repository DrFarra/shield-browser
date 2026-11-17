import SwiftUI

extension ShapeStyle where Self == Color {
    /// Color de la marca: menta, se lee bien sobre negro y no compite con el rojo de "en directo".
    static var glint: Color { Color(red: 0.40, green: 0.90, blue: 0.72) }
    static var live: Color { Color(red: 0.95, green: 0.22, blue: 0.27) }
    static var surface: Color { Color(white: 0.11) }
}

enum Format {
    private static let spanish = Locale(identifier: "es")

    /// 50754 → "51 mil"
    static func count(_ n: Int) -> String {
        n.formatted(.number.notation(.compactName).locale(spanish))
    }

    /// 5025 → "1:23:45", 83 → "1:23"
    static func clock(_ seconds: Double) -> String {
        let t = Int(max(0, seconds.isFinite ? seconds : 0))
        let h = t / 3600, m = t / 60 % 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func uptime(since date: Date?) -> String? {
        guard let date else { return nil }
        return clock(Date().timeIntervalSince(date))
    }

    static func ago(_ date: Date?) -> String {
        guard let date else { return "" }
        return date.formatted(.relative(presentation: .named).locale(spanish))
    }
}
