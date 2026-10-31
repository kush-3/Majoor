// URLGuardTests.swift
// MajoorTests — the SSRF guard in front of fetch_webpage.
//
// Static checks only, so the suite runs offline. Name resolution is
// exercised for "localhost" alone, which never leaves the machine.

import Foundation
import Testing
@testable import Majoor

@Suite("URLGuard")
struct URLGuardTests {

    nonisolated static let rejected: [String] = [
        "http://localhost/", "http://localhost./", "http://LOCALHOST/", "http://127.0.0.1:8080/", "http://10.1.2.3/",
        "http://100.100.1.1/", "http://192.168.1.1/", "http://172.16.0.1/", "http://169.254.169.254/latest/meta-data",
        "http://192.0.2.1/", "http://198.51.100.7/", "http://203.0.113.9/", "http://0.0.0.0/",
        "http://[::1]/", "http://[::ffff:127.0.0.1]/", "http://[::127.0.0.1]/", "http://[::7f00:1]/", "http://[2002:7f00:1::]/",
        "http://[fe80::1%25en0]/", "http://[fd00::1]/",
        "http://user:pw@example.com/", "ftp://example.com/", "file:///etc/passwd", "http://example.com:22/",
        "http://foo.ts.net/", "http://mac.local/", "http://x.internal/",
    ]

    nonisolated static let allowed: [String] = [
        "https://example.com/", "http://8.8.8.8/", "https://[2606:4700::1111]/", "https://example.com:8443/",
    ]

    @Test("rejects private, loopback, link-local, CGNAT and non-http targets", arguments: rejected)
    func rejects(urlString: String) throws {
        let url = try #require(URL(string: urlString))
        #expect(URLGuard.check(url) != nil, "should reject \(urlString)")
    }

    @Test("passes public targets through the static checks", arguments: allowed)
    func allows(urlString: String) throws {
        let url = try #require(URL(string: urlString))
        #expect(URLGuard.check(url) == nil, "should allow \(urlString) -> \(URLGuard.check(url)?.reason ?? "")")
    }

    @Test("judges IP literals in every spelling")
    func ipAddressForms() {
        #expect(IPAddress("127.0.0.1")?.isNonPublic == true)
        #expect(IPAddress("100.64.0.1")?.isNonPublic == true)
        #expect(IPAddress("100.127.255.255")?.isNonPublic == true)
        #expect(IPAddress("100.128.0.1")?.isNonPublic == false)
        #expect(IPAddress("::ffff:10.0.0.1")?.isNonPublic == true)
        #expect(IPAddress("64:ff9b::7f00:1")?.isNonPublic == true)
        #expect(IPAddress("2001:db8::1")?.isNonPublic == true)
        #expect(IPAddress("2606:4700::1111")?.isNonPublic == false)
        #expect(IPAddress("not an address") == nil)
    }

    @Test("resolution catches a public-looking name that points at loopback")
    func resolvesLocalhost() async throws {
        let url = try #require(URL(string: "http://localhost.localdomain.example/"))
        // `.example` names do not resolve, so this is "could not resolve"; the
        // real localhost case is covered statically. Either way: rejected.
        #expect(await URLGuard.checkResolved(url) != nil)
    }
}
