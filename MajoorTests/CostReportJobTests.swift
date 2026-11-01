// CostReportJobTests.swift
// MajoorTests — Phase 2 step 6d: the weekly facts and the report job.

import Foundation
import GRDB
import Testing
@testable import Majoor

/// A week of bookkeeping seeded into a throwaway database.
nonisolated struct SeededWeek {
    let db: DatabaseQueue
    let usage: UsageStore
    let sessions: SessionStore
    let runs: JobRunStore
    let now: Date

    static func make(now: Date = localDate("2026-11-08 18:00")) throws -> SeededWeek {
        let path = NSTemporaryDirectory() + "majoor-week-\(UUID().uuidString).sqlite"
        let db = try DatabaseManager.openAndMigrate(path: path)
        return SeededWeek(db: db, usage: UsageStore(db: db), sessions: SessionStore(db: db), runs: JobRunStore(db: db), now: now)
    }

    func seed() throws {
        // Usage is dated "today" by the store; a week-long window includes it.
        usage.recordUsage(model: ModelRouter.sonnetModel, inputTokens: 1_000_000, outputTokens: 0, tier: .frontier)
        usage.recordUsage(model: "qwen3:8b", inputTokens: 50_000, outputTokens: 10_000, tier: .local)

        let panel = ChannelRef(channelId: "panel", threadKey: "panel")
        let phone = ChannelRef(channelId: "imessage", threadKey: "imessage:+15551234567")
        for i in 1...3 {
            sessions.upsert(SessionInfo(shortId: i, kind: .task, state: .completed, input: "task \(i)", origin: panel,
                                        createdAt: now.addingTimeInterval(-Double(i) * 3_600)))
        }
        sessions.upsert(SessionInfo(shortId: 4, kind: .task, state: .failed, input: "from phone", origin: phone,
                                    createdAt: now.addingTimeInterval(-2 * 24 * 3_600)))
        sessions.upsert(SessionInfo(shortId: 5, kind: .task, state: .completed, input: "old", origin: panel,
                                    createdAt: now.addingTimeInterval(-10 * 24 * 3_600)))   // outside the week

        let sessionId = UUID()
        for (index, decision) in ["approved", "approved", "denied"].enumerated() {
            let request = ApprovalRequest(id: "ap\(index)", sessionId: sessionId, title: "Send", body: "b", category: "email",
                                          riskClass: .r3, nonce: "K7Q2", actionSignature: "send_email", requestedAt: now.addingTimeInterval(-3_600),
                                          expiresAt: now, isPipelinePlan: false, pipelineSteps: [])
            sessions.record(request)
            sessions.resolve(approvalId: request.id, decision: ApprovalDecision(approved: decision == "approved"), byChannel: "panel", at: now)
        }
        sessions.record(ApprovalRequest(id: "pending", sessionId: sessionId, title: "x", body: "b", category: "", riskClass: .r1,
                                        nonce: "AAAA", actionSignature: "rm", requestedAt: now.addingTimeInterval(-600), expiresAt: now, isPipelinePlan: false, pipelineSteps: []))

        try runs.insert(JobRunRecord(id: "r1", automationId: "a1", jobName: "hello", startedAt: now.addingTimeInterval(-3 * 3_600), endedAt: now,
                                     tier: "local", tokensIn: 0, tokensOut: 0, outcome: "no_change", summary: "heartbeat"))
        try runs.insert(JobRunRecord(id: "r2", automationId: "a1", jobName: "hello", startedAt: now.addingTimeInterval(-2 * 3_600), endedAt: now,
                                     tier: "local", tokensIn: 0, tokensOut: 0, outcome: "no_change", summary: "heartbeat"))
        try runs.insert(JobRunRecord(id: "r3", automationId: "a2", jobName: JobNames.memoryConsolidation, startedAt: now.addingTimeInterval(-24 * 3_600), endedAt: now,
                                     tier: "local", tokensIn: 0, tokensOut: 0, outcome: "failed", summary: "tier L is not configured in Settings ▸ Models"))
        try runs.insert(JobRunRecord(id: "r4", automationId: "a3", jobName: "leaky", startedAt: now.addingTimeInterval(-26 * 3_600), endedAt: now,
                                     tier: "frontier", tokensIn: 0, tokensOut: 0, outcome: "refused", summary: "inputs emailBody may not reach tier F"))
        try runs.insert(JobRunRecord(id: "r5", automationId: "a1", jobName: "hello", startedAt: now.addingTimeInterval(-9 * 24 * 3_600), endedAt: now,
                                     tier: "local", tokensIn: 0, tokensOut: 0, outcome: "failed", summary: "old"))   // outside the week
    }

    func facts() -> WeeklyFacts {
        WeeklyFacts.collect(now: now, usage: usage, sessions: sessions, runs: runs, db: db)
    }
}

@Suite("CostReportJob")
struct CostReportJobTests {

    @Test("a seeded week collects per-tier usage, sessions by origin, approvals by decision and runs by outcome")
    func collect() throws {
        let week = try SeededWeek.make()
        try week.seed()
        let facts = week.facts()

        #expect(facts.usage.count == 3)
        let frontier = try #require(facts.usage.first { $0.tier == .frontier })
        #expect(frontier.tokens == 1_000_000)
        #expect(frontier.cost == CostConfig.sonnetInput)
        let local = try #require(facts.usage.first { $0.tier == .local })
        #expect(local.tokens == 60_000)
        #expect(local.cost == 0)
        #expect(facts.usage.first { $0.tier == .privateCloud }?.tokens == 0)
        #expect(facts.totalCost == CostConfig.sonnetInput)

        #expect(facts.sessionsByOrigin == ["panel": 3, "imessage": 1])
        #expect(facts.approvalsByDecision == ["approved": 2, "denied": 1, "pending": 1])
        #expect(facts.runsByOutcome == ["no_change": 2, "failed": 1, "refused": 1])
        #expect(facts.problemRuns.map(\.jobName) == ["leaky", JobNames.memoryConsolidation])   // oldest first
        #expect(facts.since == week.now.addingTimeInterval(-7 * 24 * 3_600))

        let text = facts.rendered(timeZone: newYork)
        #expect(text.hasPrefix("Period: 2026-11-01 to 2026-11-08 (7 days)"))
        #expect(text.contains("Model usage by tier (1,060,000 tokens, $3.00 total):"))
        #expect(text.contains("- Frontier (F): 1,000,000 tokens, $3.00"))
        #expect(text.contains("- Local (L): 60,000 tokens, $0.00"))
        #expect(text.contains("- Private (P): none"))
        #expect(text.contains("Sessions by origin: panel 3, imessage 1 (4 total)"))
        #expect(text.contains("Approvals by decision: approved 2, denied 1, pending 1"))
        #expect(text.contains("Scheduled job runs by outcome: no_change 2, failed 1, refused 1 (4 total)"))

        let problems = facts.renderedProblems(timeZone: newYork)
        #expect(problems.hasPrefix("Failed or refused job runs (2):"))
        #expect(problems.contains("2026-11-07 16:00 leaky refused: inputs emailBody may not reach tier F"))
        #expect(problems.contains("memory_consolidation failed: tier L is not configured"))
    }

    @Test("an empty week renders honestly")
    func emptyWeek() throws {
        let week = try SeededWeek.make()
        let facts = week.facts()
        let text = facts.rendered(timeZone: newYork)
        #expect(text.contains("(0 tokens, $0.00 total)"))
        #expect(text.contains("- Local (L): none"))
        #expect(text.contains("Sessions by origin: none (0 total)"))
        #expect(text.contains("Approvals by decision: none"))
        #expect(text.contains("Scheduled job runs by outcome: none (0 total)"))
        #expect(facts.renderedProblems(timeZone: newYork) == "Failed or refused job runs: none")
    }

    @Test("the job hands the facts to tier L and delivers the report at urgency 2 through the ladder")
    func report() async throws {
        let week = try SeededWeek.make()
        try week.seed()
        let facts = week.facts()
        let provider = CapturingProvider([#"{"outcome":"notify","urgency":2,"text":"Spent $3.00 on Claude for 3 panel tasks.\nThe memory job failed: tier L is not configured.","summary":"week"}"#])
        let definition = CostReportJob.definition(collect: { _ in facts })
        let h = try await BehaviorHarness.make(definition: definition, provider: provider, now: week.now)
        let record = try h.row(definition)

        let outcome = await h.runner.run(record)
        #expect(outcome == .notify(urgency: 2, text: "Weekly report\nSpent $3.00 on Claude for 3 panel tasks.\nThe memory job failed: tier L is not configured."))
        #expect(h.notify.all.count == 1)
        #expect(h.notify.all.first?.urgency == 2)
        #expect(h.notify.all.first?.job == JobNames.costReport)
        #expect(h.runs.recent().first?.outcome == "notify")

        let call = try #require(provider.calls.first)
        #expect(call.systemPrompt.contains("weekly report"))
        #expect(call.systemPrompt.contains("at most 8 lines"))
        guard case .string(let user) = call.messages[0].content else { Issue.record("expected a string turn"); return }
        #expect(user.contains("Period: 2026-11-01 to 2026-11-08"))
        #expect(user.contains("- Frontier (F): 1,000,000 tokens, $3.00"))
        #expect(!user.contains("<untrusted"))   // Majoor's own numbers are not framed

        #expect(definition.tier == .local)
        #expect(definition.inputs.isEmpty)
        #expect(definition.defaultCron == "0 18 * * 0")
        #expect(definition.dataClasses.isEmpty)
        #expect(CostReportJob.definitions.map(\.name) == [JobNames.costReport])
    }

    @Test("apply: the report text comes from \"text\" or the contract, is capped, and its absence is a failure")
    func apply() throws {
        let fromField = try JSONValue(data: Data(#"{"outcome":"notify","urgency":2,"text":"  Field text  "}"#.utf8))
        #expect(CostReportJob.apply(fromField, mapped: .notify(urgency: 2, text: "Field text")) == .notify(urgency: 2, text: "Weekly report\nField text"))

        let noField = try JSONValue(data: Data(#"{"outcome":"notify","urgency":1}"#.utf8))
        #expect(CostReportJob.apply(noField, mapped: .notify(urgency: 1, text: "From the contract")) == .notify(urgency: 2, text: "Weekly report\nFrom the contract"))

        let nothing = try JSONValue(data: Data(#"{"outcome":"no_change"}"#.utf8))
        #expect(CostReportJob.apply(nothing, mapped: .noChange(summary: "no change")) == .failed("the report had no text"))

        let long = (1...20).map { "line \($0)" }.joined(separator: "\n")
        let longObject = JSONValue.object(["text": .string(long)])
        guard case .notify(_, let text) = CostReportJob.apply(longObject, mapped: .noChange(summary: "")) else { Issue.record("expected notify"); return }
        #expect(text.components(separatedBy: "\n").count == CostReportJob.maxLines + 1)
        #expect(text.hasSuffix("line 12"))
    }

    @Test("a gather failure is recorded, never papered over")
    func gatherFailure() async throws {
        struct Boom: Error {}
        let provider = CapturingProvider([#"{"outcome":"notify","urgency":2,"text":"x"}"#])
        let definition = CostReportJob.definition(collect: { _ in throw Boom() })
        let h = try await BehaviorHarness.make(definition: definition, provider: provider)
        let outcome = await h.runner.run(try h.row(definition))
        guard case .failed(let reason) = outcome else { Issue.record("expected .failed, got \(outcome)"); return }
        #expect(reason.hasPrefix("gather failed"))
        #expect(provider.calls.isEmpty)
        #expect(h.notify.all.isEmpty)
    }
}
