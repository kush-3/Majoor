// DatabaseManager.swift
// Majoor — SQLite Database via GRDB
//
// Singleton managing the GRDB DatabaseQueue.
// Database stored at ~/Library/Application Support/ai.majoor.agent/majoor.sqlite

import Foundation
import GRDB

nonisolated final class DatabaseManager: @unchecked Sendable {

    static let shared = DatabaseManager()

    let dbQueue: DatabaseQueue

    private init() {
        do {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dbDir = appSupport.appendingPathComponent("ai.majoor.agent", isDirectory: true)
            try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)

            let dbPath = dbDir.appendingPathComponent("majoor.sqlite").path
            dbQueue = try DatabaseQueue(path: dbPath)

            try migrate()

            MajoorLogger.log("Database ready at \(dbPath)")
        } catch {
            fatalError("Database init failed: \(error)")
        }
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_create_tables") { db in
            // Memories table
            try db.create(table: "memories", ifNotExists: true) { t in
                t.primaryKey("id", .text)
                t.column("category", .text).notNull()
                t.column("content", .text).notNull()
                t.column("sourceTaskId", .text)
                t.column("relevanceScore", .double).defaults(to: 1.0)
                t.column("createdAt", .text).notNull()
                t.column("lastAccessedAt", .text).notNull()
                t.column("accessCount", .integer).defaults(to: 0)
            }

            // Tasks table
            try db.create(table: "tasks", ifNotExists: true) { t in
                t.primaryKey("id", .text)
                t.column("userInput", .text).notNull()
                t.column("status", .text).notNull()
                t.column("modelUsed", .text)
                t.column("stepsJson", .text)
                t.column("summary", .text)
                t.column("tokensUsed", .integer).defaults(to: 0)
                t.column("costEstimate", .double).defaults(to: 0.0)
                t.column("createdAt", .text).notNull()
                t.column("completedAt", .text)
            }

            // Usage stats table
            try db.create(table: "usageStats", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("date", .text).notNull()
                t.column("model", .text).notNull()
                t.column("inputTokens", .integer).defaults(to: 0)
                t.column("outputTokens", .integer).defaults(to: 0)
                t.column("cost", .double).defaults(to: 0.0)
                t.column("taskCount", .integer).defaults(to: 0)
                t.uniqueKey(["date", "model"])
            }
        }

        try migrator.migrate(dbQueue)
    }
}
