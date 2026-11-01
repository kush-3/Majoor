// JobState.swift
// Majoor — Names and persisted state shared between the §8 behaviors
//
// Jobs talk to each other only through their own row's `scratch` column
// (`JobContext.saveScratch` / `scratch(ofJob:as:)`): triage holds items for
// the brief, consolidation queues contradictions for it, the nudge keeps its
// unreplied threads and drafts. The shapes live here so every behavior
// compiles against the same ones.

import Foundation

nonisolated enum JobNames {
    static let triage = "triage"
    static let morningBrief = "morning_brief"
    static let vipNudge = "vip_nudge"
    static let costReport = "cost_report"
    static let memoryConsolidation = "memory_consolidation"
    static let location = "location_check"
    static let proposals = "proposals"
}

/// One inbox or Slack item triage judged below the notify threshold; the
/// brief lists it. Header fields only, never bodies.
nonisolated struct TriageHeldItem: Codable, Sendable, Equatable {
    let id: String
    /// "gmail" or "slack".
    let source: String
    let from: String
    let subject: String
    let urgency: Int
    let reason: String
    let at: Date
}

nonisolated struct TriageState: Codable, Sendable, Equatable {
    var held: [TriageHeldItem]
    var updatedAt: Date

    init(held: [TriageHeldItem] = [], updatedAt: Date) {
        self.held = held
        self.updatedAt = updatedAt
    }
}

/// Two or more memories that disagree, found by consolidation and listed in
/// the next brief for the owner to settle.
nonisolated struct ContradictionNote: Codable, Sendable, Equatable {
    let memoryIds: [String]
    let note: String
    let at: Date
}

nonisolated struct ConsolidationState: Codable, Sendable, Equatable {
    var contradictions: [ContradictionNote]
    var lastRunAt: Date?

    init(contradictions: [ContradictionNote] = [], lastRunAt: Date? = nil) {
        self.contradictions = contradictions
        self.lastRunAt = lastRunAt
    }
}

/// A VIP thread whose last message is theirs and older than the threshold,
/// with the draft Majoor proposed and the code the owner replies with.
nonisolated struct UnrepliedThread: Codable, Sendable, Equatable {
    let threadId: String
    let from: String
    let subject: String
    let waitingSince: Date
    var draft: String?
    var code: String?
    var remindedAt: Date?

    init(threadId: String, from: String, subject: String, waitingSince: Date, draft: String? = nil, code: String? = nil, remindedAt: Date? = nil) {
        self.threadId = threadId
        self.from = from
        self.subject = subject
        self.waitingSince = waitingSince
        self.draft = draft
        self.code = code
        self.remindedAt = remindedAt
    }
}

nonisolated struct NudgeState: Codable, Sendable, Equatable {
    var threads: [UnrepliedThread]
    var updatedAt: Date

    init(threads: [UnrepliedThread] = [], updatedAt: Date) {
        self.threads = threads
        self.updatedAt = updatedAt
    }
}
