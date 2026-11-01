// EscalationLadderTests.swift
// MajoorTests — Phase 2 step 5c: the escalation ladder with a fake clock and
// a fake channel.

import Foundation
import Testing
@testable import Majoor

nonisolated final class SendBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(ref: ChannelRef, text: String)] = []
    private var failuresLeft = 0
    private var fallbacks: [(title: String, body: String)] = []

    var sent: [(ref: ChannelRef, text: String)] { lock.withLock { items } }
    var texts: [String] { lock.withLock { items.map(\.text) } }
    var fallbackBodies: [String] { lock.withLock { fallbacks.map(\.body) } }
    var fallbackTitles: [String] { lock.withLock { fallbacks.map(\.title) } }

    func failNext(_ count: Int) { lock.withLock { failuresLeft = count } }

    func send(_ ref: ChannelRef, _ text: String) throws {
        let fail = lock.withLock { () -> Bool in
            if failuresLeft > 0 { failuresLeft -= 1; return true }
            items.append((ref, text))
            return false
        }
        if fail { throw GatewayError.unavailable }
    }

    func fallback(_ title: String, _ body: String) { lock.withLock { fallbacks.append((title, body)) } }
}

private struct LadderHarness {
    let store: EscalationStore
    let ladder: EscalationLadder
    let clock: FakeSchedulerClock
    let box: SendBox
    let thread = ChannelRef(channelId: "imessage", threadKey: "imessage:+15551234567")
    let hours = ActiveHours.parse("08:00-23:00")!

    static func make(at text: String = "2026-11-03 10:00") async throws -> LadderHarness {
        let path = NSTemporaryDirectory() + "majoor-ladder-\(UUID().uuidString).sqlite"
        let store = EscalationStore(db: try DatabaseManager.openAndMigrate(path: path))
        let clock = FakeSchedulerClock(localDate(text))
        let box = SendBox()
        let ladder = EscalationLadder()
        await ladder.configure(store: store, clock: clock, timeZone: newYork,
                               send: { ref, text in try box.send(ref, text) },
                               fallback: { title, body in box.fallback(title, body) })
        return LadderHarness(store: store, ladder: ladder, clock: clock, box: box)
    }

    func escalate(_ urgency: Int, _ text: String = "Prod is down", automation: String = "auto-1", job: String = "triage") async -> EscalationLadder.Outcome {
        await ladder.escalate(automationId: automation, jobName: job, urgency: urgency, text: text, delivery: thread, activeHours: hours)
    }
}

@Suite("EscalationLadder", .serialized)
struct EscalationLadderTests {

    @Test("urgency 1 is logged and resolved; nothing is sent")
    func urgencyOne() async throws {
        let h = try await LadderHarness.make()
        #expect(await h.escalate(1) == .logged)
        #expect(h.box.sent.isEmpty)
        #expect(await h.ladder.pendingCount == 0)
        let records = h.store.recent()
        #expect(records.count == 1)
        #expect(records[0].rung == 1)
        #expect(records[0].resolvedAt != nil)
    }

    @Test("urgency 2 inside active hours is sent once, with no repeat")
    func urgencyTwoInside() async throws {
        let h = try await LadderHarness.make()
        #expect(await h.escalate(2) == .sent(rung: 2))
        #expect(h.box.texts == ["Prod is down"])
        #expect(h.box.sent.first?.ref == h.thread)
        let record = try #require(h.store.recent().first)
        #expect(record.rung == 2)
        #expect(record.sentAt == h.clock.now())
        #expect(record.repeatAt == nil)
        #expect(record.resolvedAt != nil)
        h.clock.advance(3 * 3600)
        await h.ladder.tick()
        #expect(h.box.texts.count == 1)
        #expect(await h.ladder.sentCount == 1)
    }

    @Test("urgency 2 outside active hours waits for the next opening")
    func urgencyTwoDeferred() async throws {
        let h = try await LadderHarness.make(at: "2026-11-03 23:30")
        let outcome = await h.escalate(2, "Lease form due")
        #expect(outcome == .deferred(until: localDate("2026-11-04 08:00")))
        #expect(h.box.sent.isEmpty)
        #expect(await h.ladder.pendingCount == 1)
        h.clock.advance(8 * 3600 + 29 * 60)             // 07:59
        await h.ladder.tick()
        #expect(h.box.sent.isEmpty)
        h.clock.advance(60)                              // 08:00
        await h.ladder.tick()
        #expect(h.box.texts == ["Lease form due"])
        let record = try #require(h.store.recent().first)
        #expect(record.rung == 2)
        #expect(record.deferredUntil == nil)
        #expect(record.resolvedAt != nil)
        #expect(await h.ladder.pendingCount == 0)
    }

    @Test("urgency 3 ignores active hours, repeats after 30 minutes, then reaches the call rung")
    func urgencyThree() async throws {
        let h = try await LadderHarness.make(at: "2026-11-03 23:30")
        #expect(await h.escalate(3, "Dad is in the ER") == .sent(rung: 2))
        #expect(h.box.texts == ["Dad is in the ER"])
        var record = try #require(h.store.recent().first)
        #expect(record.repeatAt == h.clock.now().addingTimeInterval(EscalationLadder.repeatAfter))

        h.clock.advance(29 * 60)
        await h.ladder.tick()
        #expect(h.box.texts.count == 1)

        h.clock.advance(60)
        await h.ladder.tick()
        #expect(h.box.texts == ["Dad is in the ER", "(Still waiting on this) Dad is in the ER"])
        record = try #require(h.store.recent().first)
        #expect(record.rung == 3)
        #expect(record.resolvedAt == nil)

        h.clock.advance(30 * 60)
        await h.ladder.tick()
        #expect(h.box.texts.count == 2)                  // the call rung sends no text
        record = try #require(h.store.recent().first)
        #expect(record.rung == EscalationLadder.callRung)
        #expect(record.resolvedAt != nil)
        #expect(await h.ladder.callCount == 1)
        #expect(await h.ladder.pendingCount == 0)
    }

    @Test("any owner reply acknowledges; the exact reply ok is consumed")
    func acknowledgement() async throws {
        let h = try await LadderHarness.make()
        #expect(await h.escalate(3) == .sent(rung: 2))
        #expect(await h.ladder.acknowledge(threadKey: "imessage:+10000000000", text: "ok", at: h.clock.now()) == false)   // other thread
        #expect(await h.ladder.pendingCount == 1)
        #expect(await h.ladder.acknowledge(threadKey: h.thread.threadKey, text: "thanks, on it", at: h.clock.now()) == false)
        #expect(await h.ladder.pendingCount == 0)
        h.clock.advance(31 * 60)
        await h.ladder.tick()
        #expect(h.box.texts.count == 1)
        let record = try #require(h.store.recent().first)
        #expect(record.acknowledgedAt != nil)
        #expect(record.repeatAt == nil)

        #expect(await h.escalate(3, "Again") == .sent(rung: 2))
        #expect(await h.ladder.acknowledge(threadKey: h.thread.threadKey, text: "  OK\n", at: h.clock.now()) == true)
        #expect(await h.ladder.acknowledge(threadKey: h.thread.threadKey, text: "ok", at: h.clock.now()) == false)   // nothing left
    }

    @Test("one message per job per hour at urgency 2; urgency 3 and other jobs are not held")
    func rateLimit() async throws {
        let h = try await LadderHarness.make()
        #expect(await h.escalate(2, "first") == .sent(rung: 2))
        h.clock.advance(30 * 60)
        #expect(await h.escalate(2, "second") == .rateLimited)
        #expect(await h.escalate(2, "other job", automation: "auto-2", job: "brief") == .sent(rung: 2))
        #expect(await h.escalate(3, "urgent") == .sent(rung: 2))
        h.clock.advance(31 * 60)
        #expect(await h.escalate(2, "third") == .rateLimited)   // the urgency-3 send 31 min ago counts
        h.clock.advance(30 * 60)
        #expect(await h.escalate(2, "fourth") == .sent(rung: 2))
        #expect(h.box.texts == ["first", "other job", "urgent", "fourth"])
        let held = h.store.recent().filter { $0.rung == 1 && $0.urgency == 2 }
        #expect(held.count == 2)
        #expect(held.allSatisfy { $0.resolvedAt != nil })
    }

    @Test("a failed send falls back to the local notification and still counts as sent")
    func sendFailure() async throws {
        let h = try await LadderHarness.make()
        h.box.failNext(1)
        #expect(await h.escalate(2, "Lease form due") == .sent(rung: 2))
        #expect(h.box.sent.isEmpty)
        #expect(h.box.fallbackBodies == ["Lease form due"])
        #expect(h.box.fallbackTitles.first?.contains("triage") == true)
        let record = try #require(h.store.recent().first)
        #expect(record.sentAt != nil)
        #expect(record.rung == 2)
    }

    @Test("an unconfigured ladder only logs")
    func unconfigured() async {
        let ladder = EscalationLadder()
        let outcome = await ladder.escalate(automationId: "a", jobName: "j", urgency: 3, text: "x",
                                            delivery: .panel, activeHours: .standard)
        #expect(outcome == .logged)
        #expect(await ladder.acknowledge(threadKey: "panel", text: "ok", at: Date()) == false)
    }

    @Test("the timer wakes for deferred and repeat deliveries")
    func timer() async throws {
        let h = try await LadderHarness.make(at: "2026-11-03 23:30")
        await h.ladder.start()
        #expect(await h.escalate(2, "Later") == .deferred(until: localDate("2026-11-04 08:00")))
        #expect(h.store.nextDue() == localDate("2026-11-04 08:00"))
        h.clock.advance(9 * 3600)
        #expect(await waitUntil { h.box.texts == ["Later"] })
        await h.ladder.stop()
    }
}

@Suite("ChannelRouter owner-message hook", .serialized)
struct OwnerMessageHookTests {

    @Test("a consumed reply is answered with Noted and never becomes a task; everything else still runs")
    func hook() async throws {
        await withPermissionMode(.standard) {
            let provider = ScriptedProvider([.text("Done. Fine.")])
            let manager = await makeManager(route: { _ in (provider, []) })
            let router = ChannelRouter()
            await router.configure(manager: manager, owners: { ["+15551234567"] })
            let seen = LockedStrings()
            await router.setOwnerMessageHandler { origin, text, _ in
                seen.append("\(origin.threadKey)|\(text)")
                return text == "ok"
            }
            let channel = FakeChannel(id: "imessage", trust: .remoteText)
            await router.register(channel)

            channel.receive("ok", from: "+15559999999")               // not the owner: never reaches the hook
            channel.receive("ok", from: "+15551234567")
            #expect(await waitUntil { channel.sent.contains("Noted.") })
            #expect(await manager.list().isEmpty)

            channel.receive("summarize my day", from: "+15551234567")
            #expect(await waitUntil { channel.sent.contains { $0.hasPrefix("On it") } })
            #expect(await waitUntil { await manager.list().count == 1 })
            #expect(seen.all == ["t1|ok", "t1|summarize my day"])

            channel.receive("yes ABCD", from: "+15551234567")        // approval replies are parsed first
            #expect(await waitUntil { channel.sent.contains("Nothing is waiting for your approval here.") })
            #expect(seen.all.count == 2)
            await router.unregister("imessage")
        }
    }
}
