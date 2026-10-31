// AutomationStore.swift
// Majoor — The `automations` table (migration v7)
//
// Full PRD §5.3 shape from day one so Phase 2's scheduled jobs need no
// ALTER. Phase 1 uses it for one-shot reminders: kind "reminder",
// scheduleKind "once", the reminder text in `prompt`, delivery to the
// channel and thread the request came from. `claimDue` is a single write
// transaction, so two timers can never fire the same row.

import Foundation
import GRDB

nonisolated struct AutomationRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "automations"

    static let reminderKind = "reminder"
    static let onceSchedule = "once"

    var id: String
    var name: String
    var kind: String
    var scheduleKind: String
    var runAt: Date?
    var cron: String?
    var activeHours: String?
    var inputSources: String?
    var prompt: String
    var scratch: String?
    var tier: String?
    var deliveryChannel: String
    var deliveryThread: String
    var urgencyCeiling: Int?
    var riskCeiling: String?
    var enabled: Bool
    var nextRunAt: Date?
    var claimedAt: Date?
    var createdAt: Date
    var createdBySession: String?
    var lastRunAt: Date?
    var lastResult: String?

    var delivery: ChannelRef { ChannelRef(channelId: deliveryChannel, threadKey: deliveryThread) }

    /// A one-shot reminder delivered back to where it was asked for.
    static func reminder(message: String, runAt: Date, origin: ChannelRef, createdBySession: SessionID?, now: Date = Date()) -> AutomationRecord {
        AutomationRecord(
            id: UUID().uuidString, name: String(message.prefix(60)), kind: reminderKind, scheduleKind: onceSchedule,
            runAt: runAt, cron: nil, activeHours: nil, inputSources: nil, prompt: message, scratch: nil, tier: nil,
            deliveryChannel: origin.channelId, deliveryThread: origin.threadKey, urgencyCeiling: nil, riskCeiling: nil,
            enabled: true, nextRunAt: runAt, claimedAt: nil, createdAt: now, createdBySession: createdBySession?.uuidString,
            lastRunAt: nil, lastResult: nil)
    }
}

nonisolated final class AutomationStore: @unchecked Sendable {

    static let shared = AutomationStore(db: DatabaseManager.shared.dbQueue)

    static let deliveredResult = "delivered"
    static let cancelledResult = "cancelled"

    private let db: DatabaseQueue

    init(db: DatabaseQueue) {
        self.db = db
    }

    func insert(_ record: AutomationRecord) throws {
        try db.write { db in try record.insert(db) }
    }

    func record(id: String) -> AutomationRecord? {
        try? db.read { db in try AutomationRecord.fetchOne(db, key: id) }
    }

    /// Disables the row. False when there is no enabled row with that id.
    @discardableResult
    func cancel(id: String, now: Date = Date()) -> Bool {
        (try? db.write { db -> Bool in
            guard var record = try AutomationRecord.filter(Column("id") == id && Column("enabled") == true).fetchOne(db) else { return false }
            record.enabled = false
            record.lastResult = Self.cancelledResult
            record.lastRunAt = now
            try record.update(db)
            return true
        }) ?? false
    }

    /// Enabled rows, soonest first. Reminders only unless `kind` is nil.
    func listUpcoming(limit: Int = 50, kind: String? = AutomationRecord.reminderKind) -> [AutomationRecord] {
        (try? db.read { db in
            var request = AutomationRecord.filter(Column("enabled") == true).order(Column("nextRunAt")).limit(limit)
            if let kind { request = request.filter(Column("kind") == kind) }
            return try request.fetchAll(db)
        }) ?? []
    }

    /// The earliest moment anything enabled and unclaimed is due.
    func nextRunAt() -> Date? {
        try? db.read { db in
            try AutomationRecord
                .filter(Column("enabled") == true && Column("claimedAt") == nil && Column("nextRunAt") != nil)
                .order(Column("nextRunAt"))
                .fetchOne(db)?.nextRunAt
        }
    }

    /// Selects every enabled, unclaimed row due at or before `now`, marks it
    /// claimed, and returns it, all in one transaction.
    func claimDue(now: Date) -> [AutomationRecord] {
        (try? db.write { db -> [AutomationRecord] in
            let due = try AutomationRecord
                .filter(Column("enabled") == true && Column("claimedAt") == nil && Column("nextRunAt") <= now)
                .order(Column("nextRunAt"))
                .fetchAll(db)
            var claimed: [AutomationRecord] = []
            for var record in due {
                record.claimedAt = now
                try record.update(db)
                claimed.append(record)
            }
            return claimed
        }) ?? []
    }

    /// A one-shot is finished: disabled with its outcome recorded.
    func markDelivered(id: String, at now: Date) {
        update(id: id) { record in
            record.enabled = false
            record.lastRunAt = now
            record.lastResult = Self.deliveredResult
        }
    }

    /// Delivery failed: unclaim and try again at `retryAt`.
    func releaseClaim(id: String, retryAt: Date?) {
        update(id: id) { record in
            record.claimedAt = nil
            if let retryAt { record.nextRunAt = retryAt }
        }
    }

    func markFailed(id: String, at now: Date, result: String) {
        update(id: id) { record in
            record.enabled = false
            record.lastRunAt = now
            record.lastResult = result
        }
    }

    /// Crash recovery: claims older than `before` on rows still enabled were
    /// never finished; release them so launch catch-up fires them again.
    @discardableResult
    func releaseStaleClaims(before: Date) -> Int {
        (try? db.write { db -> Int in
            let stale = try AutomationRecord.filter(Column("enabled") == true && Column("claimedAt") != nil && Column("claimedAt") < before).fetchAll(db)
            for var record in stale {
                record.claimedAt = nil
                try record.update(db)
            }
            return stale.count
        }) ?? 0
    }

    private func update(id: String, _ change: (inout AutomationRecord) -> Void) {
        try? db.write { db in
            guard var record = try AutomationRecord.fetchOne(db, key: id) else { return }
            change(&record)
            try record.update(db)
        }
    }
}
