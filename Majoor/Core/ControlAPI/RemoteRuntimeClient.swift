// RemoteRuntimeClient.swift
// Majoor — The laptop's side of the control API
//
// One WebSocket to the runtime. Reconnects with capped exponential backoff,
// re-authenticates, and resubscribes from the last event it applied so a
// drop costs nothing but the gap. Requests time out after ten seconds; a
// submit that may have been lost mid-flight is retried once with the same
// clientRequestId, which the runtime answers idempotently.

import Foundation
import Network

/// 1, 2, 4, 8, 15, 30 seconds, then 30 forever; reset on success.
nonisolated struct ReconnectBackoff: Sendable, Equatable {
    static let schedule: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15), .seconds(30)]

    private(set) var attempt = 0

    mutating func next() -> Duration {
        let delay = Self.schedule[min(attempt, Self.schedule.count - 1)]
        attempt += 1
        return delay
    }

    mutating func reset() { attempt = 0 }
}

/// Where the client is in the runtime's event stream. After a reconnect the
/// replay can overlap what was already applied; anything at or below the
/// last accepted seq is dropped. A snapshot moves the cursor to its seq.
nonisolated struct EventCursor: Sendable, Equatable {
    private(set) var lastSeq: Int?

    mutating func accept(_ seq: Int) -> Bool {
        if let lastSeq, seq <= lastSeq { return false }
        lastSeq = seq
        return true
    }

    mutating func reset(to seq: Int) { lastSeq = seq }
}

nonisolated enum RemoteClientError: Error, Sendable, Equatable {
    case notConfigured
    case notConnected
    case timeout
    case closed
    case runtimeMismatch(expected: String, actual: String)
    case rejected(code: ControlErrorCode, message: String)
    case unexpectedReply(ControlMessageType)

    var userMessage: String {
        switch self {
        case .notConfigured: return "Not paired with a runtime yet"
        case .notConnected: return "Runtime unreachable"
        case .timeout: return "The runtime did not answer in time"
        case .closed: return "Connection to the runtime closed"
        case .runtimeMismatch: return "The address now points at a different runtime"
        case .rejected(_, let message): return message
        case .unexpectedReply(let type): return "Unexpected reply \(type.rawValue)"
        }
    }
}

actor RemoteRuntimeClient {

    nonisolated enum State: Sendable, Equatable {
        case disconnected
        case connecting
        case authenticating
        case connected(runtimeId: String)
        case reconnecting(attempt: Int, lastError: String)
        /// Retrying would not help: the pairing was revoked, or the runtime id changed.
        case failed(String)

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    nonisolated enum Update: Sendable {
        case state(State)
        case snapshot(SnapshotBody)
        case event(SequencedEvent)
        case bye(String)
    }

    static let requestTimeout: Duration = .seconds(10)
    static let connectTimeout: Duration = .seconds(10)

    private let queue = DispatchQueue(label: "ai.majoor.control-client")
    private let appVersion: String
    private var credentials: ClientCredentials?
    private var peer: WebSocketPeer?
    private var runTask: Task<Void, Never>?
    private var readTask: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<ControlFrame, Error>] = [:]
    private var timeouts: [String: Task<Void, Never>] = [:]
    private var nextRequestId = 0
    private var cursor = EventCursor()
    private var backoff = ReconnectBackoff()
    private var wakeRequested = false
    private var subscribers: [UUID: AsyncStream<Update>.Continuation] = [:]
    private var pathMonitor: NWPathMonitor?

    private(set) var lastSnapshot: SnapshotBody?
    private(set) var state: State = .disconnected {
        didSet { if state != oldValue { broadcast(.state(state)) } }
    }

    init(appVersion: String) {
        self.appVersion = appVersion
    }

    // MARK: Configuration and lifecycle

    func configure(_ credentials: ClientCredentials) {
        self.credentials = credentials
    }

    var isConfigured: Bool { credentials != nil }
    var currentCredentials: ClientCredentials? { credentials }
    var lastSeq: Int? { cursor.lastSeq }

    func start() {
        guard runTask == nil, credentials != nil else { return }
        runTask = Task { await self.run() }
        startPathMonitor()
    }

    func stop() async {
        runTask?.cancel()
        runTask = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        closeConnection()
        state = .disconnected
    }

    /// Drops the credentials and the connection. Used by "Forget this runtime".
    func forget() async {
        await stop()
        credentials = nil
        lastSnapshot = nil
        cursor = EventCursor()
    }

    /// Current state first, then the last snapshot (so a late subscriber can
    /// render), then everything as it happens.
    func updates() -> AsyncStream<Update> {
        let id = UUID()
        let current = state
        let snapshot = lastSnapshot
        return AsyncStream { continuation in
            continuation.yield(.state(current))
            if let snapshot { continuation.yield(.snapshot(snapshot)) }
            subscribers[id] = continuation
            continuation.onTermination = { @Sendable _ in
                Task { await self.removeSubscriber(id) }
            }
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    private func broadcast(_ update: Update) {
        for continuation in subscribers.values { continuation.yield(update) }
    }

    /// After sleep: a connection that looks open may be dead. Probe it; if
    /// the probe fails the socket is closed and the reconnect loop takes
    /// over at once. While reconnecting, skip the rest of the backoff.
    func wake() async {
        wakeRequested = true
        guard state.isConnected, let peer else { return }
        do {
            _ = try await request(.ping, body: JSONValue.object([:]), peer: peer, timeout: .seconds(5))
        } catch {
            peer.close()
        }
    }

    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { await self?.networkBecameAvailable() }
        }
        monitor.start(queue: queue)
        pathMonitor = monitor
    }

    private func networkBecameAvailable() {
        if case .reconnecting = state { wakeRequested = true }
    }

    // MARK: Connection loop

    private func run() async {
        while !Task.isCancelled {
            guard let credentials else {
                state = .disconnected
                return
            }
            state = .connecting
            let peer = WebSocketPeer.client(host: credentials.host, port: credentials.port, queue: queue)
            self.peer = peer
            var failure = "Connection closed"
            do {
                try await peer.start(timeout: Self.connectTimeout)
                state = .authenticating
                let reader = Task { await self.readLoop(peer) }
                readTask = reader
                let hello = HelloRequest(clientId: credentials.clientId, token: credentials.token,
                                         appVersion: appVersion, protocolVersion: ControlProtocol.version)
                let reply = try await request(.hello, body: hello, peer: peer, timeout: Self.requestTimeout)
                guard reply.type == .helloOk else { throw RemoteClientError.unexpectedReply(reply.type) }
                let ok = try reply.body(as: HelloOk.self)
                if let expected = credentials.runtimeId, expected != ok.runtimeId {
                    throw RemoteClientError.runtimeMismatch(expected: expected, actual: ok.runtimeId)
                }
                if credentials.runtimeId == nil {
                    self.credentials?.runtimeId = ok.runtimeId
                    ClientCredentialsStore.saveRuntimeId(ok.runtimeId)
                }
                state = .connected(runtimeId: ok.runtimeId)
                backoff.reset()
                MajoorLogger.log("🔗 Connected to runtime \(ok.runtimeId.prefix(8)) at \(credentials.host):\(credentials.port) (seq \(ok.seq))")
                let subscribe = try ControlFrame(type: .subscribe, body: SubscribeRequest(sinceSeq: cursor.lastSeq), id: nextId())
                try await peer.send(frame: subscribe)
                await reader.value
            } catch {
                failure = Self.describe(error)
                if let fatal = Self.fatalMessage(for: error) {
                    readTask?.cancel()
                    closeConnection()
                    state = .failed(fatal)
                    MajoorLogger.error("Control client stopped: \(fatal)")
                    runTask = nil
                    return
                }
            }
            readTask?.cancel()
            readTask = nil
            closeConnection()
            if Task.isCancelled { break }
            let attempt = backoff.attempt + 1
            let delay = backoff.next()
            state = .reconnecting(attempt: attempt, lastError: failure)
            MajoorLogger.log("Control client: \(failure); retry \(attempt) in \(delay)")
            await sleepInterruptibly(delay)
        }
    }

    private static func describe(_ error: Error) -> String {
        if let remote = error as? RemoteClientError { return remote.userMessage }
        if let socket = error as? WebSocketError {
            switch socket {
            case .notReady(let detail): return "Could not connect: \(detail)"
            case .closed: return "Connection closed"
            case .sendFailed(let detail): return "Send failed: \(detail)"
            case .timeout: return "Connection timed out"
            }
        }
        return "\(error)"
    }

    /// Errors that a retry cannot fix.
    private static func fatalMessage(for error: Error) -> String? {
        guard let remote = error as? RemoteClientError else { return nil }
        switch remote {
        case .runtimeMismatch(let expected, let actual):
            return "The runtime at this address is not the one you paired with (expected \(expected.prefix(8))…, found \(actual.prefix(8))…). Forget it and pair again."
        case .rejected(let code, _) where code == .unauthorized || code == .lockedOut:
            return "This device is no longer paired with the runtime. Pair again in Settings."
        default:
            return nil
        }
    }

    private func sleepInterruptibly(_ delay: Duration) async {
        let deadline = ContinuousClock.now + delay
        while ContinuousClock.now < deadline, !Task.isCancelled, !wakeRequested {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if wakeRequested { backoff.reset() }
        wakeRequested = false
    }

    private func closeConnection() {
        peer?.close()
        peer = nil
        failPending(RemoteClientError.closed)
    }

    private func readLoop(_ peer: WebSocketPeer) async {
        do {
            for try await data in peer.incoming {
                dispatch(data)
            }
        } catch {
            MajoorLogger.log("Control client: read ended: \(error)")
        }
        failPending(RemoteClientError.closed)
    }

    private func dispatch(_ data: Data) {
        guard let frame = try? ControlFrame.decode(data) else { return }
        if let replyTo = frame.replyTo, let continuation = pending.removeValue(forKey: replyTo) {
            timeouts.removeValue(forKey: replyTo)?.cancel()
            continuation.resume(returning: frame)
            // A snapshot answers `subscribe` and is also state; keep going for it.
            if frame.type != .snapshot { return }
        }
        switch frame.type {
        case .event:
            guard let item = try? frame.body(as: SequencedEvent.self), cursor.accept(item.seq) else { return }
            broadcast(.event(item))
        case .snapshot:
            guard let body = try? frame.body(as: SnapshotBody.self) else { return }
            cursor.reset(to: body.seq)
            lastSnapshot = body
            broadcast(.snapshot(body))
        case .bye:
            let reason = (try? frame.body(as: ByeBody.self))?.reason ?? "The runtime closed the connection"
            MajoorLogger.log("Control client: bye (\(reason))")
            broadcast(.bye(reason))
            peer?.close()
        case .error:
            MajoorLogger.log("Control client: unsolicited error \(frame.body["message"]?.stringValue ?? "")")
        default:
            break
        }
    }

    // MARK: Requests

    private func nextId() -> String {
        nextRequestId += 1
        return "c\(nextRequestId)"
    }

    private func request<Body: Encodable>(_ type: ControlMessageType, body: Body, peer: WebSocketPeer,
                                          timeout: Duration) async throws -> ControlFrame {
        let id = nextId()
        let frame = try ControlFrame(type: type, body: body, id: id)
        let reply: ControlFrame = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            timeouts[id] = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.failRequest(id, RemoteClientError.timeout)
            }
            Task { [weak self] in
                do { try await peer.send(frame: frame) }
                catch { await self?.failRequest(id, RemoteClientError.closed) }
            }
        }
        if reply.type == .error {
            let code = ControlErrorCode(rawValue: reply.body["code"]?.stringValue ?? "") ?? .unavailable
            throw RemoteClientError.rejected(code: code, message: reply.body["message"]?.stringValue ?? "Request rejected")
        }
        return reply
    }

    /// A request on the live connection. Fails fast when there is none.
    func request<Body: Encodable>(_ type: ControlMessageType, body: Body,
                                  timeout: Duration = RemoteRuntimeClient.requestTimeout) async throws -> ControlFrame {
        guard credentials != nil else { throw RemoteClientError.notConfigured }
        guard state.isConnected, let peer else { throw RemoteClientError.notConnected }
        return try await request(type, body: body, peer: peer, timeout: timeout)
    }

    private func failRequest(_ id: String, _ error: Error) {
        timeouts.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func failPending(_ error: Error) {
        let waiting = pending
        pending.removeAll()
        for task in timeouts.values { task.cancel() }
        timeouts.removeAll()
        for continuation in waiting.values { continuation.resume(throwing: error) }
    }

    private func waitForConnection(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if state.isConnected { return true }
            if case .failed = state { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return state.isConnected
    }

    // MARK: Typed calls

    /// Idempotent: a drop after the frame left is retried once with the same
    /// clientRequestId once the connection is back, and the runtime returns
    /// the session it already started.
    func submit(text: String, threadKey: String?) async throws -> SubmitAck {
        let body = SubmitRequest(text: text, threadKey: threadKey, clientRequestId: UUID().uuidString)
        do {
            return try expect(.submitAck, from: try await request(.submit, body: body)).body(as: SubmitAck.self)
        } catch RemoteClientError.timeout, RemoteClientError.closed, RemoteClientError.notConnected {
            guard await waitForConnection(timeout: .seconds(15)) else { throw RemoteClientError.notConnected }
            return try expect(.submitAck, from: try await request(.submit, body: body)).body(as: SubmitAck.self)
        }
    }

    func stopSessions(sessionId: SessionID?) async throws -> [Int] {
        try expect(.stopOk, from: try await request(.stop, body: StopRequest(sessionId: sessionId))).body(as: StopOk.self).stopped
    }

    func answerApproval(id: String, nonce: String, decision: ApprovalDecision) async -> AgentSession.AnswerResult {
        let body = ApprovalAnswerRequest(approvalId: id, nonce: nonce, decision: decision.approved ? "approve" : "deny",
                                         feedback: decision.feedback,
                                         skipSteps: decision.skippedStepIndices.isEmpty ? nil : decision.skippedStepIndices)
        do {
            let reply = try await request(.approvalAnswer, body: body)
            return reply.type == .approvalOk ? .ok : .unknownId
        } catch RemoteClientError.rejected(let code, _) {
            switch code {
            case .badNonce: return .badNonce
            case .expired: return .expired
            default: return .unknownId
            }
        } catch {
            return .unknownId
        }
    }

    func sessions() async throws -> [SessionInfo] {
        try expect(.sessions, from: try await request(.sessionsList, body: JSONValue.object([:]))).body(as: SessionsBody.self).sessions
    }

    func settings(keys: [String]? = nil) async throws -> [String: JSONValue] {
        try expect(.settings, from: try await request(.settingsGet, body: SettingsGetRequest(keys: keys))).body(as: SettingsBody.self).values
    }

    /// Throws `RemoteClientError.rejected` with the runtime's code (for
    /// example `needs_local_approval` when loosening the permission mode).
    func setSetting(key: String, value: JSONValue) async throws {
        _ = try expect(.settingsOk, from: try await request(.settingsSet, body: SettingsSetRequest(key: key, value: value)))
    }

    func ping() async throws {
        _ = try expect(.pong, from: try await request(.ping, body: JSONValue.object([:]), timeout: .seconds(5)))
    }

    private func expect(_ type: ControlMessageType, from frame: ControlFrame) throws -> ControlFrame {
        guard frame.type == type else { throw RemoteClientError.unexpectedReply(frame.type) }
        return frame
    }

    // MARK: Pairing

    /// One short connection: `pair` with the code the runtime shows, get the
    /// client id and the one-time token back. Nothing is stored here.
    static func pair(host: String, port: UInt16, code: String, deviceName: String,
                     timeout: Duration = RemoteRuntimeClient.connectTimeout) async throws -> PairOk {
        let peer = WebSocketPeer.client(host: host, port: port, queue: DispatchQueue(label: "ai.majoor.pairing"))
        try await peer.start(timeout: timeout)
        defer { peer.close() }
        try await peer.send(frame: try ControlFrame(type: .pair, body: PairRequest(code: code, deviceName: deviceName), id: "pair"))
        let incoming = peer.incoming
        let reply = try await withThrowingTaskGroup(of: ControlFrame.self) { group in
            group.addTask {
                for try await data in incoming {
                    let frame = try ControlFrame.decode(data)
                    if frame.type == .pairOk || frame.type == .error { return frame }
                }
                throw RemoteClientError.closed
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw RemoteClientError.timeout
            }
            guard let first = try await group.next() else { throw RemoteClientError.closed }
            group.cancelAll()
            return first
        }
        if reply.type == .error {
            let code = ControlErrorCode(rawValue: reply.body["code"]?.stringValue ?? "") ?? .pairingFailed
            throw RemoteClientError.rejected(code: code, message: reply.body["message"]?.stringValue ?? "Pairing failed")
        }
        return try reply.body(as: PairOk.self)
    }
}
