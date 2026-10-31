// SessionTypes.swift
// Majoor — Session runtime value types
//
// Everything the runtime says about a session is expressed with these
// nonisolated, Codable, Sendable values, so the panel and a remote client
// render from the same data and they can cross actors and the wire.

import Foundation

typealias SessionID = UUID

nonisolated enum SessionKind: String, Codable, Sendable {
    case concierge, task, job
}

nonisolated enum SessionState: String, Codable, Sendable {
    case queued, running, waitingApproval, completed, failed, stopped

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .stopped: return true
        case .queued, .running, .waitingApproval: return false
        }
    }
}

/// Where a session came from and which conversation thread it belongs to.
nonisolated struct ChannelRef: Codable, Sendable, Hashable {
    let channelId: String
    let threadKey: String

    static let panel = ChannelRef(channelId: "panel", threadKey: "panel")
}

/// How much the origin of a message is trusted (PRD §5.7).
nonisolated enum ChannelTrust: String, Codable, Sendable {
    case local, remoteText
}

nonisolated struct SessionInfo: Codable, Sendable, Identifiable, Equatable {
    let id: SessionID
    let shortId: Int
    let kind: SessionKind
    var state: SessionState
    let input: String
    let origin: ChannelRef
    let createdAt: Date
    var endedAt: Date?
    var summary: String?
    var tokensIn: Int
    var tokensOut: Int
    var costUSD: Double

    init(id: SessionID = UUID(), shortId: Int, kind: SessionKind, state: SessionState, input: String,
         origin: ChannelRef, createdAt: Date = Date(), endedAt: Date? = nil, summary: String? = nil,
         tokensIn: Int = 0, tokensOut: Int = 0, costUSD: Double = 0) {
        self.id = id; self.shortId = shortId; self.kind = kind; self.state = state; self.input = input
        self.origin = origin; self.createdAt = createdAt; self.endedAt = endedAt; self.summary = summary
        self.tokensIn = tokensIn; self.tokensOut = tokensOut; self.costUSD = costUSD
    }
}

/// A task step as data. Same JSON shape the `stepsJson` column has always
/// held, so existing rows decode unchanged.
nonisolated struct StepDTO: Codable, Sendable, Equatable {
    let timestamp: Date
    let type: String   // thinking, toolCall, toolResult, response, error
    let description: String
    let detail: String?

    init(timestamp: Date = Date(), type: String, description: String, detail: String? = nil) {
        self.timestamp = timestamp; self.type = type; self.description = description; self.detail = detail
    }

    init(_ step: TaskStep) {
        self.init(timestamp: step.timestamp, type: Self.name(of: step.type), description: step.description, detail: step.detail)
    }

    var taskStep: TaskStep {
        TaskStep(timestamp: timestamp, type: Self.stepType(named: type), description: description, detail: detail)
    }

    static func name(of type: TaskStep.StepType) -> String {
        switch type {
        case .thinking: return "thinking"
        case .toolCall: return "toolCall"
        case .toolResult: return "toolResult"
        case .response: return "response"
        case .error: return "error"
        }
    }

    static func stepType(named name: String) -> TaskStep.StepType {
        switch name {
        case "thinking": return .thinking
        case "toolCall": return .toolCall
        case "toolResult": return .toolResult
        case "error": return .error
        default: return .response
        }
    }
}

nonisolated struct PipelineStepDTO: Codable, Sendable, Equatable {
    let index: Int
    let planDescription: String
    var status: String
    var toolCalls: [String]
    var result: String?
    var error: String?
    var enabled: Bool

    init(index: Int, _ step: PipelineStep) {
        self.init(index: index, planDescription: step.planDescription, status: step.status.rawValue,
                  toolCalls: step.toolCalls, result: step.result, error: step.error, enabled: step.enabled)
    }

    init(index: Int, planDescription: String, status: String = "pending", toolCalls: [String] = [],
         result: String? = nil, error: String? = nil, enabled: Bool = true) {
        self.index = index; self.planDescription = planDescription; self.status = status
        self.toolCalls = toolCalls; self.result = result; self.error = error; self.enabled = enabled
    }
}

/// PRD §9 risk classes. Phase 1 records them; the trust ledger is Phase 2.
nonisolated enum RiskClass: String, Codable, Sendable {
    case r0, r1, r2, r3
}

nonisolated struct ApprovalRequest: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let sessionId: SessionID
    let title: String
    let body: String
    let category: String
    let riskClass: RiskClass
    /// Short code an answer must repeat (`yes K7Q2`).
    let nonce: String
    let actionSignature: String
    let requestedAt: Date
    let expiresAt: Date
    let isPipelinePlan: Bool
    let pipelineSteps: [PipelineStepDTO]
}

nonisolated struct ApprovalDecision: Codable, Sendable, Equatable {
    let approved: Bool
    let feedback: String?
    /// Pipeline steps the approver switched off.
    let skippedStepIndices: [Int]

    init(approved: Bool, feedback: String? = nil, skippedStepIndices: [Int] = []) {
        self.approved = approved; self.feedback = feedback; self.skippedStepIndices = skippedStepIndices
    }

    static let stopped = ApprovalDecision(approved: false, feedback: "Task was stopped by the user")
    static let expired = ApprovalDecision(approved: false, feedback: "Approval expired")
}
