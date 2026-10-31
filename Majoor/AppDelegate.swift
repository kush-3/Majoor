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
    private var eventPump: SessionEventPump?
    private var panelChannel: PanelChannel?
    private var remoteClient: RemoteRuntimeClient?
    private var remoteGateway: RemoteSessionGateway?
    private var localRuntimeConfigured = false

    /// Client mode: when set, the command bar runs tasks on this Mac instead
    /// of the paired runtime. Explicit, persisted, never flipped automatically.
    static let runHereKey = "runHere"
    static var runHere: Bool { UserDefaults.standard.bool(forKey: runHereKey) }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    // MARK: - Lifecycle

    /// True when the process is a unit-test host. The MajoorTests bundle is
    /// loaded into this app, so launch must not start MCP servers, register
    /// the global hotkey, open the database or show onboarding.
    static var isRunningTests: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Self.isRunningTests {
            MajoorLogger.log("Test host: skipping startup side effects")
            return
        }
        let mode = AppMode.current
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURLEvent(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        MajoorLogger.log("Majoor is starting up in \(mode.rawValue) mode...")
        MajoorLogger.log(Bundle.main.bundleIdentifier!)

        // Configure notification system with categories and delegate (fallback)
        NotificationManager.shared.configure()

        // Start Sparkle updater AFTER notification delegate is set
        updateManager.startUpdater()

        statusBarController = StatusBarController(
            onLeftClick: { [weak self] in self?.togglePanel() },
            onSettingsClick: { [weak self] in self?.openSettings() },
            onStopAllClick: { [weak self] in self?.stopRunningTask() },
            onQuitClick: { NSApplication.shared.terminate(nil) }
        )

        registerLocalShortcuts()
        registerGlobalHotKey()
        setupAgentLoop(mode: mode)

        if mode != .client {
            // Start MCP servers in the background
            Task { await MCPServerManager.shared.startAll() }
        }

        // Power state awareness: stop MCP servers and the control API before
        // sleep, restart on wake; a client probes its connection on wake.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: nil
        ) { _ in
            MajoorLogger.log("System sleeping")
            if mode != .client {
                Task { await MCPServerManager.shared.stopAll() }
                Task { await ControlServer.shared.stop() }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                MajoorLogger.log("System woke")
                if mode != .client {
                    Task { await MCPServerManager.shared.startAll() }
                    Task { await ControlServer.shared.restartIfEnabled() }
                }
                if let client = self?.remoteClient { Task { await client.wake() } }
            }
        }

        // Listen for "Open Settings" from notification actions
        // Observers on `queue: .main` run on the main thread, but the closure
        // type is @Sendable, so the compiler cannot see that; assumeIsolated
        // asserts it at runtime instead of hopping.
        NotificationCenter.default.addObserver(forName: .majoorOpenSettings, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.openSettings() }
        }

        // Listen for "Open Panel" (e.g., when a confirmation is needed)
        NotificationCenter.default.addObserver(forName: .majoorOpenPanel, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.panelWindow == nil || self.panelWindow?.isVisible == false {
                    self.showPanel()
                }
            }
        }

        // STOP from the panel toolbar
        NotificationCenter.default.addObserver(forName: .majoorStopAll, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopRunningTask() }
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

        if AppMode.current != .client {
            Task { await MCPServerManager.shared.stopAll() }
            Task { await ControlServer.shared.stop() }
        }
        if let client = remoteClient { Task { await client.stop() } }
    }

    // MARK: - Agent

    private func setupAgentLoop(mode: AppMode) {
        if APIConfig.claudeAPIKey.isEmpty, mode != .client {
            MajoorLogger.log("No API key configured in APIConfig.swift")
        }
        // Initialize database on launch
        _ = DatabaseManager.shared

        // Decay relevance of memories untouched for 90+ days so retrieval
        // ranking favors fresh context (search orders by relevanceScore).
        Task.detached(priority: .utility) {
            do {
                try MemoryStore.shared.archiveOld()
            } catch {
                MajoorLogger.error("Memory decay pass failed: \(error)")
            }
        }

        // The panel is a channel in every mode: in client mode it carries
        // "Run here" tasks to the local runtime, which is configured lazily
        // so launching as a client does no runtime work.
        let channel = PanelChannel(taskManager: taskManager)
        panelChannel = channel
        Task {
            await ChannelRouter.shared.configure(manager: SessionManager.shared, owners: { ContactPolicyStore.shared.owners() })
            await ChannelRouter.shared.register(channel)
        }
        eventPump = SessionEventPump(
            taskManager: taskManager,
            setState: { [weak self] state, message in self?.statusBarController?.setState(state, message: message) },
            showPanel: { [weak self] in self?.showPanel() })
        eventPump?.start()

        switch mode {
        case .local, .runtime:
            ensureLocalRuntime()
            Task {
                await ControlServer.shared.configure(
                    gateway: LocalSessionGateway(manager: SessionManager.shared, channelId: "control", trust: .authenticatedClient, tasks: TaskPersistence.shared),
                    pairing: PairingManager(store: ClientStore.shared),
                    bus: SessionManager.shared.bus,
                    runtime: ControlRuntimeInfo(runtimeId: ControlServer.runtimeId, serverVersion: appVersion, mode: mode.rawValue))
                if ControlServer.isEnabled { await ControlServer.shared.start() }
            }
        case .client:
            setupClient()
        }
    }

    /// Configures the local SessionManager once. Local and runtime modes do
    /// it at launch; client mode on the first "Run here".
    private func ensureLocalRuntime() {
        guard !localRuntimeConfigured else { return }
        localRuntimeConfigured = true
        let loop = AgentLoop(tools: ToolRegistry.defaultTools())
        Task {
            await SessionManager.shared.configure(
                loop: loop,
                store: SessionStore.shared,
                persistTask: { TaskPersistence.shared.save($0) },
                notify: { request in
                    NotificationManager.shared.sendActionable(id: request.id, title: request.title, body: request.body, category: request.category)
                })
        }
    }

    private func setupClient() {
        let client = RemoteRuntimeClient(appVersion: appVersion)
        remoteClient = client
        remoteGateway = RemoteSessionGateway(client: client)
        RuntimeConnectionModel.shared.attach(client: client)
        eventPump?.startRemote(client: client)
        taskManager.approvalRouter = { [weak self] id, decision, channel in
            await self?.routeApproval(id: id, decision: decision, byChannel: channel)
        }
        NotificationManager.approvalHandler.withValue { handler in
            handler = { id, decision, channel in
                await MainActor.run {
                    (NSApp.delegate as? AppDelegate)?.taskManager.answerApproval(id: id, decision: decision, byChannel: channel)
                }
            }
        }
        if let credentials = ClientCredentialsStore.load() {
            Task {
                await client.configure(credentials)
                await client.start()
                RuntimeConnectionModel.shared.refreshPairing()
            }
        } else {
            MajoorLogger.log("Client mode: not paired yet. Open Settings ▸ Mac mini to pair.")
        }
    }

    /// Answers go to whichever runtime asked: the remote one (with the nonce
    /// the approval carried) or the local SessionManager.
    private func routeApproval(id: String, decision: ApprovalDecision, byChannel: String) async {
        if let gateway = remoteGateway, taskManager.isRemoteApproval(id: id),
           let request = taskManager.pendingApprovals.first(where: { $0.id == id }) {
            let result = await gateway.answerApproval(id: id, nonce: request.nonce, decision: decision)
            if result != .ok {
                taskManager.showToast(type: .error, title: "Approval not accepted", body: "The runtime answered: \(result)", autoDismiss: 6.0)
            }
            return
        }
        _ = await SessionManager.shared.answerApproval(id: id, nonce: nil, decision: decision, byChannel: byChannel)
    }

    // MARK: - URL Scheme (local automation hook)

    /// `majoor://task?text=…&token=…` submits a task exactly as the command bar
    /// would. Any local process or web link can open a URL scheme, so the hook
    /// is inert unless the app was launched with MAJOOR_AUTOMATION_TOKEN in its
    /// environment (`open --env …`) and the URL carries the same value. Used by
    /// QA harnesses; the 2.0 control API supersedes it.
    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: string) else { return }
        handleIncomingURL(url)
    }

    private func handleIncomingURL(_ url: URL) {
        guard url.scheme?.lowercased() == "majoor", url.host?.lowercased() == "task",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let text = items.first(where: { $0.name == "text" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            MajoorLogger.log("⛔ Ignored URL: \(url.absoluteString.prefix(120))")
            return
        }
        let expected = ProcessInfo.processInfo.environment["MAJOOR_AUTOMATION_TOKEN"] ?? ""
        let given = items.first(where: { $0.name == "token" })?.value ?? ""
        guard !expected.isEmpty, given == expected else {
            MajoorLogger.log("⛔ majoor://task ignored: automation token missing or wrong")
            return
        }
        MajoorLogger.log("🔗 majoor://task accepted (\(text.count) chars)")
        handleCommand(text)
    }

    // MARK: - Command Handling

    private func handleCommand(_ input: String) {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        commandBarWindow?.hide()

        if AppMode.current == .client, !Self.runHere {
            submitRemote(input)
            return
        }
        runLocally(input)
    }

    /// The 1.x path: the local runtime, with this Mac's files and keys.
    private func runLocally(_ input: String) {
        guard !APIConfig.claudeAPIKey.isEmpty else {
            statusBarController?.setState(.error, message: "API key not configured")
            taskManager.showToast(type: .error, title: "Setup Required",
                                  body: "API key not configured. Open Settings to add your Anthropic API key.",
                                  autoDismiss: nil, actionLabel: "Settings") { [weak self] in
                self?.openSettings()
            }
            showPanel()
            return
        }
        ensureLocalRuntime()
        statusBarController?.setState(.working)
        // The panel is a channel like any other: the router authorizes the
        // message, recognizes the exact command forms, and starts a session.
        panelChannel?.submit(input)
    }

    /// Client mode: the paired runtime does the work. A failure is shown,
    /// never silently retried locally: a task meant for the Mac mini must
    /// not quietly run with this Mac's files and identity.
    private func submitRemote(_ input: String) {
        guard let gateway = remoteGateway, RuntimeConnectionModel.shared.isPaired else {
            taskManager.showToast(type: .error, title: "Not paired",
                                  body: "Pair this Mac with your runtime in Settings ▸ Mac mini, or switch on Run here.",
                                  autoDismiss: nil, actionLabel: "Settings") { [weak self] in self?.openSettings() }
            showPanel()
            return
        }
        let command = InboundCommand.parse(input)
        statusBarController?.setState(.working)
        Task { [weak self] in
            do {
                switch command {
                case .stopAll, .stop(nil):
                    let stopped = await gateway.stop(shortId: nil)
                    self?.taskManager.showToast(type: .warning, title: "Stopped", body: stopped.isEmpty ? "Nothing was running on the runtime." : "Stopped \(stopped.count) session(s) on the runtime.", autoDismiss: 4.0)
                case .stop(let shortId?):
                    let stopped = await gateway.stop(shortId: shortId)
                    self?.taskManager.showToast(type: .warning, title: "Stopped", body: stopped.isEmpty ? "No running session \(shortId)." : "Stopped session \(shortId).", autoDismiss: 4.0)
                case .status:
                    let live = await gateway.list().filter { !$0.state.isTerminal }
                    let body = live.isEmpty ? "Nothing running on the runtime." : live.map { "#\($0.shortId) \($0.state.rawValue): \($0.input.prefix(40))" }.joined(separator: "\n")
                    self?.taskManager.showToast(type: .info, title: "Runtime status", body: body, autoDismiss: 8.0)
                case .none:
                    let threadKey = await gateway.defaultThreadKey()
                    _ = try await gateway.submit(input, threadKey: threadKey)
                }
            } catch {
                let reason = (error as? RemoteClientError)?.userMessage ?? "\(error)"
                self?.statusBarController?.setState(self?.taskManager.isTaskRunning == true ? .working : .idle)
                self?.taskManager.showToast(type: .error, title: "Mac mini unreachable", body: "\(reason). Retry from the command bar, or run this task on this Mac.",
                                            autoDismiss: nil, actionLabel: "Run here") { [weak self] in self?.runLocally(input) }
                self?.showPanel()
            }
        }
    }

    func stopRunningTask() {
        // STOP: every session, the queue, every pending approval. The sessions
        // record their own stopped outcome; the UI follows the events.
        Task { await SessionManager.shared.stopAll() }
        if let gateway = remoteGateway { Task { _ = await gateway.stop(shortId: nil) } }
        taskManager.clearConfirmation()
        statusBarController?.setState(.idle)
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
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func hidePanel() {
        guard let panel = panelWindow else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.panelWindow?.close()
                self?.panelWindow?.alphaValue = 1
            }
        })
    }

    func showPanel() {
        // Persistent panel: create once, then just show/hide
        if panelWindow == nil {
            let view = MainPanelView()
                .environmentObject(taskManager)
                .environmentObject(chatManager)
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(x: 0, y: 0, width: DT.Layout.panelWidth, height: DT.Layout.panelHeight)

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

        // Position below the status bar icon, clamped to screen bounds
        if let button = statusBarController?.statusItem?.button, let bw = button.window, let panel = panelWindow {
            let f = bw.frame
            var origin = NSPoint(x: f.midX - panel.frame.width / 2, y: f.minY - panel.frame.height - 5)

            if let screen = NSScreen.main?.visibleFrame {
                origin.x = max(screen.minX, min(origin.x, screen.maxX - panel.frame.width))
                origin.y = max(screen.minY, min(origin.y, screen.maxY - panel.frame.height))
            }

            panel.setFrameOrigin(origin)
        }
        panelWindow?.alphaValue = 0
        panelWindow?.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.panelWindow?.animator().alphaValue = 1
        }
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
            window.setContentSize(NSSize(width: DT.Layout.onboardingWidth, height: DT.Layout.onboardingHeight))
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
            window.setContentSize(NSSize(width: DT.Layout.settingsWidth, height: DT.Layout.settingsHeight))
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
