// SourcesRuntime.swift
// Majoor — Wires the four sources into the shared hub (runtime mode)
//
// One place that knows which sources exist, so `AppDelegate` calls a single
// method and Settings ▸ Location can reach the location source and the
// endpoint's state.

import Foundation

@MainActor
final class SourcesRuntime {

    static let shared = SourcesRuntime()

    private(set) var location: LocationSource?
    private(set) var started = false

    private init() {}

    /// Registers Gmail, Calendar, Slack and Location with `EventHub.shared`
    /// and starts them. Called once, in runtime mode only.
    func start() {
        guard !started else { return }
        started = true
        let devices = LocationDeviceStore.shared
        let endpoint = LocationEndpoint(port: LocationEndpoint.defaultPort) { token in devices.device(forToken: token)?.deviceId }
        let location = LocationSource(endpoint: endpoint, fixes: LocationFixStore.shared)
        self.location = location
        let gmail = GmailSource(reader: LiveGmailReader(), cursors: SourceStateStore.shared)
        let calendar = CalendarSource(reader: LiveCalendarReader())
        let slack = SlackSource(reader: LiveSlackReader(), cursors: SourceStateStore.shared)
        Task {
            let hub = EventHub.shared
            await hub.register(gmail)
            await hub.register(calendar)
            await hub.register(slack)
            await hub.register(location)
            await hub.start()
            MajoorLogger.log("📡 Event sources started: gmail, calendar, slack, location")
        }
    }

    func stop() async {
        guard started else { return }
        started = false
        await EventHub.shared.stop()
    }
}
