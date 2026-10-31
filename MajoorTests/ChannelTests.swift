// ChannelTests.swift
// MajoorTests — Phase 1 step 3: trust policy, approval replies, channel router.

import Foundation
import Testing
@testable import Majoor

/// A channel the test drives by hand and whose outbound text it can read.
nonisolated final class FakeChannel: Channel, @unchecked Sendable {
    let id: String
    let trust: ChannelTrust
    private let stream: AsyncStream<InboundMessage>
    private let continuation: AsyncStream<InboundMessage>.Continuation
    private let lock = NSLock()
    private var outbound: [(thread: String, text: String)] = []

    init(id: String, trust: ChannelTrust) {
        self.id = id
        self.trust = trust
        (stream, continuation) = AsyncStream.makeStream(of: InboundMessage.self)
    }

    var inbound: AsyncStream<InboundMessage> { stream }

    func receive(_ text: String, from sender: String, thread: String = "t1") {
        continuation.yield(InboundMessage(channelId: id, threadKey: thread, sender: sender, text: text))
    }

    func send(to threadKey: String, text: String, attachments: [URL]) async throws {
        lock.withLock { outbound.append((threadKey, text)) }
    }

    var sent: [String] { lock.withLock { outbound.map(\.text) } }
}

@Suite("TrustPolicy")
struct TrustPolicyTests {

    @Test("handles normalize to one spelling", arguments: [
        ("(555) 123-4567", "+15551234567"), ("555.123.4567", "+15551234567"), ("+1 555 123 4567", "+15551234567"),
        ("15551234567", "+15551234567"), ("+44 20 7946 0958", "+442079460958"), ("Kush@Example.COM ", "kush@example.com"),
        ("someone", "someone"),
    ] as [(String, String)])
    func normalize(input: String, expected: String) {
        #expect(TrustPolicy.normalize(handle: input) == expected)
    }

    @Test("local UI and paired clients are the owner; remote text must match a configured handle")
    func ownership() {
        let owners = ["+1 (555) 123-4567", "Kush@Example.com"]
        #expect(TrustPolicy.isOwner(sender: "", trust: .local, owners: []))
        #expect(TrustPolicy.isOwner(sender: "anything", trust: .authenticatedClient, owners: []))
        #expect(TrustPolicy.isOwner(sender: "5551234567", trust: .remoteText, owners: owners))
        #expect(TrustPolicy.isOwner(sender: "kush@example.com", trust: .remoteText, owners: owners))
        #expect(!TrustPolicy.isOwner(sender: "+15559999999", trust: .remoteText, owners: owners))
        #expect(!TrustPolicy.isOwner(sender: "", trust: .remoteText, owners: owners))
        #expect(!TrustPolicy.isOwner(sender: "kush@example.com", trust: .remoteText, owners: []))
    }

    @Test("the owner store round-trips normalized handles")
    func store() throws {
        let path = NSTemporaryDirectory() + "majoor-trust-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = ContactPolicyStore(db: try DatabaseManager.openAndMigrate(path: path))
        store.setTrust(handle: "(555) 123-4567", trust: ContactPolicyStore.ownerTrust)
        store.setTrust(handle: "Friend@Example.com", trust: "vip", isVIP: true)
        #expect(store.owners() == ["+15551234567"])
        #expect(store.all().count == 2)
        store.setTrust(handle: "+1 555 123 4567", trust: "none")
        #expect(store.owners().isEmpty)
        store.remove(handle: "friend@example.com")
        #expect(store.all().count == 1)
    }
}

@Suite("ApprovalReply")
struct ApprovalReplyTests {

    @Test("recognizes yes/no with a code and optional feedback")
    func parse() {
        #expect(ApprovalReply.parse("yes K7Q2") == .init(approved: true, nonce: "K7Q2", feedback: nil))
        #expect(ApprovalReply.parse("  NO k7q2 not today ") == .init(approved: false, nonce: "K7Q2", feedback: "not today"))
        #expect(ApprovalReply.parse("approve AB12\nchange the subject") == .init(approved: true, nonce: "AB12", feedback: "change the subject"))
        #expect(ApprovalReply.parse("ok 1234") == .init(approved: true, nonce: "1234", feedback: nil))
        #expect(ApprovalReply.parse("deny ZZZZ") == .init(approved: false, nonce: "ZZZZ", feedback: nil))
    }

    @Test("a bare yes, a wrong-length code, or ordinary text is not a reply", arguments: [
        "yes", "no", "yes please", "yes K7Q", "yes K7Q2X", "send yes K7Q2 to bob", "K7Q2", "yes, K7Q2",
    ])
    func rejects(text: String) {
        #expect(ApprovalReply.parse(text) == nil)
    }
}

@Suite("ChannelRouter", .serialized)
struct ChannelRouterTests {

    @Test("a non-owner on a remote channel never reaches the session manager")
    func nonOwnerIgnored() async throws {
        try await withPermissionMode(.standard) {
            let provider = ScriptedProvider([.text("done")])
            let manager = await makeManager(route: { _ in (provider, []) })
            let router = ChannelRouter()
            await router.configure(manager: manager, owners: { ["+15551234567"] })
            let channel = FakeChannel(id: "imessage", trust: .remoteText)
            await router.register(channel)
            channel.receive("delete everything", from: "+15559999999")
            channel.receive("/status", from: "+15559999999")
            try await Task.sleep(for: .milliseconds(300))
            #expect(await manager.list().isEmpty)
            #expect(channel.sent.isEmpty)
            await router.unregister("imessage")
        }
    }

    @Test("the owner gets status, an acknowledgement, and the result on a remote channel")
    func ownerRoundTrip() async throws {
        try await withPermissionMode(.standard) {
            let provider = ScriptedProvider([.text("Three files on the desk. More detail.")])
            let manager = await makeManager(route: { _ in (provider, []) })
            let router = ChannelRouter()
            await router.configure(manager: manager, owners: { ["kush@example.com"] })
            let channel = FakeChannel(id: "imessage", trust: .remoteText)
            await router.register(channel)

            channel.receive("/status", from: "Kush@Example.com")
            #expect(await waitUntil { channel.sent.contains("Nothing running.") })

            channel.receive("what's on my desk", from: "kush@example.com")
            #expect(await waitUntil { channel.sent.contains { $0.hasPrefix("On it (session") } })
            #expect(await waitUntil { channel.sent.contains("Three files on the desk") })
            let session = try #require(await manager.list().first)
            #expect(session.origin == ChannelRef(channelId: "imessage", threadKey: "t1"))
            await router.unregister("imessage")
        }
    }

    @Test("approval prompts go to the remote thread and a coded reply answers them")
    func remoteApproval() async throws {
        try await withPermissionMode(.standard) {
            let provider = ScriptedProvider([echoCall("x"), .text("Sent, as requested")])
            let manager = await makeManager(route: { _ in (provider, []) }, tool: EchoTool(requiresConfirmation: true))
            let router = ChannelRouter()
            await router.configure(manager: manager, owners: { ["+15551234567"] })
            let channel = FakeChannel(id: "imessage", trust: .remoteText)
            await router.register(channel)

            channel.receive("echo x", from: "+1 (555) 123-4567")
            #expect(await waitUntil { channel.sent.contains { $0.hasPrefix("Approval needed:") } }, "sent so far: \(channel.sent)")
            let request = try #require(await manager.pendingApprovals().first)
            let prompt = try #require(channel.sent.first { $0.hasPrefix("Approval needed:") })
            #expect(prompt.contains("yes \(request.nonce)"))

            channel.receive("yes", from: "+15551234567")          // bare yes: a task, not an approval
            channel.receive("yes ZZZZ", from: "+15551234567")     // wrong code
            #expect(await waitUntil { channel.sent.contains { $0.hasPrefix("That code does not match") } }, "sent so far: \(channel.sent)")
            #expect(await manager.pendingApprovals().count == 1)

            channel.receive("yes \(request.nonce.lowercased()) go ahead", from: "+15551234567")
            #expect(await waitUntil { channel.sent.contains("Approved.") }, "sent so far: \(channel.sent)")
            #expect(await waitUntil { channel.sent.contains("Sent, as requested") }, "sent so far: \(channel.sent)")
            await router.unregister("imessage")
        }
    }

    @Test("the panel channel feeds the router and reports through toasts")
    func panelChannel() async throws {
        try await withPermissionMode(.standard) {
            let provider = ScriptedProvider([.text("ok")])
            let manager = await makeManager(route: { _ in (provider, []) })
            let router = ChannelRouter()
            await router.configure(manager: manager, owners: { [] })
            let taskManager = TaskManager()
            let panel = PanelChannel(taskManager: taskManager)
            await router.register(panel)
            panel.submit("/status")
            #expect(await waitUntil { await MainActor.run { taskManager.toasts.contains { $0.body == "Nothing running." } } })
            panel.submit("do a thing")
            #expect(await waitUntil { await manager.list().count == 1 })
            #expect(await manager.list().first?.origin == .panel)
            await router.unregister("panel")
        }
    }
}
