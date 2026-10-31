// ClientModeTests.swift
// MajoorTests — Phase 1 step 5: reconnect schedule, seq dedupe, snapshot
// replace, and the remote client against a loopback runtime.

import Foundation
import Testing
@testable import Majoor

@Suite("Reconnect backoff and event cursor")
struct ClientPureTests {

    @Test("backoff follows 1, 2, 4, 8, 15, 30 and caps at 30 until reset")
    func backoffSchedule() {
        var backoff = ReconnectBackoff()
        let delays = (0..<8).map { _ in backoff.next() }
        #expect(delays == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15), .seconds(30), .seconds(30), .seconds(30)])
        #expect(backoff.attempt == 8)
        backoff.reset()
        #expect(backoff.attempt == 0)
        #expect(backoff.next() == .seconds(1))
    }

    @Test("the cursor drops replayed and out-of-order events and follows a snapshot")
    func cursorDedupe() {
        var cursor = EventCursor()
        #expect(cursor.lastSeq == nil)
        let results = [1, 2, 2, 1, 5, 3].map { cursor.accept($0) }
        #expect(results == [true, true, false, false, true, false])
        cursor.reset(to: 10)
        let afterReset = [10, 11].map { cursor.accept($0) }
        #expect(afterReset == [false, true])
        #expect(cursor.lastSeq == 11)
    }
}

@Suite("TaskManager snapshot replace")
@MainActor
struct TaskManagerSnapshotTests {

    private func snapshot(sessions: [SessionInfo] = [], approvals: [ApprovalRequest] = [], recent: [TaskSnapshot] = [], seq: Int) -> SnapshotBody {
        SnapshotBody(sessions: sessions, pendingApprovals: approvals, recentTasks: recent, settings: [:], dayUSD: 1.5, seq: seq)
    }

    private func recentTask(_ input: String, at: TimeInterval) -> TaskSnapshot {
        TaskSnapshot(id: UUID(), userInput: input, createdAt: Date(timeIntervalSince1970: at), status: .completed, summary: "done",
                     completedAt: Date(timeIntervalSince1970: at + 1), tokensIn: 1, tokensOut: 1, modelUsed: "m", steps: [])
    }

    @Test("a snapshot replaces remote tasks and approvals but keeps local ones")
    func replace() {
        let manager = TaskManager()
        manager.tasks = []
        let local = AgentTask(userInput: "local work")
        local.status = .completed
        manager.addTask(local)

        let first = snapshot(sessions: [SessionEventCodingTests.sampleInfo], approvals: [SessionEventCodingTests.sampleApproval],
                             recent: [recentTask("old remote", at: 1_000)], seq: 5)
        manager.applySnapshot(first)
        #expect(manager.tasks.count == 3)
        #expect(manager.tasks.filter { $0.source == TaskManager.remoteSource }.count == 2)
        #expect(manager.isRemote(sessionId: SessionEventCodingTests.sampleInfo.id))
        #expect(manager.isRemoteApproval(id: "appr-1"))
        #expect(manager.pendingApprovals.count == 1)
        #expect(manager.activeConfirmation?.id == "appr-1")
        #expect(manager.isTaskRunning)

        // Reconnect: the runtime now reports nothing running and a different history.
        let second = snapshot(recent: [recentTask("newer remote", at: 2_000)], seq: 9)
        manager.applySnapshot(second)
        #expect(manager.tasks.map(\.userInput).sorted() == ["local work", "newer remote"])
        #expect(manager.tasks.first { $0.userInput == "local work" }?.source == TaskManager.localSource)
        #expect(manager.pendingApprovals.isEmpty)
        #expect(manager.activeConfirmation == nil)
        #expect(!manager.isRemote(sessionId: SessionEventCodingTests.sampleInfo.id))
        #expect(!manager.isTaskRunning)
    }

    @Test("remote events mark their session remote; local events do not")
    func sourceTagging() {
        let manager = TaskManager()
        manager.tasks = []
        let remote = SessionInfo(shortId: 1, kind: .task, state: .running, input: "remote", origin: .panel)
        let local = SessionInfo(shortId: 2, kind: .task, state: .running, input: "local", origin: .panel)
        manager.apply(.created(remote), source: TaskManager.remoteSource)
        manager.apply(.created(local))
        #expect(manager.isRemote(sessionId: remote.id))
        #expect(!manager.isRemote(sessionId: local.id))
        #expect(manager.tasks.first { $0.id == remote.id }?.source == TaskManager.remoteSource)
        #expect(manager.tasks.first { $0.id == local.id }?.source == TaskManager.localSource)
    }
}

/// Collects a client's update stream.
nonisolated final class UpdateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [RemoteRuntimeClient.Update] = []
    func append(_ update: RemoteRuntimeClient.Update) { lock.withLock { items.append(update) } }
    var all: [RemoteRuntimeClient.Update] { lock.withLock { items } }
    var snapshots: [SnapshotBody] { all.compactMap { if case .snapshot(let body) = $0 { return body } else { return nil } } }
    var events: [SequencedEvent] { all.compactMap { if case .event(let item) = $0 { return item } else { return nil } } }
    var states: [RemoteRuntimeClient.State] { all.compactMap { if case .state(let state) = $0 { return state } else { return nil } } }
}

@Suite("Remote runtime client over loopback", .serialized)
struct RemoteRuntimeClientTests {

    private struct Runtime {
        let server: ControlServer
        let pairing: PairingManager
        let manager: SessionManager
        let port: UInt16
        let path: String
    }

    private func startRuntime(provider: ScriptedProvider, port: UInt16 = 0, existing: Runtime? = nil) async throws -> Runtime {
        let path = existing?.path ?? NSTemporaryDirectory() + "majoor-client-\(UUID().uuidString).sqlite"
        let manager: SessionManager
        if let existing { manager = existing.manager } else { manager = await makeManager(route: { _ in (provider, []) }) }
        let pairing: PairingManager
        if let existing { pairing = existing.pairing } else { pairing = PairingManager(store: ClientStore(db: try DatabaseManager.openAndMigrate(path: path))) }
        let server = ControlServer()
        await server.configure(
            gateway: LocalSessionGateway(manager: manager, channelId: "control", trust: .authenticatedClient),
            pairing: pairing, bus: manager.bus,
            runtime: ControlRuntimeInfo(runtimeId: "rt-client-test", serverVersion: "test", mode: "runtime"))
        await server.start(address: "127.0.0.1", port: port)
        let stream = await server.stateStream()
        var bound: UInt16 = 0
        for await state in stream {
            if case .listening(_, let p) = state { bound = p; break }
            if case .failed(let message) = state { Issue.record("listener failed: \(message)"); break }
        }
        try #require(bound != 0)
        return Runtime(server: server, pairing: pairing, manager: manager, port: bound, path: path)
    }

    @Test("pair, connect, snapshot, submit, events; reconnect after the runtime restarts")
    func lifecycle() async throws {
        let provider = ScriptedProvider([.text("First done"), .text("Second done")])
        let runtime = try await startRuntime(provider: provider)
        defer { try? FileManager.default.removeItem(atPath: runtime.path) }

        let code = await runtime.pairing.mintCode()
        let ok = try await RemoteRuntimeClient.pair(host: "127.0.0.1", port: runtime.port, code: code.code, deviceName: "Test laptop")
        #expect(!ok.token.isEmpty)
        await #expect(throws: RemoteClientError.self) {
            _ = try await RemoteRuntimeClient.pair(host: "127.0.0.1", port: runtime.port, code: "NOPE", deviceName: "x")
        }

        let client = RemoteRuntimeClient(appVersion: "test")
        let box = UpdateBox()
        let updates = await client.updates()
        let collector = Task { for await update in updates { box.append(update) } }
        defer { collector.cancel() }

        await client.configure(ClientCredentials(host: "127.0.0.1", port: runtime.port, clientId: ok.clientId, token: ok.token, runtimeId: nil))
        await client.start()
        #expect(await waitUntil { await client.state.isConnected })
        #expect(await client.currentCredentials?.runtimeId == "rt-client-test")
        #expect(await waitUntil { !box.snapshots.isEmpty })
        #expect(box.snapshots.first?.sessions.isEmpty == true)

        let ack = try await client.submit(text: "do the first thing", threadKey: nil)
        #expect(ack.shortId == 1)
        #expect(await waitUntil { box.events.contains { if case .finished(let id, .completed, "First done") = $0.event { return id == ack.sessionId }; return false } })
        let seqBefore = try #require(await client.lastSeq)
        #expect(seqBefore > 0)
        #expect(Set(box.events.map(\.seq)).count == box.events.count)

        // The runtime goes away: the client reports reconnecting with backoff.
        await runtime.server.stop()
        #expect(await waitUntil { if case .reconnecting = await client.state { return true }; return false })

        // It comes back on the same port with the same bus: the client resumes
        // from its cursor, gets no duplicate events, and can submit again.
        let restarted = try await startRuntime(provider: provider, port: runtime.port, existing: runtime)
        await client.wake()
        #expect(await waitUntil(timeout: .seconds(20)) { await client.state.isConnected })
        let ack2 = try await client.submit(text: "do the second thing", threadKey: nil)
        #expect(ack2.shortId == 2)
        #expect(await waitUntil { box.events.contains { if case .finished(let id, .completed, "Second done") = $0.event { return id == ack2.sessionId }; return false } })
        #expect(Set(box.events.map(\.seq)).count == box.events.count)
        #expect(box.events.allSatisfy { $0.seq > 0 })

        // Revoked on the runtime: bye, then a failed hello stops the retries for good.
        await restarted.server.revoke(clientId: ok.clientId)
        #expect(await waitUntil(timeout: .seconds(20)) { if case .failed = await client.state { return true }; return false })
        await client.stop()
        await restarted.server.stop()
    }

    @Test("requests fail fast when there is no connection")
    func notConnected() async throws {
        let client = RemoteRuntimeClient(appVersion: "test")
        await #expect(throws: RemoteClientError.notConfigured) { _ = try await client.sessions() }
        await client.configure(ClientCredentials(host: "127.0.0.1", port: 1, clientId: "c", token: "t", runtimeId: nil))
        await #expect(throws: RemoteClientError.notConnected) { _ = try await client.sessions() }
        let gateway = RemoteSessionGateway(client: client)
        #expect(await gateway.list().isEmpty)
        #expect(await gateway.answerApproval(id: "x", nonce: nil, decision: ApprovalDecision(approved: true)) == .badNonce)
        #expect(await gateway.defaultThreadKey() == "client:c")
    }
}
