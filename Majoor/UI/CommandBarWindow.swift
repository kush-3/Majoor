// CommandBarWindow.swift
// Majoor — Floating Command Bar Window
//
// NSPanel wrapper for the Spotlight-style command bar.
// Shows running task state with stop button when a task is active.

import SwiftUI
import AppKit

class CommandBarWindow {
    private var window: NSWindow?
    private var onSubmit: (String, CommandMode) -> Void
    private var onStop: () -> Void
    private weak var taskManager: TaskManager?

    var isVisible: Bool { window?.isVisible ?? false }

    init(taskManager: TaskManager, onSubmit: @escaping (String, CommandMode) -> Void, onStop: @escaping () -> Void) {
        self.taskManager = taskManager
        self.onSubmit = onSubmit
        self.onStop = onStop
    }

    func show() {
        // Always recreate to pick up current running state
        hide()

        guard let taskManager else { return }

        let view = CommandBarView(
            isTaskRunning: taskManager.isTaskRunning,
            runningTaskInput: taskManager.runningTaskInput,
            onSubmit: { [weak self] input, mode in
                self?.onSubmit(input, mode)
                self?.hide()
            },
            onCancel: { [weak self] in self?.hide() },
            onStop: { [weak self] in self?.onStop() }
        )
        let hosting = NSHostingView(rootView: view)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 80),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.contentView = hosting
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.hasShadow = true

        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - 300, y: f.midY + f.height * 0.15))
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = panel
    }

    func hide() { window?.close(); window = nil }
}
