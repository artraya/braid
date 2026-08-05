import Foundation
import os

/// Where a cloud API key lives: a sealed file beside the Voice Database,
/// under the same `SecretBox` and therefore the same Keychain-held key that
/// never leaves this Mac. `UserDefaults` was never an option — a key in a plist
/// is a key any process can read.
///
/// The environment is checked first, which is how CLI diagnostics and a run
/// from the checkout get a key without priming anything.
///
/// **Why not a Keychain item of its own.** Both obvious routes are closed here.
/// The legacy file-based Keychain scopes an item to the exact binary that wrote
/// it, so the first read after a rebuild blocks on an authorisation prompt —
/// and from a CLI invocation with no window server that prompt never appears
/// and the call never returns. The data-protection Keychain scopes to the
/// signing identity instead, which would be right, but it requires a
/// `keychain-access-groups` entitlement; this app is signed with a self-signed
/// certificate and no team identifier, so `SecItemAdd` returns -34018
/// (`errSecMissingEntitlement`). `SecretBox` already solved exactly this for
/// the Voice Database, so the key rides along with it rather than inventing a
/// third answer.
public struct APIKeyStore: Sendable {
    public static let geminiFile = "gemini.key"
    /// Matches the `MSNOTES_<SERVICE>_KEY` naming the repo's `.env` already uses.
    public static let geminiVariable = "MSNOTES_GEMINI_KEY"

    let url: URL
    let box: SecretBox
    let variable: String
    let log = Logger(subsystem: "no.braid.app", category: "pipeline")

    public init(url: URL = JobQueue.appSupportURL.appendingPathComponent(APIKeyStore.geminiFile),
                box: SecretBox = SecretBox(),
                variable: String = APIKeyStore.geminiVariable) {
        self.url = url
        self.box = box
        self.variable = variable
    }

    /// The key, or nil when neither source has one. Environment first, so a
    /// diagnostic run can override whatever is installed without touching it.
    public func key() -> String? {
        if let fromEnv = ProcessInfo.processInfo.environment[variable],
           !fromEnv.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return fromEnv.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let sealed = try? Data(contentsOf: url),
              let plain = try? box.open(sealed) else { return nil }
        let value = String(data: plain, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty ?? true) ? nil : value
    }

    public var hasKey: Bool { key() != nil }

    /// Stores the key, sealed. An empty string removes it, which is how
    /// Settings turns the cloud back off properly rather than just deselecting.
    public func save(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { remove(); return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let sealed = try box.seal(Data(trimmed.utf8))
            try sealed.write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            log.error("could not store an API key: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
