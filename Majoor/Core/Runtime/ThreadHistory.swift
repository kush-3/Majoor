// ThreadHistory.swift
// Majoor — Conversation continuity, keyed by thread
//
// Moves the loop's last-10-minutes conversation context out of AgentLoop
// so several sessions can share it. A thread is the panel, one iMessage
// handle, or one control client; two sessions in the same thread see each
// other's completed turns, sessions in different threads do not. Same
// constants as 1.x: 10-minute timeout, 5 entries, 1000-char response cap.

import Foundation

nonisolated struct ConversationEntry: Sendable, Equatable {
    let userInput: String
    let responseText: String
    let toolSummaries: [String]
    let toolSets: [String]   // MCP services used, for follow-up routing
    let timestamp: Date

    init(userInput: String, responseText: String, toolSummaries: [String] = [], toolSets: [String] = [], timestamp: Date = Date()) {
        self.userInput = userInput
        self.responseText = responseText
        self.toolSummaries = toolSummaries
        self.toolSets = toolSets
        self.timestamp = timestamp
    }
}

nonisolated final class ThreadHistory: @unchecked Sendable {

    static let timeout: TimeInterval = 600
    static let maxEntries = 5
    static let responseCap = 1000

    private let lock = NSLock()
    private var threads: [String: [ConversationEntry]] = [:]
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// Entries for the thread that are still inside the timeout, oldest first.
    func snapshot(thread: String) -> [ConversationEntry] {
        let current = now()
        return lock.withLock {
            (threads[thread] ?? []).filter { current.timeIntervalSince($0.timestamp) < Self.timeout }
        }
    }

    /// Appends a completed turn, dropping expired entries and keeping the
    /// newest `maxEntries`. The response text is capped so the injected
    /// context stays bounded.
    func append(thread: String, _ entry: ConversationEntry) {
        let capped = ConversationEntry(
            userInput: entry.userInput,
            responseText: String(entry.responseText.prefix(Self.responseCap)),
            toolSummaries: entry.toolSummaries,
            toolSets: entry.toolSets,
            timestamp: entry.timestamp)
        let current = now()
        lock.withLock {
            var entries = (threads[thread] ?? []).filter { current.timeIntervalSince($0.timestamp) < Self.timeout }
            entries.append(capped)
            if entries.count > Self.maxEntries {
                entries.removeFirst(entries.count - Self.maxEntries)
            }
            threads[thread] = entries
        }
    }

    func clear(thread: String) {
        lock.withLock { threads[thread] = nil }
    }

    /// Drops every expired entry in every thread. Cheap; safe to call from a job.
    func prune() {
        let current = now()
        lock.withLock {
            for (key, entries) in threads {
                let kept = entries.filter { current.timeIntervalSince($0.timestamp) < Self.timeout }
                threads[key] = kept.isEmpty ? nil : kept
            }
        }
    }
}
