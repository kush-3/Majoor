// TriageJobTests.swift
// MajoorTests — Phase 2 step 6a: inbox and Slack triage through the runner.

import Foundation
import GRDB
import Testing
@testable import Majoor

/// The runner over a throwaway database with one definition, a scripted
/// model and scripted hub events. Shared by the behavior suites.
nonisolated struct BehaviorHarness {
    let db: DatabaseQueue
    let automations: AutomationStore
    let runs: JobRunStore
    let runner: JobRunner
    let notify: NotifyBox
    let now: Date

    static func make(definition: JobDefinition, provider: any LLMProvider, events: [SourceEvent] = [],
                     now: Date = localDate("2026-11-03 10:00")) async throws -> BehaviorHarness {
        let path = NSTemporaryDirectory() + "majoor-behaviors-\(UUID().uuidString).sqlite"
        let db = try DatabaseManager.openAndMigrate(path: path)
        let automations = AutomationStore(db: db)
        let runs = JobRunStore(db: db)
        let notify = NotifyBox()
        let runner = JobRunner()
        await runner.configure(
            automations: automations, runs: runs,
            catalog: { $0 == definition.name ? definition : nil },
            gather: { input, _ in events.filter { $0.sourceId == input.sourceId } },
            providerFor: { _ in provider },
            preset: { .strict },
            notify: { _, definition, urgency, text in notify.record(definition.name, urgency, text) },
            spawn: nil,
            recordUsage: { _, _, _, _ in },
            now: { now }, timeZone: newYork)
        return BehaviorHarness(db: db, automations: automations, runs: runs, runner: runner, notify: notify, now: now)
    }

    func row(_ definition: JobDefinition, scratch: String? = nil) throws -> AutomationRecord {
        var record = AutomationRecord.job(name: definition.name, cron: definition.defaultCron, tier: definition.tier,
                                          delivery: ChannelRef(channelId: "imessage", threadKey: "imessage:+15551234567"),
                                          nextRunAt: now, now: now)
        record.scratch = scratch
        try automations.insert(record)
        return record
    }

    func scratch<T: Decodable>(of id: String, as type: T.Type) -> T? {
        guard let text = automations.record(id: id)?.scratch, let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder.wire.decode(T.self, from: data)
    }

    func scratchText<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder.wire.encode(value), as: UTF8.self)
    }
}

nonisolated func gmailEvent(_ id: String, from: String, subject: String, at: Date) -> SourceEvent {
    SourceEvent(sourceId: GmailSource.sourceId, kind: .newEmail, at: at,
                payload: .object(["messageId": .string(id), "threadId": .string("t-\(id)"), "from": .string(from),
                                  "subject": .string(subject), "date": .string(""), "labels": .array([.string("INBOX")]),
                                  "backfill": .bool(false)]))
}

nonisolated func slackEvent(_ ts: String, author: String, text: String, at: Date) -> SourceEvent {
    SourceEvent(sourceId: SlackSource.sourceId, kind: .slackMessage, at: at,
                payload: .object(["channel": .string("eng"), "author": .string(author), "ts": .string(ts),
                                  "text": .string(UntrustedContent.wrap(label: "slack message", source: "slack", text: text))]))
}

nonisolated func triageItem(_ id: String, source: String = "gmail", from: String, subject: String, urgency: Int, reason: String = "because") -> String {
    #"{"id":"\#(id)","source":"\#(source)","from":"\#(from)","subject":"\#(subject)","urgency":\#(urgency),"reason":"\#(reason)"}"#
}

nonisolated func triageAnswer(outcome: String, items: [String]) -> String {
    #"{"outcome":"\#(outcome)","urgency":2,"text":"triage","summary":"rated","items":[\#(items.joined(separator: ","))]}"#
}

@Suite("TriageJob")
struct TriageJobTests {

    private let at = localDate("2026-11-03 09:40")

    private var tenEmails: [SourceEvent] {
        (1...10).map { gmailEvent("m\($0)", from: "sender\($0)@example.com", subject: "Subject \($0)", at: at) }
    }

    @Test("ten emails: exactly the two urgent ones notify, five are held for the brief, three are dropped")
    func tenEmailsTwoUrgent() async throws {
        let answer = triageAnswer(outcome: "notify", items: [
            triageItem("m1", from: "Priya (CTO)", subject: "prod is down", urgency: 3, reason: "payments API down"),
            triageItem("m2", from: "Alice (landlord)", subject: "Lease renewal", urgency: 2, reason: "due end of day"),
            triageItem("m3", from: "Bob", subject: "Lunch next week?", urgency: 1),
            triageItem("m4", from: "Dr. Chen's office", subject: "Appointment reminder", urgency: 1),
            triageItem("m5", from: "Sam", subject: "PR review", urgency: 1),
            triageItem("m6", from: "Dana", subject: "W-9", urgency: 1),
            triageItem("m7", from: "Marcus", subject: "Deck", urgency: 1),
            triageItem("m8", from: "Weekly Digest", subject: "5 productivity tips", urgency: 0, reason: "newsletter"),
            triageItem("m9", from: "LinkedIn", subject: "You appeared in 12 searches", urgency: 0, reason: "noise"),
            triageItem("m10", from: "Promo", subject: "Sale ends tonight", urgency: 0, reason: "ad"),
        ])
        let provider = CapturingProvider([answer])
        let h = try await BehaviorHarness.make(definition: TriageJob.definition, provider: provider, events: tenEmails)
        let record = try h.row(TriageJob.definition)

        let outcome = await h.runner.run(record)
        guard case .notify(let urgency, let text) = outcome else { Issue.record("expected .notify, got \(outcome)"); return }
        #expect(urgency == 3)
        #expect(text.hasPrefix("2 items need you now:"))
        #expect(text.contains("• [gmail] Priya (CTO) — prod is down: payments API down"))
        #expect(text.contains("Lease renewal"))
        #expect(!text.contains("newsletter"))
        #expect(!text.contains("Lunch"))
        #expect(h.notify.all.count == 1)
        #expect(h.notify.all.first?.urgency == 3)
        #expect(h.notify.all.first?.job == JobNames.triage)

        let state = try #require(h.scratch(of: record.id, as: TriageState.self))
        #expect(state.held.count == 5)
        #expect(Set(state.held.map(\.id)) == ["m3", "m4", "m5", "m6", "m7"])
        #expect(state.held.allSatisfy { $0.urgency == 1 && $0.at == h.now })
        #expect(state.updatedAt == h.now)
        #expect(h.runs.recent().first?.summary == "urgency 3: " + text)
        #expect(h.automations.record(id: record.id)?.lastResult?.hasPrefix("notify: urgency 3") == true)

        // The model saw the ten headers, framed, and the triage instructions.
        let call = try #require(provider.calls.first)
        #expect(call.systemPrompt.contains("You triage a busy person's"))
        #expect(call.systemPrompt.contains("\"items\""))
        guard case .string(let user) = call.messages[0].content else { Issue.record("expected a string turn"); return }
        #expect(user.contains("source=\"gmail\""))
        #expect(user.contains("Subject 10"))
    }

    @Test("held items merge with the previous run: newest judgment wins, first-seen time stays, 48-hour-old ones drop")
    func heldMergeAndExpiry() async throws {
        let provider = CapturingProvider([triageAnswer(outcome: "no_change", items: [
            triageItem("m3", from: "Bob", subject: "Lunch next week?", urgency: 1, reason: "no rush at all"),
            triageItem("m11", from: "Carol", subject: "Photos", urgency: 1),
        ])])
        let h = try await BehaviorHarness.make(definition: TriageJob.definition, provider: provider,
                                               events: [gmailEvent("m3", from: "Bob", subject: "Lunch", at: at), gmailEvent("m11", from: "Carol", subject: "Photos", at: at)])
        let firstSeen = h.now.addingTimeInterval(-60 * 60)
        let previous = TriageState(held: [
            TriageHeldItem(id: "old", source: "gmail", from: "X", subject: "Stale", urgency: 1, reason: "", at: h.now.addingTimeInterval(-49 * 60 * 60)),
            TriageHeldItem(id: "m3", source: "gmail", from: "Bob", subject: "Lunch next week?", urgency: 1, reason: "earlier reason", at: firstSeen),
            TriageHeldItem(id: "kept", source: "slack", from: "Sam", subject: "Standup moved", urgency: 1, reason: "", at: h.now.addingTimeInterval(-47 * 60 * 60)),
        ], updatedAt: firstSeen)
        let record = try h.row(TriageJob.definition, scratch: try h.scratchText(previous))

        let outcome = await h.runner.run(record)
        #expect(outcome == .noChange(summary: "0 urgent, 3 held (2 new), 2 rated"))
        #expect(h.notify.all.isEmpty)

        let state = try #require(h.scratch(of: record.id, as: TriageState.self))
        #expect(Set(state.held.map(\.id)) == ["m3", "m11", "kept"])
        let m3 = try #require(state.held.first { $0.id == "m3" })
        #expect(m3.at == firstSeen)
        #expect(m3.reason == "no rush at all")
        #expect(state.held.first { $0.id == "m11" }?.at == h.now)
        #expect(state.held.first?.id == "m11")   // newest first
    }

    @Test("an item that became urgent leaves the held list; the held list is capped at 50")
    func urgentRemovesHeldAndCap() async throws {
        let provider = CapturingProvider([triageAnswer(outcome: "notify", items: [
            triageItem("m3", from: "Bob", subject: "Lunch today?", urgency: 2, reason: "today"),
        ])])
        let h = try await BehaviorHarness.make(definition: TriageJob.definition, provider: provider,
                                               events: [gmailEvent("m3", from: "Bob", subject: "Lunch today?", at: at)])
        var held = (0..<55).map { i in
            TriageHeldItem(id: "h\(i)", source: "gmail", from: "F", subject: "S\(i)", urgency: 1, reason: "",
                           at: h.now.addingTimeInterval(-Double(i) * 60))
        }
        held.append(TriageHeldItem(id: "m3", source: "gmail", from: "Bob", subject: "Lunch", urgency: 1, reason: "", at: h.now.addingTimeInterval(-3_600)))
        let record = try h.row(TriageJob.definition, scratch: try h.scratchText(TriageState(held: held, updatedAt: h.now)))

        let outcome = await h.runner.run(record)
        guard case .notify(let urgency, _) = outcome else { Issue.record("expected .notify"); return }
        #expect(urgency == 2)
        let state = try #require(h.scratch(of: record.id, as: TriageState.self))
        #expect(state.held.count == TriageJob.maxHeld)
        #expect(!state.held.contains { $0.id == "m3" })
        #expect(state.held.first?.id == "h0")      // newest kept
        #expect(!state.held.contains { $0.id == "h54" })   // oldest dropped by the cap
    }

    @Test("nothing new: a plain no_change leaves the scratch alone; an empty items array records zero counts")
    func nothingNew() async throws {
        let quiet = try await BehaviorHarness.make(definition: TriageJob.definition,
                                                   provider: CapturingProvider([#"{"outcome":"no_change","summary":"quiet"}"#]))
        let record = try quiet.row(TriageJob.definition)
        #expect(await quiet.runner.run(record) == .noChange(summary: "quiet"))
        #expect(quiet.automations.record(id: record.id)?.scratch == nil)
        #expect(quiet.notify.all.isEmpty)

        let empty = try await BehaviorHarness.make(definition: TriageJob.definition,
                                                   provider: CapturingProvider([triageAnswer(outcome: "no_change", items: [])]))
        let record2 = try empty.row(TriageJob.definition)
        #expect(await empty.runner.run(record2) == .noChange(summary: "0 urgent, 0 held (0 new), 0 rated"))
        #expect(empty.scratch(of: record2.id, as: TriageState.self)?.held.isEmpty == true)
    }

    @Test("Slack items are tagged, the message stops at five lines, and odd answers are normalized")
    func slackAndNormalization() async throws {
        var items = (1...6).map { triageItem("m\($0)", from: "P\($0)", subject: "Deadline \($0)", urgency: 2) }
        items.append(triageItem("1730000000.0001", source: "slack", from: "sam", subject: "release train leaves at 5", urgency: 3, reason: "failing check"))
        let provider = CapturingProvider([triageAnswer(outcome: "notify", items: items)])
        let h = try await BehaviorHarness.make(definition: TriageJob.definition, provider: provider,
                                               events: [slackEvent("1730000000.0001", author: "sam", text: "release train leaves at 5pm", at: at)])
        let outcome = await h.runner.run(try h.row(TriageJob.definition))
        guard case .notify(let urgency, let text) = outcome else { Issue.record("expected .notify"); return }
        #expect(urgency == 3)
        #expect(text.hasPrefix("7 items need you now:"))
        #expect(text.components(separatedBy: "\n").count == 7)   // head + 5 lines + "(+2 more)"
        #expect(text.hasSuffix("(+2 more)"))
        #expect(text.contains("• [slack] sam — release train leaves at 5: failing check"))

        let parsed = try #require(TriageJob.items(from: JSONValue(data: Data("""
        {"items":[{"id":"a","urgency":9,"from":"F","subject":"S"},{"id":"b","urgency":-1,"source":"SLACK","from":"F","subject":"S"},
                  {"from":"Dana","subject":"W-9\\u0007 form"},{"id":"","from":"","subject":""},{"id":"x","urgency":"two"}]}
        """.utf8))))
        #expect(parsed.count == 5)
        #expect(parsed[0].urgency == 3)
        #expect(parsed[1].urgency == 0)
        #expect(parsed[1].source == "slack")
        #expect(parsed[2].id == "dana|w-9 form")
        #expect(parsed[2].subject == "W-9 form")
        #expect(parsed[2].urgency == 1)   // missing urgency: held, never dropped
        #expect(parsed[3].from == "unknown")
        #expect(parsed[3].subject == "(no subject)")
        #expect(parsed[4].urgency == 1)   // a non-numeric urgency: held, never dropped
        #expect(TriageJob.items(from: .object(["outcome": .string("no_change")])) == nil)
    }
}
