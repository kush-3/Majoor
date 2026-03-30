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

    private static var dbDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("ai.majoor.agent", isDirectory: true)
    }

    private static var dbPath: String {
        dbDirectory.appendingPathComponent("majoor.sqlite").path
    }

    private init() {
        do {
            dbQueue = try Self.openWithRecovery()
            MajoorLogger.log("Database ready at \(Self.dbPath)")
        } catch {
            fatalError("Database unrecoverable after recovery attempt: \(error)")
        }
    }

    /// Try to open the database normally. On corruption, back up the corrupted file and create a fresh one.
    private static func openWithRecovery() throws -> DatabaseQueue {
        try FileManager.default.createDirectory(at: dbDirectory, withIntermediateDirectories: true)
        let path = dbPath

        do {
            return try openAndMigrate(path: path)
        } catch {
            MajoorLogger.error("Database open failed (\(error)) — attempting corruption recovery")
            let timestamp = Int(Date().timeIntervalSince1970)
            let backupPath = dbDirectory.appendingPathComponent("majoor.sqlite.corrupted-\(timestamp)").path
            try? FileManager.default.moveItem(atPath: path, toPath: backupPath)
            // Also move WAL/SHM sidecar files if they exist
            try? FileManager.default.moveItem(atPath: path + "-wal", toPath: backupPath + "-wal")
            try? FileManager.default.moveItem(atPath: path + "-shm", toPath: backupPath + "-shm")
            MajoorLogger.log("Corrupted database backed up to \(backupPath)")
            return try openAndMigrate(path: path)
        }
    }

    /// Open a DatabaseQueue with WAL journal mode enabled, then run all migrations.
    private static func openAndMigrate(path: String) throws -> DatabaseQueue {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        let queue = try DatabaseQueue(path: path, configuration: config)
        try runMigrations(queue)
        return queue
    }

    private static func runMigrations(_ dbQueue: DatabaseQueue) throws {
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

        // FTS5 full-text search index for memories (fast search replacing LIKE scans)
        migrator.registerMigration("v2_memories_fts5") { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts
                USING fts5(content, content='memories', content_rowid='rowid')
            """)

            try db.execute(sql: """
                INSERT INTO memories_fts(rowid, content)
                SELECT rowid, content FROM memories
            """)

            try db.execute(sql: """
                CREATE TRIGGER memories_ai AFTER INSERT ON memories BEGIN
                  INSERT INTO memories_fts(rowid, content) VALUES (new.rowid, new.content);
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER memories_ad AFTER DELETE ON memories BEGIN
                  INSERT INTO memories_fts(memories_fts, rowid, content) VALUES('delete', old.rowid, old.content);
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER memories_au AFTER UPDATE ON memories BEGIN
                  INSERT INTO memories_fts(memories_fts, rowid, content) VALUES('delete', old.rowid, old.content);
                  INSERT INTO memories_fts(rowid, content) VALUES (new.rowid, new.content);
                END
            """)
        }

        try migrator.migrate(dbQueue)
    }
}
