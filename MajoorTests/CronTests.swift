// CronTests.swift
// MajoorTests — Phase 2 step 5a: cron expressions and active hours.

import Foundation
import Testing
@testable import Majoor

nonisolated let newYork = TimeZone(identifier: "America/New_York")!
nonisolated let utc = TimeZone(identifier: "UTC")!

/// "yyyy-MM-dd HH:mm" in `tz`.
nonisolated func localDate(_ text: String, _ tz: TimeZone = newYork) -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = tz
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.date(from: text)!
}

nonisolated func localText(_ date: Date, _ tz: TimeZone = newYork) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = tz
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
}

@Suite("CronSchedule")
struct CronScheduleTests {

    /// (expression, after, expected next) in America/New_York. 2026-11-03 is a Tuesday.
    nonisolated static let table: [(String, String, String?)] = [
        ("* * * * *", "2026-11-03 10:17", "2026-11-03 10:18"),
        ("*/5 * * * *", "2026-11-03 10:17", "2026-11-03 10:20"),
        ("0 * * * *", "2026-11-03 10:17", "2026-11-03 11:00"),
        ("30 9 * * *", "2026-11-03 10:17", "2026-11-04 09:30"),
        ("30 10 * * *", "2026-11-03 10:17", "2026-11-03 10:30"),
        ("17 10 * * *", "2026-11-03 10:17", "2026-11-04 10:17"),
        ("0 0 * * 0", "2026-11-03 10:17", "2026-11-08 00:00"),
        ("0 0 * * 7", "2026-11-03 10:17", "2026-11-08 00:00"),
        ("0 0 * * sun", "2026-11-03 10:17", "2026-11-08 00:00"),
        ("0 0 * * SUNDAY", "2026-11-03 10:17", "2026-11-08 00:00"),
        ("0 9 * * mon-fri", "2026-11-03 10:17", "2026-11-04 09:00"),
        ("0 9 * * 1-5", "2026-11-06 10:00", "2026-11-09 09:00"),
        ("0 0 1 * *", "2026-11-03 10:17", "2026-12-01 00:00"),
        ("0 0 1 1 *", "2026-11-03 10:17", "2027-01-01 00:00"),
        ("0 0 1 jan *", "2026-11-03 10:17", "2027-01-01 00:00"),
        ("0 12 25 12 *", "2026-11-03 10:17", "2026-12-25 12:00"),
        ("0 12 25 dec *", "2026-11-03 10:17", "2026-12-25 12:00"),
        ("0 0 29 2 *", "2026-11-03 10:17", "2028-02-29 00:00"),
        ("0 0 31 2 *", "2026-11-03 10:17", nil),
        ("0 0 30 feb *", "2026-11-03 10:17", nil),
        ("0 0 13 * 5", "2026-11-03 10:17", "2026-11-06 00:00"),     // 13th OR Friday
        ("0 0 13 * *", "2026-11-03 10:17", "2026-11-13 00:00"),
        ("15,45 * * * *", "2026-11-03 10:17", "2026-11-03 10:45"),
        ("0 8-10 * * *", "2026-11-03 10:17", "2026-11-04 08:00"),
        ("0 10-12 * * *", "2026-11-03 10:17", "2026-11-03 11:00"),
        ("0 */6 * * *", "2026-11-03 10:17", "2026-11-03 12:00"),
        ("0 1-23/2 * * *", "2026-11-03 10:17", "2026-11-03 11:00"),
        ("5 0 * * *", "2026-11-03 10:17", "2026-11-04 00:05"),
        ("@hourly", "2026-11-03 10:17", "2026-11-03 11:00"),
        ("@daily", "2026-11-03 10:17", "2026-11-04 00:00"),
        ("@weekly", "2026-11-03 10:17", "2026-11-08 00:00"),
        ("@monthly", "2026-11-03 10:17", "2026-12-01 00:00"),
        ("@yearly", "2026-11-03 10:17", "2027-01-01 00:00"),
        ("*/15 9-17 * * 1-5", "2026-11-03 10:17", "2026-11-03 10:30"),
        ("*/15 9-17 * * 1-5", "2026-11-03 17:50", "2026-11-04 09:00"),
        ("59 23 31 12 *", "2026-11-03 10:17", "2026-12-31 23:59"),
        ("0 0 1 */3 *", "2026-11-03 10:17", "2027-01-01 00:00"),
        ("0 0 * * 6,0", "2026-11-03 10:17", "2026-11-07 00:00"),
        ("0 0 * * *", "2026-11-01 00:00", "2026-11-02 00:00"),       // strictly after
        ("30 1 * * *", "2026-11-01 00:00", "2026-11-01 01:30"),      // fall back: first pass of 01:30
        ("0 2 * * *", "2026-03-08 00:30", "2026-03-08 03:00"),       // spring forward: 02:00 does not exist
        ("0 3 * * *", "2026-03-08 00:30", "2026-03-08 03:00"),
        ("0 4 * * *", "2026-03-08 00:30", "2026-03-08 04:00"),
    ]

    @Test("the table", arguments: table)
    func next(expression: String, after: String, expected: String?) throws {
        let schedule = try #require(CronSchedule.parse(expression), "\(expression) should parse")
        let result = schedule.next(after: localDate(after), in: newYork)
        #expect(result.map { localText($0) } == expected, "\(expression) after \(after)")
        if let result {
            #expect(result > localDate(after))
            // A run that landed on the far side of a DST gap shows the hour the
            // clocks jumped to, which the expression itself does not name.
            let gap = newYork.secondsFromGMT(for: result) != newYork.secondsFromGMT(for: result.addingTimeInterval(-3600))
            #expect(gap || schedule.matches(result, in: newYork))
        }
    }

    @Test("DST instants are what the clock actually shows")
    func dstInstants() throws {
        let fallBack = try #require(CronSchedule.parse("30 1 * * *")).next(after: localDate("2026-11-01 00:00"), in: newYork)
        #expect(fallBack?.timeIntervalSince1970 == localDate("2026-11-01 05:30", utc).timeIntervalSince1970)
        let springForward = try #require(CronSchedule.parse("0 2 * * *")).next(after: localDate("2026-03-08 00:30"), in: newYork)
        #expect(springForward?.timeIntervalSince1970 == localDate("2026-03-08 07:00", utc).timeIntervalSince1970)
        // The next day the 02:00 run is back on local time.
        let nextDay = try #require(CronSchedule.parse("0 2 * * *")).next(after: localDate("2026-03-08 12:00"), in: newYork)
        #expect(nextDay.map { localText($0) } == "2026-03-09 02:00")
    }

    @Test("time zone matters")
    func timeZones() throws {
        let schedule = try #require(CronSchedule.parse("0 0 * * *"))
        let after = localDate("2026-11-03 23:59", utc)
        let inUTC = try #require(schedule.next(after: after, in: utc))
        let inNewYork = try #require(schedule.next(after: after, in: newYork))
        #expect(localText(inUTC, utc) == "2026-11-04 00:00")
        #expect(localText(inNewYork, newYork) == "2026-11-04 00:00")
        #expect(inNewYork > inUTC)
    }

    @Test("invalid expressions do not parse", arguments: [
        "60 * * * *", "* 24 * * *", "* * 0 * *", "* * 32 * *", "* * * 13 *", "* * * 0 *", "* * * * 8",
        "* * * *", "* * * * * *", "a b c d e", "*/0 * * * *", "5-3 * * * *", "1,,2 * * * *", "* * * * mon-",
        "", "@fortnightly", "0 0 * * sunn", "0 0 * jam *",
    ])
    func invalid(expression: String) {
        #expect(CronSchedule.parse(expression) == nil, "\(expression)")
    }

    @Test("parsed sets and summaries")
    func parsed() throws {
        let weekdays = try #require(CronSchedule.parse("0 9 * * mon-fri"))
        #expect(weekdays.weekdays == [1, 2, 3, 4, 5])
        #expect(weekdays.summary == "weekdays at 09:00")
        #expect(try #require(CronSchedule.parse("*/5 * * * *")).summary == "every 5 min")
        #expect(try #require(CronSchedule.parse("* * * * *")).summary == "every minute")
        #expect(try #require(CronSchedule.parse("30 7 * * *")).summary == "daily at 07:30")
        #expect(try #require(CronSchedule.parse("0 18 * * 0")).summary == "Sun at 18:00")
        #expect(try #require(CronSchedule.parse("0 0 1 * *")).summary == "monthly on day 1 at 00:00")
        #expect(try #require(CronSchedule.parse("0 0 13 * 5")).summary == "0 0 13 * 5")
        let seven = try #require(CronSchedule.parse("0 0 * * 7"))
        #expect(seven.weekdays == [0])
        let weekly = try #require(CronSchedule.parse("@weekly"))
        let sunday = try #require(CronSchedule.parse("0 0 * * 0"))
        #expect(weekly == sunday)
        #expect(try #require(CronSchedule.parse("  0   0 * * *  ")).expression == "0 0 * * *")
    }
}

@Suite("ActiveHours")
struct ActiveHoursTests {

    @Test("parsing")
    func parsing() {
        #expect(ActiveHours.parse("08:00-23:00") == ActiveHours(startMinute: 480, endMinute: 1380))
        #expect(ActiveHours.parse(" 8:00 - 23:00 ") == ActiveHours(startMinute: 480, endMinute: 1380))
        #expect(ActiveHours.parse("08:00–23:00") == ActiveHours(startMinute: 480, endMinute: 1380))   // en dash
        #expect(ActiveHours.parse("22:00-06:00")?.wrapsMidnight == true)
        #expect(ActiveHours.parse("00:00-24:00")?.isAlwaysOpen == true)
        #expect(ActiveHours.parse("09:00-09:00")?.isAlwaysOpen == true)
        #expect(ActiveHours.parse("08:00-24:00")?.endMinute == 1440)
        #expect(ActiveHours.parse("08:00-24:00")?.text == "08:00-24:00")
        #expect(ActiveHours.parse("25:00-01:00") == nil)
        #expect(ActiveHours.parse("08:60-10:00") == nil)
        #expect(ActiveHours.parse("08:00-24:30") == nil)
        #expect(ActiveHours.parse("08:00") == nil)
        #expect(ActiveHours.parse("abc") == nil)
        #expect(ActiveHours.parse("") == nil)
        #expect(ActiveHours.standard.text == ActiveHours.defaultText)
    }

    @Test("a normal window")
    func normalWindow() {
        let hours = ActiveHours.parse("08:00-23:00")!
        #expect(!hours.contains(localDate("2026-11-03 07:59"), in: newYork))
        #expect(hours.contains(localDate("2026-11-03 08:00"), in: newYork))
        #expect(hours.contains(localDate("2026-11-03 22:59"), in: newYork))
        #expect(!hours.contains(localDate("2026-11-03 23:00"), in: newYork))
        #expect(!hours.contains(localDate("2026-11-03 02:00"), in: newYork))
        // Same instant judged in another zone: 23:30 New York is 04:30 UTC.
        #expect(!hours.contains(localDate("2026-11-03 23:30", newYork), in: utc))
        #expect(hours.contains(localDate("2026-11-03 12:00", utc), in: utc))
        // 08:00-24:00 ends at midnight.
        let toMidnight = ActiveHours.parse("08:00-24:00")!
        #expect(toMidnight.contains(localDate("2026-11-03 23:59"), in: newYork))
        #expect(!toMidnight.contains(localDate("2026-11-04 00:00"), in: newYork))
    }

    @Test("an overnight window wraps midnight")
    func overnight() {
        let hours = ActiveHours.parse("22:00-06:00")!
        #expect(hours.contains(localDate("2026-11-03 23:00"), in: newYork))
        #expect(hours.contains(localDate("2026-11-03 05:59"), in: newYork))
        #expect(!hours.contains(localDate("2026-11-03 06:00"), in: newYork))
        #expect(!hours.contains(localDate("2026-11-03 12:00"), in: newYork))
        #expect(hours.contains(localDate("2026-11-03 22:00"), in: newYork))
    }

    @Test("next opening")
    func nextOpening() {
        let hours = ActiveHours.parse("08:00-23:00")!
        let inside = localDate("2026-11-03 12:00")
        #expect(hours.nextOpening(after: inside, in: newYork) == inside)
        #expect(localText(hours.nextOpening(after: localDate("2026-11-03 07:00"), in: newYork)) == "2026-11-03 08:00")
        #expect(localText(hours.nextOpening(after: localDate("2026-11-03 23:30"), in: newYork)) == "2026-11-04 08:00")
        #expect(localText(hours.nextOpening(after: localDate("2026-11-03 23:00"), in: newYork)) == "2026-11-04 08:00")
        let overnight = ActiveHours.parse("22:00-06:00")!
        #expect(localText(overnight.nextOpening(after: localDate("2026-11-03 12:00"), in: newYork)) == "2026-11-03 22:00")
        #expect(localText(overnight.nextOpening(after: localDate("2026-11-03 06:00"), in: newYork)) == "2026-11-03 22:00")
        // Across the spring-forward night the window still opens at 08:00 local.
        #expect(localText(hours.nextOpening(after: localDate("2026-03-08 01:00"), in: newYork)) == "2026-03-08 08:00")
        #expect(ActiveHours.parse("00:00-24:00")!.nextOpening(after: inside, in: newYork) == inside)
    }

    @Test("the store falls back to the standard window and honors a row's own column")
    func store() throws {
        let suite = "MajoorTests.ActiveHours.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ActiveHoursStore(defaults: defaults)
        #expect(store.hours == .standard)
        store.text = "09:30-21:00"
        #expect(store.hours == ActiveHours(startMinute: 570, endMinute: 1260))
        store.text = "garbage"
        #expect(store.hours == .standard)
        var record = AutomationRecord.reminder(message: "x", runAt: Date(), origin: .panel, createdBySession: nil)
        #expect(store.hours(for: record) == .standard)
        record.activeHours = "10:00-20:00"
        #expect(store.hours(for: record) == ActiveHours(startMinute: 600, endMinute: 1200))
        record.activeHours = "nope"
        #expect(store.hours(for: record) == .standard)
    }
}

// MARK: - Scheduler: cron rows

nonisolated final class JobRunBox: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    func record(_ record: AutomationRecord) { lock.withLock { names.append(record.name) } }
    var runs: [String] { lock.withLock { names } }
}

private func cronStore() throws -> AutomationStore {
    let path = NSTemporaryDirectory() + "majoor-cron-\(UUID().uuidString).sqlite"
    return AutomationStore(db: try DatabaseManager.openAndMigrate(path: path))
}

@Suite("AutomationScheduler cron rows", .serialized)
struct CronSchedulerTests {

    private func makeScheduler(store: AutomationStore, clock: FakeSchedulerClock, box: JobRunBox?) async -> AutomationScheduler {
        let scheduler = AutomationScheduler()
        let runJob: AutomationScheduler.RunJob? = box.map { box in { @Sendable record in box.record(record) } }
        await scheduler.configure(store: store, clock: clock, recordJob: nil,
                                  deliver: { _, _ in },
                                  runJob: runJob,
                                  timeZone: newYork)
        return scheduler
    }

    @Test("a due cron row runs once, advances to the next slot, releases its claim, and runs again at that slot")
    func fires() async throws {
        let store = try cronStore()
        let start = localDate("2026-11-03 10:00")
        let clock = FakeSchedulerClock(start)
        let box = JobRunBox()
        let scheduler = await makeScheduler(store: store, clock: clock, box: box)
        let row = AutomationRecord.job(name: "hello", cron: "*/5 * * * *", tier: .local, delivery: .panel, nextRunAt: start, now: start)
        try store.insert(row)

        await scheduler.fireDue()
        #expect(box.runs == ["hello"])
        var saved = try #require(store.record(id: row.id))
        #expect(saved.lastRunAt == start)
        #expect(saved.nextRunAt.map { localText($0) } == "2026-11-03 10:05")
        #expect(saved.claimedAt == nil)
        #expect(saved.enabled)

        await scheduler.fireDue()                       // same minute, nothing due
        #expect(box.runs.count == 1)

        clock.advance(5 * 60)
        await scheduler.fireDue()
        #expect(box.runs.count == 2)
        saved = try #require(store.record(id: row.id))
        #expect(saved.nextRunAt.map { localText($0) } == "2026-11-03 10:10")
        #expect(await scheduler.jobRunCount == 2)
    }

    @Test("a row that is hours late runs once and waits for its next slot")
    func catchUp() async throws {
        let store = try cronStore()
        let start = localDate("2026-11-03 10:02")
        let clock = FakeSchedulerClock(start)
        let box = JobRunBox()
        let scheduler = await makeScheduler(store: store, clock: clock, box: box)
        try store.insert(AutomationRecord.job(name: "hello", cron: "*/5 * * * *", tier: .local, delivery: .panel,
                                              nextRunAt: start.addingTimeInterval(-3 * 3600), now: start))
        await scheduler.fireDue()
        await scheduler.fireDue()
        #expect(box.runs == ["hello"])
        let saved = try #require(store.all().first)
        #expect(saved.nextRunAt.map { localText($0) } == "2026-11-03 10:05")
    }

    @Test("the same minute never fires twice, even when the slot is still current")
    func sameMinuteGuard() async throws {
        let store = try cronStore()
        let start = localDate("2026-11-03 10:00")
        let clock = FakeSchedulerClock(start.addingTimeInterval(20))
        let box = JobRunBox()
        let scheduler = await makeScheduler(store: store, clock: clock, box: box)
        var row = AutomationRecord.job(name: "hello", cron: "* * * * *", tier: .local, delivery: .panel, nextRunAt: start, now: start)
        row.lastRunAt = start.addingTimeInterval(5)     // ran 15 s ago in this very minute
        try store.insert(row)
        await scheduler.fireDue()
        #expect(box.runs.isEmpty)
        let saved = try #require(store.record(id: row.id))
        #expect(saved.nextRunAt.map { localText($0) } == "2026-11-03 10:01")
        #expect(saved.claimedAt == nil)
    }

    @Test("an invalid expression disables the row honestly; no runner just logs")
    func invalidAndNoRunner() async throws {
        let store = try cronStore()
        let start = localDate("2026-11-03 10:00")
        let clock = FakeSchedulerClock(start)
        let scheduler = await makeScheduler(store: store, clock: clock, box: nil)
        let bad = AutomationRecord.job(name: "bad", cron: "61 * * * *", tier: .local, delivery: .panel, nextRunAt: start, now: start)
        let fine = AutomationRecord.job(name: "fine", cron: "0 * * * *", tier: .local, delivery: .panel, nextRunAt: start, now: start)
        try store.insert(bad)
        try store.insert(fine)
        await scheduler.fireDue()
        let savedBad = try #require(store.record(id: bad.id))
        #expect(!savedBad.enabled)
        #expect(savedBad.lastResult?.hasPrefix("invalid_cron") == true)
        let savedFine = try #require(store.record(id: fine.id))
        #expect(savedFine.enabled)
        #expect(savedFine.nextRunAt.map { localText($0) } == "2026-11-03 11:00")
        #expect(await scheduler.jobRunCount == 1)
    }

    @Test("Run now fires a row whose slot is far away, and the timer picks up the next slot")
    func runNow() async throws {
        let store = try cronStore()
        let start = localDate("2026-11-03 10:00")
        let clock = FakeSchedulerClock(start)
        let box = JobRunBox()
        let scheduler = await makeScheduler(store: store, clock: clock, box: box)
        let row = AutomationRecord.job(name: "weekly", cron: "0 9 * * 0", tier: .local, delivery: .panel,
                                       nextRunAt: localDate("2026-11-08 09:00"), now: start)
        try store.insert(row)
        await scheduler.fireDue()
        #expect(box.runs.isEmpty)
        await scheduler.runNow(id: row.id)
        #expect(box.runs == ["weekly"])
        let saved = try #require(store.record(id: row.id))
        #expect(saved.nextRunAt.map { localText($0) } == "2026-11-08 09:00")
        #expect(saved.lastRunAt == start)
        #expect(await scheduler.nextRun(forCron: "0 9 * * 0").map { localText($0) } == "2026-11-08 09:00")
        #expect(await scheduler.nextRun(forCron: "bogus") == nil)
    }

    @Test("a reminder still delivers next to a cron row")
    func remindersUntouched() async throws {
        let store = try cronStore()
        let start = localDate("2026-11-03 10:00")
        let clock = FakeSchedulerClock(start)
        let box = JobRunBox()
        let delivered = DeliveryBox()
        let scheduler = AutomationScheduler()
        await scheduler.configure(store: store, clock: clock, recordJob: nil,
                                  deliver: { record, message in try delivered.deliver(record, message) },
                                  runJob: { record in box.record(record) }, timeZone: newYork)
        try store.insert(AutomationRecord.reminder(message: "stretch", runAt: start, origin: .panel, createdBySession: nil, now: start))
        try store.insert(AutomationRecord.job(name: "hello", cron: "* * * * *", tier: .local, delivery: .panel, nextRunAt: start, now: start))
        await scheduler.fireDue()
        #expect(delivered.messages == ["stretch"])
        #expect(box.runs == ["hello"])
        #expect(store.listUpcoming().isEmpty)                      // the reminder is done
        #expect(store.listUpcoming(kind: nil).map(\.name) == ["hello"])
    }
}
