// SessionManager.swift
// Majoor — Owns every session: creation, concurrency, queueing, STOP
//
// Replaces the app delegate's single running task. Up to `maxConcurrent`
// sessions run at once; the rest queue in order. STOP stops every session,
// drains the queue and denies every pending approval. Inbound text from any
// channel goes through `handleInbound`, where the few exact command forms
// are recognized and everything else becomes a task.

import Foundation

actor SessionManager {

    static let shared = SessionManager()

    nonisolated let bus = EventBus()
    nonisolated let history = ThreadHistory()

    nonisolated enum InboundOutcome: Sendable {
        case submitted(SessionInfo)
        case status(String)
        case stopped(count: Int)
        case nothingToStop(String)
        case unavailable
    }

    private var loop: AgentLoop?
    private var store: SessionStore?
    private var persistTask: (@Sendable (TaskSnapshot) -> Void)?
    private var notify: (@Sendable (ApprovalRequest) -> Void)?
    private var sessions: [SessionID: AgentSession] = [:]
    private var order: [SessionID] = []
    private var queue: [SessionID] = []
    private var active: Set<SessionID> = []
    private var nextShortId = 1
    private(set) var maxConcurrent = 3
    private(set) var approvalTimeout: TimeInterval = 600
    private var permissionMode: PermissionMode?
    private var sessionBudget: TokenBudget?

    init() {}

    /// Production wiring happens once at launch; tests call this with their
    /// own loop, store and hooks.
    func configure(loop: AgentLoop, store: SessionStore?, persistTask: (@Sendable (TaskSnapshot) -> Void)?,
                   notify: (@Sendable (ApprovalRequest) -> Void)?, maxConcurrent: Int = 3, approvalTimeout: TimeInterval = 600,
                   permissionMode: PermissionMode? = nil, sessionBudget: TokenBudget? = nil) {
        self.loop = loop
        self.permissionMode = permissionMode
        self.sessionBudget = sessionBudget
        self.store = store
        self.persistTask = persistTask
        self.notify = notify
        self.maxConcurrent = max(1, maxConcurrent)
        self.approvalTimeout = approvalTimeout
        if let store {
            let interrupted = store.markInterrupted()
            if interrupted > 0 { MajoorLogger.log("⚠️ \(interrupted) session(s) were interrupted by the last shutdown") }
        }
    }

    var isConfigured: Bool { loop != nil }

    // MARK: - Submit, list, stop

    @discardableResult
    func submit(input: String, origin: ChannelRef, trust: ChannelTrust, kind: SessionKind = .task) async -> SessionInfo? {
        guard let loop else { return nil }
        let session = AgentSession(
            shortId: nextShortId, kind: kind, input: input, origin: origin, trust: trust, budget: sessionBudget ?? TokenBudget.perSession,
            bus: bus, history: history, store: store, loop: loop, approvalTimeout: approvalTimeout,
            persist: persistTask, notify: notify, modeOverride: permissionMode,
            onFinished: { [weak self] id in await self?.sessionFinished(id) })
        nextShortId += 1
        let id = session.sessionId
        sessions[id] = session
        order.append(id)
        await bus.publish(.created(await session.info))
        if active.count < maxConcurrent {
            active.insert(id)
            await session.start()
        } else {
            queue.append(id)
            MajoorLogger.log("⏳ Session \(session.shortId) queued (\(active.count) running)")
        }
        pruneTerminal()
        return await session.info
    }

    /// A session with no model call: the scheduler records a fired reminder
    /// this way so it shows in the feed, the sessions table and `/status`
    /// history like any other work.
    @discardableResult
    func recordJob(input: String, origin: ChannelRef, summary: String) async -> SessionInfo {
        let now = Date()
        var info = SessionInfo(shortId: nextShortId, kind: .job, state: .running, input: input, origin: origin, createdAt: now)
        nextShortId += 1
        await bus.publish(.created(info))
        info.state = .completed
        info.endedAt = now
        info.summary = summary
        store?.upsert(info)
        persistTask?(TaskSnapshot(id: info.id, userInput: input, createdAt: now, status: .completed, summary: summary, completedAt: now,
                                  tokensIn: 0, tokensOut: 0, modelUsed: "none", steps: [StepDTO(type: "response", description: summary)]))
        await bus.publish(.finished(id: info.id, state: .completed, summary: summary))
        return info
    }

    private func sessionFinished(_ id: SessionID) async {
        active.remove(id)
        while active.count < maxConcurrent, !queue.isEmpty {
            let next = queue.removeFirst()
            guard let session = sessions[next] else { continue }
            active.insert(next)
            await session.start()
        }
    }

    func list() async -> [SessionInfo] {
        var result: [SessionInfo] = []
        for id in order {
            if let session = sessions[id] { result.append(await session.info) }
        }
        return result
    }

    func session(shortId: Int) -> AgentSession? {
        sessions.values.first { $0.shortId == shortId }
    }

    /// Stops one session. Returns false when no session has that number.
    func stop(shortId: Int) async -> Bool {
        guard let session = session(shortId: shortId) else { return false }
        queue.removeAll { $0 == session.sessionId }
        await session.stop()
        return true
    }

    /// STOP: every session, the queue, every pending approval. Idempotent.
    func stopAll() async {
        queue.removeAll()
        for id in order {
            if let session = sessions[id], await !session.state.isTerminal {
                await session.stop()
            }
        }
    }

    // MARK: - Approvals

    func pendingApprovals() async -> [ApprovalRequest] {
        var result: [ApprovalRequest] = []
        for id in order {
            if let session = sessions[id], let request = await session.pendingApproval { result.append(request) }
        }
        return result
    }

    func answerApproval(id: String, nonce: String?, decision: ApprovalDecision, byChannel: String) async -> AgentSession.AnswerResult {
        for session in sessions.values {
            if await session.pendingApproval?.id == id {
                return await session.answer(approvalId: id, nonce: nonce, decision: decision, byChannel: byChannel)
            }
        }
        return .unknownId
    }

    /// Current state for a subscriber that must catch up before trusting the stream.
    func snapshot() async -> (sessions: [SessionInfo], approvals: [ApprovalRequest]) {
        (await list(), await pendingApprovals())
    }

    // MARK: - Inbound text

    func handleInbound(_ text: String, origin: ChannelRef, trust: ChannelTrust) async -> InboundOutcome {
        switch InboundCommand.parse(text) {
        case .stopAll:
            let count = await list().filter { !$0.state.isTerminal }.count
            await stopAll()
            return .stopped(count: count)
        case .status:
            return .status(await statusText())
        case .stop(let number):
            if let number {
                return await stop(shortId: number) ? .stopped(count: 1) : .nothingToStop("No session \(number).")
            }
            let live = await list().filter { !$0.state.isTerminal }
            if live.count == 1, await stop(shortId: live[0].shortId) { return .stopped(count: 1) }
            if live.isEmpty { return .nothingToStop("Nothing is running.") }
            return .nothingToStop("Several sessions are running; say which:\n" + (await statusText()))
        case .none:
            guard let info = await submit(input: text, origin: origin, trust: trust) else { return .unavailable }
            return .submitted(info)
        }
    }

    func statusText() async -> String {
        let infos = await list().filter { !$0.state.isTerminal || ($0.endedAt.map { Date().timeIntervalSince($0) < 600 } ?? false) }
        guard !infos.isEmpty else { return "Nothing running." }
        let lines = infos.map { info -> String in
            let input = info.input.count > 40 ? String(info.input.prefix(40)) + "…" : info.input
            let elapsed = Int((info.endedAt ?? Date()).timeIntervalSince(info.createdAt))
            let age = elapsed < 60 ? "\(elapsed)s" : "\(elapsed / 60)m"
            return "\(info.shortId) · \(info.state.rawValue) · \"\(input)\" · \(age) · $\(String(format: "%.2f", info.costUSD))"
        }
        let day = String(format: "%.2f", UsageStore.shared.todayUsage().totalCost)
        return lines.joined(separator: "\n") + "\nToday: $\(day)"
    }

    // MARK: - Housekeeping

    /// Keeps memory bounded: terminal sessions beyond the newest 100 are dropped.
    private func pruneTerminal(keep: Int = 100) {
        guard order.count > keep else { return }
        var kept: [SessionID] = []
        var dropped = 0
        for id in order.reversed() {
            if kept.count < keep || active.contains(id) || queue.contains(id) {
                kept.append(id)
            } else {
                sessions[id] = nil
                dropped += 1
            }
        }
        if dropped > 0 { order = kept.reversed() }
    }
}
