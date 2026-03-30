// ChatView.swift
// Majoor — Streaming Chat Interface
//
// Interactive conversation with streaming responses.
// Message bubbles, auto-scroll, inline input.

import SwiftUI

struct ChatView: View {
    @EnvironmentObject var chatManager: ChatManager
    @State private var inputText = ""
    @FocusState private var inputFocused: Bool

    private static let suggestions = [
        "Summarize my recent git commits",
        "Draft a follow-up email",
        "Explain this error message",
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Messages area
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if chatManager.messages.isEmpty && !chatManager.isStreaming {
                            emptyState
                        }

                        ForEach(chatManager.messages) { message in
                            ChatBubble(message: message)
                                .id(message.id)
                        }

                        // Streaming indicator
                        if chatManager.isStreaming {
                            StreamingBubble(text: chatManager.streamingText)
                                .id("streaming")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: chatManager.messages.count) { _ in
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: chatManager.streamingText) { _ in
                    scrollToBottom(proxy: proxy)
                }
            }

            // Input area with depth separation
            VStack(spacing: 0) {
                Divider()

                HStack(spacing: 8) {
                    TextField(
                        chatManager.isStreaming ? "Waiting for response..." : "Message...",
                        text: $inputText
                    )
                    .textFieldStyle(.plain)
                    .font(DT.Font.body)
                    .focused($inputFocused)
                    .onSubmit { sendMessage() }
                    .disabled(chatManager.isStreaming)
                    .opacity(chatManager.isStreaming ? 0.5 : 1)

                    Button(action: chatManager.isStreaming ? stopStreaming : sendMessage) {
                        Image(systemName: chatManager.isStreaming
                              ? "stop.circle.fill"
                              : "arrow.up.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(sendButtonColor)
                            .animation(DT.Anim.fast, value: chatManager.isStreaming)
                    }
                    .buttonStyle(.plain)
                    .disabled(!chatManager.isStreaming && inputText.isEmpty)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                if !chatManager.messages.isEmpty {
                    Button(action: { chatManager.clearHistory() }) {
                        Text("Clear conversation")
                            .font(DT.Font.micro)
                            .foregroundColor(DT.Color.textQuaternary)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 8)
                }
            }
            .background(.ultraThinMaterial)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: DT.Spacing.sm) {
            Spacer(minLength: 60)

            Image(systemName: "sparkles")
                .font(.system(size: 24))
                .foregroundColor(DT.Color.textQuaternary)

            Text("Ask anything")
                .font(DT.Font.body(.medium))
                .foregroundColor(DT.Color.textSecondary)

            Text("Chat uses Sonnet for fast responses")
                .font(DT.Font.micro)
                .foregroundColor(DT.Color.textTertiary)

            VStack(spacing: DT.Spacing.xs) {
                ForEach(Self.suggestions, id: \.self) { suggestion in
                    Button {
                        inputText = suggestion
                        sendMessage()
                    } label: {
                        Text(suggestion)
                            .font(DT.Font.caption)
                            .foregroundColor(DT.Color.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, DT.Spacing.md)
                            .padding(.vertical, DT.Spacing.sm)
                            .background(DT.Color.surfaceCard)
                            .clipShape(RoundedRectangle(cornerRadius: DT.Radius.small, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, DT.Spacing.xs)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    private var sendButtonColor: Color {
        if chatManager.isStreaming { return DT.Color.error }
        return inputText.isEmpty ? DT.Color.textQuaternary : DT.Color.accent
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !chatManager.isStreaming else { return }
        chatManager.send(text)
        inputText = ""
    }

    private func stopStreaming() {
        chatManager.cancelStreaming()
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            if chatManager.isStreaming {
                proxy.scrollTo("streaming", anchor: .bottom)
            } else if let lastId = chatManager.messages.last?.id {
                proxy.scrollTo(lastId, anchor: .bottom)
            }
        }
    }
}

// MARK: - Chat Bubble

private struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                if message.role == .user {
                    Text(message.content)
                        .font(DT.Font.body)
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .textSelection(.enabled)
                } else {
                    // Assistant message
                    let attributed = (try? AttributedString(
                        markdown: message.content,
                        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                    )) ?? AttributedString(message.content)
                    Text(attributed)
                        .font(DT.Font.body)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .textSelection(.enabled)
                }
            }

            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }
}

// MARK: - Streaming Bubble

private struct StreamingBubble: View {
    let text: String
    @State private var dotAnimating = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                if text.isEmpty {
                    // Typing indicator
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { i in
                            Circle()
                                .fill(Color.secondary.opacity(0.5))
                                .frame(width: 5, height: 5)
                                .offset(y: dotAnimating ? -4 : 0)
                                .animation(
                                    .easeInOut(duration: 0.45)
                                    .repeatForever(autoreverses: true)
                                    .delay(Double(i) * 0.15),
                                    value: dotAnimating
                                )
                        }
                    }
                    .onAppear { dotAnimating = true }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    Text(text)
                        .font(DT.Font.body)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 40)
        }
    }
}
