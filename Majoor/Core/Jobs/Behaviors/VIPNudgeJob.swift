// VIPNudgeJob.swift
// Majoor — PRD §8 behavior 6c: the unreplied-email nudge with drafts (Phase 2 step 6)
//
// Every two hours: find VIP threads whose last message is theirs, older than
// the threshold, with nothing from the owner since; ask tier P for one reply
// per thread in the owner's voice; text the owner each draft with a code.
// `send K7Q2` spawns a task that calls reply_to_email (which always asks for
// approval, so the send is confirmed with the nonce over iMessage as usual),
// `edit K7Q2 <changes>` redrafts and sends the same way, `skip K7Q2` rests the
// thread for a week. Detection is code; drafting is the only model call; the
// thread body reaches the model framed as untrusted content.

import Foundation

// MARK: - Settings

/// The nudge threshold and the weekend rule (plan open question 8), in
/// UserDefaults. Tests pass their own suite.
nonisolated final class NudgeSettingsStore: @unchecked Sendable {

    static let shared = NudgeSettingsStore(defaults: .standard)
    static let thresholdKey = "nudgeThresholdHours"
    static let skipWeekendsKey = "nudgeSkipWeekends"
    static let defaultThresholdHours = 6

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Hours a VIP thread waits before it counts as unreplied.
    var thresholdHours: Int {
        get {
            let stored = defaults.integer(forKey: Self.thresholdKey)
            return stored > 0 ? stored : Self.defaultThresholdHours
        }
        set { defaults.set(max(1, newValue), forKey: Self.thresholdKey) }
    }

    /// No nudges on Saturday or Sunday (default on).
    var skipWeekends: Bool {
        get { defaults.object(forKey: Self.skipWeekendsKey) == nil ? true : defaults.bool(forKey: Self.skipWeekendsKey) }
        set { defaults.set(newValue, forKey: Self.skipWeekendsKey) }
    }
}

// MARK: - Mailbox

/// One message's headers, as the nudge needs them. `receivedAt` is Gmail's
/// `internalDate`; `isFromOwner` is the SENT label.
nonisolated struct NudgeMessage: Sendable, Equatable {
    let id: String
    let threadId: String
    /// The From header as written: "Alice Example <alice@example.com>".
    let from: String
    let subject: String
    let receivedAt: Date
    let isFromOwner: Bool

    var fromAddress: String { NudgeAddress.address(in: from) }
    var fromName: String { NudgeAddress.name(in: from) }
}

/// The two Gmail reads the nudge makes. `LiveNudgeMailbox` talks to the API;
/// tests script one.
nonisolated protocol NudgeMailbox: Sendable {
    /// Inbox and sent mail from the last `days` days, headers only (spam, trash and drafts excluded).
    func recentMessages(days: Int) async throws -> [NudgeMessage]
    /// The plain-text body of one message, unframed. Callers frame it.
    func body(messageId: String) async throws -> String
}

nonisolated enum NudgeAddress {
    /// "Alice Example <Alice@Example.com>" → "alice@example.com"; a bare address passes through.
    static func address(in from: String) -> String {
        let trimmed = from.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = trimmed.lastIndex(of: "<"), let close = trimmed[open...].firstIndex(of: ">") {
            return String(trimmed[trimmed.index(after: open)..<close]).trimmingCharacters(in: .whitespaces).lowercased()
        }
        return trimmed.lowercased()
    }

    /// The display name, or the address's local part when there is none.
    static func name(in from: String) -> String {
        let trimmed = from.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = trimmed.firstIndex(of: "<") {
            let name = trimmed[..<open].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'")))
            if !name.isEmpty { return name }
        }
        let address = address(in: trimmed)
        return address.split(separator: "@").first.map(String.init) ?? address
    }
}

/// Gmail through `GmailAPI` and the owner's OAuth tokens: one list call plus
/// one metadata call per message, bodies on demand.
nonisolated struct LiveNudgeMailbox: NudgeMailbox {

    static let maxMessages = 100

    func recentMessages(days: Int) async throws -> [NudgeMessage] {
        let query = "newer_than:\(max(1, days))d -in:spam -in:trash -in:draft"
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let (listData, listStatus) = try await GmailAPI.request("/messages?q=\(encoded)&maxResults=\(Self.maxMessages)")
        guard (200...299).contains(listStatus) else { throw GmailSourceError.http(listStatus) }
        let list = try JSONValue(data: listData)
        var messages: [NudgeMessage] = []
        for entry in list["messages"]?.arrayValue ?? [] {
            guard let id = entry["id"]?.stringValue else { continue }
            let (data, status) = try await GmailAPI.request("/messages/\(id)?format=metadata&metadataHeaders=From&metadataHeaders=Subject")
            guard (200...299).contains(status) else { continue }
            let json = try JSONValue(data: data)
            var headers: [String: String] = [:]
            for header in json["payload"]?["headers"]?.arrayValue ?? [] {
                if let name = header["name"]?.stringValue?.lowercased(), let value = header["value"]?.stringValue, headers[name] == nil {
                    headers[name] = value
                }
            }
            let millis = json["internalDate"]?.stringValue.flatMap(Double.init) ?? json["internalDate"]?.doubleValue
            let labels = json["labelIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
            messages.append(NudgeMessage(id: json["id"]?.stringValue ?? id,
                                         threadId: json["threadId"]?.stringValue ?? "",
                                         from: headers["from"] ?? "unknown",
                                         subject: headers["subject"] ?? "(no subject)",
                                         receivedAt: millis.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date(),
                                         isFromOwner: labels.contains("SENT")))
        }
        return messages
    }

    func body(messageId: String) async throws -> String {
        let (data, status) = try await GmailAPI.request("/messages/\(messageId)?format=full")
        guard (200...299).contains(status) else { throw GmailSourceError.http(status) }
        guard let message = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GmailSourceError.badResponse("message \(messageId) is not an object")
        }
        return GmailAPI.extractBody(from: message)
    }
}

// MARK: - State

/// The nudge's row state. Its first two fields are `NudgeState`, which the
/// morning brief decodes from the same JSON (unknown keys are ignored); the
/// rest is bookkeeping for replies.
nonisolated struct NudgeScratch: Codable, Sendable, Equatable {
    /// Threads currently waiting, with draft and code once drafted.
    var threads: [UnrepliedThread]
    var updatedAt: Date
    /// Last inbound message id per thread, for `reply_to_email`.
    var messageIds: [String: String]
    /// Threads the owner answered through Majoor, by date: no nudge for a week.
    var sent: [String: Date]
    /// Threads the owner skipped, by date: no nudge for a week.
    var skipped: [String: Date]

    init(threads: [UnrepliedThread] = [], updatedAt: Date, messageIds: [String: String] = [:],
         sent: [String: Date] = [:], skipped: [String: Date] = [:]) {
        self.threads = threads
        self.updatedAt = updatedAt
        self.messageIds = messageIds
        self.sent = sent
        self.skipped = skipped
    }

    var state: NudgeState { NudgeState(threads: threads, updatedAt: updatedAt) }

    static func decode(_ text: String?) -> NudgeScratch? {
        guard let text, let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder.wire.decode(NudgeScratch.self, from: data)
    }

    func encoded() throws -> String {
        String(decoding: try JSONEncoder.wire.encode(self), as: UTF8.self)
    }

    mutating func prune(now: Date, keep interval: TimeInterval) {
        sent = sent.filter { now.timeIntervalSince($0.value) < interval }
        skipped = skipped.filter { now.timeIntervalSince($0.value) < interval }
    }
}

// MARK: - The job

nonisolated enum VIPNudgeJob {

    static let name = JobNames.vipNudge
    static let title = "VIP email nudge"
    /// How far back the mailbox is read. The threshold is hours; three days
    /// covers a long weekend.
    static let lookbackDays = 3
    static let maxThreadsPerRun = 3
    /// A thread nudged once is not nudged again for this long.
    static let renudgeInterval: TimeInterval = 24 * 3600
    /// `send`, `edit` and `skip` rest a thread for this long.
    static let restInterval: TimeInterval = 7 * 24 * 3600
    static let codeLifetime: TimeInterval = 24 * 3600
    static let headerFieldCap = 200

    typealias VIPs = @Sendable () -> [String]
    /// What Majoor remembers about a sender, as short notes; empty when nothing.
    typealias MemoryLookup = @Sendable (String) -> [String]
    typealias CodeMinter = @Sendable () -> String

    nonisolated struct Candidate: Sendable, Equatable {
        let thread: UnrepliedThread
        let messageId: String
    }

    static let definitions: [JobDefinition] = [
        definition(mailbox: LiveNudgeMailbox(),
                   vips: { ContactPolicyStore.shared.vips().map(\.handle) },
                   settings: .shared),
    ]

    static let instructions = """
    You draft email replies for the owner. For each waiting thread below, write one complete reply in the owner's \
    own voice: direct, warm, short, with their natural sign-off and no assistant phrasing. Answer what the sender \
    asked; when you cannot know the answer, write the reply the owner would most plausibly send and make the \
    uncertain part easy to edit. Never invent commitments, dates or numbers that are not in the thread. Set \
    "outcome" to "notify", "urgency" to 2, put a one-line overview in "text", and the drafts in "drafts". When no \
    thread is listed, answer with no_change.
    """

    static let outputSchema = #""drafts": [{"threadId": "<the thread id given>", "draft": "<the full reply text>"}], one entry per waiting thread"#

    static func definition(mailbox: any NudgeMailbox, vips: @escaping VIPs, settings: NudgeSettingsStore,
                           memory: @escaping MemoryLookup = VIPNudgeJob.rememberedNotes,
                           code: @escaping CodeMinter = { AgentSession.makeNonce() }) -> JobDefinition {
        JobDefinition(
            name: name,
            title: title,
            summary: "Every two hours, finds VIP threads you have not answered and texts you a draft reply to send, edit or skip.",
            tier: .privateCloud,
            inputs: [.gmailWithBodies],
            instructions: instructions,
            outputSchema: outputSchema,
            urgencyCeiling: 2,
            riskCeiling: "R0",
            delivery: .ladder,
            defaultCron: "0 */2 * * *",
            gather: { context in
                try await gather(context, mailbox: mailbox, vips: vips, settings: settings, memory: memory)
            },
            apply: { object, _, context in
                try apply(object, context: context, code: code)
            })
    }

    // MARK: Detection

    /// Pure: which threads are waiting. A thread counts when its last message
    /// is inbound from a VIP address and older than `threshold`, and the owner
    /// has not nudged, answered or skipped it recently. Weekends are quiet
    /// when `skipWeekends` is set. Oldest first, at most `maxThreadsPerRun`.
    static func candidates(messages: [NudgeMessage], vips: Set<String>, now: Date, threshold: TimeInterval,
                           skipWeekends: Bool, timeZone: TimeZone, scratch: NudgeScratch?) -> [Candidate] {
        if skipWeekends {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let weekday = calendar.component(.weekday, from: now)
            if weekday == 1 || weekday == 7 { return [] }
        }
        var latest: [String: NudgeMessage] = [:]
        for message in messages where !message.threadId.isEmpty {
            if let current = latest[message.threadId], current.receivedAt >= message.receivedAt { continue }
            latest[message.threadId] = message
        }
        var found: [Candidate] = []
        for (threadId, last) in latest {
            guard !last.isFromOwner, vips.contains(last.fromAddress) else { continue }
            guard now.timeIntervalSince(last.receivedAt) >= threshold else { continue }
            if let scratch {
                if let previous = scratch.threads.first(where: { $0.threadId == threadId }), let remindedAt = previous.remindedAt,
                   now.timeIntervalSince(remindedAt) < renudgeInterval { continue }
                if let sentAt = scratch.sent[threadId], now.timeIntervalSince(sentAt) < restInterval { continue }
                if let skippedAt = scratch.skipped[threadId], now.timeIntervalSince(skippedAt) < restInterval { continue }
            }
            let thread = UnrepliedThread(threadId: threadId, from: clean(last.fromName), subject: clean(last.subject), waitingSince: last.receivedAt)
            found.append(Candidate(thread: thread, messageId: last.id))
        }
        found.sort { $0.thread.waitingSince < $1.thread.waitingSince }
        return Array(found.prefix(maxThreadsPerRun))
    }

    /// Header fields are outside text: control characters out, length capped.
    static func clean(_ text: String) -> String {
        String(UntrustedContent.stripControlCharacters(text).replacingOccurrences(of: "\n", with: " ").prefix(headerFieldCap))
    }

    static func gather(_ context: JobContext, mailbox: any NudgeMailbox, vips: VIPs, settings: NudgeSettingsStore,
                       memory: MemoryLookup) async throws -> [String] {
        let now = context.now
        var scratch = context.scratch(as: NudgeScratch.self) ?? NudgeScratch(updatedAt: now)
        scratch.prune(now: now, keep: restInterval)
        let vipSet = Set(vips().map { TrustPolicy.normalize(handle: $0) }.filter { $0.contains("@") })
        let found: [Candidate]
        if vipSet.isEmpty {
            found = []
        } else {
            let messages = try await mailbox.recentMessages(days: lookbackDays)
            found = candidates(messages: messages, vips: vipSet, now: now, threshold: TimeInterval(settings.thresholdHours) * 3600,
                               skipWeekends: settings.skipWeekends, timeZone: context.timeZone, scratch: scratch)
        }

        // The provisional state tells `apply` which threads were put to the model.
        scratch.threads = found.map(\.thread)
        scratch.updatedAt = now
        for candidate in found { scratch.messageIds[candidate.thread.threadId] = candidate.messageId }
        scratch.messageIds = scratch.messageIds.filter { key, _ in found.contains { $0.thread.threadId == key } }
        try context.saveScratch(scratch)

        guard !found.isEmpty else {
            return ["No VIP thread is waiting for a reply. Answer with no_change."]
        }

        // Memory is Majoor's own state: under Strict it may not reach tier P,
        // so the drafts go without it there. `claudeOnly`, or a preset that
        // lets majoorState reach this tier, gets the sender notes.
        let memoryAllowed = context.preset.allows(.majoorState, on: context.tier)
        var sections = ["\(found.count) VIP thread(s) are waiting for the owner's reply. Draft one reply for each."]
        for candidate in found {
            let thread = candidate.thread
            let hours = Int(now.timeIntervalSince(thread.waitingSince) / 3600)
            let body = try await mailbox.body(messageId: candidate.messageId)
            var section = "Thread \(thread.threadId): from \(thread.from), waiting \(hours) h.\n"
            section += UntrustedContent.wrap(label: "thread \(thread.threadId)", source: "gmail",
                                             text: "From: \(thread.from)\nSubject: \(thread.subject)\n\n\(body)")
            if memoryAllowed {
                let notes = memory(thread.from)
                if !notes.isEmpty {
                    section += "\nWhat Majoor remembers about this sender:\n" + notes.map { "- \($0)" }.joined(separator: "\n")
                }
            }
            sections.append(section)
        }
        return sections
    }

    static func rememberedNotes(_ sender: String) -> [String] {
        ((try? MemoryStore.shared.search(query: sender, limit: 5)) ?? []).map(\.content)
    }

    // MARK: Apply

    /// Matches the model's drafts to the waiting threads, mints a code for
    /// each, saves the state the replies work from, and returns the message
    /// for the owner. A thread without a draft is a failure, never a guess.
    static func apply(_ object: JSONValue, context: JobContext, code: CodeMinter) throws -> JobOutcome {
        let now = context.now
        guard var scratch = NudgeScratch.decode(context.automations.record(id: context.record.id)?.scratch) else {
            return .noChange(summary: "no VIP thread is waiting for a reply")
        }
        guard !scratch.threads.isEmpty else {
            return .noChange(summary: "no VIP thread is waiting for a reply")
        }
        var drafts: [String: String] = [:]
        for entry in object["drafts"]?.arrayValue ?? [] {
            guard let threadId = entry["threadId"]?.stringValue,
                  let draft = entry["draft"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !draft.isEmpty else { continue }
            drafts[threadId] = draft
        }
        var lines: [String] = []
        for index in scratch.threads.indices {
            let thread = scratch.threads[index]
            guard let draft = drafts[thread.threadId] else {
                return .failed("no draft for the thread \"\(thread.subject)\" from \(thread.from)")
            }
            let minted = code().uppercased()
            scratch.threads[index].draft = draft
            scratch.threads[index].code = minted
            scratch.threads[index].remindedAt = now
            let hours = Int(now.timeIntervalSince(thread.waitingSince) / 3600)
            lines.append("\(thread.from) (VIP) has waited \(hours) h on \"\(thread.subject)\". Draft:\n\(draft)\n"
                         + "Reply `send \(minted)` to send, `edit \(minted) <changes>` to redraft, `skip \(minted)`.")
        }
        scratch.updatedAt = now
        try context.saveScratch(scratch)
        return .notify(urgency: 2, text: lines.joined(separator: "\n\n"))
    }

    // MARK: Replies

    /// `send K7Q2` / `edit K7Q2 <changes>` / `skip K7Q2` from the owner, routed
    /// here by `ChannelRouter`.
    static func handleReply(action: NudgeReply.Action, code: String, changes: String?, origin: ChannelRef) async -> String {
        await NudgeReplyHandler.shared.handle(NudgeReply.Parsed(action: action, code: code, changes: changes), origin: origin)
    }
}

// MARK: - Replies

/// The owner acting on a draft. The code is required, as with approvals: a
/// bare "send" is a task, not a reply.
nonisolated enum NudgeReply {
    nonisolated enum Action: String, Sendable, Equatable {
        case send, edit, skip
    }

    nonisolated struct Parsed: Sendable, Equatable {
        let action: Action
        let code: String
        let changes: String?
    }

    private static let pattern = try! NSRegularExpression(
        pattern: #"^\s*(send|edit|skip)\s+([A-Za-z0-9]{4})(?:\s+(.+))?\s*$"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators])

    static func parse(_ text: String) -> Parsed? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern.firstMatch(in: text, range: range),
              let verbRange = Range(match.range(at: 1), in: text),
              let codeRange = Range(match.range(at: 2), in: text),
              let action = Action(rawValue: text[verbRange].lowercased()) else { return nil }
        var changes: String? = nil
        if let changesRange = Range(match.range(at: 3), in: text) {
            let trimmed = text[changesRange].trimmingCharacters(in: .whitespacesAndNewlines)
            changes = trimmed.isEmpty ? nil : trimmed
        }
        return Parsed(action: action, code: String(text[codeRange]).uppercased(), changes: changes)
    }
}

/// Looks a code up in the nudge row's state and acts: `send` and `edit`
/// spawn a task session whose only job is to call reply_to_email, which asks
/// for approval as always; `skip` rests the thread. Production uses the
/// shared stores and `SessionManager.shared`; tests inject.
nonisolated final class NudgeReplyHandler: Sendable {

    /// Submits a task and returns its short id, or nil when the runtime is unavailable.
    typealias Submit = @Sendable (_ input: String, _ origin: ChannelRef, _ trust: ChannelTrust) async -> Int?

    static let shared = NudgeReplyHandler(
        automations: { AutomationStore.shared },
        submit: { input, origin, trust in await SessionManager.shared.submit(input: input, origin: origin, trust: trust)?.shortId },
        now: { Date() })

    private let automations: @Sendable () -> AutomationStore
    private let submit: Submit
    private let now: @Sendable () -> Date

    init(automations: @escaping @Sendable () -> AutomationStore, submit: @escaping Submit, now: @escaping @Sendable () -> Date) {
        self.automations = automations
        self.submit = submit
        self.now = now
    }

    func handle(_ reply: NudgeReply.Parsed, origin: ChannelRef) async -> String {
        let store = automations()
        let code = reply.code.uppercased()
        guard let record = store.jobRecord(named: VIPNudgeJob.name), var scratch = NudgeScratch.decode(record.scratch),
              let index = scratch.threads.firstIndex(where: { $0.code?.uppercased() == code }) else {
            return "No draft matches code \(code). Codes expire after 24 hours; the next nudge brings a fresh one."
        }
        let thread = scratch.threads[index]
        let now = now()
        if let remindedAt = thread.remindedAt, now.timeIntervalSince(remindedAt) > VIPNudgeJob.codeLifetime {
            return "Code \(code) has expired (codes last 24 hours). The next nudge brings a fresh draft."
        }
        // A reply from a remote thread is remote text: Auto mode never applies to it.
        let trust: ChannelTrust = origin.channelId == PanelChannel.channelId ? .local : .remoteText

        func save(_ updated: NudgeScratch) {
            var saved = updated
            saved.threads.remove(at: index)
            saved.updatedAt = now
            store.setScratch(id: record.id, try? saved.encoded())
        }

        switch reply.action {
        case .skip:
            scratch.skipped[thread.threadId] = now
            save(scratch)
            MajoorLogger.log("✉️ Nudge \(code) skipped: \(thread.subject)")
            return "Skipped. I won't nudge you about \"\(thread.subject)\" from \(thread.from) for a week."

        case .send:
            guard let draft = thread.draft, let messageId = scratch.messageIds[thread.threadId] else {
                return "That draft is incomplete; the next nudge will redraft it."
            }
            let prompt = """
            Send this reply in the email thread "\(thread.subject)" from \(thread.from). Call reply_to_email with email_id \
            "\(messageId)" and this exact body, unchanged:

            \(draft)
            """
            guard let shortId = await submit(prompt, origin, trust) else {
                return "I could not start the send; the agent runtime is not available. Try again in a moment."
            }
            scratch.sent[thread.threadId] = now
            save(scratch)
            MajoorLogger.log("✉️ Nudge \(code) sending via session \(shortId)")
            return "Sending your reply to \(thread.from). Approve the send when I ask (session \(shortId))."

        case .edit:
            guard let changes = reply.changes, !changes.isEmpty else {
                return "Tell me what to change: `edit \(code) <changes>`."
            }
            guard let draft = thread.draft, let messageId = scratch.messageIds[thread.threadId] else {
                return "That draft is incomplete; the next nudge will redraft it."
            }
            let prompt = """
            Redraft the reply in the email thread "\(thread.subject)" from \(thread.from), then send it: call reply_to_email with \
            email_id "\(messageId)" and the new draft as the body. Keep the owner's voice and apply these changes from the owner:

            \(changes)

            The previous draft was:

            \(draft)
            """
            guard let shortId = await submit(prompt, origin, trust) else {
                return "I could not start the redraft; the agent runtime is not available. Try again in a moment."
            }
            scratch.sent[thread.threadId] = now
            save(scratch)
            MajoorLogger.log("✉️ Nudge \(code) redrafting via session \(shortId)")
            return "Redrafting with your changes. Approve the send when I ask (session \(shortId))."
        }
    }
}
