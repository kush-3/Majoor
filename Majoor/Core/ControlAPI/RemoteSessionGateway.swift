// RemoteSessionGateway.swift
// Majoor — SessionGateway over the control API (client mode)
//
// The same shape the panel uses in-process, backed by RemoteRuntimeClient.
// Sessions it starts live on the runtime; their events arrive through the
// client's update stream, not a local EventBus.

import Foundation

nonisolated struct RemoteSessionGateway: SessionGateway {

    static let channelId = "control"

    let client: RemoteRuntimeClient

    init(client: RemoteRuntimeClient) {
        self.client = client
    }

    /// The runtime keys thread history by this; it matches the server's own
    /// default for a client that sends no thread key.
    func defaultThreadKey() async -> String {
        "client:\(await client.currentCredentials?.clientId ?? "unpaired")"
    }

    func submit(_ text: String, threadKey: String) async throws -> SessionInfo {
        let ack = try await client.submit(text: text, threadKey: threadKey)
        return SessionInfo(id: ack.sessionId, shortId: ack.shortId, kind: .task, state: .queued, input: text,
                           origin: ChannelRef(channelId: Self.channelId, threadKey: threadKey))
    }

    func stop(shortId: Int?) async -> [Int] {
        var sessionId: SessionID? = nil
        if let shortId {
            guard let info = (try? await client.sessions())?.first(where: { $0.shortId == shortId }) else { return [] }
            sessionId = info.id
        }
        return (try? await client.stopSessions(sessionId: sessionId)) ?? []
    }

    func answerApproval(id: String, nonce: String?, decision: ApprovalDecision) async -> AgentSession.AnswerResult {
        guard let nonce else { return .badNonce }
        return await client.answerApproval(id: id, nonce: nonce, decision: decision)
    }

    func list() async -> [SessionInfo] {
        (try? await client.sessions()) ?? []
    }

    func pendingApprovals() async -> [ApprovalRequest] {
        await client.lastSnapshot?.pendingApprovals ?? []
    }

    func recentTasks(limit: Int) async -> [TaskSnapshot] {
        Array((await client.lastSnapshot?.recentTasks ?? []).prefix(limit))
    }

    /// Events as the runtime publishes them. The client already dedupes by
    /// seq and resumes from its cursor, so `since` only filters older items.
    func events(since: Int?) async -> EventBus.Subscription {
        let updates = await client.updates()
        let stream = AsyncStream<SequencedEvent> { continuation in
            let task = Task {
                for await update in updates {
                    if case .event(let item) = update, since.map({ item.seq > $0 }) ?? true {
                        continuation.yield(item)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
        return EventBus.Subscription(id: UUID(), snapshotRequired: true, replay: [], stream: stream)
    }
}
