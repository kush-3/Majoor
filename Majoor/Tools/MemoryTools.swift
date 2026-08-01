// MemoryTools.swift
// Majoor — Long-Term Memory Tools
//
// Lets the model deliberately save and recall memories. The model decides what
// is durable enough to keep; retrieval ranking (FTS5 + bm25) lives in MemoryStore.

import Foundation

// MARK: - Save Memory

nonisolated struct SaveMemoryTool: AgentTool {
    let name = "save_memory"
    let description = "Save a durable fact, preference, habit, or project context about the user to long-term memory so future tasks can recall it. Use for information with lasting value (stated preferences, corrections, personal facts, project details) — not task minutiae or transient state. To correct or update an existing memory, pass its id as 'supersedes_id' (find it with search_memory) instead of saving a duplicate."
    let parameters = [
        ToolParameter(name: "content", description: "The memory as one self-contained sentence (e.g., 'User's GitHub handle is kush-3')"),
        ToolParameter(name: "category", description: "Type of memory", enumValues: ["preference", "fact", "context", "habit"]),
        ToolParameter(name: "supersedes_id", description: "Optional id of an existing memory this replaces (from search_memory). That memory is updated in place instead of creating a new one."),
    ]
    let requiredParameters = ["content", "category"]
    let requiresConfirmation = false

    func execute(arguments: [String: String]) async throws -> ToolResult {
        guard let content = arguments["content"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            return ToolResult(success: false, output: "Error: 'content' is required")
        }
        guard let categoryRaw = arguments["category"],
              let category = MemoryCategory(rawValue: categoryRaw) else {
            return ToolResult(success: false, output: "Error: 'category' must be one of: preference, fact, context, habit")
        }

        do {
            var staleSupersedeNote = ""
            if let supersedesId = arguments["supersedes_id"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !supersedesId.isEmpty {
                if var existing = try MemoryStore.shared.memory(id: supersedesId) {
                    existing.content = content
                    existing.category = category
                    existing.lastAccessedAt = Date()
                    // A superseded memory was just re-affirmed — undo any age decay
                    existing.relevanceScore = 1.0
                    try MemoryStore.shared.save(existing)
                    return ToolResult(success: true, output: "Updated memory \(supersedesId): [\(category.rawValue)] \(content)")
                }
                staleSupersedeNote = " (note: no memory with id \(supersedesId) exists, so this was saved as a new memory)"
            }

            let memory = Memory(category: category, content: content)
            try MemoryStore.shared.save(memory)
            return ToolResult(success: true, output: "Saved memory \(memory.id): [\(category.rawValue)] \(content)\(staleSupersedeNote)")
        } catch {
            return ToolResult(success: false, output: "Error saving memory: \(error.localizedDescription)")
        }
    }
}

// MARK: - Search Memory

nonisolated struct SearchMemoryTool: AgentTool {
    let name = "search_memory"
    let description = "Search the user's long-term memories (facts, preferences, habits, project context) by keyword. Returns matching memories with their ids. Matching is keyword-based, not semantic — retry with different phrasings if the first search misses. Use before save_memory to find an existing memory to update, and whenever a task might depend on personal context not already shown in CONTEXT FROM MEMORY."
    let parameters = [
        ToolParameter(name: "query", description: "Keywords to search for (e.g., 'github handle')"),
    ]
    let requiredParameters = ["query"]
    let requiresConfirmation = false
    let isReadOnly = true

    func execute(arguments: [String: String]) async throws -> ToolResult {
        guard let query = arguments["query"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty else {
            return ToolResult(success: false, output: "Error: 'query' is required")
        }

        do {
            let memories = try MemoryStore.shared.search(query: query, limit: 10)
            guard !memories.isEmpty else {
                return ToolResult(success: true, output: "No memories matched \"\(query)\". Try different keywords, or the fact may not be saved yet.")
            }
            // Mark results as accessed so the 90-day decay pass spares them
            for memory in memories {
                try? MemoryStore.shared.touchMemory(id: memory.id)
            }
            var output = "\(memories.count) matching memor\(memories.count == 1 ? "y" : "ies"):\n"
            for memory in memories {
                output += "- id \(memory.id) [\(memory.category.rawValue)] \(memory.content)\n"
            }
            return ToolResult(success: true, output: output)
        } catch {
            return ToolResult(success: false, output: "Error searching memory: \(error.localizedDescription)")
        }
    }
}
