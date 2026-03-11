# Phase 3 — Memory & Intelligence (Implementation Plan)

## Status: IMPLEMENTED — NEEDS BUILD & TEST

---

## What was built

### New files created (8 files):

| File | Purpose |
|------|---------|
| `Core/Database/DatabaseManager.swift` | GRDB singleton, SQLite at ~/Library/Application Support/ai.majoor.agent/majoor.sqlite, v1 migration (3 tables) |
| `Core/Memory/MemoryModels.swift` | `Memory` struct (GRDB Record), `MemoryCategory` enum (preference/fact/context/habit) |
| `Core/Memory/MemoryStore.swift` | CRUD: save, search (keyword LIKE), allMemories, delete, deleteAll, archiveOld, touchMemory |
| `Core/Memory/MemoryRetriever.swift` | `relevantContext(for:)` — searches memories, injects into system prompt. `extractAndSaveMemories()` — saves explicit "remember" requests |
| `Core/TaskPersistence.swift` | Save/load AgentTasks to SQLite, serialize TaskSteps as JSON, deleteOldTasks |
| `Core/UsageStore.swift` | Token usage tracking per API call, aggregated by day+model. CostConfig with Opus/Sonnet/Haiku rates |
| `Core/Router/TaskClassifier.swift` | Tier 1 keyword pattern matching → TaskCategory (coding→Opus, fileManagement→Sonnet, etc.) |
| `Core/Router/ModelRouter.swift` | Maps TaskCategory → AnthropicProvider with the right model |
| `Settings/MemorySettingsView.swift` | Search/view/delete memories UI with category badges and access counts |
| `Settings/UsageSettingsView.swift` | Cost cards (today/week/month), per-model breakdown table |

### Files modified (5 files):

| File | Changes |
|------|---------|
| `AgentLoop.swift` | Classify task → route model → retrieve memories → inject into prompt → track usage → persist task → extract memories. No longer takes a `provider` param. |
| `TaskManager.swift` | Loads persisted tasks from SQLite on init. `persistTask()` method. Cleans up tasks >30 days. |
| `AppDelegate.swift` | Initializes `DatabaseManager.shared` on launch. New `AgentLoop(tools:taskManager:)` init. |
| `SettingsView.swift` | Added Memory and Usage tabs (5 tabs total). Updated Models tab to show routing. Version 0.3.0. |
| `project.pbxproj` | Removed GRDB-dynamic target (only static GRDB needed). |

---

## Architecture Flow

```
User types command → AppDelegate.handleCommand()
    │
    ├── AgentLoop.execute(userInput)
    │   ├── TaskClassifier.classify(userInput) → TaskCategory
    │   ├── ModelRouter.provider(for: category) → AnthropicProvider (Opus/Sonnet)
    │   ├── MemoryRetriever.relevantContext(for: userInput) → context string
    │   ├── systemPrompt + memoryContext → fullSystemPrompt
    │   ├── Agent loop (LLM → tools → repeat)
    │   │   └── Each API call → UsageStore.recordUsage()
    │   ├── On completion: TaskManager.persistTask() → SQLite
    │   └── On completion: MemoryRetriever.extractAndSaveMemories()
    │
    └── Notification sent
```

## Model Routing Table

| TaskCategory | Model | Trigger Keywords |
|-------------|-------|-----------------|
| coding | Opus | implement, refactor, debug, fix bug, write code, add feature, write script |
| codeReview | Opus | review code, review pr, explain this code |
| webResearchDeep | Opus | research, compare, analyze, in-depth, comprehensive |
| webResearchQuick | Sonnet | search for, look up, find out, what is, who is |
| fileManagement | Sonnet | file, folder, directory, organize, move, delete, rename |
| summarization | Sonnet | summarize, summary, brief, tldr |
| general | Sonnet | (default fallback) |

## Database Schema

Three tables in `majoor.sqlite`:
- **memories** — id, category, content, sourceTaskId, relevanceScore, createdAt, lastAccessedAt, accessCount
- **tasks** — id, userInput, status, modelUsed, stepsJson, summary, tokensUsed, costEstimate, createdAt, completedAt
- **usageStats** — id, date, model, inputTokens, outputTokens, cost, taskCount (unique on date+model)

---

## Build & Test Instructions

### Build:
Open Xcode → Build (⌘B)

### Test plan:

| Test | What to check |
|------|--------------|
| **Launch** | App launches without crash. Check Console.app for "Database ready at" log. |
| **File task** | "What's in my Downloads folder?" → Routes to Sonnet (check log) |
| **Code task** | "Write a Python script that prints hello world" → Routes to Opus (check log) |
| **Memory save** | "Remember that I prefer concise responses" → Check Settings → Memory tab |
| **Task persistence** | Run a task, quit app, relaunch → Task appears in activity feed |
| **Usage tracking** | Run tasks → Check Settings → Usage tab for costs |
| **Settings** | ⌘+, → 5 tabs: General, Models, Memory, Usage, About |

### Verify SQLite:
```
ls ~/Library/Application\ Support/ai.majoor.agent/majoor.sqlite
```

---

## Cost Rates (per 1M tokens)

| Model | Input | Output |
|-------|-------|--------|
| Opus | $15.00 | $75.00 |
| Sonnet | $3.00 | $15.00 |
| Haiku | $0.25 | $1.25 |

---

## What's Next: Phase 4 — Email & Calendar

- EventKit integration (read/create/update calendar events)
- OAuth flow for Google (Calendar + Gmail)
- Email fetching, drafting, sending tools
- Decision notifications with action buttons
