// ConfirmationManager.swift
// Majoor — Manages Pending Confirmations with async/await
//
// When a tool needs user confirmation (email send, calendar delete, pipeline),
// the agent loop suspends here until the user responds via in-app UI or notification.
// Confirmations are interactive: the user can provide text feedback alongside approve/deny.

import Foundation

/// Result of a user confirmation — includes optional text feedback.
nonisolated struct ConfirmationResult: Sendable {
    let approved: Bool
    let feedback: String?   // e.g. "send but change subject to X" or "no, do Y instead"
}

/// Context describing a pending confirmation for the UI to display.
struct ConfirmationContext: Identifiable {
    let id: String
    let title: String
    let body: String
    let category: String
}

actor ConfirmationManager {

    static let shared = ConfirmationManager()

    private var pendingConfirmations: [String: CheckedContinuation<ConfirmationResult, Never>] = [:]

    /// Called by the agent loop when a tool needs confirmation.
    /// Shows in-app UI (primary) and sends macOS notification (fallback).
    /// The optional `onPending` callback fires with the confirmation ID before suspending,
    /// allowing callers to show in-app UI alongside the notification fallback.
    func requestConfirmation(
        title: String,
        body: String,
        category: String,
        onPending: (@Sendable (String) -> Void)? = nil
    ) async -> ConfirmationResult {
        let id = UUID().uuidString

        // A task stopped while we were deciding (e.g. during Auto mode's
        // consent check) must not show a prompt that denyAll has already
        // drained past. No suspension point between this check and the
        // registration below, and denyAll is actor-serialized, so the race is
        // closed: either we see isCancelled here before any UI appears, or
        // denyAll runs after registration and resumes us as denied.
        if Task.isCancelled {
            return ConfirmationResult(approved: false, feedback: "Task was stopped by the user")
        }

        // Notify caller of the ID (for in-app UI display)
        onPending?(id)

        // Send the macOS notification as fallback (for when panel is closed)
        NotificationManager.shared.sendActionable(id: id, title: title, body: body, category: category)

        MajoorLogger.log("⏸ Waiting for user confirmation: \(title)")

        // Suspend until user responds (in-app or notification)
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<ConfirmationResult, Never>) in
            pendingConfirmations[id] = continuation
        }

        MajoorLogger.log(result.approved ? "✅ User approved: \(title)" : "❌ User denied: \(title)")
        if let feedback = result.feedback {
            MajoorLogger.log("💬 User feedback: \(feedback)")
        }
        return result
    }

    /// Deny every pending confirmation — called when the running task is
    /// stopped, so no continuation is left suspended forever and no stale
    /// prompt can later execute a tool for a dead task.
    func denyAll() {
        for (id, continuation) in pendingConfirmations {
            MajoorLogger.log("🚫 Denying stale confirmation \(id) — task stopped")
            continuation.resume(returning: ConfirmationResult(approved: false, feedback: "Task was stopped by the user"))
        }
        pendingConfirmations.removeAll()
    }

    /// Called by in-app UI or NotificationManager when user responds.
    func resolve(id: String, approved: Bool, feedback: String? = nil) {
        if let continuation = pendingConfirmations.removeValue(forKey: id) {
            let trimmedFeedback = feedback?.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = ConfirmationResult(
                approved: approved,
                feedback: (trimmedFeedback?.isEmpty == false) ? trimmedFeedback : nil
            )
            continuation.resume(returning: result)
        } else {
            MajoorLogger.log("⚠️ No pending confirmation for id: \(id)")
        }
    }
}
