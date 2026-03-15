# Majoor

A native macOS AI agent that lives in your menu bar. It runs tasks autonomously, chats interactively, manages email, calendar, git, and more — all powered by Claude.

## Features

- **Autonomous Task Execution** — Describe what you need, Majoor figures out the steps and executes them
- **Streaming Chat** — Interactive conversation mode with real-time streaming responses
- **34 Built-in Tools** — File management, shell execution, git/GitHub, web search, email (Gmail), calendar (Apple Calendar)
- **MCP Integrations** — Connect GitHub, Slack, Notion, and Linear for cross-service workflows
- **Pipeline Plans** — Complex multi-step tasks are proposed as plans you can review, edit, and approve
- **Interactive Confirmations** — Every sensitive action (email send, file delete) requires your approval with optional feedback
- **Memory System** — Majoor remembers context from past tasks to work smarter over time
- **Smart Routing** — Automatically picks the right model (Opus for complex tasks, Sonnet for quick ones)

## Requirements

- macOS 14.0 (Sonoma) or later
- An [Anthropic API key](https://console.anthropic.com)

## Installation

1. Download the latest `Majoor.dmg` from [Releases](https://github.com/kush-3/majoor/releases)
2. Open the DMG and drag Majoor to your Applications folder
3. Launch Majoor — the pickaxe icon appears in your menu bar
4. Follow the onboarding wizard to enter your API key

> **Note:** On first launch, macOS may show a warning since the app is not notarized. Right-click the app → Open → click Open to bypass this.

## Usage

### Command Bar
Press **Cmd+Shift+Space** to open the command bar. Type a task and press Enter.

- **Task mode** — Fire-and-forget autonomous execution ("create a PR for my changes", "search my email for the invoice from last week")
- **Chat mode** — Press Tab to switch. Interactive streaming conversation.
- **History** — Press Up/Down arrows to cycle through previous commands.

### Panel
Click the menu bar icon to open the panel. Two tabs:
- **Tasks** — Activity feed showing running and completed tasks with status, details, and tool call logs
- **Chat** — Streaming conversation interface

### Confirmations
Sensitive actions (sending emails, deleting files/events) trigger an in-app confirmation with:
- Full context of what will happen
- Text input for feedback ("send but change the subject to X")
- Approve / Deny buttons

### Pipelines
Complex tasks spanning 3+ tools are proposed as numbered plans. You can:
- Toggle individual steps on/off
- Add notes before approving
- Watch real-time progress as each step executes

## Integrations

### Built-in
- **Gmail** — Read, search, send, reply, draft emails (OAuth)
- **Apple Calendar** — Read, create, update, delete events (EventKit)
- **Git** — Status, diff, log, branch, commit, push, PR creation
- **Web** — Search (Tavily), fetch and extract webpage content
- **Shell** — Execute commands and scripts with safety guardrails

### MCP Servers
Connect external services via [MCP](https://modelcontextprotocol.io):
- **GitHub** — Issues, PRs, repos, code search (26 tools)
- **Slack** — Read/post messages, channels (8 tools)
- **Notion** — Pages, databases, search (22 tools)
- **Linear** — Issues, projects, teams (5 tools)

Configure tokens in Settings → Integrations, or edit `~/.majoor/mcp.json`.

## Building from Source

```bash
# Clone
git clone https://github.com/kush-3/majoor.git
cd majoor

# Build
xcodebuild -project Majoor.xcodeproj -scheme Majoor -configuration Debug build

# Or open in Xcode and press Cmd+R
open Majoor.xcodeproj
```

### Requirements
- Xcode 15.0+
- Swift 6
- Only dependency: [GRDB.swift](https://github.com/groue/GRDB.swift) v7.10.0 (SQLite, via SPM)

## Architecture

```
Majoor/
├── Core/
│   ├── AgentLoop.swift           # Central brain: classify → route → LLM → tools → persist
│   ├── AnthropicProvider.swift   # Claude API client (request-response + SSE streaming)
│   ├── ChatManager.swift         # Streaming chat session manager
│   ├── ConfirmationManager.swift # Async confirmation flow with user feedback
│   ├── TaskManager.swift         # Task state, toasts, confirmations, pipeline state
│   ├── Router/                   # Task classification + model routing
│   ├── Memory/                   # SQLite memory storage + retrieval
│   ├── MCP/                      # MCP client, server manager, tool bridge
│   ├── OAuth/                    # Google OAuth 2.0 loopback flow
│   └── Database/                 # GRDB database manager
├── Tools/                        # 34 tools: File, Shell, Git, Web, Calendar, Email
├── UI/
│   ├── MainPanelView.swift       # Dropdown panel (tasks, chat, confirmations, pipeline)
│   ├── ChatView.swift            # Streaming chat with message bubbles
│   ├── ActivityFeedView.swift    # Task cards with status and details
│   ├── CommandBarView.swift      # Spotlight-style input with Task/Chat modes
│   ├── ToastOverlay.swift        # In-app notification toasts
│   ├── ConfirmationSheet.swift   # Interactive confirmation with feedback input
│   └── StatusBarController.swift # Menu bar icon states
├── Settings/                     # 7-tab preferences window
└── Security/                     # Keychain + command sanitizer
```

## License

MIT License — see [LICENSE](LICENSE) for details.
