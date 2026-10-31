// PanelChannel.swift
// Majoor — The command bar and panel as a channel
//
// The command bar feeds `submit(_:)`; results and status text come back as
// toasts. Approvals are not routed through `send`: the panel renders them
// from SessionEvents and answers through SessionManager directly.

import Foundation

nonisolated final class PanelChannel: Channel, @unchecked Sendable {

    static let channelId = "panel"

    let id = PanelChannel.channelId
    let trust: ChannelTrust = .local

    private let stream: AsyncStream<InboundMessage>
    private let continuation: AsyncStream<InboundMessage>.Continuation
    private let taskManager: TaskManager

    init(taskManager: TaskManager) {
        self.taskManager = taskManager
        (stream, continuation) = AsyncStream.makeStream(of: InboundMessage.self, bufferingPolicy: .unbounded)
    }

    var inbound: AsyncStream<InboundMessage> { stream }

    /// Called from the main actor by the command bar and the URL hook.
    func submit(_ text: String) {
        continuation.yield(InboundMessage(channelId: id, threadKey: ChannelRef.panel.threadKey, text: text))
    }

    func send(to threadKey: String, text: String, attachments: [URL]) async throws {
        let manager = taskManager
        await MainActor.run {
            manager.showToast(type: .info, title: "Majoor", body: text, autoDismiss: 8.0)
        }
    }
}
