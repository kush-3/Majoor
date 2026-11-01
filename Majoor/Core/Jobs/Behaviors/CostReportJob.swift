// CostReportJob.swift
// Majoor — PRD §8 behavior 6d: weekly cost and activity report (Phase 2 step 6)
//
// Sunday evening, tier L turns a week of Majoor's own bookkeeping (tokens and
// dollars per tier, sessions by origin, approvals by decision, scheduled jobs
// by outcome) into a short message. The facts are gathered in code, so the
// model only has to write; they are Majoor's state and need no framing.
// `WeeklyFacts` is shared with the proposals job (6i).

import Foundation
import GRDB

// MARK: - Facts

/// A week of Majoor's own numbers, rendered for a model or a human.
nonisolated struct WeeklyFacts: Sendable, Equatable {

    nonisolated struct TierLine: Sendable, Equatable {
        let tier: ProviderTier
        let tokens: Int
        let cost: Double
    }

    nonisolated struct RunLine: Sendable, Equatable {
        let at: Date
        let jobName: String
        let outcome: String
        let summary: String
    }

    let since: Date
    let until: Date
    let usage: [TierLine]
    let sessionsByOrigin: [String: Int]
    let approvalsByDecision: [String: Int]
    let runsByOutcome: [String: Int]
    /// Failed and refused runs, oldest first, for the proposals job.
    let problemRuns: [RunLine]

    static let days = 7
    static let maxProblemRuns = 30

    /// Gathers the last seven days before `now`. Production passes the shared
    /// stores and database; tests pass throwaway ones.
    static func collect(now: Date, usage usageStore: UsageStore, sessions: SessionStore, runs: JobRunStore,
                        db: DatabaseQueue) -> WeeklyFacts {
        let since = now.addingTimeInterval(-Double(days) * 24 * 60 * 60)

        var perTier: [ProviderTier: (tokens: Int, cost: Double)] = [:]
        for row in usageStore.usageByModel(days: days) {
            let existing = perTier[row.tier] ?? (0, 0)
            perTier[row.tier] = (existing.tokens + row.tokens, existing.cost + row.cost)
        }
        let usage = ProviderTier.allCases.map { tier in
            TierLine(tier: tier, tokens: perTier[tier]?.tokens ?? 0, cost: perTier[tier]?.cost ?? 0)
        }

        var sessionsByOrigin: [String: Int] = [:]
        for session in sessions.recent(limit: 2_000) where session.createdAt >= since && session.createdAt <= now {
            sessionsByOrigin[session.origin.channelId, default: 0] += 1
        }

        var approvalsByDecision: [String: Int] = [:]
        let approvals = (try? db.read { db in
            try ApprovalRecord.filter(Column("requestedAt") >= since).fetchAll(db)
        }) ?? []
        for approval in approvals {
            approvalsByDecision[approval.decision ?? "pending", default: 0] += 1
        }

        var runsByOutcome: [String: Int] = [:]
        var problems: [RunLine] = []
        for run in runs.runs(since: since) {
            runsByOutcome[run.outcome, default: 0] += 1
            if run.outcome == "failed" || run.outcome == "refused" {
                problems.append(RunLine(at: run.startedAt, jobName: run.jobName, outcome: run.outcome, summary: run.summary))
            }
        }

        return WeeklyFacts(since: since, until: now, usage: usage, sessionsByOrigin: sessionsByOrigin,
                           approvalsByDecision: approvalsByDecision, runsByOutcome: runsByOutcome,
                           problemRuns: Array(problems.suffix(maxProblemRuns)))
    }

    var totalCost: Double { usage.reduce(0) { $0 + $1.cost } }
    var totalTokens: Int { usage.reduce(0) { $0 + $1.tokens } }
    var totalSessions: Int { sessionsByOrigin.values.reduce(0, +) }
    var totalRuns: Int { runsByOutcome.values.reduce(0, +) }

    /// The facts as plain lines, deterministic (en_US_POSIX numbers).
    func rendered(timeZone: TimeZone) -> String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = timeZone
        day.dateFormat = "yyyy-MM-dd"
        var lines = ["Period: \(day.string(from: since)) to \(day.string(from: until)) (\(Self.days) days)"]

        lines.append("Model usage by tier (\(Self.number(totalTokens)) tokens, \(Self.dollars(totalCost)) total):")
        for line in usage {
            lines.append(line.tokens == 0
                         ? "- \(line.tier.displayName): none"
                         : "- \(line.tier.displayName): \(Self.number(line.tokens)) tokens, \(Self.dollars(line.cost))")
        }
        lines.append("Sessions by origin: " + Self.counts(sessionsByOrigin, none: "none") + " (\(totalSessions) total)")
        lines.append("Approvals by decision: " + Self.counts(approvalsByDecision, none: "none"))
        lines.append("Scheduled job runs by outcome: " + Self.counts(runsByOutcome, none: "none") + " (\(totalRuns) total)")
        return lines.joined(separator: "\n")
    }

    /// Failed and refused runs as lines, for the proposals job.
    func renderedProblems(timeZone: TimeZone) -> String {
        guard !problemRuns.isEmpty else { return "Failed or refused job runs: none" }
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.timeZone = timeZone
        stamp.dateFormat = "yyyy-MM-dd HH:mm"
        var lines = ["Failed or refused job runs (\(problemRuns.count)):"]
        for run in problemRuns {
            let summary = UntrustedContent.stripControlCharacters(run.summary).replacingOccurrences(of: "\n", with: " ")
            lines.append("- \(stamp.string(from: run.at)) \(run.jobName) \(run.outcome): \(String(summary.prefix(160)))")
        }
        return lines.joined(separator: "\n")
    }

    static func counts(_ dict: [String: Int], none: String) -> String {
        guard !dict.isEmpty else { return none }
        return dict.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    }

    /// Thousands separated by commas, whatever the Mac's locale; the POSIX
    /// locale alone has no grouping, so it is set by hand.
    static func number(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.groupingSize = 3
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func dollars(_ value: Double) -> String {
        String(format: "$%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

// MARK: - Job

nonisolated enum CostReportJob {

    /// Where the facts come from; tests inject a collector over a throwaway database.
    typealias Collect = @Sendable (JobContext) async throws -> WeeklyFacts

    static let maxLines = 12

    static let definitions: [JobDefinition] = [definition(collect: { context in
        WeeklyFacts.collect(now: context.now, usage: UsageStore.shared, sessions: SessionStore.shared,
                            runs: context.runs, db: DatabaseManager.shared.dbQueue)
    })]

    static func definition(collect: @escaping Collect) -> JobDefinition {
        JobDefinition(
            name: JobNames.costReport,
            title: "Weekly cost and activity report",
            summary: "Sunday at 18:00: tokens and dollars per tier, sessions, approvals and scheduled jobs for the week, in a short message.",
            tier: .local,
            inputs: [],
            instructions: """
            You write a weekly report for the owner of Majoor, their personal AI agent, from the facts given. \
            Report what happened: spend and tokens per tier (Claude is the frontier tier and the only one that \
            costs real money unless a private tier rate was set), how many tasks ran and from where, how approvals \
            went, and how the scheduled jobs did, naming any that failed. Plain prose or short lines, no markdown \
            headings, no advice. Set "outcome" to "notify", "urgency" to 2, and put the report in "text".
            """,
            outputSchema: #""text": the report, at most 8 lines"#,
            urgencyCeiling: 2,
            riskCeiling: "R0",
            delivery: .ladder,
            defaultCron: "0 18 * * 0",
            gather: { context in
                [try await collect(context).rendered(timeZone: context.timeZone)]
            },
            apply: { object, mapped, _ in
                apply(object, mapped: mapped)
            })
    }

    /// The report text from the answer, whichever field the model used.
    static func apply(_ object: JSONValue, mapped: JobOutcome) -> JobOutcome {
        var text = object["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty, case .notify(_, let mappedText) = mapped { text = mappedText }
        guard !text.isEmpty else { return .failed("the report had no text") }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.count > maxLines { text = lines.prefix(maxLines).joined(separator: "\n") }
        return .notify(urgency: 2, text: "Weekly report\n" + text)
    }
}
