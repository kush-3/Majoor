# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

This is a native macOS app built with Xcode. There is no CLI build pipeline — use Xcode or `xcodebuild`.

```bash
# Build from command line
xcodebuild -project Majoor.xcodeproj -scheme Majoor -configuration Debug build

# Run from Xcode: ⌘+R
# Clean build: ⌘+Shift+K or:
xcodebuild -project Majoor.xcodeproj -scheme Majoor clean
```

Unit tests live in `MajoorTests/` (Swift Testing, app-hosted, synchronized folder like `Majoor/`; just add `.swift` files). Run them with:

```bash
xcodebuild test -project Majoor.xcodeproj -scheme Majoor -destination 'platform=macOS' -only-testing:MajoorTests
```

Two seams keep tests off real state: `AppDelegate.isRunningTests` skips every startup side effect in the test host, and `MAJOOR_DB_PATH` points `DatabaseManager` at a temp file. No linter or CI/CD is configured.

## Key Constraints

- **Swift 6 language mode with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`** (flipped 2026-10-31; isolation violations are compile errors): All types default to `@MainActor`. Any type that does off-main-thread work must be explicitly marked `nonisolated` (and `@unchecked Sendable` if needed). `AgentTool` is a `nonisolated protocol`, so tools are nonisolated by conformance. Main-thread AppKit callbacks typed `@Sendable` (observers on `queue: .main`, animation completions, timers) use `MainActor.assumeIsolated`.
- **PBXFileSystemSynchronizedRootGroup**: Files under `Majoor/` are auto-discovered by Xcode. Do NOT manually add `PBXBuildFile` or `PBXFileReference` entries to `project.pbxproj` — just create the `.swift` file in the right directory.
- **Two dependencies**: GRDB.swift v7.10.0 (SQLite ORM) and Sparkle 2 (auto-updates), both via Swift Package Manager, linked as static libraries.
- **Sandbox disabled**: The app needs direct Process/shell/git CLI access.
- **API keys Keychain-backed**: Anthropic and Tavily keys are saved to macOS Keychain at onboarding; `APIConfig.swift` (gitignored, copy from `APIConfig.swift.example`) only carries hardcoded app-level Google OAuth fallbacks.

## Architecture

### Agent Loop (`Core/AgentLoop.swift`)

The central brain. Each user command flows through:

1. **Classify** → `TaskClassifier` scores input against 72+ keywords across 8 categories
2. **Route** → `ModelRouter` hybrid routing: keyword fast path (confidence score ≥ 2) maps category to model (Opus for code/research, Sonnet for general/email); otherwise a Haiku classification call decides the model + MCP tool sets
3. **Inject memories** → `MemoryRetriever` searches SQLite for relevant past context, adds to system prompt
4. **LLM loop** (max 75 iterations) → Call Claude API → handle text response or execute tool calls (raw content blocks — text/tool_use/thinking/redacted_thinking — round-tripped verbatim on replay) → feed results back
5. **Persist** → Save task to SQLite (memories are saved by the model itself via the save_memory tool)

The agent loop is `nonisolated` and runs off the main thread inside an `AgentSession` (`Core/Runtime/`). It never touches UI: it records through `TaskRecorder` and publishes `SessionEvent`s on the `EventBus`; `SessionEventPump` mirrors them into `TaskManager` on the main actor. `SessionManager` runs up to 3 sessions concurrently and queues the rest.

### Providers (`Core/Providers/`)

`LLMProvider` (`Core/LLMProvider.swift`) is Anthropic-shaped on purpose and unchanged. `AnthropicProvider` serves tier F (Claude). `OpenAICompatibleProvider` serves tier L (a server on the Mac: Ollama, LM Studio, MLX) and tier P (a hosted zero-retention endpoint) through `POST {base}/chat/completions` and `GET {base}/models`, with the same retry and cancellation behaviour as the Anthropic class. `OpenAIWire` is the pure, tested translation: system prompt → `system` message, `tool_use` → `tool_calls`, `tool_result` → `role: tool`, and the reply back into `text`/`tool_use` blocks so the loop's verbatim echo works unchanged; `finish_reason: length` → `.truncated`, a leading `<think>…</think>` is stripped, 5xx/`content_filter` become `.apiError` with the endpoint's name (the `.serverOverloaded`/`.refused` strings say "Claude"). `completeJSON` requests `response_format: json_object` and retries once on prose. `ProviderTier` (`local`, `privateCloud`, `frontier`) names the tiers; `TierSettingsStore` keeps the L/P endpoints in UserDefaults with the P key in the Keychain (`majoor_tier_p_api_key`) behind a `SecretStore` seam. Settings ▸ Models edits them, lists a server's models, and holds the **routing override** (`providerTierOverride`) that `ModelRouter.routeHybrid` honors before anything else: every task to L or P, classifier skipped. `CostConfig` prices only `claude*` models; L/P usage is recorded at zero cost until the per-tier table (Phase 2 step 3c). `Scripts/local-model-eval.py` scores tier L candidates on 20 triage/extraction/summary cases.

### Tool System (`Tools/`)

40 tools across 8 files, registered via `ToolRegistry.defaultTools()`.

All tools conform to `AgentTool` protocol (`ToolProtocol.swift`):
- `name`, `description`, `parameters` → converted to Anthropic tool schema automatically
- `requiresConfirmation` → if true, triggers actionable notification and suspends agent loop via `ConfirmationManager` (actor with `CheckedContinuation`)
- `execute(arguments:)` → async execution

AgentLoop normalizes LLM argument aliases (e.g., "file_path" → "path") before dispatching.

`fetch_webpage` and `fetch_multiple_urls` pass every URL and every redirect through `Security/URLGuard.swift`: http(s) only, no embedded credentials, no localhost/private/link-local/CGNAT (Tailscale)/`.local`/`.ts.net` targets, and DNS-resolved addresses are checked too.

### Confirmation Flow

A permission mode (Settings → General; `Core/PermissionMode.swift`, stored in UserDefaults) decides which tool calls prompt via `ConfirmationPolicy`:
- **Manual** — every non-read-only tool prompts (tools declare `isReadOnly`; MCP tools use a get_/list_/search_ name heuristic)
- **Standard** (default) — sensitive tools prompt: email send/reply, file/event deletion, git push/PR, non-bash scripts, and any shell command (execute_shell, run_tests, bash execute_script) that `Security/ShellCommandClassifier.swift` maps to one of those: interpreters and script files, rm/git clean/git reset --hard, git push, gh writes, ssh, package publishing, curl/wget, Keychain access, launchd/cron, mail. Shell `git push` also gets git_push's protected-branch guard. Sensitive prompts survive pipeline approval. MCP write tools do NOT prompt in Standard (known carve-out).
- **Auto** — sensitive tools prompt only when a fail-closed Haiku consent check judges that the user's own task wording didn't request that specific action (it sees the concrete arguments, so injected recipient/target swaps still prompt). Exception: send_email/reply_to_email ALWAYS prompt, in every mode — outbound email is irreversible

Bash scripts always pass through `CommandSanitizer` (interpreted-language scripts are confirmation-gated instead). Tools can supply a human-readable `confirmationPreview` (e.g. delete_calendar_event shows the event title/date instead of an opaque id). Stopping (the Stop button, or the exact message `stop`) cancels every session and denies every pending approval (`SessionManager.stopAll`). The prompt flow:
1. The loop asks its session: `host.requestApproval(ApprovalDraft)` (`Core/Runtime/AgentSession.swift`)
2. The session mints an id, a 4-character nonce and a 10-minute expiry, writes the `approvals` row, publishes `.approvalRequested`, and sends the actionable notification
3. The panel (`SessionEventPump` → `TaskManager.apply`) or the notification answers through `SessionManager.answerApproval(id:nonce:decision:byChannel:)`; in-process UI passes `nonce: nil`, remote channels must repeat the nonce
4. Only that session suspends; other sessions keep running (3 concurrently by default, the rest queue)

### Google OAuth (`Core/OAuth/GoogleOAuthManager.swift`)

Uses a loopback HTTP server on `127.0.0.1` (dynamic port) for OAuth redirect — Google blocks custom URL schemes for desktop apps. The flow sends `state` and PKCE (S256); a callback whose state does not match the attempt is rejected. Tokens stored in macOS Keychain.

### EventKit Calendar

Must use the shared global `sharedEventStore` instance (defined in `CalendarTools.swift`). Local `EKEventStore` instances get deallocated and kill the XPC connection before macOS can show permission dialogs. Reset permissions with: `tccutil reset Calendar com.Majoor`.

### Database (`Core/Database/DatabaseManager.swift`)

SQLite via GRDB at `~/Library/Application Support/ai.majoor.agent/majoor.sqlite`. Tables: `memories`, `tasks`, `usageStats`, `sessions`, `approvals`, `contacts_policy`, `paired_clients`, `automations` (migrations v1–v7, registered on startup). `MAJOOR_DB_PATH` overrides the path; `DatabaseManager.openAndMigrate(path:)` gives tests a throwaway database.

### MCP Client (`Core/MCP/`)

Native Swift MCP implementation over stdio/JSON-RPC:
- `MCPClient` (actor) — Manages a single MCP server process, newline-delimited JSON-RPC framing, tool discovery
- `MCPServerManager` (actor) — Lifecycle management for all MCP servers: start, stop, health monitoring, crash restart
- `MCPToolBridge` — Bridges MCP-discovered tools into the `AgentTool` protocol so the agent loop treats them identically to local tools
- `MCPConfig` — Loads `~/.majoor/mcp.json`, resolves `keychain:` prefixed env values from macOS Keychain at start time

Four pre-configured servers: GitHub (26 tools), Slack (8), Notion (22), Linear (5).

### Pipeline System

Complex tasks (3+ tools) trigger plan-then-execute flow:
1. Agent proposes a numbered plan
2. User can toggle steps on/off, add notes, then approve via `%%PIPELINE_CONFIRM%%` marker
3. Steps execute sequentially with real-time progress in `PipelineProgressView`

### Chat vs Task Modes

Two separate execution paths:
- **Task mode**: `SessionManager.handleInbound` (which recognizes the exact commands `stop`, `/status`, `/stop N`) or `submit` creates an `AgentSession` that runs `AgentLoop.run(userInput:host:)` in the background.
- **Chat mode**: Uses `ChatManager` with Sonnet + SSE streaming. Interactive, no tool execution.

### Conversation Continuity

`SessionManager.history` (`Core/Runtime/ThreadHistory.swift`) keeps the last 10 minutes of completed turns per thread (the panel is one thread; an iMessage handle or a remote client is another), injected as context for the next task in that thread. Stale entries are pruned automatically.

### App Modes (`Core/AppMode.swift`)

One binary, three roles, chosen in Settings ▸ General ▸ Mode (UserDefaults `appMode`, restart to apply):
- **local** (default): 1.x behaviour. Panel plus the local runtime; nothing listens on the network; reminders run.
- **runtime**: the always-on Mac mini. Local plus the control API (on by default), the iMessage channel (Settings ▸ Channels) and the scheduler.
- **client**: the laptop. The command bar submits to a paired runtime through `RemoteRuntimeClient`; the panel mirrors the runtime's snapshot and events (tasks carry a "Mac mini" / "This Mac" chip); approvals are answered over the API with their nonce; the local `SessionManager` is configured lazily and used only when the explicit, persisted **Run here** pill is on. A failed remote submit is shown with a Run-here action and never retried locally on its own. MCP servers are not started in client mode.

### Control API (`Core/ControlAPI/`)

`ControlServer` is an `NWListener` with `NWProtocolWebSocket` bound only to the Tailscale address (`TailscaleInterface`; a DEBUG toggle allows 127.0.0.1). Protocol v1 (`ControlProtocol.swift`): JSON text frames `{v, id, replyTo, type, body}`; `pair` with a 5-minute code from Settings ▸ Remote returns a client id and a token whose SHA-256 is stored in `paired_clients`; `hello` must arrive within five seconds; then `subscribe` (snapshot plus `event` frames from the `EventBus`), `submit` (idempotent on `clientRequestId`), `approval.answer` (nonce required), `stop`, `sessions.list`, `settings.get/set` (allowlisted keys; the permission mode can only be tightened remotely). Client side: `RemoteRuntimeClient` (reconnect 1→30 s backoff, resubscribe from the last seq, 10 s request timeouts, terminal `.failed` when revoked), `RemoteSessionGateway` (the `SessionGateway` shape over it), `RuntimeConnectionModel` (UI state), credentials in UserDefaults plus the token in the Keychain (`ClientCredentialsStore`).

### Channels (`Core/Channels/`)

A `Channel` yields `InboundMessage`s and sends text to a thread; `ChannelRouter` consumes every registered channel, applies `TrustPolicy` (remote-text senders must match an owner handle in `contacts_policy`, normalized E.164/lower-case email), recognizes coded approval replies (`yes K7Q2`, `no K7Q2 note`; a bare "yes" is a task), submits through `SessionManager.handleInbound`, and sends results and approval prompts back to the originating thread. `PanelChannel` is the command bar. `IMessageChannel` (`Channels/IMessage/`, runtime mode) drives one `imsg rpc` child (`brew install steipete/tap/imsg`; Majoor.app needs Full Disk Access and Automation for Messages) through `JSONRPCLineClient` (newline JSON-RPC, `NewlineJSONFramer`, notifications stream; `MCPClient` is untouched): initialize → replay `messages.after` from the saved row id → `watch.subscribe`. `IMessageInboundPolicy` accepts only the owner, only in a direct iMessage chat, drops our own echoes, reactions, edits, groups and SMS, rate-limits to 10/min, and after an outage summarizes rather than runs messages older than the stale window (default 10 min; a trailing `stop` is still honored). Replies are chunked at ~1,500 characters, max 6. The helper is restarted with 5→80 s backoff and given up after five quick exits.

### Automations (`Core/Automation/`)

`automations` holds the full PRD shape; Phase 1 writes one-shot reminders (`create_reminder`, `list_reminders`, `cancel_reminder` in `Tools/ReminderTools.swift`). `AutomationStore.claimDue` claims due rows in one transaction; `AutomationScheduler` is a single timer behind a `SchedulerClock` seam, re-armed by `wake()` (create/cancel, system wake, clock change), with launch catch-up (rows more than a day late are prefixed "missed"), stale-claim release and 60 s retries up to five. A firing is recorded through `SessionManager.recordJob` and delivered to the originating channel (iMessage) or as a local notification plus panel toast. Runs in local and runtime modes; active hours deliberately do not apply to reminders.

# CLAUDE.md — Majoor

This document defines how Claude Code should understand, reason about, and modify this repository.  
It is written to maximize reliability, correctness, and architectural consistency.

---

# Project Overview

Majoor is a **native macOS AI agent** that autonomously performs tasks across:

- Filesystem
- Email (Gmail OAuth)
- Calendar (EventKit)
- Web research
- Code execution
- External MCP tools (GitHub, Slack, Notion, Linear)

The system is designed around a **tool‑driven agent loop** with memory, planning, and model routing.

This is **not** a typical MVC/macOS app.  
It is an **agent runtime with a UI shell**.

---

# Core Engineering Principles

Claude MUST follow these principles when modifying code:

### 1. Agent First Architecture

- The **AgentLoop** is the brain
- UI is a thin wrapper
- Tools are capabilities
- Memory is persistent intelligence

Never move logic from AgentLoop into UI.

---

### 2. Deterministic Tooling

Tools must:

- Be stateless where possible
- Return structured responses
- Never print logs as primary output
- Avoid hidden side effects

---

### 3. Safety & Reliability

Claude must:

- Avoid destructive operations without confirmation
- Preserve existing architecture
- Prefer additive changes
- Avoid refactoring unrelated files

---

# Build & Run

This is a native macOS app built with Xcode.

There is **no CLI build pipeline**.

### Build from CLI

```bash
xcodebuild -project Majoor.xcodeproj -scheme Majoor -configuration Debug build
```

### Run

```
⌘ + R (Xcode)
```

### Clean Build

```
⌘ + Shift + K
```

or

```bash
xcodebuild -project Majoor.xcodeproj -scheme Majoor clean
```

---

# Project Constraints

### Swift Version

- Swift 6
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`

This means:

- Everything defaults to `@MainActor`
- Background workers must be explicitly:

```
nonisolated
```

If concurrency is used:

```
@unchecked Sendable
```

---

### File System Sync

Project uses:

```
PBXFileSystemSynchronizedRootGroup
```

Do NOT manually edit:

```
project.pbxproj
```

To add files:

- Create `.swift` file in correct directory
- Xcode auto-discovers

---

### Dependencies

Two dependencies, both static libraries via SPM:

- **GRDB.swift v7.10.0** — SQLite ORM
- **Sparkle 2** — auto-updates

Do NOT introduce new dependencies unless necessary.

---

### Sandbox

Sandbox is **disabled intentionally**.

The app requires:

- shell execution
- git CLI
- process spawning

Do not enable sandbox.

---

### API Keys

Anthropic and Tavily keys are stored in the macOS Keychain (saved via onboarding). Resolved through:

```
APIConfig.swift
```

which is gitignored — copy from `APIConfig.swift.example` to bootstrap it. Only the Google OAuth
client ID/secret carry hardcoded app-level fallbacks in that file.

Do not refactor unless explicitly requested.

---

# Architecture

# Agent Loop

Location:

```
Core/AgentLoop.swift
```

This is the **central brain**.

Pipeline:

1. Classify → TaskClassifier
2. Route → ModelRouter
3. Retrieve Memory → MemoryRetriever
4. LLM Loop (max 75 iterations)
5. Persist Results

---

## Classification

```
TaskClassifier
```

- 72+ keywords
- 8 categories

Claude must **not break classifier assumptions**.

---

## Model Routing

```
ModelRouter
```

Hybrid routing: a keyword fast path (confidence score ≥ 2) maps category to model directly; below
that threshold, a Haiku LLM call classifies the task into a model + MCP tool sets instead.

Fast-path rules:

| Category | Model |
|----------|-------|
| Coding | Opus |
| Research | Opus |
| Email | Sonnet |
| General | Sonnet |

Do not hardcode model logic elsewhere.

A routing override in Settings ▸ Models (UserDefaults `providerTierOverride`) sends every task to
tier L or P through `OpenAICompatibleProvider` and skips both paths above. Router v2 (Phase 2
step 3) replaces it with routing by data class.

---

## Memory Injection

```
MemoryRetriever
```

SQLite search:

- Semantic retrieval
- Inject into system prompt

Memory is critical.

Never remove memory logic.

---

## LLM Loop

Max:

```
75 iterations
```

Cycle:

1. Call Claude
2. Tool call OR text response — content blocks (`text`/`tool_use`/`thinking`/`redacted_thinking`)
   are round-tripped verbatim when replaying the assistant turn
3. Execute tool
4. Feed back

This loop is **nonisolated** and talks only to its `AgentLoopHost` (the session): recorder, thread history, events, approvals, budget. UI state is derived from `SessionEvent`s; never reach into `TaskManager` from the loop.

---

# Tool System

Location:

```
Tools/
```

40 tools across 8 files.

All tools conform to:

```
AgentTool
```

Defined in:

```
ToolProtocol.swift
```

Tool Interface:

- name
- description
- parameters
- requiresConfirmation
- execute()

---

# Confirmation Flow

Gated by a permission mode (`Core/PermissionMode.swift`; Settings → General):

| Mode | Prompts for |
|------|-------------|
| Manual | every non-read-only tool |
| Standard (default) | sensitive tools, even mid-pipeline |
| Auto | sensitive tools the task didn't explicitly request (Haiku consent check, fail-closed) |

Sensitive = send_email, reply_to_email, delete_file, delete_calendar_event,
git_push, git_create_pr, execute_script for non-bash languages (bash scripts
go through CommandSanitizer in every mode), and any execute_shell/run_tests/
bash-script command that `Security/ShellCommandClassifier.swift` maps to an
equivalent sensitive action (interpreters, script files, deletions, git push,
gh writes, ssh, publishing, curl/wget, Keychain, launchd/cron, mail). MCP
write tools are a known carve-out: they never prompt in Standard/Auto.

Flow:

1. Loop → `host.requestApproval(ApprovalDraft)`
2. `AgentSession` registers one continuation per session (nonce, expiry, `approvals` row), publishes `.approvalRequested`
3. Panel or notification → `SessionManager.answerApproval`
4. That session resumes; the others never stopped

Managed by:

```
Core/Runtime/AgentSession.swift
Core/Runtime/SessionManager.swift
```

STOP (`SessionManager.stopAll`) denies every pending approval and cancels every session; a session's recorder finishes exactly once, so a stop can never be followed by a success.

---

# Google OAuth

Location:

```
Core/OAuth/GoogleOAuthManager.swift
```

Uses:

```
127.0.0.1 loopback server
```

Reason:

Google blocks custom URL schemes.

Tokens stored in:

```
macOS Keychain
```

Do not change OAuth flow.

---

# EventKit

Use global:

```
sharedEventStore
```

Defined in:

```
CalendarTools.swift
```

Do NOT create local:

```
EKEventStore
```

Reset permissions:

```bash
tccutil reset Calendar com.Majoor
```

---

# Database

Location:

```
Core/Database/DatabaseManager.swift
```

SQLite via GRDB

Path:

```
~/Library/Application Support/ai.majoor.agent/majoor.sqlite
```

Tables:

- memories
- tasks
- usageStats

Migrations run on startup.

---

# MCP Client

Location:

```
Core/MCP/
```

Components:

### MCPClient

- actor
- stdio JSON‑RPC
- tool discovery

### MCPServerManager

- lifecycle management
- restart
- health checks

### MCPToolBridge

- converts MCP tools to AgentTool

### MCPConfig

Loads:

```
~/.majoor/mcp.json
```

Supports:

```
keychain:
```

Environment variables.

---

# MCP Servers

Preconfigured:

| Server | Tools |
|--------|------|
| GitHub | 26 |
| Slack | 8 |
| Notion | 22 |
| Linear | 5 |

---

# Pipeline System

Triggered when:

```
3+ tools required
```

Flow:

1. Plan
2. User approve
3. Execute sequentially

Marker:

```
%%PIPELINE_CONFIRM%%
```

UI:

```
PipelineProgressView
```

---

# Chat vs Task Mode

## Task Mode

Uses:

```
AgentLoop
```

- Background execution
- Tool execution
- Memory persistence

---

## Chat Mode

Uses:

```
ChatManager
```

- Sonnet
- Streaming SSE
- No tool execution

---

# Conversation Continuity

`ThreadHistory` (per thread, owned by `SessionManager`) stores the last 10 minutes, 5 entries, 1000-char responses, auto-pruned.

---

# Coding Rules

Claude must:

- Prefer small changes
- Avoid large refactors
- Preserve architecture
- Avoid introducing new frameworks
- Maintain Swift concurrency correctness
- Avoid blocking main thread

---

# File Organization

```
Core/
Tools/
UI/
Settings/
Security/
Utils/
```

Follow existing structure.

---

# When Adding New Tools

Claude must:

1. Create tool file in Tools/
2. Conform to AgentTool
3. Register in ToolRegistry
4. Add description
5. Define parameters

---

# When Modifying Agent Loop

Claude must:

- Avoid changing iteration logic
- Avoid breaking tool dispatch
- Preserve memory injection

---

# Performance Constraints

Avoid:

- Blocking calls on MainActor
- Long synchronous operations
- Heavy UI updates

---

# Debugging

Logs are acceptable but:

- Avoid verbose logs
- Avoid print spam
- Prefer structured logs

---

# Testing

Swift Testing suites in `MajoorTests/` (app-hosted; see Build & Run for the
command). Pure-logic code (classifiers, guards, parsers, schedulers) gets
tests; UI and live-API flows are still tested manually. The
`majoor://task?text=&token=` hook (AppDelegate) lets a script submit a task
to a running build when the app was launched with `MAJOOR_AUTOMATION_TOKEN`.

---

# Git Commits

All agents must follow these rules for every commit, push, PR, and merge:

- **Never** add `Co-authored-by:` lines (or any other co-author / attribution trailer) to commit messages.
- **Never** use `--trailer`, `--author`, or any other git flag intended to attribute authorship to an AI, bot, or agent.
- Commit messages should contain only the human-authored description of the change — no agent attribution footers.

This applies to all git operations: local commits, pushes to GitHub, PR squash merges, and any other version-control workflow.

---

# Final Rule

Claude should treat this repository as:

> A production‑grade autonomous agent runtime

All changes must preserve:

- Reliability
- Determinism
- Safety
- Performance