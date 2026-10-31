// SessionStore.swift
// Majoor — sessions and approvals tables (migration v5)
//
// Sessions link to the tasks table by id. Approvals record every decision
// with its nonce, risk class and normalized action signature (PRD G5).

import Foundation
import GRDB

nonisolated struct SessionRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "sessions"

    let id: String
    let shortId: Int
    let kind: String
    let originChannel: String
    let threadKey: String
    var state: String
    let input: String
    var taskId: String?
    let createdAt: Date
    var endedAt: Date?
    var tokensIn: Int
    var tokensOut: Int
    var costUSD: Double
    var summary: String?

    init(_ info: SessionInfo) {
        id = info.id.uuidString
        shortId = info.shortId
        kind = info.kind.rawValue
        originChannel = info.origin.channelId
        threadKey = info.origin.threadKey
        state = info.state.rawValue
        input = info.input
        taskId = info.id.uuidString
        createdAt = info.createdAt
        endedAt = info.endedAt
        tokensIn = info.tokensIn
        tokensOut = info.tokensOut
        costUSD = info.costUSD
        summary = info.summary
    }

    var info: SessionInfo? {
        guard let uuid = UUID(uuidString: id), let kind = SessionKind(rawValue: kind) else { return nil }
        return SessionInfo(id: uuid, shortId: shortId, kind: kind,
                           state: SessionState(rawValue: state) ?? .failed,
                           input: input, origin: ChannelRef(channelId: originChannel, threadKey: threadKey),
                           createdAt: createdAt, endedAt: endedAt, summary: summary,
                           tokensIn: tokensIn, tokensOut: tokensOut, costUSD: costUSD)
    }
}

nonisolated struct ApprovalRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "approvals"

    let id: String
    let sessionId: String
    let nonce: String
    let actionSignature: String
    let riskClass: String
    let requestedAt: Date
    let expiresAt: Date
    var decision: String?
    var decidedByChannel: String?
    var decidedAt: Date?
    var feedback: String?

    init(_ request: ApprovalRequest) {
        id = request.id
        sessionId = request.sessionId.uuidString
        nonce = request.nonce
        actionSignature = request.actionSignature
        riskClass = request.riskClass.rawValue
        requestedAt = request.requestedAt
        expiresAt = request.expiresAt
    }
}

nonisolated final class SessionStore: @unchecked Sendable {

    static let shared = SessionStore(db: DatabaseManager.shared.dbQueue)

    private let db: DatabaseQueue

    init(db: DatabaseQueue) {
        self.db = db
    }

    func upsert(_ info: SessionInfo) {
        do {
            try db.write { db in try SessionRecord(info).save(db) }
        } catch {
            MajoorLogger.error("Failed to save session \(info.shortId): \(error)")
        }
    }

    func recent(limit: Int = 50) -> [SessionInfo] {
        do {
            let records = try db.read { db in
                try SessionRecord.order(Column("createdAt").desc).limit(limit).fetchAll(db)
            }
            return records.compactMap(\.info)
        } catch {
            MajoorLogger.error("Failed to load sessions: \(error)")
            return []
        }
    }

    /// Sessions that were alive when the process last died. Called once at
    /// startup, before any new session is created.
    @discardableResult
    func markInterrupted(at date: Date = Date()) -> Int {
        do {
            return try db.write { db in
                try db.execute(
                    sql: "UPDATE sessions SET state = 'failed', summary = ?, endedAt = ? WHERE state IN ('queued', 'running', 'waitingApproval')",
                    arguments: ["Interrupted by restart", date])
                return db.changesCount
            }
        } catch {
            MajoorLogger.error("Failed to mark interrupted sessions: \(error)")
            return 0
        }
    }

    func record(_ request: ApprovalRequest) {
        do {
            try db.write { db in try ApprovalRecord(request).save(db) }
        } catch {
            MajoorLogger.error("Failed to record approval \(request.id): \(error)")
        }
    }

    func resolve(approvalId: String, decision: ApprovalDecision, byChannel: String, at date: Date = Date()) {
        do {
            try db.write { db in
                try db.execute(
                    sql: "UPDATE approvals SET decision = ?, decidedByChannel = ?, decidedAt = ?, feedback = ? WHERE id = ?",
                    arguments: [decision.approved ? "approved" : "denied", byChannel, date, decision.feedback, approvalId])
            }
        } catch {
            MajoorLogger.error("Failed to resolve approval \(approvalId): \(error)")
        }
    }

    func approval(id: String) -> ApprovalRecord? {
        try? db.read { db in try ApprovalRecord.fetchOne(db, key: id) }
    }
}
