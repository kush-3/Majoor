// LocationJobTests.swift
// MajoorTests — Phase 2 step 6f: "where you should be" through the job
// runner, with a fake calendar, fake fixes and a fake route estimator.

import Foundation
import Testing
@testable import Majoor

nonisolated final class FakePlanner: LocationPlanning, @unchecked Sendable {
    private let lock = NSLock()
    var events: [CalendarEventSummary]
    var fix: LocationFixRecord?
    var fresh: LocationFixRecord?
    private(set) var fixRequests = 0
    var calendarError: Error?

    init(events: [CalendarEventSummary], fix: LocationFixRecord?, fresh: LocationFixRecord? = nil) {
        self.events = events
        self.fix = fix
        self.fresh = fresh
    }

    func upcomingEvents(within interval: TimeInterval) async throws -> [CalendarEventSummary] {
        if let calendarError { throw calendarError }
        return events
    }
    func latestFix() async -> LocationFixRecord? { fix }
    func requestFix() async -> LocationFixRecord? {
        lock.withLock { fixRequests += 1 }
        return fresh
    }
    var requests: Int { lock.withLock { fixRequests } }
}

nonisolated final class FakeEstimator: RouteEstimating, @unchecked Sendable {
    private let lock = NSLock()
    /// Minutes per destination; a missing destination throws.
    private let minutes: [String: Double]
    private(set) var modes: [TravelMode] = []

    init(_ minutes: [String: Double]) {
        self.minutes = minutes
    }

    func travelTime(fromLatitude latitude: Double, longitude: Double, to destination: String, mode: TravelMode) async throws -> TimeInterval {
        lock.withLock { modes.append(mode) }
        guard let value = minutes[destination] else { throw RouteEstimationError.destinationNotFound(destination) }
        return value * 60
    }
    var usedModes: [TravelMode] { lock.withLock { modes } }
}

nonisolated func event(_ id: String, _ title: String, start: Date, location: String?, allDay: Bool = false) -> CalendarEventSummary {
    CalendarEventSummary(id: id, title: title, start: start, end: start.addingTimeInterval(1800), location: location,
                         attendeeCount: 2, isAllDay: allDay, calendar: "Work")
}

nonisolated func fix(at: Date) -> LocationFixRecord {
    LocationFixRecord(id: 1, at: at, latitude: 33.7490, longitude: -84.3880, accuracy: 20, place: "Home", event: "arrive")
}

@Suite("LocationJob")
struct LocationJobTests {

    private let now = localDate("2026-11-03 14:45")
    private var threePM: Date { localDate("2026-11-03 15:00") }
    private let settings = LocationJobSettings(travelMode: .automobile, importantMarker: "!")

    private func harness(_ planner: FakePlanner, _ estimator: FakeEstimator, settings: LocationJobSettings? = nil,
                         at time: Date? = nil) async throws -> (ConsolidationHarness, JobDefinition) {
        let chosen = settings ?? self.settings
        let definition = LocationJob.definition(planner: planner, estimator: estimator, settings: { chosen })
        let h = try await ConsolidationHarness.make(definition: definition, provider: nil, now: time ?? now)
        return (h, definition)
    }

    @Test("late for a located event: one urgency-2 message with the ETA, never the coordinates")
    func late() async throws {
        let planner = FakePlanner(events: [event("e1", "Coffee with Sam", start: threePM, location: "Blue Bottle")], fix: fix(at: now.addingTimeInterval(-120)))
        let estimator = FakeEstimator(["Blue Bottle": 22])
        let (h, definition) = try await harness(planner, estimator)
        let outcome = await h.runner.run(try h.row(definition))

        #expect(outcome == .notify(urgency: 2, text: "You won't make your 3pm at Blue Bottle (ETA 22 min, starts in 15)"))
        #expect(h.notify.all.count == 1)
        #expect(h.notify.all.first?.urgency == 2)
        #expect(h.notify.all.first?.text.contains("33.7") == false)
        #expect(planner.requests == 0)
        #expect(estimator.usedModes == [.automobile])
        #expect(h.runs.recent().first?.outcome == "notify")
    }

    @Test("the important marker raises it to urgency 3; the walking mode is honored")
    func important() async throws {
        let planner = FakePlanner(events: [event("e2", "Board meeting !", start: localDate("2026-11-03 15:15"), location: "HQ")], fix: fix(at: now))
        let estimator = FakeEstimator(["HQ": 45])
        let (h, definition) = try await harness(planner, estimator, settings: LocationJobSettings(travelMode: .walking, importantMarker: "!"))
        let outcome = await h.runner.run(try h.row(definition))
        #expect(outcome == .notify(urgency: 3, text: "You won't make your 3:15pm at HQ (ETA 45 min, starts in 30)"))
        #expect(estimator.usedModes == [.walking])
    }

    @Test("on time stays quiet")
    func onTime() async throws {
        let planner = FakePlanner(events: [event("e1", "Coffee", start: threePM, location: "Blue Bottle")], fix: fix(at: now))
        let (h, definition) = try await harness(planner, FakeEstimator(["Blue Bottle": 10]))
        let outcome = await h.runner.run(try h.row(definition))
        #expect(outcome == .noChange(summary: "on time for 1 located event(s)"))
        #expect(h.notify.all.isEmpty)
    }

    @Test("a late event is warned about once; the warning is remembered in scratch")
    func warnOnce() async throws {
        let planner = FakePlanner(events: [event("e1", "Coffee", start: threePM, location: "Blue Bottle")], fix: fix(at: now))
        let (h, definition) = try await harness(planner, FakeEstimator(["Blue Bottle": 40]))
        let record = try h.row(definition)
        let first = await h.runner.run(record)
        guard case .notify = first else { Issue.record("expected notify, got \(first)"); return }
        let again = try #require(h.automations.record(id: record.id))
        #expect(h.scratch(definition, as: LocationJobState.self)?.warned["e1"] == now)
        let second = await h.runner.run(again)
        #expect(second == .noChange(summary: "no located event in the next 30 min"))
        #expect(h.notify.all.count == 1)
    }

    @Test("no fix, or only a fix older than an hour, says the location is stale and asks the phone once")
    func noFix() async throws {
        let planner = FakePlanner(events: [event("e1", "Coffee", start: threePM, location: "Blue Bottle")], fix: nil)
        let (h, definition) = try await harness(planner, FakeEstimator(["Blue Bottle": 40]))
        #expect(await h.runner.run(try h.row(definition)) == .noChange(summary: LocationJob.staleSummary))
        #expect(planner.requests == 1)
        #expect(h.notify.all.isEmpty)

        let stale = FakePlanner(events: [event("e1", "Coffee", start: threePM, location: "Blue Bottle")], fix: fix(at: now.addingTimeInterval(-2 * 3600)))
        let (h2, definition2) = try await harness(stale, FakeEstimator(["Blue Bottle": 40]))
        #expect(await h2.runner.run(try h2.row(definition2)) == .noChange(summary: LocationJob.staleSummary))
        #expect(stale.requests == 1)
    }

    @Test("a fix between ten minutes and an hour old is used when the phone has nothing fresher; a fresh one wins")
    func fixFreshness() async throws {
        let planner = FakePlanner(events: [event("e1", "Coffee", start: threePM, location: "Blue Bottle")], fix: fix(at: now.addingTimeInterval(-20 * 60)))
        let (h, definition) = try await harness(planner, FakeEstimator(["Blue Bottle": 40]))
        guard case .notify = await h.runner.run(try h.row(definition)) else { Issue.record("expected notify from the 20-minute-old fix"); return }
        #expect(planner.requests == 1)

        let fresh = FakePlanner(events: [event("e1", "Coffee", start: threePM, location: "Blue Bottle")],
                                fix: fix(at: now.addingTimeInterval(-2 * 3600)), fresh: fix(at: now))
        let (h2, definition2) = try await harness(fresh, FakeEstimator(["Blue Bottle": 40]))
        guard case .notify = await h2.runner.run(try h2.row(definition2)) else { Issue.record("expected notify from the fresh fix"); return }
        #expect(fresh.requests == 1)
    }

    @Test("events without a location, all-day events, past events and far events are not candidates")
    func filtering() async throws {
        let planner = FakePlanner(events: [
            event("a", "No place", start: threePM, location: nil),
            event("b", "Blank place", start: threePM, location: "   "),
            event("c", "All day", start: threePM, location: "Somewhere", allDay: true),
            event("d", "Started", start: now.addingTimeInterval(-60), location: "Somewhere"),
            event("e", "Far", start: now.addingTimeInterval(45 * 60), location: "Somewhere"),
        ], fix: fix(at: now))
        let (h, definition) = try await harness(planner, FakeEstimator(["Somewhere": 90]))
        #expect(await h.runner.run(try h.row(definition)) == .noChange(summary: "no located event in the next 30 min"))
        #expect(planner.requests == 0)
    }

    @Test("an estimator failure is reported, not guessed; a calendar failure is a quiet no_change")
    func failures() async throws {
        let planner = FakePlanner(events: [event("e1", "Coffee", start: threePM, location: "Nowhere")], fix: fix(at: now))
        let (h, definition) = try await harness(planner, FakeEstimator([:]))
        #expect(await h.runner.run(try h.row(definition)) == .noChange(summary: "no route for 1 of 1 located event(s); on time for the rest"))

        let broken = FakePlanner(events: [], fix: fix(at: now))
        broken.calendarError = CalendarSourceError.noAccess
        let (h2, definition2) = try await harness(broken, FakeEstimator([:]))
        guard case .noChange(let summary) = await h2.runner.run(try h2.row(definition2)) else { Issue.record("expected no_change"); return }
        #expect(summary.hasPrefix("calendar unavailable"))
    }

    @Test("message wording and the settings defaults")
    func wordingAndDefaults() throws {
        let text = LocationJob.message(event: event("x", "Dentist", start: localDate("2026-11-03 09:30"), location: "Dr. Chen"),
                                       destination: "Dr. Chen", eta: 61 * 60 + 1, timeLeft: 14 * 60 + 59, timeZone: newYork)
        #expect(text == "You won't make your 9:30am at Dr. Chen (ETA 62 min, starts in 14)")

        let suite = "MajoorTests.LocationJob.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fresh = LocationJobSettings(defaults: defaults)
        #expect(fresh.travelMode == .automobile)
        #expect(fresh.importantMarker == "!")
        defaults.set("walking", forKey: LocationJobSettings.travelModeKey)
        defaults.set(" [urgent] ", forKey: LocationJobSettings.importantMarkerKey)
        let chosen = LocationJobSettings(defaults: defaults)
        #expect(chosen.travelMode == .walking)
        #expect(chosen.importantMarker == "[urgent]")

        let definition = try #require(JobCatalog.definition(named: JobNames.location))
        #expect(definition.tier == .local)
        #expect(definition.modelFree)
        #expect(definition.urgencyCeiling == 3)
        #expect(definition.defaultCron == "*/5 * * * *")
        #expect(definition.inputs.isEmpty)
    }
}
