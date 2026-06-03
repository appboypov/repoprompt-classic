import XCTest
@_spi(TestSupport) @testable import RepoPrompt

final class RecommendationProfilesTests: XCTestCase {
	private var temporaryDirectories: [URL] = []
	private var userDefaultsSuites: [String] = []
	private var retainedAPISettings: [APISettingsViewModel] = []

	override func setUp() {
		super.setUp()
		AgentACPModelRegistry.shared.test_reset(providerID: .gemini)
	}

	override func tearDown() {
		AgentACPModelRegistry.shared.test_reset(providerID: .gemini)
		for directory in temporaryDirectories {
			try? FileManager.default.removeItem(at: directory)
		}
		for suite in userDefaultsSuites {
			UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
		}
		temporaryDirectories = []
		userDefaultsSuites = []
		retainedAPISettings = []
		super.tearDown()
	}

	func testBestPracticeProfilesUseGPT55Recommendations() {
		XCTAssertEqual(BestPracticeProfiles.versionCode, 202607)
		XCTAssertEqual(BestPracticeProfiles.tableTitle, "Best Models by Use Case (GPT-5.5)")
		XCTAssertEqual(BestPracticeProfiles.bestAgent.modelLabel, "GPT-5.5 Medium")
		XCTAssertEqual(BestPracticeProfiles.bestAgent.accessLabel, "Codex CLI")
		XCTAssertEqual(BestPracticeProfiles.bestAgent.modelString, "gpt-5.5-medium")
		XCTAssertEqual(BestPracticeProfiles.bestAgent.agentModel, .gpt55CodexMedium)
		XCTAssertEqual(BestPracticeProfiles.bestPlanning.modelLabel, "GPT-5.5 Pro")
		XCTAssertEqual(BestPracticeProfiles.bestPlanning.accessLabel, "OpenAI API / ChatGPT Pro export")
		XCTAssertEqual(BestPracticeProfiles.bestPlanning.modelString, "gpt-5.5-pro")
		XCTAssertEqual(BestPracticeProfiles.bestInAppPlanningReview.modelLabel, "GPT-5.5 High")
		XCTAssertEqual(BestPracticeProfiles.bestInAppPlanningReview.accessLabel, "Codex CLI")
		XCTAssertEqual(BestPracticeProfiles.bestInAppPlanningReview.modelString, AIModel.codexCliGpt55CodexHigh.rawValue)
		XCTAssertEqual(BestPracticeProfiles.bestInAppPlanningReview.agentModel, .gpt55CodexHigh)
		XCTAssertEqual(BestPracticeProfiles.bestContextBuilder.agentModel, .gpt55CodexLow)
		XCTAssertEqual(BestPracticeProfiles.bestContextBuilder.modelString, "gpt-5.5-low")
	}

	func testBestPracticeProfileCopyUsesPublicGPT55CodexLabels() {
		let userFacingStrings = BestPracticeProfiles.all.flatMap { useCase in
			[useCase.title, useCase.modelLabel, useCase.accessLabel] + useCase.strengths
		} + [
			BestPracticeProfiles.claudeStrengths,
			BestPracticeProfiles.gpt5HighStrengths,
			BestPracticeProfiles.geminiStrengths,
			BestPracticeProfiles.codexVsOpenAIExplanation,
			BestPracticeProfiles.contextBuilderRationale,
			BestPracticeProfiles.contextWindowNote,
			BestPracticeProfiles.codexHarnessNote,
		]

		XCTAssertTrue(userFacingStrings.contains { $0.localizedCaseInsensitiveContains("GPT-5.5") })
		XCTAssertTrue(userFacingStrings.contains { $0.localizedCaseInsensitiveContains("Codex CLI") })
	}

	func testCodexExecAgentModelsIncludeGPT55Variants() {
		let models = AgentModel.modelsForAgent(.codexExec)

		XCTAssertTrue(models.contains(.gpt55CodexLow))
		XCTAssertTrue(models.contains(.gpt55CodexMedium))
		XCTAssertTrue(models.contains(.gpt55CodexHigh))
		XCTAssertTrue(models.contains(.gpt55CodexXHigh))
	}

	func testCodexExecAgentModelsIncludeGPT54Variants() {
		let models = AgentModel.modelsForAgent(.codexExec)

		XCTAssertTrue(models.contains(.gpt54Low))
		XCTAssertTrue(models.contains(.gpt54Medium))
		XCTAssertTrue(models.contains(.gpt54High))
		XCTAssertTrue(models.contains(.gpt54XHigh))
	}

	func testCodexExecAgentModelsIncludeGPT54MiniVariants() {
		let models = AgentModel.modelsForAgent(.codexExec)

		XCTAssertTrue(models.contains(.gpt54MiniLow))
		XCTAssertTrue(models.contains(.gpt54MiniMedium))
		XCTAssertTrue(models.contains(.gpt54MiniHigh))
	}

	func testGeminiAgentModelsPrefer3SeriesBeforeLegacy25() throws {
		let models = AgentModel.modelsForAgent(.gemini)

		XCTAssertEqual(Array(models.prefix(3)), [.defaultModel, .gemini3FlashPreview, .geminiPro3p1Preview])
		XCTAssertLessThan(
			try XCTUnwrap(models.firstIndex(of: .gemini3FlashPreview)),
			try XCTUnwrap(models.firstIndex(of: .geminiFlash25))
		)
		XCTAssertLessThan(
			try XCTUnwrap(models.firstIndex(of: .geminiPro3p1Preview)),
			try XCTUnwrap(models.firstIndex(of: .geminiPro25))
		)
	}

	func testExploreTaskLabelPrefersCodexGPT55LowBeforeClaudeSonnetHigh() throws {
		let availability = AgentModelCatalog.AvailabilityContext(
			claudeCodeAvailable: true,
			codexAvailable: true,
			geminiAvailable: false,
			openCodeAvailable: false,
			cursorAvailable: false,
			zaiConfigured: false
		)

		let resolved = try XCTUnwrap(AgentModelCatalog.resolveTaskLabelKind(.explore, availability: availability))

		XCTAssertEqual(resolved.agent, .codexExec)
		XCTAssertEqual(resolved.modelRaw, AgentModel.gpt55CodexLow.rawValue)
	}

	func testExploreTaskLabelUsesGemini30FlashWhenGeminiIsOnlyAvailable() throws {
		let availability = AgentModelCatalog.AvailabilityContext(
			claudeCodeAvailable: false,
			codexAvailable: false,
			geminiAvailable: true,
			openCodeAvailable: false,
			cursorAvailable: false,
			zaiConfigured: false
		)

		let resolved = try XCTUnwrap(AgentModelCatalog.resolveTaskLabelKind(.explore, availability: availability))

		XCTAssertEqual(resolved.agent, .gemini)
		XCTAssertEqual(resolved.modelRaw, AgentModel.gemini3FlashPreview.rawValue)
	}

	func testTaskLabelsIncludeAllRoles() {
		let labels = AgentModelCatalog.taskLabels.map(\.label)

		XCTAssertTrue(labels.contains("explore"))
		XCTAssertTrue(labels.contains("engineer"))
		XCTAssertTrue(labels.contains("pair"))
		XCTAssertTrue(labels.contains("design"))
		XCTAssertFalse(labels.contains("complex"))
		XCTAssertFalse(labels.contains("quick"))
	}

	func testRecommendationProviderFilterUsesSupportedRecommendationProviders() {
		XCTAssertEqual(
			RecommendationProviderKind.allCases.map(\.rawValue),
			[
				RecommendationProviderKind.claudeCode.rawValue,
				RecommendationProviderKind.codex.rawValue,
				RecommendationProviderKind.cursor.rawValue,
				RecommendationProviderKind.openAI.rawValue,
				RecommendationProviderKind.geminiCLI.rawValue,
			]
		)
	}

	func testRecommendationProviderFilteringKeepsCursorAndOpenAIOnlyFromAPIProviders() {
		let status = ProviderStatusSnapshot(
			claudeCodeCLI: .notConfigured,
			codexCLI: .notConfigured,
			geminiCLI: .notConfigured,
			cursorCLI: .ready,
			openAI: .ready
		)

		let filtered = status.filtered(to: Set(RecommendationProviderKind.allCases))

		XCTAssertEqual(filtered.cursorCLI, .ready)
		XCTAssertEqual(filtered.openAI, .ready)
	}

	@MainActor
	func testOpenAIAPIRecommendationUsesGPT55ProWhenCodexUnavailable() throws {
		let workspaceID = UUID()
		let (engine, store) = try makeRecommendationHarness()
		engine.apiSettingsViewModel?.isCodexConnected = false
		engine.apiSettingsViewModel?.isGeminiConnected = false
		engine.apiSettingsViewModel?.isClaudeCodeConnected = false
		engine.apiSettingsViewModel?.isOpenAIKeyValid = true
		engine.apiSettingsViewModel?.openAIApiKey = "test-openai-key"
		store.setPreferredComposeModelRaw(AIModel.geminiCliPro3p1Preview.rawValue, commit: true)
		store.setPlanningModelRaw(AIModel.geminiCliPro3p1Preview.rawValue, commit: true)

		let chat = try XCTUnwrap(
			engine.computeRecommendations(for: workspaceID, enabledProviders: [.openAI]).chatModel
		)

		XCTAssertEqual(chat.defaultBackend, .openAI)
		XCTAssertEqual(chat.openAIOption?.modelString, AIModel.gpt54Pro.rawValue)
		XCTAssertEqual(chat.openAIOption?.modelString, "gpt-5.5-pro")
		XCTAssertTrue(chat.openAIOption?.description.contains("API-backed") == true)
		XCTAssertFalse(chat.openAIOption?.tradeoffs.joined(separator: " ").contains("unavailable through OpenAI API") == true)
	}

	@MainActor
	func testGeminiOracleRecommendationBecomesUnsatisfiedWhenCodexConnects() throws {
		let workspaceID = UUID()
		let (engine, store) = try makeRecommendationHarness()
		store.setPreferredComposeModelRaw(AIModel.geminiCliPro3p1Preview.rawValue, commit: true)
		store.setPlanningModelRaw(AIModel.geminiCliPro3p1Preview.rawValue, commit: true)

		let recommendations = engine.computeRecommendations(for: workspaceID)
		let chat = try XCTUnwrap(recommendations.chatModel)

		XCTAssertEqual(chat.defaultBackend, .codex)
		XCTAssertEqual(chat.codexOption?.modelString, AIModel.codexCliGpt55CodexHigh.rawValue)
		XCTAssertFalse(chat.alreadySatisfied)

		engine.applyChatModelRecommendation(chat, backend: chat.defaultBackend, workspaceID: workspaceID)
		XCTAssertEqual(store.planningModelRaw(), AIModel.codexCliGpt55CodexHigh.rawValue)
		XCTAssertEqual(store.preferredComposeModelRaw(), AIModel.codexCliGpt55CodexHigh.rawValue)

		let recomputedChat = try XCTUnwrap(engine.computeRecommendations(for: workspaceID).chatModel)
		XCTAssertEqual(recomputedChat.defaultBackend, .codex)
		XCTAssertTrue(recomputedChat.alreadySatisfied)
	}

	@MainActor
	func testStrongerGPT55CodexEffortSatisfiesChatRecommendation() throws {
		let workspaceID = UUID()
		let (engine, store) = try makeRecommendationHarness()
		store.setPreferredComposeModelRaw(AIModel.codexCliGpt55CodexXHigh.rawValue, commit: true)
		store.setPlanningModelRaw(AIModel.codexCliGpt55CodexXHigh.rawValue, commit: true)

		let chat = try XCTUnwrap(engine.computeRecommendations(for: workspaceID).chatModel)

		XCTAssertEqual(chat.defaultBackend, .codex)
		XCTAssertEqual(chat.codexOption?.modelString, AIModel.codexCliGpt55CodexHigh.rawValue)
		XCTAssertTrue(chat.alreadySatisfied)
		XCTAssertEqual(engine.inferCurrentChatBackend(from: chat), .codex)
	}

	@MainActor
	func testWeakerGPT55CodexEffortDoesNotSatisfyChatRecommendation() throws {
		let workspaceID = UUID()
		let (engine, store) = try makeRecommendationHarness()
		store.setPreferredComposeModelRaw(AIModel.codexCliGpt55CodexMedium.rawValue, commit: true)
		store.setPlanningModelRaw(AIModel.codexCliGpt55CodexMedium.rawValue, commit: true)

		let chat = try XCTUnwrap(engine.computeRecommendations(for: workspaceID).chatModel)

		XCTAssertEqual(chat.defaultBackend, .codex)
		XCTAssertFalse(chat.alreadySatisfied)
	}

	@MainActor
	func testRecommendationApplyHonorsSyncWithSinglePlanningWrite() throws {
		let workspaceID = UUID()
		let (engine, store) = try makeRecommendationHarness()
		store.setPreferredComposeModelRaw(AIModel.geminiCliPro3p1Preview.rawValue, commit: true)
		store.setPlanningModelRaw(AIModel.geminiCliPro3p1Preview.rawValue, commit: true)
		store.setSyncChatModelWithOracle(true)
		let chat = try XCTUnwrap(engine.computeRecommendations(for: workspaceID).chatModel)

		engine.applyChatModelRecommendation(chat, backend: chat.defaultBackend, workspaceID: workspaceID)

		XCTAssertEqual(store.planningModelRaw(), AIModel.codexCliGpt55CodexHigh.rawValue)
		XCTAssertEqual(store.preferredComposeModelRaw(), AIModel.codexCliGpt55CodexHigh.rawValue)
		let diagnostics = store.recentSettingsWriteDiagnostics()
		XCTAssertTrue(diagnostics.contains { $0.key == "planningModelRaw" && $0.reason == "recommendations.chat_model.codex.planning" })
		XCTAssertTrue(diagnostics.contains { $0.key == "preferredComposeModelRaw" && $0.reason == "recommendations.chat_model.codex.planning.sync_sibling" })
	}

	@MainActor
	func testCodexOnlyProEditRecommendationUsesGPT55Medium() throws {
		let workspaceID = UUID()
		let (engine, store) = try makeRecommendationHarness()
		engine.apiSettingsViewModel?.isCodexConnected = true
		engine.apiSettingsViewModel?.isClaudeCodeConnected = false
		engine.apiSettingsViewModel?.isGeminiConnected = false
		engine.apiSettingsViewModel?.isOpenAIKeyValid = false

		let proEdit = try XCTUnwrap(engine.computeRecommendations(for: workspaceID, enabledProviders: [.codex]).proEdit)

		XCTAssertEqual(proEdit.recommendedAgent, .codexExec)
		XCTAssertEqual(proEdit.recommendedAgentModel, .gpt55CodexMedium)

		engine.applyProEditRecommendation(proEdit, workspaceID: workspaceID)
		let settings = store.proEditSettings()
		XCTAssertTrue(settings.agentMode)
		XCTAssertEqual(settings.agentKindRaw, DiscoverAgentKind.codexExec.rawValue)
		XCTAssertEqual(settings.agentModelRaw, AgentModel.gpt55CodexMedium.rawValue)
	}

	@MainActor
	func testProviderFilterExcludingCodexKeepsGeminiOracleSatisfied() throws {
		let workspaceID = UUID()
		let (engine, store) = try makeRecommendationHarness()
		store.setPreferredComposeModelRaw(AIModel.geminiCliPro3p1Preview.rawValue, commit: true)
		store.setPlanningModelRaw(AIModel.geminiCliPro3p1Preview.rawValue, commit: true)

		let recommendations = engine.computeRecommendations(
			for: workspaceID,
			enabledProviders: [.geminiCLI]
		)
		let chat = try XCTUnwrap(recommendations.chatModel)

		XCTAssertEqual(chat.defaultBackend, .gemini)
		XCTAssertTrue(chat.alreadySatisfied)
	}

	@MainActor
	func testLegacyAllRecommendationProviderFilterIncludesCursor() {
		let normalized = GlobalSettingsStore.normalizedRecommendationProviderFilter(raw: [
			RecommendationProviderKind.claudeCode.rawValue,
			RecommendationProviderKind.codex.rawValue,
			RecommendationProviderKind.openAI.rawValue,
			"anthropic",
			RecommendationProviderKind.geminiCLI.rawValue,
		])

		XCTAssertEqual(normalized, Set(RecommendationProviderKind.allCases))
		XCTAssertTrue(normalized.contains(.cursor))
	}

	func testRecommendationSetActionableCountIgnoresSatisfiedAgentDefaultsStep() {
		let roleDefault = MCPAgentRoleDefault(
			role: .explore,
			roleLabel: "Explore",
			roleDescription: "Inspect code",
			agent: .codexExec,
			model: .gpt55CodexLow,
			modelDisplayName: "GPT-5.5 Low",
			selectionIDRaw: "codexExec:gpt-5.5-low"
		)
		var recommendations = RecommendationSet()
		recommendations.contextBuilder = ContextBuilderRecommendation(
			recommendedAgent: .codexExec,
			recommendedModel: .gpt55CodexLow,
			rationale: "Use Codex for context building"
		)
		recommendations.mcpAgentDefaults = MCPAgentDefaultsRecommendation(
			alreadySatisfied: true,
			currentRoleDefaults: [roleDefault],
			recommendedRoleDefaults: [roleDefault],
			upgradeHint: nil
		)

		XCTAssertEqual(recommendations.actionableUnsatisfiedCount, 1)
		XCTAssertTrue(recommendations.hasUnsatisfied)
	}

	@MainActor
	private func makeRecommendationHarness() throws -> (AutoRecommendationEngine, GlobalSettingsStore) {
		let suite = "RepoPrompt.RecommendationProfilesTests.\(UUID().uuidString)"
		userDefaultsSuites.append(suite)
		let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
		defaults.removePersistentDomain(forName: suite)
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("RepoPrompt-RecommendationProfilesTests-\(UUID().uuidString)", isDirectory: true)
		temporaryDirectories.append(directory)

		let fileURL = directory
			.appendingPathComponent("Settings", isDirectory: true)
			.appendingPathComponent("globalSettings.json")
		let store = GlobalSettingsStore(
			defaults: defaults,
			fileStore: GlobalSettingsFileStore(fileURL: fileURL)
		)
		let keyManager = KeyManager()
		let apiSettings = APISettingsViewModel(
			aiQueriesService: AIQueriesService(keyManager: keyManager),
			keyManager: keyManager,
			loadStoredDataOnInit: false
		)
		apiSettings.isCodexConnected = true
		apiSettings.isGeminiConnected = true
		apiSettings.isClaudeCodeConnected = false
		apiSettings.isCursorConnected = false
		apiSettings.isOpenAIKeyValid = false
		apiSettings.openAIApiKey = ""
		retainedAPISettings.append(apiSettings)

		return (AutoRecommendationEngine(settingsStore: store, apiSettingsViewModel: apiSettings), store)
	}

	func testCodexOnlyTaskLabelDefaultsUseCurrentRecommendations() throws {
		let availability = AgentModelCatalog.AvailabilityContext(
			claudeCodeAvailable: false,
			codexAvailable: true,
			geminiAvailable: false,
			openCodeAvailable: false,
			cursorAvailable: false,
			zaiConfigured: false
		)

		let explore = try XCTUnwrap(AgentModelCatalog.resolveTaskLabelKind(.explore, availability: availability))
		let engineer = try XCTUnwrap(AgentModelCatalog.resolveTaskLabelKind(.engineer, availability: availability))
		let pair = try XCTUnwrap(AgentModelCatalog.resolveTaskLabelKind(.pair, availability: availability))
		let design = try XCTUnwrap(AgentModelCatalog.resolveTaskLabelKind(.design, availability: availability))

		XCTAssertEqual(explore.agent, .codexExec)
		XCTAssertEqual(explore.modelRaw, AgentModel.gpt55CodexLow.rawValue)
		XCTAssertEqual(engineer.agent, .codexExec)
		XCTAssertEqual(engineer.modelRaw, AgentModel.gpt55CodexMedium.rawValue)
		XCTAssertEqual(pair.agent, .codexExec)
		XCTAssertEqual(pair.modelRaw, AgentModel.gpt55CodexHigh.rawValue)
		XCTAssertEqual(design.agent, .codexExec)
		XCTAssertEqual(design.modelRaw, AgentModel.gpt55CodexMedium.rawValue)
	}

	func testDiscoveryTagsAreLimitedToRecommendedModels() {
		XCTAssertEqual(AgentModel.gpt55CodexLow.discoveryTags, [.fast, .exploration])
		XCTAssertEqual(AgentModel.codexMedium.discoveryTags, [])
		XCTAssertEqual(AgentModel.gpt55CodexMedium.discoveryTags, [.engineering])
		XCTAssertEqual(AgentModel.gpt55CodexHigh.discoveryTags, [.complex, .engineering, .pair])
		XCTAssertEqual(AgentModel.claudeOpus.discoveryTags, [.complex, .engineering, .pair])

		XCTAssertEqual(AgentModel.gpt55CodexXHigh.discoveryTags, [])
		XCTAssertEqual(AgentModel.gpt54High.discoveryTags, [])
		XCTAssertEqual(AgentModel.claudeOpus1m.discoveryTags, [])
		XCTAssertEqual(AgentModel.gpt54MiniHigh.discoveryTags, [])
	}
}
