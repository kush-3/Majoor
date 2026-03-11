// ModelRouter.swift
// Majoor — Route Tasks to the Right LLM Model

import Foundation

nonisolated struct ModelRouter: Sendable {

    static let opusModel = "claude-opus-4-20250514"
    static let sonnetModel = "claude-sonnet-4-20250514"
    static let haikuModel = "claude-haiku-4-5-20251001"

    /// Create an LLM provider for the given task category
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
}
