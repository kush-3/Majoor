// AccountsSettingsView.swift
// Majoor — Connected Accounts Management
//
// Gmail OAuth connection status + EventKit calendar permission status.

import SwiftUI
import EventKit

struct AccountsSettingsView: View {
    @State private var gmailConnected = false
    @State private var gmailEmail = ""
    @State private var isConnecting = false
    @State private var connectError = ""
    @State private var calendarStatus = EKAuthorizationStatus.notDetermined

    var body: some View {
        Form {
            // Gmail
            Section("Gmail") {
                if gmailConnected {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Connected")
                                .font(.system(size: 12, weight: .medium))
                            Text(gmailEmail)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Disconnect") { disconnectGmail() }
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                } else {
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                        Text("Not connected")
                            .font(.system(size: 12))
                        Spacer()
                        if isConnecting {
                            ProgressView()
                                .scaleEffect(0.7)
                        } else {
                            Button("Connect Gmail") { connectGmail() }
                                .font(.caption)
                        }
                    }
                    if !connectError.isEmpty {
                        Text(connectError)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            }

            // Calendar
            Section("Apple Calendar") {
                HStack {
                    Image(systemName: calendarStatusIcon)
                        .foregroundColor(calendarStatusColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(calendarStatusText)
                            .font(.system(size: 12, weight: .medium))
                        if calendarStatus == .denied || calendarStatus == .restricted {
                            Text("Grant access in System Settings > Privacy & Security > Calendars")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    if calendarStatus == .fullAccess || calendarStatus == .authorized {
                        // Already granted
                    } else if calendarStatus == .denied || calendarStatus == .restricted {
                        Button("Open Settings") { openCalendarSettings() }
                            .font(.caption)
                    } else {
                        Button("Request Access") { requestCalendarAccess() }
                            .font(.caption)
                    }
                }
            }

            Section {
                Text("Connected accounts allow Majoor to read, draft, and send emails, and manage your calendar events.")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.7))
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { refreshStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshStatus()
        }
    }

    // MARK: - Gmail

    private func connectGmail() {
        isConnecting = true
        connectError = ""
        Task {
            do {
                let email = try await GoogleOAuthManager.shared.authorize()
                gmailConnected = true
                gmailEmail = email
                MajoorLogger.log("Gmail connected in UI: \(email)")
            } catch {
                connectError = error.localizedDescription
                MajoorLogger.error("Gmail connect failed: \(error)")
            }
            isConnecting = false
            // Re-verify from Keychain to make sure it actually persisted
            refreshStatus()
        }
    }

    private func disconnectGmail() {
        GoogleOAuthManager.shared.disconnect()
        gmailConnected = false
        gmailEmail = ""
    }

    // MARK: - Calendar

    private func requestCalendarAccess() {
        // Must use the long-lived shared store — a local EKEventStore() gets
        // deallocated before the XPC round-trip completes, killing the prompt.
        let store = sharedEventStore
        Task { @MainActor in
            do {
                MajoorLogger.log("Requesting calendar access via sharedEventStore... status before: \(EKEventStore.authorizationStatus(for: .event).rawValue)")
                let granted = try await store.requestFullAccessToEvents()
                MajoorLogger.log("Calendar access result: \(granted)")
            } catch {
                MajoorLogger.error("Calendar access error: \(error)")
            }
            calendarStatus = EKEventStore.authorizationStatus(for: .event)
        }
    }

    private func openCalendarSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Status

    private func refreshStatus() {
        gmailConnected = GoogleOAuthManager.shared.isAuthenticated
        gmailEmail = GoogleOAuthManager.shared.connectedEmail ?? ""
        calendarStatus = EKEventStore.authorizationStatus(for: .event)
    }

    private var calendarStatusIcon: String {
        switch calendarStatus {
        case .fullAccess, .authorized: return "checkmark.circle.fill"
        case .denied, .restricted: return "xmark.circle.fill"
        case .notDetermined: return "questionmark.circle.fill"
        @unknown default: return "questionmark.circle.fill"
        }
    }

    private var calendarStatusColor: Color {
        switch calendarStatus {
        case .fullAccess, .authorized: return .green
        case .denied, .restricted: return .red
        case .notDetermined: return .orange
        @unknown default: return .secondary
        }
    }

    private var calendarStatusText: String {
        switch calendarStatus {
        case .fullAccess, .authorized: return "Access granted"
        case .denied: return "Access denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not yet requested"
        @unknown default: return "Unknown"
        }
    }
}
