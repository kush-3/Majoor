// URLGuard.swift
// Majoor — Outbound URL Safety (SSRF guard)
//
// fetch_webpage fetches model-chosen URLs. Without this, a prompt-injected or
// hallucinated URL could reach localhost services, the Tailscale network,
// link-local metadata endpoints, or anything else the Mac can see but the
// internet cannot, and the response would come back as "page content" that
// the model then trusts. Every fetched URL and every redirect target passes
// through here: scheme, credentials, host name, IP literal, port, and the
// resolved addresses (so a public name that resolves to 127.0.0.1 is refused).
//
// Residual: DNS rebinding between this check and URLSession's own resolution
// is not covered; pinning the resolved IP would break TLS name validation.

import Foundation

nonisolated enum URLGuard {

    nonisolated struct Rejection: Sendable {
        let reason: String
    }

    private static let blockedHosts: Set<String> = ["localhost", "0.0.0.0", "broadcasthost", "metadata.google.internal"]
    private static let blockedHostSuffixes = [".localhost", ".local", ".internal", ".ts.net", ".home.arpa", ".lan", ".localdomain"]
    private static let allowedPorts: Set<Int> = [80, 443, 8080, 8443]

    /// Static checks: scheme, embedded credentials, host, IP literal, port.
    static func check(_ url: URL) -> Rejection? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return Rejection(reason: "only http and https URLs can be fetched")
        }
        if url.user != nil || url.password != nil {
            return Rejection(reason: "URLs with embedded credentials are not allowed")
        }
        guard let rawHost = url.host, !rawHost.isEmpty else {
            return Rejection(reason: "URL has no host")
        }
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        if blockedHosts.contains(host) || blockedHostSuffixes.contains(where: { host.hasSuffix($0) }) {
            return Rejection(reason: "host '\(host)' is not reachable through fetch_webpage")
        }
        if let ip = IPAddress(host), ip.isNonPublic {
            return Rejection(reason: "address \(host) is not public")
        }
        if let port = url.port, !allowedPorts.contains(port) {
            return Rejection(reason: "port \(port) is not allowed")
        }
        return nil
    }

    /// Static checks plus DNS resolution: refuses the URL if ANY resolved
    /// address is non-public (split-horizon DNS, rebinding, internal names).
    static func checkResolved(_ url: URL) async -> Rejection? {
        if let rejection = check(url) { return rejection }
        guard let host = url.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) else {
            return Rejection(reason: "URL has no host")
        }
        if IPAddress(host) != nil { return nil }   // literal, already judged
        let addresses = await resolve(host)
        if addresses.isEmpty {
            return Rejection(reason: "could not resolve host '\(host)'")
        }
        if let bad = addresses.first(where: { $0.isNonPublic }) {
            return Rejection(reason: "host '\(host)' resolves to a non-public address (\(bad.text))")
        }
        return nil
    }

    /// getaddrinfo on a GCD queue: it blocks, and the cooperative pool must not.
    private static func resolve(_ host: String) async -> [IPAddress] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var hints = addrinfo()
                hints.ai_socktype = SOCK_STREAM
                var list: UnsafeMutablePointer<addrinfo>? = nil
                guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else {
                    continuation.resume(returning: [])
                    return
                }
                defer { freeaddrinfo(first) }
                var out: [IPAddress] = []
                var node: UnsafeMutablePointer<addrinfo>? = first
                while let ai = node {
                    if let addr = ai.pointee.ai_addr {
                        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        if getnameinfo(addr, ai.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0,
                           let text = buffer.withUnsafeBufferPointer({ $0.baseAddress.map { String(cString: $0) } }),
                           let ip = IPAddress(text) {
                            out.append(ip)
                        }
                    }
                    node = ai.pointee.ai_next
                }
                continuation.resume(returning: out)
            }
        }
    }
}

/// A parsed IPv4/IPv6 literal with a "could this be something only this
/// machine can reach" test. IPv4-mapped and NAT64 IPv6 forms are judged by
/// their embedded IPv4 address.
nonisolated struct IPAddress: Sendable {
    let text: String
    private let v4: [UInt8]?    // 4 bytes, network order
    private let v6: [UInt8]?    // 16 bytes

    init?(_ literal: String) {
        var text = literal
        if let zone = text.firstIndex(of: "%") { text = String(text[..<zone]) }   // fe80::1%en0
        var a4 = in_addr()
        if inet_pton(AF_INET, text, &a4) == 1 {
            self.text = text
            self.v4 = withUnsafeBytes(of: a4) { Array($0) }
            self.v6 = nil
            return
        }
        var a6 = in6_addr()
        if inet_pton(AF_INET6, text, &a6) == 1 {
            let bytes = withUnsafeBytes(of: a6) { Array($0) }
            self.text = text
            let mappedPrefix: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff]
            let compatPrefix: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]          // deprecated ::a.b.c.d (also covers :: and ::1)
            let nat64Prefix: [UInt8] = [0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0]
            let head = Array(bytes[0..<12])
            if head == mappedPrefix || head == compatPrefix || head == nat64Prefix {
                self.v4 = Array(bytes[12..<16])
                self.v6 = nil
            } else if bytes[0] == 0x20 && bytes[1] == 0x02 {                              // 6to4: 2002:AABB:CCDD::/48 embeds A.B.C.D
                self.v4 = Array(bytes[2..<6])
                self.v6 = nil
            } else {
                self.v4 = nil
                self.v6 = bytes
            }
            return
        }
        return nil
    }

    var isNonPublic: Bool {
        if let b = v4 {
            let (a, c) = (b[0], b[1])
            if a == 0 || a == 10 || a == 127 { return true }           // this-net, private, loopback
            if a == 100 && (c & 0xC0) == 64 { return true }             // 100.64/10 CGNAT — Tailscale lives here
            if a == 169 && c == 254 { return true }                      // link-local, cloud metadata
            if a == 172 && (c & 0xF0) == 16 { return true }             // 172.16/12
            if a == 192 && c == 168 { return true }                      // 192.168/16
            if a == 192 && c == 0 && (b[2] == 0 || b[2] == 2) { return true }   // 192.0.0/24, TEST-NET-1
            if a == 198 && (c == 18 || c == 19) { return true }          // benchmarking
            if a == 198 && c == 51 && b[2] == 100 { return true }        // TEST-NET-2
            if a == 203 && c == 0 && b[2] == 113 { return true }         // TEST-NET-3
            if a >= 224 { return true }                                  // multicast, reserved, broadcast
            return false
        }
        if let b = v6 {
            if b.allSatisfy({ $0 == 0 }) { return true }                                 // ::
            if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }           // ::1
            if (b[0] & 0xFE) == 0xFC { return true }                                     // fc00::/7 unique local
            if b[0] == 0xFE && (b[1] & 0xC0) == 0x80 { return true }                     // fe80::/10 link-local
            if b[0] == 0xFF { return true }                                              // multicast
            if b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8 { return true } // documentation
            return false
        }
        return true
    }
}
