// EventSource.swift
// Majoor — Event sources and the hub that supervises them (Phase 2 step 4)
//
// A source watches one thing (the inbox, the calendar, Slack, the phone's
// location) and yields `SourceEvent`s. The hub starts every source, restarts
// one that fails with backoff and gives up after five quick exits (the same
// shape as the iMessage helper), fans events out to subscribers, and keeps a
// bounded ring of recent events per source so a job can gather "what
// happened since my last run" without every source re-fetching.
//
// Payloads are data about the owner's life; they are never shown to a model
// raw. Every source wraps text through `UntrustedContent` before it goes in
// a payload, and the job runner wraps once more when it assembles a prompt.

import Foundation

nonisolated enum SourceEventKind: String, Codable, Sendable {
    case newEmail
    case calendarChanged
    case slackMessage
    case locationFix
}

nonisolated struct SourceEvent: Sendable, Codable, Equatable, Identifiable {
    var id: String
    var sourceId: String
    var kind: SourceEventKind
    var at: Date
    var payload: JSONValue

    init(sourceId: String, kind: SourceEventKind, at: Date = Date(), payload: JSONValue, id: String = UUID().uuidString) {
        self.id = id
        self.sourceId = sourceId
        self.kind = kind
        self.at = at
        self.payload = payload
    }
}

/// One watched thing. `start()` runs until the source stops working (throw)
/// or `stop()` cancels it (return); the hub calls it again after a backoff.
/// `events` is one stream for the life of the instance: a restarted source
/// keeps yielding on it, so the hub's consumer never has to resubscribe.
nonisolated protocol EventSource: Sendable {
    var id: String { get }
    var dataClass: DataClass { get }
    func start() async throws
    func stop() async
    var events: AsyncStream<SourceEvent> { get }
}

actor EventHub {

    static let shared = EventHub()

    static let restartBackoff: [Duration] = [.seconds(5), .seconds(10), .seconds(20), .seconds(40), .seconds(80)]
    static let maxRestarts = 5
    static let healthyRunInterval: TimeInterval = 300
    static let ringCapacity = 1000
    static let subscriberBuffer = 1000

    nonisolated enum SourceStatus: Sendable, Equatable {
        case stopped
        case running
        case restarting(attempt: Int, inSeconds: Int)
        case failed(String)

        var text: String {
            switch self {
            case .stopped: return "Off"
            case .running: return "Running"
            case .restarting(let attempt, let seconds): return "Restart \(attempt) in \(seconds) s"
            case .failed(let detail): return "Failed: \(detail)"
            }
        }
    }

    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> Date

    private var sources: [String: any EventSource] = [:]
    private var order: [String] = []
    private var runTasks: [String: Task<Void, Never>] = [:]
    private var pumpTasks: [String: Task<Void, Never>] = [:]
    private var rings: [String: [SourceEvent]] = [:]
    private var statuses: [String: SourceStatus] = [:]
    private var subscribers: [UUID: AsyncStream<SourceEvent>.Continuation] = [:]
    private var statusSubscribers: [UUID: AsyncStream<[String: SourceStatus]>.Continuation] = [:]
    private var started = false

    /// `sleep` and `now` are seams so tests can run the restart ladder in
    /// milliseconds; production uses the real clock.
    init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.sleep = sleep
        self.now = now
    }

    // MARK: Registration and lifecycle

    /// Registers a source; if the hub is already running, starts it too.
    func register(_ source: any EventSource) {
        guard sources[source.id] == nil else { return }
        sources[source.id] = source
        order.append(source.id)
        statuses[source.id] = .stopped
        if started { launch(source) }
    }

    func start() {
        guard !started else { return }
        started = true
        for id in order { if let source = sources[id] { launch(source) } }
    }

    func stop() async {
        started = false
        for (_, task) in runTasks { task.cancel() }
        for (_, task) in pumpTasks { task.cancel() }
        runTasks.removeAll()
        pumpTasks.removeAll()
        for id in order { if let source = sources[id] { await source.stop() } }
        for id in order { setStatus(.stopped, for: id) }
    }

    /// Clears a failed source's strike count and starts it again.
    func restart(_ sourceId: String) {
        guard let source = sources[sourceId], started else { return }
        runTasks[sourceId]?.cancel()
        runTasks[sourceId] = nil
        launch(source)
    }

    func source(id: String) -> (any EventSource)? { sources[id] }
    var sourceIds: [String] { order }

    private func launch(_ source: any EventSource) {
        if pumpTasks[source.id] == nil {
            pumpTasks[source.id] = Task { [weak self] in
                for await event in source.events {
                    await self?.record(event)
                }
            }
        }
        guard runTasks[source.id] == nil else { return }
        runTasks[source.id] = Task { [weak self] in
            await self?.supervise(source)
        }
    }

    /// One source's life: run, and on failure restart with backoff; a run
    /// longer than `healthyRunInterval` clears the strike count.
    private func supervise(_ source: any EventSource) async {
        var restarts = 0
        while !Task.isCancelled {
            setStatus(.running, for: source.id)
            let startedAt = now()
            do {
                try await source.start()
                // A clean return means stop() was called.
                if Task.isCancelled { break }
            } catch is CancellationError {
                break
            } catch {
                MajoorLogger.error("Source \(source.id) failed: \(error)")
            }
            if Task.isCancelled { break }
            if now().timeIntervalSince(startedAt) > Self.healthyRunInterval { restarts = 0 }
            restarts += 1
            if restarts > Self.maxRestarts {
                let detail = "\(source.id) failed \(restarts) times in a row"
                setStatus(.failed(detail), for: source.id)
                MajoorLogger.error("Source \(detail); giving up until restarted from Settings")
                runTasks[source.id] = nil
                return
            }
            let delay = Self.restartBackoff[min(restarts - 1, Self.restartBackoff.count - 1)]
            setStatus(.restarting(attempt: restarts, inSeconds: Int(delay.components.seconds)), for: source.id)
            do { try await sleep(delay) } catch { break }
        }
        setStatus(.stopped, for: source.id)
        runTasks[source.id] = nil
    }

    // MARK: Events

    private func record(_ event: SourceEvent) {
        var ring = rings[event.sourceId] ?? []
        ring.append(event)
        if ring.count > Self.ringCapacity { ring.removeFirst(ring.count - Self.ringCapacity) }
        rings[event.sourceId] = ring
        for continuation in subscribers.values { continuation.yield(event) }
    }

    /// Every event from every source, from now on. Slow consumers keep the
    /// newest 1,000; nothing blocks a source.
    func subscribe() -> AsyncStream<SourceEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(Self.subscriberBuffer)) { continuation in
            subscribers[id] = continuation
            continuation.onTermination = { @Sendable _ in
                Task { await self.removeSubscriber(id) }
            }
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    /// Recent events from one source after `since`, oldest first. Bounded by
    /// the ring: a job that has not run for days sees at most 1,000.
    func events(from sourceId: String, since: Date) -> [SourceEvent] {
        (rings[sourceId] ?? []).filter { $0.at > since }
    }

    func recentEvents(from sourceId: String, limit: Int = ringCapacity) -> [SourceEvent] {
        Array((rings[sourceId] ?? []).suffix(limit))
    }

    // MARK: Status

    func status(of sourceId: String) -> SourceStatus {
        statuses[sourceId] ?? .stopped
    }

    func allStatuses() -> [String: SourceStatus] { statuses }

    func statusStream() -> AsyncStream<[String: SourceStatus]> {
        let id = UUID()
        let current = statuses
        return AsyncStream { continuation in
            continuation.yield(current)
            statusSubscribers[id] = continuation
            continuation.onTermination = { @Sendable _ in
                Task { await self.removeStatusSubscriber(id) }
            }
        }
    }

    private func removeStatusSubscriber(_ id: UUID) {
        statusSubscribers[id] = nil
    }

    private func setStatus(_ status: SourceStatus, for sourceId: String) {
        guard statuses[sourceId] != status else { return }
        statuses[sourceId] = status
        for continuation in statusSubscribers.values { continuation.yield(statuses) }
    }
}
