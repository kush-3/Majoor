// SourceState.swift
// Majoor — Per-source cursors (`source_state`, migration v8_sources)
//
// A source persists only where it got to (a Gmail historyId, a Slack ts),
// never content. Behind a protocol so tests use a dictionary.

import Foundation
import GRDB

nonisolated protocol SourceCursorStore: Sendable {
    func cursor(for sourceId: String) -> String?
    func setCursor(_ cursor: String?, for sourceId: String)
}

nonisolated struct SourceStateRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "source_state"
    var sourceId: String
    var cursor: String?
    var updatedAt: Date
}

nonisolated final class SourceStateStore: SourceCursorStore, @unchecked Sendable {

    static let shared = SourceStateStore(db: DatabaseManager.shared.dbQueue)

    private let db: DatabaseQueue

    init(db: DatabaseQueue) {
        self.db = db
    }

    func cursor(for sourceId: String) -> String? {
        (try? db.read { db in try SourceStateRecord.fetchOne(db, key: sourceId)?.cursor }) ?? nil
    }

    func setCursor(_ cursor: String?, for sourceId: String) {
        do {
            try db.write { db in
                try SourceStateRecord(sourceId: sourceId, cursor: cursor, updatedAt: Date()).save(db)
            }
        } catch {
            MajoorLogger.error("Could not save cursor for source \(sourceId): \(error)")
        }
    }

    func all() -> [SourceStateRecord] {
        (try? db.read { db in try SourceStateRecord.order(Column("sourceId")).fetchAll(db) }) ?? []
    }
}
