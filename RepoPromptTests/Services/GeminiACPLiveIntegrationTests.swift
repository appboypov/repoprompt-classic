import XCTest
@testable import RepoPrompt

@MainActor
final class GeminiACPLiveIntegrationTests: XCTestCase {
	func testLiveGeminiStaggeredTabsRouteToolsAndReuseSessionsOnFollowUp() async throws {
		let harness = try await makeHarness()
		addTeardownBlock {
			await harness.teardownLiveState()
		}

		let first = await harness.prepareGeminiSession()
		let second = await harness.prepareGeminiSession()
		let firstFollowUpReply = "FOLLOW_UP_OK_A"
		let secondFollowUpReply = "FOLLOW_UP_OK_B"

		await harness.viewModel.startAgentRun(
			tabID: first.tabID,
			initialMessage: """
			Use the RepoPrompt get_file_tree tool first to inspect this workspace.
			Then use RepoPrompt tools to read PARALLEL_A.txt.
			Reply with exactly the contents of PARALLEL_A.txt and nothing else.
			"""
		)
		let firstStarted = await harness.waitForCondition(timeoutSeconds: 30) {
			first.session.runState == .running && first.session.agentTask != nil
		}
		let firstStartFailure = await harness.failureDescription(for: first.session, label: "staggered tab A start")
		XCTAssertTrue(firstStarted, firstStartFailure)

		await harness.viewModel.startAgentRun(
			tabID: second.tabID,
			initialMessage: """
			Use the RepoPrompt get_file_tree tool first to inspect this workspace.
			Then use RepoPrompt tools to read PARALLEL_B.txt.
			Reply with exactly the contents of PARALLEL_B.txt and nothing else.
			"""
		)

		let firstCompleted = await harness.waitForCondition(timeoutSeconds: 60) {
			first.session.runState == .completed && first.session.agentTask == nil
		}
		let secondCompleted = await harness.waitForCondition(timeoutSeconds: 60) {
			second.session.runState == .completed && second.session.agentTask == nil
		}
		let firstInitialFailure = await harness.failureDescription(for: first.session, label: "staggered tab A initial")
		let secondInitialFailure = await harness.failureDescription(for: second.session, label: "staggered tab B initial")
		XCTAssertTrue(firstCompleted, firstInitialFailure)
		XCTAssertTrue(secondCompleted, secondInitialFailure)
		XCTAssertTrue(harness.assistantTranscript(in: first.session).contains(harness.fixture.parallelAToken))
		XCTAssertTrue(harness.assistantTranscript(in: second.session).contains(harness.fixture.parallelBToken))
		XCTAssertFalse(harness.repoPromptToolItems(in: first.session).isEmpty)
		XCTAssertFalse(harness.repoPromptToolItems(in: second.session).isEmpty)
		let firstRunID = try XCTUnwrap(first.session.runID)
		let secondRunID = try XCTUnwrap(second.session.runID)
		let firstProviderSessionID = try XCTUnwrap(first.session.providerSessionID)
		let secondProviderSessionID = try XCTUnwrap(second.session.providerSessionID)
		let firstControllerIdentity = ObjectIdentifier(try XCTUnwrap(first.session.acpController))
		let secondControllerIdentity = ObjectIdentifier(try XCTUnwrap(second.session.acpController))
		let firstPolicyCount = await harness.policyRecorder.count(for: first.tabID)
		let secondPolicyCount = await harness.policyRecorder.count(for: second.tabID)
		XCTAssertNotEqual(firstRunID, secondRunID)
		XCTAssertNotEqual(firstProviderSessionID, secondProviderSessionID)
		XCTAssertNotEqual(firstControllerIdentity, secondControllerIdentity)

		await harness.viewModel.startAgentRun(
			tabID: first.tabID,
			initialMessage: "Reply with exactly \(firstFollowUpReply) and nothing else."
		)
		let firstFollowUpStarted = await harness.waitForCondition(timeoutSeconds: 30) {
			first.session.runState == .running && first.session.agentTask != nil
		}
		let firstFollowUpStartFailure = await harness.failureDescription(for: first.session, label: "staggered tab A follow-up start")
		XCTAssertTrue(firstFollowUpStarted, firstFollowUpStartFailure)

		await harness.viewModel.startAgentRun(
			tabID: second.tabID,
			initialMessage: "Reply with exactly \(secondFollowUpReply) and nothing else."
		)

		let firstFollowUpCompleted = await harness.waitForCondition(timeoutSeconds: 60) {
			first.session.runState == .completed && first.session.agentTask == nil
		}
		let secondFollowUpCompleted = await harness.waitForCondition(timeoutSeconds: 60) {
			second.session.runState == .completed && second.session.agentTask == nil
		}
		let firstFollowUpFailure = await harness.failureDescription(for: first.session, label: "staggered tab A follow-up")
		let secondFollowUpFailure = await harness.failureDescription(for: second.session, label: "staggered tab B follow-up")
		XCTAssertTrue(firstFollowUpCompleted, firstFollowUpFailure)
		XCTAssertTrue(secondFollowUpCompleted, secondFollowUpFailure)
		XCTAssertTrue(harness.assistantTranscript(in: first.session).contains(firstFollowUpReply))
		XCTAssertTrue(harness.assistantTranscript(in: second.session).contains(secondFollowUpReply))
		XCTAssertEqual(first.session.runID, firstRunID)
		XCTAssertEqual(second.session.runID, secondRunID)
		XCTAssertEqual(first.session.providerSessionID, firstProviderSessionID)
		XCTAssertEqual(second.session.providerSessionID, secondProviderSessionID)
		XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(first.session.acpController)), firstControllerIdentity)
		XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(second.session.acpController)), secondControllerIdentity)
		let finalFirstPolicyCount = await harness.policyRecorder.count(for: first.tabID)
		let finalSecondPolicyCount = await harness.policyRecorder.count(for: second.tabID)
		XCTAssertEqual(finalFirstPolicyCount, firstPolicyCount)
		XCTAssertEqual(finalSecondPolicyCount, secondPolicyCount)
	}

	func testLiveGeminiCancelAndRestart() async throws {
		let harness = try await makeHarness()
		addTeardownBlock {
			await harness.teardownLiveState()
		}

		let prepared = await harness.prepareGeminiSession()

		await harness.viewModel.startAgentRun(
			tabID: prepared.tabID,
			initialMessage: """
			Use RepoPrompt tools to inspect CANCEL_SLOW.txt and then write an extremely detailed, multi-section explanation of everything in it.
			Take your time and be exhaustive.
			"""
		)

		let started = await harness.waitForCondition(timeoutSeconds: 30) {
			prepared.session.runState == .running
				&& prepared.session.agentTask != nil
				&& prepared.session.acpController != nil
		}
		let cancelStartFailure = await harness.failureDescription(for: prepared.session, label: "cancel start")
		XCTAssertTrue(started, cancelStartFailure)
		let preCancelRunID = prepared.session.runID
		try? await Task.sleep(nanoseconds: 2_000_000_000)

		await harness.viewModel.cancelAgentRun(tabID: prepared.tabID, waitForCleanup: true)

		let cancelled = await harness.waitForCondition(timeoutSeconds: 30) {
			prepared.session.runState == .cancelled
				&& prepared.session.agentTask == nil
				&& prepared.session.acpController == nil
				&& prepared.session.runID == nil
		}
		let cancelledFailure = await harness.failureDescription(for: prepared.session, label: "cancelled state")
		XCTAssertTrue(cancelled, cancelledFailure)

		await harness.viewModel.startAgentRun(
			tabID: prepared.tabID,
			initialMessage: "Reply with exactly OK and nothing else."
		)
		let restarted = await harness.waitForCondition(timeoutSeconds: 60) {
			prepared.session.runState == .completed && prepared.session.agentTask == nil
		}
		let restartFailure = await harness.failureDescription(for: prepared.session, label: "restart")
		XCTAssertTrue(restarted, restartFailure)
		XCTAssertTrue(harness.assistantTranscript(in: prepared.session).contains("OK"))
		XCTAssertFalse((prepared.session.providerSessionID ?? "").isEmpty)
		XCTAssertNotNil(prepared.session.runID)
		if let preCancelRunID {
			XCTAssertNotEqual(prepared.session.runID, preCancelRunID)
		}
	}

	private func makeHarness() async throws -> LiveGeminiHarness {
		let modelRaw = ProcessInfo.processInfo.environment["GEMINI_ACP_MODEL"] ?? "gemini-2.5-flash"
		let config = GeminiAgentConfig(
			commandName: ProcessInfo.processInfo.environment["GEMINI_CLI_PATH"] ?? "gemini",
			additionalPathHints: CLIPathHints.gemini,
			modelString: modelRaw,
			enableDebugLogging: ProcessInfo.processInfo.environment["GEMINI_ACP_DEBUG"] == "1"
		)
		let provider = GeminiACPAgentProvider(config: config)
		let workspaceURL = try Self.makeWorkspaceDirectory()
		let fixture = try Self.writeWorkspaceFixture(into: workspaceURL)
		let supportRequest = ACPRunRequest(
			agentKind: .gemini,
			modelString: modelRaw,
			workspacePath: workspaceURL.path,
			resumeSessionID: nil,
			attachments: [],
			taskLabelKind: nil
		)

		switch await provider.support(for: supportRequest) {
		case .supported:
			break
		case .unsupported(let reason):
			throw XCTSkip("Gemini ACP runtime unavailable: \(reason)")
		}

		let windowState = try await Self.makeWindowState(root: workspaceURL)
		WindowStatesManager.shared.registerWindowState(windowState)
		let policyRecorder = LivePolicyRecorder()
		let viewModel = AgentModeViewModel(
			testWindowID: windowState.windowID,
			testWorkspacePath: workspaceURL.path,
			testWorkspaceDirectory: workspaceURL,
			codexControllerFactory: { _, _, _, _, _, _ in NoopCodexController() },
			acpProviderFactory: { agent, selectedModel in
				guard agent == .gemini else { return nil }
				return GeminiACPAgentProvider(
					config: GeminiAgentConfig(
						commandName: config.commandName,
						additionalPathHints: config.additionalPathHints,
						modelString: selectedModel ?? modelRaw,
						enableDebugLogging: config.enableDebugLogging
					)
				)
			},
			connectionPolicyInstaller: { clientName, windowID, restrictedTools, oneShot, reason, ttl, tabID, runID, additionalTools, purpose, taskLabelKind, allowsAgentExternalControlTools, requiresExpectedAgentPID in
				await policyRecorder.record(
					.init(
						clientName: clientName,
						windowID: windowID,
						restrictedTools: restrictedTools,
						oneShot: oneShot,
						reason: reason,
						ttl: ttl,
						tabID: tabID,
						runID: runID,
						additionalTools: additionalTools,
						purpose: purpose,
						taskLabelKind: taskLabelKind
					)
				)
				await ServerNetworkManager.shared.installClientConnectionPolicy(
					for: clientName,
					windowID: windowID,
					restrictedTools: restrictedTools,
					oneShot: oneShot,
					reason: reason,
					ttl: ttl,
					tabID: tabID,
					runID: runID,
					additionalTools: additionalTools,
					purpose: purpose,
					taskLabelKind: taskLabelKind,
					allowsAgentExternalControlTools: allowsAgentExternalControlTools,
					requiresExpectedAgentPID: requiresExpectedAgentPID
				)
				if let runID {
					MCPRoutingWaiter.signalRouted(runID)
				}
			},
			mcpServerEnabler: {
				await windowState.mcpServer.startServer()
				await ServerNetworkManager.shared.ensureBootstrapHealthy(force: true)
			},
			testMCPServer: windowState.mcpServer
		)

		return LiveGeminiHarness(
			workspaceURL: workspaceURL,
			fixture: fixture,
			viewModel: viewModel,
			modelRaw: modelRaw,
			policyRecorder: policyRecorder,
			windowState: windowState
		)
	}

	private static func makeWindowState(root: URL) async throws -> WindowState {
		let windowState = WindowState()
		let bootstrapTab = ComposeTabState(
			name: "Live Bootstrap",
			lastModified: Date()
		)
		let workspace = WorkspaceModel(
			name: "Gemini ACP Live Workspace",
			repoPaths: [root.path],
			customStoragePath: root,
			ephemeralFlag: true,
			composeTabs: [bootstrapTab],
			activeComposeTabID: bootstrapTab.id
		)
		windowState.workspaceManager.workspaces.append(workspace)
		await windowState.workspaceManager.switchWorkspace(to: workspace, saveState: false)
		return windowState
	}

	private static func makeWorkspaceDirectory() throws -> URL {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("GeminiACPLiveIntegrationTests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		return url
	}

	private static func writeWorkspaceFixture(into workspaceURL: URL) throws -> LiveWorkspaceFixture {
		let fixture = LiveWorkspaceFixture(
			liveToolToken: "live-tool-token-\(UUID().uuidString)",
			followUpFirstToken: "follow-up-first-\(UUID().uuidString)",
			followUpSecondToken: "follow-up-second-\(UUID().uuidString)",
			parallelAToken: "parallel-a-\(UUID().uuidString)",
			parallelBToken: "parallel-b-\(UUID().uuidString)",
			restartToken: "restart-ok-\(UUID().uuidString)"
		)
		let files: [(String, String)] = [
			("LIVE_TOOL_TARGET.txt", fixture.liveToolToken),
			("FOLLOW_UP_FIRST.txt", fixture.followUpFirstToken),
			("FOLLOW_UP_SECOND.txt", fixture.followUpSecondToken),
			("PARALLEL_A.txt", fixture.parallelAToken),
			("PARALLEL_B.txt", fixture.parallelBToken),
			("RESTART_OK.txt", fixture.restartToken),
			(
				"CANCEL_SLOW.txt",
				(1...400).map { "Line \($0): Gemini ACP cancellation stress payload." }.joined(separator: "\n")
			)
		]
		for (name, content) in files {
			try content.write(
				to: workspaceURL.appendingPathComponent(name),
				atomically: true,
				encoding: .utf8
			)
		}
		return fixture
	}
}

@MainActor
private final class LiveGeminiHarness {
	struct PreparedSession {
		let tabID: UUID
		let session: AgentModeViewModel.TabSession
	}

	let workspaceURL: URL
	let fixture: LiveWorkspaceFixture
	let viewModel: AgentModeViewModel
	let modelRaw: String
	let policyRecorder: LivePolicyRecorder
	let windowState: WindowState

	private var tabIDs: Set<UUID> = []

	init(
		workspaceURL: URL,
		fixture: LiveWorkspaceFixture,
		viewModel: AgentModeViewModel,
		modelRaw: String,
		policyRecorder: LivePolicyRecorder,
		windowState: WindowState
	) {
		self.workspaceURL = workspaceURL
		self.fixture = fixture
		self.viewModel = viewModel
		self.modelRaw = modelRaw
		self.policyRecorder = policyRecorder
		self.windowState = windowState
	}

	func prepareGeminiSession() async -> PreparedSession {
		let tabID = UUID()
		tabIDs.insert(tabID)
		let session = await viewModel.ensureSessionReady(tabID: tabID)
		registerWorkspaceTab(tabID: tabID, activeAgentSessionID: session.activeAgentSessionID)
		session.selectedAgent = .gemini
		session.selectedModelRaw = modelRaw
		return PreparedSession(tabID: tabID, session: session)
	}

	func waitForCondition(
		timeoutSeconds: TimeInterval,
		pollIntervalNanoseconds: UInt64 = 50_000_000,
		condition: @escaping @MainActor () -> Bool
	) async -> Bool {
		let deadline = Date().addingTimeInterval(timeoutSeconds)
		while Date() < deadline {
			if condition() {
				return true
			}
			try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
		}
		return condition()
	}

	func repoPromptToolItems(in session: AgentModeViewModel.TabSession) -> [AgentChatItem] {
		session.items.filter { item in
			guard item.kind == .toolCall || item.kind == .toolResult else { return false }
			return !MCPIntegrationHelper.normalizedRepoPromptToolName(item.toolName ?? "").isEmpty
		}
	}

	func assistantTranscript(in session: AgentModeViewModel.TabSession) -> String {
		session.items.compactMap { item -> String? in
			guard item.kind == .assistant || item.kind == .assistantInline else { return nil }
			return item.text
		}.joined()
	}

	func failureDescription(for session: AgentModeViewModel.TabSession, label: String) async -> String {
		let itemsTail = session.items.suffix(12).map { item in
			let name = item.toolName.map { " tool=\($0)" } ?? ""
			let text = item.text.replacingOccurrences(of: "\n", with: "\\n")
			return "[\(item.kind.rawValue)]\(name) \(text)"
		}.joined(separator: "\n")
		return [
			"label=\(label)",
			"runState=\(session.runState.rawValue)",
			"providerSessionID=\(session.providerSessionID ?? "nil")",
			"runID=\(session.runID?.uuidString ?? "nil")",
			"policySummary=\(await policyRecorder.summary())",
			"itemsTail=\n\(itemsTail)"
		].joined(separator: "\n")
	}

	func teardownLiveState() async {
		for tabID in tabIDs {
			await viewModel.cancelAgentRun(tabID: tabID, waitForCleanup: true)
		}
		for policy in await policyRecorder.policies() {
			await ServerNetworkManager.shared.clearClientConnectionPolicy(
				for: policy.clientName,
				windowID: policy.windowID,
				runID: policy.runID
			)
			if let runID = policy.runID {
				await MCPRoutingWaiter.cleanup(runID: runID)
			}
		}
		await windowState.tearDown()
		WindowStatesManager.shared.unregisterWindowState(windowState)
		try? FileManager.default.removeItem(at: workspaceURL)
	}

	private func registerWorkspaceTab(tabID: UUID, activeAgentSessionID: UUID?) {
		guard
			let workspaceID = windowState.workspaceManager.activeWorkspaceID,
			let workspaceIndex = windowState.workspaceManager.workspaces.firstIndex(where: { $0.id == workspaceID })
		else {
			XCTFail("Expected live test workspace to be active")
			return
		}

		var workspace = windowState.workspaceManager.workspaces[workspaceIndex]
		if let existingIndex = workspace.composeTabs.firstIndex(where: { $0.id == tabID }) {
			workspace.composeTabs[existingIndex].activeAgentSessionID = activeAgentSessionID
			workspace.composeTabs[existingIndex].lastModified = Date()
		} else {
			workspace.composeTabs.append(
				ComposeTabState(
					id: tabID,
					name: "Live Session \(workspace.composeTabs.count + 1)",
					lastModified: Date(),
					activeAgentSessionID: activeAgentSessionID
				)
			)
		}
		workspace.activeComposeTabID = tabID
		windowState.workspaceManager.workspaces[workspaceIndex] = workspace
		windowState.workspaceManager.activeWorkspace = workspace
		windowState.promptManager.loadComposeTabsFromWorkspace(workspace, syncPromptText: true)
	}
}

private struct LiveWorkspaceFixture {
	let liveToolToken: String
	let followUpFirstToken: String
	let followUpSecondToken: String
	let parallelAToken: String
	let parallelBToken: String
	let restartToken: String
}

private actor LivePolicyRecorder {
	struct Entry: Sendable {
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
		let taskLabelKind: AgentModelCatalog.TaskLabelKind?
	}

	private var entries: [Entry] = []

	func record(_ entry: Entry) {
		entries.append(entry)
	}

	func count(for tabID: UUID) -> Int {
		entries.filter { $0.tabID == tabID }.count
	}

	func policies() -> [Entry] {
		entries
	}

	func summary() -> String {
		entries.map { entry in
			"client=\(entry.clientName) window=\(entry.windowID) tab=\(entry.tabID?.uuidString ?? "nil") run=\(entry.runID?.uuidString ?? "nil") purpose=\(entry.purpose.rawValue)"
		}.joined(separator: " | ")
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
		_ = existing
		_ = baseInstructions
		return CodexNativeSessionController.SessionRef(
			conversationID: "noop",
			rolloutPath: nil,
			model: nil,
			reasoningEffort: nil
		)
	}

	func sendUserMessage(_ text: String) async throws {
		_ = text
	}

	func sendUserTurn(text: String, images: [AgentImageAttachment]) async throws {
		_ = text
		_ = images
	}

	func cancelCurrentTurn() async {}
	func shutdown() async {}
	func respondToServerRequest(id: CodexAppServerRequestID, result: [String: Any]) async {
		_ = id
		_ = result
	}
}
