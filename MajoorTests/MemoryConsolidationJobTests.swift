// MemoryConsolidationJobTests.swift
// MajoorTests — Phase 2 step 6e: nightly memory consolidation through the
// job runner, with a fake memory store and a scripted model.

import Foundation
import Testing
@testable import Majoor

/// An in-memory `MemoryMaintenance`. Candidates are every memory, by id.
nonisolated final class FakeMemories: MemoryMaintenance, @unchecked Sendable {
    private let lock = NSLock()
    private var memories: [String: Memory]
    private(set) var candidateLimit: Int?

    init(_ list: [Memory]) {
        memories = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }

    var all: [Memory] { lock.withLock { memories.values.sorted { $0.id < $1.id } } }
    subscript(id: String) -> Memory? { lock.withLock { memories[id] } }

    func candidates(since cutoff: Date, limit: Int) throws -> [Memory] {
        lock.withLock {
            candidateLimit = limit
            return Array(memories.values.sorted { $0.id < $1.id }.prefix(limit))
        }
    }
    func memory(id: String) throws -> Memory? { lock.withLock { memories[id] } }
    func save(_ memory: Memory) throws { lock.withLock { memories[memory.id] = memory } }
    func delete(id: String) throws { lock.withLock { _ = memories.removeValue(forKey: id) } }
}

/// A runner over a throwaway database with one behavior in its catalog.
struct ConsolidationHarness {
    let automations: AutomationStore
    let runs: JobRunStore
    let runner: JobRunner
    let notify: NotifyBox
    let spawn: SpawnBox
    let now: Date

    static func make(definition: JobDefinition, provider: (any LLMProvider)?, now: Date) async throws -> ConsolidationHarness {
        let path = NSTemporaryDirectory() + "majoor-behaviors-\(UUID().uuidString).sqlite"
        let db = try DatabaseManager.openAndMigrate(path: path)
        let automations = AutomationStore(db: db)
        let runs = JobRunStore(db: db)
        let notify = NotifyBox()
        let spawn = SpawnBox()
        let runner = JobRunner()
        await runner.configure(
            automations: automations, runs: runs,
            catalog: { $0 == definition.name ? definition : nil },
            gather: { _, _ in [] },
            providerFor: { _ in provider },
            preset: { .strict },
            notify: { _, def, urgency, text in notify.record(def.name, urgency, text) },
            spawn: { prompt, origin in spawn.record(prompt, origin) },
            recordUsage: { _, _, _, _ in },
            now: { now }, timeZone: newYork)
        return ConsolidationHarness(automations: automations, runs: runs, runner: runner, notify: notify, spawn: spawn, now: now)
    }

    func row(_ definition: JobDefinition, scratch: String? = nil) throws -> AutomationRecord {
        var record = AutomationRecord.job(name: definition.name, cron: definition.defaultCron, tier: definition.tier,
                                          delivery: ChannelRef(channelId: "imessage", threadKey: "imessage:+15551234567"),
                                          nextRunAt: now, now: now)
        record.scratch = scratch
        try automations.insert(record)
        return record
    }

    func scratch<T: Decodable>(_ definition: JobDefinition, as type: T.Type) -> T? {
        guard let text = automations.jobRecord(named: definition.name)?.scratch else { return nil }
        return try? JSONDecoder.wire.decode(T.self, from: Data(text.utf8))
    }
}

nonisolated func memory(_ id: String, _ content: String, category: MemoryCategory = .fact, score: Double = 1.0) -> Memory {
    Memory(id: id, category: category, content: content, relevanceScore: score,
           createdAt: localDate("2026-10-20 09:00"), lastAccessedAt: localDate("2026-10-30 09:00"))
}

@Suite("MemoryConsolidationJob")
struct MemoryConsolidationJobTests {

    private let night = localDate("2026-11-03 03:30")

    private func fullAnswer(merges: String = "[]", contradictions: String = "[]", stale: String = "[]") -> String {
        #"{"outcome":"no_change","summary":"tidy","merges":\#(merges),"contradictions":\#(contradictions),"stale":\#(stale)}"#
    }

    @Test("a merge updates the first id in place and deletes the rest; an invented id is skipped; stale decays; contradictions queue; nothing is sent")
    func applies() async throws {
        let memories = FakeMemories([
            memory("m1", "User's GitHub handle is kush-3", score: 0.6),
            memory("m2", "GitHub username: kush-3"),
            memory("m3", "Prefers concise emails", category: .preference),
            memory("m4", "The app still targets Swift 5", category: .context, score: 0.8),
            memory("m5", "Lives in Atlanta"),
            memory("m6", "Lives in Austin"),
        ])
        let definition = MemoryConsolidationJob.definition(memories: memories)
        let provider = CapturingProvider([fullAnswer(
            merges: #"[{"ids":["m1","m2"],"merged":"User's GitHub handle is kush-3"},{"ids":["m3","zzz"],"merged":"invented"}]"#,
            contradictions: #"[{"ids":["m5","m6"],"note":"Two different home cities"},{"ids":["m5","nope"],"note":"half invented"}]"#,
            stale: #"["m4","m2"]"#)])
        let h = try await ConsolidationHarness.make(definition: definition, provider: provider, now: night)
        let record = try h.row(definition)

        let outcome = await h.runner.run(record)
        guard case .noChange(let summary) = outcome else { Issue.record("expected no_change, got \(outcome)"); return }
        #expect(summary == "merged 1 group(s) (1 memories removed, 1 skipped), decayed 1, 1 contradiction(s) queued")

        let merged = try #require(memories["m1"])
        #expect(merged.content == "User's GitHub handle is kush-3")
        #expect(merged.relevanceScore == 1.0)
        #expect(merged.lastAccessedAt == night)
        #expect(memories["m2"] == nil)
        #expect(memories["m3"]?.content == "Prefers concise emails")
        #expect(memories["m4"]?.relevanceScore == 0.4)
        #expect(memories.all.count == 5)

        let state = try #require(h.scratch(definition, as: ConsolidationState.self))
        #expect(state.contradictions.count == 1)
        #expect(state.contradictions.first?.memoryIds == ["m5", "m6"])
        #expect(state.contradictions.first?.note == "Two different home cities")
        #expect(state.lastRunAt == night)

        #expect(h.notify.all.isEmpty)
        #expect(h.spawn.all.isEmpty)
        #expect(h.runs.recent().first?.outcome == "no_change")
        #expect(memories.candidateLimit == MemoryConsolidationJob.maxMemories)

        let call = try #require(provider.calls.first)
        #expect(call.systemPrompt.contains("merges"))
        if case .string(let user) = call.messages.first?.content {
            #expect(user.contains("- id m1 [fact] (score 0.60, last used 2026-10-30): User's GitHub handle is kush-3"))
            #expect(user.contains("Memories (6):"))
        } else { Issue.record("expected a string user message") }
    }

    @Test("at most 20 merges are applied; a stale id is never deleted; decay stops at the floor")
    func caps() async throws {
        var list: [Memory] = []
        for index in 0..<50 {
            list.append(memory(String(format: "a%02d", index), "Fact \(index)"))
            list.append(memory(String(format: "b%02d", index), "Fact \(index) again", score: 0.15))
        }
        let memories = FakeMemories(list)
        let definition = MemoryConsolidationJob.definition(memories: memories)
        let merges = (0..<25).map { String(format: #"{"ids":["a%02d","b%02d"],"merged":"Fact %d, once"}"#, $0, $0, $0) }.joined(separator: ",")
        let stale = (25..<50).map { String(format: #""b%02d""#, $0) }.joined(separator: ",")
        let provider = CapturingProvider([fullAnswer(merges: "[\(merges)]", stale: "[\(stale)]")])
        let h = try await ConsolidationHarness.make(definition: definition, provider: provider, now: night)
        let outcome = await h.runner.run(try h.row(definition))

        guard case .noChange(let summary) = outcome else { Issue.record("expected no_change"); return }
        #expect(summary.hasPrefix("merged 20 group(s) (20 memories removed, 0 skipped), decayed 25"))
        #expect(memories.all.count == 80)
        #expect(memories["b19"] == nil)
        #expect(memories["b20"] != nil)
        #expect(memories["b30"]?.relevanceScore == MemoryConsolidationJob.scoreFloor)
        #expect(memories["a30"]?.relevanceScore == 1.0)
    }

    @Test("the contradiction queue keeps the newest 20")
    func queueBound() async throws {
        let memories = FakeMemories([memory("x1", "A"), memory("x2", "Not A")])
        let definition = MemoryConsolidationJob.definition(memories: memories)
        let old = (0..<20).map { ContradictionNote(memoryIds: ["o\($0)", "p\($0)"], note: "old \($0)", at: localDate("2026-10-01 03:30")) }
        let existing = ConsolidationState(contradictions: old, lastRunAt: localDate("2026-11-02 03:30"))
        let scratch = String(decoding: try JSONEncoder.wire.encode(existing), as: UTF8.self)
        let provider = CapturingProvider([fullAnswer(contradictions: #"[{"ids":["x1","x2"],"note":"A vs not A"}]"#)])
        let h = try await ConsolidationHarness.make(definition: definition, provider: provider, now: night)
        _ = await h.runner.run(try h.row(definition, scratch: scratch))

        let state = try #require(h.scratch(definition, as: ConsolidationState.self))
        #expect(state.contradictions.count == 20)
        #expect(state.contradictions.last?.note == "A vs not A")
        #expect(state.contradictions.first?.note == "old 1")
    }

    @Test("with nothing to consolidate the model is told so and the run records zero counts")
    func empty() async throws {
        let memories = FakeMemories([])
        let definition = MemoryConsolidationJob.definition(memories: memories)
        let provider = CapturingProvider([fullAnswer()])
        let h = try await ConsolidationHarness.make(definition: definition, provider: provider, now: night)
        let outcome = await h.runner.run(try h.row(definition))
        #expect(outcome == .noChange(summary: "merged 0 group(s) (0 memories removed, 0 skipped), decayed 0, 0 contradiction(s) queued"))
        if case .string(let user) = provider.calls.first?.messages.first?.content {
            #expect(user.contains("nothing to consolidate"))
        } else { Issue.record("expected a string user message") }
        #expect(h.scratch(definition, as: ConsolidationState.self)?.lastRunAt == night)
    }

    @Test("the definition runs on tier L, nightly, risk R1, and is allowed under Strict")
    func shape() {
        let definition = try! #require(JobCatalog.definition(named: JobNames.memoryConsolidation))
        #expect(definition.tier == .local)
        #expect(definition.defaultCron == "30 3 * * *")
        #expect(definition.riskCeiling == "R1")
        #expect(definition.inputs.isEmpty)
        #expect(definition.gather != nil)
        #expect(definition.apply != nil)
        #expect(definition.dataClasses.allSatisfy { PrivacyPreset.strict.allows($0, on: .local) })
    }
}
