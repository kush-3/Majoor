// RuntimeConnectionModel.swift
// Majoor — What the UI knows about the remote runtime (client mode)
//
// Mirrors RemoteRuntimeClient's state onto the main actor for the command
// bar dot, the panel badge and Settings. Owns nothing: the client is
// created by the app delegate and attached here.

import Foundation
import Combine

@MainActor
final class RuntimeConnectionModel: ObservableObject {

    static let shared = RuntimeConnectionModel()

    nonisolated enum Tone: Sendable { case off, ok, warning, bad }

    @Published private(set) var state: RemoteRuntimeClient.State = .disconnected
    @Published private(set) var dayUSD: Double = 0
    @Published private(set) var isClientMode = false
    @Published private(set) var isPaired = false
    @Published private(set) var host = ""
    @Published private(set) var port: UInt16 = ControlProtocol.defaultPort
    @Published private(set) var lastBye: String?

    private(set) var client: RemoteRuntimeClient?
    private var observer: Task<Void, Never>?

    /// Called once at launch in client mode.
    func attach(client: RemoteRuntimeClient) {
        self.client = client
        isClientMode = true
        refreshPairing()
        observer?.cancel()
        observer = Task { [weak self] in
            for await update in await client.updates() {
                guard let self else { return }
                switch update {
                case .state(let state):
                    self.state = state
                case .snapshot(let body):
                    self.dayUSD = body.dayUSD
                case .event(let item):
                    if case .cost(_, _, _, _, let dayUSD) = item.event { self.dayUSD = dayUSD }
                case .bye(let reason):
                    self.lastBye = reason
                }
            }
        }
    }

    func refreshPairing() {
        guard let client else { isPaired = false; return }
        Task {
            let credentials = await client.currentCredentials
            isPaired = credentials != nil
            host = credentials?.host ?? ""
            port = credentials?.port ?? ControlProtocol.defaultPort
        }
    }

    var isConnected: Bool { state.isConnected }

    var tone: Tone {
        switch state {
        case .connected: return .ok
        case .connecting, .authenticating, .reconnecting: return .warning
        case .failed: return .bad
        case .disconnected: return isPaired ? .bad : .off
        }
    }

    var statusText: String {
        switch state {
        case .disconnected: return isPaired ? "Not connected" : "Not paired"
        case .connecting: return "Connecting…"
        case .authenticating: return "Signing in…"
        case .connected: return "Connected to \(host)"
        case .reconnecting(let attempt, let lastError): return "Reconnecting (try \(attempt)): \(lastError)"
        case .failed(let message): return message
        }
    }

    /// The short label next to the command bar dot.
    var shortStatus: String {
        switch state {
        case .connected: return "Mac mini"
        case .connecting, .authenticating: return "Connecting"
        case .reconnecting: return "Reconnecting"
        case .failed: return "Pairing lost"
        case .disconnected: return isPaired ? "Unreachable" : "Not paired"
        }
    }
}
