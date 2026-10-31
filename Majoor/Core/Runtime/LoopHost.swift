// LoopHost.swift
// Majoor — What the agent loop needs from its session
//
// AgentLoop no longer knows about TaskManager, AgentTask or the
// confirmation manager. It records through its host's recorder, reads and
// writes conversation history through its host's thread, publishes events,
// and asks its host for approvals. AgentSession is the production host;
// tests provide a scripted one.

import Foundation

nonisolated protocol AgentLoopHost: Sendable {
    var sessionId: SessionID { get }
    var origin: ChannelRef { get }
    var trust: ChannelTrust { get }
    var budget: TokenBudget { get }
    var recorder: TaskRecorder { get }
    var history: ThreadHistory { get }
    /// The permission mode this session runs under. Remote text channels can
    /// never run in Auto (PRD §5.7 T1).
    var effectiveMode: PermissionMode { get }

    func emit(_ event: SessionEvent) async
    func requestApproval(_ draft: ApprovalDraft) async -> ApprovalDecision
}

extension AgentLoopHost {
    nonisolated var threadKey: String { origin.threadKey }
}

/// Task-local view of the running session, so tools (reminders, later the
/// connectors) can tell which channel and thread asked without a parameter
/// threaded through every call.
nonisolated struct SessionContext: Sendable {
    let sessionId: SessionID
    let origin: ChannelRef
    let trust: ChannelTrust

    @TaskLocal static var current: SessionContext?
}
