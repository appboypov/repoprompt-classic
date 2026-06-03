import XCTest
@testable import RepoPrompt

@MainActor
final class CodexAgentModeCoordinatorReasoningTests: XCTestCase {
	override func tearDown() {
		CodexGoalSupport.setEnabledForTesting(nil)
		CodexComputerUseWorkflow.setEnabledForTesting(nil)
		super.tearDown()
	}

	private func makeDefaults() -> (UserDefaults, String) {
		let suiteName = "CodexAgentModeCoordinatorReasoningTests.\(UUID().uuidString)"
		let defaults = UserDefaults(suiteName: suiteName)!
		defaults.removePersistentDomain(forName: suiteName)
		return (defaults, suiteName)
	}

	func testLastUsedReasoningEffortRoundTripsThroughPreferencesStore() {
		let suiteName = "CodexAgentModeCoordinatorReasoningTests.\(UUID().uuidString)"
		guard let defaults = UserDefaults(suiteName: suiteName) else {
			XCTFail("Expected dedicated UserDefaults suite")
			return
		}
		defaults.removePersistentDomain(forName: suiteName)
		defer { defaults.removePersistentDomain(forName: suiteName) }

		XCTAssertNil(CodexAgentToolPreferences.lastUsedReasoningEffort(defaults: defaults))

		CodexAgentToolPreferences.setLastUsedReasoningEffort(.high, defaults: defaults)
		XCTAssertEqual(CodexAgentToolPreferences.lastUsedReasoningEffort(defaults: defaults), .high)

		CodexAgentToolPreferences.setLastUsedReasoningEffort(nil, defaults: defaults)
		XCTAssertNil(CodexAgentToolPreferences.lastUsedReasoningEffort(defaults: defaults))
	}

	func testCoordinatorStartsWithSeededLastUsedReasoningEffort() {
		let coordinator = makeCoordinator(initialEffort: .xhigh)
		XCTAssertEqual(coordinator.lastUsedReasoningEffort, .xhigh)
	}

	func testCoordinatorStartsWithSeededPerModelReasoningEfforts() {
		let coordinator = makeCoordinator(
			initialEffort: .low,
			initialEffortsByModelSlug: [
				"GPT-5.3-CODEX": .high,
				"gpt-5.4": .medium
			]
		)

		XCTAssertEqual(coordinator.lastUsedReasoningEffort, .low)
		XCTAssertEqual(coordinator.lastUsedReasoningEffortByModelSlug["gpt-5.3-codex"], .high)
		XCTAssertEqual(coordinator.lastUsedReasoningEffortByModelSlug["gpt-5.4"], .medium)
	}

	func testRecordLastUsedReasoningEffortUpdatesInMemoryState() {
		let coordinator = makeCoordinator(initialEffort: .low)
		coordinator.recordLastUsedReasoningEffort(.high)
		XCTAssertEqual(coordinator.lastUsedReasoningEffort, .high)

		coordinator.recordLastUsedReasoningEffort(nil)
		XCTAssertEqual(coordinator.lastUsedReasoningEffort, .high)
	}

	func testNormalizeSelectionFallsBackToLastUsedEffortWhenSessionEffortIsNil() {
		let (defaults, suiteName) = makeDefaults()
		defer { defaults.removePersistentDomain(forName: suiteName) }
		let coordinator = makeCoordinator(initialEffort: .high, defaults: defaults)
		guard let modelOption = coordinator.modelOptions(for: .codexExec).first(where: { $0.supportedReasoningEfforts.contains(.high) }) else {
			XCTFail("Expected a Codex model that supports high reasoning effort")
			return
		}

		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec
		session.selectedModelRaw = modelOption.rawValue
		session.selectedReasoningEffortRaw = nil

		coordinator.normalizeCodexSelectionForSession(session, preservingExplicitEffort: true)

		XCTAssertEqual(session.selectedReasoningEffortRaw, CodexReasoningEffort.high.rawValue)
	}

	func testNormalizeSelectionUsesPerModelReasoningEffort() {
		let (defaults, suiteName) = makeDefaults()
		defer { defaults.removePersistentDomain(forName: suiteName) }
		let coordinator = makeCoordinator(
			initialEffort: .xhigh,
			initialEffortsByModelSlug: [
				"gpt-5.3-codex": .high,
				"gpt-5.4": .medium
			],
			defaults: defaults
		)
		let codexSession = AgentModeViewModel.TabSession(tabID: UUID())
		codexSession.selectedAgent = .codexExec
		codexSession.selectedModelRaw = "gpt-5.3-codex"
		codexSession.selectedReasoningEffortRaw = nil

		coordinator.normalizeCodexSelectionForSession(codexSession, preservingExplicitEffort: true)

		XCTAssertEqual(codexSession.selectedReasoningEffortRaw, CodexReasoningEffort.high.rawValue)

		let gpt54Session = AgentModeViewModel.TabSession(tabID: UUID())
		gpt54Session.selectedAgent = .codexExec
		gpt54Session.selectedModelRaw = "gpt-5.4"
		gpt54Session.selectedReasoningEffortRaw = nil

		coordinator.normalizeCodexSelectionForSession(gpt54Session, preservingExplicitEffort: true)

		XCTAssertEqual(gpt54Session.selectedReasoningEffortRaw, CodexReasoningEffort.medium.rawValue)
	}

	func testNormalizeSelectionDoesNotCarryPreviousExplicitEffortWhenSwitchingModels() {
		let (defaults, suiteName) = makeDefaults()
		defer { defaults.removePersistentDomain(forName: suiteName) }
		let coordinator = makeCoordinator(
			initialEffort: nil,
			initialEffortsByModelSlug: ["gpt-5.4": .medium],
			defaults: defaults
		)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec
		session.selectedModelRaw = "gpt-5.4"
		session.selectedReasoningEffortRaw = CodexReasoningEffort.high.rawValue

		coordinator.normalizeCodexSelectionForSession(session, preservingExplicitEffort: false)

		XCTAssertEqual(session.selectedModelRaw, "gpt-5.4")
		XCTAssertEqual(session.selectedReasoningEffortRaw, CodexReasoningEffort.medium.rawValue)
	}

	func testNormalizeSelectionDoesNotUseGlobalFallbackWhenSwitchingToUnsavedModel() throws {
		let (defaults, suiteName) = makeDefaults()
		defer { defaults.removePersistentDomain(forName: suiteName) }
		let coordinator = makeCoordinator(initialEffort: .high, defaults: defaults)
		let defaultEffort = try XCTUnwrap(coordinator.defaultReasoningEffort(forModelRaw: "gpt-5.4", agentKind: .codexExec))
		XCTAssertNotEqual(defaultEffort, .high, "This regression test needs a model whose default differs from the previous effort.")
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec
		session.selectedModelRaw = "gpt-5.4"
		session.selectedReasoningEffortRaw = CodexReasoningEffort.high.rawValue

		coordinator.normalizeCodexSelectionForSession(session, preservingExplicitEffort: false)

		XCTAssertEqual(session.selectedModelRaw, "gpt-5.4")
		XCTAssertEqual(session.selectedReasoningEffortRaw, defaultEffort.rawValue)
	}

	func testEffectiveCodexSelectionUsesPerModelReasoningEffort() {
		let coordinator = makeCoordinator(
			initialEffort: .low,
			initialEffortsByModelSlug: ["gpt-5.4": .high]
		)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec
		session.selectedModelRaw = "gpt-5.4"
		session.selectedReasoningEffortRaw = nil

		let selection = coordinator.effectiveCodexSelection(for: session)

		XCTAssertEqual(selection.model, "gpt-5.4")
		XCTAssertEqual(selection.reasoningEffort, CodexReasoningEffort.high.rawValue)
		XCTAssertNil(selection.serviceTier)
	}

	func testRecordLastUsedReasoningEffortUpdatesPerModelState() {
		let coordinator = makeCoordinator(initialEffort: nil)

		coordinator.recordLastUsedReasoningEffort(.high, forModelRaw: "gpt-5.4-high")
		coordinator.recordLastUsedReasoningEffort(.medium, forModelRaw: "gpt-5.3-codex-medium")

		XCTAssertEqual(coordinator.lastUsedReasoningEffort, .medium)
		XCTAssertEqual(coordinator.lastUsedReasoningEffortByModelSlug["gpt-5.4"], .high)
		XCTAssertEqual(coordinator.lastUsedReasoningEffortByModelSlug["gpt-5.3-codex"], .medium)

		coordinator.recordLastUsedReasoningEffort(nil, forModelRaw: "gpt-5.4")
		XCTAssertNil(coordinator.lastUsedReasoningEffortByModelSlug["gpt-5.4"])
		XCTAssertEqual(coordinator.lastUsedReasoningEffort, .medium)
	}

	func testFastSelectedModelDrivesEffectiveServiceTier() {
		let coordinator = makeCoordinator(initialEffort: nil)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec
		session.selectedModelRaw = "gpt-5.3-codex-fast"
		session.selectedReasoningEffortRaw = CodexReasoningEffort.high.rawValue

		let selection = coordinator.effectiveCodexSelection(for: session)

		XCTAssertEqual(selection.model, "gpt-5.3-codex")
		XCTAssertEqual(selection.reasoningEffort, "high")
		XCTAssertEqual(selection.serviceTier, "fast")
	}

	func testUnsupportedFastRawDoesNotDriveRuntimeServiceTier() {
		let coordinator = makeCoordinator(initialEffort: nil)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec
		session.selectedModelRaw = "gpt-5.2-fast-high"

		coordinator.normalizeCodexSelectionForSession(session, preservingExplicitEffort: true)

		XCTAssertEqual(session.selectedModelRaw, "gpt-5.2")
		let selection = coordinator.effectiveCodexSelection(for: session)
		XCTAssertEqual(selection.model, "gpt-5.2")
		XCTAssertNil(selection.serviceTier)
	}

	func testNormalizeSelectionPreservesFastServiceTierAndEmbeddedEffort() {
		let coordinator = makeCoordinator(initialEffort: nil)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec
		session.selectedModelRaw = "gpt-5.4-fast-high"
		session.selectedReasoningEffortRaw = nil
		session.codexServiceTier = "fast"

		coordinator.normalizeCodexSelectionForSession(session, preservingExplicitEffort: true)

		XCTAssertEqual(session.selectedModelRaw, "gpt-5.4-fast")
		XCTAssertEqual(session.selectedReasoningEffortRaw, "high")
		XCTAssertNil(session.codexServiceTier)
		let selection = coordinator.effectiveCodexSelection(for: session)
		XCTAssertEqual(selection.model, "gpt-5.4")
		XCTAssertEqual(selection.serviceTier, "fast")
	}

	func testRestoreLegacyFastServiceTierMigratesToSelectedFastModel() {
		let coordinator = makeCoordinator(initialEffort: nil)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec
		let agentSession = AgentSession(
			agentKind: DiscoverAgentKind.codexExec.rawValue,
			agentModel: "gpt-5.4-high",
			agentReasoningEffort: nil,
			codexServiceTier: "fast"
		)

		coordinator.restoreCodexSelection(from: agentSession, session: session)
		coordinator.restoreCodexMetadata(from: agentSession, session: session)

		XCTAssertEqual(session.selectedModelRaw, "gpt-5.4-fast")
		XCTAssertEqual(session.selectedReasoningEffortRaw, "high")
		XCTAssertNil(session.codexServiceTier)
		let selection = coordinator.effectiveCodexSelection(for: session)
		XCTAssertEqual(selection.model, "gpt-5.4")
		XCTAssertEqual(selection.serviceTier, "fast")
	}

	func testApplyCodexPersistenceDerivesServiceTierFromSelectedModel() {
		let coordinator = makeCoordinator(initialEffort: nil)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec
		session.selectedModelRaw = "gpt-5.4-fast"
		var agentSession = AgentSession(agentKind: DiscoverAgentKind.codexExec.rawValue)

		coordinator.applyCodexPersistence(from: session, to: &agentSession)

		XCTAssertEqual(agentSession.codexServiceTier, "fast")
	}

	func testApplyCodexPersistenceDropsUnsupportedServiceTierFromSelectedModel() {
		let coordinator = makeCoordinator(initialEffort: nil)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec
		session.selectedModelRaw = "gpt-5.2-fast"
		var agentSession = AgentSession(agentKind: DiscoverAgentKind.codexExec.rawValue, codexServiceTier: "fast")

		coordinator.applyCodexPersistence(from: session, to: &agentSession)

		XCTAssertNil(agentSession.codexServiceTier)
	}

	func testNativeSlashSuggestionsExposeGoalAndCompactForKnownThread() {
		CodexGoalSupport.setEnabledForTesting(true)
		CodexComputerUseWorkflow.setEnabledForTesting(false)
		let coordinator = makeCoordinator(initialEffort: nil)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec
		session.codexConversationID = "thread-123"

		let suggestions = coordinator.nativeSlashCommandSuggestions(for: session, query: "", limit: 10)

		XCTAssertEqual(suggestions.map(\.relativePath), ["compact", "goal"])
		XCTAssertEqual(coordinator.nativeSlashCommand(named: "fast", session: session), nil)
		XCTAssertNotNil(coordinator.nativeSlashCommand(named: "compact", session: session))
		XCTAssertNotNil(coordinator.nativeSlashCommand(named: "goal", session: session))
	}

	func testNativeSlashSuggestionsExposeGoalWithoutKnownThread() {
		CodexGoalSupport.setEnabledForTesting(true)
		CodexComputerUseWorkflow.setEnabledForTesting(false)
		let coordinator = makeCoordinator(initialEffort: nil)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec

		let suggestions = coordinator.nativeSlashCommandSuggestions(for: session, query: "", limit: 10)

		XCTAssertEqual(suggestions.map(\.relativePath), ["goal"])
		XCTAssertNotNil(coordinator.nativeSlashCommand(named: "goal", session: session))
		XCTAssertNotNil(coordinator.nativeSlashCommand(named: "compact", session: session), "Known native commands should resolve even when currently unavailable")
	}

	func testEnsureCodexNativeSessionPassesExploreTaskLabelKindToFactory() async {
		var capturedTaskLabelKind: AgentModelCatalog.TaskLabelKind?
		let coordinator = CodexAgentModeCoordinator(
			windowID: 1,
			workspacePathProvider: { nil },
			codexControllerFactory: { _, _, _, _, _, taskLabelKind, _ in
				capturedTaskLabelKind = taskLabelKind
				return NoOpCodexSessionController()
			},
			connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
			shouldManageCodexTooling: false,
			initialLastUsedReasoningEffort: nil
		)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec
		let sessionID = UUID()
		session.mcpControlContext = AgentModeViewModel.AgentMCPControlContext(
			sessionID: sessionID,
			activationID: UUID(),
			originatingConnectionID: nil,
			interactionTransport: .mcp(sessionID: sessionID, originatingConnectionID: nil),
			suppressUserNotifications: true,
			forceAutoEditEnabled: true,
			autoEditEnabledBeforeOverride: true,
			taskLabelKind: .explore
		)

		await coordinator.ensureCodexNativeSession(session: session)

		XCTAssertEqual(capturedTaskLabelKind, .explore)
	}

	func testEnsureCodexNativeSessionDoesNotEnableComputerUseWhenFeatureDisabled() async {
		CodexComputerUseWorkflow.setEnabledForTesting(false)
		var capturedComputerUseEnabled: Bool?
		let coordinator = CodexAgentModeCoordinator(
			windowID: 1,
			workspacePathProvider: { nil },
			codexControllerFactory: { _, _, _, _, _, _, computerUseEnabled in
				capturedComputerUseEnabled = computerUseEnabled
				return NoOpCodexSessionController()
			},
			connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
			shouldManageCodexTooling: false,
			initialLastUsedReasoningEffort: nil
		)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec
		session.pendingCodexComputerUseActivation = .init(id: UUID(), createdAt: Date())

		await coordinator.ensureCodexNativeSession(session: session)

		XCTAssertEqual(capturedComputerUseEnabled, false)
		XCTAssertEqual(session.codexControllerComputerUseEnabled, false)
		XCTAssertNil(session.pendingCodexComputerUseActivation)
	}

	private func makeCoordinator(
		initialEffort: CodexReasoningEffort?,
		initialEffortsByModelSlug: [String: CodexReasoningEffort] = [:],
		defaults: UserDefaults? = nil
	) -> CodexAgentModeCoordinator {
		let resolvedDefaults: UserDefaults
		let cleanupSuiteName: String?
		if let defaults {
			resolvedDefaults = defaults
			cleanupSuiteName = nil
		} else {
			let (isolatedDefaults, suiteName) = makeDefaults()
			resolvedDefaults = isolatedDefaults
			cleanupSuiteName = suiteName
		}
		let coordinator = CodexAgentModeCoordinator(
			windowID: 1,
			workspacePathProvider: { nil },
			codexControllerFactory: { _, _, _, _, _, _, _ in
				NoOpCodexSessionController()
			},
			connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
			shouldManageCodexTooling: false,
			preferenceDefaults: resolvedDefaults,
			initialLastUsedReasoningEffort: initialEffort,
			initialLastUsedReasoningEffortsByModelSlug: initialEffortsByModelSlug
		)
		if let cleanupSuiteName {
			resolvedDefaults.removePersistentDomain(forName: cleanupSuiteName)
		}
		return coordinator
	}
}

private final class NoOpCodexSessionController: CodexSessionControlling {
	var hasActiveThread: Bool { false }

	var events: AsyncStream<CodexNativeSessionController.Event> {
		AsyncStream { continuation in
			continuation.finish()
		}
	}

	func ensureEventsStreamReady() {}

	func startOrResume(
		existing: CodexNativeSessionController.SessionRef?,
		baseInstructions: String
	) async throws -> CodexNativeSessionController.SessionRef {
		CodexNativeSessionController.SessionRef(
			conversationID: existing?.conversationID ?? "noop",
			rolloutPath: existing?.rolloutPath,
			model: existing?.model,
			reasoningEffort: existing?.reasoningEffort
		)
	}

	func startOrResume(
		existing: CodexNativeSessionController.SessionRef?,
		baseInstructions: String,
		model: String?,
		reasoningEffort: String?
	) async throws -> CodexNativeSessionController.SessionRef {
		CodexNativeSessionController.SessionRef(
			conversationID: existing?.conversationID ?? "noop",
			rolloutPath: existing?.rolloutPath,
			model: model ?? existing?.model,
			reasoningEffort: reasoningEffort ?? existing?.reasoningEffort
		)
	}

	func sendUserMessage(_ text: String) async throws {}

	func sendUserTurn(text: String, images: [AgentImageAttachment]) async throws {}

	func sendUserTurn(
		text: String,
		images: [AgentImageAttachment],
		model: String?,
		reasoningEffort: String?
	) async throws {}

	func cancelCurrentTurn() async {}

	func shutdown() async {}

	func respondToServerRequest(id: CodexAppServerRequestID, result: [String : Any]) async {}
}
