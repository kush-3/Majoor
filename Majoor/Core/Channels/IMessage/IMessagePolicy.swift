// IMessagePolicy.swift
// Majoor — Pure parts of the iMessage channel: message shapes, the inbound
// filter, the per-sender rate limit and reply chunking. No I/O, so every
// rule is table-testable.

import Foundation

/// A message as `imsg` emits it (docs/json.md). Only the fields the channel
/// decides on are kept; `service` lives on the chat, not the message.
nonisolated struct IMessageMessage: Sendable, Equatable {
    let id: Int
    let guid: String
    let chatId: Int
    let sender: String
    let isFromMe: Bool
    let text: String
    let createdAt: Date?
    let isReaction: Bool
    /// "edited" or "unsent" on live mutation updates; nil for new rows.
    let mutation: String?
    let isGroup: Bool?

    init(id: Int, guid: String, chatId: Int, sender: String, isFromMe: Bool, text: String, createdAt: Date?,
         isReaction: Bool = false, mutation: String? = nil, isGroup: Bool? = nil) {
        self.id = id; self.guid = guid; self.chatId = chatId; self.sender = sender; self.isFromMe = isFromMe
        self.text = text; self.createdAt = createdAt; self.isReaction = isReaction; self.mutation = mutation; self.isGroup = isGroup
    }

    init?(json: JSONValue) {
        guard let id = json["id"]?.intValue, let chatId = json["chat_id"]?.intValue else { return nil }
        self.init(id: id, guid: json["guid"]?.stringValue ?? "row-\(id)", chatId: chatId,
                  sender: json["sender"]?.stringValue ?? "", isFromMe: json["is_from_me"]?.boolValue ?? false,
                  text: json["text"]?.stringValue ?? "", createdAt: json["created_at"]?.stringValue.flatMap(Self.parseDate),
                  isReaction: json["is_reaction"]?.boolValue ?? false, mutation: json["type"]?.stringValue,
                  isGroup: json["is_group"]?.boolValue)
    }

    /// ISO8601DateFormatter is not Sendable, so one is made per call; a
    /// handful of messages a minute makes that free.
    static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

/// `chats.get` result: whether the thread is a direct iMessage chat with the owner.
nonisolated struct IMessageChat: Sendable, Equatable {
    let id: Int
    let isGroup: Bool
    let service: String
    let participants: [String]

    init(id: Int, isGroup: Bool, service: String, participants: [String]) {
        self.id = id; self.isGroup = isGroup; self.service = service; self.participants = participants
    }

    init?(json: JSONValue) {
        guard let id = json["id"]?.intValue else { return nil }
        self.init(id: id, isGroup: json["is_group"]?.boolValue ?? false, service: json["service"]?.stringValue ?? "",
                  participants: (json["participants"]?.arrayValue ?? []).compactMap(\.stringValue))
    }
}

/// PRD §5.7: only the owner, only in a direct iMessage chat, only live or
/// recent. Everything else is data and never reaches the SessionManager.
nonisolated struct IMessageInboundPolicy: Sendable {

    nonisolated enum Decision: Sendable, Equatable {
        case accept(handle: String)
        case fromMe, mutation, reaction, empty, groupChat, unknownChat, notIMessage, nonOwner, stale

        /// A chat lookup is needed before this can be decided.
        var needsChat: Bool { self == .unknownChat }

        var name: String {
            switch self {
            case .accept: return "accept"
            case .fromMe: return "fromMe"
            case .mutation: return "mutation"
            case .reaction: return "reaction"
            case .empty: return "empty"
            case .groupChat: return "groupChat"
            case .unknownChat: return "unknownChat"
            case .notIMessage: return "notIMessage"
            case .nonOwner: return "nonOwner"
            case .stale: return "stale"
            }
        }
    }

    let owners: [String]
    let staleAfter: TimeInterval

    init(owners: [String], staleAfter: TimeInterval) {
        self.owners = owners.map(TrustPolicy.normalize(handle:)).filter { !$0.isEmpty }
        self.staleAfter = staleAfter
    }

    func evaluate(_ message: IMessageMessage, chat: IMessageChat?, now: Date, live: Bool) -> Decision {
        if message.isFromMe { return .fromMe }           // our own sends echo back through chat.db
        if message.mutation != nil { return .mutation }
        if message.isReaction { return .reaction }
        if message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
        if message.isGroup == true { return .groupChat }
        guard let chat else { return .unknownChat }
        if chat.isGroup { return .groupChat }
        // Apple-authenticated sender identity only; SMS/RCS senders are spoofable (PRD T2).
        guard chat.service.lowercased() == "imessage" else { return .notIMessage }
        let handle = TrustPolicy.normalize(handle: message.sender)
        guard !handle.isEmpty, owners.contains(handle) else { return .nonOwner }
        // A direct chat's single external participant must be the owner too.
        let participants = chat.participants.map(TrustPolicy.normalize(handle:))
        if !participants.isEmpty, participants != [handle] { return .nonOwner }
        if !live, let createdAt = message.createdAt, now.timeIntervalSince(createdAt) > staleAfter { return .stale }
        return .accept(handle: handle)
    }
}

/// At most `limit` hits per `window` per key (PRD T5: bounded cost).
nonisolated struct SlidingWindowLimiter: Sendable {
    let limit: Int
    let window: TimeInterval
    private var hits: [String: [Date]] = [:]

    init(limit: Int, window: TimeInterval) {
        self.limit = limit
        self.window = window
    }

    mutating func allow(_ key: String, at now: Date) -> Bool {
        var recent = (hits[key] ?? []).filter { now.timeIntervalSince($0) < window }
        guard recent.count < limit else { hits[key] = recent; return false }
        recent.append(now)
        hits[key] = recent
        return true
    }
}

/// Long replies become a few messages split on paragraph boundaries; past
/// the cap the rest is in the panel. Nothing else is altered.
nonisolated enum IMessageChunker {
    static let defaultLimit = 1500
    static let defaultMaxChunks = 6
    static let overflowNote = "…full result is in the Majoor panel"

    static func chunks(_ text: String, limit: Int = defaultLimit, maxChunks: Int = defaultMaxChunks) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard trimmed.count > limit else { return [trimmed] }
        var chunks: [String] = []
        var current = ""
        func flush() {
            let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { chunks.append(piece) }
            current = ""
        }
        for paragraph in trimmed.components(separatedBy: "\n\n") {
            let pieces = paragraph.count <= limit ? [paragraph] : hardSplit(paragraph, limit: limit)
            for piece in pieces {
                if current.isEmpty {
                    current = piece
                } else if current.count + 2 + piece.count <= limit {
                    current += "\n\n" + piece
                } else {
                    flush()
                    current = piece
                }
            }
        }
        flush()
        guard chunks.count > maxChunks else { return chunks }
        var kept = Array(chunks.prefix(maxChunks))
        let room = max(0, limit - overflowNote.count - 1)
        let last = kept[maxChunks - 1]
        kept[maxChunks - 1] = (last.count > room ? String(last.prefix(room)) : last) + "\n" + overflowNote
        return kept
    }

    /// Splits one over-long paragraph at whitespace near the limit.
    private static func hardSplit(_ text: String, limit: Int) -> [String] {
        var result: [String] = []
        var remaining = Substring(text)
        while remaining.count > limit {
            let window = remaining.prefix(limit)
            let cut = window.lastIndex(where: { $0.isWhitespace }).map { window.distance(from: window.startIndex, to: $0) } ?? limit
            let at = cut > limit / 2 ? cut : limit
            let head = remaining.prefix(at)
            result.append(String(head).trimmingCharacters(in: .whitespacesAndNewlines))
            remaining = remaining.dropFirst(at)
        }
        let tail = String(remaining).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append(tail) }
        return result
    }
}
