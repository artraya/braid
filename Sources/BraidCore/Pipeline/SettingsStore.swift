import Foundation

/// App settings, all non-secret, all in UserDefaults.
///
/// There are no API keys any more: Braid holds no accounts and calls no
/// services (R13, ADR-0006). The one secret it does keep, the Voice Database
/// key, lives in the Keychain under `SecretBox` and never passes through here.
public struct SettingsStore: Sendable {
    // UserDefaults is documented thread-safe; Foundation just hasn't marked it Sendable.
    nonisolated(unsafe) let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var vaultPath: String? {
        get { defaults.string(forKey: "vaultPath") }
        nonmutating set { defaults.set(newValue, forKey: "vaultPath") }
    }

    public var keyTerms: [String] {
        get { defaults.stringArray(forKey: "keyTerms") ?? [] }
        nonmutating set { defaults.set(newValue, forKey: "keyTerms") }
    }

    public var presets: [Preset] {
        get {
            guard let data = defaults.data(forKey: "presets"),
                  let stored = try? JSONDecoder().decode([Preset].self, from: data),
                  !stored.isEmpty else { return Preset.defaults }
            return stored
        }
        nonmutating set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: "presets")
        }
    }

    /// Stop recording by itself when the call app lets go of the microphone.
    /// Starting is always deliberate; only stopping is automated (R17).
    public var autoEndEnabled: Bool {
        get { defaults.object(forKey: "autoEndEnabled") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "autoEndEnabled") }
    }

    /// Bundle IDs treated as call apps, matched as prefixes (R17).
    public var callAppBundleIDs: [String] {
        get {
            let stored = defaults.stringArray(forKey: "callAppBundleIDs") ?? []
            return stored.isEmpty ? CallWatcher.defaultBundleIDs : stored
        }
        nonmutating set { defaults.set(newValue, forKey: "callAppBundleIDs") }
    }

    /// Which on-device engine transcribes. Apple by default: it measured better
    /// on speaker attribution, takes Key Terms, and downloads nothing
    /// (ADR-0006).
    public var localEngine: LocalEngine {
        get {
            guard let raw = defaults.string(forKey: "localEngine"),
                  let engine = LocalEngine(rawValue: raw) else { return .apple }
            return engine
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "localEngine") }
    }

    /// When a Session's Note is written (R26). Immediate by default: waiting is
    /// the exception, chosen by people who would rather name speakers up front
    /// than correct a Note that is already filed.
    public var delivery: Delivery {
        get {
            guard let raw = defaults.string(forKey: "delivery"),
                  let mode = Delivery(rawValue: raw) else { return .immediate }
            return mode
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "delivery") }
    }

    /// Set once the chosen engine's models are loaded at least once, so the app
    /// knows whether the next Session means a wait.
    public var localModelsInstalled: Bool {
        get { defaults.bool(forKey: "localModelsInstalled") }
        nonmutating set { defaults.set(newValue, forKey: "localModelsInstalled") }
    }
}
