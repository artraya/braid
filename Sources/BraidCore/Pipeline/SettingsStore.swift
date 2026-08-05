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

    /// Which Preset shapes every Note. Chosen once in Settings rather than
    /// before each recording: the panel asks nothing at Start that Braid can
    /// work out for itself, and in practice one shape fits nearly every
    /// session. Falls back to the first Preset when the named one is gone.
    public var defaultPresetName: String {
        get {
            let stored = defaults.string(forKey: "defaultPresetName")
            let available = presets
            if let stored, available.contains(where: { $0.name == stored }) { return stored }
            return available.first?.name ?? "Meeting"
        }
        nonmutating set { defaults.set(newValue, forKey: "defaultPresetName") }
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

    /// Which model writes the Note. Apple's by default: it is already on the
    /// machine and costs nothing, and most sessions summarise fine with it.
    public var summaryEngine: SummaryEngine {
        get {
            guard let raw = defaults.string(forKey: "summaryEngine"),
                  let engine = SummaryEngine(rawValue: raw) else { return .appleBuiltIn }
            return engine
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "summaryEngine") }
    }

    /// The open-weights model's Hugging Face id, held as a plain string because
    /// BraidCore does not know about MLX — the dependency sits at the edge, in
    /// BraidMLX, and only the app layer maps this to a model.
    public var openWeightsModel: String {
        get { defaults.string(forKey: "openWeightsModel") ?? "mlx-community/Qwen3-4B-4bit" }
        nonmutating set { defaults.set(newValue, forKey: "openWeightsModel") }
    }

    /// Which Gemini model writes the Note when the cloud Engine is selected.
    public var cloudModel: GeminiSummariser.Model {
        get {
            guard let raw = defaults.string(forKey: "cloudModel"),
                  let model = GeminiSummariser.Model(rawValue: raw) else { return .flashLite }
            return model
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "cloudModel") }
    }

    /// Dollars per million tokens for the selected cloud model. Zero by
    /// default: the app counts tokens exactly, from the API's own reply, and
    /// refuses to show an invented dollar figure. Fill these in from current
    /// published pricing and the spend line starts working.
    public var cloudRates: GeminiSummariser.Rates {
        get {
            GeminiSummariser.Rates(
                inputPerMTok: defaults.double(forKey: "cloudRateInPerMTok"),
                outputPerMTok: defaults.double(forKey: "cloudRateOutPerMTok"))
        }
        nonmutating set {
            defaults.set(newValue.inputPerMTok, forKey: "cloudRateInPerMTok")
            defaults.set(newValue.outputPerMTok, forKey: "cloudRateOutPerMTok")
        }
    }

    /// Running totals for the cloud Engine (R14, restored with the cloud).
    /// Tokens are always real; spend stays zero until `cloudRates` is set.
    public var cloudTokensUsed: Int {
        get { defaults.integer(forKey: "cloudTokensUsed") }
        nonmutating set { defaults.set(newValue, forKey: "cloudTokensUsed") }
    }

    public var cloudSpendUSD: Double {
        get { defaults.double(forKey: "cloudSpendUSD") }
        nonmutating set { defaults.set(newValue, forKey: "cloudSpendUSD") }
    }
}
