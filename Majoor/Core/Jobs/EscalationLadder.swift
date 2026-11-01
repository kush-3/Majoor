// EscalationLadder.swift
// Majoor — How a job's message reaches the owner (Phase 2 step 5c)
//
// PRD §5.3: log → message → repeat if unacknowledged → call. Urgency 1 stops
// at the log and waits for the brief. Urgency 2 is sent inside active hours
// and deferred to the next opening otherwise, at most once per job per hour.
// Urgency 3 ignores both, repeats after `repeatAfter` while unacknowledged,
// and then reaches the call rung, which is a log line until Phase 3.
// Acknowledged means any owner reply in the delivery thread after the
// message, or the exact reply "ok". State lives in `escalations`; the timer
// pattern is the scheduler's.

import Foundation
import GRDB

// MARK: - escalations

nonisolated struct EscalationRecord: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "escalations"

    var id: String
    var automationId: String
    var jobName: String
    var deliveryChannel: String
    var threadKey: String
    var urgency: Int
    var text: String
    /// 1 logged, 2 sent, 3 repeated, 4 call.
    var rung: Int
    var sentAt: Date?
    var repeatAt: Date?
    var deferredUntil: Date?
    var acknowledgedAt: Date?
    var resolvedAt: Date?
    var createdAt: Date

    var delivery: ChannelRef { ChannelRef(channelId: deliveryChannel, threadKey: threadKey) }
    var isPending: Bool { resolvedAt == nil }
}

nonisolated final class EscalationStore: @unchecked Sendable {

    static let shared = EscalationStore(db: DatabaseManager.shared.dbQueue)

    private let db: DatabaseQueue

    init(db: DatabaseQueue) {
        self.db = db
    }

    func insert(_ record: EscalationRecord) throws {
        try db.write { db in try record.insert(db) }
    }

    func update(_ record: EscalationRecord) throws {
        try db.write { db in try record.update(db) }
    }

    func record(id: String) -> EscalationRecord? {
        try? db.read { db in try EscalationRecord.fetchOne(db, key: id) }
    }

    /// Everything not yet resolved, oldest first.
    func pending() -> [EscalationRecord] {
        (try? db.read { db in
            try EscalationRecord.filter(Column("resolvedAt") == nil).order(Column("createdAt")).fetchAll(db)
        }) ?? []
    }

    func pending(threadKey: String) -> [EscalationRecord] {
        pending().filter { $0.threadKey == threadKey }
    }

    /// When this job last sent a message (rung 2 or higher).
    func lastSentAt(automationId: String) -> Date? {
        try? db.read { db in
            try EscalationRecord.filter(Column("automationId") == automationId && Column("sentAt") != nil)
                .order(Column("sentAt").desc).fetchOne(db)?.sentAt
        }
    }

    /// Newest first, for Settings.
    func recent(limit: Int = 50) -> [EscalationRecord] {
        (try? db.read { db in
            try EscalationRecord.order(Column("createdAt").desc).limit(limit).fetchAll(db)
        }) ?? []
    }

    /// The earliest moment anything pending needs attention.
    func nextDue() -> Date? {
        pending().compactMap { record -> Date? in
            if record.acknowledgedAt != nil { return nil }
            if record.sentAt == nil { return record.deferredUntil }
            return record.repeatAt
        }.min()
    }
}

// MARK: - Ladder

actor EscalationLadder {

    static let shared = EscalationLadder()

    nonisolated enum Outcome: Sendable, Equatable {
        case logged
        case sent(rung: Int)
        case deferred(until: Date)
        case rateLimited
    }

    /// Sends text to a thread; throws when the channel cannot.
    typealias Send = @Sendable (ChannelRef, String) async throws -> Void
    /// Local notification plus panel toast when the channel failed (title, body).
    typealias Fallback = @Sendable (String, String) async -> Void

    static let repeatAfter: TimeInterval = 30 * 60
    static let rung2RateLimit: TimeInterval = 60 * 60
    static let callRung = 4

    private var store: EscalationStore?
    private var clock: any SchedulerClock = SystemSchedulerClock()
    private var timeZone: TimeZone = .current
    private var send: Send?
    private var fallback: Fallback?
    private var timer: Task<Void, Never>?
    private var running = false
    private(set) var sentCount = 0
    private(set) var callCount = 0

    init() {}

    func configure(store: EscalationStore, clock: any SchedulerClock = SystemSchedulerClock(), timeZone: TimeZone = .current,
                   send: @escaping Send, fallback: Fallback? = nil) {
        self.store = store
        self.clock = clock
        self.timeZone = timeZone
        self.send = send
        self.fallback = fallback
    }

    func start() {
        guard !running, store != nil else { return }
        running = true
        arm()
    }

    func stop() {
        running = false
        timer?.cancel()
        timer = nil
    }

    func wake() {
        guard running else { return }
        arm()
    }

    var pendingCount: Int { store?.pending().count ?? 0 }

    // MARK: Escalate

    /// A job's `notify`. Rung 1 (the log) always happens; what else does
    /// depends on urgency, active hours and the hourly limit.
    func escalate(automationId: String, jobName: String, urgency: Int, text: String, delivery: ChannelRef,
                  activeHours: ActiveHours) async -> Outcome {
        guard let store else {
            MajoorLogger.error("🪜 Escalation for \(jobName) dropped: ladder not configured")
            return .logged
        }
        let now = clock.now()
        let clamped = max(1, min(urgency, 3))
        MajoorLogger.log("🪜 [\(jobName)] urgency \(clamped): \(text.prefix(160))")
        var record = EscalationRecord(id: UUID().uuidString, automationId: automationId, jobName: jobName,
                                      deliveryChannel: delivery.channelId, threadKey: delivery.threadKey, urgency: clamped,
                                      text: text, rung: 1, sentAt: nil, repeatAt: nil, deferredUntil: nil,
                                      acknowledgedAt: nil, resolvedAt: nil, createdAt: now)
        if clamped == 1 {
            record.resolvedAt = now
            try? store.insert(record)
            return .logged
        }
        if clamped == 2 {
            if let last = store.lastSentAt(automationId: automationId), now.timeIntervalSince(last) < Self.rung2RateLimit {
                record.resolvedAt = now
                try? store.insert(record)
                MajoorLogger.log("🪜 [\(jobName)] held: a message went out \(Int(now.timeIntervalSince(last) / 60)) min ago")
                return .rateLimited
            }
            if !activeHours.contains(now, in: timeZone) {
                let opening = activeHours.nextOpening(after: now, in: timeZone)
                record.deferredUntil = opening
                try? store.insert(record)
                MajoorLogger.log("🪜 [\(jobName)] deferred to \(opening) (outside \(activeHours.text))")
                if running { arm() }
                return .deferred(until: opening)
            }
        }
        try? store.insert(record)
        await deliver(&record, now: now, repeatText: false)
        if running { arm() }
        return .sent(rung: record.rung)
    }

    /// Sends rung 2 (or a rung-3 repeat), records it, and schedules the
    /// repeat for urgency 3. A failed send still counts as sent after the
    /// fallback fired: the owner was told by the only route left.
    private func deliver(_ record: inout EscalationRecord, now: Date, repeatText: Bool) async {
        let message = repeatText ? "(Still waiting on this) \(record.text)" : record.text
        do {
            if let send { try await send(record.delivery, message) } else { throw GatewayError.unavailable }
        } catch {
            MajoorLogger.error("🪜 [\(record.jobName)] send to \(record.deliveryChannel) failed: \(error); using the local fallback")
            await fallback?("Majoor · \(record.jobName)", message)
        }
        sentCount += 1
        record.rung = repeatText ? 3 : 2
        record.sentAt = now
        record.deferredUntil = nil
        if record.urgency >= 3 {
            record.repeatAt = now.addingTimeInterval(Self.repeatAfter)
        } else {
            record.repeatAt = nil
            record.resolvedAt = now
        }
        try? store?.update(record)
    }

    // MARK: Acknowledge

    /// Every owner message in a thread acknowledges what was sent there. The
    /// exact reply "ok" is consumed (true) when something was waiting; any
    /// other text also acknowledges but still runs as whatever it is.
    func acknowledge(threadKey: String, text: String, at date: Date) -> Bool {
        guard let store else { return false }
        var matched = 0
        for var record in store.pending(threadKey: threadKey) where record.sentAt != nil && record.acknowledgedAt == nil {
            record.acknowledgedAt = date
            record.resolvedAt = date
            record.repeatAt = nil
            try? store.update(record)
            matched += 1
        }
        if matched > 0 { MajoorLogger.log("🪜 \(matched) escalation(s) acknowledged in \(threadKey)") }
        let isOK = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ok"
        return isOK && matched > 0
    }

    // MARK: Timer

    private func arm() {
        timer?.cancel()
        timer = Task { [weak self] in await self?.loop() }
    }

    private func loop() async {
        guard running, let store else { return }
        await tick()
        guard running, !Task.isCancelled, let next = store.nextDue() else { return }
        do {
            try await clock.sleep(until: next)
        } catch {
            return
        }
        guard running, !Task.isCancelled else { return }
        arm()
    }

    /// Sends what was deferred, repeats what went unacknowledged, and reaches
    /// the call rung. Also callable directly (tests).
    func tick() async {
        guard let store else { return }
        let now = clock.now()
        for var record in store.pending() {
            if record.acknowledgedAt != nil {
                record.resolvedAt = now
                try? store.update(record)
                continue
            }
            if record.sentAt == nil {
                if let until = record.deferredUntil, until <= now {
                    await deliver(&record, now: now, repeatText: false)
                }
                continue
            }
            guard let repeatAt = record.repeatAt, repeatAt <= now else { continue }
            if record.rung == 2 {
                await deliver(&record, now: now, repeatText: true)
            } else {
                // Rung 4: the call. Phase 3 dials; this logs and lets go.
                MajoorLogger.error("📞 [\(record.jobName)] still unacknowledged after two messages; the call rung is Phase 3. \(record.text.prefix(120))")
                callCount += 1
                record.rung = Self.callRung
                record.repeatAt = nil
                record.resolvedAt = now
                try? store.update(record)
            }
        }
    }
}
