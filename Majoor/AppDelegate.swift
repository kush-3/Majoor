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
    private var onboardingWindow: NSWindow?
    private var localKeyMonitor: Any?
    private var hotKeyRef: EventHotKeyRef?
    
    let taskManager = TaskManager()
    let updateManager = UpdateManager()
    private var agentLoop: AgentLoop?
    
    // MARK: - Lifecycle
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        MajoorLogger.log("Majoor is starting up...")
        MajoorLogger.log(Bundle.main.bundleIdentifier!)

        // Configure notification system with categories and delegate
        NotificationManager.shared.configure()

        // Start Sparkle updater AFTER notification delegate is set,
        // then re-assert our delegate so Sparkle doesn't override it.
        updateManager.startUpdater()

        statusBarController = StatusBarController(
            onLeftClick: { [weak self] in self?.togglePanel() },
            onSettingsClick: { [weak self] in self?.openSettings() },
            onQuitClick: { NSApplication.shared.terminate(nil) }
        )
        
        registerLocalShortcuts()
        registerGlobalHotKey()
        setupAgentLoop()

        // Start MCP servers in the background
        Task { await MCPServerManager.shared.startAll() }

        // Power state awareness: stop MCP servers before sleep, restart on wake
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: nil
        ) { _ in
            MajoorLogger.log("💤 System sleeping — stopping MCP servers")
            Task { await MCPServerManager.shared.stopAll() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { _ in
            MajoorLogger.log("☀️ System woke — restarting MCP servers")
            Task { await MCPServerManager.shared.startAll() }
        }

        // Listen for "Open Settings" from notification actions
        NotificationCenter.default.addObserver(forName: .majoorOpenSettings, object: nil, queue: .main) { [weak self] _ in
            self?.openSettings()
        }

        // Listen for "Open Panel" (e.g., when a pipeline plan is proposed)
        NotificationCenter.default.addObserver(forName: .majoorOpenPanel, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if self.panelWindow == nil || self.panelWindow?.isVisible == false {
                self.showPanel()
            }
        }

        commandBarWindow = CommandBarWindow(onSubmit: { [weak self] input in
            self?.handleCommand(input)
        })

        // Show onboarding on first launch
        if !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            showOnboarding()
        }

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
        NSApp.hide(nil)  // Deactivate so notifications show as system banners
        statusBarController?.setState(.working)

        guard !APIConfig.claudeAPIKey.isEmpty else {
            statusBarController?.setState(.error, message: "API key not configured")
            sendNotification(title: "Majoor — Setup Required", body: "API key not configured. Open Settings to add your Anthropic API key.")
            return
        }

        Task {
            guard let loop = agentLoop else { return }
            do {
                let result = try await loop.execute(userInput: input)
                statusBarController?.setState(.idle)
                sendNotification(title: "Majoor — Task Complete", body: result.summary)
            } catch let error as LLMError {
                handleLLMError(error)
            } catch {
                statusBarController?.setState(.error, message: error.localizedDescription)
                sendNotification(title: "Majoor — Task Failed", body: error.localizedDescription, category: NotificationManager.taskFailedCategory)
            }
        }
    }

    private func handleLLMError(_ error: LLMError) {
        let errorDesc = error.errorDescription ?? "Unknown error"
        statusBarController?.setState(.error, message: errorDesc)

        switch error {
        case .invalidAPIKey:
            sendNotification(title: "Majoor — Invalid API Key", body: "Your API key is invalid or expired. Open Settings to update it.", category: NotificationManager.authErrorCategory)
        case .noInternet:
            sendNotification(title: "Majoor — No Internet", body: "Check your network connection and try again.")
        case .contextOverflow:
            sendNotification(title: "Majoor — Task Too Complex", body: "The conversation exceeded the context limit. Try breaking it into smaller steps.", category: NotificationManager.taskFailedCategory)
        case .rateLimited(let retryAfter):
            let waitMsg = retryAfter.map { "Try again in \($0) seconds." } ?? "Try again in a few minutes."
            sendNotification(title: "Majoor — Rate Limited", body: "Retried multiple times but still rate limited. \(waitMsg)", category: NotificationManager.taskFailedCategory)
        case .serverOverloaded:
            sendNotification(title: "Majoor — API Overloaded", body: "Claude API is overloaded after multiple retries. Try again in a few minutes.", category: NotificationManager.taskFailedCategory)
        case .networkError(let msg):
            sendNotification(title: "Majoor — Network Error", body: "Failed after retries: \(msg)", category: NotificationManager.taskFailedCategory)
        case .apiError(let msg):
            sendNotification(title: "Majoor — API Error", body: msg, category: NotificationManager.taskFailedCategory)
        case .decodingError:
            sendNotification(title: "Majoor — Response Error", body: "Failed to parse API response. This may be a temporary issue.", category: NotificationManager.taskFailedCategory)
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
    
    func showOnboarding() {
        if onboardingWindow == nil {
            let onboardingView = OnboardingView(onComplete: { [weak self] in
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
            })
            let hostingController = NSHostingController(rootView: onboardingView)
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Welcome to Majoor"
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 500, height: 400))
            window.center()
            window.isReleasedWhenClosed = false
            onboardingWindow = window
        }
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
