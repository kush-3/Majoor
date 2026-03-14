// ModelRouter.swift
// Majoor — Route Tasks to the Right LLM Model
//
// Hybrid approach:
// - Keyword classifier handles obvious cases (instant, free)
// - Sonnet LLM classifies ambiguous inputs (model + tool sets)

import Foundation

nonisolated struct ModelRouter: Sendable {

    static let opusModel = "claude-opus-4-20250514"
    static let sonnetModel = "claude-sonnet-4-20250514"
    static let haikuModel = "claude-haiku-4-5-20251001"

    /// Create an LLM provider for the given task category (keyword-based fast path)
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

    /// Hybrid routing: use keywords if confident, otherwise ask Sonnet.
    /// Returns (provider, toolSets) where toolSets determines which MCP tools to include.
    static func routeHybrid(_ input: String) async -> (provider: AnthropicProvider, toolSets: [String]) {
        let (category, score) = TaskClassifier.classifyWithConfidence(input)

        // Fast path: keyword classifier is confident
        if score >= 2 {
            let toolSets = defaultToolSets(for: category, input: input)
            MajoorLogger.log("🎯 Fast-path routing: \(category.rawValue) (score: \(score)) → tools: \(toolSets)")
            return (provider(for: category), toolSets)
        }

        // Slow path: ask Sonnet to classify
        MajoorLogger.log("🤔 Ambiguous input (score: \(score)) — asking Sonnet to classify...")
        if let result = await classifyWithLLM(input) {
            let model: String
            switch result.modelTier {
            case .opus: model = opusModel
            case .sonnet: model = sonnetModel
            case .haiku: model = haikuModel
            }
            MajoorLogger.log("🎯 LLM routing: \(result.modelTier.rawValue) → tools: \(result.toolSets)")
            return (AnthropicProvider(apiKey: APIConfig.claudeAPIKey, model: model), result.toolSets)
        }

        // Fallback: use keyword result anyway
        let toolSets = defaultToolSets(for: category, input: input)
        return (provider(for: category), toolSets)
    }

    /// Get a provider for the default model (Sonnet)
    static func defaultProvider() -> AnthropicProvider {
        return AnthropicProvider(apiKey: APIConfig.claudeAPIKey, model: sonnetModel)
    }

    // MARK: - LLM Classification

    /// Ask Sonnet to classify the input and decide model + tool sets
    private static func classifyWithLLM(_ input: String) async -> ClassificationResult? {
        let classifierPrompt = """
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

        let provider = AnthropicProvider(apiKey: APIConfig.claudeAPIKey, model: haikuModel)
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

    private static func parseClassificationResponse(_ text: String) -> ClassificationResult? {
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
    private static func defaultToolSets(for category: TaskCategory, input: String) -> [String] {
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
