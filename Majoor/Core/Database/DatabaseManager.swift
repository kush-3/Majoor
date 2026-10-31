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

    /// MAJOOR_DB_PATH overrides the database file (tests point it at a temp
    /// file so they never touch the real one).
    private static var overridePath: String? {
        let value = ProcessInfo.processInfo.environment["MAJOOR_DB_PATH"] ?? ""
        return value.isEmpty ? nil : value
    }

    private static var dbDirectory: URL {
        if let overridePath {
            return URL(fileURLWithPath: overridePath).deletingLastPathComponent()
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("ai.majoor.agent", isDirectory: true)
    }

    private static var dbPath: String {
        overridePath ?? dbDirectory.appendingPathComponent("majoor.sqlite").path
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
    /// Internal so tests can migrate a temporary database.
    static func openAndMigrate(path: String) throws -> DatabaseQueue {
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

        migrator.registerMigration("v3_fts5_contentless") { db in
            // Drop the old content-backed FTS table and its triggers
            try db.execute(sql: "DROP TRIGGER IF EXISTS memories_ai")
            try db.execute(sql: "DROP TRIGGER IF EXISTS memories_ad")
            try db.execute(sql: "DROP TRIGGER IF EXISTS memories_au")
            try db.execute(sql: "DROP TABLE IF EXISTS memories_fts")

            // Recreate as contentless FTS5 with memory_id for stable joins
            try db.execute(sql: """
                CREATE VIRTUAL TABLE memories_fts
                USING fts5(content, memory_id UNINDEXED, content='')
            """)

            // Populate from current memories — pin FTS5 rowid to memories.rowid
            // so delete/update triggers can reference old.rowid correctly
            try db.execute(sql: """
                INSERT INTO memories_fts(rowid, content, memory_id)
                SELECT rowid, content, id FROM memories
            """)

            // Triggers: pin FTS5 rowid to memories.rowid at insert time
            try db.execute(sql: """
                CREATE TRIGGER memories_ai AFTER INSERT ON memories BEGIN
                  INSERT INTO memories_fts(rowid, content, memory_id) VALUES (new.rowid, new.content, new.id);
                END
            """)
            // Contentless FTS5 delete commands require rowid. For contentless tables,
            // FTS5 tracks its own internal rowids. We must pass the rowid of the FTS
            // entry, which matches the memories table rowid at insert time.
            try db.execute(sql: """
                CREATE TRIGGER memories_ad AFTER DELETE ON memories BEGIN
                  INSERT INTO memories_fts(memories_fts, rowid, content, memory_id) VALUES('delete', old.rowid, old.content, old.id);
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER memories_au AFTER UPDATE ON memories BEGIN
                  INSERT INTO memories_fts(memories_fts, rowid, content, memory_id) VALUES('delete', old.rowid, old.content, old.id);
                  INSERT INTO memories_fts(rowid, content, memory_id) VALUES (new.rowid, new.content, new.id);
                END
            """)
        }

        migrator.registerMigration("v4_fts5_external_content") { db in
            // v3's contentless design broke search entirely: contentless FTS5
            // (content='') discards stored column values, so
            // `SELECT memory_id FROM memories_fts` always returns NULL and the
            // join in MemoryStore.search matched zero rows. Recreate the index
            // as external-content (values read from `memories` at query time,
            // joined on rowid) and rebuild it — the rebuild also repairs
            // installs whose index drifted under the pre-pinning v3 triggers.
            try db.execute(sql: "DROP TRIGGER IF EXISTS memories_ai")
            try db.execute(sql: "DROP TRIGGER IF EXISTS memories_ad")
            try db.execute(sql: "DROP TRIGGER IF EXISTS memories_au")
            try db.execute(sql: "DROP TABLE IF EXISTS memories_fts")

            try db.execute(sql: """
                CREATE VIRTUAL TABLE memories_fts
                USING fts5(content, content='memories', content_rowid='rowid')
            """)

            try db.execute(sql: "INSERT INTO memories_fts(memories_fts) VALUES('rebuild')")

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

        // Phase 1 session runtime (PRD section 7): sessions link to tasks by
        // id; approvals log every decision with nonce, risk class and the
        // normalized action signature the Phase 2 trust ledger keys on.
        migrator.registerMigration("v5_sessions_approvals") { db in
            try db.create(table: "sessions", ifNotExists: true) { t in
                t.primaryKey("id", .text)
                t.column("shortId", .integer).notNull()
                t.column("kind", .text).notNull()
                t.column("originChannel", .text).notNull()
                t.column("threadKey", .text).notNull()
                t.column("state", .text).notNull()
                t.column("input", .text).notNull()
                t.column("taskId", .text)
                t.column("createdAt", .text).notNull()
                t.column("endedAt", .text)
                t.column("tokensIn", .integer).defaults(to: 0)
                t.column("tokensOut", .integer).defaults(to: 0)
                t.column("costUSD", .double).defaults(to: 0.0)
                t.column("summary", .text)
            }
            try db.create(indexOn: "sessions", columns: ["createdAt"], options: [.ifNotExists])

            try db.create(table: "approvals", ifNotExists: true) { t in
                t.primaryKey("id", .text)
                t.column("sessionId", .text).notNull()
                t.column("nonce", .text).notNull()
                t.column("actionSignature", .text).notNull()
                t.column("riskClass", .text).notNull()
                t.column("requestedAt", .text).notNull()
                t.column("expiresAt", .text).notNull()
                t.column("decision", .text)
                t.column("decidedByChannel", .text)
                t.column("decidedAt", .text)
                t.column("feedback", .text)
            }
            try db.create(indexOn: "approvals", columns: ["sessionId"], options: [.ifNotExists])
        }

        // Phase 1 channels and control API: who may give instructions, and
        // which devices are paired. Only token hashes are stored.
        migrator.registerMigration("v6_control_clients_contacts") { db in
            try db.create(table: "contacts_policy", ifNotExists: true) { t in
                t.primaryKey("handle", .text)
                t.column("trust", .text).notNull()
                t.column("isVIP", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .text).notNull()
            }
            try db.create(table: "paired_clients", ifNotExists: true) { t in
                t.primaryKey("clientId", .text)
                t.column("name", .text).notNull()
                t.column("tokenHash", .blob).notNull()
                t.column("createdAt", .text).notNull()
                t.column("lastSeenAt", .text)
                t.column("revokedAt", .text)
            }
        }

        // Phase 1 step 6: the full PRD §5.3 automation shape. Phase 1 writes
        // only one-shot reminders; cron, activeHours, inputSources, tier and
        // the ceilings stay null until Phase 2's scheduled jobs.
        migrator.registerMigration("v7_automations") { db in
            try db.create(table: "automations", ifNotExists: true) { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("scheduleKind", .text).notNull()
                t.column("runAt", .datetime)
                t.column("cron", .text)
                t.column("activeHours", .text)
                t.column("inputSources", .text)
                t.column("prompt", .text).notNull()
                t.column("scratch", .text)
                t.column("tier", .text)
                t.column("deliveryChannel", .text).notNull()
                t.column("deliveryThread", .text).notNull()
                t.column("urgencyCeiling", .integer)
                t.column("riskCeiling", .text)
                t.column("enabled", .boolean).notNull().defaults(to: true)
                t.column("nextRunAt", .datetime)
                t.column("claimedAt", .datetime)
                t.column("createdAt", .datetime).notNull()
                t.column("createdBySession", .text)
                t.column("lastRunAt", .datetime)
                t.column("lastResult", .text)
            }
            try db.create(index: "automations_due", on: "automations", columns: ["enabled", "nextRunAt"], options: [.ifNotExists])
        }

        try migrator.migrate(dbQueue)
    }
}
