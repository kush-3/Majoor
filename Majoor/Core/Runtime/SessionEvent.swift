// SessionEvent.swift
// Majoor — The runtime's event stream
//
// Every change a session goes through is one of these. The UI mirror and,
// later, control-API clients subscribe to the same stream, so the JSON
// shape is fixed here: a "type" discriminator plus that case's fields.

import Foundation

nonisolated enum SessionEvent: Sendable, Equatable {
    case created(SessionInfo)
    case state(id: SessionID, state: SessionState)
    case step(id: SessionID, step: StepDTO)
    case pipelinePlan(id: SessionID, text: String, steps: [PipelineStepDTO])
    case pipelineStep(id: SessionID, index: Int, status: String, result: String?, error: String?)
    case approvalRequested(ApprovalRequest)
    case approvalResolved(approvalId: String, approved: Bool, byChannel: String)
    case cost(id: SessionID, tokensIn: Int, tokensOut: Int, sessionUSD: Double, dayUSD: Double)
    case finished(id: SessionID, state: SessionState, summary: String)

    var typeName: String {
        switch self {
        case .created: return "created"
        case .state: return "state"
        case .step: return "step"
        case .pipelinePlan: return "pipelinePlan"
        case .pipelineStep: return "pipelineStep"
        case .approvalRequested: return "approvalRequested"
        case .approvalResolved: return "approvalResolved"
        case .cost: return "cost"
        case .finished: return "finished"
        }
    }

    var sessionId: SessionID? {
        switch self {
        case .created(let info): return info.id
        case .state(let id, _), .step(let id, _), .pipelinePlan(let id, _, _), .pipelineStep(let id, _, _, _, _),
             .cost(let id, _, _, _, _), .finished(let id, _, _):
            return id
        case .approvalRequested(let request): return request.sessionId
        case .approvalResolved: return nil
        }
    }
}

extension SessionEvent: Codable {
    private enum Key: String, CodingKey {
        case type, session, info, state, step, text, steps, index, status, result, error
        case approval, approvalId, approved, byChannel, tokensIn, tokensOut, sessionUSD, dayUSD, summary
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(typeName, forKey: .type)
        switch self {
        case .created(let info):
            try c.encode(info, forKey: .info)
        case .state(let id, let state):
            try c.encode(id, forKey: .session); try c.encode(state, forKey: .state)
        case .step(let id, let step):
            try c.encode(id, forKey: .session); try c.encode(step, forKey: .step)
        case .pipelinePlan(let id, let text, let steps):
            try c.encode(id, forKey: .session); try c.encode(text, forKey: .text); try c.encode(steps, forKey: .steps)
        case .pipelineStep(let id, let index, let status, let result, let error):
            try c.encode(id, forKey: .session); try c.encode(index, forKey: .index); try c.encode(status, forKey: .status)
            try c.encodeIfPresent(result, forKey: .result); try c.encodeIfPresent(error, forKey: .error)
        case .approvalRequested(let request):
            try c.encode(request, forKey: .approval)
        case .approvalResolved(let approvalId, let approved, let byChannel):
            try c.encode(approvalId, forKey: .approvalId); try c.encode(approved, forKey: .approved)
            try c.encode(byChannel, forKey: .byChannel)
        case .cost(let id, let tokensIn, let tokensOut, let sessionUSD, let dayUSD):
            try c.encode(id, forKey: .session); try c.encode(tokensIn, forKey: .tokensIn); try c.encode(tokensOut, forKey: .tokensOut)
            try c.encode(sessionUSD, forKey: .sessionUSD); try c.encode(dayUSD, forKey: .dayUSD)
        case .finished(let id, let state, let summary):
            try c.encode(id, forKey: .session); try c.encode(state, forKey: .state); try c.encode(summary, forKey: .summary)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "created":
            self = .created(try c.decode(SessionInfo.self, forKey: .info))
        case "state":
            self = .state(id: try c.decode(SessionID.self, forKey: .session), state: try c.decode(SessionState.self, forKey: .state))
        case "step":
            self = .step(id: try c.decode(SessionID.self, forKey: .session), step: try c.decode(StepDTO.self, forKey: .step))
        case "pipelinePlan":
            self = .pipelinePlan(id: try c.decode(SessionID.self, forKey: .session), text: try c.decode(String.self, forKey: .text),
                                 steps: try c.decode([PipelineStepDTO].self, forKey: .steps))
        case "pipelineStep":
            self = .pipelineStep(id: try c.decode(SessionID.self, forKey: .session), index: try c.decode(Int.self, forKey: .index),
                                 status: try c.decode(String.self, forKey: .status),
                                 result: try c.decodeIfPresent(String.self, forKey: .result),
                                 error: try c.decodeIfPresent(String.self, forKey: .error))
        case "approvalRequested":
            self = .approvalRequested(try c.decode(ApprovalRequest.self, forKey: .approval))
        case "approvalResolved":
            self = .approvalResolved(approvalId: try c.decode(String.self, forKey: .approvalId),
                                     approved: try c.decode(Bool.self, forKey: .approved),
                                     byChannel: try c.decode(String.self, forKey: .byChannel))
        case "cost":
            self = .cost(id: try c.decode(SessionID.self, forKey: .session), tokensIn: try c.decode(Int.self, forKey: .tokensIn),
                         tokensOut: try c.decode(Int.self, forKey: .tokensOut), sessionUSD: try c.decode(Double.self, forKey: .sessionUSD),
                         dayUSD: try c.decode(Double.self, forKey: .dayUSD))
        case "finished":
            self = .finished(id: try c.decode(SessionID.self, forKey: .session), state: try c.decode(SessionState.self, forKey: .state),
                             summary: try c.decode(String.self, forKey: .summary))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown session event type '\(type)'")
        }
    }
}

/// An event with its position in the bus, so a subscriber can resume.
nonisolated struct SequencedEvent: Codable, Sendable, Equatable {
    let seq: Int
    let at: Date
    let event: SessionEvent
}
