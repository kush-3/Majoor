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
            Section {
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Gmail")
                                .font(.body)
                            Text(gmailConnected ? gmailEmail : "Send and manage email through Majoor")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: gmailConnected ? "envelope.fill" : "envelope")
                            .foregroundStyle(gmailConnected ? .green : .secondary)
                            .frame(width: 20)
                    }

                    Spacer()

                    if gmailConnected {
                        Button("Disconnect", role: .destructive) { disconnectGmail() }
                            .foregroundStyle(.red)
                            .buttonStyle(.plain)
                            .font(.caption)
                    } else if isConnecting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("Connect...") { connectGmail() }
                    }
                }

                if !connectError.isEmpty {
                    Text(connectError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Email")
            }

            // Calendar
            Section {
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Apple Calendar")
                                .font(.body)
                            Text(calendarDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "calendar")
                            .foregroundStyle(calendarGranted ? .green : (calendarDenied ? .red : .secondary))
                            .frame(width: 20)
                    }

                    Spacer()

                    if calendarGranted {
                        Text("Granted")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else if calendarDenied {
                        Menu {
                            Button("Open System Settings") { openCalendarSettings() }
                            Button("Reset & Retry") { resetAndRetryCalendar() }
                        } label: {
                            Text("Fix...")
                        }
                    } else {
                        Button("Grant Access") { requestCalendarAccess() }
                    }
                }
            } header: {
                Text("Calendar")
            } footer: {
                if calendarDenied {
                    Text("Calendar access was denied. Open System Settings > Privacy & Security > Calendars to grant access, or reset the permission to try again.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshStatus()
        }
    }

    // MARK: - Computed Properties

    private var calendarGranted: Bool {
        calendarStatus == .fullAccess || calendarStatus == .authorized
    }

    private var calendarDenied: Bool {
        calendarStatus == .denied || calendarStatus == .restricted
    }

    private var calendarDescription: String {
        if calendarGranted {
            return "Read and create calendar events"
        } else if calendarDenied {
            return "Access denied"
        } else {
            return "Create and manage calendar events with Majoor"
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
        let currentStatus = EKEventStore.authorizationStatus(for: .event)

        if currentStatus == .denied || currentStatus == .restricted {
            MajoorLogger.log("Calendar status is .denied/.restricted -- opening System Settings")
            openCalendarSettings()
            return
        }

        let store = sharedEventStore
        Task { @MainActor in
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            defer { NSApp.setActivationPolicy(.accessory) }

            do {
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

    private func resetAndRetryCalendar() {
        let bundleId = Bundle.main.bundleIdentifier ?? "com.Majoor"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Calendar", bundleId]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            MajoorLogger.error("TCC reset failed: \(error)")
        }
        calendarStatus = EKEventStore.authorizationStatus(for: .event)
        requestCalendarAccess()
    }

    // MARK: - Status

    private func refreshStatus() {
        gmailConnected = GoogleOAuthManager.shared.isAuthenticated
        gmailEmail = GoogleOAuthManager.shared.connectedEmail ?? ""
        calendarStatus = EKEventStore.authorizationStatus(for: .event)
    }
}
