// CommandBarWindow.swift
// Majoor — Floating Command Bar Window

import SwiftUI
import AppKit

class CommandBarWindow {
    private var window: NSWindow?
    private var onSubmit: (String) -> Void
    
    var isVisible: Bool { window?.isVisible ?? false }
    
    init(onSubmit: @escaping (String) -> Void) { self.onSubmit = onSubmit }
    
    func show() {
        if let w = window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = CommandBarView(
            onSubmit: { [weak self] input in self?.onSubmit(input); self?.hide() },
            onCancel: { [weak self] in self?.hide() }
        )
        let hosting = NSHostingView(rootView: view)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 60),
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
