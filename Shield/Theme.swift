import SwiftUI

/// Colores de la app. Al estar en ShapeStyle sirven igual como `Color.shield` y como `.foregroundStyle(.shield)`.
extension ShapeStyle where Self == Color {
    /// Marca de Shield: naranja ámbar, más cálido y sobrio que el naranja del sistema.
    static var shield: Color { Color(red: 0.96, green: 0.42, blue: 0.13) }
    /// Pestañas privadas.
    static var privateTab: Color { Color(red: 0.49, green: 0.33, blue: 0.86) }
}
