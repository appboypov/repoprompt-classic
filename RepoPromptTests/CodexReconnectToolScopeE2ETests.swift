import XCTest
@testable import RepoPrompt

@MainActor
final class CodexReconnectToolScopeE2ETests: XCTestCase {
	private static let leaseRoutingTimeoutMs = 10_000

	override func setUp() async throws {
		try await super.setUp()
		try requireCodexE2EEnabled()
		try await requireCodexRuntimePrerequisites()
	}

	func testReconnectChurnWithCachedPolicyAndStaleRunMappingReinstallsPolicyAndKeepsGatedToolsVisible() async throws {
		let runID = UUID()
		let policyHistory = PolicyInstallHistory()
		let toolHistory = ToolCompletionHistory()
		let tracker = AgentToolTracker()
		let harness = try await makeHarness(runID: runID, policyHistory: policyHistory)

		do {
			try Task.checkCancellation()
			await startToolTracking(
				tracker: tracker,
				runID: runID,
				clientNameHint: harness.codexClientName,
				toolHistory: toolHistory
			)

			await harness.viewModel.startAgentRun(
				tabID: harness.tabID,
				initialMessage: "Call set_status exactly once with {\"session_name\":\"bootstrap\"}, then reply with exactly 'ready'."
			)

			let firstToolObserved = await waitForCondition(timeoutSeconds: 120) {
				await toolHistory.completionCount(for: "set_status") >= 1
			}
			XCTAssertTrue(firstToolObserved, "Expected initial run to complete set_status")
			let initialTurnCompleted = await waitForCondition(timeoutSeconds: 90) {
				!harness.session.runState.isActive
			}
			XCTAssertTrue(initialTurnCompleted, "Expected initial run to complete before churn")
			let hasCachedPolicyAfterInitial = await ServerNetworkManager.shared.hasCachedRunPolicyState(for: runID)
			XCTAssertTrue(hasCachedPolicyAfterInitial, "Expected cached run policy state after initial turn")
			let initialPolicyCount = await policyHistory.count(for: runID)
			XCTAssertGreaterThanOrEqual(initialPolicyCount, 1)

			let initialRouted = await waitForCondition(timeoutSeconds: 90) {
				harness.windowState.mcpServer.hasLiveRunID(runID)
			}
			XCTAssertTrue(initialRouted, "Expected run to be live-routed before churn")
			guard let oldConnectionID = harness.windowState.mcpServer.liveConnectionID(forRunID: runID) else {
				XCTFail("Expected live connection for initial run")
				return
			}

			await ServerNetworkManager.shared.debugClearPersistedRoutingState(for: harness.codexClientName)
			await ServerNetworkManager.shared.debugRemoveConnection(oldConnectionID)

			let staleMappingObserved = await waitForCondition(timeoutSeconds: 30) {
				!harness.windowState.mcpServer.hasRunID(runID)
					&& !harness.windowState.mcpServer.hasLiveRunID(runID)
			}
			XCTAssertTrue(staleMappingObserved, "Expected live and historical run mappings to clear after churn")
			XCTAssertFalse(harness.windowState.mcpServer.hasRunID(runID))
			XCTAssertFalse(harness.windowState.mcpServer.hasLiveRunID(runID))
			let hasCachedPolicyBeforeReconnect = await ServerNetworkManager.shared.hasCachedRunPolicyState(for: runID)
			XCTAssertTrue(hasCachedPolicyBeforeReconnect, "Cached run policy should still exist before reconnect")

			await ServerNetworkManager.shared.debugClearPersistedRoutingState(for: harness.codexClientName)
			let staleStateStillPresent = await waitForCondition(timeoutSeconds: 20) {
				!harness.windowState.mcpServer.hasRunID(runID)
					&& !harness.windowState.mcpServer.hasLiveRunID(runID)
			}
			XCTAssertTrue(staleStateStillPresent, "Expected no stale mapping immediately before reconnect run")

			harness.session.codexNeedsReconnect = true
			await harness.viewModel.startAgentRun(
				tabID: harness.tabID,
				initialMessage: "Call set_status exactly once with {\"session_name\":\"ping\"}, then reply with exactly 'done'."
			)

			let policyReinstalled = await waitForCondition(timeoutSeconds: 120) {
				await policyHistory.count(for: runID) >= (initialPolicyCount + 1)
			}
			XCTAssertTrue(policyReinstalled, "Expected reconnect to reinstall run policy")

			let setStatusCompleted = await waitForCondition(timeoutSeconds: 120) {
				await toolHistory.completionCount(for: "set_status") >= 2
			}
			XCTAssertTrue(setStatusCompleted, "Expected policy-gated set_status tool completion after reconnect")
			let reconnectTurnCompleted = await waitForCondition(timeoutSeconds: 90) {
				!harness.session.runState.isActive
			}
			XCTAssertTrue(reconnectTurnCompleted, "Expected reconnect run to complete")
			let setStatusHasNoErrors = await toolHistory.allErrorsAreFalse(for: "set_status")
			XCTAssertTrue(setStatusHasNoErrors, "Expected set_status completions to be non-error")

			let rerouted = await waitForCondition(timeoutSeconds: 90) {
				if let newConnectionID = harness.windowState.mcpServer.liveConnectionID(forRunID: runID) {
					return newConnectionID != oldConnectionID
				}
				return false
			}
			XCTAssertTrue(rerouted, "Expected reconnect to establish a new live connection")
			guard let newConnectionID = harness.windowState.mcpServer.liveConnectionID(forRunID: runID) else {
				XCTFail("Expected live connection ID after reconnect")
				return
			}
			XCTAssertNotEqual(newConnectionID, oldConnectionID)

			let matchingCalls = await policyHistory.calls(for: runID)
			XCTAssertGreaterThanOrEqual(matchingCalls.count, 2)
			guard let latestCall = matchingCalls.last else {
				XCTFail("Expected a latest policy reinstall call")
				return
			}
			let latestAdditionalTools = latestCall.additionalTools ?? []
			XCTAssertTrue(latestAdditionalTools.isSuperset(of: AgentModeMCPToolPolicy.codexNativeGrantedTools))
			XCTAssertTrue(latestAdditionalTools.contains("set_status"))
			XCTAssertEqual(latestCall.purpose, .agentModeRun)
			XCTAssertTrue(latestCall.oneShot)

			let effective = await ServerNetworkManager.shared.debugEffectivePolicyState(for: newConnectionID)
			XCTAssertTrue(effective.additionalTools.isSuperset(of: AgentModeMCPToolPolicy.codexNativeGrantedTools))
			XCTAssertTrue(effective.additionalTools.contains("set_status"))
			XCTAssertEqual(effective.purpose, .agentModeRun)
		} catch {
			await teardownHarness(harness, runID: runID, tracker: tracker)
			throw error
		}

		await teardownHarness(harness, runID: runID, tracker: tracker)
	}

	func testReconnectAfterRepeatedConnectionChurnStillReinstallsPolicy() async throws {
		let runID = UUID()
		let policyHistory = PolicyInstallHistory()
		let toolHistory = ToolCompletionHistory()
		let tracker = AgentToolTracker()
		let harness = try await makeHarness(runID: runID, policyHistory: policyHistory)

		do {
			try Task.checkCancellation()
			await startToolTracking(
				tracker: tracker,
				runID: runID,
				clientNameHint: harness.codexClientName,
				toolHistory: toolHistory
			)

			await harness.viewModel.startAgentRun(
				tabID: harness.tabID,
				initialMessage: "Call set_status exactly once with {\"session_name\":\"bootstrap\"}, then reply with exactly 'ready'."
			)
			let initialToolObserved = await waitForCondition(timeoutSeconds: 120) {
				await toolHistory.completionCount(for: "set_status") >= 1
			}
			XCTAssertTrue(initialToolObserved, "Expected initial run to establish tool routing")
			let initialTurnCompleted = await waitForCondition(timeoutSeconds: 90) {
				!harness.session.runState.isActive
			}
			XCTAssertTrue(initialTurnCompleted, "Expected initial run to complete before churn cycles")
			let initialPolicyCount = await policyHistory.count(for: runID)
			XCTAssertGreaterThanOrEqual(initialPolicyCount, 1)

			for cycle in 1...2 {
				let routed = await waitForCondition(timeoutSeconds: 90) {
					harness.windowState.mcpServer.hasLiveRunID(runID)
				}
				XCTAssertTrue(routed, "Expected live routing before churn cycle \(cycle)")
				guard let oldConnectionID = harness.windowState.mcpServer.liveConnectionID(forRunID: runID) else {
					XCTFail("Expected live connection ID before churn cycle \(cycle)")
					return
				}

				await ServerNetworkManager.shared.debugClearPersistedRoutingState(for: harness.codexClientName)
				await ServerNetworkManager.shared.debugRemoveConnection(oldConnectionID)

				let staleMappingObserved = await waitForCondition(timeoutSeconds: 30) {
					!harness.windowState.mcpServer.hasRunID(runID)
						&& !harness.windowState.mcpServer.hasLiveRunID(runID)
				}
				XCTAssertTrue(staleMappingObserved, "Expected live and historical mappings to clear during cycle \(cycle)")
				let hasCachedPolicyForCycle = await ServerNetworkManager.shared.hasCachedRunPolicyState(for: runID)
				XCTAssertTrue(hasCachedPolicyForCycle, "Expected cached policy to survive churn cycle \(cycle)")

				await ServerNetworkManager.shared.debugClearPersistedRoutingState(for: harness.codexClientName)
				let staleStateStillPresent = await waitForCondition(timeoutSeconds: 20) {
					!harness.windowState.mcpServer.hasRunID(runID)
						&& !harness.windowState.mcpServer.hasLiveRunID(runID)
				}
				XCTAssertTrue(staleStateStillPresent, "Expected no stale mapping immediately before reconnect cycle \(cycle)")

				harness.session.codexNeedsReconnect = true
				await harness.viewModel.startAgentRun(
					tabID: harness.tabID,
					initialMessage: "Call set_status exactly once with {\"session_name\":\"ping-\(cycle)\"}, then reply with exactly 'done'."
				)

				let expectedPolicyCount = initialPolicyCount + cycle
				let policyCountReached = await waitForCondition(timeoutSeconds: 120) {
					await policyHistory.count(for: runID) >= expectedPolicyCount
				}
				XCTAssertTrue(policyCountReached, "Expected policy reinstall on reconnect cycle \(cycle)")

				let setStatusCountReached = await waitForCondition(timeoutSeconds: 120) {
					await toolHistory.completionCount(for: "set_status") >= (cycle + 1)
				}
				XCTAssertTrue(setStatusCountReached, "Expected set_status completion on reconnect cycle \(cycle)")
				let reconnectTurnCompleted = await waitForCondition(timeoutSeconds: 90) {
					!harness.session.runState.isActive
				}
				XCTAssertTrue(reconnectTurnCompleted, "Expected reconnect cycle \(cycle) run to complete")

				let reconnected = await waitForCondition(timeoutSeconds: 90) {
					if let newConnectionID = harness.windowState.mcpServer.liveConnectionID(forRunID: runID) {
						return newConnectionID != oldConnectionID
					}
					return false
				}
				XCTAssertTrue(reconnected, "Expected new live connection after cycle \(cycle)")
				guard let newConnectionID = harness.windowState.mcpServer.liveConnectionID(forRunID: runID) else {
					XCTFail("Expected live connection after reconnect cycle \(cycle)")
					return
				}
				let effective = await ServerNetworkManager.shared.debugEffectivePolicyState(for: newConnectionID)
				XCTAssertTrue(effective.additionalTools.isSuperset(of: AgentModeMCPToolPolicy.codexNativeGrantedTools))
				XCTAssertTrue(effective.additionalTools.contains("set_status"))
				XCTAssertEqual(effective.purpose, .agentModeRun)
			}

			let totalPolicyCount = await policyHistory.count(for: runID)
			let totalSetStatusCount = await toolHistory.completionCount(for: "set_status")
			let setStatusErrorsAreAllFalse = await toolHistory.allErrorsAreFalse(for: "set_status")
			XCTAssertGreaterThanOrEqual(totalPolicyCount, initialPolicyCount + 2)
			XCTAssertGreaterThanOrEqual(totalSetStatusCount, 3)
			XCTAssertTrue(setStatusErrorsAreAllFalse, "Expected all reconnect set_status completions to be non-error")
		} catch {
			await teardownHarness(harness, runID: runID, tracker: tracker)
			throw error
		}

		await teardownHarness(harness, runID: runID, tracker: tracker)
	}

	func testToolsListIncludesPolicyGatedToolsOnlyWhenAdditionalToolsPresent_onCodexConnection() async throws {
		try XCTSkipIf(
			ToolAvailabilityStore.shared.disabledTools.contains("set_status"),
			"set_status is disabled in ToolAvailabilityStore; enable it for this E2E visibility test"
		)

		let runID = UUID()
		let policyHistory = PolicyInstallHistory()
		let toolHistory = ToolCompletionHistory()
		let tracker = AgentToolTracker()
		let harness = try await makeHarness(runID: runID, policyHistory: policyHistory)

		do {
			try Task.checkCancellation()
			await startToolTracking(
				tracker: tracker,
				runID: runID,
				clientNameHint: harness.codexClientName,
				toolHistory: toolHistory
			)

			await harness.viewModel.startAgentRun(
				tabID: harness.tabID,
				initialMessage: "Call set_status exactly once with {\"session_name\":\"tool-list-baseline\"}, then reply with exactly 'ready'."
			)

			let baselineToolObserved = await waitForCondition(timeoutSeconds: 120) {
				await toolHistory.completionCount(for: "set_status") >= 1
			}
			XCTAssertTrue(baselineToolObserved, "Expected baseline set_status completion")
			let baselineTurnCompleted = await waitForCondition(timeoutSeconds: 90) {
				!harness.session.runState.isActive
			}
			XCTAssertTrue(baselineTurnCompleted, "Expected baseline run to complete before tool-list assertions")

			let routed = await waitForCondition(timeoutSeconds: 90) {
				harness.windowState.mcpServer.hasLiveRunID(runID)
			}
			XCTAssertTrue(routed, "Expected live routing for tool-list visibility assertions")
			guard let connectionID = harness.windowState.mcpServer.liveConnectionID(forRunID: runID) else {
				XCTFail("Expected a live connection for tool-list visibility assertions")
				return
			}

			let effectiveBefore = await ServerNetworkManager.shared.debugEffectivePolicyState(for: connectionID)
			XCTAssertTrue(effectiveBefore.additionalTools.contains("set_status"))

			let namesWithAdditional = try await ServerNetworkManager.shared.debugListToolNames(
				for: connectionID,
				hydratePersistedPolicy: false
			)
			XCTAssertTrue(namesWithAdditional.contains("set_status"), "Expected set_status to be visible when additional tools are present")

			await ServerNetworkManager.shared.debugClearPersistedRoutingState(for: harness.codexClientName)
			await ServerNetworkManager.shared.debugSetAdditionalTools(for: connectionID, additionalTools: nil)
			let hiddenWithoutAdditional = await waitForCondition(timeoutSeconds: 30) {
				do {
					let names = try await ServerNetworkManager.shared.debugListToolNames(
						for: connectionID,
						hydratePersistedPolicy: false
					)
					return !names.contains("set_status")
				} catch {
					return false
				}
			}
			XCTAssertTrue(hiddenWithoutAdditional, "Expected policy-gated set_status to be hidden when additional tools are removed")
			let namesWithoutAdditional = try await ServerNetworkManager.shared.debugListToolNames(
				for: connectionID,
				hydratePersistedPolicy: false
			)
			XCTAssertFalse(namesWithoutAdditional.contains("set_status"))
			XCTAssertFalse(namesWithoutAdditional.isEmpty, "Expected non-gated tools to remain visible after removing additionalTools")

			await ServerNetworkManager.shared.debugSetAdditionalTools(
				for: connectionID,
				additionalTools: AgentModeMCPToolPolicy.codexNativeGrantedTools
			)
			let restoredWithAdditional = await waitForCondition(timeoutSeconds: 30) {
				do {
					let names = try await ServerNetworkManager.shared.debugListToolNames(
						for: connectionID,
						hydratePersistedPolicy: false
					)
					return names.contains("set_status")
				} catch {
					return false
				}
			}
			XCTAssertTrue(restoredWithAdditional, "Expected set_status visibility to return when additional tools are restored")
		} catch {
			await teardownHarness(harness, runID: runID, tracker: tracker)
			throw error
		}

		await teardownHarness(harness, runID: runID, tracker: tracker)
	}

	private func requireCodexE2EEnabled() throws {
		try XCTSkipUnless(
			ProcessInfo.processInfo.environment["RUN_CODEX_E2E"] == "1",
			"Expensive Codex E2E tests are opt-in (set RUN_CODEX_E2E=1)"
		)
	}

	private func requireCodexRuntimePrerequisites() async throws {
		do {
			let probeClient = CodexAppServerClient()
			let probe = CodexNativeSessionController(
				client: probeClient,
				runID: UUID(),
				tabID: UUID(),
				windowID: -1,
				workspacePath: FileManager.default.currentDirectoryPath,
				forceExperimentalSteering: true,
				clientShutdownBehavior: .stopOnShutdown
			)
			do {
				_ = try await probe.startOrResume(
					existing: nil,
					baseInstructions: "You are a concise assistant."
				)
				await probe.shutdown()
			} catch {
				await probe.shutdown()
				throw error
			}
		} catch {
			throw XCTSkip("Codex runtime prerequisites unavailable: \(error.localizedDescription)")
		}
	}

	private func makeHarness(
		runID: UUID,
		policyHistory: PolicyInstallHistory
	) async throws -> CodexE2EHarness {
		let codexClientName = DiscoverAgentKind.codexExec.mcpClientNameHint ?? "codex-mcp-client"
		let windowState = WindowState()
		WindowStatesManager.shared.registerWindowState(windowState)

		do {
			await windowState.mcpServer.startServer()

			let toolsEnabled = await waitForCondition(timeoutSeconds: 30) {
				windowState.mcpServer.windowToolsEnabled
			}
			guard toolsEnabled else {
				throw XCTSkip("Unable to enable MCP server for Codex E2E harness")
			}

			let workspaceReady = await waitForCondition(timeoutSeconds: 30) {
				windowState.workspaceManager.isInitialized
					&& windowState.workspaceManager.activeWorkspace != nil
			}
			guard workspaceReady else {
				throw XCTSkip("Workspace initialization did not complete for Codex E2E harness")
			}

			if windowState.promptManager.activeComposeTabID == nil {
				_ = await windowState.promptManager.ensureActiveComposeTab(nil)
			}
			guard let tabID = windowState.promptManager.activeComposeTabID
				?? windowState.promptManager.currentComposeTabs.first?.id
			else {
				throw XCTSkip("No active compose tab available for Codex E2E harness")
			}

			await ServerNetworkManager.shared.debugClearPersistedRoutingState(for: codexClientName)
			await ServerNetworkManager.shared.clearClientConnectionPolicy(
				for: codexClientName,
				windowID: windowState.windowID
			)
			await ServerNetworkManager.shared.cleanupRunRoutingState(for: runID, windowID: windowState.windowID)

			let mcpServer = windowState.mcpServer
			let viewModel = AgentModeViewModel(
				testWindowID: windowState.windowID,
				testWorkspacePath: FileManager.default.currentDirectoryPath,
				shouldManageCodexTooling: true,
				codexControllerFactory: { runID, tabID, windowID, workspacePath, _, _ in
					let client = CodexAppServerClient()
					return CodexNativeSessionController(
						client: client,
						runID: runID,
						tabID: tabID,
						windowID: windowID,
						workspacePath: workspacePath,
						forceExperimentalSteering: true,
						clientShutdownBehavior: .stopOnShutdown
					)
				},
				connectionPolicyInstaller: { clientName, windowID, restrictedTools, oneShot, reason, ttl, tabID, runID, additionalTools, purpose, _, _, _ in
					await policyHistory.record(
						CodexPolicyInstallCall(
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
						purpose: purpose
					)
				},
				mcpServerEnabler: { [weak mcpServer] in
					guard let mcpServer, !mcpServer.windowToolsEnabled else { return }
					await mcpServer.startServer()
				},
				testMCPServer: mcpServer,
				testCodexLeaseRoutingTimeoutMs: Self.leaseRoutingTimeoutMs
			)

			let session = await viewModel.ensureSessionReady(tabID: tabID)
			session.selectedAgent = DiscoverAgentKind.codexExec
			session.runID = runID

			return CodexE2EHarness(
				codexClientName: codexClientName,
				windowState: windowState,
				viewModel: viewModel,
				tabID: tabID,
				session: session
			)
		} catch {
			await windowState.mcpServer.stopServer()
			WindowStatesManager.shared.unregisterWindowState(windowState)
			throw error
		}
	}

	private func startToolTracking(
		tracker: AgentToolTracker,
		runID: UUID,
		clientNameHint: String,
		toolHistory: ToolCompletionHistory
	) async {
		await tracker.startEnhanced(
			runID: runID,
			clientNameHint: clientNameHint,
			connectionTimeoutSeconds: 1.0,
			fallbackTimeoutSeconds: 1.0,
			keepObserversOnTimeout: true,
			onCalled: { _, _, _ in },
			onCompleted: { invocationID, toolName, _, _, isError in
				let normalizedName = Self.normalizedRepoPromptToolName(toolName)
				Task {
					await toolHistory.recordCompletion(
						invocationID: invocationID,
						toolName: normalizedName,
						isError: isError
					)
				}
			}
		)
	}

	private func teardownHarness(
		_ harness: CodexE2EHarness,
		runID: UUID,
		tracker: AgentToolTracker
	) async {
		await tracker.stop()
		if let controller = harness.session.codexController {
			await controller.shutdown()
		}
		await harness.windowState.mcpServer.stopServer()
		await ServerNetworkManager.shared.clearClientConnectionPolicy(
			for: harness.codexClientName,
			windowID: harness.windowState.windowID
		)
		await ServerNetworkManager.shared.cleanupRunRoutingState(
			for: runID,
			windowID: harness.windowState.windowID
		)
		await ServerNetworkManager.shared.debugClearPersistedRoutingState(for: harness.codexClientName)
		WindowStatesManager.shared.unregisterWindowState(harness.windowState)
	}

	private func waitForCondition(
		timeoutSeconds: TimeInterval,
		pollIntervalNanos: UInt64 = 100_000_000,
		condition: @escaping @MainActor () async -> Bool
	) async -> Bool {
		let deadline = Date().addingTimeInterval(timeoutSeconds)
		while Date() < deadline {
			if await condition() {
				return true
			}
			try? await Task.sleep(nanoseconds: pollIntervalNanos)
		}
		return await condition()
	}

	nonisolated private static func normalizedRepoPromptToolName(_ toolName: String) -> String {
		MCPIntegrationHelper.normalizedRepoPromptToolName(toolName)
	}
}

private struct CodexE2EHarness {
	let codexClientName: String
	let windowState: WindowState
	let viewModel: AgentModeViewModel
	let tabID: UUID
	let session: AgentModeViewModel.TabSession
}

private actor PolicyInstallHistory {
	private var calls: [CodexPolicyInstallCall] = []

	func record(_ call: CodexPolicyInstallCall) {
		calls.append(call)
	}

	func calls(for runID: UUID) -> [CodexPolicyInstallCall] {
		calls.filter { $0.runID == runID }
	}

	func count(for runID: UUID) -> Int {
		calls(for: runID).count
	}
}

private actor ToolCompletionHistory {
	private var seenInvocations: Set<UUID> = []
	private var completionsByTool: [String: Int] = [:]
	private var errorsByTool: [String: [Bool]] = [:]

	func recordCompletion(invocationID: UUID, toolName: String, isError: Bool) {
		guard !seenInvocations.contains(invocationID) else { return }
		seenInvocations.insert(invocationID)
		completionsByTool[toolName, default: 0] += 1
		errorsByTool[toolName, default: []].append(isError)
	}

	func completionCount(for toolName: String) -> Int {
		completionsByTool[toolName, default: 0]
	}

	func allErrorsAreFalse(for toolName: String) -> Bool {
		errorsByTool[toolName, default: []].allSatisfy { !$0 }
	}
}

private struct CodexPolicyInstallCall {
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
