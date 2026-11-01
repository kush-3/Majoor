// ModelRouter.swift
// Majoor — The frontier tier's model choice and the shared classification helpers
//
// Routing itself lives in `TierRouter` (Phase 2 step 3): it picks the tier,
// the provider and the tool allow-list from the privacy preset. This file
// keeps what the frontier tier needs (which Claude model for which category)
// and the pieces every router shares: the default MCP tool sets and the LLM
// classifier prompt, which runs on whatever provider the caller hands it and
// never constructs a Claude provider of its own.

import Foundation

nonisolated struct ModelRouter: Sendable {

    static let opusModel = "claude-opus-5"
    static let sonnetModel = "claude-sonnet-5"
    static let haikuModel = "claude-haiku-4-5"

    /// The frontier provider for a category: Opus for code and deep research,
    /// Sonnet for everything else.
    static func provider(for category: TaskCategory) -> AnthropicProvider {
        let model: String
        switch category.modelTier {
        case .opus:
            model = opusModel
        case .sonnet:
            model = sonnetModel
        case .haiku:
            model = haikuModel
        }

        MajoorLogger.log("Routing to \(model) for \(category.rawValue) task")
        return AnthropicProvider(apiKey: APIConfig.claudeAPIKey, model: model)
    }

    /// Get a provider for the default model (Sonnet)
    static func defaultProvider() -> AnthropicProvider {
        return AnthropicProvider(apiKey: APIConfig.claudeAPIKey, model: sonnetModel)
    }

    // MARK: - LLM Classification

    static let classifierPrompt = """
    You are a task classifier. Given the user's input, decide:
    1. Which model should handle this task: "opus" (complex coding, deep research), "sonnet" (general tasks, email, calendar), or "haiku" (simple lookups, quick answers)
    2. Which tool sets are needed: "local" (always included), "github", "slack", "linear", "notion"

    Respond with ONLY a JSON object, no markdown, no explanation:
    {"model": "opus|sonnet|haiku", "tools": ["local", ...]}

    Rules:
    - Coding, debugging, code review, PR creation → opus + relevant services
    - Email, calendar, scheduling → sonnet + local only
    - Quick questions, simple lookups → haiku + local only
    - Multi-service workflows (e.g., "I finished the auth feature") → opus or sonnet + all mentioned services
    - If unsure, default to sonnet with local tools
    """

    /// Ask `provider` to classify the input into a model tier and tool sets.
    /// `TierRouter` passes the tier-L model; nothing here reaches Claude.
    static func classify(_ input: String, with provider: any LLMProvider) async -> ClassificationResult? {
        let messages = [AnthropicMessage(role: "user", content: .string(input))]
        do {
            let (response, _) = try await provider.complete(
                systemPrompt: classifierPrompt,
                messages: messages,
                tools: [] // No tools needed for classification
            )
            if case .text(let text) = response {
                return parseClassificationResponse(text)
            }
        } catch {
            MajoorLogger.error("LLM classification failed: \(error.localizedDescription)")
        }
        return nil
    }

    static func parseClassificationResponse(_ text: String) -> ClassificationResult? {
        // Extract JSON from response (handle potential markdown wrapping)
        let cleaned = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let modelStr = json["model"] as? String,
              let tools = json["tools"] as? [String] else {
            return nil
        }

        let tier: ModelTier
        switch modelStr {
        case "opus": tier = .opus
        case "haiku": tier = .haiku
        default: tier = .sonnet
        }

        // Map tier to a category (simplified)
        let category: TaskCategory
        switch tier {
        case .opus: category = .coding
        case .haiku: category = .general
        case .sonnet: category = .general
        }

        return ClassificationResult(modelTier: tier, toolSets: tools, category: category)
    }

    // MARK: - Default Tool Sets

    /// Determine which tool sets to include based on category and keyword detection
    static func defaultToolSets(for category: TaskCategory, input: String) -> [String] {
        var sets = ["local"]

        // Always add explicitly mentioned services
        let mentioned = TaskClassifier.detectMentionedServices(input)
        sets.append(contentsOf: mentioned)

        // Add service-specific tools based on category
        switch category {
        case .coding, .codeReview:
            if !sets.contains("github") { sets.append("github") }
        case .emailCalendar:
            break // Local tools only
        case .webResearchDeep, .webResearchQuick:
            break // Local tools only (web tools are local)
        case .general:
            // For general/ambiguous, include all if pipeline-like language detected
            let lower = input.lowercased()
            if lower.contains("finished") || lower.contains("done with") || lower.contains("completed")
                || lower.contains("just did") || lower.contains("wrapped up") {
                sets = ["local", "github", "slack", "linear", "notion"]
            }
        default:
            break
        }

        return Array(Set(sets)) // Deduplicate
    }
}
