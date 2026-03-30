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
