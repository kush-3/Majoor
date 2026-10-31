// ClientSettingsView.swift
// Majoor — Settings ▸ Mac mini: pair this Mac with a runtime (client mode)

import SwiftUI
import Combine

@MainActor
final class ClientSettingsModel: ObservableObject {
    @Published var host: String = ""
    @Published var port: String = String(ControlProtocol.defaultPort)
    @Published var code: String = ""
    @Published var busy = false
    @Published var message: String?
    @Published var messageIsError = false

    private let connection = RuntimeConnectionModel.shared

    private var deviceName: String {
        Host.current().localizedName ?? "This Mac"
    }

    func load() {
        if let credentials = ClientCredentialsStore.load() {
            host = credentials.host
            port = String(credentials.port)
        }
    }

    func pair() {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !host.isEmpty else { show("Enter the runtime's Tailscale address.", error: true); return }
        guard let port = UInt16(port.trimmingCharacters(in: .whitespaces)), port >= 1024 else { show("Port must be between 1024 and 65535.", error: true); return }
        guard !code.isEmpty else { show("Enter the pairing code shown on the runtime (Settings ▸ Remote).", error: true); return }
        guard let client = connection.client else { show("Client mode is not active. Set Mode to Client and restart Majoor.", error: true); return }
        busy = true
        message = nil
        let deviceName = deviceName
        Task {
            defer { busy = false }
            do {
                let ok = try await RemoteRuntimeClient.pair(host: host, port: port, code: code, deviceName: deviceName)
                let credentials = ClientCredentials(host: host, port: port, clientId: ok.clientId, token: ok.token, runtimeId: nil)
                await client.forget()
                ClientCredentialsStore.save(credentials)
                await client.configure(credentials)
                await client.start()
                connection.refreshPairing()
                self.code = ""
                show("Paired. Connecting…", error: false)
            } catch {
                let reason = (error as? RemoteClientError)?.userMessage ?? "\(error)"
                show("Pairing failed: \(reason)", error: true)
            }
        }
    }

    func forget() {
        guard let client = connection.client else { return }
        Task {
            await client.forget()
            ClientCredentialsStore.forget()
            connection.refreshPairing()
            show("Forgot the runtime. Pair again to reconnect.", error: false)
        }
    }

    func reconnect() {
        guard let client = connection.client else { return }
        Task {
            if await client.isConfigured {
                await client.start()
                await client.wake()
            }
        }
    }

    private func show(_ text: String, error: Bool) {
        message = text
        messageIsError = error
    }
}

struct ClientSettingsView: View {
    @StateObject private var model = ClientSettingsModel()
    @ObservedObject private var connection = RuntimeConnectionModel.shared

    var body: some View {
        Form {
            Section("Runtime") {
                LabeledContent("Status", value: connection.statusText)
                if connection.isPaired {
                    LabeledContent("Address", value: "\(connection.host):\(connection.port)")
                    HStack {
                        Button("Reconnect now") { model.reconnect() }
                        Button("Forget this runtime", role: .destructive) { model.forget() }
                    }
                }
                Text("Tasks typed in the command bar run on the paired runtime; its activity and approvals show here. Switch on \"Run here\" in the command bar to use this Mac instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(connection.isPaired ? "Pair with a different runtime" : "Pair") {
                TextField("Tailscale address (100.x.y.z or name)", text: $model.host)
                    .textFieldStyle(.roundedBorder)
                TextField("Port", text: $model.port)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                TextField("Pairing code", text: $model.code)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 200)
                HStack {
                    Button(model.busy ? "Pairing…" : "Pair") { model.pair() }
                        .disabled(model.busy)
                    if let message = model.message {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(model.messageIsError ? Color.red : Color.secondary)
                    }
                }
                Text("On the runtime open Settings ▸ Remote and click \"Show pairing code\". The code is valid for five minutes. The token this Mac receives is kept in your Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.load() }
    }
}

// MARK: - Permission mode over the API

/// Client mode: the permission mode shown in General is the runtime's, read
/// and written over the control API. Tightening is accepted; loosening is
/// refused by the runtime and shown inline (PRD open question 3).
@MainActor
final class RemotePermissionModel: ObservableObject {
    @Published var mode: String = PermissionMode.standard.rawValue
    @Published var loaded = false
    @Published var error: String?

    private var client: RemoteRuntimeClient? { RuntimeConnectionModel.shared.client }

    func load() {
        guard let client else { return }
        Task {
            do {
                let values = try await client.settings(keys: ["permissionMode"])
                if let raw = values["permissionMode"]?.stringValue { mode = raw }
                loaded = true
                error = nil
            } catch {
                self.error = "Could not read the runtime's setting: \((error as? RemoteClientError)?.userMessage ?? "\(error)")"
            }
        }
    }

    func set(_ raw: String) {
        guard let client else { return }
        let previous = mode
        mode = raw
        Task {
            do {
                try await client.setSetting(key: "permissionMode", value: .string(raw))
                error = nil
            } catch RemoteClientError.rejected(let code, let message) {
                mode = previous
                error = code == .needsLocalApproval ? "Loosening the permission mode must be done on the runtime itself." : message
            } catch {
                mode = previous
                self.error = (error as? RemoteClientError)?.userMessage ?? "\(error)"
            }
        }
    }
}
