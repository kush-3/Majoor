// LocationJob.swift
// Majoor — PRD §8 behavior 6f: "where you should be" (Phase 2 step 6)
//
// Every five minutes: for each calendar event with a location that starts
// within the next 30 minutes, compare the travel time from the owner's last
// known position with the time left and say so when they will not make it.
// The decision is arithmetic, so the job is model-free, and the coordinates
// never reach any model; the message carries the ETA only. Location rows
// stay on tier L (PRD §6). Requesting a fresh fix depends on decision D10
// and returns nil today, so the job degrades to the latest stored fix.

import Foundation
import CoreLocation
import MapKit

nonisolated enum TravelMode: String, Codable, Sendable, CaseIterable {
    case automobile
    case walking

    var displayName: String {
        switch self {
        case .automobile: return "Driving"
        case .walking: return "Walking"
        }
    }
}

/// The calendar and the location source, as far as the job is concerned.
nonisolated protocol LocationPlanning: Sendable {
    func upcomingEvents(within interval: TimeInterval) async throws -> [CalendarEventSummary]
    func latestFix() async -> LocationFixRecord?
    /// A fresh fix from the phone, or nil when none can be had (D10).
    func requestFix() async -> LocationFixRecord?
}

nonisolated enum RouteEstimationError: Error, Sendable, Equatable {
    case destinationNotFound(String)
    case noRoute
}

/// Travel time from a position to a place name. Production uses MapKit.
nonisolated protocol RouteEstimating: Sendable {
    func travelTime(fromLatitude latitude: Double, longitude: Double, to destination: String, mode: TravelMode) async throws -> TimeInterval
}

/// The hub's calendar and location sources; the fix store when no location
/// source is registered (local mode).
nonisolated struct LiveLocationPlanner: LocationPlanning {
    func upcomingEvents(within interval: TimeInterval) async throws -> [CalendarEventSummary] {
        guard let source = await EventHub.shared.source(id: CalendarSource.sourceId) as? CalendarSource else { return [] }
        return try await source.upcoming(within: interval)
    }

    func latestFix() async -> LocationFixRecord? {
        if let source = await EventHub.shared.source(id: LocationSource.sourceId) as? LocationSource {
            return await source.latestFix()
        }
        return LocationFixStore.shared.latest()
    }

    func requestFix() async -> LocationFixRecord? {
        guard let source = await EventHub.shared.source(id: LocationSource.sourceId) as? LocationSource else { return nil }
        return await source.requestFix()
    }
}

/// `CLGeocoder` for the place, `MKDirections.calculateETA` for the time.
/// MapKit is driven on the main actor; the job awaits from wherever it runs.
nonisolated final class MapKitRouteEstimator: RouteEstimating {
    nonisolated init() {}

    @MainActor
    func travelTime(fromLatitude latitude: Double, longitude: Double, to destination: String, mode: TravelMode) async throws -> TimeInterval {
        let placemarks = try await CLGeocoder().geocodeAddressString(destination)
        guard let placemark = placemarks.first, let location = placemark.location else {
            throw RouteEstimationError.destinationNotFound(destination)
        }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: location.coordinate))
        request.transportType = mode == .walking ? .walking : .automobile
        let response = try await MKDirections(request: request).calculateETA()
        guard response.expectedTravelTime > 0 else { throw RouteEstimationError.noRoute }
        return response.expectedTravelTime
    }
}

/// The owner's choices, in UserDefaults; tests pass their own suite.
nonisolated struct LocationJobSettings: Sendable {
    static let travelModeKey = "locationTravelMode"
    static let importantMarkerKey = "importantEventMarker"
    /// Open question 7: a keyword in the title marks an event important. "!"
    /// until the owner picks a marker, a calendar or an attendee rule.
    static let defaultMarker = "!"

    let travelMode: TravelMode
    let importantMarker: String

    init(travelMode: TravelMode, importantMarker: String) {
        self.travelMode = travelMode
        self.importantMarker = importantMarker
    }

    init(defaults: UserDefaults) {
        travelMode = defaults.string(forKey: Self.travelModeKey).flatMap(TravelMode.init(rawValue:)) ?? .automobile
        let marker = defaults.string(forKey: Self.importantMarkerKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        importantMarker = marker.isEmpty ? Self.defaultMarker : marker
    }
}

/// Events already warned about today, so a late event is mentioned once.
nonisolated struct LocationJobState: Codable, Sendable, Equatable {
    var warned: [String: Date]

    init(warned: [String: Date] = [:]) {
        self.warned = warned
    }
}

nonisolated enum LocationJob {

    static let lookahead: TimeInterval = 30 * 60
    static let fixMaxAge: TimeInterval = 10 * 60
    static let staleFixMaxAge: TimeInterval = 60 * 60
    static let warnedRetention: TimeInterval = 24 * 3600
    static let staleSummary = "no fresh location; location is stale"

    static let definitions: [JobDefinition] = [
        definition(planner: LiveLocationPlanner(), estimator: MapKitRouteEstimator(), settings: { LocationJobSettings(defaults: .standard) }),
    ]

    /// The job over any planner and estimator; `definitions` uses the live ones.
    static func definition(planner: any LocationPlanning, estimator: any RouteEstimating,
                           settings: @escaping @Sendable () -> LocationJobSettings) -> JobDefinition {
        JobDefinition(
            name: JobNames.location,
            title: "Where you should be",
            summary: "Every five minutes: warns when the travel time to an upcoming event with a location is longer than the time left.",
            tier: .local,
            inputs: [],
            instructions: "Model-free.",
            urgencyCeiling: 3,
            riskCeiling: "R0",
            delivery: .ladder,
            defaultCron: "*/5 * * * *",
            modelFree: true,
            apply: { _, _, context in
                await check(context: context, planner: planner, estimator: estimator, settings: settings())
            })
    }

    static func check(context: JobContext, planner: any LocationPlanning, estimator: any RouteEstimating,
                      settings: LocationJobSettings) async -> JobOutcome {
        let now = context.now
        var state = context.scratch(as: LocationJobState.self) ?? LocationJobState()
        state.warned = state.warned.filter { now.timeIntervalSince($0.value) < warnedRetention }
        defer { try? context.saveScratch(state) }

        let events: [CalendarEventSummary]
        do {
            events = try await planner.upcomingEvents(within: lookahead)
        } catch {
            return .noChange(summary: "calendar unavailable: \(error.localizedDescription)")
        }
        let candidates = events
            .filter { !$0.isAllDay && $0.start > now && $0.start.timeIntervalSince(now) <= lookahead }
            .filter { !($0.location ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
            .filter { state.warned[$0.id] == nil }
            .sorted { $0.start < $1.start }
        guard !candidates.isEmpty else {
            return .noChange(summary: "no located event in the next \(Int(lookahead / 60)) min")
        }

        // A fix under ten minutes old, else ask the phone, else the latest
        // stored one if it is under an hour old.
        var fix = await planner.latestFix()
        let needsFresh = fix.map { now.timeIntervalSince($0.at) > fixMaxAge } ?? true
        if needsFresh, let fresh = await planner.requestFix() { fix = fresh }
        guard let fix, now.timeIntervalSince(fix.at) <= staleFixMaxAge else {
            return .noChange(summary: staleSummary)
        }

        var unroutable = 0
        for event in candidates {
            let destination = (event.location ?? "").trimmingCharacters(in: .whitespaces)
            let eta: TimeInterval
            do {
                eta = try await estimator.travelTime(fromLatitude: fix.latitude, longitude: fix.longitude, to: destination, mode: settings.travelMode)
            } catch {
                MajoorLogger.log("📍 No route for \"\(event.title)\" at \(destination): \(error)")
                unroutable += 1
                continue
            }
            let timeLeft = event.start.timeIntervalSince(now)
            guard eta > timeLeft else { continue }
            state.warned[event.id] = now
            let important = !settings.importantMarker.isEmpty && event.title.contains(settings.importantMarker)
            let text = message(event: event, destination: destination, eta: eta, timeLeft: timeLeft, timeZone: context.timeZone)
            MajoorLogger.log("📍 \(text)")
            return .notify(urgency: important ? 3 : 2, text: text)
        }
        if unroutable > 0 {
            return .noChange(summary: "no route for \(unroutable) of \(candidates.count) located event(s); on time for the rest")
        }
        return .noChange(summary: "on time for \(candidates.count) located event(s)")
    }

    /// "You won't make your 3pm at Blue Bottle (ETA 22 min, starts in 15)".
    static func message(event: CalendarEventSummary, destination: String, eta: TimeInterval, timeLeft: TimeInterval, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let minute = calendar.component(.minute, from: event.start)
        formatter.dateFormat = minute == 0 ? "ha" : "h:mma"
        let when = formatter.string(from: event.start).lowercased()
        let etaMinutes = Int((eta / 60).rounded(.up))
        let leftMinutes = max(0, Int((timeLeft / 60).rounded(.down)))
        return "You won't make your \(when) at \(destination) (ETA \(etaMinutes) min, starts in \(leftMinutes))"
    }
}
