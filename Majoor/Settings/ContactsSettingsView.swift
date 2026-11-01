// ContactsSettingsView.swift
// Majoor — Settings ▸ Contacts: who counts as a VIP, and how the nudge waits
//
// `contacts_policy` holds the owner handle (set in Channels, runtime mode) and
// every handle the owner lists. The VIP flag gates the unreplied-email nudge
// (Phase 2 step 6c); the threshold and weekend rule live here too. Hand-entered
// in 2.0 (plan open question 4).

import SwiftUI
import Combine

@MainActor
final class ContactsSettingsModel: ObservableObject {

    @Published private(set) var contacts: [ContactPolicyRecord] = []
    @Published var newHandle = ""
    @Published var newIsVIP = true
    @Published var thresholdHours: Int
    @Published var skipWeekends: Bool
    @Published var message: String?

    private let store: ContactPolicyStore
    private let settings: NudgeSettingsStore

    init(store: ContactPolicyStore = .shared, settings: NudgeSettingsStore = .shared) {
        self.store = store
        self.settings = settings
        self.thresholdHours = settings.thresholdHours
        self.skipWeekends = settings.skipWeekends
    }

    var owners: [ContactPolicyRecord] { contacts.filter { $0.trust == ContactPolicyStore.ownerTrust } }
    var others: [ContactPolicyRecord] { contacts.filter { $0.trust != ContactPolicyStore.ownerTrust } }

    func load() {
        contacts = store.all()
    }

    func add() {
        let normalized = TrustPolicy.normalize(handle: newHandle)
        guard !normalized.isEmpty, normalized.contains("@") || normalized.hasPrefix("+") else {
            message = "Enter an email address or a phone number."
            return
        }
        let existed = store.all().contains { $0.handle == normalized }
        store.setVIP(handle: normalized, newIsVIP)
        message = existed ? "Updated \(normalized)." : "Added \(normalized)."
        newHandle = ""
        load()
    }

    func setVIP(_ handle: String, _ on: Bool) {
        store.setVIP(handle: handle, on)
        load()
    }

    func remove(_ handle: String) {
        store.remove(handle: handle)
        load()
    }

    func setThreshold(_ hours: Int) {
        thresholdHours = max(1, min(hours, 168))
        settings.thresholdHours = thresholdHours
    }

    func setSkipWeekends(_ on: Bool) {
        skipWeekends = on
        settings.skipWeekends = on
    }
}

struct ContactsSettingsView: View {
    @StateObject private var model = ContactsSettingsModel()

    var body: some View {
        Form {
            Section {
                if model.owners.isEmpty {
                    Text("No owner handle yet.").foregroundStyle(.secondary)
                }
                ForEach(model.owners, id: \.handle) { owner in
                    LabeledContent(owner.handle, value: "owner")
                }
                Text("The owner handle is the phone number or Apple ID you text Majoor from. Set it in Settings ▸ Channels (Runtime mode).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Owner")
            }

            Section {
                if model.others.isEmpty {
                    Text("No contacts yet. Add the people whose email should never wait.").foregroundStyle(.secondary)
                }
                ForEach(model.others, id: \.handle) { contact in
                    HStack {
                        Text(contact.handle)
                            .font(.system(.body, design: .monospaced))
                        Spacer()
                        Toggle("VIP", isOn: Binding(get: { contact.isVIP }, set: { model.setVIP(contact.handle, $0) }))
                            .toggleStyle(.switch)
                        Button("Remove", role: .destructive) { model.remove(contact.handle) }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Email address or phone number", text: $model.newHandle)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.add() }
                    Toggle("VIP", isOn: $model.newIsVIP)
                    Button("Add") { model.add() }
                        .disabled(model.newHandle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let message = model.message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Contacts")
            } footer: {
                Text("VIPs gate the unreplied-email nudge: when a VIP's last email has waited longer than the threshold with no reply from you, Majoor drafts one and texts it to you to send, edit or skip. Hand-entered in 2.0.")
            }

            Section {
                Stepper("Nudge after \(model.thresholdHours) h without a reply",
                        value: Binding(get: { model.thresholdHours }, set: { model.setThreshold($0) }), in: 1...168)
                Toggle("No nudges on weekends", isOn: Binding(get: { model.skipWeekends }, set: { model.setSkipWeekends($0) }))
                Text("The nudge runs every two hours (Settings ▸ Automations), nudges a thread at most once a day, and rests a thread for a week after you send, edit or skip.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Nudge")
            }
        }
        .formStyle(.grouped)
        .onAppear { model.load() }
    }
}
