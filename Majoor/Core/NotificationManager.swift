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
    static let pipelineConfirmCategory = "PIPELINE_CONFIRM"
    static let authErrorCategory       = "AUTH_ERROR"

    // MARK: - Action IDs
    static let actionView         = "ACTION_VIEW"
    static let actionRetry        = "ACTION_RETRY"
    static let actionApprove      = "ACTION_APPROVE"
    static let actionDeny         = "ACTION_DENY"
    static let actionKeep         = "ACTION_KEEP"
    static let actionDelete       = "ACTION_DELETE"
    static let actionOpenSettings = "ACTION_OPEN_SETTINGS"

    private override init() { super.init() }

    /// Register all notification categories and set self as delegate.
    /// Call once from AppDelegate on launch.
    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        // Clear stale delivered notifications — macOS throttles banners
        // when too many accumulate from the same app.
        center.removeAllDeliveredNotifications()

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

        // Pipeline confirm: "Go ahead" + "Cancel"
        let pipelineApprove = UNNotificationAction(identifier: Self.actionApprove, title: "Go ahead", options: .foreground)
        let pipelineDeny = UNNotificationAction(identifier: Self.actionDeny, title: "Cancel", options: .destructive)
        let pipelineConfirm = UNNotificationCategory(identifier: Self.pipelineConfirmCategory, actions: [pipelineApprove, pipelineDeny], intentIdentifiers: [])

        // Auth error: "Open Settings" button
        let openSettings = UNNotificationAction(identifier: Self.actionOpenSettings, title: "Open Settings", options: .foreground)
        let authError = UNNotificationCategory(identifier: Self.authErrorCategory, actions: [openSettings], intentIdentifiers: [])

        center.setNotificationCategories([taskComplete, taskFailed, confirmEmail, confirmDelete, confirmGeneric, pipelineConfirm, authError])

        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error { MajoorLogger.error("Notification auth error: \(error)") }
            MajoorLogger.log("Notifications authorized: \(granted)")

            // Log current notification settings for diagnostics
            center.getNotificationSettings { settings in
                MajoorLogger.log("Notification settings — auth: \(settings.authorizationStatus.rawValue), alert: \(settings.alertSetting.rawValue), banner: \(settings.alertStyle.rawValue), sound: \(settings.soundSetting.rawValue)")
            }
        }
    }

    // MARK: - Delegate Guard

    /// Re-assert ourselves as the UNUserNotificationCenter delegate.
    /// Sparkle's SPUUserNotificationDriver can override the delegate at any time,
    /// so we must check and re-set before every notification send.
    nonisolated private func ensureDelegate() {
        let center = UNUserNotificationCenter.current()
        let currentDelegate = center.delegate
        if !(currentDelegate is NotificationManager) {
            MajoorLogger.log("⚠️ Notification delegate was overridden by \(String(describing: type(of: currentDelegate))) — reclaiming")
            center.delegate = NotificationManager.shared
        }
    }

    // MARK: - Send Notifications

    nonisolated func sendSimple(title: String, body: String, category: String = taskCompleteCategory) {
        ensureDelegate()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = category

        let center = UNUserNotificationCenter.current()

        // Clear previous non-actionable notifications so they don't pile up
        // and trigger macOS banner throttling.
        center.removeAllDeliveredNotifications()

        let id = UUID().uuidString
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        MajoorLogger.log("📬 Sending notification: \(title) — \(body.prefix(80))")
        center.add(request) { error in
            if let error {
                MajoorLogger.error("❌ Notification delivery failed: \(error.localizedDescription)")
            } else {
                MajoorLogger.log("📬 Notification added to center: \(id)")
            }
        }
    }

    nonisolated func sendActionable(id: String, title: String, body: String, category: String) {
        ensureDelegate()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = category
        content.userInfo = ["confirmationId": id]

        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        MajoorLogger.log("📬 Sending actionable notification: \(title) [category: \(category), id: \(id)]")
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                MajoorLogger.error("❌ Actionable notification delivery failed: \(error.localizedDescription)")
            } else {
                MajoorLogger.log("📬 Notification delivered: \(id)")
            }
        }
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

        // Handle "Open Settings" action
        if actionId == Self.actionOpenSettings {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .majoorOpenSettings, object: nil)
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
        MajoorLogger.log("📬 willPresent called for: \(notification.request.content.title)")
        completionHandler([.banner, .sound, .list])
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let majoorOpenTaskDetail = Notification.Name("majoorOpenTaskDetail")
    static let majoorOpenSettings = Notification.Name("majoorOpenSettings")
    static let majoorOpenPanel = Notification.Name("majoorOpenPanel")
}
