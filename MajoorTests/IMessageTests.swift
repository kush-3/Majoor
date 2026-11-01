// IMessageTests.swift
// MajoorTests — Phase 1 step 7: line framing, the inbound policy matrix,
// chunking, the channel against a fake helper, and the JSON-RPC client
// against a real child process.

import Foundation
import Testing
@testable import Majoor

@Suite("NewlineJSONFramer")
struct FramerTests {

    private func push(_ framer: inout NewlineJSONFramer, _ text: String) -> [String] {
        framer.push(Data(text.utf8)).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test("partial lines wait, coalesced lines split, blanks and CR are dropped")
    func framing() {
        var framer = NewlineJSONFramer()
        #expect(push(&framer, "{\"a\":1") == [])
        #expect(framer.pendingBytes == 6)
        #expect(push(&framer, "}\n{\"b\":2}\n\n  \r\n{\"c\"") == ["{\"a\":1}", "{\"b\":2}"])
        #expect(push(&framer, ":3}\r\n") == ["{\"c\":3}"])
        #expect(framer.pendingBytes == 0)
        #expect(push(&framer, "not json\n") == ["not json"])   // the decoder's problem, not the framer's
        #expect(framer.droppedLines == 0)
    }

    @Test("an oversized line is dropped and framing resumes at the next newline")
    func overflow() {
        var framer = NewlineJSONFramer(maxLineBytes: 16)
        #expect(push(&framer, String(repeating: "x", count: 20)) == [])
        #expect(framer.droppedLines == 1)
        #expect(framer.pendingBytes == 0)
        #expect(push(&framer, "yyyyy") == [])            // still the oversized line
        #expect(push(&framer, "zz\n{\"ok\":1}\n") == ["{\"ok\":1}"])
        #expect(push(&framer, "{\"after\":2}\n") == ["{\"after\":2}"])
    }
}

@Suite("iMessage inbound policy")
struct IMessagePolicyTests {

    private let owner = "+15551234567"
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private var policy: IMessageInboundPolicy { IMessageInboundPolicy(owners: ["+1 (555) 123-4567"], staleAfter: 600) }
    private var direct: IMessageChat { IMessageChat(id: 7, isGroup: false, service: "iMessage", participants: ["+15551234567"]) }

    private func message(sender: String = "+15551234567", text: String = "list files", fromMe: Bool = false, age: TimeInterval = 10,
                         reaction: Bool = false, mutation: String? = nil, isGroup: Bool? = nil) -> IMessageMessage {
        IMessageMessage(id: 1, guid: "g", chatId: 7, sender: sender, isFromMe: fromMe, text: text, createdAt: now.addingTimeInterval(-age),
                        isReaction: reaction, mutation: mutation, isGroup: isGroup)
    }

    @Test("the owner in a direct iMessage chat is accepted, live or recent")
    func accepts() {
        #expect(policy.evaluate(message(), chat: direct, now: now, live: true) == .accept(handle: owner))
        #expect(policy.evaluate(message(sender: "555-123-4567", age: 599), chat: direct, now: now, live: false) == .accept(handle: owner))
        // Participants may be absent on some rows; the sender check still holds.
        let bare = IMessageChat(id: 7, isGroup: false, service: "imessage", participants: [])
        #expect(policy.evaluate(message(), chat: bare, now: now, live: true) == .accept(handle: owner))
    }

    @Test("everything else is rejected with the right reason")
    func rejects() {
        #expect(policy.evaluate(message(fromMe: true), chat: direct, now: now, live: true) == .fromMe)
        #expect(policy.evaluate(message(mutation: "edited"), chat: direct, now: now, live: true) == .mutation)
        #expect(policy.evaluate(message(reaction: true), chat: direct, now: now, live: true) == .reaction)
        #expect(policy.evaluate(message(text: "  \n"), chat: direct, now: now, live: true) == .empty)
        #expect(policy.evaluate(message(isGroup: true), chat: direct, now: now, live: true) == .groupChat)
        let group = IMessageChat(id: 7, isGroup: true, service: "iMessage", participants: ["+15551234567", "+15550000000"])
        #expect(policy.evaluate(message(), chat: group, now: now, live: true) == .groupChat)
        #expect(policy.evaluate(message(), chat: nil, now: now, live: true) == .unknownChat)
        let sms = IMessageChat(id: 7, isGroup: false, service: "SMS", participants: ["+15551234567"])
        #expect(policy.evaluate(message(), chat: sms, now: now, live: true) == .notIMessage)
        #expect(policy.evaluate(message(sender: "+15559999999"), chat: direct, now: now, live: true) == .nonOwner)
        #expect(policy.evaluate(message(sender: ""), chat: direct, now: now, live: true) == .nonOwner)
        let spoofed = IMessageChat(id: 7, isGroup: false, service: "iMessage", participants: ["+15559999999"])
        #expect(policy.evaluate(message(), chat: spoofed, now: now, live: true) == .nonOwner)
        #expect(policy.evaluate(message(age: 601), chat: direct, now: now, live: false) == .stale)
        // Live messages are never stale: the clock may simply be ahead of chat.db.
        #expect(policy.evaluate(message(age: 601), chat: direct, now: now, live: true) == .accept(handle: owner))
    }

    @Test("rate limiter allows ten per minute per sender")
    func limiter() {
        var limiter = SlidingWindowLimiter(limit: 3, window: 60)
        let results = [("a", 0.0), ("a", 1), ("b", 1), ("a", 2), ("a", 3), ("a", 61)].map { key, offset in
            limiter.allow(key, at: now.addingTimeInterval(offset))
        }
        #expect(results == [true, true, true, true, false, true])
    }

    @Test("messages and chats decode from imsg's documented field names")
    func decoding() throws {
        let json = try JSONValue(data: Data(#"{"id":42,"chat_id":7,"guid":"ABC","sender":"+15551234567","is_from_me":false,"text":"hi","created_at":"2023-11-14T22:13:20Z","is_group":false}"#.utf8))
        let message = try #require(IMessageMessage(json: json))
        #expect(message.id == 42 && message.chatId == 7 && message.guid == "ABC" && message.sender == "+15551234567")
        #expect(message.createdAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(message.mutation == nil && !message.isReaction && message.isGroup == false)
        let edited = try JSONValue(data: Data(#"{"id":42,"chat_id":7,"type":"edited","is_reaction":true,"created_at":"2023-11-14T22:13:20.500Z"}"#.utf8))
        let update = try #require(IMessageMessage(json: edited))
        #expect(update.mutation == "edited" && update.isReaction)
        #expect(update.createdAt == Date(timeIntervalSince1970: 1_700_000_000.5))
        #expect(IMessageMessage(json: .object(["guid": .string("x")])) == nil)
        let chatJSON = try JSONValue(data: Data(#"{"id":7,"identifier":"+15551234567","guid":"iMessage;-;+15551234567","service":"iMessage","is_group":false,"participants":["+15551234567"]}"#.utf8))
        let chat = try #require(IMessageChat(json: chatJSON))
        #expect(chat == IMessageChat(id: 7, isGroup: false, service: "iMessage", participants: ["+15551234567"]))
    }

    @Test("long replies split on paragraphs and are capped with a pointer to the panel")
    func chunking() {
        #expect(IMessageChunker.chunks("  short  ") == ["short"])
        #expect(IMessageChunker.chunks("   ") == [])
        let paragraphs = (1...5).map { "Paragraph \($0) " + String(repeating: "word ", count: 40) }
        let chunks = IMessageChunker.chunks(paragraphs.joined(separator: "\n\n"), limit: 450, maxChunks: 6)
        #expect(chunks.count == 3)
        #expect(chunks.allSatisfy { $0.count <= 450 })
        #expect(chunks[0].hasPrefix("Paragraph 1") && chunks[0].contains("\n\nParagraph 2"))
        #expect(chunks[2].hasPrefix("Paragraph 5"))
        let wall = String(repeating: "abcdefghij ", count: 300)   // 3300 chars, no paragraphs
        let hard = IMessageChunker.chunks(wall, limit: 1000, maxChunks: 6)
        #expect(hard.count == 4)
        #expect(hard.allSatisfy { $0.count <= 1000 && !$0.hasPrefix(" ") })
        let huge = (1...20).map { "P\($0) " + String(repeating: "x", count: 900) }.joined(separator: "\n\n")
        let capped = IMessageChunker.chunks(huge, limit: 1000, maxChunks: 3)
        #expect(capped.count == 3)
        #expect(capped[2].hasSuffix(IMessageChunker.overflowNote))
        #expect(capped[2].count <= 1000)
    }
}

/// A scripted `imsg rpc`: canned results per method, notifications on demand.
nonisolated final class FakeIMessageTransport: JSONRPCTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var calls: [(method: String, params: JSONValue)] = []
    private var responders: [String: @Sendable (JSONValue) throws -> JSONValue] = [:]
    private var continuations: [UUID: AsyncStream<JSONRPCNotification>.Continuation] = [:]
    var startError: Error?

    func respond(_ method: String, _ responder: @escaping @Sendable (JSONValue) throws -> JSONValue) {
        lock.withLock { responders[method] = responder }
    }

    func start() async throws {
        if let startError { throw startError }
        lock.withLock { running = true }
    }

    func stop() async {
        let waiting = lock.withLock { () -> [AsyncStream<JSONRPCNotification>.Continuation] in
            running = false
            let values = Array(continuations.values)
            continuations.removeAll()
            return values
        }
        for continuation in waiting { continuation.finish() }
    }

    var isRunning: Bool { lock.withLock { running } }

    func call(_ method: String, params: JSONValue, timeout: Duration) async throws -> JSONValue {
        let responder = lock.withLock { () -> (@Sendable (JSONValue) throws -> JSONValue)? in
            calls.append((method, params))
            guard running else { return nil }
            return responders[method] ?? { _ in .object([:]) }
        }
        guard let responder else { throw JSONRPCError.notRunning }
        return try responder(params)
    }

    func notifications() async -> AsyncStream<JSONRPCNotification> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            lock.withLock { continuations[id] = continuation }
        }
    }

    func notify(_ method: String, _ params: JSONValue) {
        for continuation in lock.withLock({ Array(continuations.values) }) {
            continuation.yield(JSONRPCNotification(method: method, params: params))
        }
    }

    /// The helper died: every notification stream ends.
    func crash() {
        let waiting = lock.withLock { () -> [AsyncStream<JSONRPCNotification>.Continuation] in
            running = false
            let values = Array(continuations.values)
            continuations.removeAll()
            return values
        }
        for continuation in waiting { continuation.finish() }
    }

    func calls(for method: String) -> [JSONValue] { lock.withLock { calls.filter { $0.method == method }.map(\.params) } }
    var methods: [String] { lock.withLock { calls.map(\.method) } }
    var sentTexts: [String] { calls(for: "send").compactMap { $0["text"]?.stringValue } }
}

nonisolated final class InboundBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [InboundMessage] = []
    func append(_ message: InboundMessage) { lock.withLock { items.append(message) } }
    var all: [InboundMessage] { lock.withLock { items } }
    var texts: [String] { all.map(\.text) }
}

@Suite("IMessageChannel", .serialized)
struct IMessageChannelTests {

    private let owner = "+15551234567"
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private nonisolated func message(id: Int, text: String, sender: String? = nil, chatId: Int = 7, fromMe: Bool = false, at: Date? = nil, isGroup: Bool = false) -> JSONValue {
        let formatter = ISO8601DateFormatter()
        var fields: [String: JSONValue] = [
            "id": .number(Double(id)), "chat_id": .number(Double(chatId)), "guid": .string("guid-\(id)"),
            "sender": .string(sender ?? owner), "is_from_me": .bool(fromMe), "text": .string(text), "is_group": .bool(isGroup),
        ]
        if let at { fields["created_at"] = .string(formatter.string(from: at)) }
        return .object(fields)
    }

    private func makeChannel(transport: FakeIMessageTransport, clock: TestClock, cursor: LockedValue<Int>,
                             notices: LockedValue<[String]>? = nil, staleAfter: TimeInterval = 600) -> IMessageChannel {
        var config = IMessageChannel.Config(owners: { ["+1 (555) 123-4567"] })
        config.staleAfter = staleAfter
        config.appVersion = "t"
        config.now = { clock.now }
        config.loadCursor = { cursor.withValue { $0 } }
        config.saveCursor = { value in cursor.withValue { $0 = value } }
        config.notifyLocally = { title, _ in notices?.withValue { $0.append(title) } }
        return IMessageChannel(transport: transport, config: config)
    }

    private func readyTransport(chats: [Int: JSONValue] = [7: .object(["id": .number(7), "is_group": .bool(false), "service": .string("iMessage"), "participants": .array([.string("+15551234567")])])]) -> FakeIMessageTransport {
        let transport = FakeIMessageTransport()
        transport.respond("initialize") { _ in .object(["version": .string("9.9"), "database": .object(["ready": .bool(true)])]) }
        transport.respond("watch.subscribe") { _ in .object(["subscription": .number(1), "buffer_limit": .number(256)]) }
        transport.respond("send") { _ in .object(["ok": .bool(true)]) }
        transport.respond("chats.get") { params in
            guard let id = params["chat_id"]?.intValue, let chat = chats[id] else { throw JSONRPCError.remote(code: -32602, message: "Chat not found") }
            return chat
        }
        return transport
    }

    @Test("without Full Disk Access the channel waits and notifies once, running nothing")
    func databaseNotReady() async throws {
        let transport = FakeIMessageTransport()
        transport.respond("initialize") { _ in .object(["database": .object(["ready": .bool(false), "error": .string("permission denied")])]) }
        let notices = LockedValue<[String]>([])
        let channel = makeChannel(transport: transport, clock: TestClock(start), cursor: LockedValue(0), notices: notices)
        await channel.start()
        #expect(await waitUntil { if case .waitingForDatabase = await channel.status { return true }; return false })
        #expect(notices.withValue { $0 } == ["iMessage needs Full Disk Access"])
        #expect(transport.methods == ["initialize"])
        await channel.stop()
        #expect(await channel.status == .stopped)
    }

    @Test("first run starts at the tail, greets the owner, and filters live messages")
    func liveFiltering() async throws {
        let transport = readyTransport(chats: [
            7: .object(["id": .number(7), "is_group": .bool(false), "service": .string("iMessage"), "participants": .array([.string("+15551234567")])]),
            8: .object(["id": .number(8), "is_group": .bool(true), "service": .string("iMessage"), "participants": .array([.string("+15551234567"), .string("+15550000000")])]),
            9: .object(["id": .number(9), "is_group": .bool(false), "service": .string("SMS"), "participants": .array([.string("+15551234567")])]),
        ])
        let clock = TestClock(start)
        let cursor = LockedValue(0)
        let channel = makeChannel(transport: transport, clock: clock, cursor: cursor)
        let box = InboundBox()
        let consumer = Task { for await message in channel.inbound { box.append(message) } }
        defer { consumer.cancel() }

        await channel.start()
        #expect(await waitUntil { await channel.status == .running && transport.methods.contains("watch.subscribe") })
        #expect(transport.calls(for: "messages.after").isEmpty)                 // no cursor: nothing replayed
        #expect(transport.calls(for: "watch.subscribe").first == .object([:]))   // tail
        #expect(transport.sentTexts == ["Majoor is online (vt)."])
        #expect(await channel.helperVersion == "9.9")

        transport.notify("message", .object(["subscription": .number(1), "message": message(id: 101, text: " list files ", at: start)]))
        #expect(await waitUntil { box.texts == ["list files"] })
        #expect(box.all[0].threadKey == "imessage:+15551234567")
        #expect(box.all[0].sender == owner)
        #expect(cursor.withValue { $0 } == 101)

        transport.notify("message", .object(["subscription": .number(1), "message": message(id: 102, text: "echo", fromMe: true)]))
        transport.notify("message", .object(["subscription": .number(1), "message": message(id: 103, text: "group", chatId: 8)]))
        transport.notify("message", .object(["subscription": .number(1), "message": message(id: 104, text: "sms", chatId: 9)]))
        transport.notify("message", .object(["subscription": .number(1), "message": message(id: 105, text: "stranger", sender: "+15559999999")]))
        transport.notify("message", .object(["subscription": .number(1), "message": message(id: 106, text: "unknown chat", chatId: 99)]))
        transport.notify("message", .object(["subscription": .number(1), "message": message(id: 101, text: "duplicate guid", at: start)]))
        transport.notify("message", .object(["subscription": .number(1), "message": message(id: 107, text: "second", at: start)]))
        #expect(await waitUntil { box.texts == ["list files", "second"] })
        let dropped = await channel.dropped
        #expect(dropped["fromMe"] == 1 && dropped["groupChat"] == 1 && dropped["notIMessage"] == 1 && dropped["nonOwner"] == 1 && dropped["unknownChat"] == 1)
        #expect(cursor.withValue { $0 } == 107)
        #expect(await channel.acceptedCount == 2)

        // Replies go out as plain text with SMS fallback off, split only when long.
        try await channel.send(to: "imessage:+15551234567", text: "Done.", attachments: [])
        let send = try #require(transport.calls(for: "send").last)
        #expect(send["to"]?.stringValue == owner && send["text"]?.stringValue == "Done." && send["service"]?.stringValue == "imessage" && send["allow_sms_fallback"]?.boolValue == false)
        await channel.stop()
    }

    @Test("with a cursor, recent rows are replayed and old ones summarized; a trailing STOP still counts")
    func replay() async throws {
        let transport = readyTransport()
        let clock = TestClock(start)
        let cursor = LockedValue(500)
        transport.respond("messages.after") { params in
            let since = params["since_rowid"]?.intValue ?? -1
            let hourAgo = Date(timeIntervalSince1970: 1_700_000_000 - 3600)
            switch since {
            case 500:
                return .object(["messages": .array([
                    self.message(id: 501, text: "delete the build folder", at: hourAgo),
                    self.message(id: 502, text: "and the cache", at: hourAgo.addingTimeInterval(60)),
                ]), "next_rowid": .number(502), "has_more": .bool(true)])
            case 502:
                return .object(["messages": .array([
                    self.message(id: 503, text: "still here?", at: Date(timeIntervalSince1970: 1_700_000_000 - 120)),
                    self.message(id: 504, text: "stop", at: Date(timeIntervalSince1970: 1_700_000_000 - 1800)),
                ]), "next_rowid": .number(510), "has_more": .bool(false)])
            default:
                // The overflow replay resumes from the helper's cursor: nothing new.
                return .object(["messages": .array([]), "next_rowid": .number(Double(max(since, 510))), "has_more": .bool(false)])
            }
        }
        let channel = makeChannel(transport: transport, clock: clock, cursor: cursor)
        let box = InboundBox()
        let consumer = Task { for await message in channel.inbound { box.append(message) } }
        defer { consumer.cancel() }

        await channel.start()
        #expect(await waitUntil { transport.methods.contains("watch.subscribe") })
        #expect(await waitUntil { box.texts.count == 2 })
        #expect(box.texts == ["still here?", "stop"])     // recent one runs; STOP always runs when newest
        #expect(cursor.withValue { $0 } == 510)
        #expect(transport.calls(for: "watch.subscribe").first?["since_rowid"]?.intValue == 510)
        let summary = try #require(transport.sentTexts.first { $0.hasPrefix("I was offline and missed 3 messages") })
        #expect(summary.contains("Send them again if you still want them."))
        #expect(summary.contains("STOP"))
        #expect(!summary.contains("build folder"))

        // Overflow: resume from the helper's cursor, replay, resubscribe.
        transport.notify("watch.overflow", .object(["subscription": .number(1), "resume_after_rowid": .number(505), "terminal": .bool(true)]))
        #expect(await waitUntil { transport.calls(for: "messages.after").count == 3 })
        #expect(transport.calls(for: "messages.after").last?["since_rowid"]?.intValue == 505)
        #expect(await waitUntil { transport.calls(for: "watch.subscribe").count == 2 })
        await channel.stop()
    }

    @Test("when the helper exits the channel schedules a restart with backoff")
    func restarts() async throws {
        let transport = readyTransport()
        let channel = makeChannel(transport: transport, clock: TestClock(start), cursor: LockedValue(0))
        await channel.start()
        #expect(await waitUntil { await channel.status == .running })
        transport.crash()
        #expect(await waitUntil { await channel.status == .restarting(attempt: 1, inSeconds: 5) })
        await channel.stop()
        #expect(await channel.status == .stopped)
    }

    @Test("per-sender rate limit caps accepted messages at ten per minute")
    func rateLimit() async throws {
        let transport = readyTransport()
        let clock = TestClock(start)
        let channel = makeChannel(transport: transport, clock: clock, cursor: LockedValue(0))
        let box = InboundBox()
        let consumer = Task { for await message in channel.inbound { box.append(message) } }
        defer { consumer.cancel() }
        await channel.start()
        #expect(await waitUntil { await channel.status == .running })
        for index in 1...12 {
            transport.notify("message", .object(["message": message(id: 200 + index, text: "m\(index)", at: start)]))
        }
        #expect(await waitUntil { (await channel.dropped["rateLimited"] ?? 0) == 2 })
        #expect(box.texts.count == 10)
        clock.advance(61)
        transport.notify("message", .object(["message": message(id: 300, text: "later", at: start)]))
        #expect(await waitUntil { box.texts.last == "later" })
        await channel.stop()
    }

    // MARK: Questions (Phase 2 step 6h)

    private func startedChannel(transport: FakeIMessageTransport, box: InboundBox) async -> (IMessageChannel, Task<Void, Never>) {
        let channel = makeChannel(transport: transport, clock: TestClock(start), cursor: LockedValue(0))
        let consumer = Task { for await message in channel.inbound { box.append(message) } }
        await channel.start()
        _ = await waitUntil { await channel.status == .running && transport.methods.contains("watch.subscribe") }
        return (channel, consumer)
    }

    private func questionCode(in texts: [String]) -> String? {
        for text in texts {
            if let open = text.range(of: "Question ["), let close = text[open.upperBound...].firstIndex(of: "]") {
                return String(text[open.upperBound..<close])
            }
        }
        return nil
    }

    @Test("a question goes out with a code and options; the owner's number answers it and is never a task")
    func askByOption() async throws {
        let transport = readyTransport()
        let box = InboundBox()
        let (channel, consumer) = await startedChannel(transport: transport, box: box)
        defer { consumer.cancel() }
        let thread = "imessage:+15551234567"
        let asking = Task { await channel.ask(threadKey: thread, question: "Which color?", options: ["Red", "Blue"], timeout: .seconds(60)) }
        #expect(await waitUntil { transport.sentTexts.contains { $0.hasPrefix("Question [") } })
        let sent = try #require(transport.sentTexts.last)
        #expect(sent.contains("Which color?") && sent.contains("1. Red") && sent.contains("2. Blue") && sent.contains("1 min"))
        let code = try #require(questionCode(in: transport.sentTexts))
        #expect(code.count == 4)

        transport.notify("message", .object(["subscription": .number(1), "message": message(id: 201, text: "hello there", at: start)]))
        #expect(await waitUntil { box.texts == ["hello there"] })            // unrelated: still a task
        transport.notify("message", .object(["subscription": .number(1), "message": message(id: 202, text: "2", at: start)]))
        let answer = await asking.value
        #expect(answer == Answer(text: "Blue", option: "Blue", timedOut: false))
        #expect(box.texts == ["hello there"])                                  // the answer was consumed
        #expect(await channel.answeredQuestions == 1)
        transport.notify("message", .object(["subscription": .number(1), "message": message(id: 203, text: "1", at: start)]))
        #expect(await waitUntil { box.texts == ["hello there", "1"] })          // nothing pending: a task again
        await channel.stop()
    }

    @Test("a reply that starts with the code is a free answer; a stranger's reply and STOP are not answers")
    func askFreeText() async throws {
        let transport = readyTransport()
        let box = InboundBox()
        let (channel, consumer) = await startedChannel(transport: transport, box: box)
        defer { consumer.cancel() }
        let thread = "imessage:+15551234567"
        let asking = Task { await channel.ask(threadKey: thread, question: "Where should the file go?", options: [], timeout: .seconds(60)) }
        #expect(await waitUntil { transport.sentTexts.contains { $0.hasPrefix("Question [") } })
        let code = try #require(questionCode(in: transport.sentTexts))
        #expect(transport.sentTexts.last?.contains("Start your reply with \(code)") == true)
        transport.notify("message", .object(["subscription": .number(1), "message": message(id: 301, text: "\(code) nowhere", sender: "+15559999999", at: start)]))
        transport.notify("message", .object(["subscription": .number(1), "message": message(id: 302, text: "stop", at: start)]))
        #expect(await waitUntil { box.texts == ["stop"] })
        transport.notify("message", .object(["subscription": .number(1), "message": message(id: 303, text: "\(code.lowercased()): ~/Desktop/out", at: start)]))
        let answer = await asking.value
        #expect(answer == Answer(text: "~/Desktop/out", option: nil, timedOut: false))
        #expect(box.texts == ["stop"])
        await channel.stop()
    }

    @Test("a second question on a busy thread is refused, a cancelled question resolves, a quiet owner times out")
    func askTimeoutAndConcurrency() async throws {
        let transport = readyTransport()
        let box = InboundBox()
        let (channel, consumer) = await startedChannel(transport: transport, box: box)
        defer { consumer.cancel() }
        let thread = "imessage:+15551234567"
        let first = Task { await channel.ask(threadKey: thread, question: "First?", options: ["A"], timeout: .seconds(30)) }
        #expect(await waitUntil { transport.sentTexts.contains { $0.contains("First?") } })
        let second = await channel.ask(threadKey: thread, question: "Second?", options: [], timeout: .seconds(30))
        #expect(second == .unanswered)
        #expect(!transport.sentTexts.contains { $0.contains("Second?") })
        first.cancel()
        #expect(await first.value == .unanswered)
        transport.notify("message", .object(["subscription": .number(1), "message": message(id: 401, text: "A", at: start)]))
        #expect(await waitUntil { box.texts == ["A"] })                          // nothing pending any more

        let quick = await channel.ask(threadKey: thread, question: "Quick?", options: [], timeout: .milliseconds(200))
        #expect(quick.timedOut)
        await channel.stop()
    }

    @Test("answers match by number, option text, or code prefix; anything else is a task")
    func matchAnswer() {
        let options = ["Keep the draft", "Delete it"]
        #expect(IMessageChannel.matchAnswer("2", code: "Q7K2", options: options)?.option == "Delete it")
        #expect(IMessageChannel.matchAnswer("1.", code: "Q7K2", options: options)?.option == "Keep the draft")
        #expect(IMessageChannel.matchAnswer("delete IT", code: "Q7K2", options: options)?.option == "Delete it")
        #expect(IMessageChannel.matchAnswer("3", code: "Q7K2", options: options) == nil)
        #expect(IMessageChannel.matchAnswer("please delete it", code: "Q7K2", options: options) == nil)
        #expect(IMessageChannel.matchAnswer("q7k2 keep the draft", code: "Q7K2", options: options) == Answer(text: "keep the draft", option: "Keep the draft", timedOut: false))
        #expect(IMessageChannel.matchAnswer("Q7K2: neither, ask tomorrow", code: "Q7K2", options: options) == Answer(text: "neither, ask tomorrow", option: nil, timedOut: false))
        #expect(IMessageChannel.matchAnswer("Q7K2", code: "Q7K2", options: []) == Answer(text: nil, option: nil, timedOut: false))
        #expect(IMessageChannel.matchAnswer("yes Q7K2", code: "Q7K2", options: []) == nil)
        #expect(IMessageChannel.matchAnswer("", code: "Q7K2", options: options) == nil)
    }
}

@Suite("JSONRPCLineClient over a child process", .serialized)
struct JSONRPCLineClientTests {

    /// A tiny JSON-RPC echo server: replies to every request with its params,
    /// emits a notification when asked, and exits on "quit".
    private static let server = """
    import sys, json
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except Exception:
            sys.stdout.write("garbage\\n"); sys.stdout.flush(); continue
        m = req.get("method")
        if m == "quit":
            sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": req["id"], "result": {"bye": True}}) + "\\n"); sys.stdout.flush()
            break
        if m == "ping.notify":
            sys.stdout.write(json.dumps({"jsonrpc": "2.0", "method": "tick", "params": {"n": 1}}) + "\\n")
        if m == "fail":
            sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": req["id"], "error": {"code": -32602, "message": "nope"}}) + "\\n"); sys.stdout.flush(); continue
        if m == "slow":
            continue
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": req["id"], "result": {"echo": req.get("params", {})}}) + "\\n"); sys.stdout.flush()
    """

    @Test("requests, errors, notifications, timeouts and exit")
    func roundTrip() async throws {
        let client = JSONRPCLineClient(command: "/usr/bin/python3", arguments: ["-c", Self.server], label: "echo")
        try await client.start()
        #expect(await client.isRunning)
        let notifications = await client.notifications()
        let ticks = LockedValue<[JSONRPCNotification]>([])
        let collector = Task { for await note in notifications { ticks.withValue { $0.append(note) } } }
        defer { collector.cancel() }

        let echo = try await client.call("hello", params: .object(["a": .number(1), "b": .string("x")]), timeout: .seconds(5))
        #expect(echo["echo"]?["a"]?.intValue == 1)
        #expect(echo["echo"]?["b"]?.stringValue == "x")
        let empty = try await client.call("none", params: .object([:]), timeout: .seconds(5))
        #expect(empty["echo"] == .object([:]))

        await #expect(throws: JSONRPCError.remote(code: -32602, message: "nope")) {
            _ = try await client.call("fail", params: .object([:]), timeout: .seconds(5))
        }
        _ = try await client.call("ping.notify", params: .object([:]), timeout: .seconds(5))
        #expect(await waitUntil { ticks.withValue { $0 } == [JSONRPCNotification(method: "tick", params: .object(["n": .number(1)]))] })
        await #expect(throws: JSONRPCError.timeout) {
            _ = try await client.call("slow", params: .object([:]), timeout: .milliseconds(300))
        }
        _ = try await client.call("quit", params: .object([:]), timeout: .seconds(5))
        #expect(await waitUntil { await !client.isRunning })
        await #expect(throws: JSONRPCError.notRunning) {
            _ = try await client.call("hello", params: .object([:]), timeout: .seconds(1))
        }
        await client.stop()
    }

    @Test("a missing binary fails to start with an actionable message")
    func missing() async throws {
        let client = JSONRPCLineClient(command: "definitely-not-a-real-binary-\(UUID().uuidString)", arguments: [])
        await #expect(throws: JSONRPCError.self) { try await client.start() }
        #expect(await !client.isRunning)
    }
}
