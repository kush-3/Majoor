// ConfirmationManager.swift
// Majoor — Pending approval as the UI sees it
//
// Approvals are owned by sessions (Core/Runtime/AgentSession.swift); the
// panel renders them from SessionEvents and answers through
// SessionManager.answerApproval. This file keeps only the view-side value.

import Foundation

/// Context describing a pending approval for the UI to display.
struct ConfirmationContext: Identifiable {
    let id: String
    let title: String
    let body: String
    let category: String
    /// Short code a remote answer must repeat; shown for parity, not typed locally.
    let nonce: String
    let sessionId: SessionID?
    let isPipelinePlan: Bool
    /// How many approvals are waiting across all sessions, this one included.
    let pendingCount: Int

    init(id: String, title: String, body: String, category: String, nonce: String = "",
         sessionId: SessionID? = nil, isPipelinePlan: Bool = false, pendingCount: Int = 1) {
        self.id = id; self.title = title; self.body = body; self.category = category
        self.nonce = nonce; self.sessionId = sessionId; self.isPipelinePlan = isPipelinePlan; self.pendingCount = pendingCount
    }
}
