// EventBus.swift
// Majoor — Sequenced, replayable event stream
//
// Publishes SessionEvents to any number of subscribers with increasing
// sequence numbers and keeps a ring of recent events so a reconnecting
// client can ask for everything after seq N. When N is older than the
// ring, the subscriber is told to fetch a snapshot first. A subscriber
// that falls further behind than its buffer has its stream ended; it
// resubscribes with its last seq and catches up the same way.

import Foundation

actor EventBus {

    nonisolated struct Subscription: Sendable {
        let id: UUID
        /// True when the caller must load current state before trusting the
        /// stream: nothing was replayed, or the resume point is older than the ring.
        let snapshotRequired: Bool
        let replay: [SequencedEvent]
        let stream: AsyncStream<SequencedEvent>
    }

    private let capacity: Int
    private var ring: [SequencedEvent] = []
    private var subscribers: [UUID: AsyncStream<SequencedEvent>.Continuation] = [:]
    private(set) var latestSeq = 0

    init(capacity: Int = 1000) {
        self.capacity = max(1, capacity)
    }

    var ringCount: Int { ring.count }
    var subscriberCount: Int { subscribers.count }

    @discardableResult
    func publish(_ event: SessionEvent) -> SequencedEvent {
        latestSeq += 1
        let item = SequencedEvent(seq: latestSeq, at: Date(), event: event)
        ring.append(item)
        if ring.count > capacity {
            ring.removeFirst(ring.count - capacity)
        }
        for (id, continuation) in subscribers {
            switch continuation.yield(item) {
            case .enqueued:
                break
            case .dropped, .terminated:
                // Too far behind to be trusted: end the stream so the subscriber
                // resubscribes with `since:` and catches up from the ring or a snapshot.
                continuation.finish()
                subscribers[id] = nil
            @unknown default:
                break
            }
        }
        return item
    }

    func subscribe(since: Int? = nil, buffer: Int = 2000) -> Subscription {
        let id = UUID()
        var replay: [SequencedEvent] = []
        var snapshotRequired = true
        if let since {
            if since >= latestSeq {
                snapshotRequired = false
            } else {
                let oldest = ring.first?.seq ?? (latestSeq + 1)
                if since + 1 >= oldest {
                    snapshotRequired = false
                    replay = ring.filter { $0.seq > since }
                }
            }
        }
        let stream = AsyncStream<SequencedEvent>(bufferingPolicy: .bufferingNewest(max(1, buffer))) { continuation in
            subscribers[id] = continuation
            continuation.onTermination = { @Sendable _ in
                Task { await self.remove(id) }
            }
        }
        return Subscription(id: id, snapshotRequired: snapshotRequired, replay: replay, stream: stream)
    }

    func unsubscribe(_ id: UUID) {
        subscribers[id]?.finish()
        subscribers[id] = nil
    }

    private func remove(_ id: UUID) {
        subscribers[id] = nil
    }
}
