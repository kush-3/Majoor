// ControlConnection.swift
// Majoor — One control-API client connection
//
// State machine: unauthenticated (a valid `hello` or `pair` must arrive
// within five seconds, anything else closes the socket) → authenticated.
// Requests are dispatched to the SessionGateway; after `subscribe` the
// EventBus stream is forwarded as `event` frames, with a snapshot first
// when the client's resume point is unknown or older than the ring.

import Foundation

nonisolated struct ControlRuntimeInfo: Sendable {
    let runtimeId: String
    let serverVersion: String
    let mode: String
}

actor ControlConnection {

    nonisolated let id = UUID()

    private enum State {
        case unauthenticated
        case authenticated(clientId: String)
        case closed
    }

    private let peer: WebSocketPeer
    private let gateway: any SessionGateway
    private let pairing: PairingManager
    private let bus: EventBus
    private let runtime: ControlRuntimeInfo
    private let onClose: @Sendable (UUID) -> Void

    private var state: State = .unauthenticated
    private var readTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var subscriptionId: UUID?
    private var strikes = 0
    private var submitted: [String: SubmitAck] = [:]

    init(peer: WebSocketPeer, gateway: any SessionGateway, pairing: PairingManager, bus: EventBus,
         runtime: ControlRuntimeInfo, onClose: @escaping @Sendable (UUID) -> Void) {
        self.peer = peer
        self.gateway = gateway
        self.pairing = pairing
        self.bus = bus
        self.runtime = runtime
        self.onClose = onClose
    }

    var clientId: String? {
        if case .authenticated(let clientId) = state { return clientId }
        return nil
    }

    // MARK: Lifecycle

    func start() {
        guard readTask == nil else { return }
        readTask = Task { await self.run() }
    }

    private func run() async {
        do {
            try await peer.start()
        } catch {
            MajoorLogger.log("Control connection from \(peer.remoteDescription) failed to start: \(error)")
            await shutdown()
            return
        }
        deadlineTask = Task { [weak self] in
            try? await Task.sleep(for: ControlProtocol.helloDeadline)
            await self?.helloDeadlinePassed()
        }
        do {
            for try await data in peer.incoming {
                await handle(data)
                if case .closed = state { break }
            }
        } catch {
            MajoorLogger.log("Control connection \(id) ended: \(error)")
        }
        await shutdown()
    }

    private func helloDeadlinePassed() async {
        guard case .unauthenticated = state else { return }
        await fail(.unauthorized, "No hello within \(ControlProtocol.helloDeadline)")
    }

    func sendBye(_ reason: String) async {
        try? await peer.send(frame: ControlFrame(type: .bye, body: .object(["reason": .string(reason)])))
        await shutdown()
    }

    private func shutdown() async {
        if case .closed = state { return }
        state = .closed
        deadlineTask?.cancel()
        eventTask?.cancel()
        if let subscriptionId { await bus.unsubscribe(subscriptionId) }
        peer.close()
        onClose(id)
    }

    private func fail(_ code: ControlErrorCode, _ message: String, replyTo: String? = nil) async {
        try? await peer.send(frame: .error(code, message, replyTo: replyTo))
        await shutdown()
    }

    private func reply(_ frame: ControlFrame) async {
        do { try await peer.send(frame: frame) }
        catch { await shutdown() }
    }

    private func strike(_ why: String, replyTo: String? = nil) async {
        strikes += 1
        if strikes >= 10 {
            await fail(.badRequest, "Too many bad frames")
        } else {
            await reply(.error(.badRequest, why, replyTo: replyTo))
        }
    }

    // MARK: Dispatch

    private func handle(_ data: Data) async {
        guard data.count <= ControlProtocol.maximumFrameBytes else { await strike("frame too large"); return }
        let frame: ControlFrame
        do { frame = try ControlFrame.decode(data) }
        catch { await strike("malformed frame"); return }
        guard frame.v == ControlProtocol.version else {
            await strike("unsupported protocol version \(frame.v)", replyTo: frame.id)
            return
        }
        switch state {
        case .unauthenticated: await handleUnauthenticated(frame)
        case .authenticated(let clientId): await handleAuthenticated(frame, clientId: clientId)
        case .closed: break
        }
    }

    private func handleUnauthenticated(_ frame: ControlFrame) async {
        switch frame.type {
        case .pair:
            guard let request = try? frame.body(as: PairRequest.self) else { await fail(.badRequest, "pair needs code and deviceName"); return }
            do {
                let ok = try await pairing.redeem(code: request.code, deviceName: request.deviceName)
                await reply(try ControlFrame(type: .pairOk, body: ok, replyTo: frame.id))
            } catch PairingManager.RedeemError.lockedOut {
                await fail(.lockedOut, "Pairing is locked after too many failed attempts", replyTo: frame.id)
            } catch {
                await fail(.pairingFailed, "Pairing code not accepted", replyTo: frame.id)
            }
        case .hello:
            guard let request = try? frame.body(as: HelloRequest.self) else { await fail(.badRequest, "hello needs clientId and token"); return }
            guard request.protocolVersion == ControlProtocol.version,
                  await pairing.authenticate(clientId: request.clientId, token: request.token) else {
                await fail(.unauthorized, "Unknown client or bad token", replyTo: frame.id)
                return
            }
            state = .authenticated(clientId: request.clientId)
            deadlineTask?.cancel()
            let ok = HelloOk(runtimeId: runtime.runtimeId, serverVersion: runtime.serverVersion, seq: await bus.latestSeq, mode: runtime.mode)
            await reply((try? ControlFrame(type: .helloOk, body: ok, replyTo: frame.id)) ?? .error(.unavailable, "encode", replyTo: frame.id))
            MajoorLogger.log("🔐 Control client \(request.clientId) connected from \(peer.remoteDescription)")
        default:
            await fail(.unauthorized, "hello first")
        }
    }

    private func handleAuthenticated(_ frame: ControlFrame, clientId: String) async {
        switch frame.type {
        case .ping:
            await reply(ControlFrame(type: .pong, replyTo: frame.id))
        case .subscribe:
            let request = (try? frame.body(as: SubscribeRequest.self)) ?? SubscribeRequest()
            await subscribe(since: request.sinceSeq, replyTo: frame.id)
        case .submit:
            guard let request = try? frame.body(as: SubmitRequest.self) else { await strike("submit needs text and clientRequestId", replyTo: frame.id); return }
            if let ack = submitted[request.clientRequestId] {
                await reply((try? ControlFrame(type: .submitAck, body: ack, replyTo: frame.id)) ?? .error(.unavailable, "encode"))
                return
            }
            do {
                let info = try await gateway.submit(request.text, threadKey: request.threadKey ?? "client:\(clientId)")
                let ack = SubmitAck(sessionId: info.id, shortId: info.shortId)
                submitted[request.clientRequestId] = ack
                await reply(try ControlFrame(type: .submitAck, body: ack, replyTo: frame.id))
            } catch {
                await reply(.error(.unavailable, "The runtime is not ready", replyTo: frame.id))
            }
        case .approvalAnswer:
            guard let request = try? frame.body(as: ApprovalAnswerRequest.self), ["approve", "deny"].contains(request.decision) else {
                await strike("approval.answer needs approvalId, nonce and decision", replyTo: frame.id)
                return
            }
            let decision = ApprovalDecision(approved: request.decision == "approve", feedback: request.feedback, skippedStepIndices: request.skipSteps ?? [])
            switch await gateway.answerApproval(id: request.approvalId, nonce: request.nonce, decision: decision) {
            case .ok: await reply(ControlFrame(type: .approvalOk, replyTo: frame.id))
            case .badNonce: await reply(.error(.badNonce, "Code does not match", replyTo: frame.id))
            case .expired: await reply(.error(.expired, "Approval expired", replyTo: frame.id))
            case .tooManyAttempts: await reply(.error(.badNonce, "Too many wrong codes; denied", replyTo: frame.id))
            case .unknownId: await reply(.error(.unknown, "No such pending approval", replyTo: frame.id))
            }
        case .stop:
            let request = (try? frame.body(as: StopRequest.self)) ?? StopRequest()
            var shortId: Int? = nil
            if let sessionId = request.sessionId {
                guard let info = await gateway.list().first(where: { $0.id == sessionId }) else {
                    await reply(.error(.unknown, "No such session", replyTo: frame.id)); return
                }
                shortId = info.shortId
            }
            let stopped = await gateway.stop(shortId: shortId)
            await reply((try? ControlFrame(type: .stopOk, body: StopOk(stopped: stopped), replyTo: frame.id)) ?? .error(.unavailable, "encode"))
        case .sessionsList:
            await reply((try? ControlFrame(type: .sessions, body: SessionsBody(sessions: await gateway.list()), replyTo: frame.id)) ?? .error(.unavailable, "encode"))
        case .settingsGet:
            let request = (try? frame.body(as: SettingsGetRequest.self)) ?? SettingsGetRequest()
            await reply((try? ControlFrame(type: .settings, body: SettingsBody(values: ControlSettings.values(for: request.keys)), replyTo: frame.id)) ?? .error(.unavailable, "encode"))
        case .settingsSet:
            guard let request = try? frame.body(as: SettingsSetRequest.self) else { await strike("settings.set needs key and value", replyTo: frame.id); return }
            if let code = ControlSettings.set(key: request.key, value: request.value) {
                let message = code == .needsLocalApproval ? "Loosening the permission mode must be done on the runtime itself" : "Setting rejected"
                await reply(.error(code, message, replyTo: frame.id))
            } else {
                await reply(ControlFrame(type: .settingsOk, replyTo: frame.id))
            }
        default:
            await strike("unexpected \(frame.type.rawValue)", replyTo: frame.id)
        }
    }

    // MARK: Events

    private func subscribe(since: Int?, replyTo: String?) async {
        eventTask?.cancel()
        if let subscriptionId { await bus.unsubscribe(subscriptionId) }
        let subscription = await gateway.events(since: since)
        subscriptionId = subscription.id
        if subscription.snapshotRequired {
            let snapshot = SnapshotBody(
                sessions: await gateway.list(),
                pendingApprovals: await gateway.pendingApprovals(),
                recentTasks: await gateway.recentTasks(limit: 20),
                settings: ControlSettings.values(),
                dayUSD: UsageStore.shared.todayUsage().totalCost,
                seq: await bus.latestSeq)
            await reply((try? ControlFrame(type: .snapshot, body: snapshot, replyTo: replyTo)) ?? .error(.unavailable, "encode", replyTo: replyTo))
        }
        for item in subscription.replay { await forward(item) }
        let stream = subscription.stream
        eventTask = Task { [weak self] in
            var lastSeq = subscription.replay.last?.seq ?? since
            for await item in stream {
                lastSeq = item.seq
                await self?.forward(item)
            }
            // The bus cut us off (too far behind) or shut down: resync.
            guard let self, !Task.isCancelled else { return }
            await self.resubscribe(since: lastSeq)
        }
    }

    private func resubscribe(since: Int?) async {
        guard case .authenticated = state else { return }
        await subscribe(since: since, replyTo: nil)
    }

    private func forward(_ item: SequencedEvent) async {
        guard case .authenticated = state else { return }
        await reply((try? ControlFrame(type: .event, body: item)) ?? .error(.unavailable, "encode"))
    }
}
