// AgentSession.swift
// Majoor — One run of the agent loop, with its own approval slot
//
// A session owns one TaskRecorder, runs AgentLoop once, and holds at most
// one pending approval with its own continuation, nonce and expiry. Stop is
// safe at any point: a pending approval is resolved as denied before the
// run task is cancelled, and the recorder's finish-once rule means the
// outcome can never flip to "completed" afterwards.

import Foundation

actor AgentSession: AgentLoopHost {

    nonisolated let sessionId: SessionID
    nonisolated let shortId: Int
    nonisolated let kind: SessionKind
    nonisolated let origin: ChannelRef
    nonisolated let trust: ChannelTrust
    nonisolated let input: String
    nonisolated let createdAt: Date
    nonisolated let budget: TokenBudget
    nonisolated let recorder: TaskRecorder
    nonisolated let history: ThreadHistory

    nonisolated enum AnswerResult: Sendable, Equatable {
        case ok, unknownId, badNonce, expired, tooManyAttempts
    }

    private struct PendingApproval {
        let request: ApprovalRequest
        let continuation: CheckedContinuation<ApprovalDecision, Never>
        var wrongNonces: Int
        let expiry: Task<Void, Never>
    }

    private let bus: EventBus
    private let store: SessionStore?
    private let loop: AgentLoop
    private let approvalTimeout: TimeInterval
    private let notify: (@Sendable (ApprovalRequest) -> Void)?
    private let onFinished: @Sendable (SessionID) async -> Void
    /// Tests pin the mode; production reads the setting on every call.
    private nonisolated let modeOverride: PermissionMode?

    private(set) var state: SessionState = .queued
    private var runTask: Task<Void, Never>?
    private var pending: PendingApproval?
    private var stopped = false
    private var endedAt: Date?
    private var summary: String?
    private var tokensIn = 0
    private var tokensOut = 0
    private var costUSD = 0.0

    init(shortId: Int, kind: SessionKind, input: String, origin: ChannelRef, trust: ChannelTrust, budget: TokenBudget,
         bus: EventBus, history: ThreadHistory, store: SessionStore?, loop: AgentLoop, approvalTimeout: TimeInterval = 600,
         persist: (@Sendable (TaskSnapshot) -> Void)?, notify: (@Sendable (ApprovalRequest) -> Void)?,
         modeOverride: PermissionMode? = nil,
         onFinished: @escaping @Sendable (SessionID) async -> Void) {
        let id = UUID()
        self.modeOverride = modeOverride
        let now = Date()
        self.sessionId = id
        self.shortId = shortId
        self.kind = kind
        self.input = input
        self.origin = origin
        self.trust = trust
        self.budget = budget
        self.createdAt = now
        self.bus = bus
        self.history = history
        self.store = store
        self.loop = loop
        self.approvalTimeout = approvalTimeout
        self.notify = notify
        self.onFinished = onFinished
        self.recorder = TaskRecorder(sessionId: id, userInput: input, createdAt: now, bus: bus, persist: persist)
    }

    nonisolated var effectiveMode: PermissionMode {
        let mode = modeOverride ?? PermissionMode.current
        return (trust == .remoteText && mode == .auto) ? .standard : mode
    }

    var info: SessionInfo {
        SessionInfo(id: sessionId, shortId: shortId, kind: kind, state: state, input: input, origin: origin,
                    createdAt: createdAt, endedAt: endedAt, summary: summary,
                    tokensIn: tokensIn, tokensOut: tokensOut, costUSD: costUSD)
    }

    var pendingApproval: ApprovalRequest? { pending?.request }

    // MARK: - Lifecycle

    func start() {
        guard state == .queued, !stopped else { return }
        state = .running
        store?.upsert(info)
        runTask = Task { await self.runLoop() }
    }

    private func runLoop() async {
        let context = SessionContext(sessionId: sessionId, origin: origin, trust: trust)
        await emit(.state(id: sessionId, state: .running))
        do {
            _ = try await SessionContext.$current.withValue(context) {
                try await loop.run(userInput: input, host: self)
            }
        } catch is CancellationError {
            await recorder.fail(.cancelled)
        } catch let error as LLMError {
            await recorder.fail(message: error.errorDescription ?? "Task failed")
        } catch {
            await recorder.fail(message: error.localizedDescription)
        }
        await finish()
    }

    private func finish() async {
        let snapshot = await recorder.snapshot()
        summary = snapshot.summary
        tokensIn = snapshot.tokensIn
        tokensOut = snapshot.tokensOut
        costUSD = CostConfig.estimateCost(model: snapshot.modelUsed, inputTokens: snapshot.tokensIn, outputTokens: snapshot.tokensOut)
        endedAt = Date()
        state = snapshot.status == .completed ? .completed : (stopped ? .stopped : .failed)
        if pending != nil { resolve(.stopped, byChannel: "session") }
        store?.upsert(info)
        await emit(.state(id: sessionId, state: state))
        await onFinished(sessionId)
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        if pending != nil { resolve(.stopped, byChannel: "stop") }
        if let runTask {
            runTask.cancel()
        } else if state == .queued {
            state = .stopped
            endedAt = Date()
            await recorder.fail(.cancelled)
            store?.upsert(info)
            await emit(.state(id: sessionId, state: .stopped))
            await onFinished(sessionId)
        }
    }

    // MARK: - AgentLoopHost

    func emit(_ event: SessionEvent) async {
        if case .cost(_, let tin, let tout, let usd, _) = event {
            tokensIn = tin
            tokensOut = tout
            costUSD = usd
        }
        await bus.publish(event)
    }

    func requestApproval(_ draft: ApprovalDraft) async -> ApprovalDecision {
        if stopped || Task.isCancelled { return .stopped }
        let now = Date()
        let request = ApprovalRequest(
            id: UUID().uuidString, sessionId: sessionId, title: draft.title, body: draft.body, category: draft.category,
            riskClass: draft.riskClass, nonce: Self.makeNonce(), actionSignature: draft.actionSignature,
            requestedAt: now, expiresAt: now.addingTimeInterval(approvalTimeout),
            isPipelinePlan: draft.isPipelinePlan, pipelineSteps: draft.pipelineSteps)
        store?.record(request)
        await recorder.setWaiting(true)
        state = .waitingApproval
        await bus.publish(.approvalRequested(request))
        await bus.publish(.state(id: sessionId, state: .waitingApproval))
        notify?(request)
        MajoorLogger.log("⏸ Waiting for approval: \(draft.title) [\(request.nonce)]")

        // A stop that landed during the awaits above found nothing pending to
        // resolve, so check again with no suspension point before registering.
        if stopped { return .stopped }
        let timeout = approvalTimeout
        let decision = await withCheckedContinuation { (continuation: CheckedContinuation<ApprovalDecision, Never>) in
            let expiry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                await self?.expire(request.id)
            }
            pending = PendingApproval(request: request, continuation: continuation, wrongNonces: 0, expiry: expiry)
        }

        await recorder.setWaiting(false)
        if !stopped {
            state = .running
            await bus.publish(.state(id: sessionId, state: .running))
        }
        MajoorLogger.log(decision.approved ? "✅ Approved: \(draft.title)" : "❌ Denied: \(draft.title)")
        return decision
    }

    // MARK: - Answering

    /// `nonce` is required from any channel outside the process; in-process
    /// UI (the panel, a notification button) passes nil because it answers
    /// the exact request it was shown.
    func answer(approvalId: String, nonce: String?, decision: ApprovalDecision, byChannel: String) -> AnswerResult {
        guard var current = pending, current.request.id == approvalId else { return .unknownId }
        if Date() > current.request.expiresAt {
            resolve(.expired, byChannel: "expiry")
            return .expired
        }
        if let nonce, !Self.nonceMatches(nonce, current.request.nonce) {
            current.wrongNonces += 1
            pending = current
            if current.wrongNonces >= 5 {
                resolve(ApprovalDecision(approved: false, feedback: "Too many wrong approval codes"), byChannel: byChannel)
                return .tooManyAttempts
            }
            return .badNonce
        }
        resolve(decision, byChannel: byChannel)
        return .ok
    }

    private func resolve(_ decision: ApprovalDecision, byChannel: String) {
        guard let current = pending else { return }
        pending = nil
        current.expiry.cancel()
        store?.resolve(approvalId: current.request.id, decision: decision, byChannel: byChannel)
        current.continuation.resume(returning: decision)
        let id = current.request.id
        Task { await bus.publish(.approvalResolved(approvalId: id, approved: decision.approved, byChannel: byChannel)) }
    }

    private func expire(_ id: String) {
        guard let current = pending, current.request.id == id else { return }
        resolve(.expired, byChannel: "expiry")
    }

    // MARK: - Nonce

    private static let nonceAlphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    static func makeNonce() -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<4).map { _ in nonceAlphabet[Int.random(in: 0..<nonceAlphabet.count, using: &generator)] })
    }

    /// Case-insensitive, length-checked, constant-time over the compared bytes.
    static func nonceMatches(_ given: String, _ expected: String) -> Bool {
        let a = Array(given.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().utf8)
        let b = Array(expected.uppercased().utf8)
        guard a.count == b.count, !b.isEmpty else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}
