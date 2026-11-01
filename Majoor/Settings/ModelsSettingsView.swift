// ModelsSettingsView.swift
// Majoor — Settings ▸ Models: the three tiers of PRD §6
//
// F is Claude (the onboarding key; nothing to configure here). L and P are
// OpenAI-compatible endpoints: URL, model, a Test button that lists the
// server's models, and for P a key in the Keychain plus the owner's own
// "I verified the retention terms" reminder. The privacy preset is shown
// read-only; router v2 (Phase 2 step 3) enforces it.

import SwiftUI
import Combine

@MainActor
final class ModelsSettingsModel: ObservableObject {

    enum Probe: Equatable {
        case idle
        case running
        case ok(models: [String], latency: TimeInterval)
        case failed(String)
    }

    @Published var localBaseURL = ""
    @Published var localModel = ""
    @Published var localProbe: Probe = .idle

    @Published var privateBaseURL = ""
    @Published var privateModel = ""
    @Published var privateKey = ""
    @Published var hasPrivateKey = false
    @Published var retentionVerified = false
    @Published var privateInputRate = ""
    @Published var privateOutputRate = ""
    @Published var privateProbe: Probe = .idle

    /// "" for normal routing, else a `ProviderTier` raw value.
    @Published var override = ""
    @Published var presetId = PrivacyPreset.strict.id

    private let store: TierSettingsStore
    private let presets: PrivacyPresetStore
    private var loaded = false

    init(store: TierSettingsStore = .shared, presets: PrivacyPresetStore = .shared) {
        self.store = store
        self.presets = presets
    }

    func load() {
        guard !loaded else { return }
        loaded = true
        if let local = store.endpoint(for: .local) {
            localBaseURL = local.baseURL
            localModel = local.model
        }
        if let remote = store.endpoint(for: .privateCloud) {
            privateBaseURL = remote.baseURL
            privateModel = remote.model
        }
        hasPrivateKey = store.hasPrivateKey
        retentionVerified = store.privateRetentionVerified
        let rates = store.privateRates
        privateInputRate = rates.input == 0 ? "" : Self.formatRate(rates.input)
        privateOutputRate = rates.output == 0 ? "" : Self.formatRate(rates.output)
        override = store.routingOverride?.rawValue ?? ""
        presetId = presets.preset.id
    }

    var preset: PrivacyPreset { PrivacyPreset.named(presetId) ?? .strict }

    func setPreset(_ id: String) {
        guard let preset = PrivacyPreset.named(id) else { return }
        presetId = preset.id
        presets.preset = preset
    }

    /// Both fields are dollars per million tokens; blank or unparsable means 0.
    func savePrivateRates() {
        guard loaded else { return }
        store.privateRates = (Self.parseRate(privateInputRate), Self.parseRate(privateOutputRate))
    }

    private static func parseRate(_ text: String) -> Double {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: ".")
        return max(0, Double(cleaned) ?? 0)
    }

    private static func formatRate(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    func saveLocal() {
        guard loaded else { return }
        store.save(TierEndpoint(baseURL: localBaseURL, model: localModel), for: .local)
    }

    func savePrivate() {
        guard loaded else { return }
        store.save(TierEndpoint(baseURL: privateBaseURL, model: privateModel, apiKey: ""), for: .privateCloud)
    }

    func savePrivateKey() {
        let key = privateKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        store.save(TierEndpoint(baseURL: privateBaseURL, model: privateModel, apiKey: key), for: .privateCloud)
        privateKey = ""
        hasPrivateKey = true
    }

    func removePrivateKey() {
        store.removePrivateKey()
        privateKey = ""
        hasPrivateKey = false
    }

    func setRetentionVerified(_ on: Bool) {
        retentionVerified = on
        store.privateRetentionVerified = on
    }

    func setOverride(_ raw: String) {
        override = raw
        store.routingOverride = ProviderTier(rawValue: raw)
    }

    func test(_ tier: ProviderTier) {
        let baseURL = tier == .local ? localBaseURL : privateBaseURL
        guard let url = TierEndpoint.normalizedURL(baseURL) else {
            setProbe(.failed("Enter a URL such as \(TierSettingsStore.localDefaultBaseURL)."), for: tier)
            return
        }
        let apiKey = tier == .local ? "" : (store.endpoint(for: .privateCloud)?.apiKey ?? "")
        setProbe(.running, for: tier)
        Task {
            do {
                let result = try await OpenAICompatibleProvider.probe(baseURL: url, apiKey: apiKey)
                setProbe(.ok(models: result.models, latency: result.latency), for: tier)
            } catch {
                setProbe(.failed(error.localizedDescription), for: tier)
            }
        }
    }

    private func setProbe(_ probe: Probe, for tier: ProviderTier) {
        if tier == .local { localProbe = probe } else { privateProbe = probe }
    }

    var overrideTier: ProviderTier? { ProviderTier(rawValue: override) }

    /// Whether the override points at a tier that cannot serve yet.
    var overrideUnconfigured: Bool {
        guard let tier = overrideTier else { return false }
        return store.provider(for: tier) == nil
    }
}

struct ModelsSettingsView: View {
    @StateObject private var model = ModelsSettingsModel()

    var body: some View {
        Form {
            frontierSection
            localSection
            privateSection
            privacySection
            overrideSection
        }
        .formStyle(.grouped)
        .onAppear { model.load() }
    }

    // MARK: Sections

    private var frontierSection: some View {
        Section {
            LabeledContent("Code & research", value: ModelRouter.opusModel)
            LabeledContent("General tasks", value: ModelRouter.sonnetModel)
            LabeledContent("Classification", value: ModelRouter.haikuModel)
            HStack {
                Text(APIConfig.hasUserClaudeKey ? "Anthropic key saved in the Keychain." : "No Anthropic key yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Change key…") { (NSApp.delegate as? AppDelegate)?.showOnboarding() }
            }
        } header: {
            Text(ProviderTier.frontier.displayName)
        } footer: {
            Text(ProviderTier.frontier.blurb)
        }
    }

    private var localSection: some View {
        Section {
            TextField("Base URL", text: $model.localBaseURL, prompt: Text(TierSettingsStore.localDefaultBaseURL))
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.saveLocal() }
                .onChange(of: model.localBaseURL) { _, _ in model.saveLocal() }
            modelField(text: $model.localModel, probe: model.localProbe, save: model.saveLocal)
            probeRow(model.localProbe, tier: .local)
        } header: {
            Text(ProviderTier.local.displayName)
        } footer: {
            Text(ProviderTier.local.blurb + " Ollama serves at \(TierSettingsStore.localDefaultBaseURL); LM Studio at http://127.0.0.1:1234/v1.")
        }
    }

    private var privateSection: some View {
        Section {
            TextField("Base URL", text: $model.privateBaseURL, prompt: Text("https://api.example.com/v1"))
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.savePrivate() }
                .onChange(of: model.privateBaseURL) { _, _ in model.savePrivate() }
            modelField(text: $model.privateModel, probe: model.privateProbe, save: model.savePrivate)
            HStack {
                SecureField("API key", text: $model.privateKey, prompt: Text(model.hasPrivateKey ? "Key saved in the Keychain" : "Paste the endpoint's API key"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.savePrivateKey() }
                Button("Save key") { model.savePrivateKey() }
                    .disabled(model.privateKey.trimmingCharacters(in: .whitespaces).isEmpty)
                if model.hasPrivateKey {
                    Button("Remove", role: .destructive) { model.removePrivateKey() }
                }
            }
            Toggle("I have verified this endpoint's zero-retention terms", isOn: Binding(get: { model.retentionVerified }, set: { model.setRetentionVerified($0) }))
            Text("A reminder, not a control: Majoor cannot check the vendor's terms. Under Strict, personal data goes to this endpoint and never to Claude, so read them.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TextField("Input $ per million tokens", text: $model.privateInputRate, prompt: Text("Input $/M"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
                    .onSubmit { model.savePrivateRates() }
                    .onChange(of: model.privateInputRate) { _, _ in model.savePrivateRates() }
                TextField("Output $ per million tokens", text: $model.privateOutputRate, prompt: Text("Output $/M"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
                    .onSubmit { model.savePrivateRates() }
                    .onChange(of: model.privateOutputRate) { _, _ in model.savePrivateRates() }
                Text("Price per million tokens, for the Usage tab. Blank means 0.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            probeRow(model.privateProbe, tier: .privateCloud)
        } header: {
            Text(ProviderTier.privateCloud.displayName)
        } footer: {
            Text(ProviderTier.privateCloud.blurb)
        }
    }

    private var privacySection: some View {
        Section {
            Picker("Preset", selection: Binding(get: { model.presetId }, set: { model.setPreset($0) })) {
                ForEach(PrivacyPreset.all, id: \.id) { preset in
                    Text(preset.displayName).tag(preset.id)
                }
            }
            .pickerStyle(.segmented)
            Text(model.preset.blurb)
                .font(.caption)
                .foregroundStyle(model.preset == .claudeOnly ? Color.orange : Color.secondary)
            ForEach(ProviderTier.allCases.reversed(), id: \.rawValue) { tier in
                let classes = DataClass.allCases.filter { model.preset.ceiling(for: $0) == tier }
                if !classes.isEmpty {
                    LabeledContent(classes.map(\.displayName).joined(separator: ", "), value: "up to \(tier.letter)")
                        .font(.callout)
                }
            }
        } header: {
            Text("Privacy")
        } footer: {
            Text("The highest tier each kind of data may reach. The router gives a task only the tools its tier may use; a task that needs a tier you have not configured gets an explanation instead of a leak.")
        }
    }

    private var overrideSection: some View {
        Section {
            Picker("Run every task on", selection: Binding(get: { model.override }, set: { model.setOverride($0) })) {
                Text("Normal routing (Claude)").tag("")
                Text(ProviderTier.local.displayName).tag(ProviderTier.local.rawValue)
                Text(ProviderTier.privateCloud.displayName).tag(ProviderTier.privateCloud.rawValue)
            }
            if model.overrideUnconfigured {
                Text("That tier has no URL or model yet, so tasks still route normally.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if model.overrideTier != nil {
                Text("Every task, with its tools and results, now goes to that endpoint. The Haiku classifier is skipped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Routing override")
        } footer: {
            Text("For trying a local or private model end to end. The privacy preset still decides which tools that tier may use.")
        }
    }

    // MARK: Pieces

    private func modelField(text: Binding<String>, probe: ModelsSettingsModel.Probe, save: @escaping () -> Void) -> some View {
        HStack {
            TextField("Model", text: text, prompt: Text("e.g. qwen3:8b"))
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit { save() }
                .onChange(of: text.wrappedValue) { _, _ in save() }
            if case .ok(let models, _) = probe, !models.isEmpty {
                Menu("Choose…") {
                    ForEach(models, id: \.self) { name in
                        Button(name) { text.wrappedValue = name }
                    }
                }
                .fixedSize()
            }
        }
    }

    private func probeRow(_ probe: ModelsSettingsModel.Probe, tier: ProviderTier) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Button(probe == .running ? "Testing…" : "Test") { model.test(tier) }
                .disabled(probe == .running)
            switch probe {
            case .idle:
                Text("Lists the server's models and measures the round trip.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .running:
                ProgressView().controlSize(.small)
            case .ok(let models, let latency):
                Text(models.isEmpty ? "Reachable, but it lists no models." : "\(models.count) model\(models.count == 1 ? "" : "s") · \(Int(latency * 1000)) ms")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }
}
