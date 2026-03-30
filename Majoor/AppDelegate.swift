// AppDelegate.swift
// Majoor — Your AI That Does The Work

import SwiftUI
import Combine
import UserNotifications
import Carbon.HIToolbox

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {

    private var statusBarController: StatusBarController?
    private var commandBarWindow: CommandBarWindow?
    private var panelWindow: NSPanel?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var localKeyMonitor: Any?
    private var hotKeyRef: EventHotKeyRef?

    let taskManager = TaskManager()
    let chatManager = ChatManager()
    let updateManager = UpdateManager()
    private var agentLoop: AgentLoop?
    private var runningTaskHandle: Task<Void, Never>?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        MajoorLogger.log("Majoor is starting up...")
        MajoorLogger.log(Bundle.main.bundleIdentifier!)

        // Configure notification system with categories and delegate (fallback)
        NotificationManager.shared.configure()

        // Start Sparkle updater AFTER notification delegate is set
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
            MajoorLogger.log("System sleeping — stopping MCP servers")
            Task { await MCPServerManager.shared.stopAll() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { _ in
            MajoorLogger.log("System woke — restarting MCP servers")
            Task { await MCPServerManager.shared.startAll() }
        }

        // Listen for "Open Settings" from notification actions
        NotificationCenter.default.addObserver(forName: .majoorOpenSettings, object: nil, queue: .main) { [weak self] _ in
            self?.openSettings()
        }

        // Listen for "Open Panel" (e.g., when a confirmation is needed)
        NotificationCenter.default.addObserver(forName: .majoorOpenPanel, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if self.panelWindow == nil || self.panelWindow?.isVisible == false {
                self.showPanel()
            }
        }

        commandBarWindow = CommandBarWindow(
            taskManager: taskManager,
            onSubmit: { [weak self] input, mode in
                switch mode {
                case .task:
                    self?.handleCommand(input)
                case .chat:
                    self?.taskManager.selectedTab = 1
                    self?.showPanel()
                    self?.chatManager.send(input)
                }
            },
            onStop: { [weak self] in
                self?.stopRunningTask()
            }
        )

        // Show onboarding on first launch
        if !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            showOnboarding()
        }

        MajoorLogger.log("Majoor is ready. +Shift+Space to open.")
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
            MajoorLogger.log("No API key configured in APIConfig.swift")
        }
        // Initialize database on launch
        _ = DatabaseManager.shared

        let tools = ToolRegistry.defaultTools()
        agentLoop = AgentLoop(tools: tools, taskManager: taskManager)
    }

    // MARK: - Command Handling

    private func handleCommand(_ input: String) {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // Prevent double-submission
        guard !taskManager.isTaskRunning else { return }

        commandBarWindow?.hide()
        statusBarController?.setState(.working)
        taskManager.isTaskRunning = true
        taskManager.runningTaskInput = input

        guard !APIConfig.claudeAPIKey.isEmpty else {
            statusBarController?.setState(.error, message: "API key not configured")
            taskManager.isTaskRunning = false
            taskManager.showToast(type: .error, title: "Setup Required",
                                  body: "API key not configured. Open Settings to add your Anthropic API key.",
                                  autoDismiss: nil, actionLabel: "Settings") { [weak self] in
                self?.openSettings()
            }
            showPanel()
            return
        }

        runningTaskHandle = Task { [weak self] in
            guard let self, let loop = agentLoop else { return }
            do {
                let result = try await loop.execute(userInput: input)

                guard !Task.isCancelled else {
                    await MainActor.run {
                        self.taskManager.isTaskRunning = false
                        self.statusBarController?.setState(.idle)
                    }
                    return
                }

                await MainActor.run {
                    self.taskManager.isTaskRunning = false
                    self.statusBarController?.setState(.success)
                    let completedTask = self.taskManager.tasks.first
                    self.taskManager.showToast(
                        type: .info, title: "Task Complete", body: result.summary, autoDismiss: 6.0,
                        actionLabel: "View Details",
                        action: {
                            if let task = completedTask {
                                NotificationCenter.default.post(
                                    name: .majoorOpenTaskDetail, object: nil,
                                    userInfo: ["taskId": task.id.uuidString])
                            }
                        })
                    self.showPanel()
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.taskManager.isTaskRunning = false
                    self.statusBarController?.setState(.idle)
                    self.taskManager.showToast(type: .warning, title: "Task Stopped", body: "Task was cancelled by user.", autoDismiss: 4.0)
                    self.showPanel()
                }
            } catch let error as LLMError {
                await MainActor.run {
                    self.taskManager.isTaskRunning = false
                    self.handleLLMError(error)
                }
            } catch {
                await MainActor.run {
                    self.taskManager.isTaskRunning = false
                    self.statusBarController?.setState(.error, message: error.localizedDescription)
                    self.taskManager.showToast(type: .error, title: "Task Failed", body: error.localizedDescription)
                    self.showPanel()
                }
            }
        }
    }

    func stopRunningTask() {
        runningTaskHandle?.cancel()
        runningTaskHandle = nil
        taskManager.isTaskRunning = false
        statusBarController?.setState(.idle)
        // Mark the running task as failed
        if let runningTask = taskManager.tasks.first(where: { $0.status == .running }) {
            runningTask.status = .failed
            runningTask.summary = "Cancelled by user"
            runningTask.completedAt = Date()
        }
    }

    private func handleLLMError(_ error: LLMError) {
        let errorDesc = error.errorDescription ?? "Unknown error"
        statusBarController?.setState(.error, message: errorDesc)
        taskManager.showToast(type: .error, title: "Task Failed", body: errorDesc)
        showPanel()
    }

    /// Send macOS notification only when the panel is not visible (fallback)
    private func notifyIfPanelClosed(title: String, body: String) {
        if panelWindow == nil || panelWindow?.isVisible == false {
            NotificationManager.shared.sendSimple(title: title, body: body)
        }
    }

    // MARK: - Windows

    private func togglePanel() {
        if let w = panelWindow, w.isVisible {
            w.close()
        } else {
            showPanel()
        }
    }

    func showPanel() {
        // Persistent panel: create once, then just show/hide
        if panelWindow == nil {
            let view = MainPanelView()
                .environmentObject(taskManager)
                .environmentObject(chatManager)
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 520)

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
            panel.animationBehavior = .utilityWindow
            panelWindow = panel
        }

        // Position below the status bar icon
        if let button = statusBarController?.statusItem?.button, let bw = button.window, let panel = panelWindow {
            let f = bw.frame
            panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.minY - panel.frame.height - 5))
        }
        panelWindow?.makeKeyAndOrderFront(nil)
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
            MajoorLogger.log("Failed to register hotkey: \(status)")
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

        MajoorLogger.log("Hotkey registered: Cmd+Shift+Space")
    }

    func toggleCommandBar() {
        if commandBarWindow?.isVisible == true { commandBarWindow?.hide() }
        else { commandBarWindow?.show() }
    }
}
