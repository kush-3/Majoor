// GmailSource.swift
// Majoor — New mail as events (Phase 2 step 4c)
//
// Every three minutes: `history.list` from the stored historyId. Without a
// cursor, or when Gmail answers 404 because the history is too old, fall
// back to `messages.list q=newer_than:1d` and re-anchor at the profile's
// current historyId. Only metadata is emitted (from, subject, date, labels,
// thread); a job that needs a body asks `fetchBody(id:)`, so meta-only jobs
// never pull one. Sent mail, drafts, chat, spam and trash are not "new mail".

import Foundation

nonisolated struct GmailMessageMeta: Sendable, Codable, Equatable {
    var id: String
    var threadId: String
    var from: String
    var subject: String
    var date: String
    var labels: [String]
    var snippet: String?

    /// Labels Gmail puts on mail the owner wrote or does not want.
    static let ignoredLabels: Set<String> = ["SENT", "DRAFT", "CHAT", "SPAM", "TRASH"]

    var isInbound: Bool { labels.allSatisfy { !Self.ignoredLabels.contains($0) } }
}

nonisolated struct GmailHistoryPage: Sendable, Equatable {
    var newMessageIds: [String]
    var historyId: String
}

nonisolated enum GmailSourceError: Error, Sendable, Equatable {
    case historyExpired
    case http(Int)
    case badResponse(String)
}

/// The Gmail calls the source needs. `LiveGmailReader` talks to the API;
/// tests script one.
nonisolated protocol GmailReading: Sendable {
    func currentHistoryId() async throws -> String
    /// Throws `GmailSourceError.historyExpired` when Gmail no longer has the start id.
    func history(since historyId: String) async throws -> GmailHistoryPage
    func recentMessageIds(query: String) async throws -> [String]
    func messageMeta(id: String) async throws -> GmailMessageMeta
    func messageBody(id: String) async throws -> String
}

actor GmailSource: EventSource {

    static let sourceId = "gmail"
    static let defaultInterval: Duration = .seconds(180)
    static let reanchorQuery = "newer_than:1d"
    static let seenCapacity = 5_000
    static let metaFieldCap = 500

    nonisolated let id = GmailSource.sourceId
    nonisolated let dataClass: DataClass = .emailMeta
    nonisolated let events: AsyncStream<SourceEvent>
    private let continuation: AsyncStream<SourceEvent>.Continuation

    private let reader: any GmailReading
    private let cursors: any SourceCursorStore
    private let interval: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> Date

    private var seen: Set<String> = []
    private var seenOrder: [String] = []
    private(set) var lastPollAt: Date?
    private(set) var lastError: String?
    private(set) var pollCount = 0

    init(reader: any GmailReading, cursors: any SourceCursorStore, interval: Duration = GmailSource.defaultInterval,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.reader = reader
        self.cursors = cursors
        self.interval = interval
        self.sleep = sleep
        self.now = now
        (events, continuation) = AsyncStream.makeStream(of: SourceEvent.self, bufferingPolicy: .unbounded)
    }

    func start() async throws {
        while !Task.isCancelled {
            try await poll()
            try await sleep(interval)
        }
    }

    func stop() async {}

    /// One poll. Public so a job (or a test) can ask for "now".
    func poll() async throws {
        pollCount += 1
        lastPollAt = now()
        do {
            if let cursor = cursors.cursor(for: id) {
                do {
                    let page = try await reader.history(since: cursor)
                    try await emit(ids: page.newMessageIds, backfill: false)
                    cursors.setCursor(page.historyId, for: id)
                    lastError = nil
                    return
                } catch GmailSourceError.historyExpired {
                    MajoorLogger.log("📬 Gmail history \(cursor) expired; re-anchoring")
                }
            }
            let ids = try await reader.recentMessageIds(query: Self.reanchorQuery)
            try await emit(ids: ids, backfill: true)
            let anchor = try await reader.currentHistoryId()
            cursors.setCursor(anchor, for: id)
            lastError = nil
        } catch {
            lastError = "\(error)"
            throw error
        }
    }

    /// The body, framed. Never stored, never in an event payload.
    func fetchBody(id messageId: String) async throws -> String {
        let body = try await reader.messageBody(id: messageId)
        return UntrustedContent.wrap(label: "email body", source: "gmail", text: body)
    }

    private func emit(ids: [String], backfill: Bool) async throws {
        for messageId in ids where !seen.contains(messageId) {
            remember(messageId)
            let meta = try await reader.messageMeta(id: messageId)
            guard meta.isInbound else { continue }
            continuation.yield(SourceEvent(sourceId: id, kind: .newEmail, at: now(), payload: Self.payload(meta, backfill: backfill)))
        }
    }

    private func remember(_ messageId: String) {
        seen.insert(messageId)
        seenOrder.append(messageId)
        if seenOrder.count > Self.seenCapacity {
            let excess = seenOrder.count - Self.seenCapacity
            for id in seenOrder.prefix(excess) { seen.remove(id) }
            seenOrder.removeFirst(excess)
        }
    }

    /// Header fields are outside text too: control characters out, length
    /// capped. The job runner frames them with `UntrustedContent` when it
    /// builds a prompt; `backfill` marks mail found by re-anchoring rather
    /// than seen arrive.
    static func payload(_ meta: GmailMessageMeta, backfill: Bool) -> JSONValue {
        func clean(_ text: String) -> JSONValue {
            .string(String(UntrustedContent.stripControlCharacters(text).prefix(metaFieldCap)))
        }
        var object: [String: JSONValue] = [
            "messageId": .string(meta.id),
            "threadId": .string(meta.threadId),
            "from": clean(meta.from),
            "subject": clean(meta.subject),
            "date": clean(meta.date),
            "labels": .array(meta.labels.map { .string($0) }),
            "backfill": .bool(backfill),
        ]
        if let snippet = meta.snippet { object["snippet"] = clean(snippet) }
        return .object(object)
    }
}

// MARK: - Live reader

/// The real API through `GmailAPI` and the owner's OAuth tokens.
nonisolated struct LiveGmailReader: GmailReading {

    static let historyPageLimit = 5

    func currentHistoryId() async throws -> String {
        let json = try await object("/profile")
        guard let historyId = json["historyId"]?.stringValue ?? json["historyId"]?.intValue.map(String.init) else {
            throw GmailSourceError.badResponse("profile without historyId")
        }
        return historyId
    }

    func history(since historyId: String) async throws -> GmailHistoryPage {
        var ids: [String] = []
        var newest = historyId
        var pageToken: String?
        for _ in 0..<Self.historyPageLimit {
            var path = "/history?startHistoryId=\(historyId)&historyTypes=messageAdded&maxResults=500"
            if let pageToken { path += "&pageToken=\(pageToken)" }
            let (data, status) = try await GmailAPI.request(path)
            if status == 404 { throw GmailSourceError.historyExpired }
            guard (200...299).contains(status) else { throw GmailSourceError.http(status) }
            let json = try Self.decode(data)
            for entry in json["history"]?.arrayValue ?? [] {
                for added in entry["messagesAdded"]?.arrayValue ?? [] {
                    let labels = added["message"]?["labelIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
                    guard labels.allSatisfy({ !GmailMessageMeta.ignoredLabels.contains($0) }) else { continue }
                    if let id = added["message"]?["id"]?.stringValue, !ids.contains(id) { ids.append(id) }
                }
            }
            if let latest = json["historyId"]?.stringValue ?? json["historyId"]?.intValue.map(String.init) { newest = latest }
            pageToken = json["nextPageToken"]?.stringValue
            if pageToken == nil { break }
        }
        return GmailHistoryPage(newMessageIds: ids, historyId: newest)
    }

    func recentMessageIds(query: String) async throws -> [String] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let json = try await object("/messages?q=\(encoded)&maxResults=100")
        return (json["messages"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }.reversed()   // oldest first
    }

    func messageMeta(id: String) async throws -> GmailMessageMeta {
        let json = try await object("/messages/\(id)?format=metadata&metadataHeaders=From&metadataHeaders=Subject&metadataHeaders=Date")
        var headers: [String: String] = [:]
        for header in json["payload"]?["headers"]?.arrayValue ?? [] {
            if let name = header["name"]?.stringValue?.lowercased(), let value = header["value"]?.stringValue, headers[name] == nil {
                headers[name] = value
            }
        }
        return GmailMessageMeta(id: json["id"]?.stringValue ?? id,
                                threadId: json["threadId"]?.stringValue ?? "",
                                from: headers["from"] ?? "unknown",
                                subject: headers["subject"] ?? "(no subject)",
                                date: headers["date"] ?? "",
                                labels: json["labelIds"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                                snippet: json["snippet"]?.stringValue)
    }

    func messageBody(id: String) async throws -> String {
        let (data, status) = try await GmailAPI.request("/messages/\(id)?format=full")
        guard (200...299).contains(status) else { throw GmailSourceError.http(status) }
        guard let message = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GmailSourceError.badResponse("message \(id) is not an object")
        }
        return GmailAPI.extractBody(from: message)
    }

    private func object(_ path: String) async throws -> JSONValue {
        let (data, status) = try await GmailAPI.request(path)
        guard (200...299).contains(status) else { throw GmailSourceError.http(status) }
        return try Self.decode(data)
    }

    private static func decode(_ data: Data) throws -> JSONValue {
        do { return try JSONValue(data: data) } catch { throw GmailSourceError.badResponse("\(error)") }
    }
}
