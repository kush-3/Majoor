// WebSocketPeer.swift
// Majoor — One WebSocket connection, server- or client-side
//
// Wraps an NWConnection carrying NWProtocolWebSocket into an async
// receive stream plus send/close. Network.framework handles the HTTP
// upgrade, framing, masking and ping replies; this adds the Swift
// concurrency surface the control server and client code use.

import Foundation
import Network

nonisolated enum WebSocketError: Error, Sendable {
    case notReady(String)
    case closed
    case sendFailed(String)
    case timeout
}

nonisolated final class WebSocketPeer: @unchecked Sendable {

    let connection: NWConnection
    private let queue: DispatchQueue
    private let started = LockedValue(false)

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// Parameters shared by the listener and client connections.
    static func parameters(maximumMessageSize: Int = ControlProtocol.maximumFrameBytes) -> NWParameters {
        let parameters = NWParameters.tcp
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.maximumMessageSize = maximumMessageSize
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        return parameters
    }

    /// A URL endpoint makes Network.framework perform the HTTP upgrade; a bare
    /// host-and-port endpoint does not.
    static func client(host: String, port: UInt16, queue: DispatchQueue) -> WebSocketPeer {
        let bracketed = host.contains(":") ? "[\(host)]" : host
        let url = URL(string: "ws://\(bracketed):\(port)/")!
        return WebSocketPeer(connection: NWConnection(to: .url(url), using: parameters()), queue: queue)
    }

    var remoteDescription: String {
        if case .hostPort(let host, _) = connection.endpoint { return "\(host)" }
        return "\(connection.endpoint)"
    }

    /// Starts the connection and waits until it is ready (or fails).
    func start(timeout: Duration = .seconds(10)) async throws {
        guard started.withValue({ value -> Bool in let was = value; value = true; return !was }) else { return }
        let ready = LockedValue(false)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    self.connection.stateUpdateHandler = { state in
                        let fire = ready.withValue { done -> Bool in
                            if done { return false }
                            switch state {
                            case .ready, .failed, .cancelled: done = true; return true
                            default: return false
                            }
                        }
                        guard fire else { return }
                        switch state {
                        case .ready: continuation.resume()
                        case .failed(let error): continuation.resume(throwing: WebSocketError.notReady("\(error)"))
                        case .cancelled: continuation.resume(throwing: WebSocketError.closed)
                        default: break
                        }
                    }
                    self.connection.start(queue: self.queue)
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw WebSocketError.timeout
            }
            try await group.next()
            group.cancelAll()
        }
    }

    /// Every complete message as raw bytes (text frames arrive as UTF-8).
    var incoming: AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            @Sendable func receiveNext() {
                self.connection.receiveMessage { data, context, _, error in
                    if let error {
                        continuation.finish(throwing: error)
                        return
                    }
                    if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
                       metadata.opcode == .close {
                        continuation.finish()
                        return
                    }
                    if let data, !data.isEmpty {
                        continuation.yield(data)
                    } else if context?.isFinal == true {
                        continuation.finish()
                        return
                    }
                    receiveNext()
                }
            }
            receiveNext()
            continuation.onTermination = { @Sendable _ in }
        }
    }

    func send(text: String) async throws {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: WebSocketError.sendFailed("\(error)")) } else { continuation.resume() }
            })
        }
    }

    func send(frame: ControlFrame) async throws {
        let data = try frame.encoded()
        guard let text = String(data: data, encoding: .utf8) else { throw WebSocketError.sendFailed("non-UTF-8 frame") }
        try await send(text: text)
    }

    /// Sends a close frame, then cancels the connection.
    func close(code: NWProtocolWebSocket.CloseCode = .protocolCode(.normalClosure)) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = code
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        let connection = self.connection
        connection.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
