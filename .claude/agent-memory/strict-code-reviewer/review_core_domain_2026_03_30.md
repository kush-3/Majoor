---
name: Core domain review findings (2026-03-30)
description: Critical data races in AgentLoop and AnthropicProvider, massive execute() method, duplicated pipeline logic
type: project
---

Reviewed AgentLoop, AnthropicProvider, ChatManager, TaskManager, ConfirmationManager, Models, LLMProvider.

Key findings:
- **AgentLoop data races**: `conversationHistory` mutated without sync on nonisolated @unchecked Sendable class. `matchToolToPipelineStep` reads @MainActor taskManager.pipelineSteps from nonisolated context.
- **AnthropicProvider apiKey race**: `var apiKey` unprotected by stateLock despite class being @unchecked Sendable. complete()/stream()/updateAPIKey() all access without lock.
- **AgentLoop.execute() is ~380 lines**: pipeline confirmation logic duplicated between .text and .mixed cases (~70 lines each). Needs extraction.
- **AnthropicProvider.stream() triple-serializes**: Encode → JSONSerialization deserialize → add stream flag → re-serialize. Should add stream property to AnthropicRequest.
- **ChatManager blocks main thread**: wraps UsageStore.recordUsage in MainActor.run unnecessarily (UsageStore is thread-safe).

**Why:** These are correctness bugs (data races) and maintainability blockers.
**How to apply:** When reviewing future changes to these files, verify data race fixes are in place. Flag any new @unchecked Sendable without corresponding lock protection.
