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

    private var hosting: ContentHostingView?

    /// The size SwiftUI wants for the current content.
    var contentSize: CGSize? { hosting?.contentSize }

    func setContent(_ view: some View) {
        let hosting = ContentHostingView(rootView: AnyView(view))
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.onLayout = { [weak self] in self?.fitToContent() }
        contentView = hosting
        self.hosting = hosting
        fitToContent()
    }

    /// Shrinks or grows the window to exactly its content.
    ///
    /// Without this the window keeps whatever height it was created with and
    /// SwiftUI centres the content inside it, which reads as the panel hanging
    /// well below the menu bar with dead space above it. `.preferredContentSize`
    /// alone does not resize a borderless panel.
    func fitToContent() {
        guard let hosting, let size = hosting.contentSize else { return }
        // Guard against re-entering: setting the size lays out again.
        guard abs(size.height - frame.height) > 0.5 || abs(size.width - frame.width) > 0.5
        else { return }
        setContentSize(size)
    }
}

/// Reports back once SwiftUI has laid itself out, which is the only reliable
/// moment to learn the content's real height.
private final class ContentHostingView: NSHostingView<AnyView> {
    var onLayout: (() -> Void)?

    /// The size SwiftUI actually wants, or nil before it has worked one out.
    ///
    /// `intrinsicContentSize` is the value NSHostingView reports for its
    /// content; `fittingSize` comes back as zero here, which is what let the
    /// window keep its placeholder height.
    var contentSize: CGSize? {
        let intrinsic = intrinsicContentSize
        if intrinsic.width > 0, intrinsic.height > 0 { return intrinsic }
        let fitting = fittingSize
        return (fitting.width > 0 && fitting.height > 0) ? fitting : nil
    }

    override func layout() {
        super.layout()
        onLayout?()
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
