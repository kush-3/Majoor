// CronSchedule.swift
// Majoor — Five-field cron expressions for scheduled jobs (Phase 2 step 5a)
//
// `min hour dom mon dow`, Vixie semantics: `*`, lists, ranges, steps, month
// and weekday names, `0` and `7` both Sunday, and when both the day-of-month
// and the day-of-week fields are restricted a day matches if either does.
// `@hourly`, `@daily`, `@weekly`, `@monthly` and `@yearly` are accepted.
// `next(after:in:)` walks days, not minutes, so an impossible date such as
// `0 0 31 2 *` gives up after five years in a few thousand steps.

import Foundation

nonisolated struct CronSchedule: Sendable, Equatable {

    let expression: String
    let minutes: Set<Int>
    let hours: Set<Int>
    let daysOfMonth: Set<Int>
    let months: Set<Int>
    /// 0 = Sunday … 6 = Saturday.
    let weekdays: Set<Int>
    /// Whether the field was something other than `*`; decides the dom/dow OR rule.
    let dayOfMonthRestricted: Bool
    let weekdayRestricted: Bool

    /// Bound on the day walk in `next(after:in:)`: five years covers every
    /// leap-day schedule.
    static let maxDaysAhead = 366 * 5

    static let aliases: [String: String] = [
        "@hourly": "0 * * * *",
        "@daily": "0 0 * * *",
        "@midnight": "0 0 * * *",
        "@weekly": "0 0 * * 0",
        "@monthly": "0 0 1 * *",
        "@yearly": "0 0 1 1 *",
        "@annually": "0 0 1 1 *",
    ]

    private static let monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let weekdayNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
    private static let fullNames = ["january", "february", "march", "april", "may", "june", "july", "august", "september",
                                    "october", "november", "december",
                                    "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    // MARK: Parsing

    static func parse(_ text: String) -> CronSchedule? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = aliases[trimmed.lowercased()] ?? trimmed
        let fields = source.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard fields.count == 5,
              let minutes = parseField(fields[0], min: 0, max: 59, names: nil),
              let hours = parseField(fields[1], min: 0, max: 23, names: nil),
              let dom = parseField(fields[2], min: 1, max: 31, names: nil),
              let months = parseField(fields[3], min: 1, max: 12, names: monthNames),
              let rawWeekdays = parseField(fields[4], min: 0, max: 7, names: weekdayNames)
        else { return nil }
        let weekdays = Set(rawWeekdays.map { $0 == 7 ? 0 : $0 })
        return CronSchedule(expression: fields.joined(separator: " "), minutes: minutes, hours: hours, daysOfMonth: dom,
                            months: months, weekdays: weekdays,
                            dayOfMonthRestricted: fields[2] != "*", weekdayRestricted: fields[4] != "*")
    }

    /// One field: comma-separated parts, each `*`, `*/s`, `a`, `a-b`, `a-b/s` or `a/s`.
    private static func parseField(_ field: String, min: Int, max: Int, names: [String]?) -> Set<Int>? {
        var values = Set<Int>()
        for rawPart in field.split(separator: ",", omittingEmptySubsequences: false) {
            let part = String(rawPart).lowercased()
            guard !part.isEmpty else { return nil }
            let slash = part.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard slash.count <= 2 else { return nil }
            var step = 1
            if slash.count == 2 {
                guard let parsed = Int(slash[1]), parsed >= 1 else { return nil }
                step = parsed
            }
            let rangeText = slash[0]
            let lower: Int
            let upper: Int
            if rangeText == "*" {
                lower = min
                upper = max
            } else {
                let bounds = rangeText.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
                guard bounds.count <= 2, let first = value(bounds[0], names: names, offset: min) else { return nil }
                lower = first
                if bounds.count == 2 {
                    guard let second = value(bounds[1], names: names, offset: min) else { return nil }
                    upper = second
                } else {
                    upper = slash.count == 2 ? max : first   // `a/s` means a, a+s, … up to max
                }
            }
            guard lower >= min, upper <= max, lower <= upper else { return nil }
            var v = lower
            while v <= upper {
                values.insert(v)
                v += step
            }
        }
        return values.isEmpty ? nil : values
    }

    /// A number, a three-letter name, or a full name. Names are only valid in
    /// the month and weekday fields.
    private static func value(_ text: String, names: [String]?, offset: Int) -> Int? {
        if let number = Int(text) { return number }
        guard let names, !text.isEmpty else { return nil }
        let key: String
        if text.count == 3 {
            key = text
        } else if fullNames.contains(text) {
            key = String(text.prefix(3))
        } else {
            return nil
        }
        guard let index = names.firstIndex(of: key) else { return nil }
        return index + offset
    }

    // MARK: Evaluation

    private func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private func dayMatches(month: Int, day: Int, weekday: Int) -> Bool {
        guard months.contains(month) else { return false }
        let domOK = daysOfMonth.contains(day)
        let dowOK = weekdays.contains(weekday)
        switch (dayOfMonthRestricted, weekdayRestricted) {
        case (true, true): return domOK || dowOK
        case (true, false): return domOK
        case (false, true): return dowOK
        case (false, false): return true
        }
    }

    /// Whether the minute containing `date` is a scheduled one.
    func matches(_ date: Date, in timeZone: TimeZone) -> Bool {
        let calendar = calendar(timeZone)
        let c = calendar.dateComponents([.month, .day, .weekday, .hour, .minute], from: date)
        guard let month = c.month, let day = c.day, let weekday = c.weekday, let hour = c.hour, let minute = c.minute else { return false }
        return dayMatches(month: month, day: day, weekday: weekday - 1) && hours.contains(hour) && minutes.contains(minute)
    }

    /// The first scheduled minute strictly after `date`, or nil when none
    /// exists within five years. A local time that does not exist on a DST
    /// day (02:00 when clocks jump to 03:00) resolves to the moment the clocks
    /// land on; a local time that exists twice fires on its first pass.
    func next(after date: Date, in timeZone: TimeZone) -> Date? {
        let calendar = calendar(timeZone)
        let sortedHours = hours.sorted()
        let sortedMinutes = minutes.sorted()
        // Start at the next whole minute.
        let startComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard let floor = calendar.date(from: startComponents),
              let start = calendar.date(byAdding: .minute, value: 1, to: floor) else { return nil }
        var day = calendar.startOfDay(for: start)
        var first = true
        for _ in 0...Self.maxDaysAhead {
            let c = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
            guard let year = c.year, let month = c.month, let dayOfMonth = c.day, let weekday = c.weekday else { return nil }
            if dayMatches(month: month, day: dayOfMonth, weekday: weekday - 1) {
                let fromHour = first ? calendar.component(.hour, from: start) : 0
                let fromMinute = first ? calendar.component(.minute, from: start) : 0
                for hour in sortedHours where hour >= fromHour {
                    for minute in sortedMinutes where hour > fromHour || minute >= fromMinute {
                        var target = DateComponents()
                        target.year = year
                        target.month = month
                        target.day = dayOfMonth
                        target.hour = hour
                        target.minute = minute
                        if let candidate = calendar.date(from: target), candidate > date { return candidate }
                    }
                }
            }
            first = false
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = nextDay
        }
        return nil
    }

    /// A short English description for Settings; the expression itself when
    /// no simple phrase fits.
    var summary: String {
        let everyMonth = months.count == 12
        if minutes.count == 60, hours.count == 24, !dayOfMonthRestricted, !weekdayRestricted, everyMonth { return "every minute" }
        if hours.count == 24, !dayOfMonthRestricted, !weekdayRestricted, everyMonth, minutes.count > 1 {
            let sorted = minutes.sorted()
            let step = sorted[1] - sorted[0]
            if step > 0, sorted == Array(stride(from: 0, through: 59, by: step)) { return "every \(step) min" }
        }
        if minutes.count == 1, hours.count == 1, everyMonth, let hour = hours.first, let minute = minutes.first {
            let time = String(format: "%02d:%02d", hour, minute)
            if !dayOfMonthRestricted, !weekdayRestricted { return "daily at \(time)" }
            if !dayOfMonthRestricted, weekdayRestricted {
                if weekdays == [1, 2, 3, 4, 5] { return "weekdays at \(time)" }
                let names = weekdays.sorted().map { Self.weekdayNames[$0].capitalized }
                return "\(names.joined(separator: ", ")) at \(time)"
            }
            if dayOfMonthRestricted, !weekdayRestricted, daysOfMonth.count == 1, let day = daysOfMonth.first {
                return "monthly on day \(day) at \(time)"
            }
        }
        return expression
    }
}
