// ChatView.swift
// Majoor — Streaming Chat Interface
//
// Design reference: Messages.app
// User bubbles: accent-filled, right-aligned.
// Assistant bubbles: light material fill, left-aligned.
// Input bar: frosted material footer with single-line field.

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
                    LazyVStack(spacing: DT.Spacing.sm) {
                        if chatManager.messages.isEmpty && !chatManager.isStreaming {
                            emptyState
                        }

                        ForEach(chatManager.messages) { message in
                            ChatBubble(message: message)
                                .id(message.id)
                        }

                        if chatManager.isStreaming {
                            StreamingBubble(text: chatManager.streamingText)
                                .id("streaming")
                        }
                    }
                    .padding(.horizontal, DT.Spacing.lg)
                    .padding(.vertical, DT.Spacing.md)
                }
                .onChange(of: chatManager.messages.count) { _ in
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: chatManager.streamingText) { _ in
                    scrollToBottom(proxy: proxy)
                }
            }

            // Input bar — frosted material footer
            inputBar
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: DT.Spacing.lg) {
            Spacer(minLength: 48)

            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 32, weight: .thin))
                .foregroundStyle(.quaternary)

            VStack(spacing: DT.Spacing.xs) {
                Text("Start a conversation")
                    .font(DT.Font.body(.medium))
                    .foregroundStyle(.secondary)

                Text("Fast responses powered by Sonnet")
                    .font(DT.Font.micro)
                    .foregroundStyle(.tertiary)
            }

            VStack(spacing: DT.Spacing.xs) {
                ForEach(Self.suggestions, id: \.self) { suggestion in
                    Button {
                        inputText = suggestion
                        sendMessage()
                    } label: {
                        Text(suggestion)
                            .font(DT.Font.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, DT.Spacing.md)
                            .padding(.vertical, DT.Spacing.sm)
                            .background(
                                RoundedRectangle(cornerRadius: DT.Radius.small, style: .continuous)
                                    .fill(.ultraThinMaterial)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, DT.Spacing.xs)

            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        VStack(spacing: 0) {
            // Subtle separator — no harsh Divider()
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 0.5)

            HStack(spacing: DT.Spacing.sm) {
                TextField(
                    chatManager.isStreaming ? "Waiting..." : "Message...",
                    text: $inputText
                )
                .textFieldStyle(.plain)
                .font(DT.Font.body)
                .focused($inputFocused)
                .onSubmit { sendMessage() }
                .disabled(chatManager.isStreaming)
                .opacity(chatManager.isStreaming ? 0.4 : 1)

                Button(action: chatManager.isStreaming ? stopStreaming : sendMessage) {
                    Image(systemName: chatManager.isStreaming
                          ? "stop.circle.fill"
                          : "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(sendButtonColor)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .disabled(!chatManager.isStreaming && inputText.isEmpty)
            }
            .padding(.horizontal, DT.Spacing.lg)
            .padding(.vertical, DT.Spacing.md)

            // Clear conversation link
            if !chatManager.messages.isEmpty {
                Button {
                    chatManager.clearHistory()
                } label: {
                    Text("Clear conversation")
                        .font(DT.Font.micro)
                        .foregroundStyle(.quaternary)
                }
                .buttonStyle(.plain)
                .padding(.bottom, DT.Spacing.sm)
            }
        }
        .background(.ultraThinMaterial)
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
        withAnimation(DT.Anim.smooth) {
            if chatManager.isStreaming {
                proxy.scrollTo("streaming", anchor: .bottom)
            } else if let lastId = chatManager.messages.last?.id {
                proxy.scrollTo(lastId, anchor: .bottom)
            }
        }
    }
}

// MARK: - Chat Bubble
//
// Messages.app style: user = accent fill + white text, right-aligned.
// Assistant = subtle material fill, left-aligned. Both use continuous corners.

private struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .bottom) {
            if message.role == .user { Spacer(minLength: 48) }

            if message.role == .user {
                Text(message.content)
                    .font(DT.Font.body)
                    .foregroundStyle(.white)
                    .padding(.horizontal, DT.Spacing.md)
                    .padding(.vertical, DT.Spacing.sm)
                    .background(Color.accentColor, in: chatBubbleShape)
                    .textSelection(.enabled)
            } else {
                let attributed = (try? AttributedString(
                    markdown: message.content,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                )) ?? AttributedString(message.content)
                Text(attributed)
                    .font(DT.Font.body)
                    .padding(.horizontal, DT.Spacing.md)
                    .padding(.vertical, DT.Spacing.sm)
                    .background(.ultraThinMaterial, in: chatBubbleShape)
                    .textSelection(.enabled)
            }

            if message.role == .assistant { Spacer(minLength: 48) }
        }
    }

    private var chatBubbleShape: some Shape {
        RoundedRectangle(cornerRadius: DT.Radius.bubble, style: .continuous)
    }
}

// MARK: - Streaming Bubble

private struct StreamingBubble: View {
    let text: String
    @State private var dotAnimating = false

    var body: some View {
        HStack(alignment: .bottom) {
            if text.isEmpty {
                // Typing indicator — three animated dots
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .fill(Color.secondary.opacity(0.4))
                            .frame(width: 5, height: 5)
                            .offset(y: dotAnimating ? -3 : 0)
                            .animation(
                                .easeInOut(duration: 0.4)
                                .repeatForever(autoreverses: true)
                                .delay(Double(i) * 0.12),
                                value: dotAnimating
                            )
                    }
                }
                .onAppear { dotAnimating = true }
                .padding(.horizontal, DT.Spacing.md)
                .padding(.vertical, DT.Spacing.md)
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: DT.Radius.bubble, style: .continuous)
                )
            } else {
                Text(text)
                    .font(DT.Font.body)
                    .padding(.horizontal, DT.Spacing.md)
                    .padding(.vertical, DT.Spacing.sm)
                    .background(
                        .ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: DT.Radius.bubble, style: .continuous)
                    )
                    .textSelection(.enabled)
            }

            Spacer(minLength: 48)
        }
    }
}
