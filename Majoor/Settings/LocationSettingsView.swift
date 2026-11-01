// LocationSettingsView.swift
// Majoor — Settings ▸ Location: the phone's devices, the endpoint, the last
// fix, and the event sources' health (runtime mode)

import SwiftUI
import Combine

@MainActor
final class LocationSettingsModel: ObservableObject {
    @Published var devices: [LocationDeviceRecord] = []
    @Published var newDeviceName = "iPhone"
    @Published var freshTokenDevice: String?
    @Published var freshToken: String?
    @Published var lastFix: LocationFixRecord?
    @Published var endpointState: LocationEndpoint.State = .stopped
    @Published var statuses: [String: EventHub.SourceStatus] = [:]
    @Published var slackChannels: String = UserDefaults.standard.string(forKey: SlackSource.channelsKey) ?? ""
    @Published var error: String?

    private var stateTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?

    func start() {
        refresh()
        guard stateTask == nil else { return }
        if let location = SourcesRuntime.shared.location {
            stateTask = Task { [weak self] in
                for await state in await location.endpoint.stateStream() {
                    self?.endpointState = state
                }
            }
        }
        statusTask = Task { [weak self] in
            for await statuses in await EventHub.shared.statusStream() {
                self?.statuses = statuses
                self?.lastFix = LocationFixStore.shared.latest()
            }
        }
    }

    func stop() {
        stateTask?.cancel()
        stateTask = nil
        statusTask?.cancel()
        statusTask = nil
    }

    func refresh() {
        devices = LocationDeviceStore.shared.all()
        lastFix = LocationFixStore.shared.latest()
    }

    func addDevice() {
        do {
            let minted = try LocationDeviceStore.shared.mint(name: newDeviceName)
            freshTokenDevice = minted.device.name
            freshToken = minted.token
            error = nil
            refresh()
        } catch {
            self.error = "Could not add the device: \(error.localizedDescription)"
        }
    }

    func revoke(_ deviceId: String) {
        LocationDeviceStore.shared.revoke(deviceId: deviceId)
        if freshTokenDevice != nil, !devices.contains(where: { $0.deviceId == deviceId }) { freshToken = nil }
        refresh()
    }

    func dismissToken() {
        freshToken = nil
        freshTokenDevice = nil
    }

    func saveSlackChannels() {
        UserDefaults.standard.set(slackChannels, forKey: SlackSource.channelsKey)
    }

    func restart(_ sourceId: String) {
        Task { await EventHub.shared.restart(sourceId) }
    }

    var endpointAddress: String? {
        if case .listening(let address, let port) = endpointState { return "http://\(address):\(port)\(LocationEndpoint.path)" }
        return nil
    }
}

struct LocationSettingsView: View {
    @StateObject private var model = LocationSettingsModel()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let sourceOrder = [GmailSource.sourceId, CalendarSource.sourceId, SlackSource.sourceId, LocationSource.sourceId]

    var body: some View {
        Form {
            endpointSection
            devicesSection
            lastFixSection
            sourcesSection
            slackSection
        }
        .formStyle(.grouped)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var endpointSection: some View {
        Section {
            LabeledContent("Status", value: model.endpointState.text)
            if let address = model.endpointAddress {
                LabeledContent("URL") {
                    Text(address)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            Text("The Shortcut on your phone POSTs JSON {event, latitude, longitude, accuracy, place} to this URL over Tailscale with the device token in the X-Majoor-Token header. Nothing else is accepted, and fixes never leave this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Location endpoint")
        }
    }

    private var devicesSection: some View {
        Section {
            HStack {
                TextField("Device name", text: $model.newDeviceName)
                    .textFieldStyle(.roundedBorder)
                Button("Add device") { model.addDevice() }
            }
            if let token = model.freshToken {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Token for \(model.freshTokenDevice ?? "the new device"), shown once:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(token)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    HStack {
                        Text("Paste it into the Shortcut's X-Majoor-Token header now; Majoor keeps only its hash.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Done") { model.dismissToken() }
                    }
                }
            }
            if model.devices.isEmpty {
                Text("No devices yet.").foregroundStyle(.secondary)
            }
            ForEach(model.devices) { device in
                HStack {
                    VStack(alignment: .leading) {
                        Text(device.name)
                        Text("Added \(Self.dateFormatter.string(from: device.createdAt))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Revoke", role: .destructive) { model.revoke(device.deviceId) }
                }
            }
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Devices")
        }
    }

    private var lastFixSection: some View {
        Section {
            if let fix = model.lastFix {
                LabeledContent("When", value: Self.dateFormatter.string(from: fix.at))
                LabeledContent("Event", value: fix.event)
                if let place = fix.place { LabeledContent("Place", value: place) }
                LabeledContent("Coordinates") {
                    Text(String(format: "%.5f, %.5f", fix.latitude, fix.longitude))
                        .font(.system(.body, design: .monospaced))
                }
                if let accuracy = fix.accuracy { LabeledContent("Accuracy", value: "\(Int(accuracy)) m") }
            } else {
                Text("No fix received yet.").foregroundStyle(.secondary)
            }
            Text("Fixes are deleted after seven days.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Last fix")
        }
    }

    private var sourcesSection: some View {
        Section {
            ForEach(Self.sourceOrder, id: \.self) { sourceId in
                let status = model.statuses[sourceId] ?? .stopped
                HStack {
                    Text(sourceId.capitalized)
                    Spacer()
                    Text(status.text)
                        .font(.caption)
                        .foregroundStyle(statusColor(status))
                    if case .failed = status {
                        Button("Restart") { model.restart(sourceId) }
                    }
                }
            }
        } header: {
            Text("Event sources")
        } footer: {
            Text("Gmail polls every 3 minutes, the calendar reacts to changes, Slack polls every 30 minutes, location listens. A source that fails five times in a row stops until you restart it.")
        }
    }

    private var slackSection: some View {
        Section {
            TextField("Channel ids or names, one per line", text: $model.slackChannels, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onChange(of: model.slackChannels) { _, _ in model.saveSlackChannels() }
            Text("Read through the Slack integration in Settings ▸ Integrations. Leave empty to keep the Slack source off.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Slack channels")
        }
    }

    private func statusColor(_ status: EventHub.SourceStatus) -> Color {
        switch status {
        case .running: return .secondary
        case .stopped: return .secondary
        case .restarting: return .orange
        case .failed: return .red
        }
    }
}
