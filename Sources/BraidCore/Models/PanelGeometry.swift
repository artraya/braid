import CoreGraphics

/// Where the Sessions panel hangs and where its arrow points.
///
/// Pure maths, deliberately free of AppKit, because getting this wrong is
/// invisible in code review and awkward to check by eye: the panel either sits
/// detached from the menu bar or its arrow misses the icon by a few points.
public enum PanelGeometry {
    public struct Placement: Equatable {
        /// Top-left of the panel, in screen coordinates with y increasing upward.
        public let topLeft: CGPoint
        /// Arrow position measured from the panel's left edge.
        public let arrowX: CGFloat
    }

    /// - Parameters:
    ///   - panelSize: the panel's laid-out size.
    ///   - iconCentreX: centre of the menu bar item.
    ///   - menuBarBottomY: the panel's top edge sits here.
    ///   - screen: the usable screen area.
    ///   - margin: how close the panel may come to a screen edge.
    public static func place(panelSize: CGSize, iconCentreX: CGFloat,
                             menuBarBottomY: CGFloat, screen: CGRect,
                             margin: CGFloat = 8) -> Placement {
        // Centre under the icon, then pull back inside the screen. A menu bar
        // item near the right edge would otherwise hang the panel off it.
        let ideal = iconCentreX - panelSize.width / 2
        let lowerBound = screen.minX + margin
        let upperBound = screen.maxX - panelSize.width - margin
        // On a screen narrower than the panel the bounds cross; staying inside
        // the left edge is the sane answer.
        let x = upperBound < lowerBound ? lowerBound : min(max(ideal, lowerBound), upperBound)
        return Placement(topLeft: CGPoint(x: x, y: menuBarBottomY),
                         arrowX: iconCentreX - x)
    }
}
