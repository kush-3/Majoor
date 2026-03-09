// StatusBarController.swift
// Majoor — Menu Bar Icon Controller

import AppKit

class StatusBarController {
    
    private(set) var statusItem: NSStatusItem?
    private let onLeftClick: () -> Void
    private let onSettingsClick: () -> Void
    private let onQuitClick: () -> Void
    private var pulseTimer: Timer?
    private var pulseOn = true
    
    enum AgentState { case idle, working, attention, error }
    
    init(onLeftClick: @escaping () -> Void,
         onSettingsClick: @escaping () -> Void,
         onQuitClick: @escaping () -> Void) {
        self.onLeftClick = onLeftClick
        self.onSettingsClick = onSettingsClick
        self.onQuitClick = onQuitClick
        setupStatusItem()
    }
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Majoor")
        button.image?.size = NSSize(width: 16, height: 16)
        button.image?.isTemplate = true
        button.action = #selector(handleClick)
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }
    
    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp { showContextMenu() }
        else { onLeftClick() }
    }
    
    private func showContextMenu() {
        let menu = NSMenu()
        let cmdItem = NSMenuItem(title: "Open Command Bar (⌘⇧Space)", action: #selector(doOpenCmd), keyEquivalent: "")
        cmdItem.target = self
        menu.addItem(cmdItem)
        menu.addItem(NSMenuItem.separator())
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(doSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit Majoor", action: #selector(doQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }
    
    @objc private func doOpenCmd() {
        if let d = NSApp.delegate as? AppDelegate { d.toggleCommandBar() }
    }
    @objc private func doSettings() { onSettingsClick() }
    @objc private func doQuit() { onQuitClick() }
    
    func setState(_ state: AgentState) {
        pulseTimer?.invalidate()
        pulseTimer = nil
        guard let button = statusItem?.button else { return }
        
        switch state {
        case .idle:
            button.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Ready")
            button.image?.isTemplate = true
        case .working:
            pulseOn = true
            pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
                guard let self, let btn = self.statusItem?.button else { return }
                self.pulseOn.toggle()
                btn.image = NSImage(systemSymbolName: self.pulseOn ? "bolt.fill" : "bolt", accessibilityDescription: "Working")
                btn.image?.isTemplate = true
            }
        case .attention:
            button.image = NSImage(systemSymbolName: "bolt.badge.clock.fill", accessibilityDescription: "Needs Input")
            button.image?.isTemplate = true
        case .error:
            button.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Error")
            button.image?.isTemplate = true
        }
    }
}
