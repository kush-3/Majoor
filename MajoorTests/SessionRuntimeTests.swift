// SessionRuntimeTests.swift
// MajoorTests — Phase 1 step 2a: events, bus, recorder, store, migration.

import Foundation
import Testing
@testable import Majoor

@Suite("Test host")
struct TestHostTests {
    @Test("the app skips its startup side effects when hosting tests")
    func launchGuard() {
        #expect(AppDelegate.isRunningTests)
    }
}

@Suite("SessionEvent JSON")
struct SessionEventCodingTests {

    nonisolated static let sampleInfo = SessionInfo(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, shortId: 7, kind: .task, state: .running,
        input: "summarize the deck", origin: ChannelRef(channelId: "imessage", threadKey: "imessage:+15550001111"),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), tokensIn: 10, tokensOut: 5, costUSD: 0.01)

    nonisolated static let sampleApproval = ApprovalRequest(
        id: "appr-1", sessionId: sampleInfo.id, title: "Confirm", body: "send_email to a@b.c", category: "email",
        riskClass: .r3, nonce: "K7Q2", actionSignature: "send_email|to=a@b.c",
        requestedAt: Date(timeIntervalSince1970: 1_700_000_100), expiresAt: Date(timeIntervalSince1970: 1_700_000_700),
        isPipelinePlan: false, pipelineSteps: [])

    nonisolated static let samples: [SessionEvent] = [
        .created(sampleInfo),
        .state(id: sampleInfo.id, state: .waitingApproval),
        .step(id: sampleInfo.id, step: StepDTO(timestamp: Date(timeIntervalSince1970: 1_700_000_001), type: "toolCall",
                                              description: "Calling read_file", detail: "path: x")),
        .pipelinePlan(id: sampleInfo.id, text: "1. a\n2. b",
                      steps: [PipelineStepDTO(index: 0, planDescription: "a"), PipelineStepDTO(index: 1, planDescription: "b", enabled: false)]),
        .pipelineStep(id: sampleInfo.id, index: 1, status: "failed", result: nil, error: "boom"),
        .approvalRequested(sampleApproval),
        .approvalResolved(approvalId: "appr-1", approved: true, byChannel: "panel"),
        .cost(id: sampleInfo.id, tokensIn: 1200, tokensOut: 300, sessionUSD: 0.0123, dayUSD: 1.5),
        .finished(id: sampleInfo.id, state: .completed, summary: "done"),
    ]

    @Test("every case survives an encode/decode round trip", arguments: samples)
    func roundTrip(event: SessionEvent) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(event)
        let decoded = try decoder.decode(SessionEvent.self, from: data)
        #expect(decoded == event)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["type"] as? String == event.typeName)
    }

    @Test("an unknown type is rejected, not silently mapped")
    func unknownType() {
        let data = Data(#"{"type":"teleport","session":"11111111-2222-3333-4444-555555555555"}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(SessionEvent.self, from: data) }
    }

    @Test("old stepsJson rows decode into StepDTO unchanged")
    func legacyStepShape() throws {
        let legacy = Data(#"[{"timestamp":123.0,"type":"toolResult","description":"Result","detail":null}]"#.utf8)
        let steps = try JSONDecoder().decode([StepDTO].self, from: legacy)
        #expect(steps.count == 1)
        #expect(steps[0].type == "toolResult")
        #expect(steps[0].taskStep.type == .toolResult)
    }
}

@Suite("EventBus")
struct EventBusTests {

    @Test("replays from inside the ring and demands a snapshot from outside it")
    func resume() async {
        let bus = EventBus(capacity: 5)
        let id = UUID()
        for i in 1...8 {
            await bus.publish(.state(id: id, state: i % 2 == 0 ? .running : .queued))
        }
        // ring holds seq 4...8
        let inside = await bus.subscribe(since: 5)
        #expect(!inside.snapshotRequired)
        #expect(inside.replay.map(\.seq) == [6, 7, 8])

        let edge = await bus.subscribe(since: 3)
        #expect(!edge.snapshotRequired)
        #expect(edge.replay.map(\.seq) == [4, 5, 6, 7, 8])

        let outside = await bus.subscribe(since: 2)
        #expect(outside.snapshotRequired)
        #expect(outside.replay.isEmpty)

        let fresh = await bus.subscribe()
        #expect(fresh.snapshotRequired)

        let current = await bus.subscribe(since: 8)
        #expect(!current.snapshotRequired)
        #expect(current.replay.isEmpty)
        for sub in [inside, edge, outside, fresh, current] { await bus.unsubscribe(sub.id) }
    }

    @Test("live subscribers receive new events in order")
    func live() async {
        let bus = EventBus()
        let sub = await bus.subscribe(since: 0)
        let id = UUID()
        await bus.publish(.state(id: id, state: .running))
        await bus.publish(.finished(id: id, state: .completed, summary: "ok"))
        var seen: [Int] = []
        for await item in sub.stream {
            seen.append(item.seq)
            if seen.count == 2 { break }
        }
        #expect(seen == [1, 2])
        await bus.unsubscribe(sub.id)
    }

    @Test("a subscriber that overflows its buffer is cut off so it resyncs")
    func overflow() async {
        let bus = EventBus()
        let sub = await bus.subscribe(since: 0, buffer: 2)
        let id = UUID()
        for _ in 0..<10 {
            await bus.publish(.state(id: id, state: .running))
        }
        #expect(await bus.subscriberCount == 0)
        var delivered = 0
        for await _ in sub.stream { delivered += 1 }   // ends because the bus finished it
        #expect(delivered <= 2)
    }
}

@Suite("TaskRecorder")
struct TaskRecorderTests {

    @Test("the first of complete/fail wins; a stop cannot be followed by success")
    func finishOnce() async {
        let bus = EventBus()
        let recorder = TaskRecorder(sessionId: UUID(), userInput: "x", bus: bus, persist: nil)
        await recorder.append(StepDTO(type: "thinking", description: "Thinking"))
        #expect(await recorder.fail(.cancelled))
        #expect(await recorder.complete(summary: "late success") == false)
        #expect(await recorder.status == .failed)
        #expect(await recorder.summary == IncompleteReason.cancelled.userFacing)
        let sub = await bus.subscribe(since: 0)
        #expect(sub.replay.last?.event == .finished(id: recorder.sessionId, state: .stopped, summary: IncompleteReason.cancelled.userFacing))
        await bus.unsubscribe(sub.id)
    }

    @Test("usage accumulates and the snapshot carries real in/out counts")
    func usage() async {
        var persisted: [TaskSnapshot] = []
        let box = Box()
        let recorder = TaskRecorder(sessionId: UUID(), userInput: "y", bus: nil, persist: { box.append($0) })
        await recorder.addUsage(input: 100, output: 20, model: "m1")
        await recorder.addUsage(input: 50, output: 5, model: "")
        await recorder.append(StepDTO(type: "response", description: "Done"))
        #expect(await recorder.complete(summary: "ok"))
        await recorder.append(StepDTO(type: "error", description: "ignored after finishing"))
        #expect(await recorder.steps.count == 1)
        persisted = box.items
        #expect(persisted.count == 1)
        #expect(persisted[0].tokensIn == 150)
        #expect(persisted[0].tokensOut == 25)
        #expect(persisted[0].modelUsed == "m1")
        #expect(persisted[0].steps.count == 1)
        #expect(persisted[0].status == .completed)
    }

    nonisolated final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var items: [TaskSnapshot] = []
        func append(_ s: TaskSnapshot) { lock.lock(); items.append(s); lock.unlock() }
    }
}

@Suite("SessionStore and migration v5")
struct SessionStoreTests {

    private func temporaryDatabasePath() -> String {
        NSTemporaryDirectory() + "majoor-test-\(UUID().uuidString).sqlite"
    }

    @Test("a fresh database migrates and round-trips sessions, tasks and approvals")
    func freshDatabase() throws {
        let path = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let queue = try DatabaseManager.openAndMigrate(path: path)
        let store = SessionStore(db: queue)
        let tasks = TaskPersistence(db: queue)

        var info = SessionInfo(shortId: 1, kind: .task, state: .running, input: "hello", origin: .panel)
        store.upsert(info)
        info.state = .completed
        info.summary = "done"
        store.upsert(info)
        let loaded = store.recent()
        #expect(loaded.count == 1)
        #expect(loaded[0].state == .completed)
        #expect(loaded[0].summary == "done")
        #expect(loaded[0].origin == .panel)

        let snapshot = TaskSnapshot(id: info.id, userInput: "hello", createdAt: Date(), status: .completed, summary: "done",
                                    completedAt: Date(), tokensIn: 10, tokensOut: 4, modelUsed: "m", steps: [StepDTO(type: "response", description: "r")])
        tasks.save(snapshot)
        let back = tasks.loadRecentSnapshots()
        #expect(back.count == 1)
        #expect(back[0].tokensUsed == 14)
        #expect(back[0].steps == snapshot.steps)

        let request = ApprovalRequest(id: "a1", sessionId: info.id, title: "t", body: "b", category: "c", riskClass: .r3,
                                      nonce: "ABCD", actionSignature: "sig", requestedAt: Date(), expiresAt: Date().addingTimeInterval(600),
                                      isPipelinePlan: false, pipelineSteps: [])
        store.record(request)
        store.resolve(approvalId: "a1", decision: ApprovalDecision(approved: false, feedback: "no"), byChannel: "panel")
        let record = try #require(store.approval(id: "a1"))
        #expect(record.decision == "denied")
        #expect(record.decidedByChannel == "panel")
        #expect(record.feedback == "no")
    }

    @Test("sessions alive at the last shutdown are marked interrupted")
    func interrupted() throws {
        let path = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = SessionStore(db: try DatabaseManager.openAndMigrate(path: path))
        store.upsert(SessionInfo(shortId: 1, kind: .task, state: .running, input: "a", origin: .panel))
        store.upsert(SessionInfo(shortId: 2, kind: .task, state: .waitingApproval, input: "b", origin: .panel))
        store.upsert(SessionInfo(shortId: 3, kind: .task, state: .completed, input: "c", origin: .panel))
        #expect(store.markInterrupted() == 2)
        let states = store.recent().map(\.state)
        #expect(states.filter { $0 == .failed }.count == 2)
        #expect(states.contains(.completed))
    }

    @Test("migrating twice is a no-op and a copy of the real database migrates cleanly")
    func idempotentAndRealCopy() throws {
        let path = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try DatabaseManager.openAndMigrate(path: path)
        _ = try DatabaseManager.openAndMigrate(path: path)

        let real = NSHomeDirectory() + "/Library/Application Support/ai.majoor.agent/majoor.sqlite"
        guard FileManager.default.fileExists(atPath: real) else { return }
        let copy = temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(atPath: copy) }
        try FileManager.default.copyItem(atPath: real, toPath: copy)
        let queue = try DatabaseManager.openAndMigrate(path: copy)
        _ = SessionStore(db: queue).recent()
        _ = TaskPersistence(db: queue).loadRecentSnapshots()
    }
}
