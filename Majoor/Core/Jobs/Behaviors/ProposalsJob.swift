// ProposalsJob.swift
// Majoor — PRD §8 behavior 6i: weekly self-improvement proposals (Phase 2 step 6)
//
// The pipeline that acts on proposals is Phase 4. In Phase 2 this job looks
// at the week's failed and refused job runs and the cost facts (shared with
// 6d) and writes three proposals at urgency 1, so they appear in the morning
// brief and nothing else happens. The proposals are also kept in this job's
// scratch for the brief to read.

import Foundation

/// What the brief reads: the last run's three proposals.
nonisolated struct ProposalsState: Codable, Sendable, Equatable {
    var proposals: [String]
    var at: Date
}

nonisolated enum ProposalsJob {

    static let count = 3

    static let definitions: [JobDefinition] = [definition(collect: { context in
        WeeklyFacts.collect(now: context.now, usage: UsageStore.shared, sessions: SessionStore.shared,
                            runs: context.runs, db: DatabaseManager.shared.dbQueue)
    })]

    static func definition(collect: @escaping CostReportJob.Collect) -> JobDefinition {
        JobDefinition(
            name: JobNames.proposals,
            title: "Weekly self-improvement proposals",
            summary: "Sunday at 19:00: three proposals from the week's failed jobs and costs, for the morning brief. Nothing is changed.",
            tier: .local,
            inputs: [],
            instructions: """
            You advise the owner of Majoor, their personal AI agent, on how its scheduled jobs and spending could \
            improve next week. From the facts given (a week of model usage, sessions, approvals, job outcomes, and \
            the runs that failed or were refused), write exactly three concrete proposals, one sentence each, \
            that the owner could act on: a setting to change, a job to reschedule or disable, a tier to configure, \
            a cost to watch. Do not invent facts that are not given. Set "outcome" to "notify", "urgency" to 1, \
            and a one-line "text".
            """,
            outputSchema: #""proposals": [string, string, string]  (exactly three)"#,
            urgencyCeiling: 1,
            riskCeiling: "R0",
            delivery: .ladder,
            defaultCron: "0 19 * * 0",
            gather: { context in
                let facts = try await collect(context)
                return [facts.rendered(timeZone: context.timeZone), facts.renderedProblems(timeZone: context.timeZone)]
            },
            apply: { object, _, context in
                try apply(object, context: context)
            })
    }

    /// Up to three proposals from the answer; none is a failure, more are trimmed.
    static func proposals(from object: JSONValue) -> [String] {
        let raw = object["proposals"]?.arrayValue ?? []
        let cleaned = raw.compactMap { $0.stringValue }
            .map { UntrustedContent.stripControlCharacters($0).replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(cleaned.prefix(count))
    }

    static func apply(_ object: JSONValue, context: JobContext) throws -> JobOutcome {
        let proposals = proposals(from: object)
        guard !proposals.isEmpty else { return .failed("the answer had no proposals") }
        try context.saveScratch(ProposalsState(proposals: proposals, at: context.now))
        let lines = ["Proposals for next week:"] + proposals.enumerated().map { "\($0.offset + 1). \($0.element)" }
        return .notify(urgency: 1, text: lines.joined(separator: "\n"))
    }
}
