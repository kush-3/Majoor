// PrivacyPreset.swift
// Majoor — Which tier may see which kind of data
//
// PRD §6, decision D4 ("Strict": only code reaches Anthropic). A preset maps
// every `DataClass` to the highest tier it may reach; the router computes a
// task's tool allow-list from it, and Settings ▸ Models shows the table. The
// second preset, "Claude for everything", is the 1.x behaviour and exists
// because a Mac with no tier P endpoint would otherwise refuse every email
// and calendar task the day router v2 lands.

import Foundation

nonisolated struct PrivacyPreset: Sendable, Equatable {
    let id: String
    let displayName: String
    let blurb: String
    /// The highest tier each class may reach.
    let ceilings: [DataClass: ProviderTier]

    /// How exposed a tier is: local < private < frontier.
    static func exposure(_ tier: ProviderTier) -> Int {
        switch tier {
        case .local: return 0
        case .privateCloud: return 1
        case .frontier: return 2
        }
    }

    func ceiling(for dataClass: DataClass) -> ProviderTier {
        ceilings[dataClass] ?? .local
    }

    func allows(_ dataClass: DataClass, on tier: ProviderTier) -> Bool {
        Self.exposure(tier) <= Self.exposure(ceiling(for: dataClass))
    }

    func allowedClasses(on tier: ProviderTier) -> Set<DataClass> {
        Set(DataClass.allCases.filter { allows($0, on: tier) })
    }

    /// PRD §6 / plan §3a: code, repository context and web pages may reach
    /// Claude; everything personal stops at the private tier; location, finance
    /// and Majoor's own state never leave the machine.
    static let strict = PrivacyPreset(
        id: "strict",
        displayName: "Strict",
        blurb: "Only code, repository context and web pages reach Claude. Email, contacts, calendar, messages and files stop at the private tier. Location, finance and Majoor's own memory stay on this Mac.",
        ceilings: [
            .code: .frontier, .repoContext: .frontier, .web: .frontier,
            .emailMeta: .privateCloud, .emailBody: .privateCloud, .contacts: .privateCloud,
            .calendar: .privateCloud, .messages: .privateCloud, .files: .privateCloud,
            .location: .local, .finance: .local, .majoorState: .local,
        ])

    /// Everything to Claude, as in Majoor 1.x. For a Mac without a private or
    /// local tier; the warning in Settings says what it means.
    static let claudeOnly = PrivacyPreset(
        id: "claudeOnly",
        displayName: "Claude for everything",
        blurb: "Every kind of data, including email bodies, contacts and Majoor's memory, is sent to Anthropic. The 1.x behaviour; use it only until a private tier is configured.",
        ceilings: Dictionary(uniqueKeysWithValues: DataClass.allCases.map { ($0, ProviderTier.frontier) }))

    static let all: [PrivacyPreset] = [strict, claudeOnly]

    static func named(_ id: String) -> PrivacyPreset? {
        all.first { $0.id == id }
    }
}

/// The chosen preset, in UserDefaults. Default Strict (D4). Tests pass their
/// own suite so they never touch the real defaults.
nonisolated final class PrivacyPresetStore: @unchecked Sendable {

    static let shared = PrivacyPresetStore(defaults: .standard)
    static let defaultsKey = "privacyPreset"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var preset: PrivacyPreset {
        get {
            guard let id = defaults.string(forKey: Self.defaultsKey), let preset = PrivacyPreset.named(id) else { return .strict }
            return preset
        }
        set {
            defaults.set(newValue.id, forKey: Self.defaultsKey)
        }
    }
}
