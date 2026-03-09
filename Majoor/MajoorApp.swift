// MajoorApp.swift
// Majoor — Your AI That Does The Work
//
// App entry point. This sets up the menu bar app using AppDelegate
// since menu bar apps need AppKit integration that pure SwiftUI doesn't provide.

import SwiftUI

@main
struct MajoorApp: App {
    // Use AppDelegate for menu bar setup and global shortcuts
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        // Settings window (opened via ⌘+, or from menu bar)
        Settings {
            SettingsView()
                .environmentObject(appDelegate.taskManager)
        }
    }
}
