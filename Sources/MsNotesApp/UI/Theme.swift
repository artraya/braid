import SwiftUI

/// The look of the Sessions panel and recording HUD.
///
/// Both are deliberately dark whatever the system appearance is. They are
/// heads-up surfaces that appear over whatever you are doing, and a panel that
/// flips to white during a call is more distracting than one that simply always
/// looks the same. Settings, an ordinary window, stays native.
enum Theme {
    static let panel = Color(red: 0.145, green: 0.145, blue: 0.153)
    static let card = Color(red: 0.216, green: 0.216, blue: 0.227)
    static let cardRaised = Color(red: 0.267, green: 0.267, blue: 0.278)
    static let accent = Color(red: 0.361, green: 0.416, blue: 0.961)
    static let accentDim = Color(red: 0.361, green: 0.416, blue: 0.961, opacity: 0.16)
    static let recording = Color(red: 0.925, green: 0.353, blue: 0.161)
    static let text = Color.white
    static let dim = Color(white: 0.63)
    static let faint = Color(white: 0.42)

    static let panelWidth: CGFloat = 380
    static let corner: CGFloat = 16
    static let cardCorner: CGFloat = 12
    static let padding: CGFloat = 16
}

extension View {
    /// The dark rounded surface both floating windows sit on. The border keeps
    /// the panel's edge visible against a dark desktop.
    func panelSurface(_ fill: Color = Theme.panel) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }
}
