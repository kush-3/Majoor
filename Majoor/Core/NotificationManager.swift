// NotificationManager.swift
// Majoor — Central Notification Handler
//
// Registers notification categories with action buttons,
// sends notifications, and routes user responses to ConfirmationManager.

import Foundation
import UserNotifications

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {

    static let shared = NotificationManager()

    // MARK: - Category IDs
    static let taskCompleteCategory = "TASK_COMPLETE"
    static let taskFailedCategory   = "TASK_FAILED"
    static let confirmEmailCategory = "CONFIRM_EMAIL"
    static let confirmDeleteCategory = "CONFIRM_DELETE"
    static let confirmGenericCategory = "CONFIRM_GENERIC"

    // MARK: - Action IDs
    static let actionView    = "ACTION_VIEW"
    static let actionRetry   = "ACTION_RETRY"
    static let actionApprove = "ACTION_APPROVE"
    static let actionDeny    = "ACTION_DENY"
    static let actionKeep    = "ACTION_KEEP"
    static let actionDelete  = "ACTION_DELETE"

    private override init() { super.init() }

    /// Register all notification categories and set self as delegate.
    /// Call once from AppDelegate on launch.
    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        // Task complete: "View" button
        let viewAction = UNNotificationAction(identifier: Self.actionView, title: "View", options: .foreground)
        let taskComplete = UNNotificationCategory(identifier: Self.taskCompleteCategory, actions: [viewAction], intentIdentifiers: [])

        // Task failed: "View Error" + "Retry"
        let viewError = UNNotificationAction(identifier: Self.actionView, title: "View Error", options: .foreground)
        let retry = UNNotificationAction(identifier: Self.actionRetry, title: "Retry", options: .foreground)
        let taskFailed = UNNotificationCategory(identifier: Self.taskFailedCategory, actions: [viewError, retry], intentIdentifiers: [])

        // Confirm email send: "Approve" + "Deny"
        let approve = UNNotificationAction(identifier: Self.actionApprove, title: "Send", options: .foreground)
        let deny = UNNotificationAction(identifier: Self.actionDeny, title: "Cancel", options: .destructive)
        let confirmEmail = UNNotificationCategory(identifier: Self.confirmEmailCategory, actions: [approve, deny], intentIdentifiers: [])

        // Confirm delete: "Delete" + "Keep"
        let deleteAction = UNNotificationAction(identifier: Self.actionDelete, title: "Delete", options: .destructive)
        let keepAction = UNNotificationAction(identifier: Self.actionKeep, title: "Keep", options: [])
        let confirmDelete = UNNotificationCategory(identifier: Self.confirmDeleteCategory, actions: [deleteAction, keepAction], intentIdentifiers: [])

        // Confirm generic: "Approve" + "Deny"
        let confirmGeneric = UNNotificationCategory(identifier: Self.confirmGenericCategory, actions: [approve, deny], intentIdentifiers: [])

        center.setNotificationCategories([taskComplete, taskFailed, confirmEmail, confirmDelete, confirmGeneric])

        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error { MajoorLogger.error("Notification auth error: \(error)") }
            MajoorLogger.log("Notifications authorized: \(granted)")
        }
    }

    // MARK: - Send Notifications

    func sendSimple(title: String, body: String, category: String = taskCompleteCategory) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = category

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func sendActionable(id: String, title: String, body: String, category: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = category
        content.userInfo = ["confirmationId": id]

        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Delegate (handle user tapping actions)

    /// Called when user taps a notification action button
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionId = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        let confirmationId = userInfo["confirmationId"] as? String

        if let confirmationId {
            let approved: Bool
            switch actionId {
            case Self.actionApprove, Self.actionDelete:
                approved = true
            case Self.actionDeny, Self.actionKeep:
                approved = false
            case UNNotificationDefaultActionIdentifier:
                // User tapped the notification itself (not an action button) — treat as view
                completionHandler()
                return
            default:
                completionHandler()
                return
            }

            Task {
                await ConfirmationManager.shared.resolve(id: confirmationId, approved: approved)
            }
        }

        // Handle "View" / default tap — post notification for UI to respond
        if actionId == Self.actionView || actionId == UNNotificationDefaultActionIdentifier {
            let taskId = userInfo["taskId"] as? String
            if let taskId {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .majoorOpenTaskDetail, object: nil, userInfo: ["taskId": taskId])
                }
            }
        }

        completionHandler()
    }

    /// Show notifications even when app is in foreground
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let majoorOpenTaskDetail = Notification.Name("majoorOpenTaskDetail")
}
