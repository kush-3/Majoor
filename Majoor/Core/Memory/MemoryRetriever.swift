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
