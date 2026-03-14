// UpdateManager.swift
// Majoor — Auto-Update via Sparkle 2

import Foundation
import Combine
import Sparkle
import UserNotifications

class UpdateManager: ObservableObject {

    private let updaterController: SPUStandardUpdaterController

    @Published var canCheckForUpdates = false

    init() {
        // startingUpdater: false — defer start so Sparkle doesn't hijack
        // UNUserNotificationCenter.delegate before NotificationManager sets it.
        // Call startUpdater() after NotificationManager.shared.configure().
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        // Observe canCheckForUpdates from the updater
        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    /// Start the Sparkle updater and then re-assert our notification delegate
    /// so Sparkle's SPUUserNotificationDriver doesn't override it.
    func startUpdater() {
        do {
            try updaterController.updater.start()
        } catch {
            MajoorLogger.error("Sparkle updater failed to start: \(error)")
        }

        // Re-assert our notification delegate after Sparkle has initialized,
        // since Sparkle's user driver sets itself as the delegate.
        DispatchQueue.main.async {
            UNUserNotificationCenter.current().delegate = NotificationManager.shared
        }
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    var automaticallyChecksForUpdates: Bool {
        get { updaterController.updater.automaticallyChecksForUpdates }
        set { updaterController.updater.automaticallyChecksForUpdates = newValue }
    }

    var lastUpdateCheckDate: Date? {
        updaterController.updater.lastUpdateCheckDate
    }
}
