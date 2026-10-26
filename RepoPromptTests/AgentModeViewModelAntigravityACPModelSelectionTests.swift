import XCTest
@_spi(TestSupport) @testable import RepoPrompt

@MainActor
final class AgentModeViewModelAntigravityACPModelSelectionTests: XCTestCase {
	override func setUp() {
		super.setUp()
		AgentACPModelRegistry.shared.test_reset(providerID: .antigravity)
	}

	override func tearDown() {
		AgentACPModelRegistry.shared.test_reset(providerID: .antigravity)
		super.tearDown()
	}
	func testAntigravityDiscoveredModelsBecomePickerOptions() async {
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			AntigravityACPModelSelectionFakeCodexController()
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .antigravity
		_ = AgentACPModelRegistry.shared.updateDiscoveredModels(
			ACPDiscoveredSessionModels(
			options: [
				AgentModelOption(
					rawValue: "gemini-3.0-flash-high",
					displayName: "Gemini 3 Flash (High)",
					description: "Fast model, high thinking",
					isPlaceholderDefault: false,
					isProviderDefault: true
				),
				AgentModelOption(
					rawValue: "gemini-3.0-flash-low",
					displayName: "Gemini 3 Flash (Low)",
					description: "Fast model, low thinking",
					isPlaceholderDefault: false,
					isProviderDefault: false
				)
			],
			currentModelRaw: "gemini-3.0-flash-high"
		),
			for: .antigravity
		)

		XCTAssertEqual(
			vm.modelOptions(for: .antigravity).map(\.rawValue),
			["gemini-3.0-flash-high", "gemini-3.0-flash-low"]
		)
		XCTAssertEqual(
			vm.defaultModelRaw(for: .antigravity),
			"gemini-3.0-flash-high"
		)
		XCTAssertEqual(
			vm.modelDisplayName(
				rawModel: "gemini-3.0-flash-high",
				agentKind: .antigravity
			),
			"Gemini 3 Flash (High)"
		)
	}

	func testAntigravityOffersOnlyDefaultModelWithoutDiscoveredModels() async {
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			AntigravityACPModelSelectionFakeCodexController()
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .antigravity
		AgentACPModelRegistry.shared.test_reset(providerID: .antigravity)

		XCTAssertEqual(
			vm.modelOptions(for: .antigravity).map(\.rawValue),
			[AgentModel.defaultModel.rawValue]
		)
		XCTAssertEqual(
			vm.defaultModelRaw(for: .antigravity),
			AgentModel.defaultModel.rawValue
		)
	}
}

private final class AntigravityACPModelSelectionFakeCodexController: CodexSessionControlling {
	var hasActiveThread: Bool = false
	var events: AsyncStream<CodexNativeSessionController.Event> { AsyncStream { continuation in continuation.finish() } }

	func ensureEventsStreamReady() {}

	func startOrResume(
		existing _: CodexNativeSessionController.SessionRef?,
		baseInstructions _: String
	) async throws -> CodexNativeSessionController.SessionRef {
		hasActiveThread = true
		return CodexNativeSessionController.SessionRef(
			conversationID: "antigravity-acp-test",
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
			conversationID: "antigravity-acp-test",
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
