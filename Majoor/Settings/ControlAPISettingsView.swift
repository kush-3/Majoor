// ControlAPISettingsView.swift
// Majoor — Settings ▸ Remote: the control API for the laptop client

import SwiftUI
import Combine

@MainActor
final class ControlAPIViewModel: ObservableObject {
    @Published var enabled: Bool = ControlServer.isEnabled
    @Published var state: ControlServer.State = .stopped
    @Published var clients: [PairedClientRecord] = []
    @Published var pendingCode: PairingManager.PendingCode?
    @Published var loopback: Bool = UserDefaults.standard.bool(forKey: ControlServer.loopbackKey)
    @Published var port: Int = Int(ControlServer.configuredPort)

    private var stateTask: Task<Void, Never>?

    func start() {
        guard stateTask == nil else { return }
        stateTask = Task { [weak self] in
            for await state in await ControlServer.shared.stateStream() {
                self?.state = state
            }
        }
        refreshClients()
    }

    func stop() {
        stateTask?.cancel()
        stateTask = nil
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: ControlServer.enabledKey)
        Task {
            if on { await ControlServer.shared.start() } else { await ControlServer.shared.stop() }
        }
    }

    func setLoopback(_ on: Bool) {
        loopback = on
        UserDefaults.standard.set(on, forKey: ControlServer.loopbackKey)
        Task { await ControlServer.shared.restartIfEnabled() }
    }

    func setPort(_ value: Int) {
        port = value
        UserDefaults.standard.set(value, forKey: ControlServer.portKey)
        Task { await ControlServer.shared.restartIfEnabled() }
    }

    func pair() {
        Task { pendingCode = await ControlServer.shared.mintPairingCode() }
    }

    func revoke(_ clientId: String) {
        Task {
            await ControlServer.shared.revoke(clientId: clientId)
            refreshClients()
        }
    }

    func refreshClients() {
        Task { clients = await ControlServer.shared.pairedClients() }
    }

    var statusText: String {
        switch state {
        case .stopped: return enabled ? "Starting…" : "Off"
        case .waitingForTailscale: return "Tailscale not detected. Start Tailscale on this Mac; the API binds only to its address."
        case .listening(let address, let port): return "Listening on \(address):\(port)"
        case .failed(let message): return "Failed: \(message)"
        }
    }

    var address: String? {
        if case .listening(let address, _) = state { return address }
        return nil
    }
}

struct ControlAPISettingsView: View {
    @StateObject private var model = ControlAPIViewModel()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        Form {
            Section("Control API") {
                Toggle("Let your laptop control this Mac", isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) }))
                LabeledContent("Status", value: model.statusText)
                Stepper("Port: \(model.port)", value: Binding(get: { model.port }, set: { model.setPort($0) }), in: 1024...65535)
                Text("The API listens only on this Mac's Tailscale address. Every client needs a pairing code and is listed below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Pair a new client") {
                Button("Show pairing code") { model.pair() }
                    .disabled(!model.enabled)
                if let code = model.pendingCode {
                    Text(code.code)
                        .font(.system(.title, design: .monospaced))
                        .textSelection(.enabled)
                    Text("Enter it on your laptop within five minutes, with address \(model.address ?? "(waiting for Tailscale)") and port \(model.port).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Paired clients") {
                if model.clients.isEmpty {
                    Text("No clients paired yet.").foregroundStyle(.secondary)
                }
                ForEach(model.clients) { client in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(client.name).font(.body)
                            Text("Paired \(Self.dateFormatter.string(from: client.createdAt))"
                                 + (client.lastSeenAt.map { " · last seen \(Self.dateFormatter.string(from: $0))" } ?? ""))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if client.isRevoked {
                            Text("Revoked").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Button("Revoke") { model.revoke(client.clientId) }
                        }
                    }
                }
            }

            #if DEBUG
            Section("Development") {
                Toggle("Bind to 127.0.0.1 (this Mac only)", isOn: Binding(get: { model.loopback }, set: { model.setLoopback($0) }))
                Text("Debug builds only. Lets client mode be tried on one Mac without Tailscale.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #endif
        }
        .formStyle(.grouped)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}
