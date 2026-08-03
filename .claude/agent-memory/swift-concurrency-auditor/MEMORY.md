# Agent Memory Index

- [Isolation enforcement premise](project_isolation_enforcement.md) — repo builds in Swift 5 mode, so the MainActor isolation map is warnings-only; how to verify with swiftc
- [Adaptive thinking round-trip audit (2026-07-31)](audit_adaptive_thinking_2026_07_31.md) — rawContent echo + launch-time detached DB task validated clean; MCP double-start orphan is pre-existing
- [Truthful loop audit (2026-08-03)](audit_truthful_loop_2026_08_03.md) — AgentLoop has two failure writers, not one; AppDelegate catch-arm mapping decides stopped-vs-incomplete
