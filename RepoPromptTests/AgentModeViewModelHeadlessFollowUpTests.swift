import XCTest
@testable import RepoPrompt

@MainActor
final class AgentModeViewModelHeadlessFollowUpTests: XCTestCase {
	func testStartAgentRunEnablesMCPServerBeforeHeadlessSend() async {
		let provider = FakeHeadlessAgentProvider()
		provider.enqueue(
			results: [
				AIStreamResult(type: "message_stop", text: nil, promptTokens: 12, completionTokens: 4, providerSessionID: "claude-session-1")
			]
		)

		var executionOrder: [String] = []
		provider.onStreamStart = {
			executionOrder.append("send")
		}

		let vm = AgentModeViewModel(
			testWindowID: 99,
			testWorkspacePath: FileManager.default.currentDirectoryPath,
			codexControllerFactory: { _, _, _, _, _, _ in NoopCodexController() },
			claudeControllerFactory: { runID, _, _, _, _, _, _ in
				ProviderBackedClaudeController(runID: runID, provider: provider)
			},
			headlessProviderFactory: { _, _ in provider },
			connectionPolicyInstaller: { _, _, _, _, _, _, _, runID, _, _, _, _, _ in
				if let runID {
					MCPRoutingWaiter.signalRouted(runID)
				}
			},
			mcpServerEnabler: {
				executionOrder.append("enable-mcp")
			}
		)

		let tabID = UUID()
		vm.ensureSession(for: tabID)
		guard let session = vm.sessions[tabID] else {
			return XCTFail("Expected session for tab \(tabID)")
		}
		session.selectedAgent = .claudeCode

		await vm.startAgentRun(tabID: tabID, initialMessage: "initial")
		let completed = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .completed
		}
		XCTAssertTrue(completed, "Expected headless run to complete")
		XCTAssertEqual(executionOrder.prefix(2), ["enable-mcp", "send"])
	}

	func testStartAgentRunEnablesMCPServerBeforeCodexSend() async {
		var executionOrder: [String] = []
		let codexController = RecordingCodexController {
			executionOrder.append("send")
		}
		let vm = AgentModeViewModel(
			testWindowID: 99,
			testWorkspacePath: FileManager.default.currentDirectoryPath,
			codexControllerFactory: { _, _, _, _, _, _ in codexController },
			headlessProviderFactory: { _, _ in FakeHeadlessAgentProvider() },
			mcpServerEnabler: {
				executionOrder.append("enable-mcp")
			}
		)

		let tabID = UUID()
		vm.ensureSession(for: tabID)
		guard let session = vm.sessions[tabID] else {
			return XCTFail("Expected session for tab \(tabID)")
		}
		session.selectedAgent = .codexExec

		await vm.startAgentRun(tabID: tabID, initialMessage: "start codex")
		let didSend = await waitForCondition(timeoutSeconds: 1.0) {
			codexController.sendCallCount == 1
		}
		XCTAssertTrue(didSend, "Expected Codex send to be invoked")
		XCTAssertEqual(executionOrder.prefix(2), ["enable-mcp", "send"])
	}

	func testCodexStartBackfillsNativeRunIDFromStableSessionRunID() async {
		let codexController = RecordingCodexController {}
		var policyRunIDs: [UUID?] = []
		let vm = AgentModeViewModel(
			testWindowID: 99,
			testWorkspacePath: FileManager.default.currentDirectoryPath,
			shouldManageCodexTooling: true,
			codexControllerFactory: { _, _, _, _, _, _ in codexController },
			headlessProviderFactory: { _, _ in FakeHeadlessAgentProvider() },
			connectionPolicyInstaller: { _, _, _, _, _, _, _, runID, _, _, _, _, _ in
				policyRunIDs.append(runID)
				if let runID {
					MCPRoutingWaiter.signalRouted(runID)
				}
			}
		)

		let tabID = UUID()
		vm.ensureSession(for: tabID)
		guard let session = vm.sessions[tabID] else {
			return XCTFail("Expected session for tab \(tabID)")
		}
		XCTAssertNil(session.runID)
		session.selectedAgent = .codexExec

		await vm.startAgentRun(tabID: tabID, initialMessage: "start codex")
		let didSend = await waitForCondition(timeoutSeconds: 2.0) {
			codexController.sendCallCount == 1 && session.runID != nil
		}
		XCTAssertTrue(didSend, "Expected Codex send to be invoked")
		guard let activeRunID = session.runID else {
			return XCTFail("Expected Codex launch to mint a live run ID")
		}
		XCTAssertGreaterThanOrEqual(policyRunIDs.count, 1)
		XCTAssertTrue(policyRunIDs.allSatisfy { $0 == activeRunID })
	}

	func testGeminiFollowUpAutoRunUsesResumeSessionAndInstallsPolicyEachRun() async {
		let provider = FakeHeadlessAgentProvider()
		provider.enqueue(
			results: [
				AIStreamResult(type: "content", text: "first"),
				AIStreamResult(type: "message_stop", text: nil, promptTokens: 120, completionTokens: 30, providerSessionID: "gem-session-1")
			],
			perEventDelayNanos: 120_000_000
		)
		provider.enqueue(
			results: [
				AIStreamResult(type: "content", text: "second"),
				AIStreamResult(type: "message_stop", text: nil, promptTokens: 80, completionTokens: 20, providerSessionID: "gem-session-2")
			]
		)

		var policyCalls: [PolicyInstallCall] = []
		let vm = makeViewModel(
			provider: provider,
			onInstallPolicy: { call in
				policyCalls.append(call)
			}
		)

		let tabID = UUID()
		vm.ensureSession(for: tabID)
		guard let session = vm.sessions[tabID] else {
			return XCTFail("Expected tab session to exist")
		}
		session.selectedAgent = .gemini

		await vm.startAgentRun(tabID: tabID, initialMessage: "initial instruction")
		session.pendingInstructions.append("follow-up instruction")

		let completed = await waitForCondition(timeoutSeconds: 3.0) {
			session.runState == .completed && provider.messages.count == 2
		}
		XCTAssertTrue(completed, "Expected Gemini follow-up run to complete")
		XCTAssertEqual(session.providerSessionID, "gem-session-2")

		XCTAssertEqual(provider.messages.count, 2)
		guard provider.messages.count >= 2 else { return }
		XCTAssertNil(provider.messages[0].resumeSessionID)
		XCTAssertEqual(provider.messages[1].resumeSessionID, "gem-session-1")
		XCTAssertEqual(provider.messages[1].userMessage, "follow-up instruction")
		XCTAssertEqual(session.providerTokenUsageByTurn.count, 2)
		guard session.providerTokenUsageByTurn.count >= 2 else { return }
		XCTAssertEqual(session.providerTokenUsageByTurn[0].totalTokens, 150)
		XCTAssertEqual(session.providerTokenUsageByTurn[1].totalTokens, 100)
		XCTAssertEqual(session.codexContextUsage?.lastTotalTokens, 100)
		XCTAssertEqual(session.codexContextUsage?.totalTotalTokens, 250)
		XCTAssertNil(session.codexContextUsage?.modelContextWindow)

		XCTAssertEqual(policyCalls.count, 2)
		guard policyCalls.count >= 2 else { return }
		assertPolicyCall(policyCalls[0], expectedClient: "gemini-cli-mcp-client", expectedTabID: tabID)
		assertPolicyCall(policyCalls[1], expectedClient: "gemini-cli-mcp-client", expectedTabID: tabID)
	}

	func testClaudeFollowUpAutoRunUsesResumeSessionAndInstallsPolicyEachRun() async {
		let provider = FakeHeadlessAgentProvider()
		provider.enqueue(
			results: [
				AIStreamResult(type: "content", text: "first"),
				AIStreamResult(type: "message_stop", text: nil, promptTokens: 90, completionTokens: 10, providerSessionID: "claude-session-1")
			],
			perEventDelayNanos: 120_000_000
		)
		provider.enqueue(
			results: [
				AIStreamResult(type: "content", text: "second"),
				AIStreamResult(type: "message_stop", text: nil, promptTokens: 70, completionTokens: 30, providerSessionID: "claude-session-2")
			]
		)

		var policyCalls: [PolicyInstallCall] = []
		let vm = makeViewModel(
			provider: provider,
			onInstallPolicy: { call in
				policyCalls.append(call)
			}
		)

		let tabID = UUID()
		vm.ensureSession(for: tabID)
		guard let session = vm.sessions[tabID] else {
			return XCTFail("Expected tab session to exist")
		}
		session.selectedAgent = .claudeCode

		await vm.startAgentRun(tabID: tabID, initialMessage: "initial instruction")
		session.pendingInstructions.append("follow-up instruction")

		let completed = await waitForCondition(timeoutSeconds: 3.0) {
			session.runState == .completed && provider.messages.count == 2
		}
		XCTAssertTrue(completed, "Expected Claude follow-up run to complete")
		XCTAssertEqual(session.providerSessionID, "claude-session-2")

		XCTAssertEqual(provider.messages.count, 2)
		guard provider.messages.count >= 2 else { return }
		XCTAssertNil(provider.messages[0].resumeSessionID)
		XCTAssertEqual(provider.messages[1].resumeSessionID, "claude-session-1")
		XCTAssertEqual(provider.messages[1].userMessage, "follow-up instruction")
		XCTAssertEqual(session.providerTokenUsageByTurn.count, 2)
		guard session.providerTokenUsageByTurn.count >= 2 else { return }
		XCTAssertEqual(session.providerTokenUsageByTurn[0].totalTokens, 100)
		XCTAssertGreaterThan(session.providerTokenUsageByTurn[1].totalTokens, 0)
		XCTAssertEqual(session.codexContextUsage?.lastTotalTokens, session.providerTokenUsageByTurn[1].totalTokens)
		XCTAssertEqual(session.codexContextUsage?.totalTotalTokens, session.providerTokenUsageByTurn[1].totalTokens)
		XCTAssertNil(session.codexContextUsage?.modelContextWindow)

		XCTAssertEqual(policyCalls.count, 2)
		guard policyCalls.count >= 2 else { return }
		assertPolicyCall(policyCalls[0], expectedClient: "claude-code", expectedTabID: tabID)
		assertPolicyCall(policyCalls[1], expectedClient: "claude-code", expectedTabID: tabID)
	}

	func testClaudeMessageStopDoesNotSurfaceStopReasonSystemItem() async {
		let provider = FakeHeadlessAgentProvider()
		provider.enqueue(
			results: [
				AIStreamResult(type: "content", text: "working"),
				AIStreamResult(
					type: "message_stop",
					text: nil,
					promptTokens: 12,
					completionTokens: 4,
					providerSessionID: "claude-session-stop-reason",
					stopReason: "tool_use"
				)
			]
		)

		let vm = makeViewModel(provider: provider)
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		guard let session = vm.sessions[tabID] else {
			return XCTFail("Expected tab session to exist")
		}
		session.selectedAgent = .claudeCode

		await vm.startAgentRun(tabID: tabID, initialMessage: "initial instruction")
		let completed = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .completed
		}
		XCTAssertTrue(completed, "Expected Claude run to complete")
		XCTAssertEqual(session.providerSessionID, "claude-session-stop-reason")
		XCTAssertFalse(session.items.contains(where: {
			$0.kind == .system && $0.text == "Stop reason: tool_use"
		}))
		XCTAssertTrue(session.items.contains(where: {
			$0.kind == .assistant && $0.text == "working"
		}))
	}

	func testClaudeContextUsageTracksLatestContextInputSignalAcrossFollowUps() async {
		let provider = FakeHeadlessAgentProvider()
		provider.enqueue(
			results: [
				AIStreamResult(type: "content", text: "first"),
				AIStreamResult(
					type: "message_stop",
					text: nil,
					promptTokens: 90,
					completionTokens: 10,
					providerSessionID: "claude-session-1",
					contextUsedTokens: 800
				)
			],
			perEventDelayNanos: 120_000_000
		)
		provider.enqueue(
			results: [
				AIStreamResult(type: "content", text: "second"),
				AIStreamResult(
					type: "message_stop",
					text: nil,
					promptTokens: 70,
					completionTokens: 20,
					providerSessionID: "claude-session-2",
					contextUsedTokens: 940
				)
			]
		)

		let vm = makeViewModel(provider: provider)
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		guard let session = vm.sessions[tabID] else {
			return XCTFail("Expected tab session to exist")
		}
		session.selectedAgent = .claudeCode

		await vm.startAgentRun(tabID: tabID, initialMessage: "initial instruction")
		session.pendingInstructions.append("follow-up instruction")

		let completed = await waitForCondition(timeoutSeconds: 3.0) {
			session.runState == .completed && provider.messages.count == 2
		}
		XCTAssertTrue(completed, "Expected Claude follow-up run to complete")
		XCTAssertEqual(session.providerTokenUsageByTurn.count, 2)
		guard session.providerTokenUsageByTurn.count >= 2 else { return }
		XCTAssertEqual(session.providerTokenUsageByTurn[0].contextUsedTokens, 800)
		XCTAssertEqual(session.providerTokenUsageByTurn[1].contextUsedTokens, 940)
		XCTAssertEqual(session.codexContextUsage?.lastTotalTokens, 940)
		XCTAssertEqual(session.codexContextUsage?.totalTotalTokens, 940)
	}

	func testBoundColdHeadlessSessionMintsFreshRunIDForPolicyInstall() async {
		let provider = FakeHeadlessAgentProvider()
		provider.enqueue(
			results: [
				AIStreamResult(type: "message_stop", text: nil, promptTokens: 20, completionTokens: 5, providerSessionID: "claude-session-indexed")
			]
		)

		var policyCalls: [PolicyInstallCall] = []
		let vm = makeViewModel(
			provider: provider,
			onInstallPolicy: { call in
				policyCalls.append(call)
			}
		)

		let tabID = UUID()
		vm.ensureSession(for: tabID)
		guard let session = vm.sessions[tabID] else {
			return XCTFail("Expected tab session to exist")
		}
		session.selectedAgent = .claudeCode
		let persistedSessionID = UUID()
		let persistedRunID = UUID()
		session.activeAgentSessionID = persistedSessionID
		session.hasLoadedPersistedState = false
		session.runID = nil
		vm.test_seedSessionIndexEntry(sessionID: persistedSessionID, tabID: tabID)

		await vm.startAgentRun(tabID: tabID, initialMessage: "run with indexed run id")
		let completed = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .completed && !policyCalls.isEmpty
		}
		XCTAssertTrue(completed, "Expected headless run to complete")
		guard let activeRunID = session.runID else {
			return XCTFail("Expected Claude runtime to keep a live run ID")
		}
		XCTAssertNotEqual(activeRunID, persistedRunID)
		XCTAssertEqual(policyCalls.first?.runID, activeRunID)
	}

	func testSubmitUserTurnDefersUntilBoundColdSessionHydrates() async {
		let provider = FakeHeadlessAgentProvider()
		provider.enqueue(
			results: [
				AIStreamResult(type: "message_stop", text: nil, promptTokens: 12, completionTokens: 4, providerSessionID: "claude-session-deferred")
			]
		)

		var policyCalls: [PolicyInstallCall] = []
		let vm = makeViewModel(
			provider: provider,
			onInstallPolicy: { call in
				policyCalls.append(call)
			}
		)

		let tabID = UUID()
		vm.ensureSession(for: tabID)
		guard let session = vm.sessions[tabID] else {
			return XCTFail("Expected tab session to exist")
		}
		session.selectedAgent = .claudeCode
		let persistedSessionID = UUID()
		let persistedRunID = UUID()
		session.activeAgentSessionID = persistedSessionID
		session.hasLoadedPersistedState = false
		session.runID = nil
		vm.test_seedSessionIndexEntry(sessionID: persistedSessionID, tabID: tabID)

		let result = vm.test_submitUserTurn(tabID: tabID, text: "hydrate-first turn")
		XCTAssertEqual(result, .submitted)
		XCTAssertTrue(session.items.isEmpty, "User bubble should not append before hydration completes")

		let completed = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .completed
				&& session.items.contains(where: { $0.kind == .user })
				&& !policyCalls.isEmpty
		}
		XCTAssertTrue(completed, "Expected deferred send to complete after hydration")
		guard let activeRunID = session.runID else {
			return XCTFail("Expected Claude runtime to keep a live run ID after hydration")
		}
		XCTAssertNotEqual(activeRunID, persistedRunID)
		XCTAssertEqual(policyCalls.first?.runID, activeRunID)
		XCTAssertEqual(session.items.first?.kind, .user)
		XCTAssertEqual(session.items.first?.text, "hydrate-first turn")
	}

	func testHeadlessSessionMintsFreshRunIDAcrossConsecutiveRuns() async {
		let provider = FakeHeadlessAgentProvider()
		provider.enqueue(
			results: [
				AIStreamResult(type: "message_stop", text: nil, promptTokens: 30, completionTokens: 10, providerSessionID: "claude-session-1")
			]
		)
		provider.enqueue(
			results: [
				AIStreamResult(type: "message_stop", text: nil, promptTokens: 20, completionTokens: 5, providerSessionID: "claude-session-2")
			]
		)

		var policyCalls: [PolicyInstallCall] = []
		let vm = makeViewModel(
			provider: provider,
			onInstallPolicy: { call in
				policyCalls.append(call)
			}
		)

		let tabID = UUID()
		vm.ensureSession(for: tabID)
		guard let session = vm.sessions[tabID] else {
			return XCTFail("Expected tab session to exist")
		}
		session.selectedAgent = .claudeCode

		await vm.startAgentRun(tabID: tabID, initialMessage: "run one")
		let firstCompleted = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .completed && policyCalls.count == 1
		}
		XCTAssertTrue(firstCompleted)

		await vm.startAgentRun(tabID: tabID, initialMessage: "run two")
		let secondCompleted = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .completed && policyCalls.count == 2
		}
		XCTAssertTrue(secondCompleted)

		guard let activeRunID = session.runID else {
			return XCTFail("Expected Claude runtime to keep a live run ID across turns")
		}
		XCTAssertGreaterThanOrEqual(policyCalls.count, 2)
		guard let firstRunID = policyCalls[safe: 0]?.runID,
			let secondRunID = policyCalls[safe: 1]?.runID
		else { return XCTFail("Expected policy installs to capture run IDs") }
		XCTAssertEqual(firstRunID, activeRunID)
		XCTAssertEqual(secondRunID, activeRunID)
	}

	func testHeadlessCancelClearsRunIDAndNextRunMintsFreshRunID() async {
		let provider = FakeHeadlessAgentProvider()
		provider.enqueue(
			results: [
				AIStreamResult(type: "content", text: "working")
			],
			perEventDelayNanos: 400_000_000
		)
		provider.enqueue(
			results: [
				AIStreamResult(type: "message_stop", text: nil, promptTokens: 15, completionTokens: 5, providerSessionID: "claude-session-next")
			]
		)

		var policyCalls: [PolicyInstallCall] = []
		let vm = makeViewModel(
			provider: provider,
			onInstallPolicy: { call in
				policyCalls.append(call)
			}
		)

		let tabID = UUID()
		vm.ensureSession(for: tabID)
		guard let session = vm.sessions[tabID] else {
			return XCTFail("Expected tab session to exist")
		}
		session.selectedAgent = .claudeCode

		await vm.startAgentRun(tabID: tabID, initialMessage: "run then cancel")
		let firstPolicyInstalled = await waitForCondition(timeoutSeconds: 2.0) {
			policyCalls.count == 1
		}
		XCTAssertTrue(firstPolicyInstalled)

		await vm.cancelAgentRun(tabID: tabID)
		XCTAssertEqual(session.runState, .cancelled)
		guard let stableRunID = session.runID else {
			return XCTFail("Expected Claude runtime to keep its live run ID after cancel")
		}

		await vm.startAgentRun(tabID: tabID, initialMessage: "after cancel")
		let secondRunInstalledPolicy = await waitForCondition(timeoutSeconds: 2.0) {
			policyCalls.count >= 2
		}
		XCTAssertTrue(secondRunInstalledPolicy)
		XCTAssertEqual(session.runID, stableRunID)
		XCTAssertGreaterThanOrEqual(policyCalls.count, 2)
		guard let firstRunID = policyCalls[safe: 0]?.runID,
			let secondRunID = policyCalls[safe: 1]?.runID
		else { return XCTFail("Expected policy installs to capture run IDs") }
		XCTAssertEqual(firstRunID, stableRunID)
		XCTAssertEqual(secondRunID, stableRunID)
	}

	func testTabCloseCleansMCPRunRoutingState() async {
		let provider = FakeHeadlessAgentProvider()
		var cleanupCalls: [RoutingCleanupCall] = []
		var cancelCalls: [ToolCancelCall] = []
		let vm = makeViewModel(
			provider: provider,
			onInstallPolicy: { _ in },
			onCleanupRouting: { cleanupCalls.append($0) },
			onCancelTools: { cancelCalls.append($0) }
		)
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		guard let session = vm.sessions[tabID] else {
			return XCTFail("Expected session")
		}
		let runID = UUID()
		session.runID = runID

		await vm.test_handleComposeTabsWillClose([tabID])
		XCTAssertTrue(cancelCalls.isEmpty)
		XCTAssertTrue(cleanupCalls.isEmpty)
	}

	func testDeleteSessionCleansMCPRunRoutingState() async {
		let provider = FakeHeadlessAgentProvider()
		var cleanupCalls: [RoutingCleanupCall] = []
		var cancelCalls: [ToolCancelCall] = []
		let vm = makeViewModel(
			provider: provider,
			onInstallPolicy: { _ in },
			onCleanupRouting: { cleanupCalls.append($0) },
			onCancelTools: { cancelCalls.append($0) }
		)
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		guard let session = vm.sessions[tabID] else {
			return XCTFail("Expected session")
		}
		let runID = UUID()
		session.runID = runID

		await vm.deleteSession(tabID: tabID)
		XCTAssertTrue(cancelCalls.isEmpty)
		XCTAssertTrue(cleanupCalls.isEmpty)
	}

	func testTabCloseCleansRoutingFromSessionIndexWhenSessionNotHydrated() async {
		let provider = FakeHeadlessAgentProvider()
		var cleanupCalls: [RoutingCleanupCall] = []
		var cancelCalls: [ToolCancelCall] = []
		let vm = makeViewModel(
			provider: provider,
			onInstallPolicy: { _ in },
			onCleanupRouting: { cleanupCalls.append($0) },
			onCancelTools: { cancelCalls.append($0) }
		)
		let tabID = UUID()
		let sessionID = UUID()
		vm.test_seedSessionIndexEntry(sessionID: sessionID, tabID: tabID)

		await vm.test_handleComposeTabsWillClose([tabID])
		XCTAssertTrue(cancelCalls.isEmpty)
		XCTAssertTrue(cleanupCalls.isEmpty)
	}

	func testPrepareForWindowCloseCleansMCPRunRoutingForAllSessions() async {
		let provider = FakeHeadlessAgentProvider()
		var cleanupCalls: [RoutingCleanupCall] = []
		var cancelCalls: [ToolCancelCall] = []
		let vm = makeViewModel(
			provider: provider,
			onInstallPolicy: { _ in },
			onCleanupRouting: { cleanupCalls.append($0) },
			onCancelTools: { cancelCalls.append($0) }
		)
		let tabA = UUID()
		let tabB = UUID()
		vm.ensureSession(for: tabA)
		vm.ensureSession(for: tabB)
		guard let sessionA = vm.sessions[tabA],
			let sessionB = vm.sessions[tabB]
		else {
			return XCTFail("Expected sessions")
		}
		let runA = UUID()
		let runB = UUID()
		sessionA.runID = runA
		sessionB.runID = runB

		await vm.prepareForWindowClose()
		XCTAssertTrue(cancelCalls.isEmpty)
		XCTAssertTrue(cleanupCalls.isEmpty)
	}

	func testWorkspaceSwitchCleansMCPRunRoutingForAllSessions() async {
		let provider = FakeHeadlessAgentProvider()
		var cleanupCalls: [RoutingCleanupCall] = []
		var cancelCalls: [ToolCancelCall] = []
		let vm = makeViewModel(
			provider: provider,
			onInstallPolicy: { _ in },
			onCleanupRouting: { cleanupCalls.append($0) },
			onCancelTools: { cancelCalls.append($0) }
		)
		let tabA = UUID()
		let tabB = UUID()
		vm.ensureSession(for: tabA)
		vm.ensureSession(for: tabB)
		guard let sessionA = vm.sessions[tabA],
			let sessionB = vm.sessions[tabB]
		else {
			return XCTFail("Expected sessions")
		}
		let runA = UUID()
		let runB = UUID()
		sessionA.runID = runA
		sessionB.runID = runB

		await vm.test_handleWorkspaceSwitch(nil)
		sessionA.runID = nil
		sessionB.runID = nil
		await vm.test_waitForWorkspaceSwitchBackgroundCleanup()
		XCTAssertEqual(Set(cancelCalls.map(\.runID)), [runA, runB])
		XCTAssertEqual(Set(cancelCalls.map(\.reason)), ["workspace_switch"])
		XCTAssertEqual(Set(cleanupCalls.map(\.runID)), [runA, runB])
		XCTAssertEqual(Set(cleanupCalls.map(\.reason)), ["workspace_switch"])
	}

	func testDetachedCodexShutdownDoesNotStopNewSameTabTrackingForNilOrMismatchedOldRunID() async {
		let vm = makeViewModel(
			provider: FakeHeadlessAgentProvider(),
			onInstallPolicy: { _ in },
			shouldManageCodexTooling: true
		)
		let tabID = UUID()
		let newSession = AgentModeViewModel.TabSession(tabID: tabID)
		let newRunID = UUID()
		await ServerNetworkManager.shared.unregisterToolObservers(for: newRunID)
		defer { Task { await ServerNetworkManager.shared.unregisterToolObservers(for: newRunID) } }

		await vm.codexCoordinator.ensureCodexToolTrackingIfNeeded(for: newSession, runID: newRunID)
		let observerRegistered = await waitForAsyncCondition(timeoutSeconds: 1.0) {
			await ServerNetworkManager.shared.toolEventObserverCount(for: newRunID) == 1
		}
		XCTAssertTrue(observerRegistered, "Expected new run tool tracking to be registered")

		let nilRunOldSession = AgentModeViewModel.TabSession(tabID: tabID)
		await vm.codexCoordinator.shutdownCodexSession(
			nilRunOldSession,
			clearTabScopedCoordinatorState: false,
			detachedRunID: nil
		)
		let observerCountAfterNilRunCleanup = await ServerNetworkManager.shared.toolEventObserverCount(for: newRunID)
		XCTAssertEqual(observerCountAfterNilRunCleanup, 1)

		let mismatchedOldRunID = UUID()
		let mismatchedOldSession = AgentModeViewModel.TabSession(tabID: tabID)
		mismatchedOldSession.runID = mismatchedOldRunID
		await vm.codexCoordinator.shutdownCodexSession(
			mismatchedOldSession,
			clearTabScopedCoordinatorState: false,
			detachedRunID: mismatchedOldRunID
		)
		let observerCountAfterMismatchedRunCleanup = await ServerNetworkManager.shared.toolEventObserverCount(for: newRunID)
		XCTAssertEqual(observerCountAfterMismatchedRunCleanup, 1)

		newSession.runID = newRunID
		await vm.codexCoordinator.shutdownCodexSession(newSession)
		let observerRemoved = await waitForAsyncCondition(timeoutSeconds: 1.0) {
			await ServerNetworkManager.shared.toolEventObserverCount(for: newRunID) == 0
		}
		XCTAssertTrue(observerRemoved, "Expected live-session shutdown to remove new run tracking")
	}

	func testWorkspaceSwitchReturnsBeforeProviderDisposeCompletes() async {
		let provider = BlockingDisposeHeadlessAgentProvider()
		let vm = makeViewModel(
			provider: provider,
			onInstallPolicy: { _ in }
		)
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		guard let session = vm.sessions[tabID] else {
			return XCTFail("Expected session")
		}
		session.provider = provider

		var didCompleteSwitch = false
		let switchTask = Task { @MainActor in
			await vm.test_handleWorkspaceSwitch(nil)
			didCompleteSwitch = true
		}

		let completedBeforeDisposeRelease = await waitForCondition(timeoutSeconds: 0.5) {
			didCompleteSwitch
		}
		if !completedBeforeDisposeRelease {
			provider.releaseDispose()
		}
		await switchTask.value
		XCTAssertTrue(completedBeforeDisposeRelease, "Workspace switch should not wait for old provider disposal")
		XCTAssertTrue(vm.sessions.isEmpty)

		let disposeStarted = await waitForCondition(timeoutSeconds: 1.0) {
			provider.disposeStarted
		}
		XCTAssertTrue(disposeStarted, "Expected old provider disposal to run in background")
		XCTAssertFalse(provider.disposeFinished)

		provider.releaseDispose()
		await vm.test_waitForWorkspaceSwitchBackgroundCleanup()
		XCTAssertTrue(provider.disposeFinished)
	}

	func testCancelRunDoesNotCleanupMCPRunRoutingState() async {
		let provider = FakeHeadlessAgentProvider()
		var cleanupCalls: [RoutingCleanupCall] = []
		let vm = makeViewModel(
			provider: provider,
			onInstallPolicy: { _ in },
			onCleanupRouting: { cleanupCalls.append($0) }
		)
		let tabID = UUID()
		vm.ensureSession(for: tabID)

		await vm.cancelAgentRun(tabID: tabID)
		XCTAssertTrue(cleanupCalls.isEmpty)
	}

	func testClaudeWaitingWithImageAttachmentCancelsWaitAndRestartsWithResume() async {
		let provider = FakeHeadlessAgentProvider()
		provider.enqueue(
			results: [
				AIStreamResult(type: "content", text: "ack"),
				AIStreamResult(type: "message_stop", text: nil, promptTokens: 60, completionTokens: 40, providerSessionID: "claude-session-next")
			]
		)

		let vm = makeViewModel(provider: provider, onInstallPolicy: { _ in })
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		guard let session = vm.sessions[tabID] else {
			return XCTFail("Expected tab session to exist")
		}
		session.selectedAgent = .claudeCode
		session.providerSessionID = "claude-session-existing"

		let waitingTask = Task {
			try await vm.waitForNextUserInstruction(tabID: tabID, prompt: "Next step?")
		}
		let isWaiting = await waitForCondition(timeoutSeconds: 1.0) {
			session.runState == .waitingForUser && session.instructionContinuation != nil
		}
		XCTAssertTrue(isWaiting, "Expected session to enter waiting-for-user state")

		let imagePath = "/tmp/My Folder/screenshot (1).png"
		let attachment = AgentImageAttachment(source: .localFile(path: imagePath), title: "screenshot (1).png")
		session.pendingImageAttachments = [attachment]

		vm.test_submitUserTurn(tabID: tabID, text: "Please inspect this screenshot.")

		let restarted = await waitForCondition(timeoutSeconds: 2.0) {
			provider.messages.count == 1 && session.runState == .completed
		}
		XCTAssertTrue(restarted, "Expected Claude run to restart and complete")
		XCTAssertEqual(provider.messages.count, 1)
		guard provider.messages.count >= 1 else { return }
		XCTAssertEqual(provider.messages[0].resumeSessionID, "claude-session-existing")
		let expectedRef = "@\(vm.test_escapePathForAtCommand(imagePath))"
		XCTAssertEqual(provider.messages[0].userMessage, "\(expectedRef)\n\nPlease inspect this screenshot.")
		XCTAssertTrue(session.pendingImageAttachments.isEmpty)

		do {
			_ = try await waitingTask.value
			XCTFail("Expected waiting continuation to be cancelled")
		} catch is CancellationError {
			// Expected
		} catch {
			XCTFail("Expected CancellationError, got: \(error)")
		}
	}

	func testInstructionTimeoutClearsActiveHeadlessRunAttempt() async throws {
		let provider = FakeHeadlessAgentProvider()
		let vm = makeViewModel(provider: provider, onInstallPolicy: { _ in })
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		guard let session = vm.sessions[tabID] else {
			return XCTFail("Expected tab session to exist")
		}

		session.selectedAgent = .claudeCode
		session.activeHeadlessRunAttemptID = UUID()
		session.agentTask = Task {
			try? await Task.sleep(nanoseconds: 5_000_000_000)
		}

		let response = try await vm.waitForNextUserInstruction(
			tabID: tabID,
			prompt: "Next step?",
			timeoutSeconds: 0.05
		)

		XCTAssertTrue(response.timedOut)
		XCTAssertEqual(session.runState, .cancelled)
		XCTAssertNil(session.activeHeadlessRunAttemptID)
		XCTAssertNil(session.agentTask)
	}

	func testClaudeInitialRunWithImageAttachmentKeepsTopLevelImageReferenceFormat() async {
		let provider = FakeHeadlessAgentProvider()
		provider.enqueue(
			results: [
				AIStreamResult(type: "message_stop", text: nil, promptTokens: 40, completionTokens: 20, providerSessionID: "claude-session-new")
			]
		)

		let vm = makeViewModel(provider: provider, onInstallPolicy: { _ in })
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		guard let session = vm.sessions[tabID] else {
			return XCTFail("Expected tab session to exist")
		}
		session.selectedAgent = .claudeCode

		let imagePath = "/tmp/My Folder/screenshot (1).png"
		let attachment = AgentImageAttachment(source: .localFile(path: imagePath), title: "screenshot (1).png")
		session.pendingImageAttachments = [attachment]

		_ = vm.test_submitUserTurn(tabID: tabID, text: "Please inspect this screenshot.")

		let completed = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .completed && provider.messages.count == 1
		}
		XCTAssertTrue(completed, "Expected Claude image run to complete")
		XCTAssertEqual(provider.messages.count, 1)
		guard provider.messages.count >= 1 else { return }

		let expectedRef = "@\(vm.test_escapePathForAtCommand(imagePath))"
		let expectedMessage = "\(expectedRef)\n\nPlease inspect this screenshot."
		let sentMessage = provider.messages[0].userMessage
		XCTAssertTrue(sentMessage.hasPrefix(expectedMessage))
		XCTAssertFalse(sentMessage.contains("<previous_conversation>"))
		XCTAssertFalse(sentMessage.contains("<current_instruction>"))
	}

	func testClaudeAttachmentTurnBypassesHistoryReplayWhenAttachmentCleanupIsDisabled() async {
		let provider = FakeHeadlessAgentProvider()
		provider.enqueue(
			results: [
				AIStreamResult(type: "message_stop", text: nil, promptTokens: 20, completionTokens: 10, providerSessionID: "claude-session-new")
			]
		)

		let vm = makeViewModel(
			provider: provider,
			onInstallPolicy: { _ in },
			clearConsumedAttachmentsAfterProviderConsumption: false
		)
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		guard let session = vm.sessions[tabID] else {
			return XCTFail("Expected tab session to exist")
		}
		session.selectedAgent = .claudeCode
		session.appendItem(AgentChatItem.assistant("previous assistant response", sequenceIndex: session.nextSequenceIndex))

		let imagePath = "/tmp/Attachment Replay/history.png"
		let attachment = AgentImageAttachment(source: .localFile(path: imagePath), title: "history.png")
		session.pendingImageAttachments = [attachment]

		_ = vm.test_submitUserTurn(tabID: tabID, text: "Analyze image")

		let completed = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .completed && provider.messages.count == 1
		}
		XCTAssertTrue(completed)
		guard provider.messages.count >= 1 else { return }
		let sent = provider.messages[0].userMessage
		XCTAssertFalse(sent.contains("<previous_conversation>"))
		XCTAssertFalse(sent.contains("<current_instruction>"))
		XCTAssertTrue(sent.hasPrefix("@\(vm.test_escapePathForAtCommand(imagePath))"))
	}

	func testCancelImageRunDoesNotPoisonNextNonAttachmentRunHistoryReplay() async {
		let provider = FakeHeadlessAgentProvider()
		provider.enqueue(
			results: [
				AIStreamResult(type: "content", text: "working")
			],
			perEventDelayNanos: 800_000_000
		)
		provider.enqueue(
			results: [
				AIStreamResult(type: "message_stop", text: nil, promptTokens: 25, completionTokens: 5, providerSessionID: "claude-session-next")
			]
		)

		let vm = makeViewModel(provider: provider, onInstallPolicy: { _ in })
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		guard let session = vm.sessions[tabID] else {
			return XCTFail("Expected tab session to exist")
		}
		session.selectedAgent = .claudeCode
		session.appendItem(AgentChatItem.assistant("previous assistant response", sequenceIndex: session.nextSequenceIndex))

		let imagePath = "/tmp/Attachment Replay/first.png"
		let attachment = AgentImageAttachment(source: .localFile(path: imagePath), title: "first.png")
		session.pendingImageAttachments = [attachment]
		_ = vm.test_submitUserTurn(tabID: tabID, text: "First turn with image")

		let started = await waitForCondition(timeoutSeconds: 1.0) {
			session.runState == .running && provider.messages.count == 1
		}
		XCTAssertTrue(started)

		await vm.cancelAgentRun(tabID: tabID)
		XCTAssertEqual(session.runState, .cancelled)
		XCTAssertTrue(session.attachmentsPendingProviderConsumptionCleanup.isEmpty)

		_ = vm.test_submitUserTurn(tabID: tabID, text: "Second turn no image")
		let sentSecondTurn = await waitForCondition(timeoutSeconds: 4.0) {
			provider.messages.count >= 2
		}
		XCTAssertTrue(sentSecondTurn)
		guard provider.messages.count >= 2 else { return }

		let secondMessage = provider.messages[1].userMessage
		XCTAssertEqual(secondMessage, "Second turn no image")
		XCTAssertFalse(secondMessage.contains("<previous_conversation>"))
		XCTAssertFalse(secondMessage.contains("<current_instruction>"))
	}

	func testCancelDuringStartupDoesNotBlockNextHeadlessRun() async {
		let provider = FakeHeadlessAgentProvider()
		provider.enqueue(
			results: [
				AIStreamResult(type: "message_stop", text: nil, promptTokens: 10, completionTokens: 5, providerSessionID: "claude-session-started")
			]
		)
		var streamStartCount = 0
		provider.onStreamStart = {
			streamStartCount += 1
		}

		let vm = makeViewModel(provider: provider, onInstallPolicy: { _ in })
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		guard let session = vm.sessions[tabID] else {
			return XCTFail("Expected tab session to exist")
		}
		session.selectedAgent = .claudeCode

		let heldGateID = UUID()
		await HeadlessAgentConnectionGate.beginConnection(heldGateID)

		await vm.startAgentRun(tabID: tabID, initialMessage: "blocked startup")
		let enteredRunning = await waitForCondition(timeoutSeconds: 1.0) {
			session.runState == .running
		}
		XCTAssertTrue(enteredRunning)

		await vm.cancelAgentRun(tabID: tabID)
		_ = await HeadlessAgentConnectionGate.completeIfActive(heldGateID)

		await vm.startAgentRun(tabID: tabID, initialMessage: "next run")
		let completed = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .completed && streamStartCount == 1
		}
		XCTAssertTrue(completed)
		XCTAssertEqual(provider.messages.count, 1, "Cancelled startup should not open a provider stream")
		await HeadlessAgentConnectionGate.cancelAll()
	}

	func testGeminiRenderProviderMessageIncludesEscapedAtPathImageReferences() {
		let provider = FakeHeadlessAgentProvider()
		let vm = makeViewModel(provider: provider, onInstallPolicy: { _ in })
		let path = "/tmp/My Folder/image (1).png"
		let attachment = AgentImageAttachment(source: .localFile(path: path), title: "image (1).png")

		let rendered = vm.test_renderProviderMessage(
			text: "Describe this image.",
			attachments: [attachment],
			agent: .gemini
		)

		let expectedRef = "@\(vm.test_escapePathForAtCommand(path))"
		XCTAssertEqual(rendered, "\(expectedRef)\n\nDescribe this image.")
	}

	func testComposeInitialThreadMessageKeepsAttachmentHeaderBeforeContext() {
		let provider = FakeHeadlessAgentProvider()
		let vm = makeViewModel(provider: provider, onInstallPolicy: { _ in })
		let path = "/tmp/My Folder/image (1).png"
		let expectedRef = "@\(vm.test_escapePathForAtCommand(path))"
		let initialMessage = "\(expectedRef)\n\nDescribe this image."

		let composed = vm.test_composeInitialThreadMessage(
			initialMessage: initialMessage,
			fileTree: "TREE",
			promptText: "PROMPT"
		)

		XCTAssertTrue(composed.hasPrefix(initialMessage), "Original attachment-prefixed message should stay intact at top")
		guard
			let fileMapRange = composed.range(of: "<file_map>\nTREE\n</file_map>"),
			let promptRange = composed.range(of: "<current_prompt_content>\nPROMPT\n</current_prompt_content>"),
			let instructionRange = composed.range(of: "Describe this image.")
		else {
			return XCTFail("Expected composed message to include file map, prompt content, and instruction")
		}
		XCTAssertLessThan(instructionRange.lowerBound, fileMapRange.lowerBound)
		XCTAssertLessThan(fileMapRange.lowerBound, promptRange.lowerBound)
	}

	func testComposeInitialThreadMessageAppendsContextForPlainInstruction() {
		let provider = FakeHeadlessAgentProvider()
		let vm = makeViewModel(provider: provider, onInstallPolicy: { _ in })

		let composed = vm.test_composeInitialThreadMessage(
			initialMessage: "Do the task.",
			fileTree: "TREE",
			promptText: "PROMPT"
		)

		XCTAssertTrue(composed.hasPrefix("Do the task."))
		XCTAssertTrue(composed.contains("<file_map>\nTREE\n</file_map>"))
		XCTAssertTrue(composed.contains("<current_prompt_content>\nPROMPT\n</current_prompt_content>"))
	}

	func testComposeClaudeResumeRecoveryHandoffPayloadIncludesInitialThreadContext() {
		let provider = FakeHeadlessAgentProvider()
		let vm = makeViewModel(provider: provider, onInstallPolicy: { _ in })

		let payload = vm.test_composeClaudeResumeRecoveryHandoffPayload(
			sourceTabName: "Session",
			sourceAgentName: "Claude Code",
			transcriptXML: "<transcript>\n<user>Hello</user>\n</transcript>",
			fileTree: "TREE",
			promptText: "PROMPT",
			deliveryID: "delivery-123"
		)

		XCTAssertTrue(payload.contains("<forked_session source=\"Session\" delivery_id=\"delivery-123\">"))
		XCTAssertTrue(payload.contains("duplicate resend and do not re-apply it."))
		XCTAssertTrue(payload.contains("<original_thread_context>"))
		XCTAssertTrue(payload.contains("<file_map>\nTREE\n</file_map>"))
		XCTAssertTrue(payload.contains("<current_prompt_content>\nPROMPT\n</current_prompt_content>"))
		XCTAssertTrue(payload.contains("<transcript>\n<user>Hello</user>\n</transcript>"))
	}

	func testComposeSessionHandoffPayloadIncludesTranscriptAndFileContents() {
		let provider = FakeHeadlessAgentProvider()
		let vm = makeViewModel(provider: provider, onInstallPolicy: { _ in })

		let payload = vm.test_composeSessionHandoffPayload(
			sourceTabName: "Session",
			sourceAgentName: "Claude Code",
			sourceModelName: "GPT-5",
			fileContentsBlock: "<file_contents>\nFILE BLOCK\n</file_contents>",
			transcriptXML: "<transcript>\n<user>Hello</user>\n</transcript>",
			deliveryID: "delivery-456"
		)

		XCTAssertTrue(payload.contains("<forked_session source=\"Session\" delivery_id=\"delivery-456\">"))
		XCTAssertTrue(payload.contains("duplicate resend and do not re-apply it."))
		XCTAssertTrue(payload.contains("You are continuing a session started with Claude Code (GPT-5)."))
		XCTAssertTrue(payload.contains("<file_contents>\nFILE BLOCK\n</file_contents>"))
		XCTAssertTrue(payload.contains("<transcript>\n<user>Hello</user>\n</transcript>"))
	}

	func testCursorResumeRecoveryFallbackStagesAndPrependsHandoffPayload() {
		let provider = FakeHeadlessAgentProvider()
		let vm = makeViewModel(provider: provider, onInstallPolicy: { _ in })
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		let session = vm.session(for: tabID)
		session.selectedAgent = .cursor
		session.selectedModelRaw = AgentModel.cursorAuto.rawValue
		session.replaceItems([
			AgentChatItem.user("original cursor request", sequenceIndex: 0),
			AgentChatItem.assistant("original cursor answer", sequenceIndex: 1)
		])
		vm.test_rebuildStructuredTranscript(tabID: tabID)

		vm.stageResumeRecoveryHandoffIfNeeded(for: session)
		let outbound = vm.prependPendingHandoffIfNeeded("continue please", session: session)

		XCTAssertTrue(outbound.contains("<forked_session source="))
		XCTAssertTrue(outbound.contains("native resume failed for Cursor CLI"))
		XCTAssertTrue(outbound.contains("<transcript>"))
		XCTAssertTrue(outbound.contains("original cursor request"))
		XCTAssertTrue(outbound.contains("original cursor answer"))
		XCTAssertTrue(outbound.hasSuffix("continue please"))
		XCTAssertTrue(session.pendingHandoff.isStagedForSend)
		XCTAssertFalse(session.pendingHandoff.defersProviderLockUntilSend)
	}

	func testGeminiHandedOffSessionFirstSendUsesForkedSessionPayloadWithoutHistoryReplay() async {
		let provider = FakeHeadlessAgentProvider()
		provider.enqueue(
			results: [
				AIStreamResult(type: "message_stop", text: nil, promptTokens: 20, completionTokens: 10, providerSessionID: "gem-session-handoff")
			]
		)

		let vm = makeViewModel(provider: provider, onInstallPolicy: { _ in })
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		let session = vm.session(for: tabID)
		session.selectedAgent = .gemini
		session.replaceItems([
			AgentChatItem.user("orig user", sequenceIndex: 0),
			AgentChatItem.assistant("orig answer", sequenceIndex: 1)
		])
		vm.test_rebuildStructuredTranscript(tabID: tabID)

		session.pendingHandoff = .init(
			payload: vm.test_composeSessionHandoffPayload(
				sourceTabName: "Source Session",
				sourceAgentName: "Claude Code",
				sourceModelName: "GPT-5",
				fileContentsBlock: nil,
				transcriptXML: "<transcript>\n<user>orig user</user>\n<assistant>orig answer</assistant>\n</transcript>",
				deliveryID: "delivery-handoff"
			),
			createdAt: Date(),
			sourceItemID: session.items.last?.id,
			defersProviderLockUntilSend: true,
			isStagedForSend: false
		)

		await vm.startAgentRun(tabID: tabID, initialMessage: "continue please")
		let completed = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .completed && provider.messages.count == 1
		}
		XCTAssertTrue(completed, "Expected handed-off Gemini run to complete")
		guard provider.messages.count == 1 else { return }

		let sentMessage = provider.messages[0].userMessage
		XCTAssertTrue(sentMessage.contains("<forked_session source="))
		XCTAssertTrue(sentMessage.contains("<transcript>"))
		XCTAssertTrue(sentMessage.contains("<user>orig user</user>"))
		XCTAssertTrue(sentMessage.contains("<assistant>orig answer</assistant>"))
		XCTAssertFalse(sentMessage.contains("<previous_conversation>"))
		XCTAssertFalse(sentMessage.contains("<current_instruction>"))
	}

	func testCancelAgentRunClearsPendingNonCodexTokenStateAndQueuedInstructions() async {
		let provider = FakeHeadlessAgentProvider()
		let vm = makeViewModel(provider: provider, onInstallPolicy: { _ in })
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		guard let session = vm.sessions[tabID] else {
			return XCTFail("Expected session for tab \(tabID)")
		}

		session.pendingNonCodexUserInputTokenQueue = [12, 34]
		session.activeNonCodexTurnTokenAccumulator = AgentModeViewModel.NonCodexTurnTokenAccumulator(
			estimatedUserInputTokens: 10,
			estimatedToolInputTokens: 3,
			estimatedToolOutputTokens: 7
		)
		session.pendingInstructions = ["stale follow-up"]

		await vm.cancelAgentRun(tabID: tabID)

		XCTAssertTrue(session.pendingNonCodexUserInputTokenQueue.isEmpty)
		XCTAssertNil(session.activeNonCodexTurnTokenAccumulator)
		XCTAssertTrue(session.pendingInstructions.isEmpty)
	}

	func testHeadlessSendClearsConsumedAttachmentFilesWhenRunStops() async throws {
		let provider = FakeHeadlessAgentProvider()
		provider.enqueue(
			results: [
				AIStreamResult(type: "message_stop", text: nil, promptTokens: 10, completionTokens: 5, providerSessionID: "claude-session-1")
			],
			perEventDelayNanos: 150_000_000
		)
		let vm = makeViewModel(provider: provider, onInstallPolicy: { _ in })
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		guard let session = vm.sessions[tabID] else {
			return XCTFail("Expected session for tab \(tabID)")
		}
		session.selectedAgent = .claudeCode

		let storageRoot = AgentAttachmentStore.managedStorageRootURL(for: FileManager.default.temporaryDirectory)
		try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
		let attachmentFile = storageRoot
			.appendingPathComponent("headless-\(UUID().uuidString)")
			.appendingPathExtension("png")
		try Data([0x89, 0x50, 0x4E, 0x47]).write(to: attachmentFile)
		defer { try? FileManager.default.removeItem(at: attachmentFile) }

		let attachment = AgentImageAttachment(source: .localFile(path: attachmentFile.path), title: "image.png")
		XCTAssertTrue(FileManager.default.fileExists(atPath: attachmentFile.path))
		await vm.startAgentRun(tabID: tabID, initialMessage: "inspect", attachments: [attachment])
		XCTAssertTrue(FileManager.default.fileExists(atPath: attachmentFile.path), "File should remain while run is active")

		let didComplete = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .completed
		}
		XCTAssertTrue(didComplete, "Expected run to complete")
		XCTAssertFalse(FileManager.default.fileExists(atPath: attachmentFile.path))
	}

	func testClaudeReadToolCallWithoutResultIsAutoCompleted() async throws {
		let provider = FakeHeadlessAgentProvider()
		provider.enqueue(
			results: [
				AIStreamResult(
					type: "tool_call",
					text: nil,
					toolName: "Read",
					toolArgsJSON: #"{"file_path":"README.md"}"#
				),
				AIStreamResult(type: "message_stop", text: nil, promptTokens: 30, completionTokens: 10, providerSessionID: "claude-session-read")
			]
		)

		let vm = makeViewModel(provider: provider, onInstallPolicy: { _ in })
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		guard let session = vm.sessions[tabID] else {
			return XCTFail("Expected session for tab \(tabID)")
		}
		session.selectedAgent = .claudeCode

		await vm.startAgentRun(tabID: tabID, initialMessage: "Read a file")

		let completed = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .completed
				&& session.items.contains(where: { $0.kind == .toolResult && $0.toolName == "Read" })
		}
		XCTAssertTrue(completed, "Expected Claude read tool event to auto-complete")
		XCTAssertFalse(session.items.contains(where: { $0.kind == .toolCall && $0.toolName == "Read" }))

		guard let readResult = session.items.last(where: { $0.kind == .toolResult && $0.toolName == "Read" }) else {
			return XCTFail("Expected synthesized tool_result for Read")
		}
		let resultData = try XCTUnwrap(readResult.toolResultJSON?.data(using: .utf8))
		let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: resultData) as? [String: Any])
		XCTAssertEqual(payload["status"] as? String, "completed")
	}

	func testClaudeLateExplicitRepoPromptToolCallDoesNotCreateFailedDuplicate() async {
		let invocationID = UUID()
		let argsJSON = #"{"path":"README.md"}"#
		let provider = FakeHeadlessAgentProvider()
		provider.enqueue(
			results: [
				AIStreamResult(
					type: "tool_result",
					text: nil,
					toolName: "read_file",
					toolInvocationID: invocationID,
					toolResultJSON: #"{"status":"completed","content":"ok"}"#,
					toolArgsJSON: argsJSON,
					toolIsError: false
				),
				AIStreamResult(
					type: "tool_call",
					text: nil,
					toolName: "mcp__RepoPrompt__read_file",
					toolArgsJSON: argsJSON
				),
				AIStreamResult(type: "message_stop", text: nil, promptTokens: 22, completionTokens: 8, providerSessionID: "claude-session-late-call")
			]
		)

		let vm = makeViewModel(provider: provider, onInstallPolicy: { _ in })
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		guard let session = vm.sessions[tabID] else {
			return XCTFail("Expected session for tab \(tabID)")
		}
		session.selectedAgent = .claudeCode

		await vm.startAgentRun(tabID: tabID, initialMessage: "Reproduce late provider tool_call")

		let completed = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .completed
		}
		XCTAssertTrue(completed)

		let readToolItems = session.items.filter {
			MCPIntegrationHelper.normalizedRepoPromptToolName($0.toolName ?? "") == "read_file"
		}
		XCTAssertEqual(readToolItems.count, 1)
		XCTAssertEqual(readToolItems.first?.kind, .toolResult)

		let fallbackFailures = session.items.filter { item in
			guard
				item.kind == .toolResult,
				item.toolIsError == true,
				MCPIntegrationHelper.normalizedRepoPromptToolName(item.toolName ?? "") == "read_file"
			else {
				return false
			}
			guard let payload = item.toolResultJSON else { return false }
			return payload.contains("result_missing") || payload.contains("run_ended")
		}
		XCTAssertTrue(fallbackFailures.isEmpty)

		XCTAssertFalse(session.items.contains(where: {
			$0.kind == .toolCall && $0.toolName == "mcp__RepoPrompt__read_file"
		}))
	}

	func testClaudeSessionFixtureContainsOrphanPlaceholderToolResult() throws {
		let results = try loadTranslatorStreamResultsFromClaudeSessionFixture()
		let orphanResults = results.filter {
			$0.type == "tool_result"
				&& MCPIntegrationHelper.normalizedRepoPromptToolName($0.toolName ?? "") == "tool"
				&& $0.toolInvocationID != nil
		}

		XCTAssertEqual(orphanResults.count, 1)
		XCTAssertTrue(orphanResults[0].toolResultJSON?.contains("## Code Structure ✅") == true)
	}

	func testClaudeSessionFixtureOrphanPlaceholderToolResultIsSuppressed() async throws {
		let fixtureResults = try loadTranslatorStreamResultsFromClaudeSessionFixture()
		let readCall = try XCTUnwrap(
			fixtureResults.first(where: {
				$0.type == "tool_call" && $0.toolName == "mcp__RepoPrompt__read_file"
			})
		)
		let readResult = try XCTUnwrap(
			fixtureResults.first(where: {
				$0.type == "tool_result" && $0.toolName == "mcp__RepoPrompt__read_file"
			})
		)
		let orphanPlaceholderResult = try XCTUnwrap(
			fixtureResults.first(where: {
				$0.type == "tool_result"
					&& MCPIntegrationHelper.normalizedRepoPromptToolName($0.toolName ?? "") == "tool"
					&& $0.toolInvocationID != nil
			})
		)

		let provider = FakeHeadlessAgentProvider()
		provider.enqueue(
			results: [
				readCall,
				readResult,
				orphanPlaceholderResult,
				AIStreamResult(
					type: "message_stop",
					text: nil,
					promptTokens: 20,
					completionTokens: 5,
					providerSessionID: "fixture-session"
				)
			]
		)

		let vm = makeViewModel(provider: provider, onInstallPolicy: { _ in })
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		guard let session = vm.sessions[tabID] else {
			return XCTFail("Expected session for tab \(tabID)")
		}
		session.selectedAgent = .claudeCode

		await vm.startAgentRun(tabID: tabID, initialMessage: "Replay session fixture events")
		let completed = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .completed
		}
		XCTAssertTrue(completed)

		let readToolItems = session.items.filter {
			MCPIntegrationHelper.normalizedRepoPromptToolName($0.toolName ?? "") == "read_file"
		}
		XCTAssertEqual(readToolItems.count, 1)

		let orphanPlaceholderItems = session.items.filter {
			MCPIntegrationHelper.normalizedRepoPromptToolName($0.toolName ?? "") == "tool"
		}
		XCTAssertTrue(orphanPlaceholderItems.isEmpty)
	}

	func testProviderReasoningStreamResultsDoNotCreateTranscriptItems() async throws {
		guard ClaudeReasoningExtractionFeature.isEnabled else {
			throw XCTSkip("Claude reasoning extraction is disabled by feature flag.")
		}
		let vm = makeViewModel(provider: FakeHeadlessAgentProvider(), onInstallPolicy: { _ in })
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		let session = vm.session(for: tabID)
		session.selectedAgent = .claudeCode
		session.runState = .running
		let runID = UUID()
		let runAttemptID = UUID()
		session.runID = runID
		session.activeHeadlessRunAttemptID = runAttemptID
		session.setRunningStatus("Thinking…", source: .transport)

		await vm.test_handleStreamResult(
			AIStreamResult(type: "reasoning", text: nil, reasoning: "Planning before answer."),
			session: session,
			runID: runID,
			runAttemptID: runAttemptID
		)
		let previewShown = await waitForCondition(timeoutSeconds: 2.0) {
			session.runningStatusText == "Planning before answer."
				&& session.runningStatusSource == .reasoning
		}
		XCTAssertTrue(previewShown)
		await vm.test_handleStreamResult(AIStreamResult(type: "content", text: "Done."), session: session, runID: runID, runAttemptID: runAttemptID)
		await vm.test_handleStreamResult(AIStreamResult(type: "reasoning", text: nil, reasoning: "Post-answer reasoning."), session: session, runID: runID, runAttemptID: runAttemptID)
		await vm.test_handleStreamResult(
			AIStreamResult(type: "message_stop", text: nil, promptTokens: 16, completionTokens: 6, providerSessionID: "claude-session-reasoning-ignored"),
			session: session,
			runID: runID,
			runAttemptID: runAttemptID
		)

		XCTAssertFalse(session.items.contains { $0.kind == .thinking })
		XCTAssertFalse(session.items.contains { $0.text.contains("Planning before answer") })
		XCTAssertFalse(session.items.contains { $0.text.contains("Post-answer reasoning") })
		XCTAssertTrue(session.items.contains { $0.kind == .assistant && $0.text == "Done." })
		XCTAssertNil(session.runningStatusText)
		XCTAssertNil(session.runningStatusSource)
		XCTAssertTrue(session.claudeReasoningStatusBuffer.isEmpty)
	}

	func testClaudeReasoningStreamResultsUpdateRunningStatusOnly() async throws {
		guard ClaudeReasoningExtractionFeature.isEnabled else {
			throw XCTSkip("Claude reasoning extraction is disabled by feature flag.")
		}
		let vm = makeViewModel(provider: FakeHeadlessAgentProvider(), onInstallPolicy: { _ in })
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		let session = vm.session(for: tabID)
		session.selectedAgent = .claudeCode
		session.setRunningStatus("Thinking…", source: .transport)

		let changedImmediately = vm.test_applyClaudeReasoningStatusDelta("Inspecting project\nReading README.md", session: session)
		XCTAssertFalse(changedImmediately)

		let previewShown = await waitForCondition(timeoutSeconds: 2.0) {
			session.runningStatusText == "Reading README.md"
				&& session.runningStatusSource == .reasoning
		}
		XCTAssertTrue(previewShown, "Expected Claude reasoning to update running status, got \(session.runningStatusText ?? "nil")")
		XCTAssertFalse(session.items.contains { $0.kind == .thinking })
		XCTAssertFalse(session.items.contains { $0.text.contains("Reading README") })
		XCTAssertEqual(session.claudeReasoningStatusBuffer, "Inspecting project\nReading README.md")

		XCTAssertTrue(session.clearClaudeReasoningStatus(clearDisplayedStatus: true))
		XCTAssertNil(session.runningStatusText)
		XCTAssertNil(session.runningStatusSource)
		XCTAssertTrue(session.claudeReasoningStatusBuffer.isEmpty)
	}

	func testClaudeReasoningPreviewPrecedenceAndClearing() async throws {
		guard ClaudeReasoningExtractionFeature.isEnabled else {
			throw XCTSkip("Claude reasoning extraction is disabled by feature flag.")
		}
		let vm = makeViewModel(provider: FakeHeadlessAgentProvider(), onInstallPolicy: { _ in })
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		let session = vm.session(for: tabID)
		session.selectedAgent = .claudeCode
		session.runState = .running
		let runID = UUID()
		let runAttemptID = UUID()
		session.runID = runID
		session.activeHeadlessRunAttemptID = runAttemptID
		session.setRunningStatus("Thinking…", source: .transport)

		await vm.test_handleStreamResult(
			AIStreamResult(type: "reasoning", text: nil, reasoning: "Considering alternatives"),
			session: session,
			runID: runID,
			runAttemptID: runAttemptID
		)
		let reasoningShown = await waitForCondition(timeoutSeconds: 2.0) {
			session.runningStatusText == "Considering alternatives"
				&& session.runningStatusSource == .reasoning
		}
		XCTAssertTrue(reasoningShown)

		await vm.test_handleStreamResult(AIStreamResult(type: "status", text: "Thinking…"), session: session, runID: runID, runAttemptID: runAttemptID)
		XCTAssertEqual(session.runningStatusText, "Considering alternatives")
		XCTAssertEqual(session.runningStatusSource, .reasoning)

		await vm.test_handleStreamResult(AIStreamResult(type: "tool_call", text: nil, toolName: "read_file", toolArgsJSON: "{}"), session: session, runID: runID, runAttemptID: runAttemptID)
		XCTAssertEqual(session.runningStatusText, "Considering alternatives")
		XCTAssertEqual(session.runningStatusSource, .reasoning)
		await vm.test_handleStreamResult(AIStreamResult(type: "tool_result", text: nil, toolName: "read_file", toolResultJSON: "{\"ok\":true}"), session: session, runID: runID, runAttemptID: runAttemptID)
		XCTAssertEqual(session.runningStatusText, "Considering alternatives")
		XCTAssertEqual(session.runningStatusSource, .reasoning)

		await vm.test_handleStreamResult(AIStreamResult(type: "reasoning", text: nil, reasoning: "Reading README"), session: session, runID: runID, runAttemptID: runAttemptID)
		let nextReasoningShown = await waitForCondition(timeoutSeconds: 2.0) {
			session.runningStatusText == "Reading README"
				&& session.runningStatusSource == .reasoning
		}
		XCTAssertTrue(nextReasoningShown)

		await vm.test_handleStreamResult(AIStreamResult(type: "status", text: "Compacting context — Permission mode: acceptEdits"), session: session, runID: runID, runAttemptID: runAttemptID)
		XCTAssertEqual(session.runningStatusText, "Reading README")
		XCTAssertEqual(session.runningStatusSource, .reasoning)
		XCTAssertEqual(session.claudeReasoningStatusBuffer, "Reading README")

		await vm.test_handleStreamResult(
			AIStreamResult(type: "message_stop", text: nil, promptTokens: 10, completionTokens: 3, providerSessionID: "claude-session-precedence"),
			session: session,
			runID: runID,
			runAttemptID: runAttemptID
		)
		XCTAssertNil(session.runningStatusText)
	}

	func testClaudeReasoningPreviewIsTruncatedAndRateLimited() async throws {
		guard ClaudeReasoningExtractionFeature.isEnabled else {
			throw XCTSkip("Claude reasoning extraction is disabled by feature flag.")
		}
		let vm = makeViewModel(provider: FakeHeadlessAgentProvider(), onInstallPolicy: { _ in })
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		let session = vm.session(for: tabID)
		session.selectedAgent = .claudeCode
		session.setRunningStatus("Thinking…", source: .transport)

		let longLine = String(repeating: "analyzing status precedence and truncation behavior ", count: 8)
		let changedImmediately = vm.test_applyClaudeReasoningStatusDelta("First line\n\(longLine)", session: session)
		XCTAssertFalse(changedImmediately)
		XCTAssertEqual(session.runningStatusText, "Thinking…")
		XCTAssertEqual(session.runningStatusSource, .transport)
		XCTAssertNotNil(session.claudeReasoningStatusFlushTask)

		let previewShown = await waitForCondition(timeoutSeconds: 2.0) {
			session.runningStatusSource == .reasoning
		}
		XCTAssertTrue(previewShown)
		let preview = try XCTUnwrap(session.runningStatusText)
		XCTAssertTrue(preview.hasPrefix("…"), preview)
		XCTAssertLessThanOrEqual(preview.count, 128)
		XCTAssertFalse(preview.contains("Thinking:"))
		XCTAssertFalse(preview.contains("\n"))
		XCTAssertFalse(preview.contains("First line"))
	}

	func testClaudeReasoningPreviewCancelledFlushDoesNotPublishNextDeltaImmediately() async throws {
		guard ClaudeReasoningExtractionFeature.isEnabled else {
			throw XCTSkip("Claude reasoning extraction is disabled by feature flag.")
		}
		let vm = makeViewModel(provider: FakeHeadlessAgentProvider(), onInstallPolicy: { _ in })
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		let session = vm.session(for: tabID)
		session.selectedAgent = .claudeCode
		session.setRunningStatus("Thinking…", source: .transport)

		XCTAssertFalse(vm.test_applyClaudeReasoningStatusDelta("First preview", session: session))
		XCTAssertNotNil(session.claudeReasoningStatusFlushTask)
		XCTAssertFalse(session.clearClaudeReasoningStatus(clearDisplayedStatus: true))
		XCTAssertNil(session.claudeReasoningStatusFlushTask)

		XCTAssertFalse(vm.test_applyClaudeReasoningStatusDelta("Second preview", session: session))
		try? await Task.sleep(nanoseconds: 50_000_000)
		XCTAssertEqual(session.runningStatusText, "Thinking…")
		XCTAssertEqual(session.runningStatusSource, .transport)

		let previewShown = await waitForCondition(timeoutSeconds: 2.0) {
			session.runningStatusText == "Second preview"
				&& session.runningStatusSource == .reasoning
		}
		XCTAssertTrue(previewShown)
	}

	func testClaudeRenderProviderMessageIncludesEscapedAtPathImageReferences() {
		let provider = FakeHeadlessAgentProvider()
		let vm = makeViewModel(provider: provider, onInstallPolicy: { _ in })
		let path = "/tmp/My Folder/image (1).png"
		let attachment = AgentImageAttachment(source: .localFile(path: path), title: "image (1).png")

		let rendered = vm.test_renderProviderMessage(
			text: "Describe this image.",
			attachments: [attachment],
			agent: .claudeCode
		)

		let expectedRef = "@\(vm.test_escapePathForAtCommand(path))"
		XCTAssertEqual(rendered, "\(expectedRef)\n\nDescribe this image.")
	}

	func testQueuedSteeringQueuesForGeminiWhenNoLiveACPController() {
		let provider = FakeHeadlessAgentProvider()
		let vm = makeViewModel(provider: provider, onInstallPolicy: { _ in })
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		guard let session = vm.sessions[tabID] else {
			return XCTFail("Expected session for tab \(tabID)")
		}

		session.selectedAgent = .gemini
		session.runState = .running

		let result = vm.test_submitUserTurn(tabID: tabID, text: "follow-up steering")
		if case .blocked(let message) = result {
			return XCTFail("Expected Gemini steering submission, got blocked: \(message)")
		}

		XCTAssertEqual(session.items.count, 1)
		XCTAssertEqual(session.items.first?.kind, .user)
		XCTAssertEqual(session.items.first?.text, "follow-up steering")
		XCTAssertEqual(session.pendingInstructions, ["follow-up steering"])
		XCTAssertFalse(session.pendingNonCodexUserInputTokenQueue.isEmpty, "Queued Gemini steering should track user token estimates")
	}

	func testQueuedSteeringIsAllowedForClaudeCode() async {
		let provider = FakeHeadlessAgentProvider()
		let vm = makeViewModel(provider: provider, onInstallPolicy: { _ in })
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		guard let session = vm.sessions[tabID] else {
			return XCTFail("Expected session for tab \(tabID)")
		}

		session.selectedAgent = .claudeCode
		session.runState = .running

		let result = vm.test_submitUserTurn(tabID: tabID, text: "follow-up steering")
		if case .blocked(let message) = result {
			return XCTFail("Expected Claude steering submission, got blocked: \(message)")
		}

		let sent = await waitForCondition(timeoutSeconds: 1.0) {
			provider.messages.count == 1
		}
		XCTAssertTrue(sent, "Expected Claude steering to send immediately")
		XCTAssertEqual(provider.messages.first?.userMessage, "follow-up steering")

		XCTAssertEqual(session.items.count, 1)
		XCTAssertEqual(session.items.first?.kind, .user)
		XCTAssertEqual(session.items.first?.text, "follow-up steering")
		XCTAssertTrue(session.pendingInstructions.isEmpty)
		XCTAssertTrue(session.pendingNonCodexUserInputTokenQueue.isEmpty)
		XCTAssertNotEqual(session.activeNonCodexTurnTokenAccumulator?.estimatedUserInputTokens, 0)
	}

	func testClaudeSlashAutocompleteIncludesWorkspaceGenericAgentSkillsAndSlash() async throws {
		let workspaceURL = try makeTemporaryDirectory(named: "claude-autocomplete-workspace")
		let homeURL = try makeTemporaryDirectory(named: "claude-autocomplete-home")
		let skillCatalog = AgentSkillCatalog(homeDirectoryURL: homeURL)
		try createFolderSkill(
			at: workspaceURL,
			name: "generic-review",
			body: "Review with the generic skill.\n$ARGUMENTS"
		)
		try createLegacySkill(
			at: workspaceURL,
			name: "generic-fix",
			body: "Fix with the generic slash command.\n$ARGUMENTS",
			relativeRoot: ".agents/slash"
		)

		let vm = makeViewModel(
			provider: FakeHeadlessAgentProvider(),
			onInstallPolicy: { _ in },
			testWorkspacePath: workspaceURL.path,
			testWorkspaceDirectory: workspaceURL,
			skillCatalog: skillCatalog
		)
		let tabID = UUID()
		vm.test_setCurrentTabIDOverride(tabID)
		vm.ensureSession(for: tabID)
		guard let session = vm.sessions[tabID] else {
			return XCTFail("Expected tab session to exist")
		}
		session.selectedAgent = .claudeCode

		let suggestions = await vm.slashSkillSuggestions(for: "generic")
		let matchingSuggestions = suggestions.filter {
			$0.relativePath == "generic-review" || $0.relativePath == "generic-fix"
		}
		XCTAssertEqual(Set(matchingSuggestions.map(\.relativePath)), ["generic-review", "generic-fix"])
		XCTAssertTrue(matchingSuggestions.allSatisfy { $0.kind == .skill })
	}

	func testExplicitSkillNamespaceExpandsSameNamedCodexNativeSkill() async throws {
		let workspaceURL = try makeTemporaryDirectory(named: "skill-namespace-workspace")
		try createFolderSkill(
			at: workspaceURL,
			name: "goal",
			body: "Use the goal skill.\n$ARGUMENTS"
		)

		let vm = makeViewModel(
			provider: FakeHeadlessAgentProvider(),
			onInstallPolicy: { _ in },
			testWorkspacePath: workspaceURL.path,
			testWorkspaceDirectory: workspaceURL
		)

		XCTAssertEqual(vm.test_extractSlashSkillTokenNames(from: "/skill:goal inspect auth"), ["skill:goal"])
		let expanded = await vm.test_augmentUserMessageForProviderSend(
			"/skill:goal inspect auth",
			agent: .codexExec
		)

		XCTAssertEqual(vm.test_resolvedSlashSkillInvocationNames(from: "/skill:goal inspect auth"), ["goal"])
		XCTAssertTrue(expanded.contains("<selected_skill_context name=\"goal\" scope=\"workspace\" source=\".agents/skills\">"))
		XCTAssertTrue(expanded.contains("Use the goal skill."))
		XCTAssertTrue(expanded.contains("<user_instructions>\ninspect auth\n</user_instructions>"))
	}

	func testSlashSkillExpansionIncludesWorkspaceSkillNoticeAndDirectoryTree() async throws {
		let workspaceURL = try makeTemporaryDirectory(named: "skill-workspace")
		try createFolderSkill(
			at: workspaceURL,
			name: "review",
			body: "Follow the review checklist.\n$ARGUMENTS",
			extraFiles: [
				"references/checklist.md": "- item",
				"scripts/run.sh": "#!/bin/sh\necho review"
			]
		)

		let vm = makeViewModel(
			provider: FakeHeadlessAgentProvider(),
			onInstallPolicy: { _ in },
			testWorkspacePath: workspaceURL.path,
			testWorkspaceDirectory: workspaceURL
		)

		let expanded = await vm.test_augmentUserMessageForProviderSend(
			"/review inspect auth",
			agent: .codexExec
		)

		XCTAssertTrue(expanded.contains("<selected_skill_context name=\"review\" scope=\"workspace\" source=\".agents/skills\">"))
		XCTAssertTrue(expanded.contains("already included below"))
		XCTAssertTrue(expanded.contains("Do not re-read the skill file"))
		XCTAssertTrue(expanded.contains("<skill_directory_tree>"))
		XCTAssertTrue(expanded.contains("SKILL.md"))
		XCTAssertTrue(expanded.contains("references/"))
		XCTAssertTrue(expanded.contains("scripts/"))
		XCTAssertTrue(expanded.contains("Treat any <user_instructions> block"))
		XCTAssertTrue(expanded.contains("Follow the review checklist."))
		XCTAssertTrue(expanded.contains("<user_instructions>\ninspect auth\n</user_instructions>"))
	}

	func testSelectedWorkflowWrapsExpandedSlashSkillPrompt() async throws {
		let workspaceURL = try makeTemporaryDirectory(named: "workflow-skill-workspace")
		try createFolderSkill(
			at: workspaceURL,
			name: "review",
			body: "Follow the review checklist.\n$ARGUMENTS"
		)
		let provider = FakeHeadlessAgentProvider()
		provider.enqueue(
			results: [
				AIStreamResult(type: "message_stop", text: nil, promptTokens: 20, completionTokens: 5, providerSessionID: "claude-session-workflow-skill")
			]
		)
		let vm = makeViewModel(
			provider: provider,
			onInstallPolicy: { _ in },
			testWorkspacePath: workspaceURL.path,
			testWorkspaceDirectory: workspaceURL
		)
		let tabID = UUID()
		vm.test_setCurrentTabIDOverride(tabID)
		defer { vm.test_setCurrentTabIDOverride(nil) }
		vm.ensureSession(for: tabID)
		guard let session = vm.sessions[tabID] else {
			return XCTFail("Expected tab session to exist")
		}
		session.selectedAgent = .claudeCode
		let workflow = AgentWorkflowDefinition(
			customID: UUID(),
			displayName: "Outer Workflow",
			iconName: "sparkles",
			template: "OUTER WORKFLOW START\n$ARGUMENTS\nOUTER WORKFLOW END"
		)
		vm.selectWorkflow(workflow)

		let result = vm.test_submitUserTurn(tabID: tabID, text: "/review inspect auth flow")

		XCTAssertEqual(result, .submitted)
		let sent = await waitForCondition(timeoutSeconds: 2.0) {
			provider.messages.count == 1
		}
		XCTAssertTrue(sent)
		guard let message = provider.messages.first?.userMessage else {
			return XCTFail("Expected provider message")
		}
		XCTAssertTrue(message.contains("OUTER WORKFLOW START"))
		XCTAssertTrue(message.contains("<selected_skill_context name=\"review\" scope=\"workspace\" source=\".agents/skills\">"))
		XCTAssertTrue(message.contains("Follow the review checklist."))
		XCTAssertTrue(message.contains("<user_instructions>\ninspect auth flow\n</user_instructions>"))
		XCTAssertTrue(message.contains("OUTER WORKFLOW END"))
		XCTAssertFalse(message.contains("REPOPROMPT_PENDING_SLASH_SKILL_BASE64"))
		XCTAssertNil(session.selectedWorkflow)
		XCTAssertNil(vm.makeStatusPillsSnapshot().selectedWorkflow)
		XCTAssertEqual(session.items.last?.workflow?.displayName, "Outer Workflow")
		XCTAssertEqual(session.items.last?.text, "/review inspect auth flow")
	}

	func testSlashSkillExpansionIncludesGlobalHomeRelativeDirectoryTree() async throws {
		let tempHomeURL = try makeTemporaryDirectory(named: "skill-home")
		let skillCatalog = AgentSkillCatalog(homeDirectoryURL: tempHomeURL)
		try createFolderSkill(
			at: tempHomeURL,
			name: "triage",
			body: "Triage the issue.\n$ARGUMENTS",
			extraFiles: [
				"references/guide.md": "guide"
			],
			relativeRoot: ".agents/skills"
		)

		let vm = makeViewModel(
			provider: FakeHeadlessAgentProvider(),
			onInstallPolicy: { _ in },
			testWorkspacePath: nil,
			skillCatalog: skillCatalog
		)

		let expanded = await vm.test_augmentUserMessageForProviderSend(
			"/triage investigate crash",
			agent: .codexExec
		)

		XCTAssertTrue(expanded.contains("scope=\"global\""))
		XCTAssertTrue(expanded.contains("source=\".agents/skills\""))
		XCTAssertTrue(expanded.contains("~/.agents/skills/triage"))
		XCTAssertTrue(expanded.contains("references/"))
		XCTAssertTrue(expanded.contains("<user_instructions>\ninvestigate crash\n</user_instructions>"))
	}

	func testLegacySlashSkillExpansionUsesSingleFileTree() async throws {
		let tempHomeURL = try makeTemporaryDirectory(named: "legacy-skill-home")
		let skillCatalog = AgentSkillCatalog(homeDirectoryURL: tempHomeURL)
		try createLegacySkill(
			at: tempHomeURL,
			name: "quick-fix",
			body: "Apply a minimal fix.\n$ARGUMENTS",
			relativeRoot: ".agents/slash"
		)
		let siblingURL = tempHomeURL
			.appendingPathComponent(".agents", isDirectory: true)
			.appendingPathComponent("slash", isDirectory: true)
			.appendingPathComponent("other.md")
		try FileManager.default.createDirectory(at: siblingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
		try "Ignore me".write(to: siblingURL, atomically: true, encoding: .utf8)

		let vm = makeViewModel(
			provider: FakeHeadlessAgentProvider(),
			onInstallPolicy: { _ in },
			testWorkspacePath: nil,
			skillCatalog: skillCatalog
		)

		let expanded = await vm.test_augmentUserMessageForProviderSend(
			"/quick-fix patch parser",
			agent: .codexExec
		)

		XCTAssertTrue(expanded.contains("~/.agents/slash\n└── quick-fix.md"))
		XCTAssertFalse(expanded.contains("other.md"))
		XCTAssertTrue(expanded.contains("<user_instructions>\npatch parser\n</user_instructions>"))
	}

	func testClaudeSlashSkillWithAttachmentKeepsAttachmentHeaderBeforeExpandedSkillBlock() async throws {
		let workspaceURL = try makeTemporaryDirectory(named: "skill-attachment-workspace")
		try createFolderSkill(
			at: workspaceURL,
			name: "review",
			body: "Inspect the provided context.\n$ARGUMENTS",
			extraFiles: ["references/context.md": "context"]
		)

		let provider = FakeHeadlessAgentProvider()
		provider.enqueue(
			results: [
				AIStreamResult(type: "message_stop", text: nil, promptTokens: 20, completionTokens: 5, providerSessionID: "claude-session-skill-attachment")
			]
		)
		let vm = makeViewModel(
			provider: provider,
			onInstallPolicy: { _ in },
			testWorkspacePath: workspaceURL.path,
			testWorkspaceDirectory: workspaceURL
		)
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		guard let session = vm.sessions[tabID] else {
			return XCTFail("Expected tab session to exist")
		}
		session.selectedAgent = .claudeCode

		let imagePath = "/tmp/My Folder/skill screenshot.png"
		session.pendingImageAttachments = [AgentImageAttachment(source: .localFile(path: imagePath), title: "skill screenshot.png")]

		_ = vm.test_submitUserTurn(tabID: tabID, text: "/review inspect this screenshot")

		let sent = await waitForCondition(timeoutSeconds: 2.0) {
			provider.messages.count == 1
		}
		XCTAssertTrue(sent)
		guard let message = provider.messages.first?.userMessage else {
			return XCTFail("Expected provider message")
		}

		let expectedPrefix = "@\(vm.test_escapePathForAtCommand(imagePath))\n\n<selected_skill_context"
		XCTAssertTrue(message.hasPrefix(expectedPrefix), "Expected attachment header before expanded skill block, got: \(message)")
		XCTAssertTrue(message.contains("<skill_directory_tree>"))
		XCTAssertTrue(message.contains("SKILL.md"))
		XCTAssertTrue(message.contains("<user_instructions>\ninspect this screenshot\n</user_instructions>"))
	}

	private func makeTemporaryDirectory(named prefix: String) throws -> URL {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		addTeardownBlock {
			try? FileManager.default.removeItem(at: url)
		}
		return url
	}

	private func createFolderSkill(
		at rootURL: URL,
		name: String,
		body: String,
		extraFiles: [String: String] = [:],
		relativeRoot: String = ".agents/skills"
	) throws {
		let skillDirectoryURL = rootURL
			.appendingPathComponent(relativeRoot, isDirectory: true)
			.appendingPathComponent(name, isDirectory: true)
		try FileManager.default.createDirectory(at: skillDirectoryURL, withIntermediateDirectories: true)
		let skillBody = """
		---
		name: \(name)
		description: Test skill
		---

		\(body)
		"""
		try skillBody.write(
			to: skillDirectoryURL.appendingPathComponent("SKILL.md"),
			atomically: true,
			encoding: .utf8
		)
		for (relativePath, content) in extraFiles {
			let fileURL = skillDirectoryURL.appendingPathComponent(relativePath)
			try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
			try content.write(to: fileURL, atomically: true, encoding: .utf8)
		}
	}

	private func createLegacySkill(
		at rootURL: URL,
		name: String,
		body: String,
		relativeRoot: String
	) throws {
		let directoryURL = rootURL.appendingPathComponent(relativeRoot, isDirectory: true)
		try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
		let skillBody = """
		---
		name: \(name)
		description: Test skill
		---

		\(body)
		"""
		try skillBody.write(
			to: directoryURL.appendingPathComponent("\(name).md"),
			atomically: true,
			encoding: .utf8
		)
	}

	private func loadTranslatorStreamResultsFromClaudeSessionFixture() throws -> [AIStreamResult] {
		let fixtureURL = try XCTUnwrap(resolveClaudeSessionFixtureURL())
		let fixtureData = try Data(contentsOf: fixtureURL)
		let fixtureText = try XCTUnwrap(String(data: fixtureData, encoding: .utf8))

		var results: [AIStreamResult] = []
		for line in fixtureText.split(whereSeparator: { $0.isNewline }) {
			guard let lineData = String(line).data(using: .utf8),
				let root = try JSONSerialization.jsonObject(with: lineData) as? [String: Any],
				(root["kind"] as? String) == "translator.streamResult",
				let payload = root["payload"] as? [String: Any],
				let type = payload["type"] as? String,
				!type.isEmpty
			else {
				continue
			}

			results.append(
				AIStreamResult(
					type: type,
					text: payload["text"] as? String,
					reasoning: payload["reasoning"] as? String,
					promptTokens: intValue(payload["promptTokens"]),
					completionTokens: intValue(payload["completionTokens"]),
					cost: doubleValue(payload["cost"]),
					toolName: payload["toolName"] as? String,
					toolArgs: payload["toolArgs"] as? String,
					toolOutput: payload["toolOutput"] as? String,
					toolInvocationID: (payload["toolInvocationID"] as? String).flatMap(UUID.init(uuidString:)),
					toolResultJSON: payload["toolResultJSON"] as? String,
					toolArgsJSON: payload["toolArgsJSON"] as? String,
					toolIsError: boolValue(payload["toolIsError"]),
					providerSessionID: payload["providerSessionID"] as? String,
					stopReason: payload["stopReason"] as? String,
					modelContextWindow: intValue(payload["modelContextWindow"]),
					contextUsedTokens: intValue(payload["contextUsedTokens"])
				)
			)
		}

		return results
	}

	private func resolveClaudeSessionFixtureURL() -> URL? {
		let fixtureName = "claude-session-1f294e1d-e0ef-4903-88bf-b8748dbc9f45-20260220-162619.jsonl"
		let fileManager = FileManager.default
		let testFileURL = URL(fileURLWithPath: #filePath, isDirectory: false)
		let testsRootURL = testFileURL.deletingLastPathComponent()
		let fixtureURL = testsRootURL
			.appendingPathComponent("Fixtures")
			.appendingPathComponent("ClaudeSessions")
			.appendingPathComponent(fixtureName)
		return fileManager.fileExists(atPath: fixtureURL.path) ? fixtureURL : nil
	}

	private func intValue(_ raw: Any?) -> Int? {
		switch raw {
		case let value as Int:
			return value
		case let value as NSNumber:
			return value.intValue
		default:
			return nil
		}
	}

	private func doubleValue(_ raw: Any?) -> Double? {
		switch raw {
		case let value as Double:
			return value
		case let value as NSNumber:
			return value.doubleValue
		default:
			return nil
		}
	}

	private func boolValue(_ raw: Any?) -> Bool? {
		switch raw {
		case let value as Bool:
			return value
		case let value as NSNumber:
			return value.boolValue
		default:
			return nil
		}
	}

	private func makeViewModel(
		provider: HeadlessAgentProvider,
		onInstallPolicy: @escaping (PolicyInstallCall) -> Void = { _ in },
		clearConsumedAttachmentsAfterProviderConsumption: Bool = true,
		shouldManageCodexTooling: Bool = false,
		onCleanupRouting: @escaping (RoutingCleanupCall) -> Void = { _ in },
		onCancelTools: @escaping (ToolCancelCall) -> Void = { _ in },
		testWorkspacePath: String? = FileManager.default.currentDirectoryPath,
		testWorkspaceDirectory: URL? = nil,
		skillCatalog: AgentSkillCatalog? = nil
	) -> AgentModeViewModel {
		AgentModeViewModel(
			testWindowID: 99,
			testWorkspacePath: testWorkspacePath,
			testWorkspaceDirectory: testWorkspaceDirectory,
			clearConsumedAttachmentsAfterProviderConsumption: clearConsumedAttachmentsAfterProviderConsumption,
			shouldManageCodexTooling: shouldManageCodexTooling,
			skillCatalog: skillCatalog,
			codexControllerFactory: { _, _, _, _, _, _ in
				NoopCodexController()
			},
			claudeControllerFactory: { runID, _, _, _, _, _, _ in
				ProviderBackedClaudeController(runID: runID, provider: provider)
			},
			headlessProviderFactory: { _, _ in
				provider
			},
			connectionPolicyInstaller: { clientName, windowID, restrictedTools, oneShot, reason, ttl, tabID, runID, additionalTools, purpose, _, _, _ in
				if let runID {
					MCPRoutingWaiter.signalRouted(runID)
				}
				onInstallPolicy(
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
			},
				mcpRunRoutingCleaner: { runID, windowID, reason in
					onCleanupRouting(RoutingCleanupCall(runID: runID, windowID: windowID, reason: reason))
				},
				mcpRunToolCanceller: { runID, reason in
					onCancelTools(ToolCancelCall(runID: runID, reason: reason))
					return 0
				}
			)
	}

	private func assertPolicyCall(_ call: PolicyInstallCall, expectedClient: String, expectedTabID: UUID) {
		XCTAssertEqual(call.clientName, expectedClient)
		XCTAssertEqual(call.windowID, 99)
		XCTAssertEqual(call.restrictedTools, AgentModeMCPToolPolicy.restrictedTools)
		XCTAssertEqual(call.oneShot, true)
		XCTAssertEqual(call.reason, "agent-mode-run")
		XCTAssertEqual(call.ttl, AgentModeMCPPolicyInstaller.policyTTL, accuracy: 0.001)
		XCTAssertEqual(call.tabID, expectedTabID)
		XCTAssertNotNil(call.runID)
		switch expectedClient {
		case "claude-code":
			XCTAssertEqual(call.additionalTools, AgentModeMCPToolPolicy.claudeNativeGrantedTools)
		case "codex-mcp-client":
			XCTAssertEqual(call.additionalTools, AgentModeMCPToolPolicy.codexNativeGrantedTools)
		default:
			XCTAssertEqual(call.additionalTools, AgentModeMCPToolPolicy.grantedTools)
		}
		XCTAssertEqual(call.purpose, .agentModeRun)
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
		condition: @escaping () async -> Bool
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

private struct RoutingCleanupCall: Equatable {
	let runID: UUID
	let windowID: Int
	let reason: String
}

private struct ToolCancelCall: Equatable {
	let runID: UUID
	let reason: String?
}

private final class BlockingDisposeHeadlessAgentProvider: HeadlessAgentProvider {
	private let stateQueue = DispatchQueue(label: "BlockingDisposeHeadlessAgentProvider.state")
	private var continuation: CheckedContinuation<Void, Never>?
	private var didReleaseDispose = false
	private var _disposeStarted = false
	private var _disposeFinished = false

	var disposeStarted: Bool {
		stateQueue.sync { _disposeStarted }
	}

	var disposeFinished: Bool {
		stateQueue.sync { _disposeFinished }
	}

	func streamAgentMessage(_ message: AgentMessage, runID: UUID?) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
		AsyncThrowingStream { continuation in
			continuation.finish()
		}
	}

	func dispose() async {
		await withCheckedContinuation { continuation in
			let shouldResumeImmediately = stateQueue.sync {
				_disposeStarted = true
				if didReleaseDispose {
					_disposeFinished = true
					return true
				}
				self.continuation = continuation
				return false
			}
			if shouldResumeImmediately {
				continuation.resume()
			}
		}
	}

	func releaseDispose() {
		let continuation = stateQueue.sync {
			didReleaseDispose = true
			let continuation = self.continuation
			self.continuation = nil
			_disposeFinished = continuation != nil || _disposeFinished
			return continuation
		}
		continuation?.resume()
	}
}

private final class FakeHeadlessAgentProvider: HeadlessAgentProvider {
	private struct PlannedStream {
		let results: [AIStreamResult]
		let perEventDelayNanos: UInt64
	}

	private let lock = NSLock()
	private var plans: [PlannedStream] = []
	private(set) var messages: [AgentMessage] = []
	var onStreamStart: (() -> Void)? = nil

	func enqueue(results: [AIStreamResult], perEventDelayNanos: UInt64 = 0) {
		lock.lock()
		plans.append(PlannedStream(results: results, perEventDelayNanos: perEventDelayNanos))
		lock.unlock()
	}

	func streamAgentMessage(_ message: AgentMessage, runID: UUID?) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
		onStreamStart?()
		let plan: PlannedStream
		lock.lock()
		messages.append(message)
		if plans.isEmpty {
			plan = PlannedStream(results: [], perEventDelayNanos: 0)
		} else {
			plan = plans.removeFirst()
		}
		lock.unlock()

		return AsyncThrowingStream { continuation in
			Task {
				for result in plan.results {
					if plan.perEventDelayNanos > 0 {
						try? await Task.sleep(nanoseconds: plan.perEventDelayNanos)
					}
					continuation.yield(result)
				}
				continuation.finish()
			}
		}
	}

	func dispose() async {}
}

private actor ProviderBackedClaudeController: ClaudeSessionControlling {
	private let runID: UUID
	private let provider: HeadlessAgentProvider
	private var activeSession = false
	private var sessionID: String?
	private var streamTask: Task<Void, Never>?
	private let eventsStream: AsyncStream<ClaudeNativeProcessSessionController.Event>
	private var eventsContinuation: AsyncStream<ClaudeNativeProcessSessionController.Event>.Continuation?

	var hasActiveSession: Bool {
		activeSession
	}

	var hasTurnInFlight: Bool {
		streamTask != nil
	}

	nonisolated var events: AsyncStream<ClaudeNativeProcessSessionController.Event> {
		eventsStream
	}

	init(runID: UUID, provider: HeadlessAgentProvider) {
		self.runID = runID
		self.provider = provider
		var continuationRef: AsyncStream<ClaudeNativeProcessSessionController.Event>.Continuation?
		self.eventsStream = AsyncStream { continuation in
			continuationRef = continuation
		}
		self.eventsContinuation = continuationRef
	}

	func ensureEventsStreamReady() {}
	func resetEventsStreamForNewRun() {}

	func startOrResume(
		existingSessionID: String?,
		model _: String?,
		effortLevel _: ClaudeCodeEffortLevel?,
		systemPromptOverride _: String?
	) async throws -> ClaudeNativeProcessSessionController.SessionRef {
		self.sessionID = existingSessionID
		activeSession = true
		return ClaudeNativeProcessSessionController.SessionRef(sessionID: sessionID)
	}

	func currentSessionRef() async -> ClaudeNativeProcessSessionController.SessionRef {
		ClaudeNativeProcessSessionController.SessionRef(sessionID: sessionID)
	}

	func applyModelAndEffort(model _: String?, effortLevel _: ClaudeCodeEffortLevel?) async throws {}

	@discardableResult
	func sendUserMessage(_ text: String) async throws -> UUID {
		guard activeSession else {
			throw NSError(domain: "ProviderBackedClaudeController", code: 1)
		}
		let turnID = UUID()
		let message = AgentMessage(
			systemPrompt: "",
			userMessage: text,
			resumeSessionID: sessionID
		)
		let capturedTurnID = turnID
		streamTask?.cancel()
		streamTask = Task { [weak self] in
			await self?.consumeProviderStream(message, turnID: capturedTurnID)
		}
		return turnID
	}

	private func consumeProviderStream(_ message: AgentMessage, turnID: UUID) async {
		defer { streamTask = nil }
		do {
			let stream = try await provider.streamAgentMessage(message, runID: runID)
			for try await result in stream {
				if Task.isCancelled { throw CancellationError() }
				if let providerSessionID = result.providerSessionID,
					!providerSessionID.isEmpty {
					sessionID = providerSessionID
				}
				eventsContinuation?.yield(.stream(result))
			}
			eventsContinuation?.yield(.turnCompleted(turnID: turnID, status: .completed))
		} catch is CancellationError {
			// Cancellation is handled by AgentModeRunService.cancelRun.
		} catch {
			eventsContinuation?.yield(.error(error.localizedDescription))
			eventsContinuation?.yield(.turnCompleted(turnID: turnID, status: .failed))
		}
	}

	func interruptTurn(reason: String) async -> ClaudeNativeProcessSessionController.InterruptOutcome {
		guard streamTask != nil else { return .noTurnInFlight }
		streamTask?.cancel()
		streamTask = nil
		return .acknowledged
	}

	func shutdown() async {
		streamTask?.cancel()
		streamTask = nil
		activeSession = false
		await provider.dispose()
		eventsContinuation?.finish()
	}

	func respondToPermissionRequest(id _: String, decision _: AgentApprovalDecision) async {}
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

private final class RecordingCodexController: CodexSessionControlling {
	private(set) var hasActiveThread: Bool = false
	private(set) var sendCallCount: Int = 0
	var events: AsyncStream<CodexNativeSessionController.Event> { AsyncStream { _ in } }
	private let onSend: () -> Void

	init(onSend: @escaping () -> Void) {
		self.onSend = onSend
	}

	func ensureEventsStreamReady() {}

	func startOrResume(
		existing: CodexNativeSessionController.SessionRef?,
		baseInstructions: String
	) async throws -> CodexNativeSessionController.SessionRef {
		hasActiveThread = true
		return CodexNativeSessionController.SessionRef(conversationID: "recording", rolloutPath: nil, model: nil, reasoningEffort: nil)
	}

	func sendUserMessage(_ text: String) async throws {
		sendCallCount += 1
		onSend()
	}

	func sendUserTurn(text: String, images: [AgentImageAttachment]) async throws {
		sendCallCount += 1
		onSend()
	}

	func cancelCurrentTurn() async {}
	func shutdown() async {}
	func respondToServerRequest(id: CodexAppServerRequestID, result: [String: Any]) async {}
}
