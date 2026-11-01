// ProviderTier.swift
// Majoor — The three model tiers of PRD §6 and their endpoint settings
//
// F (frontier) is Claude through the Anthropic key saved at onboarding. L (local)
// and P (private) are OpenAI-compatible endpoints configured in Settings ▸ Models
// and served by `OpenAICompatibleProvider`. Which tier a task or job *gets* is
// router v2's business (Phase 2 step 3); this file only names the tiers, stores
// their endpoints, and builds a provider for one on request.

import Foundation

nonisolated enum ProviderTier: String, Codable, Sendable, CaseIterable {
    case local
    case privateCloud = "private"
    case frontier

    /// The PRD's letter: L, P, F.
    var letter: String {
        switch self {
        case .local: return "L"
        case .privateCloud: return "P"
        case .frontier: return "F"
        }
    }

    var displayName: String {
        switch self {
        case .local: return "Local (L)"
        case .privateCloud: return "Private (P)"
        case .frontier: return "Frontier (F)"
        }
    }

    var blurb: String {
        switch self {
        case .local:
            return "A model server on this Mac (Ollama, LM Studio, MLX). Nothing leaves the machine; the only cost is electricity."
        case .privateCloud:
            return "A hosted endpoint you have checked for zero retention. Personal data under the Strict preset goes here, never to Claude."
        case .frontier:
            return "Claude, through the Anthropic key from onboarding. Code, repository context and web research."
        }
    }
}

// MARK: - Endpoint

/// Where a tier's OpenAI-compatible server lives. `baseURL` is the prefix in
/// front of `/chat/completions` and `/models`, so it normally ends in `/v1`.
nonisolated struct TierEndpoint: Sendable, Equatable {
    var baseURL: String
    var model: String
    var apiKey: String

    init(baseURL: String, model: String, apiKey: String = "") {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
    }

    /// `baseURL` as a URL, with `/v1` appended when the owner typed only a host.
    /// Every mainstream server (Ollama, LM Studio, vLLM, Fireworks, Together)
    /// mounts the OpenAI routes under `/v1`, so a bare origin is a typo, not a
    /// choice.
    var url: URL? {
        Self.normalizedURL(baseURL)
    }

    var isConfigured: Bool {
        url != nil && !model.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Loopback endpoints get "the server is not running" wording and no retries
    /// on a refused connection, since nothing will change in two seconds.
    var isLocal: Bool {
        Self.isLoopbackHost(url)
    }

    static func normalizedURL(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") { trimmed = "http://" + trimmed }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard var components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = components.host, !host.isEmpty else { return nil }
        if components.path.isEmpty { components.path = "/v1" }
        components.query = nil
        components.fragment = nil
        return components.url
    }

    static func isLoopbackHost(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
            || host.hasPrefix("127.") || host.hasSuffix(".localhost")
    }
}

// MARK: - Secrets seam

/// The Keychain, as far as tier settings are concerned. Tests substitute a
/// dictionary so they never touch the real Keychain.
nonisolated protocol SecretStore: Sendable {
    func secret(for key: String) -> String?
    func setSecret(_ value: String, for key: String)
    func removeSecret(for key: String)
}

extension KeychainManager: SecretStore {
    nonisolated func secret(for key: String) -> String? { retrieve(key: key) }
    nonisolated func setSecret(_ value: String, for key: String) { save(key: key, value: value) }
    nonisolated func removeSecret(for key: String) { delete(key: key) }
}

// MARK: - Settings store

/// Tier L and P endpoints (UserDefaults; the P key in the Keychain), the
/// "retention terms verified" reminder, and the routing override that sends
/// every task to one tier for testing. UserDefaults and the Keychain are both
/// thread-safe, so this is plain nonisolated.
nonisolated final class TierSettingsStore: @unchecked Sendable {

    static let shared = TierSettingsStore(defaults: .standard, secrets: KeychainManager.shared)

    static let localDefaultBaseURL = "http://127.0.0.1:11434/v1"

    static let localBaseURLKey = "tierLBaseURL"
    static let localModelKey = "tierLModel"
    static let privateBaseURLKey = "tierPBaseURL"
    static let privateModelKey = "tierPModel"
    static let privateRetentionVerifiedKey = "tierPRetentionVerified"
    static let routingOverrideKey = "providerTierOverride"
    static let privateInputRateKey = "tierPInputRate"
    static let privateOutputRateKey = "tierPOutputRate"
    static let keychainPrivateKey = "majoor_tier_p_api_key"

    private let defaults: UserDefaults
    private let secrets: any SecretStore

    init(defaults: UserDefaults, secrets: any SecretStore) {
        self.defaults = defaults
        self.secrets = secrets
    }

    /// The endpoint for L or P; nil for F, which is not an OpenAI-compatible tier.
    func endpoint(for tier: ProviderTier) -> TierEndpoint? {
        switch tier {
        case .frontier:
            return nil
        case .local:
            return TierEndpoint(baseURL: defaults.string(forKey: Self.localBaseURLKey) ?? Self.localDefaultBaseURL,
                                model: defaults.string(forKey: Self.localModelKey) ?? "",
                                apiKey: "")
        case .privateCloud:
            return TierEndpoint(baseURL: defaults.string(forKey: Self.privateBaseURLKey) ?? "",
                                model: defaults.string(forKey: Self.privateModelKey) ?? "",
                                apiKey: secrets.secret(for: Self.keychainPrivateKey) ?? "")
        }
    }

    /// Saves the URL and model. The P key is written only when non-empty; use
    /// `removePrivateKey()` to clear it, so clearing a text field by accident
    /// cannot wipe the Keychain entry.
    func save(_ endpoint: TierEndpoint, for tier: ProviderTier) {
        switch tier {
        case .frontier:
            return
        case .local:
            defaults.set(endpoint.baseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.localBaseURLKey)
            defaults.set(endpoint.model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.localModelKey)
        case .privateCloud:
            defaults.set(endpoint.baseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.privateBaseURLKey)
            defaults.set(endpoint.model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.privateModelKey)
            let key = endpoint.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { secrets.setSecret(key, for: Self.keychainPrivateKey) }
        }
    }

    func removePrivateKey() {
        secrets.removeSecret(for: Self.keychainPrivateKey)
    }

    var hasPrivateKey: Bool {
        !(secrets.secret(for: Self.keychainPrivateKey) ?? "").isEmpty
    }

    /// The owner's own attestation that the P endpoint keeps nothing. A reminder
    /// shown in Settings; Majoor cannot and does not check it.
    var privateRetentionVerified: Bool {
        get { defaults.bool(forKey: Self.privateRetentionVerifiedKey) }
        set { defaults.set(newValue, forKey: Self.privateRetentionVerifiedKey) }
    }

    /// When set, `ModelRouter` sends every task to this tier instead of
    /// classifying. For trying a local model end to end; router v2 replaces it
    /// with data-class routing. Only L and P are meaningful.
    var routingOverride: ProviderTier? {
        get {
            guard let raw = defaults.string(forKey: Self.routingOverrideKey), let tier = ProviderTier(rawValue: raw), tier != .frontier else { return nil }
            return tier
        }
        set {
            if let newValue, newValue != .frontier {
                defaults.set(newValue.rawValue, forKey: Self.routingOverrideKey)
            } else {
                defaults.removeObject(forKey: Self.routingOverrideKey)
            }
        }
    }

    /// Tier P's price per million tokens (input, output), as entered in
    /// Settings ▸ Models. 0 until set: an unpriced endpoint under-reports
    /// rather than inventing a number.
    var privateRates: (input: Double, output: Double) {
        get { (defaults.double(forKey: Self.privateInputRateKey), defaults.double(forKey: Self.privateOutputRateKey)) }
        set {
            defaults.set(newValue.input, forKey: Self.privateInputRateKey)
            defaults.set(newValue.output, forKey: Self.privateOutputRateKey)
        }
    }

    /// Which tier a model name belongs to, for usage rows and task cards that
    /// arrive without one: `claude*` is Claude; a name matching the L or P
    /// endpoint is that tier; anything else never came through
    /// `AnthropicProvider`, so it is treated as P, the costlier guess.
    func tier(forModel model: String) -> ProviderTier {
        if model.hasPrefix("claude") { return .frontier }
        let name = model.trimmingCharacters(in: .whitespaces)
        if let local = endpoint(for: .local)?.model.trimmingCharacters(in: .whitespaces), !local.isEmpty, local == name { return .local }
        return .privateCloud
    }

    /// A provider for L or P, or nil when that tier has no URL or model yet.
    func provider(for tier: ProviderTier) -> OpenAICompatibleProvider? {
        guard let endpoint = endpoint(for: tier), endpoint.isConfigured, let url = endpoint.url else { return nil }
        return OpenAICompatibleProvider(tier: tier, baseURL: url, model: endpoint.model.trimmingCharacters(in: .whitespaces), apiKey: endpoint.apiKey)
    }

    /// The provider the routing override asks for, or nil when there is none or
    /// it is not configured (logged, so a forgotten override is visible).
    func overrideProvider() -> OpenAICompatibleProvider? {
        guard let tier = routingOverride else { return nil }
        guard let provider = provider(for: tier) else {
            MajoorLogger.error("Routing override asks for tier \(tier.letter) but it has no URL or model in Settings ▸ Models; routing normally")
            return nil
        }
        return provider
    }
}
