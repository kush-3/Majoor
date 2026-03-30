// ChatManager.swift
// Majoor — Chat Session Manager
//
// Manages a conversational chat session with streaming responses.
// Uses Sonnet for fast, interactive responses (no tools).

import Foundation
import Combine

struct ChatMessage: Identifiable, Sendable {
    let id = UUID()
    let role: ChatRole
    let content: String
    let timestamp: Date

    init(role: ChatRole, content: String) {
        self.role = role
        self.content = content
        self.timestamp = Date()
    }
}

enum ChatRole: Sendable {
    case user
    case assistant
}

class ChatManager: ObservableObject {

    @Published var messages: [ChatMessage] = []
    @Published var isStreaming: Bool = false
    @Published var streamingText: String = ""
    private var streamingTask: Task<Void, Never>?

    private let systemPrompt = """
    You are Majoor, a helpful AI assistant running as a native macOS menu bar app. \
    Be concise, conversational, and helpful. Use markdown formatting when appropriate. \
    Keep responses focused and to the point.
    """

    func send(_ userMessage: String) {
        let trimmed = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Append user message
        messages.append(ChatMessage(role: .user, content: trimmed))
        isStreaming = true
        streamingText = ""

        // Build conversation history for API
        let apiMessages: [AnthropicMessage] = messages.map { msg in
            AnthropicMessage(
                role: msg.role == .user ? "user" : "assistant",
                content: .string(msg.content)
            )
        }

        // Create provider (Sonnet for fast chat)
        let provider = AnthropicProvider(
            apiKey: APIConfig.claudeAPIKey,
            model: "claude-sonnet-4-20250514"
        )

        streamingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (response, usage) = try await provider.stream(
                    systemPrompt: systemPrompt,
                    messages: apiMessages,
                    tools: [],
                    onDelta: { [weak self] delta in
                        if case .textDelta(let text) = delta {
                            Task { @MainActor [weak self] in
                                self?.streamingText += text
                            }
                        }
                    }
                )

                // Finalize: extract full text and create assistant message
                let fullText: String
                if case .text(let t) = response {
                    fullText = t
                } else {
                    fullText = await MainActor.run { self.streamingText }
                }

                await MainActor.run {
                    self.messages.append(ChatMessage(role: .assistant, content: fullText))
                    self.isStreaming = false
                    self.streamingText = ""
                }

                // Track usage
                if let usage {
                    UsageStore.shared.recordUsage(
                        model: provider.model,
                        inputTokens: usage.inputTokens,
                        outputTokens: usage.outputTokens
                    )
                }
            } catch {
                // Don't show error for intentional cancellation (stop button)
                guard !Task.isCancelled else {
                    await MainActor.run {
                        if self.isStreaming {
                            self.isStreaming = false
                            self.streamingText = ""
                        }
                    }
                    return
                }
                await MainActor.run {
                    self.messages.append(ChatMessage(role: .assistant, content: "Error: \(error.localizedDescription)"))
                    self.isStreaming = false
                    self.streamingText = ""
                }
            }
        }
    }

    func cancelStreaming() {
        streamingTask?.cancel()
        streamingTask = nil
        if !streamingText.isEmpty {
            messages.append(ChatMessage(role: .assistant, content: streamingText))
        }
        isStreaming = false
        streamingText = ""
    }

    func clearHistory() {
        streamingTask?.cancel()
        streamingTask = nil
        messages.removeAll()
        isStreaming = false
        streamingText = ""
    }
}
