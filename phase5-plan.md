# Phase 5 — MCP Integrations & Pipelines

**Goal:** Connect Majoor to the tools developers and knowledge workers live in — GitHub, Linear, Slack, Notion — via MCP (Model Context Protocol), and teach the agent to recognize when a user's action has cross-tool consequences and handle them automatically after a single confirmation.

**Branch:** `kush/phase-5-mcp-pipelines`

---

## The Core Idea

Today Majoor executes single commands: "read my email", "create a calendar event", "commit this code." Phase 5 makes Majoor understand **consequences.** When the user says "I just finished the auth feature," Majoor recognizes that this means:

1. Code needs to be committed and pushed
2. A PR needs to be created on GitHub
3. The Linear ticket needs to move to "In Review"
4. The Slack channel needs to know
5. The Notion project doc might need updating

Instead of doing all of this silently, Majoor **proposes a plan** and waits for the user to approve:

```
User: "I just finished the auth feature"

Majoor: "Nice. Here's what I can handle for you:
  • Commit & push your changes to a new branch
  • Open a PR on GitHub with a summary of the diff
  • Move the auth ticket to 'In Review' on Linear
  • Post an update in #engineering on Slack
  Want me to go ahead? (Yes / No)"

User: "Yes"

Majoor: [executes everything autonomously]
```

One confirmation. Then full autonomy. No tool-by-tool approvals.

---

## Architecture Decisions

| Decision | Choice | Rationale |
|---|---|---|
| MCP Client | Native Swift MCP client using stdio transport | MCP servers run as local subprocesses; no HTTP overhead. Swift keeps everything native. |
| MCP Server Management | Bundled server binaries + user-configurable paths | Ship common servers (GitHub, Slack, Linear, Notion) as npm packages. User provides their own tokens. |
| MCP Config | JSON config file at `~/.majoor/mcp.json` | Same pattern as Claude Code. Easy to edit, version control friendly. |
| Token Storage | Keychain via existing `KeychainManager` | Consistent with Anthropic/Google token storage. Never on disk in plaintext. |
| Pipeline Confirmation | Plan-then-execute pattern via `ConfirmationManager` | Agent proposes a list of actions in natural language, user approves once, agent executes all. Reuses existing confirmation infra. |
| Pipeline Detection | System prompt + Claude reasoning | No keyword matching. Claude decides when a user's input implies cross-tool consequences. The system prompt teaches it the pattern. |
| Tool Registration | MCP tools register dynamically alongside local tools | `ToolRegistry` returns both local `AgentTool` instances and MCP-backed tools. Agent loop doesn't know the difference. |

---

## MCP Primer

MCP (Model Context Protocol) is a standard for connecting AI agents to external tools. An MCP server is a small process that exposes tools (functions) over a standard protocol. Majoor runs as an MCP **client** — it starts server processes, discovers their tools, and calls them.

**Transport:** stdio (stdin/stdout JSON-RPC). The MCP server runs as a subprocess. Majoor writes requests to its stdin and reads responses from its stdout.

**Why this matters:** Adding a new integration to Majoor becomes "install an MCP server and add it to the config" instead of writing custom Swift tool code. The community already has servers for GitHub, Slack, Linear, Notion, and hundreds more.

---

## Sub-phases & File Plan

### 5A — MCP Client Foundation

**New files:**
- `Majoor/Core/MCP/MCPClient.swift` — Core MCP client: spawn subprocess, JSON-RPC communication, tool discovery
- `Majoor/Core/MCP/MCPServerManager.swift` — Manages configured MCP servers: start, stop, health check, restart on crash
- `Majoor/Core/MCP/MCPToolBridge.swift` — Bridges MCP tools into the `AgentTool` protocol so they work seamlessly in the agent loop
- `Majoor/Core/MCP/MCPConfig.swift` — Load/save MCP server configuration from `~/.majoor/mcp.json`

**Modified files:**
- `Majoor/Tools/ToolProtocol.swift` — `ToolRegistry.defaultTools()` merges local tools + MCP-discovered tools
- `Majoor/AppDelegate.swift` — Start MCP servers on launch, stop on quit

**MCP Config format (`~/.majoor/mcp.json`):**
```json
{
  "mcpServers": {
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": {
        "GITHUB_PERSONAL_ACCESS_TOKEN": "keychain:github_pat"
      }
    },
    "slack": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-slack"],
      "env": {
        "SLACK_BOT_TOKEN": "keychain:slack_bot_token"
      }
    },
    "linear": {
      "command": "npx",
      "args": ["-y", "mcp-linear"],
      "env": {
        "LINEAR_API_KEY": "keychain:linear_api_key"
      }
    },
    "notion": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-notion"],
      "env": {
        "NOTION_API_KEY": "keychain:notion_api_key"
      }
    }
  }
}
```

**`keychain:` prefix convention:** When an env value starts with `keychain:`, `MCPConfig` reads the actual value from Keychain via `KeychainManager`. Tokens never live in the JSON file.

**MCPClient design:**
```swift
actor MCPClient {
    private let process: Process
    private let stdin: FileHandle
    private let stdout: FileHandle
    private var requestId = 0
    private var pending: [Int: CheckedContinuation<MCPResponse, Error>] = [:]

    /// Start the MCP server subprocess
    func start(command: String, args: [String], env: [String: String]) async throws

    /// Discover available tools from the server
    func listTools() async throws -> [MCPToolDefinition]

    /// Call a tool on the server
    func callTool(name: String, arguments: [String: Any]) async throws -> MCPToolResult

    /// Gracefully shut down
    func shutdown() async
}
```

**MCPToolBridge — makes MCP tools look like AgentTools:**
```swift
struct MCPToolBridge: AgentTool, Sendable {
    let name: String
    let description: String
    let parameters: [ToolParameter]
    let requiredParameters: [String]
    let requiresConfirmation: Bool = false

    private let client: MCPClient
    private let serverName: String

    func execute(arguments: [String: String]) async throws -> ToolResult {
        let result = try await client.callTool(name: name, arguments: arguments)
        return ToolResult(success: !result.isError, output: result.content)
    }
}
```

**Tool Registry update:**
```swift
static func allTools(mcpManager: MCPServerManager) async -> [any AgentTool] {
    var tools: [any AgentTool] = defaultTools()  // existing local tools
    let mcpTools = await mcpManager.allDiscoveredTools()
    tools.append(contentsOf: mcpTools)
    return tools
}
```

The agent loop doesn't know or care if a tool is local Swift code or an MCP bridge. It just sees tools.

---

### 5B — GitHub, Slack, Linear, Notion Integration

**No new Swift files needed** — these all run via MCP servers from 5A.

**New file:**
- `Majoor/Settings/MCPSettingsView.swift` — UI to view connected MCP servers, add tokens, see tool counts, test connections

**Modified files:**
- `Majoor/Settings/SettingsView.swift` — Add "Integrations" tab
- `Majoor/Core/AgentLoop.swift` — Pass MCP tools to the tool list

**MCP Servers to support at launch:**

| Service | MCP Server Package | Token Required | Tools Exposed |
|---|---|---|---|
| **GitHub** | `@modelcontextprotocol/server-github` | Personal Access Token | create_issue, create_pull_request, list_issues, get_file_contents, search_repositories, create_or_update_file, push_files, etc. |
| **Slack** | `@modelcontextprotocol/server-slack` | Bot Token (xoxb-) | list_channels, post_message, reply_to_thread, get_channel_history, search_messages, get_users, etc. |
| **Linear** | `mcp-linear` | API Key | create_issue, update_issue, list_issues, search_issues, get_teams, create_comment, transition_issue, etc. |
| **Notion** | `@modelcontextprotocol/server-notion` | Integration Token | search, get_page, create_page, update_page, append_blocks, list_databases, query_database, etc. |

**MCPSettingsView design:**
- List all configured servers from `mcp.json`
- Status indicator: 🟢 running (X tools) / 🔴 stopped / 🟡 starting
- "Add Token" button per server → stores in Keychain
- "Test Connection" button → calls `listTools()` and shows count
- "Add Server" for custom MCP servers (advanced users)
- Link to open `~/.majoor/mcp.json` in editor for manual config

**Token setup flow:**
1. User goes to Settings → Integrations
2. Clicks "Connect GitHub"
3. Prompted to paste a Personal Access Token (with link to GitHub's token page)
4. Token saved to Keychain as `github_pat`
5. MCP server starts, discovers tools, shows "GitHub: Connected (14 tools)"

---

### 5C — Pipeline Confirmation System (Plan-Then-Execute)

This is the core UX innovation. When the user describes something that has cross-tool consequences, Majoor proposes a plan and waits for approval before executing.

**New files:**
- `Majoor/Core/PipelineConfirmation.swift` — Manages the plan-confirm-execute flow

**Modified files:**
- `Majoor/Core/AgentLoop.swift` — Updated system prompt to teach Claude the pipeline pattern + confirmation injection
- `Majoor/UI/CommandBarView.swift` — Show the plan inline with Yes/No buttons (not just a notification)

**How it works — the flow:**

1. User types: "I just finished the auth feature"
2. `AgentLoop` sends this to Claude with the full tool list (local + MCP)
3. Claude recognizes this implies cross-tool work
4. Instead of immediately calling tools, Claude returns a **plan as text** — because the system prompt tells it to
5. `AgentLoop` detects this is a pipeline plan (Claude formats it with a specific marker)
6. Majoor shows the plan in the UI with Yes/No buttons
7. User taps Yes
8. Majoor sends the approval back to Claude: "User approved. Execute the plan."
9. Claude now calls all the tools autonomously — no per-tool confirmations
10. Majoor shows progress as each step completes
11. Final summary notification when done

**System prompt addition:**
```
PIPELINE BEHAVIOR:
When the user describes a completed action, decision, or status change that has consequences
across multiple tools or services, DO NOT immediately start executing. Instead:

1. Analyze what downstream actions are needed across the connected tools
2. Present a brief, numbered plan of what you'll do
3. End with exactly: "Want me to go ahead? %%PIPELINE_CONFIRM%%"
4. WAIT for the user to respond before executing anything

Only do this when 3+ tools/services would be affected. For simple single-tool tasks,
just execute normally.

When the user approves, execute ALL steps autonomously without asking for confirmation
on individual actions. The user already approved the full plan.

Examples of pipeline triggers:
- "I finished [feature/task]" → git + PR + ticket + Slack
- "The client approved [thing]" → project setup + tasks + calendar + Slack
- "Ship the release" → tests + tag + release + tickets + changelog + Slack
- "Start the sprint" → tickets + docs + calendar + Slack
- "This bug is critical" → escalate ticket + notify people + calendar block
```

**Pipeline detection in AgentLoop:**

When Claude's response contains `%%PIPELINE_CONFIRM%%`, the agent loop:
1. Strips the marker
2. Shows the plan text in the command bar / panel UI with Yes / No buttons
3. Suspends via `ConfirmationManager` (reuses existing infra)
4. On Yes: appends `"User approved. Execute all steps now."` to messages and continues the loop
5. On No: appends `"User declined. Ask what they'd like to do differently."` and continues

This means **no new confirmation infrastructure needed.** The existing `ConfirmationManager` + notification system handles it. The only difference is that the confirmation shows a multi-line plan instead of a single action.

**Per-tool confirmations during pipeline execution:**

Once the user approves the plan, individual tools that normally require confirmation (like `send_email`, `git_push`) should **skip their individual confirmations** during pipeline execution. The plan approval covers everything.

To support this, add a flag to the agent loop:

```swift
private var pipelineApproved = false  // When true, skip per-tool confirmations
```

When `pipelineApproved` is true, tools that check `requiresConfirmation` still execute but bypass the notification prompt. Reset to `false` when the task completes.

---

### 5D — Pipeline Progress UI

**New files:**
- `Majoor/UI/PipelineProgressView.swift` — Real-time progress view showing each pipeline step

**Modified files:**
- `Majoor/UI/MainPanelView.swift` — Show pipeline progress when a pipeline is running
- `Majoor/UI/ActivityFeedView.swift` — Pipeline tasks show the plan + results in expanded view

**PipelineProgressView design:**
- Appears in the dropdown panel when a pipeline is executing
- Shows each step from the plan with status:
  - ⏳ Pending
  - 🔄 Running
  - ✅ Done
  - ❌ Failed
- Updates in real time as the agent loop processes each tool call
- Collapses into a summary card in the activity feed when complete

**Implementation:** This is mostly a UI view that reads from the existing `task.steps` array. Each `TaskStep` of type `.toolCall` maps to a pipeline step. The view groups and labels them based on the original plan.

---

### 5E — Smart Context Injection

When the user triggers a pipeline, Majoor should automatically gather relevant context before proposing the plan. This makes the plan smarter without the user having to specify details.

**Modified files:**
- `Majoor/Core/AgentLoop.swift` — Pre-gather context for pipeline-like inputs

**Context gathering rules (added to system prompt):**

```
CONTEXT GATHERING:
Before proposing a pipeline plan, silently gather context to make your plan specific:

- If the user mentions finishing code work → run git_status and git_diff first
  to know what actually changed, which branch, how many files
- If the user mentions a ticket/issue → search Linear for it to get the ID and current status
- If the user mentions a person → check recent emails and Slack messages for context
- If the user mentions a project → check Notion for the project page
- If the user mentions a meeting → check calendar for details

Use this context to make your plan specific, not generic. Instead of:
  "• Create a PR on GitHub"
Show:
  "• Create a PR 'Add JWT auth middleware' on github.com/kush/majoor (3 files changed, +142 -28)"
```

This means when the user says "I just finished the auth feature," Majoor:
1. Silently runs `git_status` and `git_diff` (1-2 seconds)
2. Finds the Linear ticket by searching for "auth" (1 second)
3. Now proposes a plan with real details: branch name, file count, ticket ID, channel name
4. User sees a specific plan, not a vague one — builds trust

---

## Implementation Order

```
Step 1: 5A — MCP Client Foundation (the plumbing)
Step 2: 5B — GitHub + Slack + Linear + Notion servers + Settings UI
Step 3: 5C — Pipeline confirmation system (the brain)
Step 4: 5D — Pipeline progress UI (the polish)
Step 5: 5E — Smart context injection (the magic)
```

---

## New File Count: 6 new files

| File | LOC Estimate |
|---|---|
| `Core/MCP/MCPClient.swift` | ~250 |
| `Core/MCP/MCPServerManager.swift` | ~150 |
| `Core/MCP/MCPToolBridge.swift` | ~80 |
| `Core/MCP/MCPConfig.swift` | ~100 |
| `Core/PipelineConfirmation.swift` | ~60 |
| `Settings/MCPSettingsView.swift` | ~180 |
| `UI/PipelineProgressView.swift` | ~120 |
| **Total new** | **~940 LOC** |

**Modified files:** ~6 existing files with moderate changes

---

## Prerequisites Checklist (before coding)

1. **Install Node.js** — MCP servers run via `npx`. Ensure `node` and `npx` are in PATH.
2. **GitHub PAT** — Generate at https://github.com/settings/tokens (scopes: `repo`, `read:org`)
3. **Slack Bot Token** — Create app at https://api.slack.com/apps, add `chat:write`, `channels:read`, `channels:history` scopes
4. **Linear API Key** — Generate at https://linear.app/settings/api
5. **Notion Integration** — Create at https://www.notion.so/my-integrations, share relevant pages with the integration
6. **Test each MCP server manually first:**
   ```bash
   GITHUB_PERSONAL_ACCESS_TOKEN=ghp_xxx npx -y @modelcontextprotocol/server-github
   ```

---

## Pipeline Examples (for system prompt testing)

### Example 1: Feature Complete
```
User: "I just finished the auth feature"
Majoor: [silently runs git_status, git_diff, searches Linear for 'auth']
Majoor: "Here's what I'll do:
  1. Commit & push your changes on branch 'agent/auth-middleware' (3 files, +142 -28)
  2. Open PR 'Add JWT auth middleware' on kush/majoor with a diff summary
  3. Move LIN-142 'Implement auth' to 'In Review' on Linear
  4. Post in #engineering on Slack: 'Auth feature ready for review → PR #47'
  Want me to go ahead? (Yes / No)"
```

### Example 2: Bug Escalation
```
User: "the payment bug is critical, escalate it"
Majoor: [searches Linear for 'payment bug', checks Slack for recent mentions]
Majoor: "Here's what I'll do:
  1. Bump LIN-289 'Payment processing fails on retry' to Urgent priority
  2. Assign it to @sarah (she last touched payments code)
  3. DM Sarah on Slack with the bug context and a link to the ticket
  4. Block 2 hours on your calendar tomorrow morning for debugging
  Want me to go ahead? (Yes / No)"
```

### Example 3: Sprint Start
```
User: "let's start the new sprint"
Majoor: [pulls Linear backlog, checks current sprint status]
Majoor: "Here's what I'll do:
  1. Start Sprint 14 on Linear with 8 tickets (23 points)
  2. Create a 'Sprint 14' page in Notion with the ticket breakdown
  3. Post sprint goals in #engineering on Slack
  4. Block 3 focus time slots on your calendar this week based on ticket estimates
  Want me to go ahead? (Yes / No)"
```

### Example 4: Ship Release
```
User: "ship v1.2.0"
Majoor: [runs tests, checks git status, lists merged PRs since last tag]
Majoor: "Here's what I'll do:
  1. Run the test suite (swift test)
  2. Create git tag v1.2.0 and push
  3. Create GitHub Release 'v1.2.0' with notes from 6 merged PRs
  4. Close 4 completed Linear tickets (LIN-301, 305, 308, 312)
  5. Update the Notion changelog with release notes
  6. Post release announcement in #general on Slack
  Want me to go ahead? (Yes / No)"
```

---

## System Prompt Update

Add to `AgentLoop.systemPrompt`:

```
YOUR MCP INTEGRATIONS:
- GitHub: create PRs, issues, read repos, manage releases via MCP
- Slack: post messages, read channels, DM users, search messages via MCP
- Linear: create/update/transition issues, manage sprints, comment on tickets via MCP
- Notion: create/update pages, query databases, manage project docs via MCP

PIPELINE BEHAVIOR:
When the user describes a completed action, decision, or status change that implies
work across 3 or more tools/services, follow the plan-then-execute pattern:

1. Silently gather context first (git status, search Linear, check Slack, etc.)
2. Present a specific, numbered plan based on real data — not generic placeholders
3. End with: "Want me to go ahead? %%PIPELINE_CONFIRM%%"
4. WAIT for approval before executing anything
5. Once approved, execute ALL steps without per-step confirmations
6. Report a summary when complete

For simple single-tool or two-tool tasks, just execute normally without the pipeline flow.
```

---

## Milestone

> User says "I just finished the auth feature." Majoor silently checks git and Linear, proposes a specific 4-step plan (commit + PR + ticket + Slack), user taps Yes, and Majoor executes everything autonomously — real PR on GitHub, real ticket moved on Linear, real message in Slack. One command, one confirmation, full execution.

---

## Open Questions

1. **MCP server lifecycle** — Should servers start on app launch and stay running? Or start on-demand when a tool is called? On-demand saves memory but adds ~2s cold start. Recommendation: start on launch for configured servers, lazy-start for optional ones.

2. **Tool count explosion** — GitHub MCP alone exposes ~15 tools. With 4 servers that's ~50+ MCP tools on top of existing ~35 local tools. That's 85+ tools in the system prompt. May need to filter by relevance or only send MCP tools when the user's input suggests cross-tool work.

3. **MCP server errors** — If an MCP server crashes mid-pipeline, should Majoor retry, skip that step, or abort? Recommendation: retry once, then skip with a note in the summary ("Slack notification skipped — connection error").

4. **Rate limits on external APIs** — GitHub, Slack, Linear all have rate limits. The MCP servers handle this internally, but long pipelines with many API calls could hit limits. Monitor and add delays if needed.

5. **Offline graceful degradation** — If user is offline, local tools (git, files, calendar) should still work. MCP tools should fail gracefully with "GitHub unavailable — I'll skip the PR creation. You can ask me to retry later."
