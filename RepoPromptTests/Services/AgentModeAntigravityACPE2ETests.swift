import XCTest
import MCP
@_spi(TestSupport) @testable import RepoPrompt

@MainActor
final class AgentModeAntigravityACPE2ETests: XCTestCase {
	override func setUp() {
		super.setUp()
		AgentACPModelRegistry.shared.test_reset(providerID: .antigravity)
	}

	override func tearDown() {
		AgentACPModelRegistry.shared.test_reset(providerID: .antigravity)
		super.tearDown()
	}

	func testAntigravityACPAgentModeCompletesEndToEndAfterRouting() async throws {
		let recorder = ACPAppPathRecorder()
		let harness = try makeHarness(scenario: .success, routeStrategy: .auto, recorder: recorder)
		let session = await harness.prepareAntigravitySession()

		await harness.viewModel.startAgentRun(tabID: harness.tabID, initialMessage: "Reply with OK")

		let completed = await waitForCondition(timeoutSeconds: 5.0) {
			session.runState == .completed
				&& session.agentTask == nil
				&& session.providerSessionID == harness.sessionID
		}
		if !completed {
			XCTFail(await recorder.summary())
		}
		XCTAssertEqual(session.providerSessionID, harness.sessionID)
		let promptCompleted = await recorder.hasPhaseCompleted("prompt")
		if !promptCompleted {
			XCTFail(await recorder.summary())
		}

		let methods = try harness.requestMethodSequence()
		XCTAssertTrue(methods.contains("initialize"))
		XCTAssertTrue(methods.contains("session/new"))
		XCTAssertTrue(methods.contains("session/prompt"))
		XCTAssertTrue(session.items.contains(where: { ($0.text ?? "").contains("OK from success scenario") }))
	}

	func testAntigravityACPAgentModePermissionFlowWaitsAndResumes() async throws {
		let recorder = ACPAppPathRecorder()
		let harness = try makeHarness(scenario: .permissionThenComplete, routeStrategy: .auto, recorder: recorder)
		let session = await harness.prepareAntigravitySession()

		await harness.viewModel.startAgentRun(tabID: harness.tabID, initialMessage: "Need permission")

		let sawApproval = await waitForCondition(timeoutSeconds: 5.0) {
			session.pendingApproval != nil && session.runState == .waitingForApproval
		}
		if !sawApproval {
			XCTFail(await recorder.summary())
		}

		harness.viewModel.submitApprovalDecision(tabID: harness.tabID, decision: .acceptForSession)

		let completed = await waitForCondition(timeoutSeconds: 5.0) {
			session.runState == .completed && session.pendingApproval == nil
		}
		if !completed {
			XCTFail(await recorder.summary())
		}

		let entries = try harness.readLoggedEntries()
		let permissionResponses = entries.filter {
			(($0["method"] as? String) == nil) && intJSONRPCID($0) == 900
		}
		XCTAssertFalse(permissionResponses.isEmpty, "Expected client response to permission request")
	}

	func testAntigravityACPAgentModeWaitsForPermissionUntilDecisionSubmitted() async throws {
		let recorder = ACPAppPathRecorder()
		let harness = try makeHarness(
			scenario: .permissionThenComplete,
			routeStrategy: .auto,
			recorder: recorder
		)
		let session = await harness.prepareAntigravitySession()

		await harness.viewModel.startAgentRun(tabID: harness.tabID, initialMessage: "Need permission")

		let sawApproval = await waitForCondition(timeoutSeconds: 5.0) {
			session.pendingApproval != nil && session.runState == .waitingForApproval
		}
		if !sawApproval {
			XCTFail(await recorder.summary())
		}

		try? await Task.sleep(nanoseconds: 1_000_000_000)
		XCTAssertEqual(session.runState, .waitingForApproval)
		XCTAssertNotNil(session.pendingApproval)

		harness.viewModel.submitApprovalDecision(tabID: harness.tabID, decision: .acceptForSession)

		let completed = await waitForCondition(timeoutSeconds: 5.0) {
			session.runState == .completed && session.pendingApproval == nil
		}
		if !completed {
			XCTFail(await recorder.summary())
		}
	}

	func testAntigravityACPAgentModeSendsPromptBeforeMCPRoutingAndCompletesOnceRouted() async throws {
		let recorder = ACPAppPathRecorder()
		let harness = try makeHarness(scenario: .success, routeStrategy: .manual, recorder: recorder)
		let session = await harness.prepareAntigravitySession()

		await harness.viewModel.startAgentRun(tabID: harness.tabID, initialMessage: "Route after prompt")

		// Antigravity connects to RepoPrompt MCP only after it receives the prompt.
		let promptSent = await waitForCondition(timeoutSeconds: 5.0) {
			(try? harness.requestMethodSequence().contains("session/prompt")) == true
		}
		if !promptSent {
			XCTFail(await recorder.summary())
		}
		XCTAssertEqual(session.runState, .running, "The run must wait for the MCP connection the prompt triggers")

		let runID = try XCTUnwrap(session.runID)
		MCPRoutingWaiter.signalRouted(runID)

		let completed = await waitForCondition(timeoutSeconds: 5.0) {
			session.runState == .completed && session.agentTask == nil
		}
		if !completed {
			XCTFail(await recorder.summary())
		}
	}

	func testAntigravityACPShowsStatusImmediately() async throws {
		let recorder = ACPAppPathRecorder()
		let harness = try makeHarness(scenario: .success, routeStrategy: .manual, recorder: recorder)
		let session = await harness.prepareAntigravitySession()

		await harness.viewModel.startAgentRun(tabID: harness.tabID, initialMessage: "Show status")

		let showedImmediateStatus = await waitForCondition(timeoutSeconds: 1.0) {
			session.runState == .running
				&& !(session.runningStatusText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
		}
		if !showedImmediateStatus {
			XCTFail(await recorder.summary())
		}

		await harness.viewModel.cancelAgentRun(tabID: harness.tabID)
		_ = await waitForCondition(timeoutSeconds: 5.0) {
			session.runState == .cancelled && session.agentTask == nil
		}
	}

	func testAntigravityACPAgentModePromptRequestCanHangAfterPromptStartsUntilCancelled() async throws {
		let recorder = ACPAppPathRecorder()
		let harness = try makeHarness(
			scenario: .noPromptResponse,
			routeStrategy: .auto,
			recorder: recorder,
			environmentOverrides: [
				"ACP_TEST_LOAD_ERROR": "Invalid params",
				"ACP_TEST_LOAD_ERROR_CODE": "-32602",
				"ACP_TEST_LOAD_ERROR_DATA_MESSAGE": "Session stale-antigravity-acp-session not found"
			]
		)
		let session = await harness.prepareAntigravitySession()

		await harness.viewModel.startAgentRun(tabID: harness.tabID, initialMessage: "Hang after prompt")

		let promptStarted = await waitForCondition(timeoutSeconds: 5.0) {
			session.runState == .running
				&& session.agentTask != nil
				&& session.acpController != nil
		}
		if !promptStarted {
			XCTFail(await recorder.summary())
		}
		let phaseStarted = await recorder.waitForPhaseStarted("prompt", timeout: 5.0)
		let phaseCompleted = await recorder.hasPhaseCompleted("prompt")
		if !(phaseStarted && !phaseCompleted) {
			XCTFail(await recorder.summary())
		}

		try? await Task.sleep(nanoseconds: 1_000_000_000)
		XCTAssertEqual(session.runState, .running)
		XCTAssertNotNil(session.agentTask)
		let initialErrorText = session.items
			.filter { $0.kind == .error }
			.compactMap(\.text)
			.joined(separator: "\n")
		XCTAssertFalse(initialErrorText.localizedCaseInsensitiveContains("timed out"), initialErrorText)

		await harness.viewModel.cancelAgentRun(tabID: harness.tabID)

		let cancelled = await waitForCondition(timeoutSeconds: 5.0) {
			session.runState == .cancelled
				&& session.agentTask == nil
				&& session.acpController == nil
		}
		if !cancelled {
			XCTFail(await recorder.summary())
		}
		XCTAssertEqual(session.providerSessionID, harness.sessionID)
		XCTAssertTrue(try harness.requestMethodSequence().contains("session/cancel"))

		await harness.viewModel.startAgentRun(tabID: harness.tabID, initialMessage: "Follow-up after cancel")

		let followupRecovered = await waitForAsyncCondition(timeoutSeconds: 5.0) {
			guard let methods = try? harness.requestMethodSequence() else { return false }
			return methods.filter { $0 == "session/load" }.count >= 1
				&& methods.filter { $0 == "session/new" }.count >= 2
		}
		if !followupRecovered {
			XCTFail(await recorder.summary())
		}

		let followupCompleted = await waitForCondition(timeoutSeconds: 8.0) {
			session.runState == .completed
				&& session.agentTask == nil
		}
		if !followupCompleted {
			XCTFail(await recorder.summary())
		}

		let finalErrorText = session.items
			.filter { $0.kind == .error }
			.compactMap(\.text)
			.joined(separator: "\n")
		XCTAssertFalse(finalErrorText.localizedCaseInsensitiveContains("not found"), finalErrorText)

		let methods = try harness.requestMethodSequence()
		XCTAssertEqual(methods.filter { $0 == "session/new" }.count, 2)
		XCTAssertTrue(methods.filter { $0 == "session/load" }.count >= 1)
		XCTAssertTrue(methods.filter { $0 == "session/prompt" }.count >= 2)
		XCTAssertEqual(session.providerSessionID, harness.sessionID)
	}

	func testAntigravityACPAgentModeStreamingProgressCompletesSuccessfully() async throws {
		let recorder = ACPAppPathRecorder()
		let harness = try makeHarness(
			scenario: .streamingProgressThenComplete,
			routeStrategy: .auto,
			recorder: recorder
		)
		let session = await harness.prepareAntigravitySession()

		await harness.viewModel.startAgentRun(tabID: harness.tabID, initialMessage: "Stream and finish")

		let completed = await waitForCondition(timeoutSeconds: 8.0) {
			session.runState == .completed
				&& session.agentTask == nil
		}
		if !completed {
			XCTFail(await recorder.summary())
		}
		let errorText = session.items
			.filter { $0.kind == .error }
			.compactMap(\.text)
			.joined(separator: "\n")
		XCTAssertFalse(errorText.localizedCaseInsensitiveContains("timed out"), errorText)
	}

	func testAntigravityACPSecondTurnUsesSessionLoad() async throws {
		let recorder = ACPAppPathRecorder()
		let harness = try makeHarness(scenario: .success, routeStrategy: .auto, recorder: recorder)
		let session = await harness.prepareAntigravitySession()

		await harness.viewModel.startAgentRun(tabID: harness.tabID, initialMessage: "First turn")
		let firstCompleted = await waitForCondition(timeoutSeconds: 8.0) {
			session.runState == .completed
				&& session.agentTask == nil
				&& session.providerSessionID == harness.sessionID
		}
		if !firstCompleted {
			XCTFail(await recorder.summary())
		}
		if let controller = session.acpController {
			await controller.shutdown()
			session.acpController = nil
		}

		await harness.viewModel.startAgentRun(tabID: harness.tabID, initialMessage: "Second turn")
		let secondCompleted = await waitForCondition(timeoutSeconds: 8.0) {
			session.runState == .completed && session.agentTask == nil
		}
		if !secondCompleted {
			XCTFail(await recorder.summary())
		}

		let methods = try harness.requestMethodSequence()
		XCTAssertGreaterThanOrEqual(methods.filter { $0 == "session/new" }.count, 1)
		XCTAssertGreaterThanOrEqual(methods.filter { $0 == "session/load" }.count, 1)
	}

	func testAntigravityACPBootstrapMetadataBecomesLivePickerSource() async throws {
		let recorder = ACPAppPathRecorder()
		let modelsJSON = #"{"currentModelId":"gemini-3.0-flash-high","availableModels":[{"modelId":"gemini-3.0-flash-high","name":"Gemini 3 Flash (High)","description":"Fast model, high thinking"},{"modelId":"gemini-3.0-flash-low","name":"Gemini 3 Flash (Low)","description":"Fast model, low thinking"}]}"#
		let harness = try makeHarness(
			scenario: .success,
			routeStrategy: .auto,
			recorder: recorder,
			environmentOverrides: ["ACP_TEST_MODELS_JSON": modelsJSON]
		)
		let session = await harness.prepareAntigravitySession()

		await harness.viewModel.startAgentRun(tabID: harness.tabID, initialMessage: "Use live models")

		let completed = await waitForCondition(timeoutSeconds: 5.0) {
			session.runState == .completed
				&& session.providerSessionID == harness.sessionID
		}
		if !completed {
			XCTFail(await recorder.summary())
		}

		let discoveredModels = AgentACPModelRegistry.shared.test_snapshot(providerID: .antigravity)
		XCTAssertEqual(discoveredModels?.currentModelRaw, "gemini-3.0-flash-high")
		XCTAssertEqual(session.selectedModelRaw, "gemini-3.0-flash-high")

		let options = harness.viewModel.modelOptions(for: .antigravity)
		XCTAssertEqual(options.map(\.rawValue), [
			"gemini-3.0-flash-high",
			"gemini-3.0-flash-low"
		])
		XCTAssertEqual(
			harness.viewModel.modelDisplayName(
				rawModel: session.selectedModelRaw,
				agentKind: .antigravity
			),
			"Gemini 3 Flash (High)"
		)
	}

	func testAntigravityACPTrackerCallbacksRenderRepoPromptTools() async throws {
		let recorder = ACPAppPathRecorder()
		let harness = try makeHarness(scenario: .noPromptResponse, routeStrategy: .auto, recorder: recorder)
		let session = await harness.prepareAntigravitySession()

		await harness.viewModel.startAgentRun(tabID: harness.tabID, initialMessage: "Track MCP tools")

		let trackerReady = await waitForAsyncCondition(timeoutSeconds: 5.0) {
			guard let runID = session.runID else { return false }
			return await ServerNetworkManager.shared.toolEventObserverCount(for: runID) > 0
		}
		if !trackerReady {
			XCTFail(await recorder.summary())
		}
		guard let runID = session.runID else {
			return XCTFail("Expected active Antigravity run ID")
		}

		let invocationID = UUID()
		_ = await ServerNetworkManager.shared.debugFireToolCalledObservers(
			runID: runID,
			invocationID: invocationID,
			toolName: "functions.mcp_RepoPrompt__read_file",
			args: ["path": .string("README.md")]
		)
		_ = await ServerNetworkManager.shared.debugFireToolCompletedObservers(
			runID: runID,
			invocationID: invocationID,
			toolName: "functions.mcp_RepoPrompt__read_file",
			args: ["path": .string("README.md")],
			resultJSON: #"{"content":"mock file contents"}"#,
			isError: false
		)

		let delivered = await waitForCondition(timeoutSeconds: 2.0) {
			session.items.contains(where: {
				$0.kind == .toolResult
					&& $0.toolInvocationID == invocationID
					&& $0.toolName == "read_file"
			})
		}
		XCTAssertTrue(delivered)

		await harness.viewModel.cancelAgentRun(tabID: harness.tabID)
		_ = await waitForCondition(timeoutSeconds: 5.0) {
			session.runState == .cancelled && session.agentTask == nil
		}
	}

	private func makeHarness(
		scenario: MockAntigravityACPScenario,
		routeStrategy: RouteStrategy,
		recorder: ACPAppPathRecorder,
		environmentOverrides: [String: String] = [:],
		requestTimeouts: ACPAgentSessionController.RequestTimeouts = .default
	) throws -> AntigravityACPHarness {
		let tempDirectory = try makeTempDirectory()
		let scriptURL = tempDirectory.appendingPathComponent("mock-acp-server.sh")
		let logURL = tempDirectory.appendingPathComponent("agent-mode-antigravity-acp.jsonl")
		let sessionID = "antigravity-session-\(UUID().uuidString)"
		let effectiveEnvironmentOverrides = environmentOverrides
		let fixtureURL = try mockACPServerFixtureURL()
		try FileManager.default.copyItem(at: fixtureURL, to: scriptURL)
		try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int(0o755))], ofItemAtPath: scriptURL.path)

		let vm = AgentModeViewModel(
			testWindowID: 99,
			testWorkspacePath: tempDirectory.path,
			codexControllerFactory: { _, _, _, _, _, _ in NoopCodexController() },
			acpProviderFactory: { agent, _ in
				guard agent == .antigravity else { return nil }
				return ScriptBackedAntigravityACPProvider(
					scriptURL: scriptURL,
					logURL: logURL,
					scenario: scenario.rawValue,
					sessionID: sessionID,
					workingDirectory: tempDirectory.path,
					environmentOverrides: effectiveEnvironmentOverrides
				)
			},
			acpControllerFactory: { provider, runRequest in
				try ACPAgentSessionController(
					provider: provider,
					runRequest: runRequest,
					diagnosticSink: { event in
						Task {
							await recorder.recordDiagnostic(event)
						}
					},
					requestTimeouts: requestTimeouts
				)
			},
			connectionPolicyInstaller: { clientName, windowID, restrictedTools, oneShot, reason, ttl, tabID, runID, additionalTools, purpose, _, _, _ in
				await recorder.recordPolicy(
					PolicyInstallCall(
						clientName: clientName,
						windowID: windowID,
						restrictedTools: restrictedTools,
						oneShot: oneShot,
						reason: reason,
						ttl: ttl,
						tabID: tabID,
						runID: runID,
						additionalTools: additionalTools,
						purpose: purpose
					)
				)
				if routeStrategy == .auto, let runID {
					MCPRoutingWaiter.signalRouted(runID)
				}
			},
			mcpServerEnabler: {
				await recorder.recordServerEnable()
			}
		)
		return AntigravityACPHarness(
			viewModel: vm,
			tabID: UUID(),
			tempDirectory: tempDirectory,
			logURL: logURL,
			sessionID: sessionID,
			recorder: recorder
		)
	}

	private func makeTempDirectory() throws -> URL {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("AgentModeAntigravityACPE2ETests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		addTeardownBlock {
			try? FileManager.default.removeItem(at: url)
		}
		return url
	}

	private func mockACPServerFixtureURL() throws -> URL {
		let url = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.appendingPathComponent("Fixtures/mock-acp-server.sh")
		guard FileManager.default.fileExists(atPath: url.path) else {
			throw XCTSkip("Missing mock ACP server fixture at \(url.path)")
		}
		return url
	}

	private func waitForCondition(
		timeoutSeconds: TimeInterval,
		condition: @escaping @MainActor () -> Bool
	) async -> Bool {
		let deadline = Date().addingTimeInterval(timeoutSeconds)
		while Date() < deadline {
			if condition() {
				return true
			}
			try? await Task.sleep(nanoseconds: 20_000_000)
		}
		return condition()
	}

	private func waitForAsyncCondition(
		timeoutSeconds: TimeInterval,
		condition: @escaping @MainActor () async -> Bool
	) async -> Bool {
		let deadline = Date().addingTimeInterval(timeoutSeconds)
		while Date() < deadline {
			if await condition() {
				return true
			}
			try? await Task.sleep(nanoseconds: 20_000_000)
		}
		return await condition()
	}

	private func intJSONRPCID(_ object: [String: Any]) -> Int? {
		if let value = object["id"] as? Int {
			return value
		}
		if let value = object["id"] as? NSNumber {
			return value.intValue
		}
		return nil
	}
}

@MainActor
private struct AntigravityACPHarness {
	let viewModel: AgentModeViewModel
	let tabID: UUID
	let tempDirectory: URL
	let logURL: URL
	let sessionID: String
	let recorder: ACPAppPathRecorder

	func prepareAntigravitySession() async -> AgentModeViewModel.TabSession {
		let session = await viewModel.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .antigravity
		session.selectedModelRaw = AgentModel.defaultModel.rawValue
		return session
	}

	func readLoggedEntries() throws -> [[String: Any]] {
		guard FileManager.default.fileExists(atPath: logURL.path) else { return [] }
		let content = try String(contentsOf: logURL, encoding: .utf8)
		return try content
			.split(whereSeparator: \.isNewline)
			.compactMap { line -> [String: Any]? in
				guard !line.isEmpty else { return nil }
				return try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
			}
	}

	func requestMethodSequence() throws -> [String] {
		try readLoggedEntries().compactMap { $0["method"] as? String }
	}
}

private enum RouteStrategy {
	case auto
	case manual
}

private enum MockAntigravityACPScenario: String {
	case success = "success"
	case permissionThenComplete = "permission_then_complete"
	case noPromptResponse = "no_prompt_response"
	case streamingProgressThenComplete = "streaming_progress_then_complete"
}

private actor ACPAppPathRecorder {
	private var diagnostics: [ACPAgentSessionController.DiagnosticEvent] = []
	private var policyCalls: [PolicyInstallCall] = []
	private var serverEnableCount = 0

	func recordDiagnostic(_ event: ACPAgentSessionController.DiagnosticEvent) {
		diagnostics.append(event)
	}

	func recordPolicy(_ call: PolicyInstallCall) {
		policyCalls.append(call)
	}

	func recordServerEnable() {
		serverEnableCount += 1
	}

	func hasPhaseStarted(_ phase: String) -> Bool {
		diagnostics.contains {
			if case .phaseStarted(let value) = $0 {
				return value == phase
			}
			return false
		}
	}

	func hasPhaseCompleted(_ phase: String) -> Bool {
		diagnostics.contains {
			if case .phaseCompleted(let value) = $0 {
				return value == phase
			}
			return false
		}
	}

	func waitForPhaseStarted(_ phase: String, timeout: TimeInterval) async -> Bool {
		let deadline = Date().addingTimeInterval(timeout)
		while Date() < deadline {
			if hasPhaseStarted(phase) {
				return true
			}
			try? await Task.sleep(nanoseconds: 20_000_000)
		}
		return hasPhaseStarted(phase)
	}

	func summary() -> String {
		let diagnosticLines = diagnostics.suffix(12).map(Self.describe)
		let policyLines = policyCalls.map { call in
			"policy(client=\(call.clientName), runID=\(call.runID?.uuidString ?? "nil"), purpose=\(call.purpose.rawValue))"
		}
		return (["serverEnableCount=\(serverEnableCount)"] + policyLines + diagnosticLines).joined(separator: "\n")
	}

	private static func describe(_ event: ACPAgentSessionController.DiagnosticEvent) -> String {
		switch event {
		case .info(let text):
			return "info: \(text)"
		case .outboundJSON(let line):
			return "out: \(line)"
		case .inboundJSON(let line):
			return "in: \(line)"
		case .stderrLine(let line):
			return "stderr: \(line)"
		case .phaseStarted(let phase):
			return "phase-start: \(phase)"
		case .phaseCompleted(let phase):
			return "phase-complete: \(phase)"
		case .invalidJSON(let preview):
			return "invalid-json: \(preview)"
		case .unmatchedResponse(let id, let line):
			return "unmatched-response: \(id) \(line)"
		}
	}
}

private struct PolicyInstallCall {
	let clientName: String
	let windowID: Int
	let restrictedTools: Set<String>
	let oneShot: Bool
	let reason: String?
	let ttl: TimeInterval
	let tabID: UUID?
	let runID: UUID?
	let additionalTools: Set<String>?
	let purpose: MCPRunPurpose
}

private struct ScriptBackedAntigravityACPProvider: ACPAgentProvider {
	private let base = AntigravityACPAgentProvider(config: AntigravityAgentConfig(modelString: "mock-model", enableDebugLogging: false))
	let scriptURL: URL
	let logURL: URL
	let scenario: String
	let sessionID: String
	let workingDirectory: String
	let environmentOverrides: [String: String]

	var providerID: ACPProviderID { .antigravity }

	func support(for _: ACPRunRequest) async -> ACPSupportResult {
		.supported
	}

	func makeLaunchConfiguration(for _: ACPRunRequest) throws -> ACPLaunchConfiguration {
		var environment: [String: String] = [
			"ACP_TEST_LOG": logURL.path,
			"ACP_TEST_SCENARIO": scenario,
			"ACP_TEST_SESSION_ID": sessionID
		]
		for (key, value) in environmentOverrides {
			environment[key] = value
		}
		return ACPLaunchConfiguration(
			providerID: providerID,
			command: "/bin/sh",
			arguments: [scriptURL.path],
			environment: environment,
			workingDirectory: workingDirectory,
			additionalPathHints: [],
			enableDebugLogging: false
		)
	}

	func makeSessionConfiguration(
		for request: ACPRunRequest,
		mcpServer: RepoPromptMCPServerConfiguration
	) throws -> ACPSessionConfiguration {
		let mode: ACPSessionConfiguration.Mode
		if let resume = request.resumeSessionID, !resume.isEmpty {
			mode = .load(existingSessionID: resume)
		} else {
			mode = .new
		}
		return ACPSessionConfiguration(
			mode: mode,
			workingDirectory: workingDirectory,
			mcpServers: [mcpServer]
		)
	}

	func buildPromptBlocks(for message: AgentMessage, request: ACPRunRequest) throws -> [[String: Any]] {
		try base.buildPromptBlocks(for: message, request: request)
	}

	func normalizeSessionUpdate(_ payload: [String: Any], sessionID: String) -> [NormalizedAgentRuntimeEvent] {
		base.normalizeSessionUpdate(payload, sessionID: sessionID)
	}

	func normalizeError(_ error: Error) -> Error {
		base.normalizeError(error)
	}
}

private final class NoopCodexController: CodexSessionControlling {
	var hasActiveThread: Bool { false }
	var events: AsyncStream<CodexNativeSessionController.Event> { AsyncStream { _ in } }

	func ensureEventsStreamReady() {}

	func startOrResume(
		existing: CodexNativeSessionController.SessionRef?,
		baseInstructions: String
	) async throws -> CodexNativeSessionController.SessionRef {
		CodexNativeSessionController.SessionRef(conversationID: "noop", rolloutPath: nil, model: nil, reasoningEffort: nil)
	}

	func sendUserMessage(_ text: String) async throws {}
	func sendUserTurn(text: String, images: [AgentImageAttachment]) async throws {}
	func cancelCurrentTurn() async {}
	func shutdown() async {}
	func respondToServerRequest(id: CodexAppServerRequestID, result: [String: Any]) async {}
}
