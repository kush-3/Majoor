// MemoryRetriever.swift
// Majoor — Retrieves Relevant Memories for Agent Context

import Foundation

nonisolated struct MemoryRetriever: Sendable {

    /// Cache for recent memory queries (avoid redundant SQLite lookups)
    private static let cache = MemoryRetrievalCache()

    /// Find memories relevant to the user's input and format them for the system prompt
    static func relevantContext(for userInput: String, limit: Int = 5) -> String {
        // Check cache first — reuse if same/similar query within 60s
        if let cached = cache.get(for: userInput) {
            MajoorLogger.log("📎 Memory cache hit for query")
            return cached
        }

        do {
            let memories = try MemoryStore.shared.search(query: userInput, limit: limit)

            guard !memories.isEmpty else {
                cache.set(for: userInput, value: "")
                return ""
            }

            // Touch each retrieved memory (update access time)
            for memory in memories {
                try? MemoryStore.shared.touchMemory(id: memory.id)
            }

            var context = "\n\nCONTEXT FROM MEMORY:"
            for memory in memories {
                context += "\n- [\(memory.category.rawValue)] \(memory.content)"
            }

            cache.set(for: userInput, value: context)
            return context
        } catch {
            MajoorLogger.error("Memory retrieval failed: \(error)")
            return ""
        }
    }

    /// Extract potential memories from a completed task and save them
    /// Called after task completion with the final response text
    static func extractAndSaveMemories(from responseText: String, userInput: String, taskId: String) {
        // Look for explicit "remember" requests
        let lower = userInput.lowercased()
        if lower.contains("remember") || lower.contains("note that") || lower.contains("keep in mind") {
            // The user explicitly asked to remember something — save the input as a memory
            let content = userInput
                .replacingOccurrences(of: "remember that ", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: "remember ", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: "note that ", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: "keep in mind ", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let category = classifyMemory(content)
            let memory = Memory(
                category: category,
                content: content,
                sourceTaskId: taskId
            )
            try? MemoryStore.shared.save(memory)
        }
    }

    /// Simple heuristic to classify a memory into a category
    private static func classifyMemory(_ content: String) -> MemoryCategory {
        let lower = content.lowercased()

        if lower.contains("prefer") || lower.contains("always") || lower.contains("never") ||
           lower.contains("like to") || lower.contains("don't like") {
            return .preference
        }
        if lower.contains("uses") || lower.contains("project") || lower.contains("stack") ||
           lower.contains("framework") || lower.contains("built with") {
            return .context
        }
        if lower.contains("every") || lower.contains("usually") || lower.contains("routine") ||
           lower.contains("schedule") {
            return .habit
        }
        return .fact
    }
}

// MARK: - Memory Retrieval Cache

/// Thread-safe cache for memory retrieval results. Expires entries after 60 seconds.
nonisolated final class MemoryRetrievalCache: @unchecked Sendable {

    private struct CacheEntry {
        let value: String
        let timestamp: Date
    }

    private var entries: [String: CacheEntry] = [:]
    private let lock = NSLock()
    private let ttlSeconds: TimeInterval = 60

    /// Get a cached result if it exists and is fresh.
    func get(for query: String) -> String? {
        let key = normalizeKey(query)
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key],
              Date().timeIntervalSince(entry.timestamp) < ttlSeconds else {
            return nil
        }
        return entry.value
    }

    /// Store a result in the cache.
    func set(for query: String, value: String) {
        let key = normalizeKey(query)
        lock.lock()
        defer { lock.unlock() }
        entries[key] = CacheEntry(value: value, timestamp: Date())
        // Evict stale entries periodically (keep cache small)
        if entries.count > 20 {
            let now = Date()
            entries = entries.filter { now.timeIntervalSince($0.value.timestamp) < ttlSeconds }
        }
    }

    /// Normalize the query for cache key (lowercase, trimmed).
    private func normalizeKey(_ query: String) -> String {
        query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
