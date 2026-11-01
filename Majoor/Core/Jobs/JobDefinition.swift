// JobDefinition.swift
// Majoor — What a scheduled job is (Phase 2 step 5b)
//
// PRD §5.3: a job gathers events, asks one model for a structured answer,
// and ends in `no_change`, `notify` or `spawn_task`. Definitions are code
// (the `JobCatalog`); the `automations` table only says when each one runs,
// on which tier, and where its messages go. The §8 behaviors (Phase 2 step
// 6) are entries here, nothing more.

import Foundation

/// One input a job reads from the `EventHub`: a source, the event kinds it
/// cares about, and the data class those events carry. `includesBodies`
/// means the job may call the Gmail source's `fetchBody`, which adds
/// `.emailBody` to what the privacy preset must allow on its tier.
nonisolated struct JobInput: Sendable, Equatable {
    let sourceId: String
    let kinds: Set<SourceEventKind>
    let dataClass: DataClass
    let includesBodies: Bool

    init(sourceId: String, kinds: Set<SourceEventKind>, dataClass: DataClass, includesBodies: Bool = false) {
        self.sourceId = sourceId
        self.kinds = kinds
        self.dataClass = dataClass
        self.includesBodies = includesBodies
    }

    static let gmailMeta = JobInput(sourceId: GmailSource.sourceId, kinds: [.newEmail], dataClass: .emailMeta)
    static let gmailWithBodies = JobInput(sourceId: GmailSource.sourceId, kinds: [.newEmail], dataClass: .emailMeta, includesBodies: true)
    static let calendar = JobInput(sourceId: CalendarSource.sourceId, kinds: [.calendarChanged], dataClass: .calendar)
    static let slack = JobInput(sourceId: SlackSource.sourceId, kinds: [.slackMessage], dataClass: .messages)
    static let location = JobInput(sourceId: LocationSource.sourceId, kinds: [.locationFix], dataClass: .location)
}

/// How a job's result reaches the owner. `ladder` sends only `notify`
/// outcomes through the escalation ladder; `always` also delivers a
/// `no_change` summary (the morning brief says "nothing new" rather than
/// staying silent).
nonisolated enum JobDelivery: String, Sendable {
    case ladder
    case always
}

nonisolated struct JobDefinition: Sendable {
    let name: String
    let title: String
    /// One sentence for Settings ▸ Automations.
    let summary: String
    let tier: ProviderTier
    let inputs: [JobInput]
    /// What the model is told to do. The runner appends the output contract.
    let instructions: String
    /// Extra fields the job expects inside the JSON object, described in prose.
    let outputSchema: String
    /// 0–3; a model answer above it is clamped.
    let urgencyCeiling: Int
    /// "R0" … "R3", recorded on the spawned task's prompt for the owner to see.
    let riskCeiling: String
    let delivery: JobDelivery
    let defaultCron: String
    /// A job with no model call at all: it records `no_change` and nothing
    /// else. The `hello` heartbeat proves the scheduler → runner → table path
    /// without a model server.
    let modelFree: Bool

    init(name: String, title: String, summary: String, tier: ProviderTier, inputs: [JobInput], instructions: String,
         outputSchema: String = "", urgencyCeiling: Int = 2, riskCeiling: String = "R0", delivery: JobDelivery = .ladder,
         defaultCron: String, modelFree: Bool = false) {
        self.name = name
        self.title = title
        self.summary = summary
        self.tier = tier
        self.inputs = inputs
        self.instructions = instructions
        self.outputSchema = outputSchema
        self.urgencyCeiling = urgencyCeiling
        self.riskCeiling = riskCeiling
        self.delivery = delivery
        self.defaultCron = defaultCron
        self.modelFree = modelFree
    }

    /// Every data class the job touches; the runner checks each against the
    /// privacy preset before anything is gathered.
    var dataClasses: Set<DataClass> {
        var classes = Set(inputs.map(\.dataClass))
        if inputs.contains(where: \.includesBodies) { classes.insert(.emailBody) }
        return classes
    }
}

/// What a run concluded. `label` is the `automation_runs.outcome` value.
nonisolated enum JobOutcome: Sendable, Equatable {
    case noChange(summary: String)
    case notify(urgency: Int, text: String)
    case spawnTask(prompt: String)
    /// The job could not run: unknown definition, tier not configured, a
    /// model error, an answer that was not the contract.
    case failed(String)
    /// The job's inputs may not reach its tier under the privacy preset; it
    /// was never run.
    case refused(String)

    var label: String {
        switch self {
        case .noChange: return "no_change"
        case .notify: return "notify"
        case .spawnTask: return "spawn_task"
        case .failed: return "failed"
        case .refused: return "refused"
        }
    }

    var summary: String {
        switch self {
        case .noChange(let summary): return summary
        case .notify(let urgency, let text): return "urgency \(urgency): \(text)"
        case .spawnTask(let prompt): return prompt
        case .failed(let reason): return reason
        case .refused(let reason): return reason
        }
    }
}

/// The jobs Majoor knows how to run. Settings lists them; a row in
/// `automations` schedules one. Step 6 adds the §8 behaviors here.
nonisolated enum JobCatalog {

    /// A heartbeat: no inputs, no model, always `no_change`. Exists so the
    /// path from the scheduler through the runner to `automation_runs` can be
    /// watched working before any model server is configured.
    static let hello = JobDefinition(
        name: "hello",
        title: "Heartbeat",
        summary: "Records a no-change run on schedule and sends nothing. For checking that scheduled jobs work.",
        tier: .local,
        inputs: [],
        instructions: "Answer with no_change.",
        urgencyCeiling: 0,
        riskCeiling: "R0",
        delivery: .ladder,
        defaultCron: "*/5 * * * *",
        modelFree: true)

    static let all: [JobDefinition] = [hello]

    static func definition(named name: String) -> JobDefinition? {
        all.first { $0.name == name }
    }
}
