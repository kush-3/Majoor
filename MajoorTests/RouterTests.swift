// RouterTests.swift
// MajoorTests — Router v2: the privacy preset, per-tool data classes, tier
// selection, the loop's tool gate, and usage attribution by tier. No real
// UserDefaults, Keychain, network or database.

import Foundation
import GRDB
import Testing
@testable import Majoor

// MARK: - Helpers

/// A throwaway defaults suite, removed when the test ends.
nonisolated final class TestDefaults: @unchecked Sendable {
    let name = "MajoorTests.Router.\(UUID().uuidString)"
    let defaults: UserDefaults
    init() { defaults = UserDefaults(suiteName: name)! }
    deinit { defaults.removePersistentDomain(forName: name) }
}

nonisolated final class LockedBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ item: T) { lock.withLock { items.append(item) } }
    var all: [T] { lock.withLock { items } }
}

/// A tool that returns email bodies: `.emailBody`, never allowed on Claude under Strict.
nonisolated struct PersonalTool: AgentTool {
    let name = "fetch_emails"
    let description = "Returns email bodies"
    let parameters = [ToolParameter(name: "query", description: "Search")]
    let requiredParameters: [String] = []
    let requiresConfirmation = false
    let isReadOnly = true
    let dataClass: DataClass = .emailBody
    let executed: LockedBox<String>

    func execute(arguments: [String: String]) async throws -> ToolResult {
        executed.append(arguments["query"] ?? "")
        return ToolResult(success: true, output: "Subject: hi\n\nsecret body")
    }
}

nonisolated func toolCall(_ name: String, _ arguments: [String: String]) -> LLMResponse {
    let id = "call-" + UUID().uuidString
    return .toolCalls(
        [ToolCall(id: id, toolName: name, arguments: arguments, rawInputJSON: nil)],
        rawContent: [AnthropicContentBlock(type: "tool_use", text: nil, id: id, name: name, input: nil, toolUseId: nil, content: nil, isError: nil)])
}

/// Like `makeManager` in SessionLoopTests, but with a full routing decision.
func makeRoutedManager(tools: [any AgentTool], routing: @escaping TierRoutingRouter, persist: SnapshotBox? = nil) async -> SessionManager {
    let manager = SessionManager()
    let loop = AgentLoop(tools: tools, routing: routing)
    var persistClosure: (@Sendable (TaskSnapshot) -> Void)? = nil
    if let persist { persistClosure = { snapshot in persist.append(snapshot) } }
    await manager.configure(loop: loop, store: nil, persistTask: persistClosure, notify: nil, maxConcurrent: 3,
                            approvalTimeout: 600, permissionMode: .standard, sessionBudget: nil)
    return manager
}

/// A router with injected settings, preset, classifier and frontier provider.
nonisolated struct RouterFixture: Sendable {
    let router: TierRouter
    let settings: TierSettingsStore
    let presets: PrivacyPresetStore
    let classifier: ScriptedProvider?
    let frontier: ScriptedProvider
    let frontierCategories: LockedBox<TaskCategory>
    let holder: TestDefaults

    init(preset: PrivacyPreset = .strict, localModel: String? = nil, privateModel: String? = nil,
         override: ProviderTier? = nil, classifier: ScriptedProvider? = nil) {
        let holder = TestDefaults()
        let settings = TierSettingsStore(defaults: holder.defaults, secrets: MemorySecrets())
        if let localModel { settings.save(TierEndpoint(baseURL: "http://127.0.0.1:11434/v1", model: localModel), for: .local) }
        if let privateModel { settings.save(TierEndpoint(baseURL: "https://p.example.com/v1", model: privateModel, apiKey: "k"), for: .privateCloud) }
        settings.routingOverride = override
        let presets = PrivacyPresetStore(defaults: holder.defaults)
        presets.preset = preset
        let frontier = ScriptedProvider([.text("frontier")])
        let categories = LockedBox<TaskCategory>()
        self.router = TierRouter(settings: settings, presets: presets,
                                 classifierProvider: { classifier },
                                 frontierProvider: { category in categories.append(category); return frontier })
        self.settings = settings
        self.presets = presets
        self.classifier = classifier
        self.frontier = frontier
        self.frontierCategories = categories
        self.holder = holder
    }
}

// MARK: - Preset

@Suite("PrivacyPreset")
struct PrivacyPresetTests {

    @Test("Strict ceilings match plan §3a")
    func strictTable() {
        let strict = PrivacyPreset.strict
        for dataClass in [DataClass.code, .repoContext, .web] { #expect(strict.ceiling(for: dataClass) == .frontier, "\(dataClass)") }
        for dataClass in [DataClass.emailMeta, .emailBody, .contacts, .calendar, .messages, .files] { #expect(strict.ceiling(for: dataClass) == .privateCloud, "\(dataClass)") }
        for dataClass in [DataClass.location, .finance, .majoorState] { #expect(strict.ceiling(for: dataClass) == .local, "\(dataClass)") }
        #expect(strict.ceilings.count == DataClass.allCases.count)
    }

    @Test("allows() compares exposure: a class may reach its ceiling and anything more private")
    func allows() {
        let strict = PrivacyPreset.strict
        #expect(strict.allows(.code, on: .frontier))
        #expect(strict.allows(.code, on: .local))
        #expect(!strict.allows(.emailBody, on: .frontier))
        #expect(strict.allows(.emailBody, on: .privateCloud))
        #expect(strict.allows(.emailBody, on: .local))
        #expect(!strict.allows(.majoorState, on: .privateCloud))
        #expect(strict.allows(.majoorState, on: .local))
        #expect(strict.allowedClasses(on: .frontier) == [.code, .repoContext, .web])
        #expect(strict.allowedClasses(on: .local) == Set(DataClass.allCases))
        #expect(PrivacyPreset.claudeOnly.allowedClasses(on: .frontier) == Set(DataClass.allCases))
    }

    @Test("the store defaults to Strict and round-trips the choice")
    func store() {
        let holder = TestDefaults()
        let store = PrivacyPresetStore(defaults: holder.defaults)
        #expect(store.preset == .strict)
        store.preset = .claudeOnly
        #expect(store.preset == .claudeOnly)
        #expect(holder.defaults.string(forKey: PrivacyPresetStore.defaultsKey) == "claudeOnly")
        holder.defaults.set("nonsense", forKey: PrivacyPresetStore.defaultsKey)
        #expect(store.preset == .strict)
        #expect(PrivacyPreset.named("strict") == .strict)
        #expect(PrivacyPreset.named("x") == nil)
    }
}

// MARK: - Tool classes

@Suite("Tool data classes")
struct ToolDataClassTests {

    @Test("every registered tool declares the class the plan assigns")
    func registry() {
        let byName = Dictionary(uniqueKeysWithValues: ToolRegistry.defaultTools().map { ($0.name, $0.dataClass) })
        #expect(byName.count == 40)
        #expect(byName["fetch_emails"] == .emailMeta)
        #expect(byName["search_emails"] == .emailMeta)
        #expect(byName["read_email"] == .emailBody)
        #expect(byName["send_email"] == .emailBody)
        #expect(byName["reply_to_email"] == .emailBody)
        #expect(byName["draft_email"] == .emailBody)
        #expect(byName["read_calendar_events"] == .calendar)
        #expect(byName["delete_calendar_event"] == .calendar)
        #expect(byName["save_memory"] == .majoorState)
        #expect(byName["search_memory"] == .majoorState)
        #expect(byName["create_reminder"] == .majoorState)
        #expect(byName["git_status"] == .code)
        #expect(byName["execute_shell"] == .code)
        #expect(byName["run_tests"] == .code)
        #expect(byName["read_project_structure"] == .code)
        #expect(byName["web_search"] == .web)
        #expect(byName["fetch_webpage"] == .web)
        #expect(byName["read_file"] == .files)
        #expect(byName["search_files"] == .files)
        #expect(EchoTool().dataClass == .files)   // the protocol default
    }

    @Test("MCP tools are classed by server")
    func mcp() {
        func bridge(_ server: String) -> MCPToolBridge {
            MCPToolBridge(serverName: server, tool: MCPToolDefinition(name: "do_thing", description: "x", inputSchema: nil))
        }
        #expect(bridge("github").dataClass == .code)
        #expect(bridge("slack").dataClass == .messages)
        #expect(bridge("notion").dataClass == .files)
        #expect(bridge("linear").dataClass == .files)
        #expect(bridge("unknown").dataClass == .files)
    }
}

// MARK: - TierRouter

@Suite("TierRouter")
struct TierRouterTests {

    @Test("category → tier per plan §3b")
    func requestedTier() {
        #expect(TierRouter.requestedTier(for: .coding) == .frontier)
        #expect(TierRouter.requestedTier(for: .codeReview) == .frontier)
        #expect(TierRouter.requestedTier(for: .webResearchDeep) == .frontier)
        #expect(TierRouter.requestedTier(for: .emailCalendar) == .privateCloud)
        #expect(TierRouter.requestedTier(for: .fileManagement) == .privateCloud)
        #expect(TierRouter.requestedTier(for: .summarization) == .privateCloud)
        #expect(TierRouter.requestedTier(for: .webResearchQuick) == .privateCloud)
        #expect(TierRouter.requestedTier(for: .general) == .privateCloud)
    }

    @Test("a coding task goes to Claude with code, web and (as a coding exception) file tools")
    func coding() async throws {
        let fixture = RouterFixture(preset: .strict, privateModel: "p-model")
        let decision = await fixture.router.route("implement the parser and refactor the tests")
        #expect(decision.tier == .frontier)
        #expect(decision.provider.model == fixture.frontier.model)
        #expect(fixture.frontierCategories.all == [.coding])
        let gate = try #require(decision.gate)
        #expect(gate.allows(.code))
        #expect(gate.allows(.web))
        #expect(gate.allows(.files))
        #expect(!gate.allows(.emailBody))
        #expect(!gate.allows(.majoorState))
        #expect(decision.toolSets.contains("github"))
        #expect(decision.note?.contains("coding task") == true)
    }

    @Test("an email task goes to the private tier when it is configured")
    func emailToPrivate() async throws {
        let fixture = RouterFixture(preset: .strict, privateModel: "p-model")
        let decision = await fixture.router.route("summarize my inbox and list unread email")
        #expect(decision.tier == .privateCloud)
        let provider = try #require(decision.provider as? OpenAICompatibleProvider)
        #expect(provider.tier == .privateCloud)
        #expect(provider.model == "p-model")
        #expect(fixture.frontierCategories.all.isEmpty)
        let gate = try #require(decision.gate)
        #expect(gate.allows(.emailBody))
        #expect(gate.allows(.files))
        #expect(!gate.allows(.majoorState))
        #expect(!gate.allows(.location))
    }

    @Test("Strict with no private tier: Claude runs the task with personal tools withheld")
    func strictNoPrivate() async throws {
        let fixture = RouterFixture(preset: .strict)
        let decision = await fixture.router.route("summarize my inbox and list unread email")
        #expect(decision.tier == .frontier)
        #expect(decision.provider.model == fixture.frontier.model)
        let gate = try #require(decision.gate)
        #expect(!gate.allows(.emailBody))
        #expect(!gate.allows(.files))
        #expect(gate.allows(.code))
        #expect(decision.note?.contains("not configured") == true)
        let refusal = gate.refusal(toolName: "fetch_emails", dataClass: .emailBody)
        #expect(refusal.hasPrefix("Error:"))
        #expect(refusal.contains("fetch_emails") && refusal.contains("tier F") && refusal.contains("tier P") && refusal.contains("Settings ▸ Models"))
    }

    @Test("Claude-for-everything with no private tier: Claude, every tool")
    func claudeOnlyNoPrivate() async throws {
        let fixture = RouterFixture(preset: .claudeOnly)
        let decision = await fixture.router.route("summarize my inbox and list unread email")
        #expect(decision.tier == .frontier)
        let gate = try #require(decision.gate)
        #expect(gate.allowedClasses == Set(DataClass.allCases))
    }

    @Test("a coding task that names a personal source is downgraded to the private tier")
    func downgrade() async throws {
        let fixture = RouterFixture(preset: .strict, privateModel: "p-model")
        let input = "implement the parser, refactor it and add tests, then email me the summary"
        #expect(TaskClassifier.classifyWithConfidence(input).category == .coding)
        #expect(TaskClassifier.mentionsPersonalSource(input))
        let decision = await fixture.router.route(input)
        #expect(decision.tier == .privateCloud)
        #expect((decision.provider as? OpenAICompatibleProvider)?.model == "p-model")
        #expect(decision.note?.contains("downgraded") == true)
        #expect(fixture.frontierCategories.all.isEmpty)
    }

    @Test("ambiguous input is classified on tier L, never on Claude")
    func slowPath() async throws {
        let classifier = ScriptedProvider([.text(#"{"model": "opus", "tools": ["local", "github"]}"#)])
        let fixture = RouterFixture(preset: .strict, localModel: "qwen3:8b", privateModel: "p-model", classifier: classifier)
        let decision = await fixture.router.route("hello there")
        #expect(classifier.calls == 1)
        #expect(decision.tier == .frontier)
        #expect(fixture.frontierCategories.all == [.coding])
        #expect(Set(decision.toolSets) == ["local", "github"])
        #expect(decision.note?.contains("tier L") == true)
    }

    @Test("without tier L the keyword result stands and Claude is not asked")
    func slowPathNoLocal() async throws {
        let fixture = RouterFixture(preset: .strict, privateModel: "p-model")
        let decision = await fixture.router.route("hello there")
        #expect(decision.tier == .privateCloud)
        #expect(fixture.frontierCategories.all.isEmpty)
        #expect(decision.note?.contains("tier L not configured") == true)
    }

    @Test("the routing override wins and skips the classifier")
    func override() async throws {
        let classifier = ScriptedProvider([.text(#"{"model": "opus", "tools": ["local"]}"#)])
        let fixture = RouterFixture(preset: .strict, localModel: "qwen3:8b", override: .local, classifier: classifier)
        let decision = await fixture.router.route("hello there")
        #expect(classifier.calls == 0)
        #expect(decision.tier == .local)
        #expect((decision.provider as? OpenAICompatibleProvider)?.tier == .local)
        #expect(decision.gate?.allowedClasses == Set(DataClass.allCases))
        #expect(decision.note?.contains("override") == true)
    }
}

// MARK: - Loop gate

@Suite("Loop tool gate", .serialized)
struct LoopGateTests {

    @Test("a withheld tool is answered with the refusal and never executed; the task still completes")
    func withheld() async throws {
        let executed = LockedBox<String>()
        let personal = PersonalTool(executed: executed)
        let provider = ScriptedProvider([toolCall("fetch_emails", ["query": "unread"]), toolCall("echo", ["text": "ok"]), .text("Done without email.")])
        let gate = ToolGate(tier: .frontier, preset: .strict, allowedClasses: PrivacyPreset.strict.allowedClasses(on: .frontier).union([.files]))
        let box = SnapshotBox()
        let manager = await makeRoutedManager(tools: [personal, EchoTool()], routing: { _ in
            RoutingDecision(provider: provider, toolSets: [], tier: .frontier, gate: gate, note: "test")
        }, persist: box)
        let info = try #require(await manager.submit(input: "summarize my inbox", origin: .panel, trust: .local))
        let final = try #require(await terminal(manager, info.id))
        #expect(final.state == .completed)
        #expect(final.summary == "Done without email")
        #expect(executed.all.isEmpty)
        #expect(provider.calls == 3)
        let steps = box.all.first?.steps ?? []
        let refusal = steps.first { $0.description == "Result from fetch_emails" }
        #expect(refusal?.detail?.contains("unavailable on tier F") == true)
        #expect(steps.first { $0.description == "Result from echo" }?.detail == "echo: ok")
    }

    @Test("a decision without a gate leaves every tool available")
    func ungated() async throws {
        let executed = LockedBox<String>()
        let personal = PersonalTool(executed: executed)
        let provider = ScriptedProvider([toolCall("fetch_emails", ["query": "all"]), .text("Read it.")])
        let manager = await makeRoutedManager(tools: [personal], routing: { _ in RoutingDecision(provider: provider, toolSets: []) })
        let info = try #require(await manager.submit(input: "read my email", origin: .panel, trust: .local))
        let final = try #require(await terminal(manager, info.id))
        #expect(final.state == .completed)
        #expect(executed.all == ["all"])
    }
}

// MARK: - Usage by tier

@Suite("Usage tiers")
struct UsageTierTests {

    private func temporaryDatabase() throws -> (queue: DatabaseQueue, path: String) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("majoor-router-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("majoor.sqlite").path
        return (try DatabaseManager.openAndMigrate(path: path), path)
    }

    @Test("migration v8 adds a tier column that defaults to frontier for old rows")
    func migration() throws {
        let (queue, _) = try temporaryDatabase()
        let columns = try queue.read { db in try Row.fetchAll(db, sql: "PRAGMA table_info(usageStats)").map { $0["name"] as String } }
        #expect(columns.contains("tier"))
        try queue.write { db in
            try db.execute(sql: "INSERT INTO usageStats (date, model, inputTokens, outputTokens, cost, taskCount) VALUES ('2026-01-01', 'claude-sonnet-5', 10, 5, 0.1, 1)")
        }
        let record = try queue.read { db in try UsageRecord.fetchOne(db) }
        #expect(record?.tier == "frontier")
        let applied = try queue.read { db in try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations") }
        #expect(applied.contains("v8_usage_tier"))
    }

    @Test("recordUsage stores the tier and prices by it")
    func record() throws {
        let (queue, _) = try temporaryDatabase()
        let store = UsageStore(db: queue)
        store.recordUsage(model: "qwen3:8b", inputTokens: 1_000_000, outputTokens: 1_000_000, tier: .local)
        store.recordUsage(model: ModelRouter.opusModel, inputTokens: 1_000_000, outputTokens: 0, tier: .frontier)
        store.recordUsage(model: ModelRouter.opusModel, inputTokens: 1_000_000, outputTokens: 0, tier: .frontier)
        let rows = try queue.read { db in try UsageRecord.order(Column("model")).fetchAll(db) }
        #expect(rows.count == 2)
        let local = try #require(rows.first { $0.model == "qwen3:8b" })
        #expect(local.tier == "local")
        #expect(local.cost == 0)
        let opus = try #require(rows.first { $0.model == ModelRouter.opusModel })
        #expect(opus.tier == "frontier")
        #expect(opus.cost == CostConfig.opusInput * 2)
        #expect(opus.taskCount == 2)
        let breakdown = store.usageByModel(days: 1)
        #expect(breakdown.count == 2)
        #expect(breakdown.first?.tier == .frontier)   // sorted by cost
        #expect(breakdown.last?.tier == .local)
        #expect(store.todayUsage().totalCost == CostConfig.opusInput * 2)
    }

    @Test("the price table: L is free, P is the configured rate, F is Claude's table")
    func prices() {
        #expect(CostConfig.estimateCost(model: "qwen3:8b", inputTokens: 1_000_000, outputTokens: 1_000_000, tier: .local) == 0)
        #expect(CostConfig.estimateCost(model: "llama", inputTokens: 1_000_000, outputTokens: 2_000_000, tier: .privateCloud, privateRates: (0.9, 0.9)) == 0.9 * 3)
        #expect(CostConfig.estimateCost(model: "llama", inputTokens: 1_000_000, outputTokens: 0, tier: .privateCloud, privateRates: (0, 0)) == 0)
        #expect(CostConfig.estimateCost(model: ModelRouter.opusModel, inputTokens: 1_000_000, outputTokens: 1_000_000, tier: .frontier) == CostConfig.opusInput + CostConfig.opusOutput)
        #expect(CostConfig.estimateCost(model: ModelRouter.haikuModel, inputTokens: 0, outputTokens: 1_000_000, tier: .frontier) == CostConfig.haikuOutput)
        #expect(CostConfig.frontierRates(for: ModelRouter.sonnetModel) == (CostConfig.sonnetInput, CostConfig.sonnetOutput))
    }

    @Test("a model name resolves to its tier from the settings")
    func tierForModel() {
        let holder = TestDefaults()
        let store = TierSettingsStore(defaults: holder.defaults, secrets: MemorySecrets())
        #expect(store.tier(forModel: ModelRouter.sonnetModel) == .frontier)
        #expect(store.tier(forModel: "qwen3:8b") == .privateCloud)   // unknown: the costlier guess
        store.save(TierEndpoint(baseURL: "http://127.0.0.1:11434/v1", model: "qwen3:8b"), for: .local)
        #expect(store.tier(forModel: "qwen3:8b") == .local)
        store.privateRates = (0.2, 0.8)
        #expect(store.privateRates == (0.2, 0.8))
    }
}
