// AutomationScheduler.swift
// Majoor — Fires due automations: one-shot reminders and cron jobs
//
// One timer, not one per row: sleep until the earliest nextRunAt, wake,
// claim everything due, fire it, re-arm. `wake()` re-arms at once when a
// row is created or cancelled, after system sleep, and when the clock
// changes. At launch, overdue rows fire immediately (reminders prefixed
// "missed" when more than a day late) and stale claims left by a crash are
// released: reminders are at-least-once.
//
// Cron rows (Phase 2 step 5): the next slot is computed from *now*, written
// before the job runs, and the claim is released after it, so a row never
// fires twice in one minute and a Mac that slept through a day runs the job
// once, not once per missed slot. The job itself is the `runJob` closure
// (`JobRunner`); the scheduler only decides when.
//
// Active hours do not apply here on purpose: they govern proactive
// messages (PRD §5.3), which the escalation ladder gates on delivery; a
// reminder is something the owner asked for, and a job that runs at night
// simply records its result.

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
    /// Runs a due cron row (the `JobRunner`). It records its own outcome.
    typealias RunJob = @Sendable (AutomationRecord) async -> Void

    static let staleClaimAge: TimeInterval = 120
    static let missedThreshold: TimeInterval = 24 * 60 * 60
    static let retryDelay: TimeInterval = 60
    static let maxDeliveryAttempts = 5

    private var store: AutomationStore?
    private var clock: any SchedulerClock = SystemSchedulerClock()
    private var timeZone: TimeZone = .current
    private var deliver: Deliver?
    private var recordJob: RecordJob?
    private var onDeliveryFailed: Failed?
    private var runJob: RunJob?
    private var timer: Task<Void, Never>?
    private var running = false
    private var attempts: [String: Int] = [:]
    private(set) var deliveredCount = 0
    private(set) var failedCount = 0
    private(set) var jobRunCount = 0

    init() {}

    func configure(store: AutomationStore, clock: any SchedulerClock = SystemSchedulerClock(),
                   recordJob: RecordJob?, deliver: @escaping Deliver, onDeliveryFailed: Failed? = nil,
                   runJob: RunJob? = nil, timeZone: TimeZone = .current) {
        self.store = store
        self.clock = clock
        self.recordJob = recordJob
        self.deliver = deliver
        self.onDeliveryFailed = onDeliveryFailed
        self.runJob = runJob
        self.timeZone = timeZone
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

    /// The next slot for a cron expression, in the owner's zone. Nil when the
    /// expression is invalid or never fires again.
    func nextRun(forCron cron: String, after date: Date? = nil) -> Date? {
        CronSchedule.parse(cron)?.next(after: date ?? clock.now(), in: timeZone)
    }

    /// Settings ▸ Automations "Run now": makes the row due and fires what is
    /// due. A row that is already running finishes first and then runs again.
    func runNow(id: String) async {
        guard let store, let record = store.record(id: id), record.enabled else { return }
        store.setNextRun(id: id, at: clock.now())
        await fireDue()
        if running { arm() }
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
        switch record.scheduleKind {
        case AutomationRecord.onceSchedule:
            await fireReminder(record, now: now)
        case AutomationRecord.cronSchedule:
            await fireCron(record, now: now)
        default:
            // Unknown kind. The claim is left in place so this does not spin;
            // the next launch releases it and logs again, once.
            MajoorLogger.log("⏰ Automation \(record.id) has scheduleKind '\(record.scheduleKind)', which nothing runs")
        }
    }

    private func fireReminder(_ record: AutomationRecord, now: Date) async {
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

    private func fireCron(_ record: AutomationRecord, now: Date) async {
        guard let store else { return }
        guard let text = record.cron, let schedule = CronSchedule.parse(text) else {
            store.markFailed(id: record.id, at: now, result: "invalid_cron: \(record.cron ?? "")")
            MajoorLogger.error("⏰ Job \(record.name) has an invalid cron expression '\(record.cron ?? "")'; disabled")
            return
        }
        let next = schedule.next(after: now, in: timeZone)
        // Never twice in one minute: a wake() right after a run would otherwise
        // re-fire a row whose slot is still the current minute.
        if let last = record.lastRunAt, Self.sameMinute(last, now) {
            store.markCronFired(id: record.id, at: last, nextRunAt: next)
            store.releaseClaim(id: record.id, retryAt: nil)
            return
        }
        guard let next else {
            store.markFailed(id: record.id, at: now, result: "no_next_run")
            MajoorLogger.error("⏰ Job \(record.name): '\(text)' never fires again; disabled")
            return
        }
        // The next slot is written before the run and computed from now, so a
        // late row (the Mac was asleep) runs once and then waits for its slot.
        store.markCronFired(id: record.id, at: now, nextRunAt: next)
        if let runJob {
            await runJob(record)
        } else {
            MajoorLogger.log("⏰ Job \(record.name) is due but no job runner is configured")
        }
        jobRunCount += 1
        store.releaseClaim(id: record.id, retryAt: nil)
    }

    private static func sameMinute(_ a: Date, _ b: Date) -> Bool {
        Int(a.timeIntervalSince1970 / 60) == Int(b.timeIntervalSince1970 / 60)
    }
}
