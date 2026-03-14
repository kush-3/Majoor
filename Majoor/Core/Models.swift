// Models.swift
// Majoor — Core Data Models

import Foundation
import Combine

// MARK: - Anthropic API Request/Response Types
// These are nonisolated since they're just data containers used in networking

nonisolated struct AnthropicRequest: Codable, Sendable {
    let model: String
    let maxTokens: Int
    let system: String?
    let messages: [AnthropicMessage]
    let tools: [AnthropicTool]?
    
    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system, messages, tools
    }
}

nonisolated struct AnthropicMessage: Codable, Sendable {
    let role: String
    let content: AnthropicContent
}

enum AnthropicContent: Codable, Sendable {
    case string(String)
    case blocks([AnthropicContentBlock])
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let str): try container.encode(str)
        case .blocks(let blocks): try container.encode(blocks)
        }
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            self = .string(str)
        } else {
            self = .blocks(try container.decode([AnthropicContentBlock].self))
        }
    }
}

nonisolated struct AnthropicContentBlock: Codable, Sendable {
    let type: String
    let text: String?
    let id: String?
    let name: String?
    let input: [String: AnyCodable]?
    let toolUseId: String?
    let content: String?
    
    enum CodingKeys: String, CodingKey {
        case type, text, id, name, input
        case toolUseId = "tool_use_id"
        case content
    }
}

nonisolated struct AnthropicTool: Codable, Sendable {
    let name: String
    let description: String
    let inputSchema: AnthropicToolSchema
    
    enum CodingKeys: String, CodingKey {
        case name, description
        case inputSchema = "input_schema"
    }
}

nonisolated struct AnthropicToolSchema: Codable, Sendable {
    let type: String
    let properties: [String: AnthropicProperty]
    let required: [String]?
}

nonisolated struct AnthropicProperty: Codable, Sendable {
    let type: String
    let description: String
    let enumValues: [String]?
    
    enum CodingKeys: String, CodingKey {
        case type, description
        case enumValues = "enum"
    }
}

nonisolated struct AnthropicResponse: Codable, Sendable {
    let id: String
    let type: String
    let role: String
    let content: [AnthropicContentBlock]
    let stopReason: String?
    let usage: AnthropicUsage?
    
    enum CodingKeys: String, CodingKey {
        case id, type, role, content
        case stopReason = "stop_reason"
        case usage
    }
}

nonisolated struct AnthropicUsage: Codable, Sendable {
    let inputTokens: Int
    let outputTokens: Int
    
    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

nonisolated struct AnthropicError: Codable, Sendable {
    let type: String
    let error: AnthropicErrorDetail
}

nonisolated struct AnthropicErrorDetail: Codable, Sendable {
    let type: String
    let message: String
}

// MARK: - Task Model (MainActor — drives SwiftUI)

class AgentTask: ObservableObject, Identifiable {
    let id: UUID
    let userInput: String
    let createdAt: Date
    
    @Published var status: TaskStatus
    @Published var steps: [TaskStep]
    @Published var summary: String
    @Published var completedAt: Date?
    @Published var tokensUsed: Int
    @Published var modelUsed: String
    
    init(userInput: String) {
        self.id = UUID()
        self.userInput = userInput
        self.createdAt = Date()
        self.status = .running
        self.steps = []
        self.summary = ""
        self.completedAt = nil
        self.tokensUsed = 0
        self.modelUsed = ""
    }

    /// Restore a task from persistence with its original ID and timestamps
    init(id: UUID, userInput: String, createdAt: Date, status: TaskStatus, summary: String,
         completedAt: Date?, tokensUsed: Int, modelUsed: String, steps: [TaskStep]) {
        self.id = id
        self.userInput = userInput
        self.createdAt = createdAt
        self.status = status
        self.steps = steps
        self.summary = summary
        self.completedAt = completedAt
        self.tokensUsed = tokensUsed
        self.modelUsed = modelUsed
    }
}

enum TaskStatus: String, Sendable {
    case running = "Running"
    case completed = "Completed"
    case failed = "Failed"
    case waiting = "Waiting for Input"
}

struct TaskStep: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let type: StepType
    let description: String
    let detail: String?
    
    enum StepType: Sendable {
        case thinking, toolCall, toolResult, response, error
    }
}

nonisolated struct TaskResult: Sendable {
    let summary: String
    let steps: [TaskStep]
    let tokensUsed: Int
}

// MARK: - Pipeline Step Model

struct PipelineStep: Identifiable, Sendable {
    let id = UUID()
    let planDescription: String        // "Create PR 'Add auth' on kush/majoor"
    var status: PipelineStepStatus     // pending → running → completed → failed → skipped
    var toolCalls: [String]            // Tool names used for this step
    var result: String?                // Brief result text
    var error: String?                 // Error if failed
    var enabled: Bool                  // Whether user toggled this step on (for inline editing)

    init(planDescription: String, enabled: Bool = true) {
        self.planDescription = planDescription
        self.status = .pending
        self.toolCalls = []
        self.result = nil
        self.error = nil
        self.enabled = enabled
    }
}

enum PipelineStepStatus: String, Sendable {
    case pending, running, completed, failed, skipped
}

// MARK: - AnyCodable Helper

struct AnyCodable: Codable, Sendable {
    let value: any Sendable
    
    init(_ value: any Sendable) { self.value = value }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.value = "" // Represent nil as empty string
        } else if let bool = try? container.decode(Bool.self) {
            self.value = bool
        } else if let int = try? container.decode(Int.self) {
            self.value = int
        } else if let double = try? container.decode(Double.self) {
            self.value = double
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            self.value = array
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            self.value = dict
        } else {
            self.value = ""
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let bool as Bool: try container.encode(bool)
        case let int as Int: try container.encode(int)
        case let double as Double: try container.encode(double)
        case let string as String: try container.encode(string)
        case let array as [AnyCodable]: try container.encode(array)
        case let dict as [String: AnyCodable]: try container.encode(dict)
        default: try container.encodeNil()
        }
    }
    
    var stringValue: String? { value as? String }
    var intValue: Int? { value as? Int }
    var boolValue: Bool? { value as? Bool }
}
