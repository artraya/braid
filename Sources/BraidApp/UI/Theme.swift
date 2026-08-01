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
    /// Cautionary but not alarming: the speaker-count mismatch line.
    static let warning = Color(red: 0.945, green: 0.702, blue: 0.278)
    static let text = Color.white
    static let dim = Color(white: 0.63)
    static let faint = Color(white: 0.42)

    static let panelWidth: CGFloat = 380
    static let corner: CGFloat = 16
    static let cardCorner: CGFloat = 12
    static let padding: CGFloat = 16
    /// The pointer that ties the Sessions panel to its menu bar icon.
    static let arrowHeight: CGFloat = 9
    static let arrowWidth: CGFloat = 20
}

/// The panel outline: a rounded rectangle with a triangle on top pointing at
/// the menu bar icon. Drawn as one continuous path rather than a rectangle with
/// a triangle laid over it, so the border strokes cleanly around the point
/// instead of showing a seam where the two shapes meet.
///
/// `arrowX` is measured from the panel's left edge, because the panel gets
/// clamped away from the screen edge while the icon stays where it is.
struct PanelShape: Shape {
    var arrowX: CGFloat
    var showsArrow = true

    func path(in rect: CGRect) -> Path {
        let arrowHeight = showsArrow ? Theme.arrowHeight : 0
        let halfArrow = Theme.arrowWidth / 2
        let top = rect.minY + arrowHeight
        let radius = min(Theme.corner, (rect.height - arrowHeight) / 2, rect.width / 2)
        // Keep the point clear of the rounded corners.
        let tip = min(max(arrowX, radius + halfArrow), rect.width - radius - halfArrow)

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + radius, y: top))
        if showsArrow {
            path.addLine(to: CGPoint(x: tip - halfArrow, y: top))
            path.addLine(to: CGPoint(x: tip, y: rect.minY))
            path.addLine(to: CGPoint(x: tip + halfArrow, y: top))
        }
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: top))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: top),
                    tangent2End: CGPoint(x: rect.maxX, y: top + radius), radius: radius)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.maxX - radius, y: rect.maxY), radius: radius)
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.minX, y: rect.maxY - radius), radius: radius)
        path.addLine(to: CGPoint(x: rect.minX, y: top + radius))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: top),
                    tangent2End: CGPoint(x: rect.minX + radius, y: top), radius: radius)
        path.closeSubpath()
        return path
    }
}

extension View {
    /// The dark rounded surface both floating windows sit on. The border keeps
    /// the panel's edge visible against a dark desktop.
    func panelSurface(_ fill: Color = Theme.panel,
                      arrowX: CGFloat? = nil) -> some View {
        let shape = PanelShape(arrowX: arrowX ?? 0, showsArrow: arrowX != nil)
        return padding(.top, arrowX != nil ? Theme.arrowHeight : 0)
            .background(shape.fill(fill))
            .overlay(shape.stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}
