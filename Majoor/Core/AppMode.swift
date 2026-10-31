// AppMode.swift
// Majoor — Which role this install plays (PRD §5.1: one binary, two modes)
//
// `local` is 1.x: the panel and a local runtime, nothing listening.
// `runtime` is the always-on Mac mini: local plus the control API, the
// messaging channels and the scheduler. `client` is the laptop: the hotkey,
// bar and panel talk to a remote runtime; the local runtime is only used
// when "Run here" is chosen explicitly.

import Foundation

nonisolated enum AppMode: String, CaseIterable, Codable, Sendable {
    case local, runtime, client

    static let defaultsKey = "appMode"

    /// Default `local`, so existing installs behave exactly as before.
    static var current: AppMode {
        AppMode(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .local
    }

    var displayName: String {
        switch self {
        case .local: return "Local"
        case .runtime: return "Runtime"
        case .client: return "Client"
        }
    }

    var blurb: String {
        switch self {
        case .local: return "Runs tasks on this Mac. Nothing listens on the network."
        case .runtime: return "Always-on Mac: runs tasks, accepts paired laptops over Tailscale, delivers reminders."
        case .client: return "Sends tasks to a paired runtime (your Mac mini) and shows its activity here. \"Run here\" runs a task on this Mac instead."
        }
    }
}
