// AutomationsSettingsView.swift
// Majoor — Settings ▸ Automations: scheduled jobs, reminders, delivery
//
// Job definitions are code (`JobCatalog`); here the owner switches each one
// on, edits its schedule, runs it now, and decides where messages go and
// during which hours. Rows come from `automations`; recent outcomes from
// `automation_runs`.

import SwiftUI
import Combine

@MainActor
final class AutomationsSettingsModel: ObservableObject {

    struct JobRow: Identifiable {
        let definition: JobDefinition
        var record: AutomationRecord?
        var id: String { definition.name }
        var isOn: Bool { record?.enabled ?? false }
    }

    static let deliveryChannelKey = "jobDeliveryChannel"

    @Published var jobs: [JobRow] = []
    @Published var reminders: [AutomationRecord] = []
    @Published var runs: [JobRunRecord] = []
    @Published var cronDrafts: [String: String] = [:]
    @Published var cronErrors: [String: String] = [:]
    @Published var activeHoursText: String = ActiveHours.defaultText
    @Published var activeHoursError: String?
    @Published var deliveryChannel: String = PanelChannel.channelId
    @Published var ownerHandle: String?
    @Published var waitingOnOwner = 0

    private let automations = AutomationStore.shared
    private let runStore = JobRunStore.shared
    private let hoursStore = ActiveHoursStore.shared
    private var refresh: Task<Void, Never>?

    func start() {
        load()
        guard refresh == nil else { return }
        refresh = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                self?.load()
            }
        }
    }

    func stop() {
        refresh?.cancel()
        refresh = nil
    }

    func load() {
        let rows = automations.all()
        jobs = JobCatalog.all.map { definition in
            JobRow(definition: definition, record: rows.first { $0.kind == AutomationRecord.jobKind && $0.name == definition.name })
        }
        for job in jobs where cronDrafts[job.id] == nil {
            cronDrafts[job.id] = job.record?.cron ?? job.definition.defaultCron
        }
        reminders = automations.listUpcoming()
        runs = runStore.recent(limit: 20)
        activeHoursText = hoursStore.text
        deliveryChannel = UserDefaults.standard.string(forKey: Self.deliveryChannelKey) ?? PanelChannel.channelId
        ownerHandle = ContactPolicyStore.shared.owners().first
        Task { [weak self] in
            let count = await EscalationLadder.shared.pendingCount
            self?.waitingOnOwner = count
        }
    }

    /// Where a job's messages go: the owner's iMessage thread when chosen and
    /// known, else the panel (toast plus local notification).
    var delivery: ChannelRef {
        if deliveryChannel == IMessageChannel.channelId, let handle = ownerHandle {
            return ChannelRef(channelId: IMessageChannel.channelId, threadKey: IMessageChannel.threadKey(for: handle))
        }
        return .panel
    }

    func toggle(_ name: String, on: Bool) {
        guard let job = jobs.first(where: { $0.id == name }) else { return }
        let cron = cronDrafts[name] ?? job.definition.defaultCron
        let delivery = delivery
        Task {
            let next = await AutomationScheduler.shared.nextRun(forCron: cron)
            if let record = job.record {
                automations.setEnabled(id: record.id, on, nextRunAt: next)
            } else if on {
                let record = AutomationRecord.job(name: name, cron: cron, tier: job.definition.tier, delivery: delivery,
                                                  urgencyCeiling: job.definition.urgencyCeiling, riskCeiling: job.definition.riskCeiling,
                                                  nextRunAt: next)
                do { try automations.insert(record) } catch { MajoorLogger.error("Could not schedule \(name): \(error)") }
            }
            await AutomationScheduler.shared.wake()
            load()
        }
    }

    func cronSummary(_ name: String) -> String? {
        CronSchedule.parse(cronDrafts[name] ?? "")?.summary
    }

    func cronChanged(_ name: String) -> Bool {
        guard let job = jobs.first(where: { $0.id == name }) else { return false }
        return (cronDrafts[name] ?? "").trimmingCharacters(in: .whitespaces) != (job.record?.cron ?? job.definition.defaultCron)
    }

    func saveCron(_ name: String) {
        guard let job = jobs.first(where: { $0.id == name }) else { return }
        let text = (cronDrafts[name] ?? "").trimmingCharacters(in: .whitespaces)
        guard let schedule = CronSchedule.parse(text) else {
            cronErrors[name] = "Not a cron expression (minute hour day month weekday, e.g. */30 * * * *)."
            return
        }
        cronErrors[name] = nil
        cronDrafts[name] = schedule.expression
        guard let record = job.record else { return }
        Task {
            let next = await AutomationScheduler.shared.nextRun(forCron: schedule.expression)
            automations.setCron(id: record.id, cron: schedule.expression, nextRunAt: next)
            await AutomationScheduler.shared.wake()
            load()
        }
    }

    func runNow(_ name: String) {
        guard let record = jobs.first(where: { $0.id == name })?.record else { return }
        Task {
            await AutomationScheduler.shared.runNow(id: record.id)
            load()
        }
    }

    func saveActiveHours() {
        guard let hours = ActiveHours.parse(activeHoursText) else {
            activeHoursError = "Use HH:MM-HH:MM, for example 08:00-23:00 (22:00-06:00 wraps midnight)."
            return
        }
        activeHoursError = nil
        hoursStore.text = hours.text
        activeHoursText = hours.text
        Task { await EscalationLadder.shared.wake() }
    }

    func setDeliveryChannel(_ channel: String) {
        deliveryChannel = channel
        UserDefaults.standard.set(channel, forKey: Self.deliveryChannelKey)
        let target = delivery
        for job in jobs {
            if let record = job.record { automations.setDelivery(id: record.id, target) }
        }
        load()
    }
}

struct AutomationsSettingsView: View {
    @StateObject private var model = AutomationsSettingsModel()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        Form {
            jobsSection
            deliverySection
            remindersSection
            runsSection
        }
        .formStyle(.grouped)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    // MARK: Sections

    private var jobsSection: some View {
        Section {
            ForEach(model.jobs) { job in
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: Binding(get: { job.isOn }, set: { model.toggle(job.id, on: $0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(job.definition.title)
                            Text(job.definition.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if job.isOn, let record = job.record {
                        HStack(spacing: 8) {
                            TextField("Cron", text: Binding(get: { model.cronDrafts[job.id] ?? "" }, set: { model.cronDrafts[job.id] = $0 }))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .frame(width: 170)
                                .onSubmit { model.saveCron(job.id) }
                            if model.cronChanged(job.id) {
                                Button("Save") { model.saveCron(job.id) }
                            }
                            Text(model.cronSummary(job.id) ?? "—")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Run now") { model.runNow(job.id) }
                        }
                        if let error = model.cronErrors[job.id] {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        Text(details(record))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let result = record.lastResult {
                            Text(result)
                                .font(.caption)
                                .foregroundStyle(result.hasPrefix("failed") || result.hasPrefix("refused") ? .red : .secondary)
                                .lineLimit(2)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Scheduled jobs")
        } footer: {
            Text("Jobs gather events, ask one model for a structured answer, and either stay quiet, message you, or start a task with the usual approvals. Definitions are code; you choose the schedule.")
        }
    }

    private var deliverySection: some View {
        Section {
            Picker("Send job messages to", selection: Binding(get: { model.deliveryChannel }, set: { model.setDeliveryChannel($0) })) {
                Text("This Mac (panel and notifications)").tag(PanelChannel.channelId)
                if let handle = model.ownerHandle {
                    Text("iMessage to \(handle)").tag(IMessageChannel.channelId)
                }
            }
            if model.ownerHandle == nil {
                Text("Add your handle in Settings ▸ Channels to receive job messages over iMessage.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                TextField("Active hours", text: $model.activeHoursText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 140)
                    .onSubmit { model.saveActiveHours() }
                Button("Save") { model.saveActiveHours() }
                    .disabled(model.activeHoursText == ActiveHoursStore.shared.text)
                Text("Urgency 2 messages wait for this window; urgency 3 does not. Reminders are never held.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = model.activeHoursError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if model.waitingOnOwner > 0 {
                LabeledContent("Waiting for your reply", value: "\(model.waitingOnOwner)")
            }
        } header: {
            Text("Delivery")
        } footer: {
            Text("Urgency 1 only appears in the brief. Urgency 2 is one message per job per hour. Urgency 3 repeats after 30 minutes until you reply; any reply in the thread, or just \"ok\", counts.")
        }
    }

    private var remindersSection: some View {
        Section("Reminders") {
            if model.reminders.isEmpty {
                Text("No reminders scheduled.").foregroundStyle(.secondary)
            }
            ForEach(model.reminders, id: \.id) { reminder in
                HStack {
                    Text(reminder.prompt).lineLimit(1)
                    Spacer()
                    if let runAt = reminder.runAt {
                        Text(Self.dateFormatter.string(from: runAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var runsSection: some View {
        Section("Recent runs") {
            if model.runs.isEmpty {
                Text("No job has run yet.").foregroundStyle(.secondary)
            }
            ForEach(model.runs) { run in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Self.dateFormatter.string(from: run.startedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 120, alignment: .leading)
                    Text(run.jobName)
                        .font(.caption)
                        .fontWeight(.medium)
                    Text(run.outcome)
                        .font(.caption)
                        .foregroundStyle(run.outcome == "failed" || run.outcome == "refused" ? .red : .secondary)
                    Text(run.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if run.tokensIn + run.tokensOut > 0 {
                        Text("\(run.tokensIn + run.tokensOut) tok · \(ProviderTier(rawValue: run.tier)?.letter ?? run.tier)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    // MARK: Pieces

    private func details(_ record: AutomationRecord) -> String {
        var parts: [String] = []
        parts.append("Tier \(ProviderTier(rawValue: record.tier ?? "")?.letter ?? "?")")
        if let next = record.nextRunAt { parts.append("next \(Self.dateFormatter.string(from: next))") }
        if let last = record.lastRunAt { parts.append("last \(Self.dateFormatter.string(from: last))") }
        parts.append(record.deliveryChannel == IMessageChannel.channelId ? "to iMessage" : "to this Mac")
        return parts.joined(separator: " · ")
    }
}
