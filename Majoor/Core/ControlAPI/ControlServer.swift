// ControlServer.swift
// Majoor — The WebSocket listener for paired clients
//
// Listens only on the Tailscale address (PRD §5.7 T9). When Tailscale is
// absent the server waits; when the address changes the listener is
// rebuilt; nothing ever binds to all interfaces. DEBUG builds can bind to
// 127.0.0.1 so client mode can be exercised on one Mac.

import Foundation
import Network

actor ControlServer {

    static let shared = ControlServer()

    static let enabledKey = "controlAPIEnabled"
    static let portKey = "controlPort"
    static let loopbackKey = "controlAPILoopback"
    static let runtimeIdKey = "runtimeId"
    static let maxConnections = 4

    nonisolated enum State: Sendable, Equatable {
        case stopped
        case waitingForTailscale
        case listening(address: String, port: UInt16)
        case failed(String)

        var isListening: Bool {
            if case .listening = self { return true }
            return false
        }
    }

    private let queue = DispatchQueue(label: "ai.majoor.control")
    private var gateway: (any SessionGateway)?
    private var pairing: PairingManager?
    private var bus: EventBus?
    private var runtime: ControlRuntimeInfo?

    private var listener: NWListener?
    private var listenerAddress: String?
    private var listenerPort: UInt16 = ControlProtocol.defaultPort
    private var connections: [UUID: ControlConnection] = [:]
    private var watcher: Task<Void, Never>?
    private var stateSubscribers: [UUID: AsyncStream<State>.Continuation] = [:]
    private var connectAttempts: [String: [Date]] = [:]

    private(set) var state: State = .stopped {
        didSet {
            guard state != oldValue else { return }
            for continuation in stateSubscribers.values { continuation.yield(state) }
        }
    }

    init() {}

    // MARK: Configuration

    func configure(gateway: any SessionGateway, pairing: PairingManager, bus: EventBus, runtime: ControlRuntimeInfo) {
        self.gateway = gateway
        self.pairing = pairing
        self.bus = bus
        self.runtime = runtime
    }

    static var configuredPort: UInt16 {
        let stored = UserDefaults.standard.integer(forKey: portKey)
        return (1024...65535).contains(stored) ? UInt16(stored) : ControlProtocol.defaultPort
    }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    static var runtimeId: String {
        if let existing = UserDefaults.standard.string(forKey: runtimeIdKey), !existing.isEmpty { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: runtimeIdKey)
        return fresh
    }

    /// Where to bind: a fixed loopback address in DEBUG when the developer
    /// switch is on, otherwise the live Tailscale address stream.
    private static var loopbackForDevelopment: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: loopbackKey)
        #else
        return false
        #endif
    }

    func stateStream() -> AsyncStream<State> {
        let id = UUID()
        let current = state
        return AsyncStream { continuation in
            continuation.yield(current)
            stateSubscribers[id] = continuation
            continuation.onTermination = { @Sendable _ in
                Task { await self.removeStateSubscriber(id) }
            }
        }
    }

    private func removeStateSubscriber(_ id: UUID) {
        stateSubscribers[id] = nil
    }

    var connectionCount: Int { connections.count }

    // MARK: Lifecycle

    func start() {
        guard watcher == nil, gateway != nil else { return }
        listenerPort = Self.configuredPort
        if Self.loopbackForDevelopment {
            watcher = Task { self.addressChanged("127.0.0.1") }
            return
        }
        watcher = Task { [weak self] in
            for await address in TailscaleInterface.changes() {
                await self?.addressChanged(address)
            }
        }
    }

    /// Binds to an explicit address and port right away. Tests use it with
    /// 127.0.0.1 and port 0 (ephemeral).
    func start(address: String, port: UInt16) async {
        guard gateway != nil else { return }
        watcher?.cancel()
        watcher = Task {}
        listenerPort = port
        tearDownListener()
        listenerAddress = address
        startListener(on: address)
    }

    func stop() async {
        watcher?.cancel()
        watcher = nil
        tearDownListener()
        for connection in connections.values { await connection.sendBye("Runtime control API stopping") }
        connections.removeAll()
        state = .stopped
    }

    func restartIfEnabled() async {
        guard Self.isEnabled else { return }
        await stop()
        start()
    }

    private func addressChanged(_ address: String?) {
        if address == listenerAddress, listener != nil { return }
        tearDownListener()
        listenerAddress = address
        guard let address else {
            state = .waitingForTailscale
            return
        }
        startListener(on: address)
    }

    private func startListener(on address: String) {
        let parameters = WebSocketPeer.parameters()
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(address), port: NWEndpoint.Port(rawValue: listenerPort) ?? .any)
        do {
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] listenerState in
                Task { await self?.listenerStateChanged(listenerState, address: address) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { await self?.accept(connection) }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            state = .failed("Could not create listener: \(error)")
            MajoorLogger.error("Control API listener failed: \(error)")
        }
    }

    private func listenerStateChanged(_ listenerState: NWListener.State, address: String) {
        switch listenerState {
        case .ready:
            if let actual = listener?.port?.rawValue { listenerPort = actual }
            state = .listening(address: address, port: listenerPort)
            MajoorLogger.log("🌐 Control API listening on \(address):\(listenerPort)")
        case .failed(let error):
            state = .failed("\(error)")
            MajoorLogger.error("Control API listener failed: \(error)")
            tearDownListener()
        case .waiting(let error):
            // The address is not bindable right now (interface down, port busy).
            // The listener keeps trying; report it rather than looking stopped.
            state = .failed("Waiting to bind \(address):\(listenerPort): \(error)")
            MajoorLogger.log("Control API listener waiting: \(error)")
        case .cancelled:
            if case .listening = state { state = .stopped }
        case .setup:
            break
        @unknown default:
            break
        }
    }

    private func tearDownListener() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) async {
        guard let gateway, let pairing, let bus, let runtime else { connection.cancel(); return }
        let remote: String
        if case .hostPort(let host, _) = connection.endpoint { remote = "\(host)" } else { remote = "?" }
        let now = Date()
        var attempts = (connectAttempts[remote] ?? []).filter { now.timeIntervalSince($0) < 60 }
        attempts.append(now)
        connectAttempts[remote] = attempts
        guard attempts.count <= 10 else {
            MajoorLogger.log("Control API: rate-limited \(remote)")
            connection.cancel()
            return
        }
        guard connections.count < Self.maxConnections else {
            MajoorLogger.log("Control API: refusing \(remote), connection limit reached")
            connection.cancel()
            return
        }
        let peer = WebSocketPeer(connection: connection, queue: queue)
        let control = ControlConnection(peer: peer, gateway: gateway, pairing: pairing, bus: bus, runtime: runtime,
                                        onClose: { [weak self] id in Task { await self?.connectionClosed(id) } })
        connections[control.id] = control
        await control.start()
    }

    private func connectionClosed(_ id: UUID) {
        connections[id] = nil
    }

    // MARK: Pairing (for Settings)

    func mintPairingCode() async -> PairingManager.PendingCode? {
        await pairing?.mintCode()
    }

    func currentPairingCode() async -> PairingManager.PendingCode? {
        await pairing?.currentCode()
    }

    func pairedClients() async -> [PairedClientRecord] {
        await pairing?.clients() ?? []
    }

    func revoke(clientId: String) async {
        await pairing?.revoke(clientId: clientId)
        for connection in connections.values where await connection.clientId == clientId {
            await connection.sendBye("This device was revoked")
        }
    }
}
