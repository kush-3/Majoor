// ConfirmationManager.swift
// Majoor — Manages Pending Confirmations with async/await
//
// When a tool needs user confirmation (email send, calendar delete),
// the agent loop suspends here until the user responds via notification.

import Foundation

actor ConfirmationManager {

    static let shared = ConfirmationManager()

    private var pendingConfirmations: [String: CheckedContinuation<Bool, Never>] = [:]

    /// Called by the agent loop when a tool needs confirmation.
    /// Sends an actionable notification and suspends until the user responds.
    func requestConfirmation(
        title: String,
        body: String,
        category: String
    ) async -> Bool {
        let id = UUID().uuidString

        // Send the notification with action buttons
        NotificationManager.shared.sendActionable(id: id, title: title, body: body, category: category)

        MajoorLogger.log("⏸ Waiting for user confirmation: \(title)")

        // Suspend until user taps an action
        let approved = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            pendingConfirmations[id] = continuation
        }

        MajoorLogger.log(approved ? "✅ User approved: \(title)" : "❌ User denied: \(title)")
        return approved
    }

    /// Called by NotificationManager when user taps an action button.
    func resolve(id: String, approved: Bool) {
        if let continuation = pendingConfirmations.removeValue(forKey: id) {
            continuation.resume(returning: approved)
        } else {
            MajoorLogger.log("⚠️ No pending confirmation for id: \(id)")
        }
    }
}
