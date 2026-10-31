// SessionGateway.swift
// Majoor — How a UI or an API talks to a runtime
//
// A channel is where messages come from; a gateway is the runtime they go
// to. The in-process gateway wraps SessionManager; the control server uses
// it on behalf of a paired client, and in client mode (step 5) a remote
// gateway speaks the same shape over the control API.

import Foundation

nonisolated enum GatewayError: Error, Sendable, Equatable {
    case unavailable
}

nonisolated protocol SessionGateway: Sendable {
    func submit(_ text: String, threadKey: String) async throws -> SessionInfo
    /// nil stops everything. Returns the short ids that were stopped.
    func stop(shortId: Int?) async -> [Int]
    func answerApproval(id: String, nonce: String?, decision: ApprovalDecision) async -> AgentSession.AnswerResult
    func list() async -> [SessionInfo]
    func pendingApprovals() async -> [ApprovalRequest]
    func recentTasks(limit: Int) async -> [TaskSnapshot]
    func events(since: Int?) async -> EventBus.Subscription
}

nonisolated struct LocalSessionGateway: SessionGateway {
    let manager: SessionManager
    let channelId: String
    let trust: ChannelTrust
    let tasks: TaskPersistence?

    init(manager: SessionManager, channelId: String, trust: ChannelTrust, tasks: TaskPersistence? = nil) {
        self.manager = manager; self.channelId = channelId; self.trust = trust; self.tasks = tasks
    }

    func submit(_ text: String, threadKey: String) async throws -> SessionInfo {
        guard let info = await manager.submit(input: text, origin: ChannelRef(channelId: channelId, threadKey: threadKey), trust: trust) else {
            throw GatewayError.unavailable
        }
        return info
    }

    func stop(shortId: Int?) async -> [Int] {
        if let shortId {
            return await manager.stop(shortId: shortId) ? [shortId] : []
        }
        let live = await manager.list().filter { !$0.state.isTerminal }.map(\.shortId)
        await manager.stopAll()
        return live
    }

    func answerApproval(id: String, nonce: String?, decision: ApprovalDecision) async -> AgentSession.AnswerResult {
        await manager.answerApproval(id: id, nonce: nonce, decision: decision, byChannel: channelId)
    }

    func list() async -> [SessionInfo] { await manager.list() }
    func pendingApprovals() async -> [ApprovalRequest] { await manager.pendingApprovals() }
    func recentTasks(limit: Int) async -> [TaskSnapshot] { tasks?.loadRecentSnapshots(limit: limit) ?? [] }
    func events(since: Int?) async -> EventBus.Subscription { await manager.bus.subscribe(since: since) }
}
