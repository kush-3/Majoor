// AutomationScheduler.swift
// Majoor — Fires due automations (Phase 1: one-shot reminders)
//
// One timer, not one per row: sleep until the earliest nextRunAt, wake,
// claim everything due, fire it, re-arm. `wake()` re-arms at once when a
// reminder is created or cancelled, after system sleep, and when the clock
// changes. At launch, overdue rows fire immediately (prefixed "missed" when
// more than a day late) and stale claims left by a crash are released:
// reminders are at-least-once.
//
// Active hours do not apply here on purpose: they govern proactive
// messages (PRD §5.3); a reminder is something the owner asked for.

import Foundation

nonisolated protocol SchedulerClock: Sendable {
    func now() -> Date
    /// Returns when `date` is reached; throws CancellationError if cancelled first.
    func sleep(until date: Date) async throws
}

nonisolated struct SystemSchedulerClock: SchedulerClock {
    func now() -> Date { Date() }

    func sleep(until date: Date) async throws {
        let interval = date.timeIntervalSinceNow
        if interval > 0 { try await Task.sleep(for: .seconds(interval)) }
    }
}

actor AutomationScheduler {

    static let shared = AutomationScheduler()

    /// Sends the reminder text to its channel; throws when it could not.
    typealias Deliver = @Sendable (AutomationRecord, String) async throws -> Void
    /// Records the firing as a job session (input, origin, summary) so it
    /// shows in the feed and in `/status` history.
    typealias RecordJob = @Sendable (String, ChannelRef, String) async -> Void
    typealias Failed = @Sendable (AutomationRecord, String) -> Void

    static let staleClaimAge: TimeInterval = 120
    static let missedThreshold: TimeInterval = 24 * 60 * 60
    static let retryDelay: TimeInterval = 60
    static let maxDeliveryAttempts = 5

    private var store: AutomationStore?
    private var clock: any SchedulerClock = SystemSchedulerClock()
    private var deliver: Deliver?
    private var recordJob: RecordJob?
    private var onDeliveryFailed: Failed?
    private var timer: Task<Void, Never>?
    private var running = false
    private var attempts: [String: Int] = [:]
    private(set) var deliveredCount = 0
    private(set) var failedCount = 0

    init() {}

    func configure(store: AutomationStore, clock: any SchedulerClock = SystemSchedulerClock(),
                   recordJob: RecordJob?, deliver: @escaping Deliver, onDeliveryFailed: Failed? = nil) {
        self.store = store
        self.clock = clock
        self.recordJob = recordJob
        self.deliver = deliver
        self.onDeliveryFailed = onDeliveryFailed
    }

    var isRunning: Bool { running }

    func start() {
        guard !running, let store else { return }
        running = true
        let released = store.releaseStaleClaims(before: clock.now().addingTimeInterval(-Self.staleClaimAge))
        if released > 0 { MajoorLogger.log("⏰ Released \(released) stale automation claim(s) from the last run") }
        arm()
    }

    func stop() {
        running = false
        timer?.cancel()
        timer = nil
    }

    /// Re-arm now: something was added, cancelled, or time jumped.
    func wake() {
        guard running else { return }
        arm()
    }

    // MARK: Timer

    private func arm() {
        timer?.cancel()
        timer = Task { [weak self] in await self?.tick() }
    }

    private func tick() async {
        guard running, let store else { return }
        await fireDue()
        guard running, !Task.isCancelled, let next = store.nextRunAt() else { return }
        do {
            try await clock.sleep(until: next)
        } catch {
            return   // cancelled: a newer timer owns the schedule now
        }
        guard running, !Task.isCancelled else { return }
        arm()
    }

    /// Claims and fires everything due. Also callable directly (tests).
    func fireDue() async {
        guard let store else { return }
        let now = clock.now()
        for record in store.claimDue(now: now) {
            await fire(record, now: now)
        }
    }

    private static let missedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private func fire(_ record: AutomationRecord, now: Date) async {
        guard record.scheduleKind == AutomationRecord.onceSchedule else {
            // Phase 2 territory. The claim is left in place so this does not
            // spin; the next launch releases it and logs again, once.
            MajoorLogger.log("⏰ Automation \(record.id) has scheduleKind '\(record.scheduleKind)'; only one-shot reminders run in Phase 1")
            return
        }
        var message = record.prompt
        if let runAt = record.runAt, now.timeIntervalSince(runAt) > Self.missedThreshold {
            message = "(missed, was due \(Self.missedFormatter.string(from: runAt))) " + message
        }
        let attempt = (attempts[record.id] ?? 0) + 1
        attempts[record.id] = attempt
        if attempt == 1 {
            await recordJob?("Reminder: \(record.prompt)", record.delivery, message)
        }
        do {
            try await deliver?(record, message)
            store?.markDelivered(id: record.id, at: now)
            attempts[record.id] = nil
            deliveredCount += 1
        } catch {
            if attempt >= Self.maxDeliveryAttempts {
                let result = "delivery_failed: \(error)"
                store?.markFailed(id: record.id, at: now, result: result)
                attempts[record.id] = nil
                failedCount += 1
                MajoorLogger.error("⏰ Reminder \(record.id) could not be delivered after \(attempt) attempts: \(error)")
                onDeliveryFailed?(record, result)
            } else {
                MajoorLogger.log("⏰ Reminder \(record.id) delivery failed (attempt \(attempt)): \(error); retrying in \(Int(Self.retryDelay)) s")
                store?.releaseClaim(id: record.id, retryAt: now.addingTimeInterval(Self.retryDelay))
            }
        }
    }
}
