// ControlAPITests.swift
// MajoorTests — Phase 1 step 4: wire format, pairing, settings rules, and a
// loopback round trip through the real listener.

import Foundation
import Testing
@testable import Majoor

@Suite("JSONValue")
struct JSONValueTests {
    @Test("round-trips mixed documents and keeps integers integral")
    func roundTrip() throws {
        let text = #"{"a":1,"b":2.5,"c":true,"d":null,"e":[1,"x",{"f":false}],"g":"s"}"#
        let value = try JSONValue(data: Data(text.utf8))
        #expect(value["a"]?.intValue == 1)
        #expect(value["b"]?.doubleValue == 2.5)
        #expect(value["c"]?.boolValue == true)
        #expect(value["d"]?.isNull == true)
        #expect(value["e"]?.arrayValue?.count == 3)
        let again = try JSONValue(data: try value.data())
        #expect(again == value)
        let encoded = String(decoding: try value.data(), as: UTF8.self)
        #expect(encoded.contains(#""a":1,"#))
        #expect(!encoded.contains("1.0,"))
    }

    @Test("bridges typed values both ways")
    func bridging() throws {
        let info = SessionEventCodingTests.sampleInfo
        let tree = try JSONValue.encoding(info)
        #expect(tree["shortId"]?.intValue == 7)
        #expect(try tree.decoded(as: SessionInfo.self) == info)
    }
}

@Suite("Control protocol")
struct ControlProtocolTests {
    @Test("frames round-trip with typed bodies and reply ids")
    func frames() throws {
        let hello = try ControlFrame(type: .hello, body: HelloRequest(clientId: "c", token: "t", appVersion: "1", protocolVersion: 1), id: "r1")
        let data = try hello.encoded()
        let decoded = try ControlFrame.decode(data)
        #expect(decoded.type == .hello)
        #expect(decoded.id == "r1")
        #expect(try decoded.body(as: HelloRequest.self).token == "t")
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""protocol":1"#))

        let event = try ControlFrame(type: .event, body: SequencedEvent(seq: 9, at: Date(timeIntervalSince1970: 1_700_000_000), event: .finished(id: UUID(), state: .completed, summary: "ok")))
        let back = try ControlFrame.decode(try event.encoded())
        #expect(try back.body(as: SequencedEvent.self).seq == 9)

        let error = ControlFrame.error(.badNonce, "nope", replyTo: "r2")
        #expect(error.replyTo == "r2")
        #expect(error.body["code"]?.stringValue == "bad_nonce")
    }

    @Test("settings: allowlist, types, and tighten-only permission mode")
    func settings() {
        #expect(ControlSettings.validate(key: "anthropicKey", value: .string("x"), currentMode: .standard) == .notAllowed)
        #expect(ControlSettings.validate(key: "maxConcurrentSessions", value: .number(0), currentMode: .standard) == .badRequest)
        #expect(ControlSettings.validate(key: "maxConcurrentSessions", value: .number(4), currentMode: .standard) == nil)
        #expect(ControlSettings.validate(key: "showNotifications", value: .string("yes"), currentMode: .standard) == .badRequest)
        #expect(ControlSettings.validate(key: "permissionMode", value: .string("auto"), currentMode: .standard) == .needsLocalApproval)
        #expect(ControlSettings.validate(key: "permissionMode", value: .string("standard"), currentMode: .auto) == nil)
        #expect(ControlSettings.validate(key: "permissionMode", value: .string("manual"), currentMode: .standard) == nil)
        #expect(ControlSettings.validate(key: "permissionMode", value: .string("standard"), currentMode: .manual) == .needsLocalApproval)
        #expect(ControlSettings.validate(key: "permissionMode", value: .string("yolo"), currentMode: .standard) == .badRequest)
        let values = ControlSettings.values(for: ["permissionMode", "dailySpendCapUSD", "secret"])
        #expect(Set(values.keys) == ["permissionMode", "dailySpendCapUSD"])
    }

    @Test("Tailscale address predicate")
    func tailscale() {
        #expect(TailscaleInterface.isTailscaleAddress("100.64.0.1"))
        #expect(TailscaleInterface.isTailscaleAddress("100.127.255.254"))
        #expect(!TailscaleInterface.isTailscaleAddress("100.128.0.1"))
        #expect(!TailscaleInterface.isTailscaleAddress("10.0.0.1"))
        #expect(!TailscaleInterface.isTailscaleAddress("nope"))
    }
}

@Suite("Pairing")
struct PairingTests {
    private func makeManager() throws -> (PairingManager, String) {
        let path = NSTemporaryDirectory() + "majoor-pair-\(UUID().uuidString).sqlite"
        return (PairingManager(store: ClientStore(db: try DatabaseManager.openAndMigrate(path: path))), path)
    }

    @Test("a code is single use, case-insensitive, and expires")
    func codes() async throws {
        let (manager, path) = try makeManager()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let now = Date()
        let code = await manager.mintCode(now: now)
        #expect(code.code.count == 8)
        await #expect(throws: PairingManager.RedeemError.wrongCode) { try await manager.redeem(code: "ZZZZZZZZ", deviceName: "x", now: now) }
        let ok = try await manager.redeem(code: code.code.lowercased(), deviceName: "Laptop", now: now)
        #expect(!ok.token.isEmpty)
        await #expect(throws: PairingManager.RedeemError.noCode) { try await manager.redeem(code: code.code, deviceName: "x", now: now) }
        let stale = await manager.mintCode(now: now)
        await #expect(throws: PairingManager.RedeemError.expired) {
            try await manager.redeem(code: stale.code, deviceName: "x", now: now.addingTimeInterval(PairingManager.codeLifetime + 1))
        }
        #expect(await manager.authenticate(clientId: ok.clientId, token: ok.token))
        #expect(!(await manager.authenticate(clientId: ok.clientId, token: ok.token + "x")))
        #expect(!(await manager.authenticate(clientId: "nobody", token: ok.token)))
        await manager.revoke(clientId: ok.clientId)
        #expect(!(await manager.authenticate(clientId: ok.clientId, token: ok.token)))
        #expect(await manager.clients().first?.isRevoked == true)
    }

    @Test("five wrong codes lock pairing for the window")
    func lockout() async throws {
        let (manager, path) = try makeManager()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let now = Date()
        let code = await manager.mintCode(now: now)
        for _ in 0..<5 {
            _ = try? await manager.redeem(code: "WRONGONE", deviceName: "x", now: now)
        }
        await #expect(throws: PairingManager.RedeemError.lockedOut) { try await manager.redeem(code: code.code, deviceName: "x", now: now) }
        #expect(await manager.isLockedOut)
        // Once the window passes, pairing works again (with a fresh code: the old one expired).
        let later = now.addingTimeInterval(PairingManager.lockoutWindow + 1)
        let fresh = await manager.mintCode(now: later)
        _ = try await manager.redeem(code: fresh.code, deviceName: "x", now: later)
    }
}

/// A minimal client: connect, send frames, read frames with a timeout.
nonisolated final class ControlTestClient: @unchecked Sendable {
    let peer: WebSocketPeer
    private let frames: AsyncThrowingStream<Data, Error>
    private var iterator: AsyncThrowingStream<Data, Error>.AsyncIterator
    private let lock = NSLock()
    private var backlog: [ControlFrame] = []

    init(port: UInt16) {
        peer = WebSocketPeer.client(host: "127.0.0.1", port: port, queue: DispatchQueue(label: "test-client"))
        frames = peer.incoming
        iterator = frames.makeAsyncIterator()
    }

    func connect() async throws { try await peer.start() }

    func send(_ frame: ControlFrame) async throws { try await peer.send(frame: frame) }

    /// The next frame of the given type, skipping others (which are kept).
    func wait(for type: ControlMessageType, timeout: Duration = .seconds(10)) async throws -> ControlFrame {
        if let index = lock.withLock({ backlog.firstIndex { $0.type == type } }) {
            return lock.withLock { backlog.remove(at: index) }
        }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            guard let data = try await iterator.next() else { throw WebSocketError.closed }
            let frame = try ControlFrame.decode(data)
            if frame.type == type { return frame }
            lock.withLock { backlog.append(frame) }
        }
        throw WebSocketError.timeout
    }

    func close() { peer.close() }
}

@Suite("Control server loopback", .serialized)
struct ControlServerTests {

    private func startServer(provider: ScriptedProvider, tool: EchoTool = EchoTool()) async throws -> (ControlServer, PairingManager, UInt16, String) {
        let path = NSTemporaryDirectory() + "majoor-control-\(UUID().uuidString).sqlite"
        let manager = await makeManager(route: { _ in (provider, []) }, tool: tool)
        let pairing = PairingManager(store: ClientStore(db: try DatabaseManager.openAndMigrate(path: path)))
        let server = ControlServer()
        await server.configure(
            gateway: LocalSessionGateway(manager: manager, channelId: "control", trust: .authenticatedClient),
            pairing: pairing, bus: manager.bus,
            runtime: ControlRuntimeInfo(runtimeId: "rt-test", serverVersion: "test", mode: "runtime"))
        await server.start(address: "127.0.0.1", port: 0)
        let stream = await server.stateStream()
        var port: UInt16 = 0
        var lastState: ControlServer.State = .stopped
        let waited = await waitUntil(timeout: .seconds(10)) {
            // Drain whatever the stream has yielded so far; stop at listening.
            return await server.state.isListening
        }
        for await state in stream {
            lastState = state
            if case .listening(_, let p) = state { port = p; break }
            if case .failed = state { break }
            if !waited { break }
        }
        if port == 0 { Issue.record("listener never became ready: \(lastState)") }
        try #require(port != 0)
        return (server, pairing, port, path)
    }

    private func pairAndHello(_ client: ControlTestClient, pairing: PairingManager) async throws -> String {
        let code = await pairing.mintCode()
        try await client.send(try ControlFrame(type: .pair, body: PairRequest(code: code.code, deviceName: "Test laptop"), id: "p1"))
        let pairOk = try await client.wait(for: .pairOk)
        let credentials = try pairOk.body(as: PairOk.self)
        try await client.send(try ControlFrame(type: .hello, body: HelloRequest(clientId: credentials.clientId, token: credentials.token, appVersion: "t", protocolVersion: 1), id: "h1"))
        let helloOk = try await client.wait(for: .helloOk)
        #expect(helloOk.replyTo == "h1")
        #expect(try helloOk.body(as: HelloOk.self).runtimeId == "rt-test")
        return credentials.clientId
    }

    @Test("a request before hello is refused and the socket closes")
    func unauthenticated() async throws {
        let (server, _, port, path) = try await startServer(provider: ScriptedProvider([.text("x")]))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let client = ControlTestClient(port: port)
        try await client.connect()
        try await client.send(try ControlFrame(type: .submit, body: SubmitRequest(text: "hi", clientRequestId: "1"), id: "s1"))
        let error = try await client.wait(for: .error)
        #expect(error.body["code"]?.stringValue == "unauthorized")
        await #expect(throws: (any Error).self) { _ = try await client.wait(for: .pong, timeout: .seconds(3)) }
        await server.stop()
    }

    @Test("a wrong pairing code and a bad token are refused")
    func badCredentials() async throws {
        let (server, pairing, port, path) = try await startServer(provider: ScriptedProvider([.text("x")]))
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = await pairing.mintCode()
        let client = ControlTestClient(port: port)
        try await client.connect()
        try await client.send(try ControlFrame(type: .pair, body: PairRequest(code: "NOPENOPE", deviceName: "x"), id: "p1"))
        #expect(try await client.wait(for: .error).body["code"]?.stringValue == "pairing_failed")

        let other = ControlTestClient(port: port)
        try await other.connect()
        try await other.send(try ControlFrame(type: .hello, body: HelloRequest(clientId: "ghost", token: "t", appVersion: "t", protocolVersion: 1), id: "h1"))
        #expect(try await other.wait(for: .error).body["code"]?.stringValue == "unauthorized")
        await server.stop()
    }

    @Test("pair, hello, subscribe, submit, events, approval with codes, stop")
    func fullRoundTrip() async throws {
        let provider = ScriptedProvider([echoCall("x"), .text("Finished the thing")])
        let (server, pairing, port, path) = try await startServer(provider: provider, tool: EchoTool(requiresConfirmation: true))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let client = ControlTestClient(port: port)
        try await client.connect()
        _ = try await pairAndHello(client, pairing: pairing)

        try await client.send(ControlFrame(type: .subscribe, id: "sub1"))
        let snapshot = try await client.wait(for: .snapshot)
        #expect(snapshot.replyTo == "sub1")
        #expect(try snapshot.body(as: SnapshotBody.self).sessions.isEmpty)

        try await client.send(try ControlFrame(type: .submit, body: SubmitRequest(text: "echo x", clientRequestId: "req-1"), id: "s1"))
        let ack = try await client.wait(for: .submitAck)
        let submitted = try ack.body(as: SubmitAck.self)
        #expect(submitted.shortId == 1)

        // Idempotent on clientRequestId: a retry returns the same session.
        try await client.send(try ControlFrame(type: .submit, body: SubmitRequest(text: "echo x", clientRequestId: "req-1"), id: "s2"))
        #expect(try (try await client.wait(for: .submitAck)).body(as: SubmitAck.self) == submitted)

        var approval: ApprovalRequest? = nil
        for _ in 0..<20 {
            let event = try await client.wait(for: .event)
            if case .approvalRequested(let request) = try event.body(as: SequencedEvent.self).event { approval = request; break }
        }
        let request = try #require(approval)
        #expect(request.sessionId == submitted.sessionId)

        try await client.send(try ControlFrame(type: .approvalAnswer, body: ApprovalAnswerRequest(approvalId: request.id, nonce: "ZZZZ", decision: "approve"), id: "a1"))
        #expect(try await client.wait(for: .error).body["code"]?.stringValue == "bad_nonce")
        try await client.send(try ControlFrame(type: .approvalAnswer, body: ApprovalAnswerRequest(approvalId: request.id, nonce: request.nonce, decision: "approve"), id: "a2"))
        #expect(try await client.wait(for: .approvalOk).replyTo == "a2")

        var finished = false
        for _ in 0..<40 {
            let event = try await client.wait(for: .event)
            if case .finished(let id, let state, let summary) = try event.body(as: SequencedEvent.self).event, id == submitted.sessionId {
                #expect(state == .completed)
                #expect(summary == "Finished the thing")
                finished = true
                break
            }
        }
        #expect(finished)

        try await client.send(ControlFrame(type: .sessionsList, id: "l1"))
        #expect(try (try await client.wait(for: .sessions)).body(as: SessionsBody.self).sessions.count == 1)
        try await client.send(ControlFrame(type: .ping, id: "pp"))
        #expect(try await client.wait(for: .pong).replyTo == "pp")
        try await client.send(try ControlFrame(type: .stop, body: StopRequest(), id: "st"))
        #expect(try (try await client.wait(for: .stopOk)).body(as: StopOk.self).stopped.isEmpty)
        try await client.send(try ControlFrame(type: .settingsGet, body: SettingsGetRequest(keys: ["permissionMode"]), id: "g1"))
        #expect(try (try await client.wait(for: .settings)).body(as: SettingsBody.self).values["permissionMode"] != nil)

        await server.revoke(clientId: try #require(await pairing.clients().first?.clientId))
        _ = try await client.wait(for: .bye)
        await server.stop()
    }
}
