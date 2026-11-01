// MemoryConsolidationJob.swift
// Majoor — PRD §8 behavior 6e: nightly memory consolidation (Phase 2 step 6)
//
// Memories are Majoor's own state (`.majoorState`), which the Strict preset
// keeps on the local tier, so the job runs on tier L only. It reads a bounded
// set of recently used memories plus their nearest neighbours, asks the model
// for merges, contradictions and stale entries as JSON, applies the merges
// through the same supersede semantics as `save_memory`, decays what is
// stale, and queues the contradictions for the morning brief. It never sends
// anything itself.

import Foundation

/// The memory store, as far as consolidation is concerned. Tests fake it.
nonisolated protocol MemoryMaintenance: Sendable {
    /// Memories created or touched since `cutoff` plus their nearest
    /// neighbours by text search, at most `limit` in all.
    func candidates(since cutoff: Date, limit: Int) throws -> [Memory]
    func memory(id: String) throws -> Memory?
    func save(_ memory: Memory) throws
    func delete(id: String) throws
}

/// `MemoryStore` behind the seam. Neighbours come from the FTS search the
/// `search_memory` tool uses, a few per recent memory, until the cap.
nonisolated struct LiveMemoryMaintenance: MemoryMaintenance {
    private let store: MemoryStore

    init(store: MemoryStore = .shared) {
        self.store = store
    }

    func candidates(since cutoff: Date, limit: Int) throws -> [Memory] {
        let recent = try store.allMemories()
            .filter { $0.lastAccessedAt >= cutoff || $0.createdAt >= cutoff }
            .sorted { $0.lastAccessedAt > $1.lastAccessedAt }
            .prefix(limit)
        var out: [Memory] = []
        var seen: Set<String> = []
        for memory in recent where !seen.contains(memory.id) {
            out.append(memory)
            seen.insert(memory.id)
        }
        for memory in recent {
            guard out.count < limit else { break }
            let neighbours = (try? store.search(query: memory.content, limit: 3)) ?? []
            for neighbour in neighbours where !seen.contains(neighbour.id) && out.count < limit {
                out.append(neighbour)
                seen.insert(neighbour.id)
            }
        }
        return out
    }

    func memory(id: String) throws -> Memory? { try store.memory(id: id) }
    func save(_ memory: Memory) throws { try store.save(memory) }
    func delete(id: String) throws { try store.delete(id: id) }
}

/// What one run proposed and did, for the summary and the tests.
nonisolated struct ConsolidationReport: Sendable, Equatable {
    var mergesApplied = 0
    var memoriesRemoved = 0
    var mergesSkipped = 0
    var decayed = 0
    var contradictions = 0

    var summary: String {
        "merged \(mergesApplied) group(s) (\(memoriesRemoved) memories removed, \(mergesSkipped) skipped), "
            + "decayed \(decayed), \(contradictions) contradiction(s) queued"
    }
}

nonisolated enum MemoryConsolidationJob {

    static let lookback: TimeInterval = 30 * 24 * 3600
    static let maxMemories = 200
    static let maxMerges = 20
    static let maxQueuedContradictions = 20
    /// A stale memory keeps half its score, never less than the archive floor.
    static let decayFactor = 0.5
    static let scoreFloor = 0.1

    static let definitions: [JobDefinition] = [definition(memories: LiveMemoryMaintenance())]

    static let instructions = """
    You tidy a personal assistant's long-term memory. You are given memories with ids. Propose:
    - merges: groups of two or more memories that say the same thing or overlap, each with one merged sentence that keeps every fact from the group; never merge unrelated memories.
    - contradictions: groups of two or more memories that cannot all be true, with a one-sentence note on what disagrees. Do not resolve them.
    - stale: ids that are clearly outdated or superseded by a newer memory in the list.
    Use only ids from the list. When nothing needs doing, return empty arrays. The outcome is always no_change.
    """

    static let outputSchema = """
    "merges": [{"ids": ["<id>", "<id>"], "merged": "<one sentence>"}], \
    "contradictions": [{"ids": ["<id>", "<id>"], "note": "<what disagrees>"}], \
    "stale": ["<id>"]
    """

    /// The job, over any memory store; `definitions` uses the live one.
    static func definition(memories: any MemoryMaintenance) -> JobDefinition {
        let candidates = CandidateBox()
        return JobDefinition(
            name: JobNames.memoryConsolidation,
            title: "Memory consolidation",
            summary: "Nightly: merges duplicate memories, decays stale ones and lists contradictions for the brief. Sends nothing.",
            tier: .local,
            inputs: [],
            instructions: instructions,
            outputSchema: outputSchema,
            urgencyCeiling: 0,
            riskCeiling: "R1",
            delivery: .ladder,
            defaultCron: "30 3 * * *",
            gather: { context in
                let cutoff = context.now.addingTimeInterval(-lookback)
                let found = try memories.candidates(since: cutoff, limit: maxMemories)
                candidates.set(Set(found.map(\.id)))
                guard !found.isEmpty else { return ["No memories were used or created in the last 30 days; nothing to consolidate."] }
                return [render(found, timeZone: context.timeZone)]
            },
            apply: { object, _, context in
                let valid = candidates.get()
                var report = ConsolidationReport()
                var consumed: Set<String> = []

                for merge in (object["merges"]?.arrayValue ?? []).prefix(maxMerges) {
                    let ids = (merge["ids"]?.arrayValue ?? []).compactMap(\.stringValue)
                    let merged = merge["merged"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let usable = ids.filter { valid.contains($0) && !consumed.contains($0) }
                    guard usable.count >= 2, !merged.isEmpty, var first = try memories.memory(id: usable[0]) else {
                        report.mergesSkipped += 1
                        continue
                    }
                    // Supersede, as save_memory does: the first id is updated in
                    // place and re-affirmed; the others are gone.
                    first.content = merged
                    first.lastAccessedAt = context.now
                    first.relevanceScore = 1.0
                    try memories.save(first)
                    for id in usable.dropFirst() {
                        try memories.delete(id: id)
                        report.memoriesRemoved += 1
                    }
                    consumed.formUnion(usable)
                    report.mergesApplied += 1
                }

                for id in (object["stale"]?.arrayValue ?? []).compactMap(\.stringValue) where valid.contains(id) && !consumed.contains(id) {
                    guard var memory = try memories.memory(id: id) else { continue }
                    memory.relevanceScore = max(scoreFloor, memory.relevanceScore * decayFactor)
                    try memories.save(memory)
                    report.decayed += 1
                }

                var state = context.scratch(as: ConsolidationState.self) ?? ConsolidationState()
                for item in object["contradictions"]?.arrayValue ?? [] {
                    let ids = (item["ids"]?.arrayValue ?? []).compactMap(\.stringValue).filter { valid.contains($0) }
                    let note = item["note"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard ids.count >= 2, !note.isEmpty else { continue }
                    state.contradictions.append(ContradictionNote(memoryIds: ids, note: note, at: context.now))
                    report.contradictions += 1
                }
                state.contradictions = Array(state.contradictions.suffix(maxQueuedContradictions))
                state.lastRunAt = context.now
                try context.saveScratch(state)

                MajoorLogger.log("🧠 Memory consolidation: \(report.summary)")
                return .noChange(summary: report.summary)
            })
    }

    /// The candidate block for the prompt. Majoor's own state: not framed.
    static func render(_ memories: [Memory], timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let lines = memories.map { memory in
            "- id \(memory.id) [\(memory.category.rawValue)] (score \(String(format: "%.2f", memory.relevanceScore)), "
                + "last used \(formatter.string(from: memory.lastAccessedAt))): \(memory.content)"
        }
        return "Memories (\(memories.count)):\n" + lines.joined(separator: "\n")
    }

    /// The ids the model was shown, handed from `gather` to `apply`. Runs are
    /// serialized by the runner, so one box per definition is enough.
    nonisolated final class CandidateBox: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: Set<String> = []
        func set(_ ids: Set<String>) { lock.withLock { self.ids = ids } }
        func get() -> Set<String> { lock.withLock { ids } }
    }
}
