import AppKit
import BraidCore

// AppKit shell hosting SwiftUI content: AppKit owns the status item, the
// windows and their lifecycles, SwiftUI draws the Sessions panel, the recording
// HUD and the naming sheet. The CLT toolchain ships no SwiftUIMacros plugin, so
// no view may use @State — state lives in @Observable models the controllers
// own (ADR-0004).
@main
struct Entry {
    static func main() {
        if runCLI() { return }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)  // menu-bar only, no dock icon (R15)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let state = AppState()
        controller = StatusItemController(state: state)
        state.bootstrap()
    }
}
