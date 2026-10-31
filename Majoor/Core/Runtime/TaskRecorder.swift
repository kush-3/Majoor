// TaskRecorder.swift
// Majoor — Per-session task state, owned by an actor
//
// Replaces the loop's direct writes to the SwiftUI AgentTask. The recorder
// is the single writer for a session's steps, usage and outcome; it
// persists a snapshot on completion or failure and publishes the matching
// events. Finishing is idempotent and serialized: the first of
// complete/fail wins, so a Stop that lands while the loop is wrapping up
// cannot be followed by a green "completed". That is the actor-serialized
// form of the liveness check the loop used to do inside one MainActor hop.

import Foundation

actor TaskRecorder {

    nonisolated let sessionId: SessionID
    nonisolated let userInput: String
    nonisolated let createdAt: Date

    private(set) var steps: [StepDTO] = []
    private(set) var status: TaskStatus = .running
    private(set) var summary: String = ""
    private(set) var tokensIn = 0
    private(set) var tokensOut = 0
    private(set) var modelUsed = ""
    private(set) var completedAt: Date?

    private let bus: EventBus?
    private let persist: (@Sendable (TaskSnapshot) -> Void)?

    init(sessionId: SessionID, userInput: String, createdAt: Date = Date(),
         bus: EventBus?, persist: (@Sendable (TaskSnapshot) -> Void)?) {
        self.sessionId = sessionId
        self.userInput = userInput
        self.createdAt = createdAt
        self.bus = bus
        self.persist = persist
    }

    var isFinished: Bool { status == .completed || status == .failed }
    var tokensUsed: Int { tokensIn + tokensOut }

    func append(_ step: StepDTO) async {
        guard !isFinished else { return }
        steps.append(step)
        await bus?.publish(.step(id: sessionId, step: step))
    }

    func addUsage(input: Int, output: Int, model: String) {
        tokensIn += input
        tokensOut += output
        if !model.isEmpty { modelUsed = model }
    }

    /// Mirrors the 1.x "Waiting for Input" status while an approval is pending.
    func setWaiting(_ waiting: Bool) {
        guard !isFinished else { return }
        status = waiting ? .waiting : .running
    }

    /// Returns false when the session already ended (stopped or failed): the
    /// caller must not report success.
    @discardableResult
    func complete(summary: String) async -> Bool {
        guard !isFinished else { return false }
        status = .completed
        self.summary = summary
        completedAt = Date()
        persist?(snapshot())
        await bus?.publish(.finished(id: sessionId, state: .completed, summary: summary))
        return true
    }

    @discardableResult
    func fail(_ reason: IncompleteReason) async -> Bool {
        guard !isFinished else { return false }
        status = .failed
        summary = reason.userFacing
        completedAt = Date()
        persist?(snapshot())
        await bus?.publish(.finished(id: sessionId, state: reason == .cancelled ? .stopped : .failed, summary: summary))
        return true
    }

    func snapshot() -> TaskSnapshot {
        TaskSnapshot(id: sessionId, userInput: userInput, createdAt: createdAt, status: status, summary: summary,
                     completedAt: completedAt, tokensIn: tokensIn, tokensOut: tokensOut, modelUsed: modelUsed, steps: steps)
    }
}
