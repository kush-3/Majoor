// AutomationTests.swift
// MajoorTests — Phase 1 step 6: the automations table, the one-timer
// scheduler with a fake clock, and reminder argument validation.

import Foundation
import Testing
@testable import Majoor

/// A clock the test moves by hand. `sleep(until:)` returns once the fake
/// time reaches the date, or throws when the sleeping task is cancelled.
nonisolated final class FakeSchedulerClock: SchedulerClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private(set) var sleeps = 0

    init(_ start: Date) { current = start }

    func now() -> Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }

    func sleep(until date: Date) async throws {
        lock.withLock { sleeps += 1 }
        while now() < date {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// Collects deliveries; can be told to fail the next N.
nonisolated final class DeliveryBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(AutomationRecord, String)] = []
    private var failuresLeft = 0
    private var jobs: [String] = []

    var messages: [String] { lock.withLock { items.map(\.1) } }
    var records: [AutomationRecord] { lock.withLock { items.map(\.0) } }
    var recordedJobs: [String] { lock.withLock { jobs } }

    func failNext(_ count: Int) { lock.withLock { failuresLeft = count } }

    func deliver(_ record: AutomationRecord, _ message: String) throws {
        let fail = lock.withLock { () -> Bool in
            if failuresLeft > 0 { failuresLeft -= 1; return true }
            items.append((record, message))
            return false
        }
        if fail { throw GatewayError.unavailable }
    }

    func recordJob(_ input: String) { lock.withLock { jobs.append(input) } }
}

private func temporaryStore() throws -> (AutomationStore, String) {
    let path = NSTemporaryDirectory() + "majoor-automations-\(UUID().uuidString).sqlite"
    return (AutomationStore(db: try DatabaseManager.openAndMigrate(path: path)), path)
}

@Suite("AutomationStore")
struct AutomationStoreTests {

    @Test("claimDue returns each due row once, even when called concurrently")
    func claimOnce() async throws {
        let (store, path) = try temporaryStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<5 {
            try store.insert(.reminder(message: "r\(index)", runAt: now.addingTimeInterval(TimeInterval(index) - 10), origin: .panel, createdBySession: nil, now: now))
        }
        try store.insert(.reminder(message: "future", runAt: now.addingTimeInterval(600), origin: .panel, createdBySession: nil, now: now))

        let results = await withTaskGroup(of: [AutomationRecord].self, returning: [[AutomationRecord]].self) { group in
            for _ in 0..<4 { group.addTask { store.claimDue(now: now) } }
            var all: [[AutomationRecord]] = []
            for await batch in group { all.append(batch) }
            return all
        }
        let claimed = results.flatMap { $0 }
        #expect(claimed.count == 5)
        #expect(Set(claimed.map(\.id)).count == 5)
        #expect(claimed.allSatisfy { $0.claimedAt == now })
        #expect(claimed.map(\.prompt) == ["r0", "r1", "r2", "r3", "r4"] || Set(claimed.map(\.prompt)) == ["r0", "r1", "r2", "r3", "r4"])
        #expect(store.claimDue(now: now).isEmpty)
        #expect(store.nextRunAt() == now.addingTimeInterval(600))
        #expect(store.listUpcoming().count == 6)
    }

    @Test("delivered, failed and cancelled rows leave the schedule; stale claims are released")
    func lifecycle() throws {
        let (store, path) = try temporaryStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let a = AutomationRecord.reminder(message: "a", runAt: now, origin: .panel, createdBySession: nil, now: now)
        let b = AutomationRecord.reminder(message: "b", runAt: now, origin: .panel, createdBySession: nil, now: now)
        let c = AutomationRecord.reminder(message: "c", runAt: now.addingTimeInterval(60), origin: .panel, createdBySession: nil, now: now)
        for record in [a, b, c] { try store.insert(record) }

        #expect(store.claimDue(now: now).map(\.id) == [a.id, b.id])
        store.markDelivered(id: a.id, at: now)
        #expect(store.record(id: a.id)?.enabled == false)
        #expect(store.record(id: a.id)?.lastResult == AutomationStore.deliveredResult)

        store.releaseClaim(id: b.id, retryAt: now.addingTimeInterval(30))
        #expect(store.record(id: b.id)?.claimedAt == nil)
        #expect(store.nextRunAt() == now.addingTimeInterval(30))
        store.markFailed(id: b.id, at: now, result: "delivery_failed")
        #expect(store.listUpcoming().map(\.id) == [c.id])

        #expect(store.cancel(id: c.id, now: now))
        #expect(!store.cancel(id: c.id, now: now))
        #expect(store.listUpcoming().isEmpty)
        #expect(store.nextRunAt() == nil)

        // A crash between claim and delivery leaves a claim behind.
        let d = AutomationRecord.reminder(message: "d", runAt: now, origin: .panel, createdBySession: nil, now: now)
        try store.insert(d)
        #expect(store.claimDue(now: now).count == 1)
        #expect(store.releaseStaleClaims(before: now.addingTimeInterval(-120)) == 0)
        #expect(store.releaseStaleClaims(before: now.addingTimeInterval(1)) == 1)
        #expect(store.claimDue(now: now).map(\.id) == [d.id])
    }
}

@Suite("AutomationScheduler", .serialized)
struct AutomationSchedulerTests {

    @Test("fires in order as the clock advances, re-arms on insert, catches up and marks a missed one")
    func firesInOrder() async throws {
        let (store, path) = try temporaryStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = FakeSchedulerClock(start)
        let box = DeliveryBox()
        let scheduler = AutomationScheduler()
        await scheduler.configure(store: store, clock: clock,
                                  recordJob: { input, _, _ in box.recordJob(input) },
                                  deliver: { record, message in try box.deliver(record, message) })

        // Overdue by two days and overdue by a minute: both fire at launch.
        try store.insert(.reminder(message: "very old", runAt: start.addingTimeInterval(-2 * 86_400), origin: .panel, createdBySession: nil, now: start))
        try store.insert(.reminder(message: "just late", runAt: start.addingTimeInterval(-60), origin: .panel, createdBySession: nil, now: start))
        try store.insert(.reminder(message: "in ten", runAt: start.addingTimeInterval(600), origin: .panel, createdBySession: nil, now: start))
        try store.insert(.reminder(message: "in twenty", runAt: start.addingTimeInterval(1200), origin: .panel, createdBySession: nil, now: start))

        await scheduler.start()
        #expect(await waitUntil { box.messages.count == 2 })
        #expect(box.messages[0].hasPrefix("(missed, was due "))
        #expect(box.messages[0].hasSuffix(") very old"))
        #expect(box.messages[1] == "just late")
        #expect(box.recordedJobs == ["Reminder: very old", "Reminder: just late"])

        clock.advance(601)
        #expect(await waitUntil { box.messages.count == 3 })
        #expect(box.messages[2] == "in ten")

        // A new reminder due before the next armed one: wake() re-arms.
        try store.insert(.reminder(message: "in fifteen", runAt: start.addingTimeInterval(900), origin: .panel, createdBySession: nil, now: clock.now()))
        await scheduler.wake()
        clock.advance(300)
        #expect(await waitUntil { box.messages.count == 4 })
        #expect(box.messages[3] == "in fifteen")

        clock.advance(300)
        #expect(await waitUntil { box.messages.count == 5 })
        #expect(box.messages[4] == "in twenty")
        #expect(store.listUpcoming().isEmpty)
        #expect(await scheduler.deliveredCount == 5)
        await scheduler.stop()
    }

    @Test("a failed delivery is retried after a minute; the job is recorded once")
    func retries() async throws {
        let (store, path) = try temporaryStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = FakeSchedulerClock(start)
        let box = DeliveryBox()
        let scheduler = AutomationScheduler()
        await scheduler.configure(store: store, clock: clock,
                                  recordJob: { input, _, _ in box.recordJob(input) },
                                  deliver: { record, message in try box.deliver(record, message) })
        let record = AutomationRecord.reminder(message: "flaky", runAt: start, origin: .panel, createdBySession: nil, now: start)
        try store.insert(record)
        box.failNext(2)

        await scheduler.start()
        #expect(await waitUntil { store.record(id: record.id)?.nextRunAt == start.addingTimeInterval(60) })
        #expect(store.record(id: record.id)?.claimedAt == nil)
        #expect(box.messages.isEmpty)

        clock.advance(60)
        #expect(await waitUntil { store.record(id: record.id)?.nextRunAt == start.addingTimeInterval(120) })
        clock.advance(60)
        #expect(await waitUntil { box.messages == ["flaky"] })
        #expect(store.record(id: record.id)?.lastResult == AutomationStore.deliveredResult)
        #expect(box.recordedJobs == ["Reminder: flaky"])
        await scheduler.stop()
    }

    @Test("after five failed deliveries the reminder is marked failed and reported once")
    func givesUp() async throws {
        let (store, path) = try temporaryStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = FakeSchedulerClock(start)
        let box = DeliveryBox()
        let failures = LockedValue<[String]>([])
        let scheduler = AutomationScheduler()
        await scheduler.configure(store: store, clock: clock, recordJob: nil,
                                  deliver: { record, message in try box.deliver(record, message) },
                                  onDeliveryFailed: { record, _ in failures.withValue { $0.append(record.id) } })
        let record = AutomationRecord.reminder(message: "doomed", runAt: start, origin: .panel, createdBySession: nil, now: start)
        try store.insert(record)
        box.failNext(10)
        await scheduler.start()
        // Each failed attempt pushes nextRunAt out by a minute; wait for that
        // before moving the clock, so every attempt actually happens.
        for attempt in 1...4 {
            #expect(await waitUntil { store.record(id: record.id)?.nextRunAt == start.addingTimeInterval(Double(attempt) * 60) })
            clock.advance(60)
        }
        #expect(await waitUntil { store.record(id: record.id)?.enabled == false })
        #expect(store.record(id: record.id)?.lastResult?.hasPrefix("delivery_failed") == true)
        #expect(failures.withValue { $0 } == [record.id])
        #expect(await scheduler.failedCount == 1)
        await scheduler.stop()
    }
}

@Suite("Reminder tools")
struct ReminderToolTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14 22:13:20 UTC

    @Test("time resolution: exactly one of delay_minutes and when, positive, parseable, future")
    func resolve() {
        let zone = TimeZone(identifier: "America/New_York")!
        #expect(ReminderTime.resolve(delayMinutes: nil, when: nil, now: now) == .failure(.missingTime))
        #expect(ReminderTime.resolve(delayMinutes: "5", when: "2030-01-01T10:00", now: now) == .failure(.bothTimes))
        #expect(ReminderTime.resolve(delayMinutes: "0", when: nil, now: now) == .failure(.nonPositiveDelay))
        #expect(ReminderTime.resolve(delayMinutes: "-3", when: nil, now: now) == .failure(.nonPositiveDelay))
        #expect(ReminderTime.resolve(delayMinutes: "soon", when: nil, now: now) == .failure(.badDelay("soon")))
        #expect(ReminderTime.resolve(delayMinutes: "20", when: nil, now: now) == .success(now.addingTimeInterval(1200)))
        #expect(ReminderTime.resolve(delayMinutes: "1.5", when: nil, now: now) == .success(now.addingTimeInterval(120)))
        #expect(ReminderTime.resolve(delayMinutes: nil, when: "tomorrow", now: now) == .failure(.badWhen("tomorrow")))
        #expect(ReminderTime.resolve(delayMinutes: nil, when: "2020-01-01T10:00", now: now, timeZone: zone) == .failure(.inThePast("2020-01-01T10:00")))
        // Local time in the given zone: 17:00 New York on 2023-11-14 is 22:00 UTC.
        let expected = Date(timeIntervalSince1970: 1_700_000_000 - 800)   // 22:00:00 UTC that day
        #expect(ReminderTime.resolve(delayMinutes: nil, when: "2023-11-14T17:00", now: now.addingTimeInterval(-3600), timeZone: zone) == .success(expected))
        // An explicit offset wins over the zone.
        #expect(ReminderTime.resolve(delayMinutes: nil, when: "2023-11-14T23:00:00Z", now: now, timeZone: zone) == .success(Date(timeIntervalSince1970: 1_700_002_800)))
    }

    @Test("create, list and cancel through the tools")
    func tools() async throws {
        let (store, path) = try temporaryStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let now = now
        let create = CreateReminderTool(store: store, scheduler: nil, now: { now })
        let list = ListRemindersTool(store: store)
        let cancel = CancelReminderTool(store: store, scheduler: nil)

        #expect(try await create.execute(arguments: ["message": "x"]).success == false)
        #expect(try await create.execute(arguments: ["delay_minutes": "5"]).success == false)
        let made = try await create.execute(arguments: ["message": "Check the oven", "delay_minutes": "20"])
        #expect(made.success)
        #expect(made.output.hasPrefix("Reminder "))
        let upcoming = store.listUpcoming()
        #expect(upcoming.count == 1)
        #expect(upcoming[0].prompt == "Check the oven")
        #expect(upcoming[0].nextRunAt == now.addingTimeInterval(1200))
        #expect(upcoming[0].deliveryChannel == "panel")
        #expect(upcoming[0].kind == AutomationRecord.reminderKind)
        #expect(upcoming[0].scheduleKind == AutomationRecord.onceSchedule)

        // Inside a session the reminder goes back to that session's channel.
        let context = SessionContext(sessionId: UUID(), origin: ChannelRef(channelId: "imessage", threadKey: "imessage:+15550001111"), trust: .remoteText)
        let viaIMessage = try await SessionContext.$current.withValue(context) {
            try await create.execute(arguments: ["message": "Call mom", "delay_minutes": "60"])
        }
        #expect(viaIMessage.success)
        let second = store.listUpcoming().first { $0.prompt == "Call mom" }
        #expect(second?.deliveryChannel == "imessage")
        #expect(second?.deliveryThread == "imessage:+15550001111")
        #expect(second?.createdBySession == context.sessionId.uuidString)

        let listed = try await list.execute(arguments: [:])
        #expect(listed.output.contains("Check the oven") && listed.output.contains("Call mom"))

        #expect(try await cancel.execute(arguments: [:]).success == false)
        #expect(try await cancel.execute(arguments: ["id": "nope"]).success == false)
        let byText = try await cancel.execute(arguments: ["matching": "OVEN"])
        #expect(byText.success)
        #expect(store.listUpcoming().map(\.prompt) == ["Call mom"])
        let byId = try await cancel.execute(arguments: ["id": second!.id])
        #expect(byId.success)
        #expect(store.listUpcoming().isEmpty)
        #expect(try await list.execute(arguments: [:]).output == "No upcoming reminders.")
    }
}
