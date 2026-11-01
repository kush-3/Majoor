// ChannelRouter.swift
// Majoor — Inbound text in, results and approval prompts out
//
// One consumer per registered channel. Every inbound message is checked
// against the trust policy first; a non-owner sender on a remote channel
// never reaches the SessionManager. Replies to approval prompts
// (`yes K7Q2`, `no K7Q2 not today`) are recognized before anything is
// treated as a task. Session outcomes and approval prompts for sessions
// that started on a remote channel are sent back to that channel.

import Foundation

/// `yes K7Q2 [feedback]` / `no K7Q2 [feedback]`. The code is required: a
/// bare "yes" never approves anything.
nonisolated enum ApprovalReply {
    nonisolated struct Parsed: Sendable, Equatable {
        let approved: Bool
        let nonce: String
        let feedback: String?
    }

    private static let pattern = try! NSRegularExpression(
        pattern: #"^\s*(yes|y|approve|approved|ok|no|n|deny|denied|reject)\s+([A-Za-z0-9]{4})(?:\s+(.+))?\s*$"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators])

    static func parse(_ text: String) -> Parsed? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern.firstMatch(in: text, range: range),
              let verbRange = Range(match.range(at: 1), in: text),
              let codeRange = Range(match.range(at: 2), in: text) else { return nil }
        let verb = text[verbRange].lowercased()
        let approved = ["yes", "y", "approve", "approved", "ok"].contains(verb)
        var feedback: String? = nil
        if let feedbackRange = Range(match.range(at: 3), in: text) {
            let trimmed = text[feedbackRange].trimmingCharacters(in: .whitespacesAndNewlines)
            feedback = trimmed.isEmpty ? nil : trimmed
        }
        return Parsed(approved: approved, nonce: String(text[codeRange]).uppercased(), feedback: feedback)
    }
}

actor ChannelRouter {

    static let shared = ChannelRouter()

    private var channels: [String: any Channel] = [:]
    private var consumers: [String: Task<Void, Never>] = [:]
    private var forwarder: Task<Void, Never>?
    private var manager: SessionManager?
    private var owners: @Sendable () -> [String] = { [] }

    /// Sees every owner message (origin, text, when) after the approval
    /// check; returns true when it consumed the message. The escalation
    /// ladder uses it: any reply acknowledges what was sent to that thread,
    /// and a bare "ok" is swallowed instead of becoming a task.
    typealias OwnerMessageHandler = @Sendable (ChannelRef, String, Date) async -> Bool
    private var ownerMessageHandler: OwnerMessageHandler?

    init() {}

    func configure(manager: SessionManager, owners: @escaping @Sendable () -> [String]) {
        self.manager = manager
        self.owners = owners
        if forwarder == nil { forwarder = Task { [weak self] in await self?.forwardEvents() } }
    }

    func setOwnerMessageHandler(_ handler: OwnerMessageHandler?) {
        ownerMessageHandler = handler
    }

    func register(_ channel: any Channel) {
        channels[channel.id] = channel
        consumers[channel.id]?.cancel()
        consumers[channel.id] = Task { [weak self] in
            for await message in channel.inbound {
                await self?.handle(message, via: channel)
            }
        }
    }

    func unregister(_ channelId: String) {
        consumers[channelId]?.cancel()
        consumers[channelId] = nil
        channels[channelId] = nil
    }

    func channel(_ id: String) -> (any Channel)? { channels[id] }

    /// Deliver text to a thread on a channel, if that channel is registered.
    func deliver(to ref: ChannelRef, text: String) async {
        guard let channel = channels[ref.channelId] else { return }
        do { try await channel.send(to: ref.threadKey, text: text) }
        catch { MajoorLogger.error("Delivery to \(ref.channelId) failed: \(error)") }
    }

    /// Like `deliver`, but the caller learns about failure: no such channel
    /// registered, or the channel's send threw.
    func send(to ref: ChannelRef, text: String) async throws {
        guard let channel = channels[ref.channelId] else { throw GatewayError.unavailable }
        try await channel.send(to: ref.threadKey, text: text)
    }

    // MARK: - Inbound

    func handle(_ message: InboundMessage, via channel: any Channel) async {
        guard let manager else { return }
        guard TrustPolicy.isOwner(sender: message.sender, trust: channel.trust, owners: owners()) else {
            MajoorLogger.log("🚫 Ignored message on \(channel.id) from non-owner sender")
            return
        }
        let origin = ChannelRef(channelId: channel.id, threadKey: message.threadKey)

        if let reply = ApprovalReply.parse(message.text) {
            let text = await answer(reply, origin: origin, manager: manager)
            await deliver(to: origin, text: text)
            return
        }

        if let handler = ownerMessageHandler, await handler(origin, message.text, Date()) {
            await deliver(to: origin, text: "Noted.")
            return
        }

        let outcome = await manager.handleInbound(message.text, origin: origin, trust: channel.trust)
        let isPanel = channel.id == PanelChannel.channelId
        switch outcome {
        case .submitted(let info):
            if !isPanel { await deliver(to: origin, text: "On it (session \(info.shortId)).") }
        case .status(let text):
            await deliver(to: origin, text: text)
        case .stopped(let count):
            await deliver(to: origin, text: count == 0 ? "Nothing was running." : "Stopped \(count) session(s).")
        case .nothingToStop(let text):
            await deliver(to: origin, text: text)
        case .unavailable:
            await deliver(to: origin, text: "The agent runtime is still starting. Try again in a moment.")
        }
    }

    private func answer(_ reply: ApprovalReply.Parsed, origin: ChannelRef, manager: SessionManager) async -> String {
        // Only approvals for sessions that started in this thread can be answered from it.
        let sessions = await manager.list()
        let mine = Set(sessions.filter { $0.origin == origin }.map(\.id))
        let candidates = await manager.pendingApprovals().filter { mine.contains($0.sessionId) }
        guard !candidates.isEmpty else { return "Nothing is waiting for your approval here." }
        let target = candidates.first { $0.nonce.uppercased() == reply.nonce } ?? (candidates.count == 1 ? candidates[0] : nil)
        guard let target else { return "Several approvals are waiting; reply with the code shown in the one you mean." }
        let decision = ApprovalDecision(approved: reply.approved, feedback: reply.feedback)
        switch await manager.answerApproval(id: target.id, nonce: reply.nonce, decision: decision, byChannel: origin.channelId) {
        case .ok: return reply.approved ? "Approved." : "Denied."
        case .badNonce: return "That code does not match. Reply with the 4-character code from the request."
        case .expired: return "That request expired."
        case .tooManyAttempts: return "Too many wrong codes; the request was denied."
        case .unknownId: return "That request is no longer pending."
        }
    }

    // MARK: - Outbound

    private func forwardEvents() async {
        guard let manager else { return }
        // Resume from the start of the ring: an approval published between
        // configure() and this task's first subscribe must not be lost.
        var lastSeq: Int? = 0
        while !Task.isCancelled {
            let subscription = await manager.bus.subscribe(since: lastSeq)
            for item in subscription.replay { await forward(item, manager: manager) }
            for await item in subscription.stream { await forward(item, manager: manager) }
            lastSeq = await manager.bus.latestSeq
        }
    }

    private func forward(_ item: SequencedEvent, manager: SessionManager) async {
        switch item.event {
        case .approvalRequested(let request):
            guard let origin = await origin(of: request.sessionId, manager: manager), origin.channelId != PanelChannel.channelId else { return }
            let head = request.isPipelinePlan ? "Plan proposed:" : "Approval needed:"
            let minutes = max(1, Int(request.expiresAt.timeIntervalSince(request.requestedAt) / 60))
            await deliver(to: origin, text: "\(head)\n\(request.body)\n\nReply \"yes \(request.nonce)\" to approve, \"no \(request.nonce) <note>\" to decline. Expires in \(minutes) min.")
        case .finished(let id, let state, let summary):
            guard let origin = await origin(of: id, manager: manager), origin.channelId != PanelChannel.channelId else { return }
            let text: String
            switch state {
            case .completed: text = summary
            case .stopped: text = "Stopped."
            default: text = "Could not finish: \(summary)"
            }
            await deliver(to: origin, text: text)
        default:
            break
        }
    }

    private func origin(of sessionId: SessionID, manager: SessionManager) async -> ChannelRef? {
        await manager.list().first { $0.id == sessionId }?.origin
    }
}
