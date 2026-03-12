// CalendarTools.swift
// Majoor — EventKit Calendar Tools
//
// 4 tools: read_calendar_events, create_calendar_event, update_calendar_event, delete_calendar_event
// Uses Apple Calendar (EventKit). No OAuth required.

import Foundation
import EventKit
import AppKit

// MARK: - Shared Event Store (must be kept alive for XPC connection)

nonisolated(unsafe) let sharedEventStore = EKEventStore()

private func ensureCalendarAccess() async throws {
    let status = EKEventStore.authorizationStatus(for: .event)
    MajoorLogger.log("📅 Calendar auth status: \(status.rawValue) (\(describeAuthStatus(status)))")

    switch status {
    case .fullAccess, .authorized:
        return
    case .notDetermined:
        MajoorLogger.log("📅 Requesting calendar access...")
        // LSUIElement apps have .accessory activation policy — TCC won't show
        // permission dialogs. Temporarily switch to .regular.
        await MainActor.run {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        let granted: Bool
        do {
            granted = try await sharedEventStore.requestFullAccessToEvents()
        } catch {
            await MainActor.run { NSApp.setActivationPolicy(.accessory) }
            throw error
        }
        await MainActor.run { NSApp.setActivationPolicy(.accessory) }
        if granted {
            MajoorLogger.log("📅 Calendar access granted!")
        } else {
            MajoorLogger.error("📅 Calendar access request returned false")
            throw CalendarError.accessDenied
        }
    case .denied, .restricted:
        MajoorLogger.error("📅 Calendar access is denied. Reset with: tccutil reset Calendar com.Majoor")
        throw CalendarError.accessDenied
    @unknown default:
        MajoorLogger.error("📅 Unknown calendar auth status: \(status.rawValue)")
        throw CalendarError.accessDenied
    }
}

private func describeAuthStatus(_ status: EKAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: return "notDetermined"
    case .restricted: return "restricted"
    case .denied: return "denied"
    case .authorized: return "authorized (legacy)"
    case .fullAccess: return "fullAccess"
    case .writeOnly: return "writeOnly"
    @unknown default: return "unknown(\(status.rawValue))"
    }
}

private enum CalendarError: LocalizedError {
    case accessDenied
    case eventNotFound
    case parseDateFailed(String)
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .accessDenied: return "Calendar access denied. Run 'tccutil reset Calendar com.Majoor' in Terminal, then relaunch Majoor to re-trigger the permission prompt. Or grant access in System Settings > Privacy & Security > Calendars."
        case .eventNotFound: return "Calendar event not found."
        case .parseDateFailed(let s): return "Could not parse date: \(s). Use ISO8601 format (e.g., 2026-03-15T14:00:00)."
        case .saveFailed(let s): return "Failed to save calendar event: \(s)"
        }
    }
}

private func parseDate(_ string: String) throws -> Date {
    // Try ISO8601 first
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = iso.date(from: string) { return date }

    // Try without fractional seconds
    iso.formatOptions = [.withInternetDateTime]
    if let date = iso.date(from: string) { return date }

    // Try common formats
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
        formatter.dateFormat = fmt
        if let date = formatter.date(from: string) { return date }
    }

    throw CalendarError.parseDateFailed(string)
}

private func formatEvent(_ event: EKEvent) -> String {
    let df = DateFormatter()
    df.dateStyle = .medium
    df.timeStyle = .short
    var lines = [
        "Title: \(event.title ?? "Untitled")",
        "Start: \(df.string(from: event.startDate))",
        "End: \(df.string(from: event.endDate))",
        "Calendar: \(event.calendar.title)",
        "Event ID: \(event.eventIdentifier ?? "unknown")",
    ]
    if let location = event.location, !location.isEmpty {
        lines.append("Location: \(location)")
    }
    if let notes = event.notes, !notes.isEmpty {
        lines.append("Notes: \(notes)")
    }
    if event.isAllDay {
        lines.append("All Day: yes")
    }
    return lines.joined(separator: "\n")
}

// MARK: - Read Calendar Events

nonisolated struct ReadCalendarEventsTool: AgentTool, Sendable {
    let name = "read_calendar_events"
    let description = "Read calendar events from Apple Calendar within a date range. Defaults to today if no dates provided."
    let parameters: [ToolParameter] = [
        ToolParameter(name: "start_date", description: "Start date in ISO8601 format (e.g., 2026-03-15). Defaults to today."),
        ToolParameter(name: "end_date", description: "End date in ISO8601 format. Defaults to end of start_date."),
    ]
    let requiredParameters: [String] = []
    let requiresConfirmation = false

    func execute(arguments: [String: String]) async throws -> ToolResult {
        try await ensureCalendarAccess()

        let now = Date()
        let calendar = Calendar.current

        let startDate: Date
        if let s = arguments["start_date"], !s.isEmpty {
            startDate = try parseDate(s)
        } else {
            startDate = calendar.startOfDay(for: now)
        }

        let endDate: Date
        if let e = arguments["end_date"], !e.isEmpty {
            endDate = try parseDate(e)
        } else {
            // Default to end of the start day
            endDate = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: startDate))!
        }

        let predicate = sharedEventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)
        let events = sharedEventStore.events(matching: predicate)

        if events.isEmpty {
            let df = DateFormatter()
            df.dateStyle = .medium
            return ToolResult(success: true, output: "No events found between \(df.string(from: startDate)) and \(df.string(from: endDate)).")
        }

        let formatted = events.map { formatEvent($0) }.joined(separator: "\n---\n")
        return ToolResult(success: true, output: "Found \(events.count) event(s):\n\n\(formatted)")
    }
}

// MARK: - Create Calendar Event

nonisolated struct CreateCalendarEventTool: AgentTool, Sendable {
    let name = "create_calendar_event"
    let description = "Create a new calendar event in Apple Calendar."
    let parameters: [ToolParameter] = [
        ToolParameter(name: "title", description: "Event title"),
        ToolParameter(name: "start_date", description: "Start date/time in ISO8601 format (e.g., 2026-03-15T14:00:00)"),
        ToolParameter(name: "end_date", description: "End date/time in ISO8601 format. If omitted, defaults to 1 hour after start."),
        ToolParameter(name: "notes", description: "Optional notes/description for the event"),
        ToolParameter(name: "location", description: "Optional location"),
        ToolParameter(name: "calendar_name", description: "Calendar name to add to. Uses default calendar if omitted."),
    ]
    let requiredParameters = ["title", "start_date"]
    let requiresConfirmation = false

    func execute(arguments: [String: String]) async throws -> ToolResult {
        try await ensureCalendarAccess()

        guard let title = arguments["title"] else {
            return ToolResult(success: false, output: "Error: 'title' is required.")
        }
        guard let startStr = arguments["start_date"] else {
            return ToolResult(success: false, output: "Error: 'start_date' is required.")
        }

        let startDate = try parseDate(startStr)
        let endDate: Date
        if let endStr = arguments["end_date"], !endStr.isEmpty {
            endDate = try parseDate(endStr)
        } else {
            endDate = Calendar.current.date(byAdding: .hour, value: 1, to: startDate)!
        }

        let event = EKEvent(eventStore: sharedEventStore)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        event.notes = arguments["notes"]
        event.location = arguments["location"]

        // Pick calendar
        if let calName = arguments["calendar_name"], !calName.isEmpty {
            let calendars = sharedEventStore.calendars(for: .event)
            if let match = calendars.first(where: { $0.title.lowercased() == calName.lowercased() }) {
                event.calendar = match
            } else {
                event.calendar = sharedEventStore.defaultCalendarForNewEvents
            }
        } else {
            event.calendar = sharedEventStore.defaultCalendarForNewEvents
        }

        do {
            try sharedEventStore.save(event, span: .thisEvent)
            return ToolResult(success: true, output: "Event created:\n\(formatEvent(event))")
        } catch {
            throw CalendarError.saveFailed(error.localizedDescription)
        }
    }
}

// MARK: - Update Calendar Event

nonisolated struct UpdateCalendarEventTool: AgentTool, Sendable {
    let name = "update_calendar_event"
    let description = "Update an existing calendar event by its event ID."
    let parameters: [ToolParameter] = [
        ToolParameter(name: "event_id", description: "The event identifier (from read_calendar_events)"),
        ToolParameter(name: "title", description: "New title (optional)"),
        ToolParameter(name: "start_date", description: "New start date in ISO8601 (optional)"),
        ToolParameter(name: "end_date", description: "New end date in ISO8601 (optional)"),
        ToolParameter(name: "notes", description: "New notes (optional)"),
        ToolParameter(name: "location", description: "New location (optional)"),
    ]
    let requiredParameters = ["event_id"]
    let requiresConfirmation = false

    func execute(arguments: [String: String]) async throws -> ToolResult {
        try await ensureCalendarAccess()

        guard let eventId = arguments["event_id"] else {
            return ToolResult(success: false, output: "Error: 'event_id' is required.")
        }

        guard let event = sharedEventStore.event(withIdentifier: eventId) else {
            throw CalendarError.eventNotFound
        }

        if let title = arguments["title"], !title.isEmpty { event.title = title }
        if let s = arguments["start_date"], !s.isEmpty { event.startDate = try parseDate(s) }
        if let e = arguments["end_date"], !e.isEmpty { event.endDate = try parseDate(e) }
        if let notes = arguments["notes"] { event.notes = notes }
        if let loc = arguments["location"] { event.location = loc }

        do {
            try sharedEventStore.save(event, span: .thisEvent)
            return ToolResult(success: true, output: "Event updated:\n\(formatEvent(event))")
        } catch {
            throw CalendarError.saveFailed(error.localizedDescription)
        }
    }
}

// MARK: - Delete Calendar Event

nonisolated struct DeleteCalendarEventTool: AgentTool, Sendable {
    let name = "delete_calendar_event"
    let description = "Delete a calendar event by its event ID. Requires user confirmation via notification."
    let parameters: [ToolParameter] = [
        ToolParameter(name: "event_id", description: "The event identifier (from read_calendar_events)"),
    ]
    let requiredParameters = ["event_id"]
    let requiresConfirmation = true

    func execute(arguments: [String: String]) async throws -> ToolResult {
        try await ensureCalendarAccess()

        guard let eventId = arguments["event_id"] else {
            return ToolResult(success: false, output: "Error: 'event_id' is required.")
        }

        guard let event = sharedEventStore.event(withIdentifier: eventId) else {
            throw CalendarError.eventNotFound
        }

        let title = event.title ?? "Untitled"
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short

        // Request user confirmation
        let approved = await ConfirmationManager.shared.requestConfirmation(
            title: "Delete Calendar Event?",
            body: "\(title)\n\(df.string(from: event.startDate)) – \(df.string(from: event.endDate))",
            category: NotificationManager.confirmDeleteCategory
        )

        guard approved else {
            return ToolResult(success: false, output: "User declined to delete event '\(title)'.")
        }

        do {
            try sharedEventStore.remove(event, span: .thisEvent)
            return ToolResult(success: true, output: "Deleted event: \(title)")
        } catch {
            return ToolResult(success: false, output: "Failed to delete event: \(error.localizedDescription)")
        }
    }
}
