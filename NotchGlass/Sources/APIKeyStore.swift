import Foundation

/// Where each provider's API key lives. Stored in `UserDefaults` — a plain plist
/// in the app's preferences. Every `Provider` gets its own entry, so switching
/// backends doesn't clobber the other one's key.
///
/// Lookup order per provider (see `AppDelegate`):
///   1. The provider's env var (e.g. `MIMO_API_KEY`, `DEEPSEEK_API_KEY`) — handy
///      for local dev / debugging.
///   2. The `UserDefaults` entry the user typed into Settings.
///   3. A built-in default, if any (none ship by default — every provider's key
///      is supplied by the user).
/// The env var wins so you can run with a throwaway key without touching the
/// stored one.
///
/// Why not the Keychain? These are client-side keys anyway — anyone who can run
/// the app can recover them, so the Keychain's encryption buys little here. In
/// exchange it triggers the system "wants to use your confidential information"
/// authorization prompt (especially across rebuilds with changing ad-hoc
/// signatures), which is more annoying than it's worth for a personal local app.
/// `UserDefaults` keeps the key in a plist under the user's own account — low
/// real-world risk for this use case, and no prompts.
///
/// ⚠️ The trade-off: the key is stored in plaintext, so any process that can read
/// your user defaults can read it. Fine for personal use; before distributing the
/// app to others, move the key behind a small backend so it never ships or sits
/// on disk in the clear.
enum APIKeyStore {
    private static let keyPrefix = "api_key."
    private static let modelKeyPrefix = "model."
    private static let selectedProviderKey = "selected_provider"

    /// Built-in development keys, used only when no env var and no stored entry
    /// are present for that provider. None ship by default — every provider's key
    /// comes from the env var or the Settings entry.
    ///
    /// ⚠️ Anything returned here would ship inside the app bundle — anyone with
    /// the `.app` could extract it. Keep these empty for distribution; if you ever
    /// add one for local convenience, remove it before shipping and rotate it if
    /// it leaks.
    private static func bundledKey(for _: Provider) -> String {
        ""   // no bundled keys — every provider's key is user-supplied
    }

    // MARK: - Selected provider

    /// Which backend is active. Persisted in `UserDefaults`. When the user has
    /// never explicitly picked one, prefer a provider they already configured a
    /// key for (installs that predate this default never wrote the selection),
    /// and otherwise default to OpenRouter — the only backend that works without
    /// pasting a key (one-click connect, free models).
    static var selectedProvider: Provider {
        get {
            let raw = UserDefaults.standard.string(forKey: selectedProviderKey) ?? ""
            if let chosen = Provider(rawValue: raw) { return chosen }
            if let configured = Provider.allCases.first(where: { read($0) != nil }) {
                return configured
            }
            return .openrouter
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: selectedProviderKey)
        }
    }

    // MARK: - Effective / stored key

    /// The effective key to use right now for `provider`:
    /// env var → stored entry → bundled default. `nil` when none is available.
    static func current(for provider: Provider) -> String? {
        if let env = ProcessInfo.processInfo.environment[provider.envVarName],
           !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return env
        }
        if let stored = read(provider) { return stored }
        let bundled = bundledKey(for: provider)
        return bundled.isEmpty ? nil : bundled
    }

    /// The key the user saved in Settings for `provider` (ignores the env
    /// override), so the Settings field shows what's actually stored.
    static func stored(for provider: Provider) -> String { read(provider) ?? "" }

    /// True when the provider's env var is forcing a key — then the Settings field
    /// is informational only, since the env override wins.
    static func hasEnvOverride(for provider: Provider) -> Bool {
        let env = ProcessInfo.processInfo.environment[provider.envVarName]
        return env?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    /// Save (or clear, when empty) the user's key for `provider` in `UserDefaults`.
    static func save(_ key: String, for provider: Provider) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { delete(provider); return }
        UserDefaults.standard.set(trimmed, forKey: defaultsKey(for: provider))
    }

    // MARK: - Optional per-provider model override

    /// The model id the user typed in Settings for `provider` (empty when none),
    /// so the Settings field shows what's actually stored. An empty value means
    /// "use the provider's `defaultModel`".
    static func storedModel(for provider: Provider) -> String {
        UserDefaults.standard.string(forKey: modelDefaultsKey(for: provider)) ?? ""
    }

    /// Save (or clear, when empty) the user's model override for `provider`.
    static func saveModel(_ model: String, for provider: Provider) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = modelDefaultsKey(for: provider)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(trimmed, forKey: key)
        }
    }

    /// The model to actually use for `provider`: the user's override if set,
    /// otherwise `nil` so the client falls back to `provider.defaultModel`.
    static func effectiveModel(for provider: Provider) -> String? {
        let stored = storedModel(for: provider)
        return stored.isEmpty ? nil : stored
    }

    // MARK: - UserDefaults plumbing

    private static func defaultsKey(for provider: Provider) -> String {
        keyPrefix + provider.rawValue
    }

    private static func modelDefaultsKey(for provider: Provider) -> String {
        modelKeyPrefix + provider.rawValue
    }

    private static func read(_ provider: Provider) -> String? {
        guard let key = UserDefaults.standard.string(forKey: defaultsKey(for: provider)),
              !key.isEmpty
        else { return nil }
        return key
    }

    private static func delete(_ provider: Provider) {
        UserDefaults.standard.removeObject(forKey: defaultsKey(for: provider))
    }
}
