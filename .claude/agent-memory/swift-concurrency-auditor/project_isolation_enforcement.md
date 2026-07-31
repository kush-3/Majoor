---
name: project-isolation-enforcement
description: Majoor builds in Swift 5 language mode, so the MainActor-default isolation map is NOT compiler-enforced — audit premise to re-verify every session
metadata:
  type: project
---

Majoor sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` **and** `SWIFT_VERSION = 5.0`
(both Debug and Release, `Majoor.xcodeproj/project.pbxproj`). `SWIFT_STRICT_CONCURRENCY`
is not set at all. Consequence: every isolation violation — isolated conformances,
cross-actor calls, Sendable gaps — is emitted as a **warning** ("this is an error in the
Swift 6 language mode"), never an error. A green build proves nothing about race freedom.

**Why:** CLAUDE.md and the agent brief both describe this as "Swift 6", which invites the
false inference that the compiler already rejects the racy shapes. It does not. Confirmed
2026-07-31 by compiling a reproduction with the project's own flags.

**How to apply:**
- Do not treat "it compiles" as evidence. Read the lock/actor discipline by hand.
- Re-grep `SWIFT_VERSION` in project.pbxproj at the start of each audit — if it ever moves
  to 6.0, a batch of currently-silent warnings becomes build-breaking, and unannotated
  MainActor-by-default types used from actors are the first to fail.
- To settle an isolation question definitively, compile a minimal repro instead of
  reasoning from memory:
  `swiftc -typecheck -swift-version 6 -default-isolation MainActor repro.swift`
  (run it at `-swift-version 5` too — the delta is exactly what the Swift 6 migration will break).
- Verified semantics: type-level `nonisolated` on a struct covers the synthesized
  `Codable` conformance *and* all custom members (custom `init(from:)`, `toX()`), so a
  single type-level annotation is sufficient. Explicit `Sendable` conformance does **not**
  exempt a type from default MainActor isolation. A MainActor-isolated type nested inside
  a `nonisolated` container that is only decoded from nonisolated contexts produces no
  diagnostic — which is why `AnyCodable` gets away with being unannotated.

See [[audit-adaptive-thinking-roundtrip-2026-07-31]].
