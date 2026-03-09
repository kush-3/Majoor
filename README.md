# Majoor — Your AI That Does The Work

A native macOS AI agent that lives in your menu bar and autonomously performs tasks on your behalf.

## Phase 1 — Foundation

This is the Phase 1 scaffold: menu bar app, command bar, agent loop, and file management tools.

## Setup Instructions

### Prerequisites
- macOS 14.0 (Sonoma) or later
- Xcode 15.0 or later
- An Anthropic API key (get one at https://console.anthropic.com)

### Creating the Xcode Project

1. Open Xcode → File → New → Project
2. Select **macOS** → **App**
3. Configure:
   - Product Name: `Majoor`
   - Team: Your developer team (or Personal Team)
   - Organization Identifier: `com.majoor` (or your own)
   - Interface: **SwiftUI**
   - Language: **Swift**
   - Uncheck "Include Tests" for now
4. Save the project

### Adding Source Files

1. Delete the default `ContentView.swift` and `MajoorApp.swift` that Xcode created
2. Drag the contents of `Sources/Majoor/` into your Xcode project navigator
3. Make sure "Copy items if needed" is checked
4. Ensure all `.swift` files are added to the Majoor target

### Project Configuration

1. Select the Majoor target → **General** tab:
   - Set Minimum Deployment to **macOS 14.0**

2. Select the Majoor target → **Signing & Capabilities**:
   - Add **App Sandbox** capability
   - Enable: Outgoing Connections (Client) — needed for API calls
   - Enable: User Selected File — Read/Write — needed for file operations
   - Enable: Downloads Folder — Read/Write

3. Select the Majoor target → **Info** tab:
   - Add key: `LSUIElement` → Boolean → `YES`
     (This hides the app from the Dock — menu bar apps only)

### Running

1. Build and run (⌘ + R)
2. Look for the Majoor icon in your menu bar (⚡ icon)
3. Click the icon → Settings → Enter your Anthropic API key
4. Press ⌘ + Shift + Space to open the command bar
5. Try: "List all files in my Downloads folder"

### Architecture Overview

```
Sources/Majoor/
├── MajoorApp.swift          — App entry point
├── AppDelegate.swift        — Menu bar + global shortcut setup
├── Core/
│   ├── Models.swift         — Data models (Message, Task, ToolCall)
│   ├── AgentLoop.swift      — Main agent execution loop
│   ├── LLMProvider.swift    — Protocol for LLM providers
│   ├── AnthropicProvider.swift — Claude API implementation
│   └── TaskManager.swift    — Manage running/completed tasks
├── Tools/
│   ├── ToolProtocol.swift   — Base tool protocol + registry
│   └── FileTools.swift      — File management tools
├── UI/
│   ├── StatusBarController.swift — Menu bar icon management
│   ├── CommandBarWindow.swift    — Floating command window
│   ├── CommandBarView.swift      — Command input SwiftUI view
│   ├── MainPanelView.swift       — Dropdown panel (activity + chat)
│   └── ActivityFeedView.swift    — Task history feed
├── Security/
│   └── KeychainManager.swift     — Secure API key storage
├── Settings/
│   └── SettingsView.swift        — Preferences window
└── Utils/
    └── Logger.swift              — Simple logging utility
```
