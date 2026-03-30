// CommandBarWindow.swift
// Majoor — Floating Command Bar Window
//
// NSPanel wrapper for the Spotlight-style command bar.
// Positioned in the upper-center third of the screen (like Spotlight).
// Smooth fade-in/out animation.

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

        let barWidth = DT.Layout.commandBarWidth

        if let panel, let hostingView {
            hostingView.rootView = view
            positionPanel(panel, width: barWidth)
            panel.alphaValue = 0
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
            return
        }

        let hosting = NSHostingView(rootView: view)
        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: barWidth, height: 80),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        newPanel.isReleasedWhenClosed = false
        newPanel.contentView = hosting
        newPanel.titlebarAppearsTransparent = true
        newPanel.titleVisibility = .hidden
        newPanel.level = .floating
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = false  // SwiftUI handles the shadow

        positionPanel(newPanel, width: barWidth)
        newPanel.alphaValue = 0
        newPanel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            newPanel.animator().alphaValue = 1
        }
        panel = newPanel
        hostingView = hosting
    }

    func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel?.orderOut(nil)
            self?.panel?.alphaValue = 1
        })
    }

    /// Position the panel in the upper third of the screen, centered horizontally.
    /// This matches Spotlight's positioning.
    private func positionPanel(_ panel: NSPanel, width: CGFloat) {
        guard let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        let x = f.midX - width / 2
        // Upper third: ~28% down from top of visible frame
        let y = f.maxY - f.height * 0.28
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
