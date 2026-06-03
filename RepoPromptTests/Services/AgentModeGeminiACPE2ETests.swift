import XCTest
import MCP
@_spi(TestSupport) @testable import RepoPrompt

@MainActor
final class AgentModeGeminiACPE2ETests: XCTestCase {
	override func setUp() {
		super.setUp()
		AgentACPModelRegistry.shared.test_reset(providerID: .gemini)
	}

	override func tearDown() {
		AgentACPModelRegistry.shared.test_reset(providerID: .gemini)
		super.tearDown()
	}

	func testGeminiACPAgentModeCompletesEndToEndAfterRouting() async throws {
		let recorder = ACPAppPathRecorder()
		let harness = try makeHarness(scenario: .success, routeStrategy: .auto, recorder: recorder)
		let session = await harness.prepareGeminiSession()

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

	func testGeminiACPAgentModePermissionFlowWaitsAndResumes() async throws {
		let recorder = ACPAppPathRecorder()
		let harness = try makeHarness(scenario: .permissionThenComplete, routeStrategy: .auto, recorder: recorder)
		let session = await harness.prepareGeminiSession()

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

	func testGeminiACPAgentModeWaitsForPermissionUntilDecisionSubmitted() async throws {
		let recorder = ACPAppPathRecorder()
		let harness = try makeHarness(
			scenario: .permissionThenComplete,
			routeStrategy: .auto,
			recorder: recorder
		)
		let session = await harness.prepareGeminiSession()

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

	func testGeminiACPAgentModeWithoutRoutingNeverStartsPromptAndCanBeCancelled() async throws {
		let recorder = ACPAppPathRecorder()
		let harness = try makeHarness(scenario: .success, routeStrategy: .manual, recorder: recorder)
		let session = await harness.prepareGeminiSession()

		await harness.viewModel.startAgentRun(tabID: harness.tabID, initialMessage: "Route later")

		let bootstrapped = await waitForCondition(timeoutSeconds: 5.0) {
			session.geminiACPResumeMetadata.runtimeSessionID == harness.sessionID && session.acpController != nil
		}
		if !bootstrapped {
			XCTFail(await recorder.summary())
		}
		let promptStarted = await recorder.hasPhaseStarted("prompt")
		if promptStarted {
			XCTFail(await recorder.summary())
		}
		XCTAssertFalse(try harness.requestMethodSequence().contains("session/prompt"))

		await harness.viewModel.cancelAgentRun(tabID: harness.tabID)

		let cancelled = await waitForCondition(timeoutSeconds: 5.0) {
			session.runState == .cancelled
				&& session.agentTask == nil
				&& session.acpController == nil
		}
		if !cancelled {
			XCTFail(await recorder.summary())
		}
	}

	func testGeminiACPShowsStatusImmediatelyAndWhileWaitingForRouting() async throws {
		let recorder = ACPAppPathRecorder()
		let harness = try makeHarness(scenario: .success, routeStrategy: .manual, recorder: recorder)
		let session = await harness.prepareGeminiSession()

		await harness.viewModel.startAgentRun(tabID: harness.tabID, initialMessage: "Show status")

		let showedImmediateStatus = await waitForCondition(timeoutSeconds: 1.0) {
			session.runState == .running
				&& !(session.runningStatusText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
		}
		if !showedImmediateStatus {
			XCTFail(await recorder.summary())
		}

		let waitingForRouting = await waitForCondition(timeoutSeconds: 5.0) {
			session.geminiACPResumeMetadata.runtimeSessionID == harness.sessionID
				&& session.acpController != nil
				&& session.runningStatusText == "Waiting for connection…"
		}
		if !waitingForRouting {
			XCTFail(await recorder.summary())
		}

		await harness.viewModel.cancelAgentRun(tabID: harness.tabID)
		_ = await waitForCondition(timeoutSeconds: 5.0) {
			session.runState == .cancelled && session.agentTask == nil
		}
	}

	func testGeminiACPAgentModePromptRequestCanHangAfterPromptStartsUntilCancelled() async throws {
		let recorder = ACPAppPathRecorder()
		let harness = try makeHarness(
			scenario: .noPromptResponse,
			routeStrategy: .auto,
			recorder: recorder,
			environmentOverrides: [
				"ACP_TEST_LOAD_ERROR": "Internal error",
				"ACP_TEST_LOAD_ERROR_CODE": "-32603",
				"ACP_TEST_LOAD_ERROR_DATA_MESSAGE": "Invalid session identifier stale-gemini-acp-session. Searched for sessions in ~/.gemini/tmp/studio/chats. Use --list-sessions, --resume {number}, --resume {uuid}, or --resume latest."
			]
		)
		let session = await harness.prepareGeminiSession()

		await harness.viewModel.startAgentRun(tabID: harness.tabID, initialMessage: "Hang after prompt")

		let promptStarted = await waitForCondition(timeoutSeconds: 5.0) {
			session.runState == .running
				&& session.agentTask != nil
				&& session.acpController != nil
		}
		if !promptStarted {
			XCTFail(await recorder.summary())
		}
		let phaseStarted = await recorder.hasPhaseStarted("prompt")
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
		XCTAssertFalse(finalErrorText.localizedCaseInsensitiveContains("invalid session identifier"), finalErrorText)

		let methods = try harness.requestMethodSequence()
		XCTAssertEqual(methods.filter { $0 == "session/new" }.count, 2)
		XCTAssertTrue(methods.filter { $0 == "session/load" }.count >= 1)
		XCTAssertTrue(methods.filter { $0 == "session/prompt" }.count >= 2)
		XCTAssertEqual(session.providerSessionID, harness.sessionID)
	}

	func testGeminiACPAgentModeStreamingProgressCompletesSuccessfully() async throws {
		let recorder = ACPAppPathRecorder()
		let harness = try makeHarness(
			scenario: .streamingProgressThenComplete,
			routeStrategy: .auto,
			recorder: recorder
		)
		let session = await harness.prepareGeminiSession()

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

	func testGeminiACPSecondTurnUsesSessionLoad() async throws {
		let recorder = ACPAppPathRecorder()
		let harness = try makeHarness(scenario: .success, routeStrategy: .auto, recorder: recorder)
		let session = await harness.prepareGeminiSession()

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

	func testGeminiACPBootstrapMetadataBecomesLivePickerSource() async throws {
		let recorder = ACPAppPathRecorder()
		let modelsJSON = #"{"currentModelId":"gemini-2.5-pro-exp-0827","availableModels":[{"modelId":"gemini-2.5-pro-exp-0827","name":"Gemini 2.5 Pro Experimental","description":"Experimental Gemini Pro build"},{"modelId":"gemini-2.5-flash","name":"Gemini 2.5 Flash","description":"Fast Gemini model"}]}"#
		let harness = try makeHarness(
			scenario: .success,
			routeStrategy: .auto,
			recorder: recorder,
			environmentOverrides: ["ACP_TEST_MODELS_JSON": modelsJSON]
		)
		let session = await harness.prepareGeminiSession()

		await harness.viewModel.startAgentRun(tabID: harness.tabID, initialMessage: "Use live models")

		let completed = await waitForCondition(timeoutSeconds: 5.0) {
			session.runState == .completed
				&& session.providerSessionID == harness.sessionID
		}
		if !completed {
			XCTFail(await recorder.summary())
		}

		let discoveredModels = AgentACPModelRegistry.shared.test_snapshot(providerID: .gemini)
		XCTAssertEqual(discoveredModels?.currentModelRaw, "gemini-2.5-pro-exp-0827")
		XCTAssertEqual(session.selectedModelRaw, "gemini-2.5-pro-exp-0827")

		let options = harness.viewModel.modelOptions(for: .gemini)
		XCTAssertEqual(options.map(\.rawValue), [
			"gemini-2.5-pro-exp-0827",
			"gemini-2.5-flash"
		])
		XCTAssertFalse(options.contains(where: { $0.rawValue == "gemini-3-flash-preview" }))
		XCTAssertEqual(
			harness.viewModel.modelDisplayName(
				rawModel: session.selectedModelRaw,
				agentKind: .gemini
			),
			"Gemini 2.5 Pro Experimental"
		)
	}

	func testGeminiACPTrackerCallbacksRenderRepoPromptTools() async throws {
		let recorder = ACPAppPathRecorder()
		let harness = try makeHarness(scenario: .noPromptResponse, routeStrategy: .auto, recorder: recorder)
		let session = await harness.prepareGeminiSession()

		await harness.viewModel.startAgentRun(tabID: harness.tabID, initialMessage: "Track MCP tools")

		let trackerReady = await waitForAsyncCondition(timeoutSeconds: 5.0) {
			guard let runID = session.runID else { return false }
			return await ServerNetworkManager.shared.toolEventObserverCount(for: runID) > 0
		}
		if !trackerReady {
			XCTFail(await recorder.summary())
		}
		guard let runID = session.runID else {
			return XCTFail("Expected active Gemini run ID")
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
		scenario: MockGeminiACPScenario,
		routeStrategy: RouteStrategy,
		recorder: ACPAppPathRecorder,
		environmentOverrides: [String: String] = [:],
		requestTimeouts: ACPAgentSessionController.RequestTimeouts = .default
	) throws -> GeminiACPHarness {
		let tempDirectory = try makeTempDirectory()
		let scriptURL = tempDirectory.appendingPathComponent("mock-acp-server.sh")
		let logURL = tempDirectory.appendingPathComponent("agent-mode-gemini-acp.jsonl")
		let sessionID = "gemini-session-\(UUID().uuidString)"
		let geminiRoot = tempDirectory.appendingPathComponent("gemini-home", isDirectory: true)
		try FileManager.default.createDirectory(at: geminiRoot, withIntermediateDirectories: true)
		GeminiACPResumeIDResolver.test_setGlobalGeminiDirectoryURL(geminiRoot)
		var effectiveEnvironmentOverrides = environmentOverrides
		effectiveEnvironmentOverrides["ACP_TEST_GEMINI_CHAT_TMP_DIR"] = geminiRoot.appendingPathComponent("tmp", isDirectory: true).path
		effectiveEnvironmentOverrides["ACP_TEST_GEMINI_WORKSPACE_PATH"] = tempDirectory.path
		effectiveEnvironmentOverrides["ACP_TEST_GEMINI_WRITE_CHAT_ON_PROMPT"] = effectiveEnvironmentOverrides["ACP_TEST_GEMINI_WRITE_CHAT_ON_PROMPT"] ?? "true"
		addTeardownBlock {
			GeminiACPResumeIDResolver.test_setGlobalGeminiDirectoryURL(nil)
		}
		let fixtureURL = try mockACPServerFixtureURL()
		try FileManager.default.copyItem(at: fixtureURL, to: scriptURL)
		try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int(0o755))], ofItemAtPath: scriptURL.path)

		let vm = AgentModeViewModel(
			testWindowID: 99,
			testWorkspacePath: tempDirectory.path,
			codexControllerFactory: { _, _, _, _, _, _ in NoopCodexController() },
			acpProviderFactory: { agent, _ in
				guard agent == .gemini else { return nil }
				return ScriptBackedGeminiACPProvider(
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
		return GeminiACPHarness(
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
			.appendingPathComponent("AgentModeGeminiACPE2ETests-\(UUID().uuidString)", isDirectory: true)
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
private struct GeminiACPHarness {
	let viewModel: AgentModeViewModel
	let tabID: UUID
	let tempDirectory: URL
	let logURL: URL
	let sessionID: String
	let recorder: ACPAppPathRecorder

	func prepareGeminiSession() async -> AgentModeViewModel.TabSession {
		let session = await viewModel.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .gemini
		session.selectedModelRaw = "gemini-3-flash-preview"
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

private enum MockGeminiACPScenario: String {
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

private struct ScriptBackedGeminiACPProvider: ACPAgentProvider {
	private let base = GeminiACPAgentProvider(config: GeminiAgentConfig(modelString: "mock-model", enableDebugLogging: false))
	let scriptURL: URL
	let logURL: URL
	let scenario: String
	let sessionID: String
	let workingDirectory: String
	let environmentOverrides: [String: String]

	var providerID: ACPProviderID { .gemini }

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
