# Phase 3 — Memory & Intelligence (Implementation Plan)

## Status: NOT STARTED
## Prerequisite: User must add GRDB Swift package in Xcode before any code is written

---

## Context

Phase 1 (foundation) and Phase 2 (web/shell/git tools) are complete. The app builds and runs with 24 tools, zero warnings. The agent is stateless — every task starts from scratch, task history is lost on restart, and all tasks go to Claude Sonnet 4 regardless of complexity.

### Key decisions already made:
- **Database**: SQLite via GRDB.swift (https://github.com/groue/GRDB.swift)
- **Multi-model**: Use Opus for code tasks (user approved the cost)
- **API keys**: Hardcoded in `APIConfig.swift` (personal use only)
- **Sandbox**: Disabled (Process/shell access available)
- **Project uses**: `PBXFileSystemSynchronizedRootGroup` — new files auto-discovered by Xcode, no manual pbxproj edits needed
- **Swift concurrency**: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — all new types need explicit `nonisolated` if they do off-main-thread work

---

## Architecture Overview

```
AgentLoop.execute(userInput)
    │
    ├── 1. TaskClassifier.classify(userInput) → TaskCategory
    ├── 2. ModelRouter.route(category) → LLMProvider (Opus/Sonnet/Haiku)
    ├── 3. MemoryRetriever.relevantMemories(for: userInput) → [Memory]
    ├── 4. Build system prompt + inject memories
    ├── 5. Execute agent loop with routed model
    ├── 6. On completion: persist task to SQLite
    └── 7. On completion: extract & save new memories
```

---

## File Plan

### New files to create:

```
Majoor/
├── Core/
│   ├── Database/
│   │   └── DatabaseManager.swift      — GRDB setup, migrations, shared db queue
│   ├── Memory/
│   │   ├── MemoryStore.swift          — CRUD for memories table
│   │   ├── MemoryRetriever.swift      — Query relevant memories for a task
│   │   └── MemoryModels.swift         — Memory struct (GRDB Record)
│   ├── Router/
│   │   ├── TaskClassifier.swift       — Classify user input into task category
│   │   └── ModelRouter.swift          — Map category → model → LLMProvider
│   └── TaskPersistence.swift          — Save/load AgentTasks to SQLite
├── Settings/
│   └── MemorySettingsView.swift       — View/search/delete memories UI
```

### Files to modify:

| File | Changes |
|------|---------|
| `AgentLoop.swift` | Inject memories into system prompt, use routed model, persist tasks on completion, extract memories |
| `TaskManager.swift` | Load tasks from SQLite on init, save on changes |
| `AppDelegate.swift` | Initialize DatabaseManager on launch |
| `AnthropicProvider.swift` | Support creating providers with different models (Opus/Sonnet/Haiku) |
| `APIConfig.swift` | Add model name constants |
| `SettingsView.swift` | Add Memory tab, add Usage/Cost tab |
| `Models.swift` | Add TaskCategory enum, add cost calculation helpers |

---

## Milestone 1: Database Layer + GRDB Setup

### User action required:
Open Xcode → File → Add Package Dependencies → paste `https://github.com/groue/GRDB.swift` → add to Majoor target.

### DatabaseManager.swift
```swift
// Location: Majoor/Core/Database/DatabaseManager.swift
// Singleton, nonisolated, manages the GRDB DatabaseQueue
// Database file: ~/Library/Application Support/ai.majoor.agent/majoor.sqlite

// Tables to create in v1 migration:
// 1. memories — id, category, content, source_task_id, relevance_score, created_at, last_accessed_at, access_count
// 2. tasks — id, user_input, status, model_used, steps_json, tokens_used, cost_estimate, created_at, completed_at
// 3. usage_stats — id, date, model, input_tokens, output_tokens, cost, task_count
```

### Schema (from PRD):
```sql
CREATE TABLE memories (
    id TEXT PRIMARY KEY,
    category TEXT NOT NULL,          -- 'preference', 'fact', 'context', 'habit'
    content TEXT NOT NULL,
    source_task_id TEXT,
    relevance_score REAL DEFAULT 1.0,
    created_at TEXT NOT NULL,
    last_accessed_at TEXT NOT NULL,
    access_count INTEGER DEFAULT 0
);

CREATE TABLE tasks (
    id TEXT PRIMARY KEY,
    user_input TEXT NOT NULL,
    status TEXT NOT NULL,
    model_used TEXT,
    steps_json TEXT,
    tokens_used INTEGER DEFAULT 0,
    cost_estimate REAL DEFAULT 0.0,
    created_at TEXT NOT NULL,
    completed_at TEXT
);

CREATE TABLE usage_stats (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    date TEXT NOT NULL,
    model TEXT NOT NULL,
    input_tokens INTEGER DEFAULT 0,
    output_tokens INTEGER DEFAULT 0,
    cost REAL DEFAULT 0.0,
    task_count INTEGER DEFAULT 0,
    UNIQUE(date, model)
);
```

---

## Milestone 2: Task Persistence

### TaskPersistence.swift
- `saveTask(_ task: AgentTask)` — serialize task (including steps as JSON) and upsert to SQLite
- `loadRecentTasks(limit: Int) -> [AgentTask]` — load last N tasks for activity feed
- `loadTask(id: UUID) -> AgentTask?` — load specific task
- `deleteOldTasks(olderThan days: Int)` — cleanup tasks older than N days

### TaskManager.swift changes:
- On `init`: load recent tasks from SQLite
- On `addTask`: also persist to SQLite
- On task status change: update SQLite record
- Keep in-memory array for UI reactivity, SQLite as source of truth on restart

### TaskStep serialization:
- Encode `[TaskStep]` as JSON string for the `steps_json` column
- Decode back on load

---

## Milestone 3: Memory Store & Retrieval

### MemoryModels.swift
```swift
struct Memory: Codable, Identifiable {
    let id: String              // UUID string
    var category: MemoryCategory
    var content: String
    var sourceTaskId: String?
    var relevanceScore: Double
    var createdAt: Date
    var lastAccessedAt: Date
    var accessCount: Int
}

enum MemoryCategory: String, Codable, CaseIterable {
    case preference  // "user prefers concise emails"
    case fact        // "Sarah = PM at Acme Corp"
    case context     // "myapp uses Next.js + TypeScript"
    case habit       // "user organizes Downloads on Fridays"
}
```

### MemoryStore.swift
- `save(_ memory: Memory)` — insert or update
- `search(query: String, limit: Int) -> [Memory]` — keyword search via LIKE
- `recentMemories(limit: Int) -> [Memory]` — most recently accessed
- `allMemories() -> [Memory]` — for settings UI
- `delete(id: String)` — remove a memory
- `deleteAll()` — clear all memories
- `archiveOld(days: Int)` — memories not accessed in N days get archived (low relevance score)
- `touchMemory(id: String)` — update last_accessed_at and increment access_count

### MemoryRetriever.swift
- `relevantMemories(for userInput: String, limit: Int = 5) -> [Memory]`
- Strategy: extract keywords from user input, search memories table, rank by:
  1. Keyword match count
  2. Recency (last_accessed_at)
  3. Access frequency (access_count)
  4. Relevance score
- Return top N memories formatted as context string for system prompt

### AgentLoop.swift changes:
- Before building messages, call `MemoryRetriever.relevantMemories(for: userInput)`
- Append to system prompt:
  ```
  CONTEXT FROM MEMORY:
  - [preference] User prefers concise summaries
  - [context] ~/code/myapp is a Next.js project with TypeScript
  - [fact] Sarah (sarah@acme.com) is the project manager
  ```
- After task completion: optionally have the LLM extract any new memories worth saving (add a brief extraction prompt at the end of the task)

---

## Milestone 4: Token Tracking & Cost Display

### Cost constants (add to APIConfig.swift or a new CostConfig):
```swift
struct CostConfig {
    // Per 1M tokens (input / output)
    static let opusInput = 15.0
    static let opusOutput = 75.0
    static let sonnetInput = 3.0
    static let sonnetOutput = 15.0
    static let haikuInput = 0.25
    static let haikuOutput = 1.25
}
```

### Usage tracking:
- After each API call, record input_tokens, output_tokens, model to usage_stats table
- Aggregate by day + model
- `UsageStore.swift`:
  - `recordUsage(model: String, inputTokens: Int, outputTokens: Int)`
  - `todayUsage() -> (tokens: Int, cost: Double)`
  - `weekUsage() -> (tokens: Int, cost: Double)`
  - `monthUsage() -> (tokens: Int, cost: Double)`
  - `usageByModel(days: Int) -> [(model: String, tokens: Int, cost: Double)]`

### Settings UI — new "Usage" tab:
- Today / This Week / This Month cost breakdown
- Per-model breakdown (Opus vs Sonnet vs Haiku)
- Total tasks run
- Average cost per task

---

## Milestone 5: Multi-Model Router

### TaskClassifier.swift

**Tier 1 — Pattern matching (instant, free):**
```swift
enum TaskCategory: String {
    case coding          // → Opus
    case codeReview      // → Opus
    case webResearchDeep // → Opus
    case webResearchQuick // → Sonnet
    case fileManagement  // → Sonnet
    case email           // → Sonnet (future)
    case calendar        // → Sonnet (future)
    case summarization   // → Sonnet
    case general         // → Sonnet (default)
}
```

Keyword patterns:
- **coding**: code, function, implement, refactor, PR, git, debug, build, fix bug, write script, add feature
- **codeReview**: review, PR, diff, what changed
- **webResearchDeep**: research, compare, analyze, in-depth, comprehensive
- **webResearchQuick**: search, find, look up, what is, who is
- **fileManagement**: file, folder, directory, organize, move, delete, rename, download
- **summarization**: summarize, summary, brief, tldr

**Tier 2 — Haiku classifier (fallback for ambiguous):**
- Send user input to Claude Haiku with a classification prompt
- Costs < $0.001 per classification
- Only triggered if Tier 1 confidence is low (no keyword matches)

### ModelRouter.swift
```swift
struct ModelRouter {
    static func provider(for category: TaskCategory) -> AnthropicProvider {
        switch category {
        case .coding, .codeReview, .webResearchDeep:
            return AnthropicProvider(apiKey: APIConfig.claudeAPIKey, model: "claude-opus-4-20250514")
        case .general, .fileManagement, .webResearchQuick, .summarization, .email, .calendar:
            return AnthropicProvider(apiKey: APIConfig.claudeAPIKey, model: "claude-sonnet-4-20250514")
        }
    }
}
```

### AgentLoop.swift changes:
- Replace fixed provider with routed provider:
  ```swift
  let category = TaskClassifier.classify(userInput)
  let provider = ModelRouter.provider(for: category)
  // ... use this provider for the task
  ```
- Log which model was selected and why

### AnthropicProvider.swift changes:
- No structural changes needed — already accepts model as init param
- Just need to create multiple instances with different model strings

---

## Milestone 6: Memory Management UI

### MemorySettingsView.swift (new tab in Settings)
- Searchable list of all memories
- Each memory shows: category badge, content, created date, access count
- Swipe-to-delete or delete button per memory
- "Clear All Memories" button with confirmation
- Search field to filter memories
- Memory count display

### SettingsView.swift changes:
- Add "Memory" tab (MemorySettingsView)
- Add "Usage" tab (UsageSettingsView)
- Total tabs: General, Models, Memory, Usage, About

---

## Testing Plan

After each milestone, build and test:

| Milestone | Test |
|-----------|------|
| M1 | App launches without crash, SQLite file created in ~/Library/Application Support/ |
| M2 | Run a task, quit app, relaunch — task appears in activity feed |
| M3 | Run "remember that I prefer dark mode" → check memory saved. Run another task → check memory injected into context |
| M4 | Run a few tasks → check Usage tab shows token counts and costs |
| M5 | "fix the bug in parser.ts" → should route to Opus. "what's in my downloads" → should route to Sonnet |
| M6 | Open Settings → Memory tab → see saved memories, delete one, search |

---

## Estimated scope:
- ~8 new files, ~1200-1500 LOC
- ~6 files modified
- GRDB is the only new dependency
