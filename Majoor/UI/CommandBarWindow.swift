// CommandBarWindow.swift
// Majoor — Floating Command Bar Window
//
// NSPanel wrapper for the Spotlight-style command bar.
// Shows running task state with stop button when a task is active.

import SwiftUI
import AppKit

class CommandBarWindow {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<CommandBarView>?
    private var onSubmit: (String, CommandMode) -> Void
    private var onStop: () -> Void
    private weak var taskManager: TaskManager?

    var isVisible: Bool { panel?.isVisible ?? false }

    init(taskManager: TaskManager, onSubmit: @escaping (String, CommandMode) -> Void, onStop: @escaping () -> Void) {
        self.taskManager = taskManager
        self.onSubmit = onSubmit
        self.onStop = onStop
    }

    func show() {
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

        if let panel, let hostingView {
            hostingView.rootView = view
            if let screen = NSScreen.main {
                let f = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: f.midX - 300, y: f.midY + f.height * 0.15))
            }
            panel.alphaValue = 0
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().alphaValue = 1
            }
            return
        }

        let hosting = NSHostingView(rootView: view)
        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 80),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        newPanel.isReleasedWhenClosed = false
        newPanel.contentView = hosting
        newPanel.titlebarAppearsTransparent = true
        newPanel.titleVisibility = .hidden
        newPanel.level = .floating
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true

        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            newPanel.setFrameOrigin(NSPoint(x: f.midX - 300, y: f.midY + f.height * 0.15))
        }
        newPanel.alphaValue = 0
        newPanel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            newPanel.animator().alphaValue = 1
        }
        panel = newPanel
        hostingView = hosting
    }

    func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel?.orderOut(nil)
            self?.panel?.alphaValue = 1
        })
    }
}
