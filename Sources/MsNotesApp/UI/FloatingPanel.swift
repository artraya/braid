import AppKit
import SwiftUI
import MsNotesCore

/// A borderless, transparent-backed panel that hosts SwiftUI. Both the Sessions
/// panel and the recording HUD are one of these; the rounded dark surface is
/// drawn by the SwiftUI content, not the window.
///
/// `.nonactivatingPanel` matters: clicking the menu bar item should not pull
/// focus away from the call you are in.
final class FloatingPanel: NSPanel {
    init(contentRect: NSRect, draggable: Bool) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = draggable
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        animationBehavior = .utilityWindow
    }

    /// Borderless panels refuse key status by default, which would leave the
    /// start form's text fields untypeable.
    override var canBecomeKey: Bool { true }

    func setContent(_ view: some View) {
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.sizingOptions = [.preferredContentSize]
        contentView = hosting
    }
}

/// Where a panel hangs from: the point on the menu bar it should tuck under,
/// and the icon it should point at.
struct MenuBarAnchor {
    /// Centre of the status item, in screen coordinates.
    let iconCentreX: CGFloat
    /// Bottom edge of the menu bar: the panel's top edge sits here.
    let topY: CGFloat
    let screenFrame: CGRect

    init?(statusItemButton: NSStatusBarButton?) {
        guard let buttonWindow = statusItemButton?.window,
              let screen = buttonWindow.screen ?? NSScreen.main else { return nil }
        iconCentreX = buttonWindow.frame.midX
        topY = buttonWindow.frame.minY
        screenFrame = screen.visibleFrame
    }

    func placement(for panelSize: CGSize) -> PanelGeometry.Placement {
        PanelGeometry.place(panelSize: panelSize, iconCentreX: iconCentreX,
                            menuBarBottomY: topY, screen: screenFrame)
    }
}

extension NSPanel {
    /// Hangs the panel from the menu bar by its **top** edge.
    ///
    /// Pinning the top matters because SwiftUI resizes the window to fit its
    /// content after this runs, and a window resizes about its bottom-left
    /// corner. Positioning by the bottom left the panel floating a long way
    /// below the menu bar, by exactly the difference between the placeholder
    /// height and the real one, and pushed it up under the menu bar whenever
    /// the start form expanded.
    /// Returns the arrow position, measured from the panel's left edge.
    @discardableResult
    func hang(from anchor: MenuBarAnchor) -> CGFloat {
        let placement = anchor.placement(for: frame.size)
        setFrameTopLeftPoint(placement.topLeft)
        return placement.arrowX
    }
}
