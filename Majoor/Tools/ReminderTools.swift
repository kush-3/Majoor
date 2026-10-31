// ReminderTools.swift
// Majoor — One-shot reminders
//
// The model turns "remind me in 20 minutes to check the oven" into a
// create_reminder call; the scheduler delivers the text back on the
// channel the request came from. Computation is done here, not by the
// model: delay_minutes is added to now, `when` is parsed as local time.

import Foundation

nonisolated enum ReminderTime {
    static let maxDelayMinutes = 60 * 24 * 365

    /// Exactly one of `delayMinutes` / `when` must be given. Returns the run
    /// time or a user-facing error.
    static func resolve(delayMinutes: String?, when: String?, now: Date, timeZone: TimeZone = .current) -> Result<Date, ReminderError> {
        let delay = delayMinutes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let whenText = when?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch (delay.isEmpty, whenText.isEmpty) {
        case (true, true): return .failure(.missingTime)
        case (false, false): return .failure(.bothTimes)
        case (false, true):
            guard let minutes = Int(delay) ?? Double(delay).map({ Int($0.rounded()) }) else { return .failure(.badDelay(delay)) }
            guard minutes > 0 else { return .failure(.nonPositiveDelay) }
            guard minutes <= maxDelayMinutes else { return .failure(.badDelay(delay)) }
            return .success(now.addingTimeInterval(TimeInterval(minutes) * 60))
        case (true, false):
            guard let date = parseLocal(whenText, timeZone: timeZone) else { return .failure(.badWhen(whenText)) }
            guard date > now else { return .failure(.inThePast(whenText)) }
            return .success(date)
        }
    }

    /// Same format list CalendarTools accepts, interpreted in the given zone
    /// unless the string carries its own offset.
    static func parseLocal(_ string: String, timeZone: TimeZone) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: string) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: string) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }

    static func describe(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

nonisolated enum ReminderError: Error, Equatable, Sendable {
    case missingTime, bothTimes, nonPositiveDelay
    case badDelay(String), badWhen(String), inThePast(String)

    var message: String {
        switch self {
        case .missingTime: return "Error: give either 'delay_minutes' (e.g. \"20\") or 'when' (local time, yyyy-MM-dd'T'HH:mm)"
        case .bothTimes: return "Error: give only one of 'delay_minutes' and 'when'"
        case .nonPositiveDelay: return "Error: 'delay_minutes' must be a positive number"
        case .badDelay(let text): return "Error: 'delay_minutes' must be a whole number of minutes up to one year, got \"\(text)\""
        case .badWhen(let text): return "Error: could not parse 'when' \"\(text)\"; use yyyy-MM-dd'T'HH:mm in the user's local time"
        case .inThePast(let text): return "Error: 'when' \"\(text)\" is in the past; compute the next occurrence or use delay_minutes"
        }
    }
}

// MARK: - Create

nonisolated struct CreateReminderTool: AgentTool {
    let name = "create_reminder"
    let description = "Set a one-time reminder. Majoor delivers the message back to the user at that time on the channel they are using (panel, laptop, or iMessage). Give exactly one of 'delay_minutes' (relative, preferred for \"in 20 minutes\", \"in 2 hours\") or 'when' (an absolute local time). Use this for \"remind me\" requests instead of creating calendar events."
    let parameters = [
        ToolParameter(name: "message", description: "What to remind the user about, as they would want to read it (e.g. \"Check the oven\")"),
        ToolParameter(name: "delay_minutes", description: "Minutes from now, as a whole number (e.g. \"20\", \"120\" for two hours)"),
        ToolParameter(name: "when", description: "Absolute local time, yyyy-MM-dd'T'HH:mm (e.g. \"2026-11-02T17:00\"). The current date, time and time zone are in the system prompt."),
    ]
    let requiredParameters = ["message"]
    let requiresConfirmation = false

    private let store: AutomationStore
    private let scheduler: AutomationScheduler?
    private let now: @Sendable () -> Date

    init(store: AutomationStore = .shared, scheduler: AutomationScheduler? = .shared, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.scheduler = scheduler
        self.now = now
    }

    func execute(arguments: [String: String]) async throws -> ToolResult {
        guard let message = arguments["message"]?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty else {
            return ToolResult(success: false, output: "Error: 'message' is required")
        }
        let current = now()
        let runAt: Date
        switch ReminderTime.resolve(delayMinutes: arguments["delay_minutes"], when: arguments["when"], now: current) {
        case .success(let date): runAt = date
        case .failure(let error): return ToolResult(success: false, output: error.message)
        }
        // Deliver back to where the request came from. Without a session
        // (a direct tool test) the panel is the owner's primary channel.
        let context = SessionContext.current
        let record = AutomationRecord.reminder(message: message, runAt: runAt, origin: context?.origin ?? .panel,
                                               createdBySession: context?.sessionId, now: current)
        do {
            try store.insert(record)
        } catch {
            return ToolResult(success: false, output: "Error saving reminder: \(error.localizedDescription)")
        }
        await scheduler?.wake()
        return ToolResult(success: true, output: "Reminder \(record.id) set for \(ReminderTime.describe(runAt)): \(message)")
    }
}

// MARK: - List

nonisolated struct ListRemindersTool: AgentTool {
    let name = "list_reminders"
    let description = "List the user's upcoming reminders with their ids and delivery times."
    let parameters: [ToolParameter] = []
    let requiredParameters: [String] = []
    let requiresConfirmation = false
    let isReadOnly = true

    private let store: AutomationStore

    init(store: AutomationStore = .shared) {
        self.store = store
    }

    func execute(arguments: [String: String]) async throws -> ToolResult {
        let upcoming = store.listUpcoming()
        guard !upcoming.isEmpty else { return ToolResult(success: true, output: "No upcoming reminders.") }
        let lines = upcoming.map { record in
            "\(record.id) — \(record.nextRunAt.map { ReminderTime.describe($0) } ?? "unscheduled"): \(record.prompt)"
        }
        return ToolResult(success: true, output: lines.joined(separator: "\n"))
    }
}

// MARK: - Cancel

nonisolated struct CancelReminderTool: AgentTool {
    let name = "cancel_reminder"
    let description = "Cancel an upcoming reminder by id (from list_reminders), or every upcoming reminder whose text contains 'matching'."
    let parameters = [
        ToolParameter(name: "id", description: "The reminder id to cancel"),
        ToolParameter(name: "matching", description: "Case-insensitive text; cancels every upcoming reminder containing it"),
    ]
    let requiredParameters: [String] = []
    let requiresConfirmation = false

    private let store: AutomationStore
    private let scheduler: AutomationScheduler?

    init(store: AutomationStore = .shared, scheduler: AutomationScheduler? = .shared) {
        self.store = store
        self.scheduler = scheduler
    }

    func execute(arguments: [String: String]) async throws -> ToolResult {
        let id = arguments["id"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let matching = arguments["matching"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !id.isEmpty || !matching.isEmpty else {
            return ToolResult(success: false, output: "Error: give 'id' or 'matching'")
        }
        var cancelled: [AutomationRecord] = []
        if !id.isEmpty {
            if let record = store.record(id: id), store.cancel(id: id) { cancelled.append(record) }
        } else {
            for record in store.listUpcoming() where record.prompt.lowercased().contains(matching) {
                if store.cancel(id: record.id) { cancelled.append(record) }
            }
        }
        await scheduler?.wake()
        guard !cancelled.isEmpty else {
            return ToolResult(success: false, output: id.isEmpty ? "No upcoming reminder contains \"\(matching)\"" : "No upcoming reminder with id \(id)")
        }
        return ToolResult(success: true, output: "Cancelled \(cancelled.count) reminder(s): " + cancelled.map(\.prompt).joined(separator: "; "))
    }
}
