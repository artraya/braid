import AppKit
import MsNotesCore

// AppKit shell (SPEC Design/Architecture: "SwiftUI MenuBarExtra is the
// expected shell, AppKit acceptable"). The CLT toolchain ships no
// SwiftUIMacros plugin, so SwiftUI's @State cannot compile without Xcode
// (ADR-0004); AppKit needs no macros and is lighter anyway.
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
