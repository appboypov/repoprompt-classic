import XCTest
@_spi(TestSupport) @testable import RepoPrompt

@MainActor
final class AgentModeViewModelGeminiACPModelSelectionTests: XCTestCase {
	override func setUp() {
		super.setUp()
		AgentACPModelRegistry.shared.test_reset(providerID: .gemini)
	}

	override func tearDown() {
		AgentACPModelRegistry.shared.test_reset(providerID: .gemini)
		super.tearDown()
	}
	func testGeminiDiscoveredModelsOverrideStaticPickerOptions() async {
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			GeminiACPModelSelectionFakeCodexController()
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .gemini
		_ = AgentACPModelRegistry.shared.updateDiscoveredModels(
			ACPDiscoveredSessionModels(
			options: [
				AgentModelOption(
					rawValue: "gemini-2.5-pro-exp-0827",
					displayName: "Gemini 2.5 Pro Experimental",
					description: "Experimental Gemini Pro build",
					isPlaceholderDefault: false,
					isProviderDefault: true
				),
				AgentModelOption(
					rawValue: "gemini-2.5-flash",
					displayName: "Gemini 2.5 Flash",
					description: "Fast Gemini model",
					isPlaceholderDefault: false,
					isProviderDefault: false
				)
			],
			currentModelRaw: "gemini-2.5-pro-exp-0827"
		),
			for: .gemini
		)

		XCTAssertEqual(
			vm.modelOptions(for: .gemini).map(\.rawValue),
			["gemini-2.5-flash", "gemini-2.5-pro-exp-0827"]
		)
		XCTAssertEqual(
			vm.defaultModelRaw(for: .gemini),
			"gemini-2.5-pro-exp-0827"
		)
		XCTAssertEqual(
			vm.modelDisplayName(
				rawModel: "gemini-2.5-pro-exp-0827",
				agentKind: .gemini
			),
			"Gemini 2.5 Pro Experimental"
		)
	}

	func testGeminiFallsBackToStaticCatalogWithoutDiscoveredModels() async {
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			GeminiACPModelSelectionFakeCodexController()
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .gemini
		AgentACPModelRegistry.shared.test_reset(providerID: .gemini)

		XCTAssertEqual(
			vm.modelOptions(for: .gemini).map(\.rawValue),
			AgentModelCatalog.options(for: .gemini).map(\.rawValue)
		)
		XCTAssertEqual(
			vm.defaultModelRaw(for: .gemini),
			AgentModelCatalog.defaultModelRaw(for: .gemini)
		)
	}
}

private final class GeminiACPModelSelectionFakeCodexController: CodexSessionControlling {
	var hasActiveThread: Bool = false
	var events: AsyncStream<CodexNativeSessionController.Event> { AsyncStream { continuation in continuation.finish() } }

	func ensureEventsStreamReady() {}

	func startOrResume(
		existing _: CodexNativeSessionController.SessionRef?,
		baseInstructions _: String
	) async throws -> CodexNativeSessionController.SessionRef {
		hasActiveThread = true
		return CodexNativeSessionController.SessionRef(
			conversationID: "gemini-acp-test",
			rolloutPath: nil,
			model: "gpt-5.2-codex",
			reasoningEffort: "medium"
		)
	}

	func startOrResume(
		existing: CodexNativeSessionController.SessionRef?,
		baseInstructions: String,
		model _: String?,
		reasoningEffort _: String?
	) async throws -> CodexNativeSessionController.SessionRef {
		try await startOrResume(existing: existing, baseInstructions: baseInstructions)
	}

	func startOrResume(
		existing: CodexNativeSessionController.SessionRef?,
		baseInstructions: String,
		model _: String?,
		reasoningEffort _: String?,
		serviceTier _: String?
	) async throws -> CodexNativeSessionController.SessionRef {
		try await startOrResume(existing: existing, baseInstructions: baseInstructions)
	}

	func readThreadSnapshot(
		includeTurns _: Bool,
		timeout _: TimeInterval?
	) async throws -> CodexNativeSessionController.ThreadSnapshot {
		return CodexNativeSessionController.ThreadSnapshot(
			conversationID: "gemini-acp-test",
			rolloutPath: nil,
			model: "gpt-5.2-codex",
			reasoningEffort: "medium",
			runtimeStatus: .idle,
			currentTurnID: nil,
			activeTurnIDs: [],
			latestTurnStatus: nil
		)
	}

	func sendUserMessage(_: String) async throws {}
	func sendUserTurn(text _: String, images _: [AgentImageAttachment]) async throws {}
	func sendUserTurn(text _: String, images _: [AgentImageAttachment], model _: String?, reasoningEffort _: String?) async throws {}
	func sendUserTurn(text _: String, images _: [AgentImageAttachment], model _: String?, reasoningEffort _: String?, serviceTier _: String?) async throws {}
	func compactThread() async throws {}
	func cancelCurrentTurn() async {}
	func shutdown() async { hasActiveThread = false }
	func respondToServerRequest(id _: CodexAppServerRequestID, result _: [String: Any]) async {}
}
