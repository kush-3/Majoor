// TierRouter.swift
// Majoor — Router v2: which tier, which provider, which tools (Phase 2 step 3)
//
// PRD §6 and plan §3b. A task's category still comes from the keyword
// classifier, with an LLM slow path for ambiguous input; what changed is what
// the category buys. Code, code review and deep research go to the frontier
// tier (Claude); everything else goes to the private tier. The privacy preset
// then decides which tools the task may use on that tier, so a personal
// source can never leak through a tool result the preset forbids. The slow
// path runs on tier L, never on Claude: under Strict the owner's text is
// personal until proven otherwise.

import Foundation

/// What the router decided for one task.
nonisolated struct RoutingDecision: Sendable {
    let provider: any LLMProvider
    /// MCP tool sets to load ("local", "github", …), as before.
    let toolSets: [String]
    /// The tier the task runs on. Nil for a scripted test provider.
    let tier: ProviderTier?
    /// Which tools the task may use. Nil means no restriction.
    let gate: ToolGate?
    /// One line on why, for the log.
    let note: String?

    init(provider: any LLMProvider, toolSets: [String], tier: ProviderTier? = nil, gate: ToolGate? = nil, note: String? = nil) {
        self.provider = provider
        self.toolSets = toolSets
        self.tier = tier
        self.gate = gate
        self.note = note
    }
}

/// The data classes a task may touch on its tier, and the words the model
/// gets when it asks for a tool outside them.
nonisolated struct ToolGate: Sendable, Equatable {
    let tier: ProviderTier
    let preset: PrivacyPreset
    let allowedClasses: Set<DataClass>

    func allows(_ dataClass: DataClass) -> Bool {
        allowedClasses.contains(dataClass)
    }

    func allows(_ tool: any AgentTool) -> Bool {
        allows(tool.dataClass)
    }

    /// The tool result for a withheld tool. Starts with "Error" so the feed and
    /// a pipeline step show it as a failure, and tells the model what to do
    /// instead of retrying.
    func refusal(toolName: String, dataClass: DataClass) -> String {
        let needed = preset.ceiling(for: dataClass)
        return "Error: \(toolName) is unavailable on tier \(tier.letter) under the \(preset.displayName) privacy preset because it touches \(dataClass.displayName.lowercased()), which may only reach tier \(needed.letter). Do not retry it. Tell the user to configure tier \(needed.letter) in Settings ▸ Models, or to switch the privacy preset there."
    }
}

/// The router the loop calls. Tests inject a decision directly.
typealias TierRoutingRouter = @Sendable (String) async -> RoutingDecision

nonisolated final class TierRouter: Sendable {

    static let shared = TierRouter(
        settings: .shared,
        presets: .shared,
        classifierProvider: { TierSettingsStore.shared.provider(for: .local) },
        frontierProvider: { ModelRouter.provider(for: $0) })

    private let settings: TierSettingsStore
    private let presets: PrivacyPresetStore
    /// The tier-L model that classifies ambiguous input; nil when L is not configured.
    private let classifierProvider: @Sendable () -> (any LLMProvider)?
    /// The Claude model for a category (Opus for code and deep research, Sonnet otherwise).
    private let frontierProvider: @Sendable (TaskCategory) -> any LLMProvider

    init(settings: TierSettingsStore, presets: PrivacyPresetStore,
         classifierProvider: @escaping @Sendable () -> (any LLMProvider)?,
         frontierProvider: @escaping @Sendable (TaskCategory) -> any LLMProvider) {
        self.settings = settings
        self.presets = presets
        self.classifierProvider = classifierProvider
        self.frontierProvider = frontierProvider
    }

    /// Plan §3b: code, code review and deep research need the frontier model;
    /// everything else is personal by default and goes to the private tier.
    static func requestedTier(for category: TaskCategory) -> ProviderTier {
        switch category {
        case .coding, .codeReview, .webResearchDeep: return .frontier
        case .webResearchQuick, .fileManagement, .emailCalendar, .summarization, .general: return .privateCloud
        }
    }

    func route(_ input: String) async -> RoutingDecision {
        let preset = presets.preset
        var (category, score) = TaskClassifier.classifyWithConfidence(input)
        var toolSets = ModelRouter.defaultToolSets(for: category, input: input)
        var notes: [String] = []

        // Settings ▸ Models can pin every task to tier L or P. Honored first, and
        // the classifier is skipped: the input must not reach another model.
        if let forced = settings.overrideProvider() {
            let gate = gate(preset: preset, tier: forced.tier, category: category, notes: &notes)
            notes.insert("override to tier \(forced.tier.letter) (\(forced.model))", at: 0)
            return finish(provider: forced, toolSets: toolSets, tier: forced.tier, gate: gate, notes: notes)
        }

        // Slow path: ambiguous input is classified on tier L, never on Claude.
        // DecisionModel seam: see PHASE-2-PLAN open question 9.
        if score < TaskClassifier.confidenceThreshold {
            if let classifier = classifierProvider() {
                if let result = await ModelRouter.classify(input, with: classifier) {
                    category = result.category
                    toolSets = result.toolSets
                    score = TaskClassifier.confidenceThreshold
                    notes.append("classified on tier L as \(category.rawValue)")
                } else {
                    notes.append("tier L classification failed; keyword result \(category.rawValue) kept")
                }
            } else {
                notes.append("ambiguous (score \(score)); tier L not configured, keyword result \(category.rawValue) kept")
            }
        }

        var tier = Self.requestedTier(for: category)
        if tier == .frontier, TaskClassifier.mentionsPersonalSource(input) {
            tier = .privateCloud
            notes.append("downgraded to tier P: the task names a personal source")
        }

        let provider: any LLMProvider
        switch tier {
        case .frontier:
            provider = frontierProvider(category)
        case .privateCloud, .local:
            if let configured = settings.provider(for: tier) {
                provider = configured
            } else if preset == .claudeOnly {
                notes.append("tier \(tier.letter) not configured; preset allows Claude")
                tier = .frontier
                provider = frontierProvider(category)
            } else {
                // Strict with no private endpoint: the task still runs on Claude,
                // but with every tool the preset keeps off Claude withheld, so a
                // code task works and an email task gets an honest refusal
                // instead of a leak.
                notes.append("tier \(tier.letter) not configured; running on Claude with personal tools withheld")
                tier = .frontier
                provider = frontierProvider(category)
            }
        }

        let gate = gate(preset: preset, tier: tier, category: category, notes: &notes)
        return finish(provider: provider, toolSets: toolSets, tier: tier, gate: gate, notes: notes)
    }

    /// The preset's classes for the tier, plus one exception: a coding or
    /// code-review task on Claude keeps the file tools, because its files are
    /// the repository. "Organize my Downloads" is file management, not coding,
    /// and stays on the private tier.
    private func gate(preset: PrivacyPreset, tier: ProviderTier, category: TaskCategory, notes: inout [String]) -> ToolGate {
        var allowed = preset.allowedClasses(on: tier)
        if tier == .frontier, category == .coding || category == .codeReview, !allowed.contains(.files) {
            allowed.insert(.files)
            notes.append("file tools kept for a coding task (repository files)")
        }
        return ToolGate(tier: tier, preset: preset, allowedClasses: allowed)
    }

    private func finish(provider: any LLMProvider, toolSets: [String], tier: ProviderTier, gate: ToolGate, notes: [String]) -> RoutingDecision {
        let note = notes.joined(separator: "; ")
        let withheld = DataClass.allCases.filter { !gate.allows($0) }.map(\.rawValue)
        MajoorLogger.log("🧭 Tier \(tier.letter) · \(provider.model) · preset \(gate.preset.displayName)\(withheld.isEmpty ? "" : " · withheld: \(withheld.joined(separator: ", "))")\(note.isEmpty ? "" : " · \(note)")")
        return RoutingDecision(provider: provider, toolSets: toolSets, tier: tier, gate: gate, note: note.isEmpty ? nil : note)
    }
}
