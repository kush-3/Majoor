// SessionEventPump.swift
// Majoor — Feeds the runtime's events into the UI
//
// Subscribes to the SessionManager's bus, applies every event to
// TaskManager on the main actor, and drives the status bar, toasts and the
// panel the way the app delegate's single-task callback used to.

import Foundation

@MainActor
final class SessionEventPump {

    private let taskManager: TaskManager
    private let setState: (StatusBarController.AgentState, String?) -> Void
    private let showPanel: () -> Void
    private var pumpTask: Task<Void, Never>?
    private var lastSeq: Int?

    init(taskManager: TaskManager,
         setState: @escaping (StatusBarController.AgentState, String?) -> Void,
         showPanel: @escaping () -> Void) {
        self.taskManager = taskManager
        self.setState = setState
        self.showPanel = showPanel
    }

    func start() {
        guard pumpTask == nil else { return }
        pumpTask = Task { [weak self] in await self?.pump() }
    }

    func stop() {
        pumpTask?.cancel()
        pumpTask = nil
    }

    private func pump() async {
        let manager = SessionManager.shared
        while !Task.isCancelled {
            let subscription = await manager.bus.subscribe(since: lastSeq)
            if subscription.snapshotRequired {
                let snapshot = await manager.snapshot()
                for info in snapshot.sessions where !info.state.isTerminal {
                    taskManager.apply(.created(info))
                    taskManager.apply(.state(id: info.id, state: info.state))
                }
                for request in snapshot.approvals {
                    taskManager.apply(.approvalRequested(request))
                }
            }
            for item in subscription.replay { handle(item) }
            for await item in subscription.stream { handle(item) }
            // The stream ended: the bus cut us off for falling behind, or shutdown.
            // Loop around and resubscribe from the last sequence we saw.
        }
    }

    private func handle(_ item: SequencedEvent) {
        lastSeq = item.seq
        taskManager.apply(item.event)
        switch item.event {
        case .created:
            setState(.working, nil)
        case .approvalRequested:
            NotificationCenter.default.post(name: .majoorOpenPanel, object: nil)
        case .finished(let id, let state, let summary):
            switch state {
            case .completed:
                setState(.success, nil)
                taskManager.showToast(type: .info, title: "Task Complete", body: summary, autoDismiss: 6.0,
                                      actionLabel: "View Details") {
                    NotificationCenter.default.post(name: .majoorOpenTaskDetail, object: nil, userInfo: ["taskId": id.uuidString])
                }
            case .stopped:
                setState(taskManager.isTaskRunning ? .working : .idle, nil)
                taskManager.showToast(type: .warning, title: "Task Stopped", body: "Task was cancelled by user.", autoDismiss: 4.0)
            default:
                let incomplete = IncompleteReason.allCases.contains { $0.userFacing == summary }
                setState(incomplete ? .attention : .error, summary)
                taskManager.showToast(type: incomplete ? .warning : .error,
                                      title: incomplete ? "Task Incomplete" : "Task Failed",
                                      body: summary, autoDismiss: incomplete ? 8.0 : nil)
            }
            showPanel()
        default:
            break
        }
    }
}
