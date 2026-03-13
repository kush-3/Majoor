// AppDelegate.swift
// Majoor — Your AI That Does The Work

import SwiftUI
import Combine
import UserNotifications
import Carbon.HIToolbox

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    
    private var statusBarController: StatusBarController?
    private var commandBarWindow: CommandBarWindow?
    private var panelWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var localKeyMonitor: Any?
    private var hotKeyRef: EventHotKeyRef?
    
    let taskManager = TaskManager()
    private var agentLoop: AgentLoop?
    
    // MARK: - Lifecycle
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        MajoorLogger.log("Majoor is starting up...")
        MajoorLogger.log(Bundle.main.bundleIdentifier!)

        // Configure notification system with categories and delegate
        NotificationManager.shared.configure()

        statusBarController = StatusBarController(
            onLeftClick: { [weak self] in self?.togglePanel() },
            onSettingsClick: { [weak self] in self?.openSettings() },
            onQuitClick: { NSApplication.shared.terminate(nil) }
        )
        
        // Clear any stale Keychain entry from previous testing
        KeychainManager.shared.deleteAPIKey(for: .anthropic)

        registerLocalShortcuts()
        registerGlobalHotKey()
        setupAgentLoop()

        // Start MCP servers in the background (don't block the agent loop)
        Task { await MCPServerManager.shared.startAll() }

        commandBarWindow = CommandBarWindow(onSubmit: { [weak self] input in
            self?.handleCommand(input)
        })

        MajoorLogger.log("Majoor is ready. ⌘+Shift+Space to open.")
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }

        // Stop MCP servers
        Task { await MCPServerManager.shared.stopAll() }
    }
    
    // MARK: - Agent
    
    private func setupAgentLoop() {
        if APIConfig.claudeAPIKey.isEmpty {
            MajoorLogger.log("⚠️ No API key configured in APIConfig.swift")
        }
        // Initialize database on launch
        _ = DatabaseManager.shared

        let tools = ToolRegistry.defaultTools()
        agentLoop = AgentLoop(tools: tools, taskManager: taskManager)
    }
    
    // MARK: - Command Handling
    
    private func handleCommand(_ input: String) {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
        commandBarWindow?.hide()
        statusBarController?.setState(.working)
        
        guard !APIConfig.claudeAPIKey.isEmpty else {
            statusBarController?.setState(.error)
            sendNotification(title: "Majoor — Setup Required", body: "API key not configured in APIConfig.swift")
            return
        }
        
        Task {
            guard let loop = agentLoop else { return }
            do {
                let result = try await loop.execute(userInput: input)
                statusBarController?.setState(.idle)
                sendNotification(title: "Majoor — Task Complete", body: result.summary)
            } catch {
                statusBarController?.setState(.error)
                sendNotification(title: "Majoor — Task Failed", body: error.localizedDescription, category: NotificationManager.taskFailedCategory)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                statusBarController?.setState(.idle)
            }
        }
    }
    
    // MARK: - Windows
    
    private func togglePanel() {
        if let w = panelWindow, w.isVisible { w.close(); panelWindow = nil }
        else { showPanel() }
    }
    
    private func showPanel() {
        let view = MainPanelView().environmentObject(taskManager)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 380, height: 500)
        
        let panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.contentView = hosting
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.backgroundColor = .clear
        
        if let button = statusBarController?.statusItem?.button, let bw = button.window {
            let f = bw.frame
            panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.minY - panel.frame.height - 5))
        }
        panel.makeKeyAndOrderFront(nil)
        panelWindow = panel
    }
    
    private func openSettings() {
        if settingsWindow == nil {
            let settingsView = SettingsView().environmentObject(taskManager)
            let hostingController = NSHostingController(rootView: settingsView)
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 500, height: 350))
            window.center()
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }

        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func registerLocalShortcuts() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == [.command], event.charactersIgnoringModifiers == "," {
                self?.openSettings()
                return nil
            }
            return event
        }
    }
    
    // MARK: - Global Hotkey
    
    private func registerGlobalHotKey() {
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D4A5220), id: 1)
        let modifiers: UInt32 = UInt32(cmdKey | shiftKey)
        let keyCode: UInt32 = UInt32(kVK_Space)
        
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr else {
            MajoorLogger.log("⚠️ Failed to register hotkey: \(status)")
            return
        }
        hotKeyRef = ref
        
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, _, userData -> OSStatus in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { delegate.toggleCommandBar() }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil)
        
        MajoorLogger.log("✅ Hotkey registered: ⌘+Shift+Space")
    }
    
    func toggleCommandBar() {
        if commandBarWindow?.isVisible == true { commandBarWindow?.hide() }
        else { commandBarWindow?.show() }
    }
    
    // MARK: - Notifications

    private func sendNotification(title: String, body: String, category: String = NotificationManager.taskCompleteCategory) {
        NotificationManager.shared.sendSimple(title: title, body: body, category: category)
    }
}
