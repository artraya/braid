import AppKit
import SwiftUI

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

extension NSPanel {
    /// Places the panel under a menu bar item, nudged inside the screen edge so
    /// an item near the right of the menu bar does not push it off-screen.
    func position(below statusItemButton: NSStatusBarButton?, gap: CGFloat = 6) {
        guard let buttonWindow = statusItemButton?.window,
              let screen = buttonWindow.screen ?? NSScreen.main else {
            center()
            return
        }
        let anchor = buttonWindow.frame
        let size = frame.size
        var x = anchor.midX - size.width / 2
        let visible = screen.visibleFrame
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        let y = anchor.minY - gap - size.height
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}
