// StatusBarController.swift
// Majoor — Menu Bar Icon Controller
//
// Manages the status bar icon with state-based SF Symbols.
// States: idle, working (pulse), success (checkmark flash), attention, error.
// Uses template images throughout for proper dark/light mode adaptation.

import AppKit

class StatusBarController {

    private(set) var statusItem: NSStatusItem?
    private let onLeftClick: () -> Void
    private let onSettingsClick: () -> Void
    private let onQuitClick: () -> Void
    private var pulseTimer: Timer?
    private var successRevertTimer: Timer?
    private var pulseOn = true
    private var currentState: AgentState = .idle

    enum AgentState { case idle, working, success, attention, error }

    init(onLeftClick: @escaping () -> Void,
         onSettingsClick: @escaping () -> Void,
         onQuitClick: @escaping () -> Void) {
        self.onLeftClick = onLeftClick
        self.onSettingsClick = onSettingsClick
        self.onQuitClick = onQuitClick
        setupStatusItem()
        observePowerState()
    }

    private func observePowerState() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.pulseTimer?.invalidate()
            self?.pulseTimer = nil
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.currentState == .working else { return }
            self.setState(.working)
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }

        // Use a clean, recognizable symbol
        button.image = NSImage(systemSymbolName: "hammer.fill", accessibilityDescription: "Majoor")
        button.image?.size = NSSize(width: 16, height: 16)
        button.image?.isTemplate = true
        button.action = #selector(handleClick)
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp { showContextMenu() }
        else {
            if currentState == .error { setState(.idle) }
            onLeftClick()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()

        let cmdItem = NSMenuItem(title: "Command Bar", action: #selector(doOpenCmd), keyEquivalent: "")
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

    func setState(_ state: AgentState, message: String? = nil) {
        pulseTimer?.invalidate()
        pulseTimer = nil
        successRevertTimer?.invalidate()
        successRevertTimer = nil
        currentState = state
        guard let button = statusItem?.button else { return }
        button.alphaValue = 1.0

        switch state {
        case .idle:
            button.image = NSImage(systemSymbolName: "hammer.fill", accessibilityDescription: "Ready")
            button.image?.isTemplate = true
            button.contentTintColor = nil
            button.toolTip = "Majoor"

        case .working:
            let tooltip = message ?? "Working..."
            button.toolTip = "Majoor -- \(tooltip)"
            button.contentTintColor = nil
            button.image = NSImage(systemSymbolName: "hammer.fill", accessibilityDescription: "Working")
            button.image?.isTemplate = true

            // Gentle pulse — not jarring, just enough to signal activity
            pulseOn = true
            pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: true) { [weak self] _ in
                guard let self, let btn = self.statusItem?.button else { return }
                self.pulseOn.toggle()
                let target: CGFloat = self.pulseOn ? 1.0 : 0.5
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.7
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    btn.animator().alphaValue = target
                }
            }

        case .success:
            button.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Done")
            button.image?.isTemplate = false
            button.contentTintColor = .systemGreen
            button.toolTip = "Majoor -- Task complete"
            successRevertTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
                self?.setState(.idle)
            }

        case .attention:
            button.image = NSImage(systemSymbolName: "hammer.circle", accessibilityDescription: "Needs Input")
            button.image?.isTemplate = true
            button.contentTintColor = nil
            button.toolTip = "Majoor -- Waiting for input"

        case .error:
            button.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Error")
            button.image?.isTemplate = true
            button.contentTintColor = .systemRed
            button.toolTip = message != nil ? "Majoor -- \(message!)" : "Majoor -- Error (click to dismiss)"
        }
    }
}
