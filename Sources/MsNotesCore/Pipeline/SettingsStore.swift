import Foundation

/// App settings. Non-secret values in UserDefaults; API keys in the Keychain
/// only (SPEC R13). Presets are seeded from repo defaults at first access
/// (R12) and user-editable afterwards.
public struct SettingsStore: Sendable {
    // UserDefaults is documented thread-safe; Foundation just hasn't marked it Sendable.
    nonisolated(unsafe) let defaults: UserDefaults
    public let keychain = KeychainStore()

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

    /// Minutes of recording the user allows themselves per calendar month. The
    /// usage card warns as this approaches, but recording is never blocked:
    /// losing a meeting is worse than overshooting a self-imposed budget.
    public var monthlyMinuteCap: Int {
        get {
            let stored = defaults.integer(forKey: "monthlyMinuteCap")
            return stored > 0 ? stored : 600
        }
        nonmutating set { defaults.set(max(0, newValue), forKey: "monthlyMinuteCap") }
    }

    /// Running cost total in USD (SPEC R14).
    public var costTotalUSD: Double {
        get { defaults.double(forKey: "costTotalUSD") }
        nonmutating set { defaults.set(newValue, forKey: "costTotalUSD") }
    }

    public func addCost(_ usd: Double) {
        costTotalUSD += usd
    }
}
