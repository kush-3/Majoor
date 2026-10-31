// TailscaleInterface.swift
// Majoor — Finds the Tailscale address to bind the control API to
//
// The control API must never listen on anything but the Tailscale
// interface (PRD §5.7 T9). Tailscale appears as a utun interface with an
// address in 100.64.0.0/10. Without one, the server stays off; nothing
// ever falls back to a wider bind.

import Foundation
import Network

nonisolated enum TailscaleInterface {

    /// True for IPv4 addresses inside 100.64.0.0/10 (the CGNAT range Tailscale uses).
    static func isTailscaleAddress(_ text: String) -> Bool {
        var addr = in_addr()
        guard inet_pton(AF_INET, text, &addr) == 1 else { return false }
        let bytes = withUnsafeBytes(of: addr) { Array($0) }
        return bytes[0] == 100 && (bytes[1] & 0xC0) == 64
    }

    /// The first up utun interface with a Tailscale address, or nil.
    static func currentIPv4() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(first) }
        var node: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = node {
            defer { node = ifa.pointee.ifa_next }
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            guard (Int32(ifa.pointee.ifa_flags) & IFF_UP) != 0 else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            guard name.hasPrefix("utun") else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(MemoryLayout<sockaddr_in>.size), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = buffer.withUnsafeBufferPointer { $0.baseAddress.map { String(cString: $0) } } ?? ""
            if isTailscaleAddress(text) { return text }
        }
        return nil
    }

    /// Yields the current address whenever it changes (including to nil):
    /// on every network path change and at least every `interval`.
    static func changes(interval: Duration = .seconds(30)) -> AsyncStream<String?> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "ai.majoor.tailscale-monitor")
            let last = LockedValue<String??>(.none)
            @Sendable func check() {
                let now = currentIPv4()
                let changed = last.withValue { stored -> Bool in
                    if case .some(let previous) = stored, previous == now { return false }
                    stored = .some(now)
                    return true
                }
                if changed { continuation.yield(now) }
            }
            monitor.pathUpdateHandler = { _ in check() }
            monitor.start(queue: queue)
            let ticker = Task {
                check()
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    check()
                }
            }
            continuation.onTermination = { @Sendable _ in
                monitor.cancel()
                ticker.cancel()
            }
        }
    }
}

/// A tiny lock-protected box for values shared with GCD callbacks.
nonisolated final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withValue<R>(_ body: (inout Value) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}
