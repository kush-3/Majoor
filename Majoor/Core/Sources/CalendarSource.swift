// CalendarSource.swift
// Majoor — Calendar changes as events (Phase 2 step 4c)
//
// EventKit posts `EKEventStoreChanged` on the one shared store whenever
// anything changes; the source debounces five seconds and re-reads the next
// 48 hours. It never prompts for access: the calendar tools do that on the
// owner's first request, and until then this source simply reports no access.

import Foundation
import EventKit

nonisolated struct CalendarEventSummary: Sendable, Codable, Equatable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var location: String?
    var attendeeCount: Int
    var isAllDay: Bool
    var calendar: String
}

nonisolated enum CalendarSourceError: Error, Sendable, Equatable {
    case noAccess
}

/// EventKit, as far as the source is concerned. Tests script one.
nonisolated protocol CalendarReading: Sendable {
    func events(from start: Date, to end: Date) async throws -> [CalendarEventSummary]
    /// One tick per store change; the stream ends only when the reader is deallocated.
    func changes() -> AsyncStream<Void>
}

actor CalendarSource: EventSource {

    static let sourceId = "calendar"
    static let defaultWindow: TimeInterval = 48 * 3600
    static let defaultDebounce: Duration = .seconds(5)

    nonisolated let id = CalendarSource.sourceId
    nonisolated let dataClass: DataClass = .calendar
    nonisolated let events: AsyncStream<SourceEvent>
    private let continuation: AsyncStream<SourceEvent>.Continuation

    private let reader: any CalendarReading
    private let window: TimeInterval
    private let debounce: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> Date

    private(set) var pendingChanges = 0
    private var debounceTask: Task<Void, Never>?
    private(set) var lastWindow: [CalendarEventSummary] = []
    private(set) var emitCount = 0

    init(reader: any CalendarReading, window: TimeInterval = CalendarSource.defaultWindow, debounce: Duration = CalendarSource.defaultDebounce,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.reader = reader
        self.window = window
        self.debounce = debounce
        self.sleep = sleep
        self.now = now
        (events, continuation) = AsyncStream.makeStream(of: SourceEvent.self, bufferingPolicy: .unbounded)
    }

    func start() async throws {
        try await emitWindow()
        for await _ in reader.changes() {
            try Task.checkCancellation()
            noteChange()
        }
    }

    func stop() async {
        debounceTask?.cancel()
        debounceTask = nil
    }

    /// Events starting within `interval` from now, for the location job.
    func upcoming(within interval: TimeInterval) async throws -> [CalendarEventSummary] {
        let start = now()
        return try await reader.events(from: start, to: start.addingTimeInterval(interval))
    }

    /// The window a snapshot covers: from the start of the current minute.
    static func window(from date: Date, length: TimeInterval) -> (start: Date, end: Date) {
        let start = Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
        return (start, start.addingTimeInterval(length))
    }

    /// A burst of store notifications becomes one re-read, `debounce` after
    /// the last of them.
    private func noteChange() {
        pendingChanges += 1
        guard debounceTask == nil else { return }
        debounceTask = Task { [weak self] in
            await self?.drainChanges()
        }
    }

    private func drainChanges() async {
        var seen = 0
        while seen != pendingChanges {
            seen = pendingChanges
            do { try await sleep(debounce) } catch { debounceTask = nil; return }
        }
        pendingChanges = 0
        debounceTask = nil
        do {
            try await emitWindow()
        } catch {
            MajoorLogger.error("Calendar source could not re-read the window: \(error)")
        }
    }

    private func emitWindow() async throws {
        let (start, end) = Self.window(from: now(), length: window)
        let summaries = try await reader.events(from: start, to: end)
        lastWindow = summaries
        emitCount += 1
        continuation.yield(SourceEvent(sourceId: id, kind: .calendarChanged, at: now(), payload: Self.payload(summaries, start: start, end: end)))
    }

    static func payload(_ summaries: [CalendarEventSummary], start: Date, end: Date) -> JSONValue {
        let formatter = ISO8601DateFormatter()
        func clean(_ text: String) -> JSONValue { .string(String(UntrustedContent.stripControlCharacters(text).prefix(300))) }
        return .object([
            "windowStart": .string(formatter.string(from: start)),
            "windowEnd": .string(formatter.string(from: end)),
            "events": .array(summaries.map { event in
                var object: [String: JSONValue] = [
                    "id": .string(event.id),
                    "title": clean(event.title),
                    "start": .string(formatter.string(from: event.start)),
                    "end": .string(formatter.string(from: event.end)),
                    "attendeeCount": .number(Double(event.attendeeCount)),
                    "isAllDay": .bool(event.isAllDay),
                    "calendar": clean(event.calendar),
                ]
                if let location = event.location { object["location"] = clean(location) }
                return .object(object)
            }),
        ])
    }
}

// MARK: - Live reader

/// Reads `sharedEventStore` (the one instance the calendar tools keep alive
/// for its XPC connection). Access must already be granted.
nonisolated final class LiveCalendarReader: CalendarReading, @unchecked Sendable {

    func events(from start: Date, to end: Date) async throws -> [CalendarEventSummary] {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess else { throw CalendarSourceError.noAccess }
        let predicate = sharedEventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        return sharedEventStore.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                CalendarEventSummary(id: event.eventIdentifier ?? UUID().uuidString,
                                     title: event.title ?? "(untitled)",
                                     start: event.startDate,
                                     end: event.endDate,
                                     location: event.location?.isEmpty == false ? event.location : nil,
                                     attendeeCount: event.attendees?.count ?? 0,
                                     isAllDay: event.isAllDay,
                                     calendar: event.calendar?.title ?? "")
            }
    }

    func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            // The observer token is not Sendable; the box carries it into the
            // termination handler.
            let token = LockedValue<(any NSObjectProtocol)?>(nil)
            let observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: sharedEventStore, queue: nil) { _ in
                continuation.yield(())
            }
            token.withValue { $0 = observer }
            continuation.onTermination = { @Sendable _ in
                token.withValue { stored in
                    if let stored { NotificationCenter.default.removeObserver(stored) }
                    stored = nil
                }
            }
        }
    }
}
