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

There are no tests, linter, or CI/CD configured.

## Key Constraints

- **Swift 6 with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`**: All types default to `@MainActor`. Any type that does off-main-thread work must be explicitly marked `nonisolated` (and `@unchecked Sendable` if needed).
- **PBXFileSystemSynchronizedRootGroup**: Files under `Majoor/` are auto-discovered by Xcode. Do NOT manually add `PBXBuildFile` or `PBXFileReference` entries to `project.pbxproj` — just create the `.swift` file in the right directory.
- **Single dependency**: GRDB.swift v7.10.0 (SQLite ORM) via Swift Package Manager, linked as a static library.
- **Sandbox disabled**: The app needs direct Process/shell/git CLI access.
- **API keys hardcoded** in `APIConfig.swift` — this is intentional for personal use.

## Architecture

### Agent Loop (`Core/AgentLoop.swift`)

The central brain. Each user command flows through:

1. **Classify** → `TaskClassifier` scores input against 72+ keywords across 8 categories
2. **Route** → `ModelRouter` maps category to model (Opus for code/research, Sonnet for general/email)
3. **Inject memories** → `MemoryRetriever` searches SQLite for relevant past context, adds to system prompt
4. **LLM loop** (max 25 iterations) → Call Claude API → handle text response or execute tool calls → feed results back
5. **Persist** → Save task to SQLite, extract memories from conversation

The agent loop is `nonisolated` and runs off the main thread. UI updates go through `MainActor.run`.

### Tool System (`Tools/`)

34 tools across 6 files, registered via `ToolRegistry.defaultTools()`.

All tools conform to `AgentTool` protocol (`ToolProtocol.swift`):
- `name`, `description`, `parameters` → converted to Anthropic tool schema automatically
- `requiresConfirmation` → if true, triggers actionable notification and suspends agent loop via `ConfirmationManager` (actor with `CheckedContinuation`)
- `execute(arguments:)` → async execution

AgentLoop normalizes LLM argument aliases (e.g., "file_path" → "path") before dispatching.

### Confirmation Flow

Tools like `send_email` and `delete_calendar_event` require user approval:
1. `ConfirmationManager` sends actionable notification (approve/deny)
2. Agent loop suspends via `CheckedContinuation`
3. User taps notification action → continuation resumes
4. The entire agent loop blocks during confirmation (no concurrent task queue)

### Google OAuth (`Core/OAuth/GoogleOAuthManager.swift`)

Uses a loopback HTTP server on `127.0.0.1` (dynamic port) for OAuth redirect — Google blocks custom URL schemes for desktop apps. Tokens stored in macOS Keychain.

### EventKit Calendar

Must use the shared global `sharedEventStore` instance (defined in `CalendarTools.swift`). Local `EKEventStore` instances get deallocated and kill the XPC connection before macOS can show permission dialogs. Reset permissions with: `tccutil reset Calendar com.Majoor`.

### Database (`Core/Database/DatabaseManager.swift`)

SQLite via GRDB at `~/Library/Application Support/ai.majoor.agent/majoor.sqlite`. Three tables: `memories`, `tasks`, `usageStats`. Migrations registered on startup.

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
- **Task mode**: Uses `AgentLoop` (classify → route → tools → persist). Fire-and-forget, runs in background.
- **Chat mode**: Uses `ChatManager` with Sonnet + SSE streaming. Interactive, no tool execution.

### Conversation Continuity

AgentLoop maintains a `conversationHistory` of the last 10 minutes, auto-injected as context for subsequent tasks. Stale entries are pruned automatically.

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

Single dependency:

- **GRDB.swift v7.10.0**
- SQLite ORM
- Static library via SPM

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

Stored in:

```
APIConfig.swift
```

Hardcoded intentionally.

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
4. LLM Loop (max 25 iterations)
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

Routing rules:

| Category | Model |
|----------|-------|
| Coding | Opus |
| Research | Opus |
| Email | Sonnet |
| General | Sonnet |

Do not hardcode model logic elsewhere.

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
25 iterations
```

Cycle:

1. Call Claude
2. Tool call OR text response
3. Execute tool
4. Feed back

This loop is **nonisolated**.

UI updates must use:

```
MainActor.run
```

---

# Tool System

Location:

```
Tools/
```

34 tools across 6 files.

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

Used for:

- send_email
- delete_calendar_event
- destructive actions

Flow:

1. Notification
2. Suspend loop
3. Await response
4. Resume continuation

Managed by:

```
ConfirmationManager
```

Uses:

```
CheckedContinuation
```

The agent loop **blocks intentionally**.

Do not introduce concurrency here.

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

AgentLoop stores:

```
conversationHistory
```

Retention:

```
10 minutes
```

Auto pruning.

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
Models/
Services/
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

No test framework configured.

Manual testing only.

---

# Final Rule

Claude should treat this repository as:

> A production‑grade autonomous agent runtime

All changes must preserve:

- Reliability
- Determinism
- Safety
- Performance