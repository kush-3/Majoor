// ChannelsSettingsView.swift
// Majoor — Settings ▸ Channels: the iMessage channel (runtime mode)

import SwiftUI
import Combine

/// Owns the live iMessage channel for the UI and the app delegate. The
/// factory is set by the app delegate at launch (runtime mode only).
@MainActor
final class IMessageModel: ObservableObject {

    static let shared = IMessageModel()

    @Published var enabled: Bool = UserDefaults.standard.bool(forKey: IMessageChannel.enabledKey)
    @Published var ownerHandle: String = ContactPolicyStore.shared.owners().first ?? ""
    @Published var staleMinutes: Int = {
        let stored = UserDefaults.standard.integer(forKey: IMessageChannel.staleMinutesKey)
        return stored > 0 ? stored : IMessageChannel.defaultStaleMinutes
    }()
    @Published private(set) var status: IMessageChannel.Status = .stopped
    @Published private(set) var helperVersion: String?
    @Published private(set) var cursor: Int = UserDefaults.standard.integer(forKey: IMessageChannel.lastRowIdKey)
    @Published private(set) var accepted = 0
    @Published private(set) var dropped: [String: Int] = [:]
    @Published var message: String?

    var helperPath: String? { JSONRPCLineClient.resolve("imsg") }
    var isAvailable: Bool { factory != nil }

    private(set) var channel: IMessageChannel?
    private var statusTask: Task<Void, Never>?
    private var factory: (@MainActor () -> IMessageChannel)?

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: IMessageChannel.enabledKey) }

    static var staleAfter: TimeInterval {
        let stored = UserDefaults.standard.integer(forKey: IMessageChannel.staleMinutesKey)
        return TimeInterval((stored > 0 ? stored : IMessageChannel.defaultStaleMinutes) * 60)
    }

    /// Runtime mode: the app delegate provides how to build a channel and
    /// starts one right away when the setting is on.
    func configure(factory: @escaping @MainActor () -> IMessageChannel) {
        self.factory = factory
        if Self.isEnabled { startChannel() }
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: IMessageChannel.enabledKey)
        if on { startChannel() } else { stopChannel() }
    }

    func saveOwner() {
        let normalized = TrustPolicy.normalize(handle: ownerHandle)
        guard !normalized.isEmpty, normalized.contains("@") || normalized.hasPrefix("+") else {
            message = "Enter the phone number (+1 555 000 1111) or Apple ID email you text Majoor from."
            return
        }
        for existing in ContactPolicyStore.shared.owners() where existing != normalized {
            ContactPolicyStore.shared.remove(handle: existing)
        }
        ContactPolicyStore.shared.setTrust(handle: normalized, trust: ContactPolicyStore.ownerTrust)
        ownerHandle = normalized
        message = "Owner handle saved: \(normalized)"
    }

    func setStaleMinutes(_ minutes: Int) {
        staleMinutes = max(1, minutes)
        UserDefaults.standard.set(staleMinutes, forKey: IMessageChannel.staleMinutesKey)
    }

    func sendTest() {
        guard let channel else { message = "Turn the channel on first."; return }
        Task {
            do {
                try await channel.sendTest()
                message = "Test message sent."
            } catch {
                message = "Send failed: \((error as? JSONRPCError)?.userMessage ?? "\(error)")"
            }
        }
    }

    func refreshCounts() {
        guard let channel else { return }
        Task {
            accepted = await channel.acceptedCount
            dropped = await channel.dropped
            cursor = await channel.currentCursor
            helperVersion = await channel.helperVersion
        }
    }

    private func startChannel() {
        guard channel == nil, let factory else { return }
        guard !ContactPolicyStore.shared.owners().isEmpty else {
            message = "Set the owner handle first; the channel only listens to it."
            return
        }
        let channel = factory()
        self.channel = channel
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            for await status in await channel.statusStream() {
                self?.status = status
                self?.refreshCounts()
            }
        }
        Task {
            await ChannelRouter.shared.register(channel)
            await channel.start()
        }
    }

    func stopChannel() {
        guard let channel else { return }
        self.channel = nil
        statusTask?.cancel()
        statusTask = nil
        status = .stopped
        Task {
            await ChannelRouter.shared.unregister(IMessageChannel.channelId)
            await channel.stop()
        }
    }
}

struct ChannelsSettingsView: View {
    @StateObject private var model = IMessageModel.shared

    var body: some View {
        Form {
            Section("iMessage") {
                Toggle("Listen for texts from the owner", isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) }))
                    .disabled(!model.isAvailable)
                LabeledContent("Status", value: model.status.text)
                HStack {
                    TextField("Owner phone or Apple ID email", text: $model.ownerHandle)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") { model.saveOwner() }
                }
                Text("Only this handle can give Majoor instructions, and only from a direct iMessage chat. Group chats and SMS are ignored. Text Majoor first so Messages has a conversation to reply into.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !model.isAvailable {
                    Text("Available in Runtime mode (Settings ▸ General ▸ Mode).")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Helper") {
                LabeledContent("imsg", value: model.helperPath ?? "not found — brew install steipete/tap/imsg")
                if let version = model.helperVersion { LabeledContent("Version", value: version) }
                LabeledContent("Last row", value: model.cursor == 0 ? "none yet (starts at the current tail)" : String(model.cursor))
                Text("Majoor.app needs Full Disk Access (to read Messages) and Automation for Messages (to send). Grant both in System Settings ▸ Privacy & Security.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("After an outage") {
                Stepper("Summarize, don't run, messages older than \(model.staleMinutes) min", value: Binding(get: { model.staleMinutes }, set: { model.setStaleMinutes($0) }), in: 1...1440)
                Text("STOP is honored regardless of age when it is the newest message.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Activity") {
                LabeledContent("Accepted", value: String(model.accepted))
                if !model.dropped.isEmpty {
                    LabeledContent("Ignored", value: model.dropped.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " · "))
                }
                HStack {
                    Button("Send test message") { model.sendTest() }
                        .disabled(model.channel == nil)
                    if let message = model.message {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshCounts() }
    }
}
