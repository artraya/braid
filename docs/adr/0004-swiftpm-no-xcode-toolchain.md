# SwiftPM + Command Line Tools, no Xcode, self-signed identity, zero dependencies

The build machine (macOS 27.0, Swift 6.4 CLT) has no Xcode, and installing it (12+ GB, App Store interaction) buys nothing the project needs. We build with Swift Package Manager: `swift build` produces the executable and a repo script assembles and signs the `.app` bundle (Info.plist, `LSUIElement`, resources). Signing uses a local self-signed identity, "ms-notes Development" (created 2026-07-31, trusted for code signing in the login keychain), which gives the stable code identity macOS's privacy system (TCC) needs to remember audio permissions across rebuilds — no Apple Developer account involved. Third-party dependencies are zero by policy: capture, CAF/FLAC audio, HTTP, Keychain, logging, and UI all come from OS frameworks, and the Anthropic call is plain `URLSession` HTTP.

## Consequences

- The bundle-assembly script is project-owned code (~50 lines) and is the only "build system" beyond SwiftPM; Xcode can still open the package later if GUI debugging is ever wanted.
- The self-signed identity exists only on this machine — reinstalling macOS or moving machines means re-creating it and re-granting permissions (acceptable: non-goal #6, no distribution).
- Adding any SPM dependency is a deliberate decision to revisit this ADR, not a routine import.
