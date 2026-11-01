// ActiveHours.swift
// Majoor — When proactive messages may reach the owner (PRD §5.3, D-quiet)
//
// `"08:00-23:00"` in the owner's time zone. Governs *delivery* of urgency 1
// and 2 messages; jobs still run at night and record their results, and
// urgency 3 ignores the window. An overnight window (`"22:00-06:00"`) wraps
// midnight; equal bounds mean always open. Reminders are exempt (Phase 1).

import Foundation

nonisolated struct ActiveHours: Sendable, Equatable {

    /// Minutes after midnight.
    let startMinute: Int
    let endMinute: Int

    static let defaultText = "08:00-23:00"
    static let standard = ActiveHours(startMinute: 8 * 60, endMinute: 23 * 60)

    private static let pattern = try! NSRegularExpression(pattern: #"^\s*(\d{1,2}):(\d{2})\s*[-–]\s*(\d{1,2}):(\d{2})\s*$"#)

    /// `"HH:MM-HH:MM"`; `24:00` is accepted as an end. Nil for anything else.
    static func parse(_ text: String) -> ActiveHours? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern.firstMatch(in: text, range: range) else { return nil }
        func group(_ index: Int) -> Int? {
            Range(match.range(at: index), in: text).flatMap { Int(text[$0]) }
        }
        guard let startHour = group(1), let startMin = group(2), let endHour = group(3), let endMin = group(4),
              (0...23).contains(startHour), (0...59).contains(startMin), (0...24).contains(endHour), (0...59).contains(endMin),
              endHour < 24 || endMin == 0 else { return nil }
        let start = startHour * 60 + startMin
        var end = endHour * 60 + endMin
        if end == 24 * 60, start == 0 { end = 0 }   // 00:00-24:00 is "always"; 08:00-24:00 ends at midnight
        return ActiveHours(startMinute: start, endMinute: end)
    }

    var text: String {
        let end = endMinute == 24 * 60 ? "24:00" : String(format: "%02d:%02d", endMinute / 60, endMinute % 60)
        return String(format: "%02d:%02d-", startMinute / 60, startMinute % 60) + end
    }

    var isAlwaysOpen: Bool { startMinute == endMinute }
    var wrapsMidnight: Bool { endMinute < startMinute }

    private func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private func minuteOfDay(_ date: Date, _ calendar: Calendar) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    func contains(_ date: Date, in timeZone: TimeZone) -> Bool {
        if isAlwaysOpen { return true }
        let minute = minuteOfDay(date, calendar(timeZone))
        if wrapsMidnight { return minute >= startMinute || minute < endMinute }
        return minute >= startMinute && minute < endMinute
    }

    /// `date` itself when inside the window; otherwise the next moment the
    /// window opens (today's start if still ahead, else tomorrow's).
    func nextOpening(after date: Date, in timeZone: TimeZone) -> Date {
        if contains(date, in: timeZone) { return date }
        let calendar = calendar(timeZone)
        let todayStart = calendar.date(bySettingHour: startMinute / 60, minute: startMinute % 60, second: 0, of: date) ?? date
        if todayStart > date { return todayStart }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) ?? date
        return calendar.date(bySettingHour: startMinute / 60, minute: startMinute % 60, second: 0, of: tomorrow) ?? tomorrow
    }
}

/// The owner's default window, in UserDefaults. A row's own `activeHours`
/// column overrides it; an unparseable value falls back to the standard one.
nonisolated final class ActiveHoursStore: @unchecked Sendable {

    static let shared = ActiveHoursStore(defaults: .standard)
    static let defaultsKey = "activeHoursDefault"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var text: String {
        get { defaults.string(forKey: Self.defaultsKey) ?? ActiveHours.defaultText }
        set { defaults.set(newValue, forKey: Self.defaultsKey) }
    }

    var hours: ActiveHours {
        ActiveHours.parse(text) ?? .standard
    }

    /// The window for one automation row: its own column when set and valid,
    /// else the default.
    func hours(for record: AutomationRecord) -> ActiveHours {
        record.activeHours.flatMap(ActiveHours.parse) ?? hours
    }
}
