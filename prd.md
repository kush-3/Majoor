# macOS AI Agent — Full Product Plan

## 1. Product Vision

A native macOS AI agent that lives in your menu bar and autonomously performs tasks on your behalf — managing files, handling email and calendar, writing and shipping code, doing web research, and running scheduled routines — all powered by intelligently routed LLMs.

**One-liner:** A silent, capable AI assistant that works in the background so you don't have to.

**Key differentiators from OpenClaw:**
- Fully native macOS experience — no messaging app middleman
- Deep integration with macOS APIs (filesystem, Calendar, Mail, Spotlight, Accessibility)
- Multi-model orchestration — routes tasks to the best model for the job
- Hybrid local + cloud architecture for 24/7 availability
- Independent distribution (notarized, outside App Store) for maximum capability

---

## 2. Core Architecture

### 2.1 High-Level System Overview

```
┌─────────────────────────────────────────────────────┐
│                    macOS App (Swift)                 │
│                                                     │
│  ┌─────────┐  ┌──────────┐  ┌────────────────────┐ │
│  │ Menu Bar │  │ Chat/CMD │  │  Settings/Prefs    │ │
│  │   Icon   │  │  Panel   │  │     Window         │ │
│  └────┬─────┘  └────┬─────┘  └────────────────────┘ │
│       │              │                               │
│  ┌────▼──────────────▼──────────────────────────┐   │
│  │              Agent Loop (Core)                │   │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────────┐  │   │
│  │  │  Router   │ │  Memory  │ │  Task Queue  │  │   │
│  │  └────┬─────┘ └──────────┘ └──────────────┘  │   │
│  └───────┼───────────────────────────────────────┘   │
│          │                                           │
│  ┌───────▼───────────────────────────────────────┐   │
│  │            LLM Provider Layer                 │   │
│  │  ┌────────┐  ┌────────┐  ┌────────────────┐  │   │
│  │  │ Claude │  │ OpenAI │  │  Future Models │  │   │
│  │  │Opus/Son│  │ GPT-4o │  │                │  │   │
│  │  └────────┘  └────────┘  └────────────────┘  │   │
│  └───────────────────────────────────────────────┘   │
│                                                      │
│  ┌───────────────────────────────────────────────┐   │
│  │              Tool Layer (Local)               │   │
│  │  ┌──────┐┌───────┐┌─────┐┌─────┐┌─────────┐ │   │
│  │  │Files ││Email/ ││ Web ││Code ││  Git/   │ │   │
│  │  │Mgmt  ││Cal    ││Fetch││Exec ││  PR     │ │   │
│  │  └──────┘└───────┘└─────┘└─────┘└─────────┘ │   │
│  └───────────────────────────────────────────────┘   │
└──────────────────────┬──────────────────────────────┘
                       │ REST API (sync)
┌──────────────────────▼──────────────────────────────┐
│                Cloud Backend (Server)                │
│                                                      │
│  ┌──────────┐  ┌──────────┐  ┌────────────────────┐ │
│  │Scheduler │  │  Claude  │  │  Email Delivery    │ │
│  │(Cron/Job)│  │   API    │  │  (Resend/SendGrid) │ │
│  └──────────┘  └──────────┘  └────────────────────┘ │
│  ┌──────────┐  ┌──────────┐  ┌────────────────────┐ │
│  │  OAuth   │  │  Task    │  │  Push Notification │ │
│  │  Tokens  │  │  History │  │    (APNs)          │ │
│  └──────────┘  └──────────┘  └────────────────────┘ │
└─────────────────────────────────────────────────────┘
```

### 2.2 Local Agent (macOS App)

**Language:** Swift + SwiftUI
**Distribution:** Notarized, independent (outside App Store)
**Minimum macOS:** 14.0 (Sonoma) — for latest SwiftUI and background task APIs

The local agent handles everything that requires direct machine access:
- Filesystem operations
- Shell/script execution
- Git operations and PR creation
- Reading/writing local app data
- Controlling other apps via Accessibility APIs
- Spotlight search via NSMetadataQuery
- Local memory storage (SQLite)

### 2.3 Cloud Backend

**Language:** Node.js (TypeScript) or Python (FastAPI)
**Hosting:** Railway, Fly.io, or a basic VPS
**Database:** PostgreSQL (task history, user settings, schedules)
**Cache/Queue:** Redis + BullMQ (job scheduling)

The cloud backend handles everything that needs to work while the laptop is asleep:
- Scheduled/recurring tasks
- Calendar API access (Google Calendar, Apple Calendar via CalDAV)
- Email operations via Gmail API or IMAP
- Web research tasks
- Delivering results via email or push notifications
- Syncing task history with the local app

### 2.4 Sync Protocol (Local ↔ Cloud)

A REST API handles communication between the local app and cloud:

| Endpoint | Method | Purpose |
|---|---|---|
| `/tasks` | POST | Create a new scheduled/recurring task |
| `/tasks` | GET | Fetch all tasks and their statuses |
| `/tasks/:id/results` | GET | Get results of a completed task |
| `/tasks/:id` | DELETE | Cancel a scheduled task |
| `/sync/memory` | POST | Push local memory updates to cloud |
| `/sync/memory` | GET | Pull cloud memory to local |
| `/health` | GET | Check cloud backend status |

**Auth:** Each user gets an API key generated on first setup. All requests are authenticated via Bearer token over HTTPS.

**Sync strategy:** On app launch + every 5 minutes while app is active, the local app polls the cloud for new results. When the user creates a scheduled task locally, it pushes to cloud immediately.

---

## 3. Multi-Model Orchestration

### 3.1 Router Design

A lightweight classification layer sits between user input and the LLM providers. It determines which model handles each task.

**Classification approach (two tiers):**

**Tier 1 — Pattern matching (fast, free):**
Keywords and intent patterns handle obvious cases.
- Contains `code`, `function`, `implement`, `refactor`, `PR`, `git`, `debug`, `build` → Coding task → Opus
- Contains `email`, `calendar`, `file`, `organize`, `summarize`, `schedule` → Daily task → Sonnet
- Contains `research`, `search`, `compare`, `find information` → Research task → Sonnet or GPT

**Tier 2 — LLM classifier (smart, cheap):**
For ambiguous tasks, send the request to Claude Haiku with a classification prompt. Costs < $0.001 per classification, takes < 500ms.

### 3.2 Default Model Routing

| Task Category | Default Model | Reasoning |
|---|---|---|
| Code writing & refactoring | Claude Opus | Highest code quality, best at multi-file changes |
| Code review & PR descriptions | Claude Opus | Needs deep understanding of codebase |
| Email drafting & triage | Claude Sonnet | Fast, good at communication tasks |
| Calendar management | Claude Sonnet | Routine scheduling logic |
| File organization | Claude Sonnet | Pattern recognition, simple operations |
| Summarization | Claude Sonnet | Fast, cost-effective for text processing |
| Web research (deep) | Claude Opus | Better synthesis of complex information |
| Web research (quick) | Claude Sonnet | Simple lookups and summaries |
| Scheduled briefings | Claude Sonnet | Routine aggregation tasks |
| Task classification | Claude Haiku | Ultra-fast, ultra-cheap routing |
| Image understanding | GPT-4o (or Claude) | If user drops screenshots for UI work |
| Fallback / default | Claude Sonnet | Best balance of speed, cost, and quality |

### 3.3 Multi-Agent Handoff

For complex tasks that span categories, agents hand off to each other:

```
User: "Research our top 5 competitors, write a technical comparison,
       and open a PR adding it to our docs repo."

Step 1: Sonnet → Web research, gathers competitor data
Step 2: Opus  → Writes technical comparison document
Step 3: Opus  → Writes markdown, commits to repo, opens PR
```

The agent loop manages this by breaking the task into subtasks, routing each to the appropriate model, and passing context between them.

### 3.4 Cost Optimization

| Model | Approx. Cost (input/output per 1M tokens) | Use Sparingly |
|---|---|---|
| Claude Opus | ~$15 / $75 | Yes — coding and deep analysis only |
| Claude Sonnet | ~$3 / $15 | No — workhorse for daily tasks |
| Claude Haiku | ~$0.25 / $1.25 | No — use freely for classification |
| GPT-4o | ~$2.50 / $10 | Moderate — specialized tasks |

The app tracks token usage per model and displays a monthly cost estimate in settings. Users can set budget caps.

---

## 4. Feature Set (Detailed)

### 4.1 File Management & Organization

**Tools exposed to the LLM:**
- `list_directory(path)` — List contents of a directory
- `read_file(path)` — Read file contents (text files) or metadata (binary)
- `write_file(path, content)` — Create or overwrite a file
- `move_file(source, destination)` — Move or rename a file
- `copy_file(source, destination)` — Copy a file
- `delete_file(path)` — Delete a file (with confirmation)
- `search_files(query)` — Spotlight search via NSMetadataQuery
- `get_file_metadata(path)` — Get size, dates, type, etc.
- `create_directory(path)` — Create a new folder

**Example capabilities:**
- "Organize my Downloads folder by file type"
- "Find all PDFs from last month and move them to ~/Documents/Archive"
- "Delete all .tmp files in my project directory"
- "Rename all screenshots on my Desktop to include the date"
- "Find that invoice from Acme Corp"

**Safety constraints:**
- Destructive operations (delete, overwrite) always require user confirmation via notification
- Protected paths (system directories, application bundles) are off-limits
- All file operations are logged in the activity feed
- User can define "safe zones" (directories the agent can freely modify) and "protected zones" (always ask first)

### 4.2 Email & Calendar Automation

**Local tools (via macOS APIs):**
- `read_calendar_events(date_range)` — Via EventKit
- `create_calendar_event(title, date, time, duration, notes)` — Via EventKit
- `update_calendar_event(event_id, changes)` — Via EventKit
- `delete_calendar_event(event_id)` — Via EventKit (with confirmation)

**Cloud tools (via APIs):**
- `fetch_emails(query, limit)` — Via Gmail API or IMAP
- `read_email(email_id)` — Full email content
- `draft_email(to, subject, body)` — Create a draft
- `send_email(to, subject, body)` — Send (with confirmation)
- `reply_to_email(email_id, body)` — Reply to a thread
- `search_emails(query)` — Search inbox

**Example capabilities:**
- "What's on my calendar today?"
- "Schedule a meeting with Sarah for next Tuesday at 2pm"
- "Check my email for anything urgent and give me a summary"
- "Draft a reply to John's email about the project deadline"
- "Every morning at 8am, email me my daily briefing" (cloud scheduled)
- "Move all newsletters to a 'Read Later' label"

**Safety constraints:**
- Sending emails always requires explicit user confirmation
- The agent shows a preview of the draft before sending
- Calendar deletions require confirmation
- Email credentials stored securely in macOS Keychain (local) and encrypted at rest (cloud)

### 4.3 Web Browsing & Research

**Tools:**
- `web_search(query)` — Search the web via a search API (Brave Search, SerpAPI, or Tavily)
- `fetch_webpage(url)` — Fetch and extract text content from a URL
- `fetch_multiple_urls(urls[])` — Batch fetch for comparison research
- `extract_structured_data(url, schema)` — Pull specific data points from a page

**Example capabilities:**
- "Research the top 5 project management tools and compare their pricing"
- "Find the latest news about Apple's AI announcements"
- "Summarize this article: [URL]"
- "What are the current mortgage rates?"
- "Find documentation on Swift's async/await patterns"

**Implementation notes:**
- Use `URLSession` for HTTP requests
- HTML-to-text extraction via SwiftSoup or a lightweight parser
- For JavaScript-heavy pages, option to use headless WKWebView
- Rate limiting to avoid hammering websites
- Respect robots.txt

### 4.4 Code Execution & Scripting

**Tools:**
- `execute_shell(command)` — Run a shell command via Process API
- `execute_script(language, code)` — Run a script (Python, Node, Ruby, etc.)
- `read_project_structure(path)` — Get an overview of a codebase
- `read_source_file(path)` — Read a source code file
- `write_source_file(path, content)` — Write/update a source file
- `run_tests(path, command)` — Execute test suite
- `install_dependency(package_manager, package)` — Install a package

**Example capabilities:**
- "Run the test suite for my project and tell me what's failing"
- "Write a Python script that processes all CSVs in ~/data and merges them"
- "Set up a new Next.js project in ~/code/new-app"
- "Find and fix the bug in src/utils/parser.ts"
- "Refactor the authentication module to use JWT instead of sessions"

**Safety constraints:**
- Dangerous commands (rm -rf, sudo, format, etc.) are blocked or require confirmation
- Script execution happens in the project directory, not system-wide
- All executed commands are logged
- User can set a "dry run" mode where the agent shows what it would do without executing

### 4.5 Git Operations & PR Management

**Tools:**
- `git_status(repo_path)` — Check repo status
- `git_diff(repo_path)` — View current changes
- `git_create_branch(repo_path, branch_name)` — Create and checkout a new branch
- `git_commit(repo_path, message, files[])` — Stage and commit files
- `git_push(repo_path, branch)` — Push to remote
- `git_create_pr(repo_path, title, body, base_branch)` — Create a pull request
- `git_log(repo_path, count)` — View recent commits
- `git_checkout(repo_path, branch)` — Switch branches

**Workflow for code changes:**
1. Agent always creates a new branch prefixed with `agent/` (e.g., `agent/add-dark-mode`)
2. Never commits directly to `main`, `master`, or `develop`
3. Makes atomic, well-described commits
4. Runs tests before pushing (if test command is configured)
5. Creates PR with a detailed description of changes and reasoning
6. Notifies user with a link to the PR

**Supported platforms:**
- GitHub (via `gh` CLI)
- GitLab (via `glab` CLI)
- Bitbucket (via API)
- Auto-detected from git remote URL

**Example capabilities:**
- "Add input validation to the signup form and open a PR"
- "Create a new feature branch, implement the dark mode toggle, write tests, and open a PR"
- "Review the last 5 commits and summarize what changed"
- "Check if there are any open PRs that need my review"

### 4.6 Scheduled & Recurring Tasks

**Implementation:**

Local scheduler:
- `DispatchSourceTimer` for tasks while the app is running
- `IOPMAssertion` to prevent sleep during active task execution
- On-wake catch-up: checks for any missed schedules and runs them immediately

Cloud scheduler:
- BullMQ (Node.js) or Celery (Python) with Redis for job queuing
- Cron-style scheduling with timezone support
- Retry logic for failed tasks (3 attempts with exponential backoff)
- Results stored in PostgreSQL, synced to local app

**Tools:**
- `create_schedule(description, cron_expression, task_definition)` — Set up a recurring task
- `list_schedules()` — View all scheduled tasks
- `update_schedule(schedule_id, changes)` — Modify a schedule
- `delete_schedule(schedule_id)` — Remove a schedule
- `pause_schedule(schedule_id)` — Temporarily disable
- `get_schedule_history(schedule_id)` — View past executions

**Example schedules:**
- "Every Monday at 9am, check my calendar and email me a weekly briefing"
- "Every day at 6pm, summarize my unread emails"
- "Every Friday, generate a summary of git activity across my repos"
- "First of every month, organize my Downloads folder"
- "Every morning, check Hacker News for AI news and send me the top 5"

### 4.7 Persistent Memory

**What gets remembered:**
- User preferences and habits (e.g., "user prefers concise emails")
- Frequently accessed directories and files
- Past task history and outcomes
- Contact information and relationships (e.g., "Sarah = project manager at Acme")
- Project contexts (e.g., "myapp uses Next.js, TypeScript, Prisma")
- Recurring patterns (e.g., "user organizes Downloads every Friday")

**Storage:**
- Local: SQLite database via GRDB (Swift)
- Cloud: PostgreSQL (synced subset for scheduled tasks)

**Schema (simplified):**
```sql
-- Core memory entries
CREATE TABLE memories (
    id TEXT PRIMARY KEY,
    category TEXT NOT NULL,        -- 'preference', 'fact', 'context', 'habit'
    content TEXT NOT NULL,          -- The actual memory
    source_task_id TEXT,            -- Which task created this memory
    relevance_score REAL DEFAULT 1.0,
    created_at TIMESTAMP,
    last_accessed_at TIMESTAMP,
    access_count INTEGER DEFAULT 0
);

-- Task history
CREATE TABLE tasks (
    id TEXT PRIMARY KEY,
    user_input TEXT NOT NULL,
    status TEXT NOT NULL,           -- 'running', 'completed', 'failed', 'waiting'
    model_used TEXT,
    steps_json TEXT,                -- Full step-by-step log
    tokens_used INTEGER,
    cost_estimate REAL,
    created_at TIMESTAMP,
    completed_at TIMESTAMP
);

-- Scheduled tasks
CREATE TABLE schedules (
    id TEXT PRIMARY KEY,
    description TEXT NOT NULL,
    cron_expression TEXT NOT NULL,
    task_definition_json TEXT,
    is_cloud BOOLEAN DEFAULT FALSE,
    is_active BOOLEAN DEFAULT TRUE,
    last_run_at TIMESTAMP,
    next_run_at TIMESTAMP,
    created_at TIMESTAMP
);
```

**Memory retrieval:**
Before each task, the agent queries relevant memories using keyword matching and recency. These are injected into the system prompt as context. Memories that haven't been accessed in 90 days are archived (not deleted).

**User control:**
- Users can view all memories in settings
- Users can edit or delete any memory
- Users can export/import memory (JSON)
- "Forget everything about X" command works

---

## 5. User Experience (UX)

### 5.1 Menu Bar Interface

The app lives as an `NSStatusItem` in the macOS menu bar.

**Icon states:**
- Idle (default icon) — agent is ready
- Working (pulsing/animated icon) — agent is executing a task
- Attention needed (badge/dot) — agent is waiting for user input
- Error (red indicator) — something failed

**Click behavior:**
- Left click → Opens the dropdown panel (activity feed + chat)
- Right click → Quick menu (Preferences, Pause Agent, Quit)

### 5.2 Command Bar (Primary Input)

**Trigger:** Global keyboard shortcut (default: `⌘ + Shift + Space`, configurable)

**Behavior:**
- Floating, centered window (similar to Spotlight/Raycast)
- Single text input field with placeholder: "What can I help with?"
- Type a command in natural language, hit Enter
- Window dismisses, agent works in background
- Supports multi-line input (Shift+Enter for new line)
- Up arrow recalls previous commands

**Smart suggestions:**
- As user types, show 2-3 contextual suggestions based on memory and recent tasks
- e.g., typing "organize" might suggest "Organize Downloads (like last Friday)"

### 5.3 Dropdown Panel

**Tabs:**
1. **Activity** — Running and recent tasks (card-based feed)
2. **Chat** — Conversational interface for back-and-forth
3. **Routines** — Scheduled/recurring tasks with status

**Activity card anatomy:**
```
┌────────────────────────────────────────────┐
│ 🟢 Completed · 2 minutes ago              │
│                                            │
│ "Organize Downloads by file type"          │
│                                            │
│ Moved 47 files into 6 folders              │
│ Deleted 12 files older than 30 days        │
│                                            │
│ [View Details]     Model: Sonnet · $0.003  │
└────────────────────────────────────────────┘
```

**Expandable details:** clicking "View Details" shows the full step-by-step log of every action the agent took, every tool call, and every decision point.

### 5.4 Notification System

**macOS native notifications via UserNotifications framework.**

**Notification types:**
- **Task completed** — "Downloads organized. Moved 47 files." (informational)
- **Decision required** — "Found tax_return_2025.pdf (45 days old). Keep or Delete?" (actionable, with buttons)
- **Scheduled task result** — "Your weekly briefing is ready. [View]" (actionable)
- **Error** — "Failed to send email. [Retry] [View Error]" (actionable)

**Decision notifications** are critical. When the agent encounters ambiguity:
1. Agent pauses the task
2. Sends a notification with clear options (2-3 buttons)
3. User taps a button
4. Agent resumes with the user's choice

### 5.5 Settings / Preferences Window

Standard macOS preferences window (`⌘ + ,`), organized into tabs:

**General:**
- Global keyboard shortcut configuration
- Launch at login toggle
- Notification preferences (all, important only, none)
- Theme (follow system / light / dark)

**Models & Routing:**
- API keys for each provider (stored in Keychain)
- Model assignment per task category (table with dropdowns)
- Default model selector
- Monthly budget cap with warning threshold

**Permissions & Safety:**
- Directory access control (safe zones, protected zones, off-limits)
- Email sending: always confirm / confirm first time / auto-send
- File deletion: always confirm / smart (confirm for important files)
- Code execution: always confirm / auto-execute in project dirs
- Shell commands: whitelist/blacklist specific commands

**Connected Accounts:**
- Google account (Calendar, Gmail) — OAuth flow
- GitHub / GitLab — OAuth or personal access token
- Email (IMAP/SMTP) — for non-Gmail accounts

**Memory:**
- View all memories (searchable list)
- Edit / delete individual memories
- Export memories (JSON)
- Clear all memory button
- Memory auto-archive threshold (days)

**Cloud:**
- Cloud backend URL
- Sync status (last synced, connection health)
- Manage scheduled tasks
- View cloud execution history

**Usage & Costs:**
- Token usage breakdown by model (daily/weekly/monthly)
- Cost estimate per model
- Task count by category
- Most-used tools

---

## 6. Technical Implementation Details

### 6.1 Agent Loop (Core Engine)

The agent loop is the heart of the app. It follows a recursive tool-use pattern:

```
┌─────────────────────────────────────────────┐
│                                             │
│  User Input (or scheduled task trigger)     │
│         │                                   │
│         ▼                                   │
│  ┌─────────────────┐                        │
│  │  Classify Task   │ (Router)              │
│  └────────┬────────┘                        │
│           ▼                                  │
│  ┌─────────────────┐                        │
│  │  Load Relevant   │ (Memory)              │
│  │  Context/Memory  │                       │
│  └────────┬────────┘                        │
│           ▼                                  │
│  ┌─────────────────┐                        │
│  │  Build Messages  │ (System prompt +      │
│  │  + Tool Defs     │  memory + user input) │
│  └────────┬────────┘                        │
│           ▼                                  │
│  ┌─────────────────┐                        │
│  │  Call LLM API    │ ◄───────────────┐     │
│  └────────┬────────┘                  │     │
│           ▼                           │     │
│  ┌─────────────────┐                  │     │
│  │  Response Type?  │                 │     │
│  └────────┬────────┘                  │     │
│           │                           │     │
│     ┌─────┴──────┐                    │     │
│     ▼            ▼                    │     │
│  [Text]     [Tool Call]               │     │
│     │            │                    │     │
│     │            ▼                    │     │
│     │     ┌─────────────┐            │     │
│     │     │ Execute Tool │            │     │
│     │     │  Locally     │            │     │
│     │     └──────┬──────┘            │     │
│     │            │                    │     │
│     │            ▼                    │     │
│     │     ┌─────────────┐            │     │
│     │     │ Send Result  │────────────┘     │
│     │     │ Back to LLM  │                  │
│     │     └─────────────┘                   │
│     │                                       │
│     ▼                                       │
│  ┌─────────────────┐                        │
│  │  Task Complete   │                        │
│  │  Update Memory   │                        │
│  │  Notify User     │                        │
│  └─────────────────┘                        │
│                                             │
└─────────────────────────────────────────────┘
```

**Key implementation details:**

- Max iterations per task: 25 (configurable) — prevents infinite loops
- Each tool execution has a timeout (30 seconds default)
- If the LLM requests a destructive action, the loop pauses and notifies the user
- All steps are logged to the task history in real-time
- Token count is tracked per task for cost estimation

### 6.2 LLM Provider Protocol

```swift
protocol LLMProvider {
    var name: String { get }
    var model: String { get }

    func complete(
        systemPrompt: String,
        messages: [Message],
        tools: [ToolDefinition]
    ) async throws -> LLMResponse
}

enum LLMResponse {
    case text(String)
    case toolCall(id: String, name: String, arguments: [String: Any])
    case mixed([LLMResponseBlock])
}

class AnthropicProvider: LLMProvider {
    // Implements Claude API (Opus, Sonnet, Haiku)
}

class OpenAIProvider: LLMProvider {
    // Implements OpenAI API (GPT-4o, etc.)
}
```

### 6.3 Tool Protocol

```swift
protocol AgentTool {
    var name: String { get }
    var description: String { get }
    var parameters: JSONSchema { get }
    var requiresConfirmation: Bool { get }
    var category: ToolCategory { get }

    func execute(arguments: [String: Any]) async throws -> ToolResult
}

enum ToolCategory {
    case fileManagement
    case emailCalendar
    case webResearch
    case codeExecution
    case gitOperations
    case scheduling
}

struct ToolResult {
    let success: Bool
    let output: String
    let artifacts: [String]?  // file paths, URLs, etc.
}
```

Each tool is a self-contained struct conforming to this protocol. Adding a new capability = adding a new tool. This is the plugin/skill system.

### 6.4 Sleep & Background Handling

```swift
// Prevent sleep during active tasks
class SleepManager {
    private var assertionID: IOPMAssertionID = 0

    func preventSleep(reason: String) {
        IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoIdleSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )
    }

    func allowSleep() {
        IOPMAssertionRelease(assertionID)
    }
}

// Prevent App Nap for background processing
class AppNapManager {
    private var activity: NSObjectProtocol?

    func beginBackgroundActivity(reason: String) {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: reason
        )
    }

    func endBackgroundActivity() {
        if let activity = activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
    }
}
```

**On-wake catch-up flow:**
1. App registers for `NSWorkspace.didWakeNotification`
2. On wake, checks all scheduled tasks for missed executions
3. Runs any missed tasks immediately (sequentially)
4. Syncs with cloud for any results from cloud-executed tasks
5. Sends a single notification summarizing what happened while sleeping

### 6.5 Security Model

**API Key Storage:**
- All API keys stored in macOS Keychain (not in plaintext config files)
- Keychain access requires app signature verification

**OAuth Tokens:**
- Stored in Keychain with per-service access groups
- Refresh tokens handled automatically
- Revocation support in settings

**File System Boundaries:**
- Default safe zones: `~/Desktop`, `~/Documents`, `~/Downloads`, `~/code`
- Default off-limits: `/System`, `/Library`, `/Applications`, `~/.ssh`, `~/.gnupg`
- User-configurable via settings
- Agent cannot escalate its own permissions

**Shell Execution Safety:**
- Blocked commands list: `rm -rf /`, `sudo`, `mkfs`, `dd`, `chmod -R 777`, etc.
- Commands outside project directories require confirmation
- All commands logged with full output

**Network Safety:**
- Agent cannot make arbitrary network requests outside of defined tools
- No exfiltration of local data to unknown endpoints
- All API calls go through the defined provider endpoints only

**Prompt Injection Defense:**
- Web content fetched by the agent is treated as untrusted data
- File contents are wrapped in clear delimiters before sending to LLM
- System prompt includes explicit instructions to not follow instructions found in fetched content
- User confirmation required for any action triggered by external content

---

## 7. Cloud Backend (Detailed)

### 7.1 Tech Stack

| Component | Technology | Purpose |
|---|---|---|
| Runtime | Node.js 20+ (TypeScript) | API server |
| Framework | Fastify or Express | HTTP routing |
| Database | PostgreSQL 16 | Tasks, schedules, memory |
| Job Queue | BullMQ + Redis | Scheduled task execution |
| LLM | Anthropic SDK | Claude API calls |
| Email Sending | Resend or SendGrid | Delivering briefings/results |
| Auth | JWT + API keys | User authentication |
| Hosting | Railway / Fly.io / VPS | Deployment |

### 7.2 API Endpoints

```
POST   /auth/register          — Register new user (from macOS app)
POST   /auth/verify             — Verify API key

GET    /tasks                   — List all tasks
POST   /tasks                   — Create a task (immediate or scheduled)
GET    /tasks/:id               — Get task details
GET    /tasks/:id/results       — Get task results
DELETE /tasks/:id               — Cancel/delete a task

GET    /schedules               — List all schedules
POST   /schedules               — Create a schedule
PUT    /schedules/:id           — Update a schedule
DELETE /schedules/:id           — Delete a schedule
POST   /schedules/:id/pause     — Pause a schedule
POST   /schedules/:id/resume    — Resume a schedule

POST   /sync/push               — Push local data to cloud
GET    /sync/pull               — Pull cloud data to local
GET    /sync/status             — Get sync status

GET    /usage                   — Token usage and cost breakdown

POST   /accounts/connect        — OAuth flow initiation
GET    /accounts                — List connected accounts
DELETE /accounts/:id            — Disconnect an account
```

### 7.3 Scheduled Task Execution Flow

```
1. BullMQ cron fires at scheduled time
2. Worker picks up the job
3. Loads task definition + relevant user memory
4. Calls connected APIs (Calendar, Email) to gather data
5. Sends context to Claude API with tool definitions
6. Claude processes and generates output
7. If output requires delivery (email briefing):
   a. Format the content (HTML email template)
   b. Send via Resend/SendGrid
8. Store results in PostgreSQL
9. Mark task as completed
10. If user's local app is online, push notification via WebSocket
11. Otherwise, results wait for next sync
```

---

## 8. MCP (Model Context Protocol) Integration

### 8.1 Why MCP

MCP is Anthropic's open standard for connecting AI models to external tools and data sources. Building your tool layer with MCP compatibility gives you:
- Access to a growing ecosystem of community-built MCP servers
- Standardized tool definitions that work across different AI clients
- Future-proofing as more services build MCP integrations

### 8.2 Implementation

Your app can act as both an MCP client (consuming existing MCP servers) and expose its own tools as MCP-compatible endpoints.

**As an MCP client:**
- Users can connect third-party MCP servers in settings
- The app discovers available tools from connected servers
- These tools are automatically included in the LLM's tool list

**Examples of existing MCP servers users could connect:**
- Filesystem MCP server
- GitHub MCP server
- Slack MCP server
- Google Drive MCP server
- Notion MCP server

This means instead of building every integration yourself, users can plug in community MCP servers to extend the agent's capabilities.

---

## 9. Project Structure

```
macOS-AI-Agent/
├── App/
│   ├── MacOSAgentApp.swift              — App entry point
│   ├── AppDelegate.swift                 — Menu bar setup, global shortcut
│   ├── Info.plist                         — App configuration
│   └── Entitlements.plist                — Permissions
│
├── Core/
│   ├── AgentLoop/
│   │   ├── AgentLoop.swift               — Main agent execution loop
│   │   ├── TaskClassifier.swift          — Route tasks to models
│   │   └── TaskManager.swift             — Manage running/queued tasks
│   │
│   ├── LLM/
│   │   ├── LLMProvider.swift             — Protocol definition
│   │   ├── AnthropicProvider.swift        — Claude API implementation
│   │   ├── OpenAIProvider.swift           — OpenAI API implementation
│   │   ├── ModelRouter.swift             — Model selection logic
│   │   └── MessageBuilder.swift          — Construct API messages
│   │
│   ├── Tools/
│   │   ├── ToolProtocol.swift            — Base tool protocol
│   │   ├── ToolRegistry.swift            — Register and discover tools
│   │   ├── FileTools/
│   │   │   ├── ListDirectoryTool.swift
│   │   │   ├── ReadFileTool.swift
│   │   │   ├── WriteFileTool.swift
│   │   │   ├── MoveFileTool.swift
│   │   │   ├── SearchFilesTool.swift
│   │   │   └── DeleteFileTool.swift
│   │   ├── EmailTools/
│   │   │   ├── FetchEmailsTool.swift
│   │   │   ├── SendEmailTool.swift
│   │   │   ├── DraftEmailTool.swift
│   │   │   └── SearchEmailTool.swift
│   │   ├── CalendarTools/
│   │   │   ├── ReadEventsTool.swift
│   │   │   ├── CreateEventTool.swift
│   │   │   └── UpdateEventTool.swift
│   │   ├── WebTools/
│   │   │   ├── WebSearchTool.swift
│   │   │   ├── FetchWebpageTool.swift
│   │   │   └── ExtractDataTool.swift
│   │   ├── CodeTools/
│   │   │   ├── ExecuteShellTool.swift
│   │   │   ├── ReadSourceTool.swift
│   │   │   ├── WriteSourceTool.swift
│   │   │   └── RunTestsTool.swift
│   │   └── GitTools/
│   │       ├── GitStatusTool.swift
│   │       ├── GitCommitTool.swift
│   │       ├── GitPushTool.swift
│   │       └── CreatePRTool.swift
│   │
│   ├── Memory/
│   │   ├── MemoryStore.swift             — SQLite-backed memory
│   │   ├── MemoryRetriever.swift         — Context-relevant memory lookup
│   │   └── MemorySummarizer.swift        — Compress old memories
│   │
│   ├── Scheduler/
│   │   ├── LocalScheduler.swift          — On-device scheduling
│   │   ├── ScheduleManager.swift         — CRUD for schedules
│   │   └── WakeHandler.swift             — Handle missed tasks on wake
│   │
│   ├── Security/
│   │   ├── KeychainManager.swift         — API key & token storage
│   │   ├── PermissionManager.swift       — File/action permissions
│   │   └── CommandSanitizer.swift        — Shell command safety
│   │
│   └── Sync/
│       ├── CloudSyncManager.swift        — Local ↔ Cloud sync
│       └── SyncModels.swift              — Sync data models
│
├── UI/
│   ├── MenuBar/
│   │   ├── StatusBarController.swift     — Menu bar icon management
│   │   └── StatusBarMenu.swift           — Right-click menu
│   │
│   ├── CommandBar/
│   │   ├── CommandBarWindow.swift        — Floating input window
│   │   ├── CommandBarView.swift          — SwiftUI input view
│   │   └── SuggestionEngine.swift        — Smart autocomplete
│   │
│   ├── Panel/
│   │   ├── MainPanelView.swift           — Dropdown panel container
│   │   ├── ActivityFeedView.swift        — Task history feed
│   │   ├── ChatView.swift                — Conversational interface
│   │   ├── RoutinesView.swift            — Scheduled tasks view
│   │   └── TaskDetailView.swift          — Expanded task log
│   │
│   ├── Settings/
│   │   ├── SettingsWindow.swift          — Preferences window
│   │   ├── GeneralSettingsView.swift
│   │   ├── ModelsSettingsView.swift      — Model routing config
│   │   ├── PermissionsSettingsView.swift
│   │   ├── AccountsSettingsView.swift    — Connected services
│   │   ├── MemorySettingsView.swift
│   │   ├── CloudSettingsView.swift
│   │   └── UsageSettingsView.swift       — Cost tracking
│   │
│   └── Components/
│       ├── TaskCardView.swift
│       ├── NotificationManager.swift
│       └── LoadingIndicators.swift
│
├── CloudBackend/
│   ├── src/
│   │   ├── index.ts                      — Server entry point
│   │   ├── routes/
│   │   │   ├── tasks.ts
│   │   │   ├── schedules.ts
│   │   │   ├── sync.ts
│   │   │   ├── auth.ts
│   │   │   └── accounts.ts
│   │   ├── services/
│   │   │   ├── scheduler.ts              — BullMQ job scheduling
│   │   │   ├── claude.ts                 — Anthropic API wrapper
│   │   │   ├── email.ts                  — Email sending (Resend)
│   │   │   ├── calendar.ts               — Google Calendar API
│   │   │   └── gmail.ts                  — Gmail API
│   │   ├── models/
│   │   │   ├── task.ts
│   │   │   ├── schedule.ts
│   │   │   ├── user.ts
│   │   │   └── memory.ts
│   │   ├── workers/
│   │   │   └── taskWorker.ts             — Executes scheduled tasks
│   │   └── middleware/
│   │       ├── auth.ts
│   │       └── rateLimit.ts
│   ├── package.json
│   ├── tsconfig.json
│   ├── Dockerfile
│   └── docker-compose.yml                — PostgreSQL + Redis + App
│
├── Shared/
│   ├── Models/                            — Shared data models
│   └── Constants/                         — Shared constants
│
└── README.md
```

---

## 10. Development Roadmap

### Phase 1 — Foundation (Weeks 1-3)

**Goal:** Basic menu bar app with a working agent loop and file management.

- [ ] macOS menu bar app shell (NSStatusItem, global shortcut)
- [ ] Command bar UI (floating input window)
- [ ] LLM provider protocol + Anthropic Claude implementation
- [ ] Agent loop (send to Claude → receive tool call → execute → loop)
- [ ] File management tools (list, read, write, move, delete, search)
- [ ] Basic activity feed UI
- [ ] Settings window with API key configuration
- [ ] Keychain storage for API keys

**Milestone:** User can hit shortcut, type "organize my Downloads by file type," and the agent does it.

### Phase 2 — Core Tools (Weeks 4-6)

**Goal:** Add web research, code execution, and git capabilities.

- [ ] Web search tool (via Brave Search / Tavily API)
- [ ] Web page fetching and text extraction
- [ ] Shell command execution tool
- [ ] Source code reading/writing tools
- [ ] Git tools (status, branch, commit, push)
- [ ] PR creation (via gh CLI)
- [ ] Command safety layer (blocked commands, confirmation for destructive ops)
- [ ] Task detail view (step-by-step logs)

**Milestone:** User can say "fix the bug in parser.ts and open a PR" and the agent does it.

### Phase 3 — Memory & Intelligence (Weeks 7-8)

**Goal:** Persistent memory and multi-model routing.

- [ ] SQLite memory store (GRDB)
- [ ] Memory retrieval (inject relevant context before each task)
- [ ] Memory management UI in settings
- [ ] Task classifier (pattern matching + Haiku-based)
- [ ] Multi-model router (Opus for code, Sonnet for daily tasks)
- [ ] Model configuration UI in settings
- [ ] Token usage tracking and cost display

**Milestone:** Agent remembers past tasks and uses the right model for each job.

### Phase 4 — Email & Calendar (Weeks 9-11)

**Goal:** Email and calendar integration (local + cloud).

- [ ] EventKit integration (read/create/update calendar events)
- [ ] OAuth flow for Google (Calendar + Gmail)
- [ ] Email fetching and reading tools
- [ ] Email drafting and sending tools (with confirmation)
- [ ] macOS notification system (task complete, decisions, errors)
- [ ] Decision notifications with action buttons

**Milestone:** User can say "what's on my calendar today" and "draft a reply to John's email."

### Phase 5 — Cloud Backend (Weeks 12-15)

**Goal:** Cloud backend for scheduled tasks and always-on capabilities.

- [ ] Cloud server setup (Node.js + PostgreSQL + Redis)
- [ ] REST API (tasks, schedules, sync, auth)
- [ ] BullMQ scheduler for recurring tasks
- [ ] Cloud-side Claude integration
- [ ] Email delivery (Resend/SendGrid)
- [ ] Local ↔ Cloud sync protocol
- [ ] Scheduled task creation from local app
- [ ] On-wake catch-up for missed tasks
- [ ] Routines tab in the dropdown panel

**Milestone:** User sets up "email me a weekly briefing every Monday" and it works even when laptop is off.

### Phase 6 — Polish & Launch Prep (Weeks 16-18)

**Goal:** Production-ready quality, onboarding, and distribution.

- [ ] Onboarding flow (first-run setup wizard)
- [ ] App notarization for independent distribution
- [ ] Auto-update mechanism (Sparkle framework)
- [ ] Crash reporting and analytics (privacy-respecting)
- [ ] Comprehensive error handling and recovery
- [ ] Performance optimization (memory usage, battery impact)
- [ ] MCP client support (connect third-party MCP servers)
- [ ] Documentation and landing page
- [ ] Beta testing program

**Milestone:** App is ready for public beta.

---

## 11. Tech Stack Summary

| Layer | Technology |
|---|---|
| macOS App | Swift 5.9+, SwiftUI, AppKit |
| Local Database | SQLite via GRDB |
| Keychain | macOS Security framework |
| HTTP Client | URLSession (native) |
| HTML Parsing | SwiftSoup |
| LLM (Primary) | Anthropic Claude API (Opus, Sonnet, Haiku) |
| LLM (Secondary) | OpenAI API (GPT-4o) |
| Cloud Server | Node.js (TypeScript) + Fastify |
| Cloud Database | PostgreSQL 16 |
| Job Queue | BullMQ + Redis |
| Email Delivery | Resend or SendGrid |
| Git Integration | gh CLI (GitHub), glab CLI (GitLab) |
| Auto Updates | Sparkle framework |
| Distribution | Notarized DMG (independent) |
| CI/CD | GitHub Actions |

---

## 12. Open Questions & Decisions

1. **App name** — Needs a memorable, distinct name. Avoid anything that could conflict with existing trademarks.

2. **Pricing model** — Free app + users bring their own API keys? Or subscription with included token budget? Or hybrid?

3. **Cloud backend hosting** — Self-hosted by each user? Or a managed cloud service you operate? The latter is simpler for users but means you're running infrastructure.

4. **Multi-user / team features** — Is this a single-user personal assistant only, or could teams share agents/routines?

5. **Mobile companion** — Future iOS app for viewing results and approving decisions on the go?

6. **Voice input** — Should the command bar support voice (via macOS speech recognition or Whisper API)?

7. **Plugin / skill marketplace** — Allow third-party developers to build and share tools?

8. **Telemetry & analytics** — What (if any) usage data do you collect? Privacy-first approach recommended.