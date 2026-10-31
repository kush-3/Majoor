// Channel.swift
// Majoor — Where messages come from and go to
//
// A channel is a place the owner talks to Majoor from: the panel, an
// iMessage handle, a paired control client. It yields inbound messages,
// delivers text back to a thread, and can ask a question. The runtime
// treats every channel the same; only its trust level differs.

import Foundation

nonisolated struct InboundMessage: Sendable, Equatable {
    let channelId: String
    let threadKey: String
    /// Sender handle as the channel saw it ("" for local UI). TrustPolicy
    /// normalizes it before comparing with the owner.
    let sender: String
    let text: String
    let attachments: [URL]
    let receivedAt: Date

    init(channelId: String, threadKey: String, sender: String = "", text: String, attachments: [URL] = [], receivedAt: Date = Date()) {
        self.channelId = channelId; self.threadKey = threadKey; self.sender = sender
        self.text = text; self.attachments = attachments; self.receivedAt = receivedAt
    }
}

nonisolated struct Answer: Sendable, Equatable {
    let text: String?
    let option: String?
    let timedOut: Bool

    static let unanswered = Answer(text: nil, option: nil, timedOut: true)
}

nonisolated protocol Channel: Sendable {
    var id: String { get }
    var trust: ChannelTrust { get }
    /// One stream per channel, consumed by the ChannelRouter for the app's lifetime.
    var inbound: AsyncStream<InboundMessage> { get }
    func send(to threadKey: String, text: String, attachments: [URL]) async throws
    func ask(threadKey: String, question: String, options: [String], timeout: Duration) async -> Answer
}

extension Channel {
    nonisolated func send(to threadKey: String, text: String) async throws {
        try await send(to: threadKey, text: text, attachments: [])
    }

    /// Free-form questions arrive with the "I'm blocked" job in Phase 2;
    /// until then a channel that cannot ask simply reports no answer.
    nonisolated func ask(threadKey: String, question: String, options: [String], timeout: Duration) async -> Answer {
        .unanswered
    }
}
