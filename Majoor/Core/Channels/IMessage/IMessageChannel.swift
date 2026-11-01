// IMessageChannel.swift
// Majoor — The owner's iMessage thread as a channel (Phase 1 step 7)
//
// Drives one `imsg rpc` child: initialize, replay what arrived while we
// were down, then watch. Inbound text passes the owner-only policy before
// it reaches the router; replies and approval prompts go out as plain
// text. The helper is supervised: on exit it restarts with backoff and
// gives up after five quick crashes. Messages that arrived more than ten
// minutes ago (configurable) are summarized, never executed: an unattended
// agent must not run an hours-old "delete the build folder".
//
// Questions (Phase 2 step 6h): `ask` texts the owner a question with a short
// code and optional numbered options, and the next owner message in that
// thread that names an option or starts with the code is the answer. It is
// consumed here and never reaches the router as a task. One question per
// thread at a time; nothing survives a relaunch.

import Foundation

nonisolated enum IMessageError: Error, Sendable, Equatable {
    case databaseNotReady(String)
    case helperExited
    case badThread(String)
    case notRunning
}

actor IMessageChannel: Channel {

    static let channelId = "imessage"
    static let enabledKey = "imessageEnabled"
    static let staleMinutesKey = "imessageStaleMinutes"
    static let lastRowIdKey = "imessageLastRowId"
    static let defaultStaleMinutes = 10
    static let restartBackoff: [Duration] = [.seconds(5), .seconds(10), .seconds(20), .seconds(40), .seconds(80)]
    static let maxRestarts = 5
    static let healthyRunInterval: TimeInterval = 300
    static let greetingInterval: TimeInterval = 600
    static let rateLimitPerMinute = 10
    static let replayPageLimit = 100

    nonisolated enum Status: Sendable, Equatable {
        case stopped
        case starting
        case waitingForDatabase(String)
        case running
        case restarting(attempt: Int, inSeconds: Int)
        case failed(String)

        var text: String {
            switch self {
            case .stopped: return "Off"
            case .starting: return "Starting…"
            case .waitingForDatabase(let detail): return "Waiting for the Messages database: \(detail)"
            case .running: return "Connected"
            case .restarting(let attempt, let seconds): return "imsg exited; restart \(attempt) in \(seconds) s"
            case .failed(let detail): return "Failed: \(detail)"
            }
        }
    }

    nonisolated struct Config: Sendable {
        var owners: @Sendable () -> [String]
        var staleAfter: TimeInterval = TimeInterval(IMessageChannel.defaultStaleMinutes * 60)
        var appVersion: String = "0"
        var loadCursor: @Sendable () -> Int = { 0 }
        var saveCursor: @Sendable (Int) -> Void = { _ in }
        var now: @Sendable () -> Date = { Date() }
        /// Local notification for degraded states (Full Disk Access, crash loop).
        var notifyLocally: @Sendable (String, String) -> Void = { _, _ in }

        init(owners: @escaping @Sendable () -> [String]) {
            self.owners = owners
        }
    }

    nonisolated let id = IMessageChannel.channelId
    nonisolated let trust: ChannelTrust = .remoteText
    nonisolated let inbound: AsyncStream<InboundMessage>
    private let continuation: AsyncStream<InboundMessage>.Continuation

    private let transport: any JSONRPCTransport
    private let config: Config
    private var runTask: Task<Void, Never>?
    private var cursor: Int
    private var chats: [Int: IMessageChat] = [:]
    private var unknownChats: Set<Int> = []
    private var seen: Set<String> = []
    private var seenOrder: [String] = []
    private var limiter = SlidingWindowLimiter(limit: IMessageChannel.rateLimitPerMinute, window: 60)
    private var lastGreetingAt: Date?
    private var notifiedDatabase = false
    private var statusSubscribers: [UUID: AsyncStream<Status>.Continuation] = [:]

    private struct PendingQuestion {
        let code: String
        let options: [String]
        let continuation: CheckedContinuation<Answer, Never>
        let expiry: Task<Void, Never>
    }
    /// Keyed by thread. In memory only: a question does not outlive the process.
    private var pendingQuestions: [String: PendingQuestion] = [:]
    /// Owner messages consumed as answers, never yielded as tasks.
    private(set) var answeredQuestions = 0

    private(set) var helperVersion: String?
    private(set) var databaseReady = false
    /// Counts by policy decision; never the content (PRD T1).
    private(set) var dropped: [String: Int] = [:]
    private(set) var acceptedCount = 0
    private(set) var status: Status = .stopped {
        didSet {
            guard status != oldValue else { return }
            for continuation in statusSubscribers.values { continuation.yield(status) }
        }
    }

    init(transport: any JSONRPCTransport, config: Config) {
        self.transport = transport
        self.config = config
        self.cursor = config.loadCursor()
        (inbound, continuation) = AsyncStream.makeStream(of: InboundMessage.self, bufferingPolicy: .unbounded)
    }

    var currentCursor: Int { cursor }

    func statusStream() -> AsyncStream<Status> {
        let id = UUID()
        let current = status
        return AsyncStream { continuation in
            continuation.yield(current)
            statusSubscribers[id] = continuation
            continuation.onTermination = { @Sendable _ in
                Task { await self.removeStatusSubscriber(id) }
            }
        }
    }

    private func removeStatusSubscriber(_ id: UUID) {
        statusSubscribers[id] = nil
    }

    // MARK: Lifecycle

    func start() {
        guard runTask == nil else { return }
        runTask = Task { await self.run() }
    }

    func stop() async {
        runTask?.cancel()
        runTask = nil
        for threadKey in Array(pendingQuestions.keys) { resolveQuestion(threadKey, with: .unanswered) }
        await transport.stop()
        status = .stopped
    }

    private func run() async {
        var restarts = 0
        while !Task.isCancelled {
            status = restarts == 0 ? .starting : .restarting(attempt: restarts, inSeconds: 0)
            let startedAt = config.now()
            do {
                try await session()
            } catch IMessageError.databaseNotReady(let detail) {
                status = .waitingForDatabase(detail)
                if !notifiedDatabase {
                    notifiedDatabase = true
                    config.notifyLocally("iMessage needs Full Disk Access", "Grant Majoor Full Disk Access in System Settings ▸ Privacy & Security, then it will connect on its own.")
                }
                await transport.stop()
                if Task.isCancelled { break }
                try? await Task.sleep(for: .seconds(60))
                continue
            } catch {
                MajoorLogger.error("iMessage channel: \(error)")
            }
            await transport.stop()
            if Task.isCancelled { break }
            if config.now().timeIntervalSince(startedAt) > Self.healthyRunInterval { restarts = 0 }
            restarts += 1
            if restarts > Self.maxRestarts {
                let detail = "imsg exited \(restarts) times in a row"
                status = .failed(detail)
                config.notifyLocally("iMessage channel stopped", "\(detail). Turn iMessage off and on in Settings ▸ Channels to retry.")
                runTask = nil
                return
            }
            let delay = Self.restartBackoff[min(restarts - 1, Self.restartBackoff.count - 1)]
            status = .restarting(attempt: restarts, inSeconds: Int(delay.components.seconds))
            try? await Task.sleep(for: delay)
        }
        status = .stopped
    }

    /// One life of the helper: until its notification stream ends.
    private func session() async throws {
        try await transport.start()
        let info = try await transport.call("initialize", params: .object(["protocol_version": .number(1)]), timeout: .seconds(30))
        helperVersion = info["version"]?.stringValue
        databaseReady = info["database"]?["ready"]?.boolValue ?? false
        guard databaseReady else {
            throw IMessageError.databaseNotReady(info["database"]?["error"]?.stringValue ?? "chat.db is not readable")
        }
        notifiedDatabase = false
        status = .running
        // Subscribe to notifications before `watch.subscribe` so none are missed.
        let notifications = await transport.notifications()
        await greet()
        try await replay()
        try await subscribeWatch()
        for await notification in notifications {
            switch notification.method {
            case "message":
                if let json = notification.params["message"], let message = IMessageMessage(json: json) {
                    _ = await handle(message, live: true)
                }
            case "watch.overflow":
                if let resume = notification.params["resume_after_rowid"]?.intValue {
                    cursor = resume
                    config.saveCursor(cursor)
                }
                try await replay()
                try await subscribeWatch()
            default:
                break
            }
        }
        throw IMessageError.helperExited
    }

    private func subscribeWatch() async throws {
        var params: [String: JSONValue] = [:]
        if cursor > 0 { params["since_rowid"] = .number(Double(cursor)) }
        _ = try await transport.call("watch.subscribe", params: .object(params), timeout: .seconds(30))
    }

    /// PRD §14: "Majoor texts you after any restart". One line, at most one
    /// per ten minutes so a crash loop does not spam.
    private func greet() async {
        let now = config.now()
        if let last = lastGreetingAt, now.timeIntervalSince(last) < Self.greetingInterval { return }
        lastGreetingAt = now
        for owner in config.owners() {
            do { try await sendText(to: TrustPolicy.normalize(handle: owner), text: "Majoor is online (v\(config.appVersion)).") }
            catch { MajoorLogger.log("iMessage greeting to owner failed: \(error)") }
        }
    }

    // MARK: Replay

    /// Without a cursor (first run) nothing is replayed: the watch starts
    /// at the tail. With one, every new row since is paged through; recent
    /// ones are handed to the router, older ones summarized.
    private func replay() async throws {
        guard cursor > 0 else { return }
        var stale: [IMessageMessage] = []
        var hasMore = true
        var pages = 0
        while hasMore, pages < Self.replayPageLimit {
            let page = try await transport.call("messages.after", params: .object(["since_rowid": .number(Double(cursor)), "limit": .number(200)]), timeout: .seconds(60))
            for json in page["messages"]?.arrayValue ?? [] {
                guard let message = IMessageMessage(json: json) else { continue }
                if let old = await handle(message, live: false) { stale.append(old) }
            }
            if let next = page["next_rowid"]?.intValue, next > cursor { cursor = next }
            config.saveCursor(cursor)
            hasMore = page["has_more"]?.boolValue ?? false
            pages += 1
        }
        await reportStale(stale)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private func reportStale(_ stale: [IMessageMessage]) async {
        guard let last = stale.last else { return }
        let handle = TrustPolicy.normalize(handle: last.sender)
        let dates = stale.compactMap(\.createdAt)
        var text = "I was offline and missed \(stale.count) message\(stale.count == 1 ? "" : "s")"
        if let first = dates.min(), let latest = dates.max() {
            text += " from \(Self.timeFormatter.string(from: first)) to \(Self.timeFormatter.string(from: latest))"
        }
        text += ". Send them again if you still want them."
        // STOP is the one command always honored when it is the newest message.
        if InboundCommand.parse(last.text) == .stopAll {
            continuation.yield(InboundMessage(channelId: id, threadKey: Self.threadKey(for: handle), sender: last.sender, text: last.text,
                                              receivedAt: last.createdAt ?? config.now()))
            text += " (Your last message was STOP, so I stopped everything.)"
        }
        do { try await sendText(to: handle, text: text) }
        catch { MajoorLogger.log("iMessage stale summary failed: \(error)") }
    }

    // MARK: Inbound

    /// Returns the message when it is stale (for the summary); nil otherwise.
    private func handle(_ message: IMessageMessage, live: Bool) async -> IMessageMessage? {
        if message.mutation == nil, message.id > cursor, live {
            cursor = message.id
            config.saveCursor(cursor)
        }
        guard remember(message.guid) else { return nil }
        let policy = IMessageInboundPolicy(owners: config.owners(), staleAfter: config.staleAfter)
        let now = config.now()
        var decision = policy.evaluate(message, chat: nil, now: now, live: live)
        if decision.needsChat {
            decision = policy.evaluate(message, chat: await chatInfo(message.chatId), now: now, live: live)
        }
        switch decision {
        case .accept(let handle):
            guard limiter.allow(handle, at: now) else {
                dropped["rateLimited", default: 0] += 1
                return nil
            }
            acceptedCount += 1
            let threadKey = Self.threadKey(for: handle)
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // A reply to a pending question is consumed here. STOP is never an
            // answer: it must reach the router whatever is pending.
            if let pending = pendingQuestions[threadKey], InboundCommand.parse(text) != .stopAll,
               let answer = Self.matchAnswer(text, code: pending.code, options: pending.options) {
                answeredQuestions += 1
                resolveQuestion(threadKey, with: answer)
                return nil
            }
            continuation.yield(InboundMessage(channelId: id, threadKey: threadKey, sender: message.sender,
                                              text: text, receivedAt: message.createdAt ?? now))
            return nil
        case .stale:
            return message
        default:
            dropped[decision.name, default: 0] += 1
            return nil
        }
    }

    /// Bounded guid set: live rows after a replay overlap can arrive twice.
    private func remember(_ guid: String) -> Bool {
        guard !seen.contains(guid) else { return false }
        seen.insert(guid)
        seenOrder.append(guid)
        if seenOrder.count > 1000 {
            let evicted = seenOrder.removeFirst()
            seen.remove(evicted)
        }
        return true
    }

    private func chatInfo(_ chatId: Int) async -> IMessageChat? {
        if let cached = chats[chatId] { return cached }
        if unknownChats.contains(chatId) { return nil }
        do {
            let json = try await transport.call("chats.get", params: .object(["chat_id": .number(Double(chatId))]), timeout: .seconds(30))
            guard let chat = IMessageChat(json: json) else { unknownChats.insert(chatId); return nil }
            chats[chatId] = chat
            return chat
        } catch {
            MajoorLogger.log("iMessage: chats.get \(chatId) failed: \(error)")
            unknownChats.insert(chatId)
            return nil
        }
    }

    // MARK: Outbound

    static func threadKey(for handle: String) -> String { "\(channelId):\(handle)" }

    static func handle(fromThreadKey key: String) -> String {
        let prefix = channelId + ":"
        return key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : key
    }

    /// Plain text only in Phase 1 (PRD §5.4 with SIP on); attachments are ignored.
    func send(to threadKey: String, text: String, attachments: [URL]) async throws {
        try await sendText(to: Self.handle(fromThreadKey: threadKey), text: text)
    }

    func sendText(to handle: String, text: String) async throws {
        let target = TrustPolicy.normalize(handle: handle)
        guard !target.isEmpty else { throw IMessageError.badThread(handle) }
        guard await transport.isRunning else { throw IMessageError.notRunning }
        for chunk in IMessageChunker.chunks(text) {
            let params: JSONValue = .object(["to": .string(target), "text": .string(chunk), "service": .string("imessage"), "allow_sms_fallback": .bool(false)])
            _ = try await transport.call("send", params: params, timeout: .seconds(60))
        }
    }

    // MARK: Questions

    /// Texts the question with a code and the options, then waits for the
    /// owner's reply in that thread (see `matchAnswer`), the timeout, or
    /// cancellation (the session was stopped). A second question on a thread
    /// that already has one pending is refused at once with no answer.
    func ask(threadKey: String, question: String, options: [String], timeout: Duration) async -> Answer {
        guard pendingQuestions[threadKey] == nil else {
            MajoorLogger.log("❓ A question is already pending on \(threadKey); refusing another")
            return .unanswered
        }
        let code = AgentSession.makeNonce()
        let cleanOptions = options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        do {
            try await send(to: threadKey, text: Self.questionText(question, options: cleanOptions, code: code, timeout: timeout), attachments: [])
        } catch {
            MajoorLogger.log("❓ Could not send the question on \(threadKey): \(error)")
            return .unanswered
        }
        guard pendingQuestions[threadKey] == nil else { return .unanswered }   // raced with another ask while sending
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Answer, Never>) in
                let expiry = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    await self?.expireQuestion(threadKey, code: code)
                }
                pendingQuestions[threadKey] = PendingQuestion(code: code, options: cleanOptions, continuation: continuation, expiry: expiry)
            }
        } onCancel: {
            Task { await self.cancelQuestion(threadKey, code: code) }
        }
    }

    static func questionText(_ question: String, options: [String], code: String, timeout: Duration) -> String {
        var text = "Question [\(code)]: \(question.trimmingCharacters(in: .whitespacesAndNewlines))"
        if !options.isEmpty {
            text += "\n" + options.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            text += "\nReply with a number or an option, or start a free answer with \(code)."
        } else {
            text += "\nStart your reply with \(code)."
        }
        let minutes = max(1, Int(timeout.components.seconds / 60))
        text += " I will wait \(minutes) min."
        return text
    }

    /// The owner's text as an answer, or nil when it is not one. A reply that
    /// starts with the code is a free answer (an option name after it counts as
    /// that option); otherwise only an option's number or text matches, so an
    /// unrelated message while a question is pending is still a task.
    static func matchAnswer(_ text: String, code: String, options: [String]) -> Answer? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let first = trimmed.split(whereSeparator: { $0.isWhitespace || $0 == ":" }).first,
           AgentSession.nonceMatches(String(first).trimmingCharacters(in: .punctuationCharacters), code) {
            var rest = String(trimmed.dropFirst(first.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            while let lead = rest.first, ":-–".contains(lead) {
                rest.removeFirst()
                rest = rest.trimmingCharacters(in: .whitespaces)
            }
            let option = option(matching: rest, in: options)
            return Answer(text: rest.isEmpty ? nil : rest, option: option, timedOut: false)
        }
        if let option = option(matching: trimmed, in: options) {
            return Answer(text: option, option: option, timedOut: false)
        }
        return nil
    }

    static func option(matching text: String, in options: [String]) -> String? {
        guard !options.isEmpty else { return nil }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".)"))
        if let number = Int(cleaned), (1...options.count).contains(number) { return options[number - 1] }
        return options.first { $0.compare(cleaned, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    private func resolveQuestion(_ threadKey: String, with answer: Answer) {
        guard let pending = pendingQuestions.removeValue(forKey: threadKey) else { return }
        pending.expiry.cancel()
        pending.continuation.resume(returning: answer)
    }

    private func expireQuestion(_ threadKey: String, code: String) {
        guard pendingQuestions[threadKey]?.code == code else { return }
        MajoorLogger.log("❓ No answer on \(threadKey) in time")
        resolveQuestion(threadKey, with: .unanswered)
    }

    private func cancelQuestion(_ threadKey: String, code: String) {
        guard pendingQuestions[threadKey]?.code == code else { return }
        resolveQuestion(threadKey, with: .unanswered)
    }

    /// Settings ▸ Channels "Send test message".
    func sendTest() async throws {
        guard let owner = config.owners().first else { throw IMessageError.badThread("no owner handle configured") }
        try await sendText(to: owner, text: "Test from Majoor (v\(config.appVersion)). If you can read this, iMessage is working.")
    }
}
