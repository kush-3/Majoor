// TriageJob.swift
// Majoor — PRD §8 behavior 6a: inbox and Slack urgency triage (Phase 2 step 6)
//
// Every 30 minutes, tier L reads the new email headers and Slack messages
// the hub collected and rates each 0–3. Only urgency 2 and 3 reach the
// owner, as one message through the escalation ladder; urgency 1 is held in
// this job's scratch for the morning brief; 0 is dropped. Bodies are never
// read here (VIP threads are the nudge's business, 6c).

import Foundation

nonisolated enum TriageJob {

    static let holdWindow: TimeInterval = 48 * 60 * 60
    static let maxHeld = 50
    static let maxLinesInMessage = 5

    static let definitions: [JobDefinition] = [definition]

    static let definition = JobDefinition(
        name: JobNames.triage,
        title: "Inbox and Slack triage",
        summary: "Every 30 minutes, rates new email headers and Slack messages 0–3. Urgent ones (2–3) are sent to you; the rest wait for the brief.",
        tier: .local,
        inputs: [.gmailMeta, .slack],
        instructions: """
        You triage a busy person's new email headers and Slack messages. For every item in the events, \
        rate how urgently they must see it: 0 = ignore, newsletter or automated noise; 1 = can wait for the \
        daily brief; 2 = today; 3 = interrupt them now (an outage, a family emergency, a hard deadline in \
        hours). Judge from the sender, subject, channel and text only; you never see email bodies. \
        Copy each item's id exactly: the "messageId" of an email, the "ts" of a Slack message. \
        Set "outcome" to "notify" when any item is 2 or 3, with "text" summarizing those items, and to \
        "no_change" otherwise; the app composes the final message from "items", so keep "text" short.
        """,
        outputSchema: """
        "items": [{"id": "<messageId or ts>", "source": "gmail" | "slack", "from": "<sender or author>", \
        "subject": "<subject, or the first words of a Slack message>", "urgency": 0 | 1 | 2 | 3, \
        "reason": "<ten words or fewer>"}]  (one entry per event; an empty array when there were no events)
        """,
        urgencyCeiling: 3,
        riskCeiling: "R0",
        delivery: .ladder,
        defaultCron: "*/30 * * * *",
        apply: { object, mapped, context in
            try await apply(object, mapped: mapped, context: context)
        })

    /// One rated item as the model returned it.
    nonisolated struct Item: Sendable, Equatable {
        let id: String
        let source: String
        let from: String
        let subject: String
        let urgency: Int
        let reason: String
    }

    /// `items` from the answer; nil when the key is absent (the model followed
    /// only the base contract), empty when it was an empty array.
    static func items(from object: JSONValue) -> [Item]? {
        guard let array = object["items"]?.arrayValue else { return nil }
        return array.compactMap { entry in
            let subject = clean(entry["subject"]?.stringValue ?? "", limit: 120)
            let from = clean(entry["from"]?.stringValue ?? "", limit: 80)
            var id = clean(entry["id"]?.stringValue ?? "", limit: 120)
            if id.isEmpty { id = "\(from)|\(subject)".lowercased() }
            guard !id.isEmpty else { return nil }
            let source = (entry["source"]?.stringValue?.lowercased() == "slack") ? "slack" : "gmail"
            let urgency = max(0, min(3, entry["urgency"]?.intValue ?? 1))
            return Item(id: id, source: source, from: from.isEmpty ? "unknown" : from,
                        subject: subject.isEmpty ? "(no subject)" : subject, urgency: urgency,
                        reason: clean(entry["reason"]?.stringValue ?? "", limit: 120))
        }
    }

    static func apply(_ object: JSONValue, mapped: JobOutcome, context: JobContext) async throws -> JobOutcome {
        guard let items = items(from: object) else { return mapped }
        let now = context.now

        let urgent = items.filter { $0.urgency >= 2 }.sorted { $0.urgency > $1.urgency }
        let newlyHeld = items.filter { $0.urgency == 1 }

        // Held items: what was waiting, minus anything older than the window,
        // plus this run's; the newest judgment wins but the first-seen time stays.
        let previous = context.scratch(as: TriageState.self)?.held ?? []
        var merged: [String: TriageHeldItem] = [:]
        for item in previous where now.timeIntervalSince(item.at) <= holdWindow { merged[item.id] = item }
        for item in newlyHeld {
            merged[item.id] = TriageHeldItem(id: item.id, source: item.source, from: item.from, subject: item.subject,
                                             urgency: item.urgency, reason: item.reason, at: merged[item.id]?.at ?? now)
        }
        // An item that is urgent now is no longer "held".
        for item in urgent { merged.removeValue(forKey: item.id) }
        let held = Array(merged.values.sorted { $0.at > $1.at }.prefix(maxHeld))
        try context.saveScratch(TriageState(held: held, updatedAt: now))

        let summary = "\(urgent.count) urgent, \(held.count) held (\(newlyHeld.count) new), \(items.count) rated"
        guard !urgent.isEmpty else { return .noChange(summary: summary) }
        return .notify(urgency: urgent[0].urgency, text: message(urgent))
    }

    /// The owner's message: one line per urgent item, at most five.
    static func message(_ urgent: [Item]) -> String {
        let head = urgent.count == 1 ? "1 item needs you" : "\(urgent.count) items need you"
        var lines = [head + (urgent.contains { $0.urgency == 3 } ? " now:" : " today:")]
        for item in urgent.prefix(maxLinesInMessage) {
            var line = "• [\(item.source)] \(item.from) — \(item.subject)"
            if !item.reason.isEmpty { line += ": \(item.reason)" }
            lines.append(line)
        }
        if urgent.count > maxLinesInMessage { lines.append("(+\(urgent.count - maxLinesInMessage) more)") }
        return lines.joined(separator: "\n")
    }

    private static func clean(_ text: String, limit: Int) -> String {
        let stripped = UntrustedContent.stripControlCharacters(text)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(stripped.prefix(limit))
    }
}
