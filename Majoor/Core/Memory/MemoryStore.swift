// MemoryStore.swift
// Majoor — CRUD Operations for Memories

import Foundation
import GRDB

nonisolated final class MemoryStore: @unchecked Sendable {

    static let shared = MemoryStore()
    private let db = DatabaseManager.shared.dbQueue

    private init() {}

    // MARK: - Create / Update

    func save(_ memory: Memory) throws {
        try db.write { db in
            try memory.save(db)
        }
        MajoorLogger.log("Memory saved: [\(memory.category.rawValue)] \(memory.content.prefix(50))")
    }

    // MARK: - Read

    func allMemories() throws -> [Memory] {
        try db.read { db in
            try Memory.order(Column("lastAccessedAt").desc).fetchAll(db)
        }
    }

    func recentMemories(limit: Int = 10) throws -> [Memory] {
        try db.read { db in
            try Memory.order(Column("lastAccessedAt").desc).limit(limit).fetchAll(db)
        }
    }

    func search(query: String, limit: Int = 10) throws -> [Memory] {
        let keywords = query.lowercased().split(separator: " ").map { "%\($0)%" }
        guard !keywords.isEmpty else { return try recentMemories(limit: limit) }

        return try db.read { db in
            // Match any keyword in content
            let conditions = keywords.map { keyword in
                Column("content").like(keyword)
            }
            let combined = conditions.dropFirst().reduce(conditions[0]) { result, condition in
                result || condition
            }
            return try Memory
                .filter(combined)
                .order(Column("relevanceScore").desc, Column("accessCount").desc, Column("lastAccessedAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func memoryCount() throws -> Int {
        try db.read { db in
            try Memory.fetchCount(db)
        }
    }

    // MARK: - Update

    func touchMemory(id: String) throws {
        try db.write { db in
            if var memory = try Memory.fetchOne(db, key: id) {
                memory.lastAccessedAt = Date()
                memory.accessCount += 1
                try memory.update(db)
            }
        }
    }

    // MARK: - Delete

    func delete(id: String) throws {
        try db.write { db in
            _ = try Memory.deleteOne(db, key: id)
        }
    }

    func deleteAll() throws {
        try db.write { db in
            _ = try Memory.deleteAll(db)
        }
        MajoorLogger.log("All memories cleared")
    }

    // MARK: - Maintenance

    func archiveOld(days: Int = 90) throws {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        try db.write { db in
            try db.execute(
                sql: "UPDATE memories SET relevanceScore = 0.1 WHERE lastAccessedAt < ? AND relevanceScore > 0.1",
                arguments: [cutoff]
            )
        }
    }
}
