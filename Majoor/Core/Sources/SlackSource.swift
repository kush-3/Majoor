// SlackSource.swift
// Majoor — Slack messages as events (Phase 2 step 4c)
//
// Slack is an MCP server, not a native connector, so the source polls the
// bridged tools every 30 minutes for the channels the owner listed in
// Settings (UserDefaults `slackSourceChannels`, by id or name). It is off
// while that list is empty. The cursor is the newest `ts` seen per channel.
// Native Socket Mode is Phase 3's remote-MCP work.

import Foundation

nonisolated struct SlackChannelRef: Sendable, Equatable {
    var id: String
    var name: String
}

nonisolated struct SlackMessageSummary: Sendable, Equatable {
    var ts: String
    var user: String
    var text: String
}

nonisolated enum SlackSourceError: Error, Sendable, Equatable {
    case notRunning(String)
    case badResponse(String)
}

/// The two Slack reads the source needs. `LiveSlackReader` goes through the
/// MCP server; tests script one.
nonisolated protocol SlackReading: Sendable {
    func listChannels() async throws -> [SlackChannelRef]
    func history(channelId: String, limit: Int) async throws -> [SlackMessageSummary]
}

actor SlackSource: EventSource {

    static let sourceId = "slack"
    static let channelsKey = "slackSourceChannels"
    static let defaultInterval: Duration = .seconds(30 * 60)
    static let historyLimit = 50
    static let textCap = 2_000

    nonisolated let id = SlackSource.sourceId
    nonisolated let dataClass: DataClass = .messages
    nonisolated let events: AsyncStream<SourceEvent>
    private let continuation: AsyncStream<SourceEvent>.Continuation

    private let reader: any SlackReading
    private let cursors: any SourceCursorStore
    private let channels: @Sendable () -> [String]
    private let interval: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> Date

    private var known: [SlackChannelRef] = []
    private(set) var lastPollAt: Date?
    private(set) var lastError: String?

    /// Channel entries from Settings: one per line or comma, ids or names.
    static func parseChannelList(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")) }
            .filter { !$0.isEmpty }
    }

    init(reader: any SlackReading, cursors: any SourceCursorStore,
         channels: @escaping @Sendable () -> [String] = { SlackSource.parseChannelList(UserDefaults.standard.string(forKey: SlackSource.channelsKey) ?? "") },
         interval: Duration = SlackSource.defaultInterval,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.reader = reader
        self.cursors = cursors
        self.channels = channels
        self.interval = interval
        self.sleep = sleep
        self.now = now
        (events, continuation) = AsyncStream.makeStream(of: SourceEvent.self, bufferingPolicy: .unbounded)
    }

    func start() async throws {
        while !Task.isCancelled {
            let wanted = channels()
            if !wanted.isEmpty { try await poll(wanted) }
            try await sleep(interval)
        }
    }

    func stop() async {}

    /// One poll over the listed channels.
    func poll(_ wanted: [String]) async throws {
        lastPollAt = now()
        do {
            var cursorMap = loadCursors()
            for entry in wanted {
                guard let channel = try await resolve(entry) else {
                    MajoorLogger.log("💬 Slack source: no channel matches '\(entry)'")
                    continue
                }
                let messages = try await reader.history(channelId: channel.id, limit: Self.historyLimit)
                // The first poll of a channel only anchors: fifty old messages
                // are not "new". After that, everything later than the cursor is.
                if let last = cursorMap[channel.id] {
                    let fresh = messages.filter { Self.isLater($0.ts, than: last) }.sorted { Self.isLater($1.ts, than: $0.ts) }
                    for message in fresh {
                        continuation.yield(SourceEvent(sourceId: id, kind: .slackMessage, at: now(), payload: Self.payload(message, channel: channel)))
                    }
                }
                if let newest = messages.map(\.ts).max(by: { Self.isLater($1, than: $0) }) {
                    cursorMap[channel.id] = newest
                } else if cursorMap[channel.id] == nil {
                    cursorMap[channel.id] = "0"
                }
            }
            saveCursors(cursorMap)
            lastError = nil
        } catch {
            lastError = "\(error)"
            throw error
        }
    }

    /// Slack `ts` values are "seconds.sequence" strings; compare numerically.
    static func isLater(_ a: String, than b: String) -> Bool {
        (Double(a) ?? 0) > (Double(b) ?? 0)
    }

    private func resolve(_ entry: String) async throws -> SlackChannelRef? {
        if let match = known.first(where: { $0.id == entry || $0.name.caseInsensitiveCompare(entry) == .orderedSame }) { return match }
        if Self.looksLikeChannelId(entry) { return SlackChannelRef(id: entry, name: entry) }
        known = try await reader.listChannels()
        return known.first { $0.id == entry || $0.name.caseInsensitiveCompare(entry) == .orderedSame }
    }

    static func looksLikeChannelId(_ text: String) -> Bool {
        text.count >= 9 && (text.hasPrefix("C") || text.hasPrefix("G") || text.hasPrefix("D")) && text.allSatisfy { $0.isUppercase || $0.isNumber }
    }

    private func loadCursors() -> [String: String] {
        guard let raw = cursors.cursor(for: id), let data = raw.data(using: .utf8),
              let value = try? JSONValue(data: data), let object = value.objectValue else { return [:] }
        return object.compactMapValues(\.stringValue)
    }

    private func saveCursors(_ map: [String: String]) {
        guard let data = try? JSONValue.object(map.mapValues { .string($0) }).data() else { return }
        cursors.setCursor(String(decoding: data, as: UTF8.self), for: id)
    }

    /// Message text is framed; author and channel are cleaned.
    static func payload(_ message: SlackMessageSummary, channel: SlackChannelRef) -> JSONValue {
        .object([
            "channelId": .string(channel.id),
            "channel": .string(String(UntrustedContent.stripControlCharacters(channel.name).prefix(100))),
            "author": .string(String(UntrustedContent.stripControlCharacters(message.user).prefix(100))),
            "ts": .string(message.ts),
            "text": .string(UntrustedContent.wrap(label: "slack message", source: "slack", text: message.text, limit: textCap)),
        ])
    }
}

// MARK: - Live reader

/// The Slack MCP server's `slack_list_channels` and `slack_get_channel_history`.
nonisolated struct LiveSlackReader: SlackReading {

    static let serverName = "slack"

    func listChannels() async throws -> [SlackChannelRef] {
        let json = try await call("slack_list_channels", ["limit": .number(200)])
        let items = json["channels"]?.arrayValue ?? json.arrayValue ?? []
        return items.compactMap { item in
            guard let id = item["id"]?.stringValue else { return nil }
            return SlackChannelRef(id: id, name: item["name"]?.stringValue ?? id)
        }
    }

    func history(channelId: String, limit: Int) async throws -> [SlackMessageSummary] {
        let json = try await call("slack_get_channel_history", ["channel_id": .string(channelId), "limit": .number(Double(limit))])
        let items = json["messages"]?.arrayValue ?? json.arrayValue ?? []
        return items.compactMap { item in
            guard let ts = item["ts"]?.stringValue else { return nil }
            return SlackMessageSummary(ts: ts, user: item["user"]?.stringValue ?? item["username"]?.stringValue ?? "unknown",
                                       text: item["text"]?.stringValue ?? "")
        }
    }

    private func call(_ tool: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
        do {
            try await MCPServerManager.shared.ensureRunning(Self.serverName)
        } catch {
            throw SlackSourceError.notRunning("\(error.localizedDescription)")
        }
        guard let client = await MCPServerManager.shared.client(for: Self.serverName) else {
            throw SlackSourceError.notRunning("the Slack MCP server is not running")
        }
        // `callTool` takes Foundation objects; build them here, fresh, so the
        // value can be sent into the actor.
        let encoded = try JSONValue.object(arguments).data()
        guard let anyArgs = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw SlackSourceError.badResponse("could not encode arguments for \(tool)")
        }
        let result = try await client.callTool(name: tool, arguments: anyArgs)
        guard !result.isError else { throw SlackSourceError.badResponse(String(result.content.prefix(300))) }
        guard let data = result.content.data(using: .utf8), let json = try? JSONValue(data: data) else {
            throw SlackSourceError.badResponse("\(tool) did not return JSON")
        }
        return json
    }
}
