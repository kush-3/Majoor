// ProposalsJobTests.swift
// MajoorTests — Phase 2 step 6i: three proposals a week, for the brief.

import Foundation
import Testing
@testable import Majoor

@Suite("ProposalsJob")
struct ProposalsJobTests {

    @Test("the job shows tier L the week's facts and its failed runs, delivers three proposals at urgency 1, and keeps them for the brief")
    func threeProposals() async throws {
        let week = try SeededWeek.make()
        try week.seed()
        let facts = week.facts()
        let provider = CapturingProvider([#"""
        {"outcome":"notify","urgency":1,"text":"three proposals","summary":"ok",
         "proposals":["Configure tier L in Settings ▸ Models so memory consolidation can run.",
                      "Move the leaky job off tier F or drop its email input.",
                      "Watch Claude spend: $3.00 this week came from three panel tasks."]}
        """#])
        let definition = ProposalsJob.definition(collect: { _ in facts })
        let h = try await BehaviorHarness.make(definition: definition, provider: provider, now: week.now)
        let record = try h.row(definition)

        let outcome = await h.runner.run(record)
        guard case .notify(let urgency, let text) = outcome else { Issue.record("expected .notify, got \(outcome)"); return }
        #expect(urgency == 1)
        #expect(text == """
        Proposals for next week:
        1. Configure tier L in Settings ▸ Models so memory consolidation can run.
        2. Move the leaky job off tier F or drop its email input.
        3. Watch Claude spend: $3.00 this week came from three panel tasks.
        """)
        #expect(h.notify.all.count == 1)
        #expect(h.notify.all.first?.urgency == 1)   // the ladder logs it; the brief picks it up

        let state = try #require(h.scratch(of: record.id, as: ProposalsState.self))
        #expect(state.proposals.count == 3)
        #expect(state.proposals[1] == "Move the leaky job off tier F or drop its email input.")
        #expect(state.at == week.now)

        let call = try #require(provider.calls.first)
        #expect(call.systemPrompt.contains("exactly three concrete proposals"))
        guard case .string(let user) = call.messages[0].content else { Issue.record("expected a string turn"); return }
        #expect(user.contains("Period: 2026-11-01 to 2026-11-08"))
        #expect(user.contains("Failed or refused job runs (2):"))
        #expect(user.contains("memory_consolidation failed: tier L is not configured"))
        #expect(user.contains("leaky refused"))

        #expect(definition.tier == .local)
        #expect(definition.urgencyCeiling == 1)
        #expect(definition.defaultCron == "0 19 * * 0")
        #expect(definition.dataClasses.isEmpty)
        #expect(ProposalsJob.definitions.map(\.name) == [JobNames.proposals])
    }

    @Test("more than three are trimmed, blanks are dropped, none is a recorded failure")
    func trimAndFail() async throws {
        let five = try JSONValue(data: Data(#"{"proposals":["a","  ","b\nc","d","e","f"]}"#.utf8))
        #expect(ProposalsJob.proposals(from: five) == ["a", "b c", "d"])
        #expect(ProposalsJob.proposals(from: .object(["outcome": .string("notify")])) == [])

        let week = try SeededWeek.make()
        let definition = ProposalsJob.definition(collect: { _ in week.facts() })
        let h = try await BehaviorHarness.make(definition: definition,
                                               provider: CapturingProvider([#"{"outcome":"notify","urgency":1,"text":"none","proposals":[]}"#]), now: week.now)
        let record = try h.row(definition)
        let outcome = await h.runner.run(record)
        #expect(outcome == .failed("the answer had no proposals"))
        #expect(h.notify.all.isEmpty)
        #expect(h.automations.record(id: record.id)?.scratch == nil)
        #expect(h.runs.recent().first?.outcome == "failed")
    }
}
