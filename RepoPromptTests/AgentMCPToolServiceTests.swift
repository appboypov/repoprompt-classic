import Foundation
import XCTest
import MCP
@testable import RepoPrompt

@MainActor
final class AgentMCPToolServiceTests: XCTestCase {
	private enum PreservedSecurePayload {
		case absent
		case value(String)
		case unavailable
	}

	override func tearDown() {
		CodexGoalSupport.setEnabledForTesting(nil)
		CodexComputerUseWorkflow.setEnabledForTesting(nil)
		super.tearDown()
	}

	private func withPreservedCompatibleBackendState(_ body: () async throws -> Void) async rethrows {
		let defaults = UserDefaults.standard
		let store = ClaudeCodeCompatibleBackendStore.shared
		let previousConfigData = defaults.object(forKey: ClaudeCodeCompatibleBackendStore.configsDefaultsKey)
		let previousConfiguredValues = Dictionary(uniqueKeysWithValues: ClaudeCodeCompatibleBackendID.allCases.map {
			($0, defaults.object(forKey: store.configuredDefaultsKey(for: $0)))
		})
		defer {
			if let previousConfigData {
				defaults.set(previousConfigData, forKey: ClaudeCodeCompatibleBackendStore.configsDefaultsKey)
			} else {
				defaults.removeObject(forKey: ClaudeCodeCompatibleBackendStore.configsDefaultsKey)
			}
			for id in ClaudeCodeCompatibleBackendID.allCases {
				let key = store.configuredDefaultsKey(for: id)
				if let value = previousConfiguredValues[id] {
					defaults.set(value, forKey: key)
				} else {
					defaults.removeObject(forKey: key)
				}
			}
		}
		try await body()
	}

	private func withPreservedUserDefault<T>(_ key: String, body: () async throws -> T) async rethrows -> T {
		let defaults = UserDefaults.standard
		let previousValue = defaults.object(forKey: key)
		defer {
			if let previousValue {
				defaults.set(previousValue, forKey: key)
			} else {
				defaults.removeObject(forKey: key)
			}
		}
		return try await body()
	}

	private func preserveSubagentPermissionPreferences() -> () -> Void {
		let defaults = UserDefaults.standard
		let legacyKey = AgentModePermissionPreferences.forceSafeSubagentPermissionsKey
		let policyKey = AgentModePermissionPreferences.subagentPermissionPolicyKey
		let hadLegacy = defaults.object(forKey: legacyKey) != nil
		let previousLegacy = defaults.bool(forKey: legacyKey)
		let previousPolicy = defaults.string(forKey: policyKey)
		let secureKeys = SecureKeysService()
		let secureKey = AgentPermissionSecureDomain.subagent.storageKey
		let previousSecurePayload: PreservedSecurePayload
		do {
			if let payload = try secureKeys.getIntegrityProtectedValue(for: secureKey) {
				previousSecurePayload = .value(payload)
			} else {
				previousSecurePayload = .absent
			}
		} catch {
			previousSecurePayload = .unavailable
		}
		let store = AgentPermissionSecureStore.shared
		store.clearCachedDocuments()
		return {
			switch previousSecurePayload {
			case .value(let payload):
				try? secureKeys.saveIntegrityProtectedValue(payload, for: secureKey)
			case .absent:
				try? secureKeys.deleteIntegrityProtectedValue(for: secureKey)
			case .unavailable:
				break
			}
			store.clearCachedDocuments()
			if hadLegacy {
				defaults.set(previousLegacy, forKey: legacyKey)
			} else {
				defaults.removeObject(forKey: legacyKey)
			}
			if let previousPolicy {
				defaults.set(previousPolicy, forKey: policyKey)
			} else {
				defaults.removeObject(forKey: policyKey)
			}
		}
	}

	func testOracleMarkdownUsesMinimalPlanFormat() {
		let markdown = AgentOracleExport.oracleMarkdown(
			request: OracleExportRequest(
				sourceTool: "ask_oracle",
				mode: "plan",
				message: "Original task text",
				chatID: "new-chat-8352D7",
				response: "- First step\n- Second step"
			),
			exportedAt: Date(timeIntervalSince1970: 0)
		)

		XCTAssertEqual(markdown, "# Oracle Plan\n\n- First step\n- Second step")
		XCTAssertFalse(markdown.contains("RepoPrompt Oracle Export"))
		XCTAssertFalse(markdown.contains("Provenance"))
		XCTAssertFalse(markdown.contains("Original message"))
		XCTAssertFalse(markdown.contains("Original task text"))
		XCTAssertFalse(markdown.contains("new-chat-8352D7"))
	}

	func testOracleMarkdownUsesReviewTitle() {
		let markdown = AgentOracleExport.oracleMarkdown(
			request: OracleExportRequest(
				sourceTool: "ask_oracle",
				mode: "review",
				message: "Review this",
				chatID: nil,
				response: "Looks good."
			)
		)

		XCTAssertEqual(markdown, "# Oracle Review\n\nLooks good.")
	}

	func testOracleExportRequestCarriesDestinationMetadata() {
		let workspaceID = UUID()
		let tabID = UUID()
		let destination = OracleExportDestination(
			workspaceID: workspaceID,
			windowID: 9,
			tabID: tabID,
			primaryRootPath: "/tmp/xcodetester"
		)
		let request = OracleExportRequest(
			sourceTool: "oracle_send",
			mode: "plan",
			message: "Plan this",
			chatID: "chat-123",
			response: "Plan text",
			destination: destination
		)

		XCTAssertEqual(request.destination, destination)
		XCTAssertEqual(request.destination?.workspaceID, workspaceID)
		XCTAssertEqual(request.destination?.windowID, 9)
		XCTAssertEqual(request.destination?.tabID, tabID)
		XCTAssertEqual(request.destination?.primaryRootPath, "/tmp/xcodetester")
	}

	func testOracleExportInstructionCanUseAbsolutePath() {
		let path = "/tmp/xcodetester/prompt-exports/oracle-plan.md"
		let instruction = AgentOracleExport.instruction(path: path)

		XCTAssertTrue(instruction.contains(path))
		XCTAssertTrue(instruction.contains("read_file"))
	}

	func testAgentRunStartCreatesTopLevelSessionFromSourceTab() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }

		let agentModeVM = windowState.agentModeViewModel
		agentModeVM.ensureSession(for: sourceTabID)
		guard let sourceSessionID = agentModeVM.sessions[sourceTabID]?.activeAgentSessionID else {
			return XCTFail("Expected bound source session")
		}
		let metadata = MCPServerViewModel.RequestMetadata(
			connectionID: UUID(),
			clientName: "test-client",
			windowID: windowState.windowID
		)
		var observedParentSessionID: UUID?
		let service = AgentRunMCPToolService(
			toolName: "agent_run",
			captureRequestMetadata: { metadata },
			requireTargetWindow: { windowState },
			resolveRequestedTabID: { _ in nil },
			resolveSpawnSourceTabID: { _ in sourceTabID },
			resolveSpawnParentSessionID: { _, _ in nil },
			bindCurrentRequestToTab: { _, _ in },
			withHeartbeat: { _, _, _, _, operation in try await operation() },
			startRun: { target, _, _, _, agentModeVM, agentRaw, modelRaw, reasoningEffortRaw, _, _ in
				observedParentSessionID = agentModeVM.session(for: target.tabID, createIfNeeded: false)?.parentSessionID
				guard let sessionID = target.sessionID else {
					throw MCPError.internalError("Expected session ID")
				}
				return .init(
					snapshot: self.makeSnapshot(
						sessionID: sessionID,
						tabID: target.tabID,
						agentRaw: agentRaw,
						modelRaw: modelRaw,
						reasoningEffortRaw: reasoningEffortRaw,
						status: .completed
					),
					delivery: .startedRun
				)
			}
		)

		let value = try await service.execute(args: [
			"op": .string("start"),
			"message": .string("Spawn a child run")
		])
		let object = try XCTUnwrap(value.objectValue)

		let spawnedSessions = agentModeVM.sessions.values.filter {
			$0.tabID != sourceTabID
		}
		XCTAssertNil(observedParentSessionID)
		XCTAssertEqual(spawnedSessions.count, 1)
		XCTAssertEqual(object["session_id"]?.stringValue, spawnedSessions.first?.activeAgentSessionID?.uuidString)
		XCTAssertNotEqual(object["session_id"]?.stringValue, sourceSessionID.uuidString)
		XCTAssertNil(spawnedSessions.first?.parentSessionID)
	}

	func testAgentRunStartFromMCPSourceAppliesCustomSubagentPermissionProfile() async throws {
		let restorePreference = preserveSubagentPermissionPreferences()
		defer { restorePreference() }
		AgentModePermissionPreferences.setSubagentPermissionPolicy(.custom)
		AgentModePermissionPreferences.setProviderSubagentPermissionLevel(.codex(.fullAccess), for: .codex)

		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }
		windowState.apiSettingsViewModel.isCodexConnected = true

		let agentModeVM = windowState.agentModeViewModel
		agentModeVM.ensureSession(for: sourceTabID)
		let sourceSessionID = try XCTUnwrap(agentModeVM.sessions[sourceTabID]?.activeAgentSessionID)
		let connectionID = UUID()
		let metadata = MCPServerViewModel.RequestMetadata(
			connectionID: connectionID,
			clientName: "test-agent-client",
			windowID: windowState.windowID
		)
		await agentModeVM.mcpActivateControlContext(
			forTabID: sourceTabID,
			sessionID: sourceSessionID,
			originatingConnectionID: connectionID,
			taskLabelKind: .engineer
		)

		let service = AgentRunMCPToolService(
			toolName: "agent_run",
			captureRequestMetadata: { metadata },
			requireTargetWindow: { windowState },
			resolveRequestedTabID: { _ in nil },
			resolveSpawnSourceTabID: { _ in sourceTabID },
			resolveSpawnParentSessionID: { _, _ in sourceSessionID },
			bindCurrentRequestToTab: { _, _ in },
			withHeartbeat: { _, _, _, _, operation in try await operation() },
			startRun: { target, _, metadata, bindCurrentRequestToTab, agentModeVM, agentRaw, modelRaw, reasoningEffortRaw, taskLabelKind, _ in
				let sessionID = try XCTUnwrap(target.sessionID)
				await agentModeVM.mcpActivateControlContext(
					forTabID: target.tabID,
					sessionID: sessionID,
					originatingConnectionID: metadata.connectionID,
					taskLabelKind: taskLabelKind,
					startPending: false
				)
				try await agentModeVM.mcpConfigureSession(
					tabID: target.tabID,
					agentRaw: agentRaw,
					modelRaw: modelRaw,
					reasoningEffortRaw: reasoningEffortRaw
				)
				try await bindCurrentRequestToTab(target.tabID, metadata)
				return .init(
					snapshot: self.makeSnapshot(sessionID: sessionID, tabID: target.tabID, status: .completed),
					delivery: .startedRun
				)
			}
		)

		let value = try await service.execute(args: [
			"op": .string("start"),
			"message": .string("Spawn a child run"),
			"model_id": .string("\(DiscoverAgentKind.codexExec.rawValue):gpt-5.4")
		])
		let object = try XCTUnwrap(value.objectValue)
		let childSessionID = try XCTUnwrap(object["session_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
		let childSession = try XCTUnwrap(agentModeVM.sessions.values.first { $0.activeAgentSessionID == childSessionID })

		XCTAssertEqual(childSession.parentSessionID, sourceSessionID)
		XCTAssertNotNil(childSession.mcpControlContext)
		XCTAssertEqual(childSession.permissionProfile, .providerOverride(.codex(.fullAccess)))

		await agentModeVM.mcpDeactivateControlContext(sessionID: sourceSessionID)
		await agentModeVM.mcpDeactivateControlContext(sessionID: childSessionID)
		await AgentRunSessionStore.cleanup(sessionID: sourceSessionID)
		await AgentRunSessionStore.cleanup(sessionID: childSessionID)
	}

	func testAgentRunStartMCPChildShowsOptimisticUserMessageOnImmediateTabActivation() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }

		let agentModeVM = windowState.agentModeViewModel
		agentModeVM.ensureSession(for: sourceTabID)
		agentModeVM.setAgentModeActive(true)
		let sourceSessionID = try XCTUnwrap(agentModeVM.sessions[sourceTabID]?.activeAgentSessionID)
		let connectionID = UUID()
		let metadata = MCPServerViewModel.RequestMetadata(
			connectionID: connectionID,
			clientName: "test-agent-client",
			windowID: windowState.windowID
		)
		await agentModeVM.mcpActivateControlContext(
			forTabID: sourceTabID,
			sessionID: sourceSessionID,
			originatingConnectionID: connectionID,
			taskLabelKind: .engineer
		)

		var boundChildTabID: UUID?
		let service = AgentRunMCPToolService(
			toolName: "agent_run",
			captureRequestMetadata: { metadata },
			requireTargetWindow: { windowState },
			resolveRequestedTabID: { _ in nil },
			resolveSpawnSourceTabID: { _ in sourceTabID },
			resolveSpawnParentSessionID: { _, _ in sourceSessionID },
			bindCurrentRequestToTab: { tabID, _ in boundChildTabID = tabID },
			withHeartbeat: { _, _, _, _, operation in try await operation() },
			startRun: { target, message, metadata, bindCurrentRequestToTab, agentModeVM, agentRaw, modelRaw, reasoningEffortRaw, taskLabelKind, _ in
				let sessionID = try XCTUnwrap(target.sessionID)
				await agentModeVM.mcpActivateControlContext(
					forTabID: target.tabID,
					sessionID: sessionID,
					originatingConnectionID: metadata.connectionID,
					taskLabelKind: taskLabelKind,
					startPending: true
				)
				try await agentModeVM.mcpConfigureSession(
					tabID: target.tabID,
					agentRaw: agentRaw,
					modelRaw: modelRaw,
					reasoningEffortRaw: reasoningEffortRaw
				)
				try await bindCurrentRequestToTab(target.tabID, metadata)
				let session = try XCTUnwrap(agentModeVM.sessions[target.tabID])
				session.appendItem(.user(message, sequenceIndex: session.nextSequenceIndex))
				session.runState = .running
				return .init(
					snapshot: self.makeSnapshot(sessionID: sessionID, tabID: target.tabID, status: .running),
					delivery: .startedRun
				)
			}
		)

		let value = try await service.execute(args: [
			"op": .string("start"),
			"message": .string("Investigate child task"),
			"detach": .bool(true)
		])
		let object = try XCTUnwrap(value.objectValue)
		let childSessionID = try XCTUnwrap(object["session_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
		let childTabID = try XCTUnwrap(boundChildTabID)
		let childSession = try XCTUnwrap(agentModeVM.sessions[childTabID])

		await windowState.promptManager.switchComposeTab(childTabID)
		await Task.yield()

		XCTAssertEqual(agentModeVM.activeTranscriptPresentation.tabID, childTabID)
		XCTAssertTrue(agentModeVM.activeSessionBindingsAreHydrated)
		XCTAssertEqual(agentModeVM.activeTranscriptPresentation.visibleRows.map(\.kind), [.user])
		XCTAssertEqual(agentModeVM.activeTranscriptPresentation.workingRows.map(\.kind), [.user])
		XCTAssertEqual(agentModeVM.activeTranscriptPresentation.visibleRows.first?.text, "Investigate child task")
		XCTAssertEqual(agentModeVM.activeTranscriptPresentation.workingRows.first?.text, "Investigate child task")
		XCTAssertEqual(childSession.parentSessionID, sourceSessionID)
		XCTAssertEqual(childSession.activeAgentSessionID, childSessionID)
		XCTAssertNotNil(childSession.mcpControlContext)

		await agentModeVM.mcpDeactivateControlContext(sessionID: sourceSessionID)
		await agentModeVM.mcpDeactivateControlContext(sessionID: childSessionID)
		await AgentRunSessionStore.cleanup(sessionID: sourceSessionID)
		await AgentRunSessionStore.cleanup(sessionID: childSessionID)
	}

	func testAgentRunStartFromBoundAgentConnectionDoesNotRebindToSpawnedChildren() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }

		let agentModeVM = windowState.agentModeViewModel
		agentModeVM.ensureSession(for: sourceTabID)
		let sourceSessionID = try XCTUnwrap(agentModeVM.sessions[sourceTabID]?.activeAgentSessionID)
		let connectionID = UUID()
		let clientName = "test-agent-client"
		let sourceRunID = UUID()
		let metadata = MCPServerViewModel.RequestMetadata(
			connectionID: connectionID,
			clientName: clientName,
			windowID: windowState.windowID
		)
		await ServerNetworkManager.shared.setRunPurpose(.agentModeRun, for: connectionID)
		await agentModeVM.mcpActivateControlContext(
			forTabID: sourceTabID,
			sessionID: sourceSessionID,
			originatingConnectionID: connectionID,
			taskLabelKind: .engineer
		)
		let sourceSnapshot = try XCTUnwrap(windowState.workspaceManager.composeTab(with: sourceTabID))
		windowState.mcpServer.installTabContext(
			clientID: connectionID.uuidString,
			clientName: clientName,
			windowID: windowState.windowID,
			snapshot: sourceSnapshot,
			runID: sourceRunID
		)

		func startChild() async throws -> (sessionID: UUID, tabID: UUID) {
			let resolvedSourceTabID = await windowState.mcpServer.resolveSpawnSourceTabIDForAgentSessionCreation(metadata: metadata)
			try agentModeVM.mcpValidateAgentRunSpawnAllowed(sourceTabID: resolvedSourceTabID)
			let parentSessionID = await windowState.mcpServer.resolveSpawnParentSessionID(metadata: metadata, targetWindow: windowState)
			let target = try await agentModeVM.mcpResolveOrCreateSessionTarget(
				tabID: nil,
				sessionID: nil,
				createIfNeeded: true,
				sessionName: nil,
				parentSessionID: parentSessionID
			)
			let sessionID = try XCTUnwrap(target.sessionID)
			await agentModeVM.mcpActivateControlContext(
				forTabID: target.tabID,
				sessionID: sessionID,
				originatingConnectionID: metadata.connectionID,
				taskLabelKind: .engineer
			)
			try await windowState.mcpServer.bindCurrentRequestToTabIfPossible(tabID: target.tabID, metadata: metadata)
			await AgentRunSessionStore.noteSnapshot(makeSnapshot(sessionID: sessionID, tabID: target.tabID, status: .completed))
			return (sessionID, target.tabID)
		}

		let first = try await startChild()
		let firstSessionID = first.sessionID
		let firstChild = try XCTUnwrap(agentModeVM.sessions.values.first { $0.activeAgentSessionID == firstSessionID })
		let bindingAfterFirst = windowState.mcpServer.connectionBindingSnapshot(forConnection: connectionID)

		XCTAssertEqual(firstChild.parentSessionID, sourceSessionID)
		XCTAssertEqual(bindingAfterFirst.tabID, sourceTabID)
		XCTAssertEqual(bindingAfterFirst.runID, sourceRunID)
		XCTAssertFalse(bindingAfterFirst.explicitlyBound)

		let second = try await startChild()
		let secondSessionID = second.sessionID
		let secondChild = try XCTUnwrap(agentModeVM.sessions.values.first { $0.activeAgentSessionID == secondSessionID })
		let bindingAfterSecond = windowState.mcpServer.connectionBindingSnapshot(forConnection: connectionID)
		let spawnedSessions = agentModeVM.sessions.values.filter { $0.tabID != sourceTabID }

		XCTAssertEqual(spawnedSessions.count, 2)
		XCTAssertEqual(secondChild.parentSessionID, sourceSessionID)
		XCTAssertNotEqual(secondChild.parentSessionID, firstSessionID)
		XCTAssertEqual(bindingAfterSecond.tabID, sourceTabID)
		XCTAssertEqual(bindingAfterSecond.runID, sourceRunID)
		XCTAssertFalse(bindingAfterSecond.explicitlyBound)

		await agentModeVM.mcpDeactivateControlContext(sessionID: sourceSessionID)
		await AgentRunSessionStore.cleanup(sessionID: sourceSessionID)
		await AgentRunSessionStore.cleanup(sessionID: firstSessionID)
		await AgentRunSessionStore.cleanup(sessionID: secondSessionID)
		await ServerNetworkManager.shared.setRunPurpose(.unknown, for: connectionID)
	}

	func testResolveSpawnSourceTabIDRehydratesAgentModeContextFromCachedRunPolicy() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		let windowManager = WindowStatesManager.shared
		let originalWindows = windowManager.allWindows
		windowManager.allWindows = [windowState]
		defer {
			windowManager.allWindows = originalWindows
			Task { await windowState.tearDown() }
		}

		let agentModeVM = windowState.agentModeViewModel
		agentModeVM.ensureSession(for: sourceTabID)
		let sourceSessionID = try XCTUnwrap(agentModeVM.sessions[sourceTabID]?.activeAgentSessionID)
		let workspaceID = try XCTUnwrap(windowState.workspaceManager.activeWorkspace?.id)
		let connectionID = UUID()
		let runID = UUID()
		let metadata = MCPServerViewModel.RequestMetadata(
			connectionID: connectionID,
			clientName: "test-agent-client",
			windowID: windowState.windowID
		)

		await ServerNetworkManager.shared.debugSeedRunPolicyState(
			runID: runID,
			windowID: windowState.windowID,
			workspaceID: workspaceID,
			tabID: sourceTabID,
			restrictedTools: [],
			additionalTools: ["agent_run"],
			purpose: .agentModeRun
		)
		await ServerNetworkManager.shared.debugSeedConnectionRunRouting(
			connectionID: connectionID,
			runID: runID,
			purpose: .unknown,
			windowID: windowState.windowID
		)

		XCTAssertNil(windowState.mcpServer.connectionBindingSnapshot(forConnection: connectionID).tabID)

		let resolvedSourceTabID = await windowState.mcpServer.resolveSpawnSourceTabIDForAgentSessionCreation(metadata: metadata)
		let binding = windowState.mcpServer.connectionBindingSnapshot(forConnection: connectionID)
		let parentSessionID = await windowState.mcpServer.resolveSpawnParentSessionID(metadata: metadata, targetWindow: windowState)

		XCTAssertEqual(resolvedSourceTabID, sourceTabID)
		XCTAssertEqual(binding.tabID, sourceTabID)
		XCTAssertEqual(binding.runID, runID)
		XCTAssertFalse(binding.explicitlyBound)
		XCTAssertEqual(parentSessionID, sourceSessionID)

		await ServerNetworkManager.shared.cleanupRunRoutingState(for: runID, windowID: windowState.windowID)
		await ServerNetworkManager.shared.setRunPurpose(.unknown, for: connectionID)
	}

	func testRunScopedBindRemovesStaleForwardRunMappingWhenRebindingConnection() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }

		let connectionID = UUID()
		let clientName = "test-agent-client"
		let workspaceID = try XCTUnwrap(windowState.workspaceManager.activeWorkspace?.id)
		let firstRunID = UUID()
		let secondRunID = UUID()

		try windowState.mcpServer.bindTabForConnection(
			connectionID: connectionID,
			clientName: clientName,
			tabID: sourceTabID,
			workspaceID: workspaceID,
			windowID: windowState.windowID,
			runID: firstRunID,
			explicitlyBound: false
		)
		XCTAssertEqual(windowState.mcpServer.connectionIDs(forRunID: firstRunID), [connectionID])

		try windowState.mcpServer.bindTabForConnection(
			connectionID: connectionID,
			clientName: clientName,
			tabID: sourceTabID,
			workspaceID: workspaceID,
			windowID: windowState.windowID,
			runID: secondRunID,
			explicitlyBound: false
		)

		XCTAssertTrue(windowState.mcpServer.connectionIDs(forRunID: firstRunID).isEmpty)
		XCTAssertEqual(windowState.mcpServer.connectionIDs(forRunID: secondRunID), [connectionID])
		XCTAssertEqual(windowState.mcpServer.connectionBindingSnapshot(forConnection: connectionID).runID, secondRunID)
	}

	func testAgentRunStartFromAgentModeConnectionFailsClosedWhenSourceContextMissing() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }

		let connectionID = UUID()
		let metadata = MCPServerViewModel.RequestMetadata(
			connectionID: connectionID,
			clientName: "test-agent-client",
			windowID: windowState.windowID
		)
		await ServerNetworkManager.shared.setRunPurpose(.agentModeRun, for: connectionID)

		var startRunInvoked = false
		let service = AgentRunMCPToolService(
			toolName: "agent_run",
			captureRequestMetadata: { metadata },
			requireTargetWindow: { windowState },
			resolveRequestedTabID: { _ in nil },
			resolveSpawnSourceTabID: { _ in nil },
			validateSpawnRouting: { metadata, sourceTabID in
				try await windowState.mcpServer.validateAgentRunStartRouting(metadata: metadata, resolvedSourceTabID: sourceTabID)
			},
			resolveSpawnParentSessionID: { _, _ in nil },
			bindCurrentRequestToTab: { _, _ in },
			withHeartbeat: { _, _, _, _, operation in try await operation() },
			startRun: { _, _, _, _, _, _, _, _, _, _ in
				startRunInvoked = true
				throw MCPError.internalError("startRun should not be invoked")
			}
		)

		do {
			_ = try await service.execute(args: [
				"op": .string("start"),
				"message": .string("Spawn a child run")
			])
			XCTFail("Expected ambiguous Agent Mode routing to fail closed")
		} catch MCPError.invalidParams(let message) {
			let message = message ?? ""
			XCTAssertTrue(message.contains("could not resolve its run-scoped tab context"))
			XCTAssertTrue(message.contains("Refusing to create an unparented top-level run"))
		} catch {
			XCTFail("Expected MCPError.invalidParams, got \(error)")
		}
		XCTAssertFalse(startRunInvoked)

		await ServerNetworkManager.shared.setRunPurpose(.unknown, for: connectionID)
	}

	func testBindCurrentRequestToTabStillRebindsExternalClient() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }

		let connectionID = UUID()
		let clientName = "external-client"
		let workspaceID = try XCTUnwrap(windowState.workspaceManager.activeWorkspace?.id)
		try windowState.mcpServer.bindTabForConnection(
			connectionID: connectionID,
			clientName: clientName,
			tabID: sourceTabID,
			workspaceID: workspaceID,
			windowID: windowState.windowID
		)
		let target = try await windowState.agentModeViewModel.mcpResolveOrCreateSessionTarget(
			tabID: nil,
			sessionID: nil,
			createIfNeeded: true,
			sessionName: "External target"
		)
		let metadata = MCPServerViewModel.RequestMetadata(
			connectionID: connectionID,
			clientName: clientName,
			windowID: windowState.windowID
		)

		try await windowState.mcpServer.bindCurrentRequestToTabIfPossible(tabID: target.tabID, metadata: metadata)
		let binding = windowState.mcpServer.connectionBindingSnapshot(forConnection: connectionID)

		XCTAssertEqual(binding.tabID, target.tabID)
		XCTAssertTrue(binding.explicitlyBound)
		XCTAssertNil(binding.runID)
	}

	func testAgentExploreStartForcesExploreRoleAndCreatesOwnedChild() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }

		let agentModeVM = windowState.agentModeViewModel
		agentModeVM.ensureSession(for: sourceTabID)
		let sourceSession = try XCTUnwrap(agentModeVM.sessions[sourceTabID])
		let sourceSessionID = try XCTUnwrap(sourceSession.activeAgentSessionID)
		vmApplyParent(agentModeVM, tabID: sourceTabID)
		await agentModeVM.mcpActivateControlContext(
			forTabID: sourceTabID,
			sessionID: sourceSessionID,
			originatingConnectionID: nil,
			taskLabelKind: .engineer
		)

		let metadata = MCPServerViewModel.RequestMetadata(connectionID: UUID(), clientName: "test-client", windowID: windowState.windowID)
		var observedTaskLabelKind: AgentModelCatalog.TaskLabelKind?
		var observedWorkflow: AgentWorkflowDefinition?
		var observedParentSessionID: UUID?
		let service = AgentExploreMCPToolService(
			toolName: "agent_explore",
			captureRequestMetadata: { metadata },
			requireTargetWindow: { windowState },
			resolveSpawnSourceTabID: { _ in sourceTabID },
			resolveSpawnParentSessionID: { _, _ in nil },
			bindCurrentRequestToTab: { _, _ in },
			withHeartbeat: { _, _, _, _, operation in try await operation() },
			startRun: { target, _, _, _, agentModeVM, agentRaw, modelRaw, reasoningEffortRaw, taskLabelKind, workflow in
				observedTaskLabelKind = taskLabelKind
				observedWorkflow = workflow
				observedParentSessionID = agentModeVM.session(for: target.tabID, createIfNeeded: false)?.parentSessionID
				let sessionID = try XCTUnwrap(target.sessionID)
				return .init(
					snapshot: self.makeSnapshot(
						sessionID: sessionID,
						tabID: target.tabID,
						agentRaw: agentRaw,
						modelRaw: modelRaw,
						reasoningEffortRaw: reasoningEffortRaw,
						status: .completed
					),
					delivery: .startedRun
				)
			}
		)

		let value = try await service.execute(args: [
			"op": .string("start"),
			"message": .string("Map the codebase")
		])
		let object = try XCTUnwrap(value.objectValue)
		let spawned = agentModeVM.sessions.values.first { $0.tabID != sourceTabID }

		XCTAssertEqual(observedTaskLabelKind, .explore)
		XCTAssertNil(observedWorkflow)
		XCTAssertEqual(observedParentSessionID, sourceSessionID)
		XCTAssertEqual(spawned?.parentSessionID, sourceSessionID)
		XCTAssertEqual(object["session_id"]?.stringValue, spawned?.activeAgentSessionID?.uuidString)
		await agentModeVM.mcpDeactivateControlContext(sessionID: sourceSessionID)
		await AgentRunSessionStore.cleanup(sessionID: sourceSessionID)
	}

	func testAgentExploreStartRejectsUnsupportedModelWorkflowAndSessionFields() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let windowState = makeWindowState(root: tempRoot, sourceTabID: UUID())
		defer { Task { await windowState.tearDown() } }
		let service = makeAgentExploreService(windowState: windowState, sourceTabID: nil)
		for key in ["model_id", "workflow_name", "session_name", "session_id", "session_ids", "tab_id", "wait", "timeout_seconds", "oracle_export_path"] {
			await XCTAssertThrowsErrorAsync(try await service.execute(args: [
				"op": .string("start"),
				"message": .string("Map the codebase"),
				key: .string("unsupported")
			])) { error in
				guard case MCPError.invalidParams(let message) = error else {
					return XCTFail("Expected invalidParams error, got \(error)")
				}
				XCTAssertTrue((message ?? "").contains("does not support '\(key)'"))
			}
		}
	}

	func testAgentExploreBatchStartDetachedLaunchesMultipleOwnedExploreChildren() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }
		let agentModeVM = windowState.agentModeViewModel
		let sourceSessionID = try await activateMCPSource(windowState: windowState, tabID: sourceTabID, taskLabelKind: .engineer)
		var observedMessages: [String] = []
		var observedTaskLabels: [AgentModelCatalog.TaskLabelKind?] = []
		let service = makeAgentExploreService(windowState: windowState, sourceTabID: sourceTabID) { target, message, _, _, agentModeVM, _, _, _, taskLabelKind, workflow in
			XCTAssertNil(workflow)
			observedMessages.append(message)
			observedTaskLabels.append(taskLabelKind)
			let sessionID = try XCTUnwrap(target.sessionID)
			await agentModeVM.mcpActivateControlContext(
				forTabID: target.tabID,
				sessionID: sessionID,
				originatingConnectionID: nil,
				taskLabelKind: taskLabelKind
			)
			agentModeVM.sessions[target.tabID]?.runState = .running
			let snapshot = self.makeSnapshot(sessionID: sessionID, tabID: target.tabID, status: .running)
			await AgentRunSessionStore.register(sessionID: sessionID)
			await AgentRunSessionStore.noteSnapshot(snapshot)
			return .init(snapshot: snapshot, delivery: .startedRun)
		}

		let requestedMessages = ["Map service files", "Inspect tests", "Review prompts"]
		let value = try await service.execute(args: [
			"op": .string("start"),
			"messages": .array(requestedMessages.map { .string($0) }),
			"detach": .bool(true)
		])
		let object = try XCTUnwrap(value.objectValue)
		let start = try XCTUnwrap(object["start"]?.objectValue)
		let sessionIDs = object["session_ids"]?.arrayValue?.compactMap { $0.stringValue } ?? []
		let snapshots = object["snapshots"]?.arrayValue ?? []
		let spawned = agentModeVM.sessions.values.filter { $0.tabID != sourceTabID }

		XCTAssertEqual(start["mode"]?.stringValue, "many")
		XCTAssertEqual(start["result"]?.stringValue, "detached")
		XCTAssertEqual(start["started_count"]?.intValue, 3)
		XCTAssertEqual(sessionIDs.count, 3)
		XCTAssertEqual(snapshots.count, 3)
		XCTAssertEqual(observedTaskLabels, [.explore, .explore, .explore])
		XCTAssertEqual(observedMessages, requestedMessages)
		XCTAssertEqual(spawned.count, 3)
		XCTAssertTrue(spawned.allSatisfy { $0.parentSessionID == sourceSessionID })
		XCTAssertTrue(spawned.allSatisfy { $0.mcpControlContext?.taskLabelKind == .explore })

		await agentModeVM.mcpDeactivateControlContext(sessionID: sourceSessionID)
		await AgentRunSessionStore.cleanup(sessionID: sourceSessionID)
		for sessionID in sessionIDs.compactMap(UUID.init(uuidString:)) {
			await AgentRunSessionStore.cleanup(sessionID: sessionID)
		}
	}

	func testAgentExploreBatchStartRejectsMixedOrInvalidMessages() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let windowState = makeWindowState(root: tempRoot, sourceTabID: UUID())
		defer { Task { await windowState.tearDown() } }
		let service = makeAgentExploreService(windowState: windowState, sourceTabID: nil)

		let cases: [([String: Value], String)] = [
			([
				"op": .string("start"),
				"message": .string("single"),
				"messages": .array([.string("batch")])
			], "not both"),
			([
				"op": .string("start"),
				"messages": .array([])
			], "non-empty array"),
			([
				"op": .string("start"),
				"messages": .array([.string("ok"), .string("   ")])
			], "messages[1]"),
			([
				"op": .string("start")
			], "message or messages is required")
		]

		for (args, expectedMessage) in cases {
			await XCTAssertThrowsErrorAsync(try await service.execute(args: args)) { error in
				guard case MCPError.invalidParams(let message) = error else {
					return XCTFail("Expected invalidParams error, got \(error)")
				}
				XCTAssertTrue((message ?? "").contains(expectedMessage))
			}
		}
	}

	func testAgentExploreBatchStartWaitsWithCanonicalMultiWaitShape() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }
		let agentModeVM = windowState.agentModeViewModel
		let sourceSessionID = try await activateMCPSource(windowState: windowState, tabID: sourceTabID, taskLabelKind: .pair)
		var startedSessionIDs: [UUID] = []
		let service = makeAgentExploreService(windowState: windowState, sourceTabID: sourceTabID) { target, _, _, _, agentModeVM, _, _, _, taskLabelKind, _ in
			let sessionID = try XCTUnwrap(target.sessionID)
			startedSessionIDs.append(sessionID)
			await agentModeVM.mcpActivateControlContext(
				forTabID: target.tabID,
				sessionID: sessionID,
				originatingConnectionID: nil,
				taskLabelKind: taskLabelKind
			)
			let status: AgentRunMCPSnapshot.Status = startedSessionIDs.count == 2 ? .completed : .running
			agentModeVM.sessions[target.tabID]?.runState = status == .completed ? .completed : .running
			let snapshot = self.makeSnapshot(sessionID: sessionID, tabID: target.tabID, status: status)
			await AgentRunSessionStore.register(sessionID: sessionID)
			await AgentRunSessionStore.noteSnapshot(snapshot)
			return .init(snapshot: self.makeSnapshot(sessionID: sessionID, tabID: target.tabID, status: .running), delivery: .startedRun)
		}

		let value = try await service.execute(args: [
			"op": .string("start"),
			"messages": .array([.string("First probe"), .string("Second probe")]),
			"timeout": .double(30)
		])
		let object = try XCTUnwrap(value.objectValue)
		let wait = try XCTUnwrap(object["wait"]?.objectValue)
		let winnerID = try XCTUnwrap(startedSessionIDs.last)

		XCTAssertEqual(wait["mode"]?.stringValue, "any")
		XCTAssertEqual(wait["result"]?.stringValue, "snapshot_ready")
		XCTAssertEqual(wait["winner_session_id"]?.stringValue, winnerID.uuidString)
		XCTAssertEqual(wait["session_ids"]?.arrayValue?.compactMap { $0.stringValue }, startedSessionIDs.map(\.uuidString))
		XCTAssertEqual(object["session_id"]?.stringValue, winnerID.uuidString)
		XCTAssertNil(object["start"])

		await agentModeVM.mcpDeactivateControlContext(sessionID: sourceSessionID)
		await AgentRunSessionStore.cleanup(sessionID: sourceSessionID)
		for sessionID in startedSessionIDs {
			await AgentRunSessionStore.cleanup(sessionID: sessionID)
		}
	}

	func testAgentExploreWaitManyReturnsFirstInterestingOwnedExploreChild() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }
		let agentModeVM = windowState.agentModeViewModel
		let sourceSessionID = try await activateMCPSource(windowState: windowState, tabID: sourceTabID, taskLabelKind: .engineer)
		let first = try await createMCPChild(windowState: windowState, parentSessionID: sourceSessionID, taskLabelKind: .explore, runState: .running)
		let second = try await createMCPChild(windowState: windowState, parentSessionID: sourceSessionID, taskLabelKind: .explore, runState: .completed)
		defer {
			Task {
				await AgentRunSessionStore.cleanup(sessionID: first.sessionID)
				await AgentRunSessionStore.cleanup(sessionID: second.sessionID)
			}
		}
		await AgentRunSessionStore.register(sessionID: first.sessionID)
		await AgentRunSessionStore.register(sessionID: second.sessionID)
		await AgentRunSessionStore.noteSnapshot(makeSnapshot(sessionID: first.sessionID, tabID: first.tabID, status: .running))
		await AgentRunSessionStore.noteSnapshot(makeSnapshot(sessionID: second.sessionID, tabID: second.tabID, status: .completed))

		let service = makeAgentExploreService(windowState: windowState, sourceTabID: sourceTabID)
		let value = try await service.execute(args: [
			"op": .string("wait"),
			"session_ids": sessionIDsValue([first.sessionID, second.sessionID]),
			"timeout": .double(30)
		])
		let object = try XCTUnwrap(value.objectValue)
		let wait = try XCTUnwrap(object["wait"]?.objectValue)

		XCTAssertEqual(wait["mode"]?.stringValue, "any")
		XCTAssertEqual(wait["winner_session_id"]?.stringValue, second.sessionID.uuidString)
		XCTAssertEqual(object["session_id"]?.stringValue, second.sessionID.uuidString)
		await agentModeVM.mcpDeactivateControlContext(sessionID: sourceSessionID)
		await AgentRunSessionStore.cleanup(sessionID: sourceSessionID)
	}

	func testAgentExploreRejectsDirectOrExploreCaller() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }

		await XCTAssertThrowsErrorAsync(try await makeAgentExploreService(windowState: windowState, sourceTabID: nil).execute(args: [
			"op": .string("poll"),
			"session_id": .string(UUID().uuidString)
		])) { error in
			guard case MCPError.invalidParams(let message) = error else {
				return XCTFail("Expected invalidParams error, got \(error)")
			}
			XCTAssertTrue((message ?? "").contains("only available from MCP-started Agent Mode sessions"))
		}

		let agentModeVM = windowState.agentModeViewModel
		agentModeVM.ensureSession(for: sourceTabID)
		let sourceSessionID = try XCTUnwrap(agentModeVM.sessions[sourceTabID]?.activeAgentSessionID)
		await agentModeVM.mcpActivateControlContext(
			forTabID: sourceTabID,
			sessionID: sourceSessionID,
			originatingConnectionID: nil,
			taskLabelKind: .explore
		)
		await XCTAssertThrowsErrorAsync(try await makeAgentExploreService(windowState: windowState, sourceTabID: sourceTabID).execute(args: [
			"op": .string("poll"),
			"session_id": .string(UUID().uuidString)
		])) { error in
			guard case MCPError.invalidParams(let message) = error else {
				return XCTFail("Expected invalidParams error, got \(error)")
			}
			XCTAssertEqual(message, "Explore agents cannot start additional explore agents.")
		}
		await agentModeVM.mcpDeactivateControlContext(sessionID: sourceSessionID)
		await AgentRunSessionStore.cleanup(sessionID: sourceSessionID)
	}

	func testAgentExplorePollManyReturnsOwnedExploreChildSnapshots() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }
		let agentModeVM = windowState.agentModeViewModel
		let sourceSessionID = try await activateMCPSource(windowState: windowState, tabID: sourceTabID, taskLabelKind: .engineer)
		let first = try await createMCPChild(windowState: windowState, parentSessionID: sourceSessionID, taskLabelKind: .explore, runState: .running)
		let second = try await createMCPChild(windowState: windowState, parentSessionID: sourceSessionID, taskLabelKind: .explore, runState: .completed)
		defer {
			Task {
				await AgentRunSessionStore.cleanup(sessionID: first.sessionID)
				await AgentRunSessionStore.cleanup(sessionID: second.sessionID)
			}
		}

		let service = makeAgentExploreService(windowState: windowState, sourceTabID: sourceTabID)
		let value = try await service.execute(args: [
			"op": .string("poll"),
			"session_ids": sessionIDsValue([first.sessionID, second.sessionID])
		])
		let object = try XCTUnwrap(value.objectValue)
		let poll = try XCTUnwrap(object["poll"]?.objectValue)
		let snapshots = object["snapshots"]?.arrayValue ?? []

		XCTAssertEqual(poll["mode"]?.stringValue, "many")
		XCTAssertEqual(poll["polled_count"]?.intValue, 2)
		XCTAssertEqual(snapshots.count, 2)
		await agentModeVM.mcpDeactivateControlContext(sessionID: sourceSessionID)
		await AgentRunSessionStore.cleanup(sessionID: sourceSessionID)
	}

	func testAgentExploreCancelRejectsNonExploreOrUnownedChild() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }
		let sourceSessionID = try await activateMCPSource(windowState: windowState, tabID: sourceTabID, taskLabelKind: .engineer)
		let nonExplore = try await createMCPChild(windowState: windowState, parentSessionID: sourceSessionID, taskLabelKind: .pair, runState: .running)
		let unowned = try await createMCPChild(windowState: windowState, parentSessionID: UUID(), taskLabelKind: .explore, runState: .running)
		let service = makeAgentExploreService(windowState: windowState, sourceTabID: sourceTabID)

		for sessionID in [nonExplore.sessionID, unowned.sessionID] {
			await XCTAssertThrowsErrorAsync(try await service.execute(args: [
				"op": .string("cancel"),
				"session_id": .string(sessionID.uuidString)
			])) { error in
				guard case MCPError.invalidParams(let message) = error else {
					return XCTFail("Expected invalidParams error, got \(error)")
				}
				XCTAssertTrue((message ?? "").contains("is not an explore child of the current agent session"))
			}
		}
		await windowState.agentModeViewModel.mcpDeactivateControlContext(sessionID: sourceSessionID)
		await AgentRunSessionStore.cleanup(sessionID: sourceSessionID)
		await AgentRunSessionStore.cleanup(sessionID: nonExplore.sessionID)
		await AgentRunSessionStore.cleanup(sessionID: unowned.sessionID)
	}

	func testAgentRunStartRejectsSystemWorkspace() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID, isSystemWorkspace: true)
		defer { Task { await windowState.tearDown() } }

		let metadata = MCPServerViewModel.RequestMetadata(
			connectionID: UUID(),
			clientName: "test-client",
			windowID: windowState.windowID
		)
		var startRunInvoked = false
		let service = AgentRunMCPToolService(
			toolName: "agent_run",
			captureRequestMetadata: { metadata },
			requireTargetWindow: { windowState },
			resolveRequestedTabID: { _ in nil },
			resolveSpawnSourceTabID: { _ in sourceTabID },
			resolveSpawnParentSessionID: { _, _ in nil },
			bindCurrentRequestToTab: { _, _ in },
			withHeartbeat: { _, _, _, _, operation in try await operation() },
			startRun: { _, _, _, _, _, _, _, _, _, _ in
				startRunInvoked = true
				throw MCPError.internalError("startRun should not be reached")
			}
		)

		await XCTAssertThrowsErrorAsync(try await service.execute(args: [
			"op": .string("start"),
			"message": .string("Spawn a child run")
		])) { error in
			guard case MCPError.invalidParams(let message) = error else {
				return XCTFail("Expected invalidParams error, got \(error)")
			}
			XCTAssertEqual(
				message,
				"Cannot start an agent run from the default system workspace. Open or select a project workspace and try again."
			)
		}
		XCTAssertFalse(startRunInvoked)
	}

	func testAgentRunStartPassesThroughMessageWithEmbeddedPlanPath() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }

		let metadata = MCPServerViewModel.RequestMetadata(
			connectionID: UUID(),
			clientName: "test-client",
			windowID: windowState.windowID
		)
		var observedMessage: String?
		let service = AgentRunMCPToolService(
			toolName: "agent_run",
			captureRequestMetadata: { metadata },
			requireTargetWindow: { windowState },
			resolveRequestedTabID: { _ in nil },
			resolveSpawnSourceTabID: { _ in sourceTabID },
			resolveSpawnParentSessionID: { _, _ in nil },
			bindCurrentRequestToTab: { _, _ in },
			withHeartbeat: { _, _, _, _, operation in try await operation() },
			startRun: { target, message, _, _, _, _, _, _, _, _ in
				observedMessage = message
				guard let sessionID = target.sessionID else {
					throw MCPError.internalError("Expected session ID")
				}
				return .init(
					snapshot: self.makeSnapshot(sessionID: sessionID, tabID: target.tabID, status: .completed),
					delivery: .startedRun
				)
			}
		)

		let requestedMessage = "Read the plan at prompt-exports/2026-04-08-oracle-plan.md with read_file first. Implement the first item."
		_ = try await service.execute(args: [
			"op": .string("start"),
			"message": .string(requestedMessage)
		])

		let message = try XCTUnwrap(observedMessage)
		XCTAssertEqual(message, requestedMessage)
		XCTAssertFalse(message.contains("<oracle_export>"))
	}

	func testAgentRunSteerPassesThroughMessageWithEmbeddedPlanPath() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }

		let agentModeVM = windowState.agentModeViewModel
		agentModeVM.ensureSession(for: sourceTabID)
		let session = try XCTUnwrap(agentModeVM.sessions[sourceTabID])
		let sessionID = try XCTUnwrap(session.activeAgentSessionID)
		session.runState = .completed

		let metadata = MCPServerViewModel.RequestMetadata(
			connectionID: UUID(),
			clientName: "test-client",
			windowID: windowState.windowID
		)
		var observedMessage: String?
		let service = AgentRunMCPToolService(
			toolName: "agent_run",
			captureRequestMetadata: { metadata },
			requireTargetWindow: { windowState },
			resolveRequestedTabID: { _ in nil },
			resolveSpawnSourceTabID: { _ in nil },
			resolveSpawnParentSessionID: { _, _ in nil },
			bindCurrentRequestToTab: { _, _ in },
			withHeartbeat: { _, _, _, _, operation in try await operation() },
			startRun: { target, message, _, _, _, _, _, _, _, _ in
				observedMessage = message
				guard let sessionID = target.sessionID else {
					throw MCPError.internalError("Expected session ID")
				}
				return .init(
					snapshot: self.makeSnapshot(sessionID: sessionID, tabID: target.tabID, status: .running),
					delivery: .startedRun
				)
			}
		)

		let requestedMessage = "Read the plan at prompt-exports/exported-oracle-plan.md with read_file first. Continue with the second item."
		_ = try await service.execute(args: [
			"op": .string("steer"),
			"session_id": .string(sessionID.uuidString),
			"message": .string(requestedMessage)
		])

		let message = try XCTUnwrap(observedMessage)
		XCTAssertEqual(message, requestedMessage)
		XCTAssertFalse(message.contains("<oracle_export>"))
	}

	func testAgentRunStartIgnoresStaleOracleExportPathParam() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }

		let metadata = MCPServerViewModel.RequestMetadata(
			connectionID: UUID(),
			clientName: "test-client",
			windowID: windowState.windowID
		)
		var observedMessage: String?
		let service = AgentRunMCPToolService(
			toolName: "agent_run",
			captureRequestMetadata: { metadata },
			requireTargetWindow: { windowState },
			resolveRequestedTabID: { _ in nil },
			resolveSpawnSourceTabID: { _ in sourceTabID },
			resolveSpawnParentSessionID: { _, _ in nil },
			bindCurrentRequestToTab: { _, _ in },
			withHeartbeat: { _, _, _, _, operation in try await operation() },
			startRun: { target, message, _, _, _, _, _, _, _, _ in
				observedMessage = message
				guard let sessionID = target.sessionID else {
					throw MCPError.internalError("Expected session ID")
				}
				return .init(
					snapshot: self.makeSnapshot(sessionID: sessionID, tabID: target.tabID, status: .completed),
					delivery: .startedRun
				)
			}
		)

		let requestedMessage = "Implement the first item"
		_ = try await service.execute(args: [
			"op": .string("start"),
			"message": .string(requestedMessage),
			"oracle_export_path": .null
		])

		let message = try XCTUnwrap(observedMessage)
		XCTAssertEqual(message, requestedMessage)
		XCTAssertFalse(message.contains("<oracle_export>"))
	}

	func testAgentRunSteerIgnoresStaleOracleExportPathParam() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }

		let agentModeVM = windowState.agentModeViewModel
		agentModeVM.ensureSession(for: sourceTabID)
		let session = try XCTUnwrap(agentModeVM.sessions[sourceTabID])
		let sessionID = try XCTUnwrap(session.activeAgentSessionID)
		session.runState = .completed

		let metadata = MCPServerViewModel.RequestMetadata(
			connectionID: UUID(),
			clientName: "test-client",
			windowID: windowState.windowID
		)
		var observedMessage: String?
		let service = AgentRunMCPToolService(
			toolName: "agent_run",
			captureRequestMetadata: { metadata },
			requireTargetWindow: { windowState },
			resolveRequestedTabID: { _ in nil },
			resolveSpawnSourceTabID: { _ in nil },
			resolveSpawnParentSessionID: { _, _ in nil },
			bindCurrentRequestToTab: { _, _ in },
			withHeartbeat: { _, _, _, _, operation in try await operation() },
			startRun: { target, message, _, _, _, _, _, _, _, _ in
				observedMessage = message
				guard let sessionID = target.sessionID else {
					throw MCPError.internalError("Expected session ID")
				}
				return .init(
					snapshot: self.makeSnapshot(sessionID: sessionID, tabID: target.tabID, status: .running),
					delivery: .startedRun
				)
			}
		)

		let requestedMessage = "Continue with the second item"
		_ = try await service.execute(args: [
			"op": .string("steer"),
			"session_id": .string(sessionID.uuidString),
			"message": .string(requestedMessage),
			"oracle_export_path": .string("prompt-exports/exported-oracle-plan.md")
		])

		let message = try XCTUnwrap(observedMessage)
		XCTAssertEqual(message, requestedMessage)
		XCTAssertFalse(message.contains("<oracle_export>"))
	}

	func testAgentRunStartWaitsByDefaultAndReturnsCompletedStatus() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }

		let metadata = MCPServerViewModel.RequestMetadata(
			connectionID: UUID(),
			clientName: "test-client",
			windowID: windowState.windowID
		)
		var heartbeatInvoked = false
		let service = AgentRunMCPToolService(
			toolName: "agent_run",
			captureRequestMetadata: { metadata },
			requireTargetWindow: { windowState },
			resolveRequestedTabID: { _ in nil },
			resolveSpawnSourceTabID: { _ in sourceTabID },
			resolveSpawnParentSessionID: { _, _ in nil },
			bindCurrentRequestToTab: { _, _ in },
			withHeartbeat: { _, _, _, _, operation in
				heartbeatInvoked = true
				return try await operation()
			},
			startRun: { target, _, _, _, _, _, _, _, _, _ in
				guard let sessionID = target.sessionID else {
					throw MCPError.internalError("Expected session ID")
				}
				let running = self.makeSnapshot(sessionID: sessionID, tabID: target.tabID, status: .running)
				let completed = self.makeSnapshot(sessionID: sessionID, tabID: target.tabID, status: .completed)
				await AgentRunSessionStore.register(sessionID: sessionID)
				await AgentRunSessionStore.noteSnapshot(completed)
				return .init(snapshot: running, delivery: .startedRun)
			}
		)

		let value = try await service.execute(args: [
			"op": .string("start"),
			"message": .string("Run to completion")
		])
		let object = try XCTUnwrap(value.objectValue)

		XCTAssertTrue(heartbeatInvoked)
		XCTAssertEqual(object["status"]?.stringValue, AgentRunMCPSnapshot.Status.completed.rawValue)
		XCTAssertNil(object["run_state"])
	}

	func testAgentRunWaitReturnsImmediatelyWhenSessionSettlesBackToIdle() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }

		let agentModeVM = windowState.agentModeViewModel
		agentModeVM.ensureSession(for: sourceTabID)
		let session = await agentModeVM.ensureSessionReady(tabID: sourceTabID)
		guard let sessionID = session.activeAgentSessionID else {
			return XCTFail("Expected active session ID")
		}
		await agentModeVM.mcpActivateControlContext(
			forTabID: sourceTabID,
			sessionID: sessionID,
			originatingConnectionID: nil
		)
		session.runState = .idle

		let metadata = MCPServerViewModel.RequestMetadata(
			connectionID: UUID(),
			clientName: "test-client",
			windowID: windowState.windowID
		)
		var heartbeatInvoked = false
		let service = AgentRunMCPToolService(
			toolName: "agent_run",
			captureRequestMetadata: { metadata },
			requireTargetWindow: { windowState },
			resolveRequestedTabID: { _ in nil },
			resolveSpawnSourceTabID: { _ in nil },
			resolveSpawnParentSessionID: { _, _ in nil },
			bindCurrentRequestToTab: { _, _ in },
			withHeartbeat: { _, _, _, _, operation in
				heartbeatInvoked = true
				return try await operation()
			},
			startRun: { _, _, _, _, _, _, _, _, _, _ in
				throw MCPError.internalError("startRun should not be used for wait")
			}
		)

		let value = try await service.execute(args: [
			"op": .string("wait"),
			"session_id": .string(sessionID.uuidString),
			"timeout": .double(30)
		])

		XCTAssertFalse(heartbeatInvoked)
		let object = try XCTUnwrap(value.objectValue)
		XCTAssertEqual(object["status"]?.stringValue, AgentRunMCPSnapshot.Status.completed.rawValue)
		XCTAssertNil(object["run_state"])

		await agentModeVM.mcpDeactivateControlContext(sessionID: sessionID)
		await AgentRunSessionStore.cleanup(sessionID: sessionID)
	}

	func testAgentRunSteerContinuesCompletedSessionUsingReturnedSessionID() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }

		let agentModeVM = windowState.agentModeViewModel
		agentModeVM.ensureSession(for: sourceTabID)
		let session = try XCTUnwrap(agentModeVM.sessions[sourceTabID])
		let sessionID = try XCTUnwrap(session.activeAgentSessionID)
		session.runState = .completed

		let metadata = MCPServerViewModel.RequestMetadata(
			connectionID: UUID(),
			clientName: "test-client",
			windowID: windowState.windowID
		)
		var observedTargetTabID: UUID?
		var observedTargetSessionID: UUID?
		let service = AgentRunMCPToolService(
			toolName: "agent_run",
			captureRequestMetadata: { metadata },
			requireTargetWindow: { windowState },
			resolveRequestedTabID: { _ in nil },
			resolveSpawnSourceTabID: { _ in nil },
			resolveSpawnParentSessionID: { _, _ in nil },
			bindCurrentRequestToTab: { _, _ in },
			withHeartbeat: { _, _, _, _, operation in try await operation() },
			startRun: { target, _, _, _, _, _, _, _, _, _ in
				observedTargetTabID = target.tabID
				observedTargetSessionID = target.sessionID
				guard let sessionID = target.sessionID else {
					throw MCPError.internalError("Expected session ID")
				}
				return .init(
					snapshot: self.makeSnapshot(
						sessionID: sessionID,
						tabID: target.tabID,
						status: .running
					),
					delivery: .startedRun
				)
			}
		)

		let value = try await service.execute(args: [
			"op": .string("steer"),
			"session_id": .string(sessionID.uuidString),
			"message": .string("Continue with a second pass")
		])
		let object = try XCTUnwrap(value.objectValue)

		XCTAssertEqual(observedTargetTabID, sourceTabID)
		XCTAssertEqual(observedTargetSessionID, sessionID)
		XCTAssertEqual(object["session_id"]?.stringValue, sessionID.uuidString)
		XCTAssertEqual(object["status"]?.stringValue, AgentRunMCPSnapshot.Status.running.rawValue)
	}

	func testAgentRunSteerWaitFalseWithTimeoutWarnsAfterAcceptedDispatch() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }

		let agentModeVM = windowState.agentModeViewModel
		agentModeVM.ensureSession(for: sourceTabID)
		let session = try XCTUnwrap(agentModeVM.sessions[sourceTabID])
		let sessionID = try XCTUnwrap(session.activeAgentSessionID)
		session.runState = .completed

		let metadata = MCPServerViewModel.RequestMetadata(
			connectionID: UUID(),
			clientName: "test-client",
			windowID: windowState.windowID
		)
		var observedMessage: String?
		var startRunCount = 0
		let service = AgentRunMCPToolService(
			toolName: "agent_run",
			captureRequestMetadata: { metadata },
			requireTargetWindow: { windowState },
			resolveRequestedTabID: { _ in nil },
			resolveSpawnSourceTabID: { _ in nil },
			resolveSpawnParentSessionID: { _, _ in nil },
			bindCurrentRequestToTab: { _, _ in },
			withHeartbeat: { _, _, _, _, operation in try await operation() },
			startRun: { target, message, _, _, _, _, _, _, _, _ in
				startRunCount += 1
				observedMessage = message
				guard let sessionID = target.sessionID else {
					throw MCPError.internalError("Expected session ID")
				}
				return .init(
					snapshot: self.makeSnapshot(
						sessionID: sessionID,
						tabID: target.tabID,
						status: .running
					),
					delivery: .startedRun
				)
			}
		)

		let value = try await service.execute(args: [
			"op": .string("steer"),
			"session_id": .string(sessionID.uuidString),
			"message": .string("Continue and test performance"),
			"wait": .bool(false),
			"timeout_seconds": .int(0)
		])
		let object = try XCTUnwrap(value.objectValue)

		XCTAssertEqual(startRunCount, 1)
		XCTAssertEqual(observedMessage, "Continue and test performance")
		XCTAssertEqual(object["session_id"]?.stringValue, sessionID.uuidString)
		XCTAssertEqual(object["status"]?.stringValue, AgentRunMCPSnapshot.Status.running.rawValue)
		let warning = try XCTUnwrap(object["warning"]?.stringValue)
		XCTAssertTrue(warning.contains("Ignoring timeout_seconds"))
		XCTAssertTrue(warning.contains("wait=false"))
	}

	func testAgentManageListAgentsUsesCompatibleClaudeBackendRoleMappingsWhenNativeClaudeIsUnavailable() async throws {
		try await withPreservedCompatibleBackendState {
			let tempRoot = makeTempDirectory()
			defer { try? FileManager.default.removeItem(at: tempRoot) }
			let sourceTabID = UUID()
			let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
			defer { Task { await windowState.tearDown() } }

			windowState.apiSettingsViewModel.isClaudeCodeConnected = false
			windowState.apiSettingsViewModel.isCodexConnected = false
			windowState.apiSettingsViewModel.isGeminiConnected = false
			windowState.apiSettingsViewModel.isOpenCodeConnected = false
			windowState.apiSettingsViewModel.isCursorConnected = false

			let glmConfig = ClaudeCodeCompatibleBackendID.glmZAI.defaultPreset
			ClaudeCodeCompatibleBackendStore.shared.saveConfig(glmConfig)
			_ = ClaudeCodeCompatibleBackendStore.shared.setConfigured(true, for: .glmZAI)
			windowState.apiSettingsViewModel.compatibleBackendConfigs[.glmZAI] = glmConfig
			windowState.apiSettingsViewModel.compatibleBackendSecretPresence[.glmZAI] = true

			let metadata = MCPServerViewModel.RequestMetadata(
				connectionID: UUID(),
				clientName: "test-client",
				windowID: windowState.windowID
			)
			let service = AgentManageMCPToolService(
				toolName: "agent_manage",
				captureRequestMetadata: { metadata },
				requireTargetWindow: { windowState },
				resolveSpawnSourceTabID: { _ in nil },
				resolveSpawnParentSessionID: { _, _ in nil },
				bindCurrentRequestToTab: { _, _ in }
			)

			let value = try await service.execute(args: ["op": .string("list_agents")])
			let object = try XCTUnwrap(value.objectValue)
			let agents = object["agents"]?.arrayValue ?? []
			let agentsByName = Dictionary(uniqueKeysWithValues: try agents.map { value -> (String, [String: Value]) in
				let object = try XCTUnwrap(value.objectValue)
				let name = try XCTUnwrap(object["name"]?.stringValue)
				return (name, object)
			})

			let glmAgent = try XCTUnwrap(agentsByName[DiscoverAgentKind.claudeCodeGLM.displayName])
			XCTAssertEqual(glmAgent["available"]?.boolValue, true)
			XCTAssertFalse((glmAgent["models"]?.arrayValue ?? []).isEmpty)

			let nativeClaude = try XCTUnwrap(agentsByName[DiscoverAgentKind.claudeCode.displayName])
			XCTAssertEqual(nativeClaude["available"]?.boolValue, false)
			XCTAssertTrue((nativeClaude["models"]?.arrayValue ?? []).isEmpty)

			let taskLabels = object["task_labels"]?.arrayValue ?? []
			XCTAssertFalse(taskLabels.isEmpty)
			for labelValue in taskLabels {
				let labelObject = try XCTUnwrap(labelValue.objectValue)
				let modelID = try XCTUnwrap(labelObject["model_id"]?.stringValue)
				let recommendedModelID = try XCTUnwrap(labelObject["recommended_model_id"]?.stringValue)
				XCTAssertTrue(modelID.hasPrefix("\(DiscoverAgentKind.claudeCodeGLM.rawValue):"))
				XCTAssertTrue(recommendedModelID.hasPrefix("\(DiscoverAgentKind.claudeCodeGLM.rawValue):"))
			}
		}
	}

	func testAgentManageListAgentsHidesCompatibleClaudeBackendsWhenClaudeCLIIsKnownMissing() async throws {
		try await withPreservedCompatibleBackendState {
			let tempRoot = makeTempDirectory()
			defer { try? FileManager.default.removeItem(at: tempRoot) }
			let sourceTabID = UUID()
			let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
			defer { Task { await windowState.tearDown() } }

			windowState.apiSettingsViewModel.isClaudeCodeConnected = false
			windowState.apiSettingsViewModel.isCodexConnected = false
			windowState.apiSettingsViewModel.isGeminiConnected = false
			windowState.apiSettingsViewModel.isOpenCodeConnected = false
			windowState.apiSettingsViewModel.isCursorConnected = false
			windowState.apiSettingsViewModel.test_setClaudeCodeCLIStatus(
				.binaryMissing(message: "Claude Code CLI isn't installed or isn't on PATH.")
			)

			let glmConfig = ClaudeCodeCompatibleBackendID.glmZAI.defaultPreset
			ClaudeCodeCompatibleBackendStore.shared.saveConfig(glmConfig)
			_ = ClaudeCodeCompatibleBackendStore.shared.setConfigured(true, for: .glmZAI)
			windowState.apiSettingsViewModel.compatibleBackendConfigs[.glmZAI] = glmConfig
			windowState.apiSettingsViewModel.compatibleBackendSecretPresence[.glmZAI] = true

			let metadata = MCPServerViewModel.RequestMetadata(
				connectionID: UUID(),
				clientName: "test-client",
				windowID: windowState.windowID
			)
			let service = AgentManageMCPToolService(
				toolName: "agent_manage",
				captureRequestMetadata: { metadata },
				requireTargetWindow: { windowState },
				resolveSpawnSourceTabID: { _ in nil },
				resolveSpawnParentSessionID: { _, _ in nil },
				bindCurrentRequestToTab: { _, _ in }
			)

			let value = try await service.execute(args: ["op": .string("list_agents")])
			let object = try XCTUnwrap(value.objectValue)
			let agents = object["agents"]?.arrayValue ?? []
			let agentsByName = Dictionary(uniqueKeysWithValues: try agents.map { value -> (String, [String: Value]) in
				let object = try XCTUnwrap(value.objectValue)
				let name = try XCTUnwrap(object["name"]?.stringValue)
				return (name, object)
			})

			let glmAgent = try XCTUnwrap(agentsByName[DiscoverAgentKind.claudeCodeGLM.displayName])
			XCTAssertEqual(glmAgent["available"]?.boolValue, false)
			XCTAssertTrue((glmAgent["models"]?.arrayValue ?? []).isEmpty)
			XCTAssertTrue((object["task_labels"]?.arrayValue ?? []).isEmpty)
		}
	}

	func testLocateOrCreateChatWithTabContextDoesNotReuseGlobalCurrentSessionFromOtherTab() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let otherTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }

		var workspace = try XCTUnwrap(windowState.workspaceManager.activeWorkspace)
		workspace.composeTabs.append(ComposeTabState(id: otherTabID, name: "Other", lastModified: Date()))
		workspace.activeComposeTabID = otherTabID
		windowState.workspaceManager.workspaces = [workspace]
		windowState.workspaceManager.activeWorkspace = workspace
		windowState.promptManager.loadComposeTabsFromWorkspace(workspace)

		let otherSessionID = UUID()
		let otherSession = ChatSession(
			id: otherSessionID,
			workspaceID: workspace.id,
			composeTabID: otherTabID,
			name: "Other Tab Current",
			savedAt: Date(),
			messages: [StoredMessage(isUser: false, rawText: "other", sequenceIndex: 0)]
		)
		windowState.chatViewModel.sessions = [otherSession]
		windowState.chatViewModel.currentSessionID = otherSessionID
		windowState.workspaceManager.setActiveChatSessionID(otherSessionID, forTabID: otherTabID)

		let agentSessionID = UUID()
		let runID = UUID()
		let resolvedID = try await windowState.chatViewModel.locateOrCreateChat(
			nil,
			desiredName: "Oracle",
			tabID: sourceTabID,
			activateInUI: true,
			agentModeSessionID: agentSessionID,
			agentModeRunID: runID
		)

		let resolved = try XCTUnwrap(windowState.chatViewModel.sessions.first(where: { $0.id == resolvedID }))
		XCTAssertNotEqual(resolvedID, otherSessionID)
		XCTAssertEqual(resolved.composeTabID, sourceTabID)
		XCTAssertEqual(resolved.agentModeSessionID, agentSessionID)
		XCTAssertEqual(resolved.agentModeRunID, runID)
		XCTAssertEqual(windowState.workspaceManager.activeChatSessionID(forTabID: otherTabID), otherSessionID)
	}

	func testLocateOrCreateChatWithAgentOwnerPrefersExactOwnedRunOverActiveLegacySession() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }
		let workspace = try XCTUnwrap(windowState.workspaceManager.activeWorkspace)

		let ownerID = UUID()
		let runID = UUID()
		let legacyID = UUID()
		let exactID = UUID()
		let legacy = ChatSession(
			id: legacyID,
			workspaceID: workspace.id,
			composeTabID: sourceTabID,
			name: "Legacy Active",
			savedAt: Date(),
			messages: [StoredMessage(isUser: false, rawText: "legacy", sequenceIndex: 0)]
		)
		let exact = ChatSession(
			id: exactID,
			workspaceID: workspace.id,
			composeTabID: sourceTabID,
			agentModeSessionID: ownerID,
			agentModeRunID: runID,
			name: "Exact Owner",
			savedAt: Date().addingTimeInterval(-120),
			messages: [StoredMessage(isUser: false, rawText: "exact", sequenceIndex: 0)]
		)
		windowState.chatViewModel.sessions = [legacy, exact]
		windowState.chatViewModel.currentSessionID = legacyID
		windowState.workspaceManager.setActiveChatSessionID(legacyID, forTabID: sourceTabID)

		let resolvedID = try await windowState.chatViewModel.locateOrCreateChat(
			nil,
			tabID: sourceTabID,
			activateInUI: true,
			agentModeSessionID: ownerID,
			agentModeRunID: runID
		)

		XCTAssertEqual(resolvedID, exactID)
	}

	func testLocateOrCreateChatWithAgentOwnerPrefersSameAgentLegacyRunOverActiveUnownedLegacy() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }
		let workspace = try XCTUnwrap(windowState.workspaceManager.activeWorkspace)

		let ownerID = UUID()
		let runID = UUID()
		let unownedID = UUID()
		let sameAgentID = UUID()
		let activeUnowned = ChatSession(
			id: unownedID,
			workspaceID: workspace.id,
			composeTabID: sourceTabID,
			name: "Unowned Active",
			savedAt: Date(),
			messages: [StoredMessage(isUser: false, rawText: "unowned", sequenceIndex: 0)]
		)
		let sameAgentLegacyRun = ChatSession(
			id: sameAgentID,
			workspaceID: workspace.id,
			composeTabID: sourceTabID,
			agentModeSessionID: ownerID,
			name: "Same Agent Legacy Run",
			savedAt: Date().addingTimeInterval(-120),
			messages: [StoredMessage(isUser: false, rawText: "same agent", sequenceIndex: 0)]
		)
		windowState.chatViewModel.sessions = [activeUnowned, sameAgentLegacyRun]
		windowState.chatViewModel.currentSessionID = unownedID
		windowState.workspaceManager.setActiveChatSessionID(unownedID, forTabID: sourceTabID)

		let resolvedID = try await windowState.chatViewModel.locateOrCreateChat(
			nil,
			tabID: sourceTabID,
			activateInUI: true,
			agentModeSessionID: ownerID,
			agentModeRunID: runID
		)

		let resolved = try XCTUnwrap(windowState.chatViewModel.sessions.first(where: { $0.id == resolvedID }))
		let unowned = try XCTUnwrap(windowState.chatViewModel.sessions.first(where: { $0.id == unownedID }))
		XCTAssertEqual(resolvedID, sameAgentID)
		XCTAssertEqual(resolved.agentModeSessionID, ownerID)
		XCTAssertEqual(resolved.agentModeRunID, runID)
		XCTAssertNil(unowned.agentModeSessionID)
		XCTAssertNil(unowned.agentModeRunID)
	}

	func testLocateOrCreateChatWithAgentOwnerDoesNotReuseSameTabSessionFromOtherOwner() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }
		let workspace = try XCTUnwrap(windowState.workspaceManager.activeWorkspace)

		let otherOwnerID = UUID()
		let currentOwnerID = UUID()
		let existingID = UUID()
		let existing = ChatSession(
			id: existingID,
			workspaceID: workspace.id,
			composeTabID: sourceTabID,
			agentModeSessionID: otherOwnerID,
			name: "Other Owner",
			savedAt: Date(),
			messages: [StoredMessage(isUser: false, rawText: "other owner", sequenceIndex: 0)]
		)
		windowState.chatViewModel.sessions = [existing]
		windowState.chatViewModel.currentSessionID = existingID
		windowState.workspaceManager.setActiveChatSessionID(existingID, forTabID: sourceTabID)

		let resolvedID = try await windowState.chatViewModel.locateOrCreateChat(
			nil,
			desiredName: "Oracle",
			tabID: sourceTabID,
			activateInUI: true,
			agentModeSessionID: currentOwnerID
		)

		let resolved = try XCTUnwrap(windowState.chatViewModel.sessions.first(where: { $0.id == resolvedID }))
		XCTAssertNotEqual(resolvedID, existingID)
		XCTAssertEqual(resolved.composeTabID, sourceTabID)
		XCTAssertEqual(resolved.agentModeSessionID, currentOwnerID)
	}

	func testOracleChatLogServicePassesAgentOwnerFromTabContext() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }
		let workspace = try XCTUnwrap(windowState.workspaceManager.activeWorkspace)

		let agentModeVM = windowState.agentModeViewModel
		agentModeVM.ensureSession(for: sourceTabID)
		let agentSessionID = try XCTUnwrap(agentModeVM.sessions[sourceTabID]?.activeAgentSessionID)
		let runID = UUID()
		agentModeVM.sessions[sourceTabID]?.runID = runID

		let chatSession = ChatSession(
			workspaceID: workspace.id,
			composeTabID: sourceTabID,
			name: "Oracle",
			savedAt: Date(),
			messages: [StoredMessage(isUser: false, rawText: "answer", sequenceIndex: 0)]
		)
		windowState.chatViewModel.sessions = [chatSession]
		windowState.workspaceManager.setActiveChatSessionID(chatSession.id, forTabID: sourceTabID)

		let connectionID = UUID()
		let context = MCPServerViewModel.TabScopedContext(
			tabID: sourceTabID,
			windowID: windowState.windowID,
			workspaceID: workspace.id,
			promptText: "prompt",
			selection: StoredSelection(),
			selectedMetaPromptIDs: [],
			tabName: "Source",
			runID: runID,
			explicitlyBound: false
		)
		let metadata = MCPServerViewModel.RequestMetadata(connectionID: connectionID, clientName: "oracle-test", windowID: windowState.windowID)
		let service = MCPOracleToolService(
			askOracleToolName: "ask_oracle",
			oracleSendToolName: "oracle_send",
			oracleChatLogToolName: "oracle_chat_log",
			promptVM: windowState.promptManager,
			chatVM: windowState.chatViewModel,
			fileManager: windowState.fileManager,
			captureRequestMetadata: { metadata },
			resolveExecContext: { _ in .virtual(context) },
			requireCurrentTabContext: { _ in context },
			rebindChatSessionIfNeeded: { _, _ in },
			resolveTabIDForAgentMode: { _, _ in sourceTabID },
			requireTargetWindow: { windowState },
			rawExplicitTabID: { _ in nil },
			sendStageProgress: { _, _, _, _ in },
			withHeartbeat: { _, _, _, _, operation in try await operation() },
			exportOracleResponse: { _ in
				OracleExportFile(path: "/tmp/unused", instruction: "unused")
			}
		)

		let value = try await ServerNetworkManager.withConnectionID(connectionID) {
			try await service.executeOracleChatLog(args: [:])
		}
		let object = try XCTUnwrap(value.objectValue)
		XCTAssertEqual(object["context_id"]?.stringValue, sourceTabID.uuidString)
		XCTAssertEqual(object["agent_session_id"]?.stringValue, agentSessionID.uuidString)
		XCTAssertEqual(object["agent_run_id"]?.stringValue, runID.uuidString)
	}

	func testOracleChatLogExplicitTabIgnoresMismatchedCurrentContextRunID() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let explicitTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }

		var workspace = try XCTUnwrap(windowState.workspaceManager.activeWorkspace)
		workspace.composeTabs.append(ComposeTabState(id: explicitTabID, name: "Explicit", lastModified: Date()))
		windowState.workspaceManager.workspaces = [workspace]
		windowState.workspaceManager.activeWorkspace = workspace
		windowState.promptManager.loadComposeTabsFromWorkspace(workspace)

		let agentModeVM = windowState.agentModeViewModel
		agentModeVM.ensureSession(for: sourceTabID)
		agentModeVM.ensureSession(for: explicitTabID)
		let sourceRunID = UUID()
		let explicitRunID = UUID()
		agentModeVM.sessions[sourceTabID]?.runID = sourceRunID
		agentModeVM.sessions[explicitTabID]?.runID = explicitRunID
		let explicitAgentSessionID = try XCTUnwrap(agentModeVM.sessions[explicitTabID]?.activeAgentSessionID)

		let explicitChat = ChatSession(
			workspaceID: workspace.id,
			composeTabID: explicitTabID,
			agentModeSessionID: explicitAgentSessionID,
			agentModeRunID: explicitRunID,
			name: "Explicit Oracle",
			savedAt: Date(),
			messages: [StoredMessage(isUser: false, rawText: "explicit answer", sequenceIndex: 0)]
		)
		windowState.chatViewModel.sessions = [explicitChat]
		windowState.workspaceManager.setActiveChatSessionID(explicitChat.id, forTabID: explicitTabID)

		let connectionID = UUID()
		let sourceContext = MCPServerViewModel.TabScopedContext(
			tabID: sourceTabID,
			windowID: windowState.windowID,
			workspaceID: workspace.id,
			promptText: "source prompt",
			selection: StoredSelection(),
			selectedMetaPromptIDs: [],
			tabName: "Source",
			runID: sourceRunID,
			explicitlyBound: false
		)
		let metadata = MCPServerViewModel.RequestMetadata(connectionID: connectionID, clientName: "oracle-test", windowID: windowState.windowID)
		let service = MCPOracleToolService(
			askOracleToolName: "ask_oracle",
			oracleSendToolName: "oracle_send",
			oracleChatLogToolName: "oracle_chat_log",
			promptVM: windowState.promptManager,
			chatVM: windowState.chatViewModel,
			fileManager: windowState.fileManager,
			captureRequestMetadata: { metadata },
			resolveExecContext: { _ in .virtual(sourceContext) },
			requireCurrentTabContext: { _ in sourceContext },
			rebindChatSessionIfNeeded: { _, _ in },
			resolveTabIDForAgentMode: { _, _ in explicitTabID },
			requireTargetWindow: { windowState },
			rawExplicitTabID: { args in args["_tab_id"]?.stringValue },
			sendStageProgress: { _, _, _, _ in },
			withHeartbeat: { _, _, _, _, operation in try await operation() },
			exportOracleResponse: { _ in
				OracleExportFile(path: "/tmp/unused", instruction: "unused")
			}
		)

		let value = try await ServerNetworkManager.withConnectionID(connectionID) {
			try await service.executeOracleChatLog(args: ["_tab_id": .string(explicitTabID.uuidString)])
		}
		let object = try XCTUnwrap(value.objectValue)
		XCTAssertEqual(object["context_id"]?.stringValue, explicitTabID.uuidString)
		XCTAssertEqual(object["agent_session_id"]?.stringValue, explicitAgentSessionID.uuidString)
		XCTAssertEqual(object["agent_run_id"]?.stringValue, explicitRunID.uuidString)
		XCTAssertNotEqual(object["agent_run_id"]?.stringValue, sourceRunID.uuidString)
	}

	func testToolChatSendUnavailableClaudeFamilyPlanningModelMentionsClaudeCodeConnection() async throws {
		try await withPreservedUserDefault("mcpShowModelPresets") {
			let tempRoot = makeTempDirectory()
			defer { try? FileManager.default.removeItem(at: tempRoot) }
			let sourceTabID = UUID()
			let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
			defer { Task { await windowState.tearDown() } }

			UserDefaults.standard.set(false, forKey: "mcpShowModelPresets")
			windowState.apiSettingsViewModel.isClaudeCodeConnected = false
			windowState.apiSettingsViewModel.compatibleBackendSecretPresence = [:]
			windowState.promptManager.planningModelName = AIModel.claudeCodeSonnet.rawValue

			await XCTAssertThrowsErrorAsync(try await windowState.chatViewModel.tool_chatSend(
				args: [
					"message": .string("Plan this task"),
					"mode": .string("plan")
				],
				promptVM: windowState.promptManager,
				fileMgr: windowState.fileManager
			)) { error in
				guard let chatError = error as? ChatToolError else {
					return XCTFail("Expected ChatToolError, got \(error)")
				}
				XCTAssertEqual(chatError.code, .invalidParams)
				XCTAssertTrue(chatError.message.contains("Connect Claude Code in Settings."))
				XCTAssertFalse(chatError.message.contains("configure an enabled Claude-compatible backend"))
				XCTAssertTrue(chatError.message.contains("MCP oracle model 'Claude Code Sonnet Latest' is not available"))
			}
		}
	}

	func testAgentManageListAgentsUsesTargetWindowProviderAvailability() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }

		windowState.apiSettingsViewModel.isClaudeCodeConnected = true
		windowState.apiSettingsViewModel.isCodexConnected = false
		windowState.apiSettingsViewModel.isGeminiConnected = false
		windowState.apiSettingsViewModel.isOpenCodeConnected = false
		windowState.apiSettingsViewModel.isCursorConnected = false

		let metadata = MCPServerViewModel.RequestMetadata(
			connectionID: UUID(),
			clientName: "test-client",
			windowID: windowState.windowID
		)
		let service = AgentManageMCPToolService(
			toolName: "agent_manage",
			captureRequestMetadata: { metadata },
			requireTargetWindow: { windowState },
			resolveSpawnSourceTabID: { _ in nil },
			resolveSpawnParentSessionID: { _, _ in nil },
			bindCurrentRequestToTab: { _, _ in }
		)

		let value = try await service.execute(args: ["op": .string("list_agents")])
		let object = try XCTUnwrap(value.objectValue)
		let agents = object["agents"]?.arrayValue ?? []
		let agentsByName = Dictionary(uniqueKeysWithValues: try agents.map { value -> (String, [String: Value]) in
			let object = try XCTUnwrap(value.objectValue)
			let name = try XCTUnwrap(object["name"]?.stringValue)
			return (name, object)
		})

		let claude = try XCTUnwrap(agentsByName[DiscoverAgentKind.claudeCode.displayName])
		XCTAssertEqual(claude["available"]?.boolValue, true)
		let claudeModels = claude["models"]?.arrayValue ?? []
		XCTAssertFalse(claudeModels.isEmpty)

		for disconnectedAgent in [DiscoverAgentKind.codexExec, .gemini, .openCode, .cursor] {
			let agent = try XCTUnwrap(agentsByName[disconnectedAgent.displayName])
			XCTAssertEqual(agent["available"]?.boolValue, false, "\(disconnectedAgent.displayName) should reflect target-window disconnected state")
			XCTAssertTrue((agent["models"]?.arrayValue ?? []).isEmpty, "\(disconnectedAgent.displayName) should not expose models while disconnected")
		}

		// Per-agent model entries must not expose suitability/role-like tags;
		// role-label routing lives exclusively in top-level `task_labels`.
		for (agentName, agent) in agentsByName {
			let models = agent["models"]?.arrayValue ?? []
			for modelValue in models {
				let model = try XCTUnwrap(modelValue.objectValue)
				XCTAssertNil(model["tags"], "\(agentName) model entry must not expose `tags`")
			}
		}

		// Explicit compound model_id values should remain discoverable for the
		// connected provider so callers can pin specific agent+model targets.
		let claudeCompoundIDs = claudeModels.compactMap { $0.objectValue?["model_id"]?.stringValue }
		XCTAssertFalse(claudeCompoundIDs.isEmpty, "Connected agent should expose at least one explicit compound model_id")
		XCTAssertTrue(
			claudeCompoundIDs.contains(where: { $0.hasPrefix("\(DiscoverAgentKind.claudeCode.rawValue):") && $0.contains(":") }),
			"Connected agent should surface explicit compound model_ids of the form 'agent:model...'"
		)

		let taskLabels = object["task_labels"]?.arrayValue ?? []
		XCTAssertFalse(taskLabels.isEmpty)
		let labelNames = Set(taskLabels.compactMap { $0.objectValue?["label"]?.stringValue })
		XCTAssertTrue(labelNames.isSuperset(of: ["explore", "engineer", "pair", "design"]),
			"task_labels must expose all four authoritative role labels")
		for labelValue in taskLabels {
			let labelObject = try XCTUnwrap(labelValue.objectValue)
			let modelID = try XCTUnwrap(labelObject["model_id"]?.stringValue)
			let recommendedModelID = try XCTUnwrap(labelObject["recommended_model_id"]?.stringValue)
			XCTAssertTrue(modelID.hasPrefix("\(DiscoverAgentKind.claudeCode.rawValue):"), "Task label should resolve only to connected providers")
			XCTAssertTrue(recommendedModelID.hasPrefix("\(DiscoverAgentKind.claudeCode.rawValue):"), "Recommended label should resolve only to connected providers")
		}
	}

	func testAgentManageListAgentsRolesOnlyOmitsAgentsCatalog() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }

		windowState.apiSettingsViewModel.isClaudeCodeConnected = true
		windowState.apiSettingsViewModel.isCodexConnected = false
		windowState.apiSettingsViewModel.isGeminiConnected = false
		windowState.apiSettingsViewModel.isOpenCodeConnected = false
		windowState.apiSettingsViewModel.isCursorConnected = false

		let metadata = MCPServerViewModel.RequestMetadata(
			connectionID: UUID(),
			clientName: "test-client",
			windowID: windowState.windowID
		)
		let service = AgentManageMCPToolService(
			toolName: "agent_manage",
			captureRequestMetadata: { metadata },
			requireTargetWindow: { windowState },
			resolveSpawnSourceTabID: { _ in nil },
			resolveSpawnParentSessionID: { _, _ in nil },
			bindCurrentRequestToTab: { _, _ in }
		)

		let value = try await service.execute(args: [
			"op": .string("list_agents"),
			"roles_only": .bool(true)
		])
		let object = try XCTUnwrap(value.objectValue)
		XCTAssertNil(object["agents"], "roles_only=true must omit the per-agent catalog")
		let taskLabels = object["task_labels"]?.arrayValue ?? []
		XCTAssertFalse(taskLabels.isEmpty, "task_labels should remain the authoritative role mapping when roles_only=true")
	}

	func testAgentManageListAgentsRestrictedDiscoveryOmitsAgentsAndKeepsRoleModelMappings() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }

		windowState.apiSettingsViewModel.isClaudeCodeConnected = true
		windowState.apiSettingsViewModel.isCodexConnected = false
		windowState.apiSettingsViewModel.isGeminiConnected = false
		windowState.apiSettingsViewModel.isOpenCodeConnected = false
		windowState.apiSettingsViewModel.isCursorConnected = false

		let metadata = MCPServerViewModel.RequestMetadata(
			connectionID: UUID(),
			clientName: "test-client",
			windowID: windowState.windowID
		)
		let service = AgentManageMCPToolService(
			toolName: "agent_manage",
			captureRequestMetadata: { metadata },
			requireTargetWindow: { windowState },
			resolveSpawnSourceTabID: { _ in nil },
			resolveSpawnParentSessionID: { _, _ in nil },
			bindCurrentRequestToTab: { _, _ in },
			restrictDiscoveryToRoleLabels: { true }
		)

		let value = try await service.execute(args: [
			"op": .string("list_agents"),
			"roles_only": .bool(false)
		])
		let object = try XCTUnwrap(value.objectValue)
		XCTAssertNil(object["agents"], "Restricted discovery must omit the per-agent catalog")

		let taskLabels = object["task_labels"]?.arrayValue ?? []
		XCTAssertEqual(taskLabels.count, AgentModelCatalog.TaskLabelKind.allCases.count)
		let expectedLabels = Set(AgentModelCatalog.TaskLabelKind.allCases.map(\.rawValue))
		let actualLabels = Set(taskLabels.compactMap { $0.objectValue?["label"]?.stringValue })
		XCTAssertEqual(actualLabels, expectedLabels)

		for labelValue in taskLabels {
			let labelObject = try XCTUnwrap(labelValue.objectValue)
			let modelID = try XCTUnwrap(labelObject["model_id"]?.stringValue)
			let recommendedModelID = try XCTUnwrap(labelObject["recommended_model_id"]?.stringValue)
			XCTAssertTrue(modelID.hasPrefix("\(DiscoverAgentKind.claudeCode.rawValue):"), "Restricted discovery should still show each role's concrete model mapping")
			XCTAssertTrue(recommendedModelID.hasPrefix("\(DiscoverAgentKind.claudeCode.rawValue):"), "Restricted discovery should still show each role's recommended model mapping")
			XCTAssertTrue(modelID.contains(":"))
			XCTAssertTrue(recommendedModelID.contains(":"))
			XCTAssertNotNil(labelObject["name"]?.stringValue)
			XCTAssertNotNil(labelObject["recommended_name"]?.stringValue)
			XCTAssertNil(labelObject["models"])
		}
	}

	func testAgentManageCreateSessionCreatesTopLevelSessionFromSourceTab() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }

		let agentModeVM = windowState.agentModeViewModel
		agentModeVM.ensureSession(for: sourceTabID)
		guard let sourceSessionID = agentModeVM.sessions[sourceTabID]?.activeAgentSessionID else {
			return XCTFail("Expected bound source session")
		}
		let metadata = MCPServerViewModel.RequestMetadata(
			connectionID: UUID(),
			clientName: "test-client",
			windowID: windowState.windowID
		)
		let service = AgentManageMCPToolService(
			toolName: "agent_manage",
			captureRequestMetadata: { metadata },
			requireTargetWindow: { windowState },
			resolveSpawnSourceTabID: { _ in sourceTabID },
			resolveSpawnParentSessionID: { _, _ in nil },
			bindCurrentRequestToTab: { _, _ in }
		)

		let value = try await service.execute(args: [
			"op": .string("create_session")
		])
		let object = try XCTUnwrap(value.objectValue)
		XCTAssertNil(object["parent_session_id"])

		let spawnedSessions = agentModeVM.sessions.values.filter {
			$0.tabID != sourceTabID
		}
		XCTAssertEqual(spawnedSessions.count, 1)
		XCTAssertEqual(object["session_id"]?.stringValue, spawnedSessions.first?.activeAgentSessionID?.uuidString)
		XCTAssertNotEqual(object["session_id"]?.stringValue, sourceSessionID.uuidString)
		XCTAssertNil(spawnedSessions.first?.parentSessionID)
		XCTAssertEqual(object["is_mcp_originated"]?.boolValue, true)
		if let spawnedSessionID = spawnedSessions.first?.activeAgentSessionID {
			await agentModeVM.mcpDeactivateControlContext(sessionID: spawnedSessionID)
			await AgentRunSessionStore.cleanup(sessionID: spawnedSessionID)
		}
	}

	func testAgentManageCreateSessionFromMCPSourceActivatesControlAndSubagentPermissions() async throws {
		let restorePreference = preserveSubagentPermissionPreferences()
		defer { restorePreference() }
		AgentModePermissionPreferences.setForceSafeSubagentPermissions(false)

		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }
		windowState.apiSettingsViewModel.isCodexConnected = true

		let agentModeVM = windowState.agentModeViewModel
		agentModeVM.ensureSession(for: sourceTabID)
		let sourceSessionID = try XCTUnwrap(agentModeVM.sessions[sourceTabID]?.activeAgentSessionID)
		await agentModeVM.mcpActivateControlContext(
			forTabID: sourceTabID,
			sessionID: sourceSessionID,
			originatingConnectionID: nil,
			taskLabelKind: .engineer
		)

		let metadata = MCPServerViewModel.RequestMetadata(
			connectionID: UUID(),
			clientName: "test-agent-client",
			windowID: windowState.windowID
		)
		let service = AgentManageMCPToolService(
			toolName: "agent_manage",
			captureRequestMetadata: { metadata },
			requireTargetWindow: { windowState },
			resolveSpawnSourceTabID: { _ in sourceTabID },
			resolveSpawnParentSessionID: { _, _ in sourceSessionID },
			bindCurrentRequestToTab: { _, _ in }
		)

		let value = try await service.execute(args: [
			"op": .string("create_session"),
			"model_id": .string("\(DiscoverAgentKind.codexExec.rawValue):gpt-5.4")
		])
		let object = try XCTUnwrap(value.objectValue)
		let childSessionID = try XCTUnwrap(object["session_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
		let childSession = try XCTUnwrap(agentModeVM.sessions.values.first { $0.activeAgentSessionID == childSessionID })

		XCTAssertEqual(object["parent_session_id"]?.stringValue, sourceSessionID.uuidString)
		XCTAssertEqual(object["is_mcp_originated"]?.boolValue, true)
		XCTAssertEqual(childSession.parentSessionID, sourceSessionID)
		XCTAssertTrue(childSession.isMCPOriginated)
		XCTAssertNotNil(childSession.mcpControlContext)
		XCTAssertEqual(childSession.permissionProfile, .userConfigured)

		await agentModeVM.mcpDeactivateControlContext(sessionID: sourceSessionID)
		await agentModeVM.mcpDeactivateControlContext(sessionID: childSessionID)
		await AgentRunSessionStore.cleanup(sessionID: sourceSessionID)
		await AgentRunSessionStore.cleanup(sessionID: childSessionID)
	}

	func testAgentManageResumeSessionValidatesModelBeforeApplyingParentLineage() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let targetTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }

		let agentModeVM = windowState.agentModeViewModel
		agentModeVM.ensureSession(for: sourceTabID)
		let sourceSessionID = try XCTUnwrap(agentModeVM.sessions[sourceTabID]?.activeAgentSessionID)
		await agentModeVM.mcpActivateControlContext(
			forTabID: sourceTabID,
			sessionID: sourceSessionID,
			originatingConnectionID: nil,
			taskLabelKind: .engineer
		)
		agentModeVM.ensureSession(for: targetTabID)
		let targetSession = try XCTUnwrap(agentModeVM.sessions[targetTabID])
		let targetSessionID = try XCTUnwrap(targetSession.activeAgentSessionID)
		XCTAssertNil(targetSession.parentSessionID)

		let metadata = MCPServerViewModel.RequestMetadata(
			connectionID: UUID(),
			clientName: "test-agent-client",
			windowID: windowState.windowID
		)
		let service = AgentManageMCPToolService(
			toolName: "agent_manage",
			captureRequestMetadata: { metadata },
			requireTargetWindow: { windowState },
			resolveSpawnSourceTabID: { _ in sourceTabID },
			resolveSpawnParentSessionID: { _, _ in sourceSessionID },
			bindCurrentRequestToTab: { _, _ in }
		)

		await XCTAssertThrowsErrorAsync(try await service.execute(args: [
			"op": .string("resume_session"),
			"session_id": .string(targetSessionID.uuidString),
			"model_id": .string("not-a-valid-model-id")
		])) { error in
			guard case MCPError.invalidParams = error else {
				return XCTFail("Expected invalidParams error, got \(error)")
			}
		}

		XCTAssertNil(targetSession.parentSessionID)
		XCTAssertNil(agentModeVM.sessionIndex[targetSessionID]?.parentSessionID)
		XCTAssertNil(targetSession.mcpControlContext)

		await agentModeVM.mcpDeactivateControlContext(sessionID: sourceSessionID)
		await AgentRunSessionStore.cleanup(sessionID: sourceSessionID)
	}

	func testAgentManageCleanupSessionsDeletesOpenInactiveMCPChildAndSessionSwitchingStillWorks() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }

		let agentModeVM = windowState.agentModeViewModel
		agentModeVM.ensureSession(for: sourceTabID)
		let sourceSessionID = try XCTUnwrap(agentModeVM.sessions[sourceTabID]?.activeAgentSessionID)
		await agentModeVM.mcpActivateControlContext(
			forTabID: sourceTabID,
			sessionID: sourceSessionID,
			originatingConnectionID: nil,
			taskLabelKind: .engineer
		)
		defer { Task { await AgentRunSessionStore.cleanup(sessionID: sourceSessionID) } }

		var createdTabID: UUID?
		let metadata = MCPServerViewModel.RequestMetadata(
			connectionID: UUID(),
			clientName: "test-client",
			windowID: windowState.windowID
		)
		let createService = AgentManageMCPToolService(
			toolName: "agent_manage",
			captureRequestMetadata: { metadata },
			requireTargetWindow: { windowState },
			resolveSpawnSourceTabID: { _ in sourceTabID },
			resolveSpawnParentSessionID: { _, _ in sourceSessionID },
			bindCurrentRequestToTab: { tabID, _ in createdTabID = tabID }
		)
		let createValue = try await createService.execute(args: [
			"op": .string("create_session"),
			"session_name": .string("Cleanup Child")
		])
		let createObject = try XCTUnwrap(createValue.objectValue)
		let childSessionID = try XCTUnwrap(createObject["session_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
		let childTabID = try XCTUnwrap(createdTabID)
		let childSession = try XCTUnwrap(agentModeVM.sessions[childTabID])
		childSession.runState = .completed
		await agentModeVM.mcpActivateControlContext(
			forTabID: childTabID,
			sessionID: childSessionID,
			originatingConnectionID: nil,
			taskLabelKind: .engineer
		)
		await windowState.promptManager.switchComposeTab(childTabID)
		XCTAssertEqual(windowState.promptManager.activeComposeTabID, childTabID)

		let cleanupValue = try await makeAgentManageService(windowState: windowState).execute(args: [
			"op": .string("cleanup_sessions"),
			"session_ids": sessionIDsValue([childSessionID])
		])
		let cleanupObject = try XCTUnwrap(cleanupValue.objectValue)

		XCTAssertEqual(cleanupObject["status"]?.stringValue, "completed")
		XCTAssertEqual(cleanupObject["deleted_count"]?.intValue, 1)
		XCTAssertNil(agentModeVM.sessions[childTabID])
		XCTAssertNil(agentModeVM.sessionIndex[childSessionID])
		XCTAssertFalse(agentModeVM.tabsWithActiveAgentRun.contains(childTabID))
		XCTAssertFalse(agentModeVM.mcpControlledTabIDs.contains(childTabID))
		let childStoreSnapshot = await AgentRunSessionStore.snapshot(for: childSessionID)
		XCTAssertNil(childStoreSnapshot)
		XCTAssertFalse(windowState.workspaceManager.activeWorkspace?.composeTabs.contains(where: { $0.id == childTabID }) == true)
		assertNoWorkspaceActiveAgentSessionReferences(windowState: windowState, sessionID: childSessionID)
		XCTAssertNotEqual(windowState.promptManager.activeComposeTabID, childTabID)

		await windowState.promptManager.switchComposeTab(sourceTabID)
		let sourceSession = await agentModeVM.ensureSessionReady(tabID: sourceTabID)
		XCTAssertEqual(sourceSession.activeAgentSessionID, sourceSessionID)
	}

	func testAgentManageCleanupSessionsSkipsLiveEffectivelyActiveMCPSession() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }

		let agentModeVM = windowState.agentModeViewModel
		agentModeVM.ensureSession(for: sourceTabID)
		let session = try XCTUnwrap(agentModeVM.sessions[sourceTabID])
		let sessionID = try XCTUnwrap(session.activeAgentSessionID)
		await agentModeVM.mcpActivateControlContext(
			forTabID: sourceTabID,
			sessionID: sessionID,
			originatingConnectionID: nil,
			taskLabelKind: .engineer
		)
		defer { Task { await AgentRunSessionStore.cleanup(sessionID: sessionID) } }
		session.runState = .completed

		session.mcpFollowUpRunPending = true
		var cleanupValue = try await makeAgentManageService(windowState: windowState).execute(args: [
			"op": .string("cleanup_sessions"),
			"session_ids": sessionIDsValue([sessionID])
		])
		var cleanupObject = try XCTUnwrap(cleanupValue.objectValue)
		XCTAssertEqual(cleanupObject["status"]?.stringValue, "partial")
		XCTAssertEqual(cleanupObject["deleted_count"]?.intValue, 0)
		XCTAssertEqual(cleanupObject["skipped_count"]?.intValue, 1)
		XCTAssertEqual(cleanupObject["skipped_sessions"]?.arrayValue?.first?.objectValue?["reason"]?.stringValue, "skipped_active")
		XCTAssertNotNil(agentModeVM.sessions[sourceTabID])

		session.mcpFollowUpRunPending = false
		session.pendingSupersedingTurnCompletions = 1
		cleanupValue = try await makeAgentManageService(windowState: windowState).execute(args: [
			"op": .string("cleanup_sessions"),
			"session_ids": sessionIDsValue([sessionID])
		])
		cleanupObject = try XCTUnwrap(cleanupValue.objectValue)
		XCTAssertEqual(cleanupObject["status"]?.stringValue, "partial")
		XCTAssertEqual(cleanupObject["deleted_count"]?.intValue, 0)
		XCTAssertEqual(cleanupObject["skipped_count"]?.intValue, 1)
		XCTAssertEqual(cleanupObject["skipped_sessions"]?.arrayValue?.first?.objectValue?["reason"]?.stringValue, "skipped_active")
		XCTAssertNotNil(agentModeVM.sessions[sourceTabID])
	}

	func testAgentManageCleanupSessionsUsesPersistedComposeTabIDWhenIndexMissing() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let childTabID = UUID()
		let childSessionID = UUID()
		let duplicateStashedTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }
		let workspace = try XCTUnwrap(windowState.workspaceManager.activeWorkspace)
		let workspaceIndex = try XCTUnwrap(windowState.workspaceManager.workspaces.firstIndex(where: { $0.id == workspace.id }))

		windowState.workspaceManager.workspaces[workspaceIndex].composeTabs.append(
			ComposeTabState(
				id: childTabID,
				name: "Persisted Child",
				lastModified: Date(),
				activeAgentSessionID: childSessionID
			)
		)
		windowState.workspaceManager.workspaces[workspaceIndex].stashedTabs.append(
			StashedTab(
				tab: ComposeTabState(
					id: duplicateStashedTabID,
					name: "Duplicate Stale Binding",
					lastModified: Date(),
					activeAgentSessionID: childSessionID
				)
			)
		)
		windowState.workspaceManager.workspaces[workspaceIndex].activeComposeTabID = childTabID
		windowState.promptManager.loadComposeTabsFromWorkspace(windowState.workspaceManager.workspaces[workspaceIndex])

		let persistedSession = AgentSession(
			id: childSessionID,
			workspaceID: workspace.id,
			composeTabID: childTabID,
			name: "Persisted Child",
			transcript: .empty,
			lastRunState: AgentSessionRunState.completed.rawValue,
			parentSessionID: UUID(),
			isMCPOriginated: true
		)
		_ = try await AgentSessionDataService.shared.saveAgentSession(
			persistedSession,
			for: workspace,
			preparation: .alreadyCanonicalTranscript
		)
		XCTAssertNil(windowState.agentModeViewModel.sessionIndex[childSessionID])
		XCTAssertNil(windowState.agentModeViewModel.sessions[childTabID])

		let cleanupValue = try await makeAgentManageService(windowState: windowState).execute(args: [
			"op": .string("cleanup_sessions"),
			"session_ids": sessionIDsValue([childSessionID])
		])
		let cleanupObject = try XCTUnwrap(cleanupValue.objectValue)
		let activeWorkspace = try XCTUnwrap(windowState.workspaceManager.activeWorkspace)

		XCTAssertEqual(cleanupObject["status"]?.stringValue, "completed")
		XCTAssertEqual(cleanupObject["deleted_count"]?.intValue, 1)
		let loadedDeletedSession = try await AgentSessionDataService.shared.loadAgentSession(id: childSessionID, for: activeWorkspace)
		XCTAssertNil(loadedDeletedSession)
		XCTAssertFalse(activeWorkspace.composeTabs.contains(where: { $0.id == childTabID }))
		assertNoWorkspaceActiveAgentSessionReferences(windowState: windowState, sessionID: childSessionID)
		XCTAssertNil(windowState.agentModeViewModel.sessionIndex[childSessionID])
		XCTAssertNotEqual(windowState.promptManager.activeComposeTabID, childTabID)

		let sourceSession = await windowState.agentModeViewModel.ensureSessionReady(tabID: sourceTabID)
		XCTAssertEqual(sourceSession.tabID, sourceTabID)
	}

	func testAgentManageListSessionsWaitingForInputMatchesApprovalState() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }

		let agentModeVM = windowState.agentModeViewModel
		agentModeVM.ensureSession(for: sourceTabID)
		let session = try XCTUnwrap(agentModeVM.sessions[sourceTabID])
		let sessionID = try XCTUnwrap(session.activeAgentSessionID)
		agentModeVM.test_upsertSessionIndex(
			sessionID: sessionID,
			tabID: sourceTabID,
			name: "Stale Index Session",
			lastUserMessageAt: nil,
			savedAt: Date(timeIntervalSince1970: 100),
			lastRunStateRaw: AgentSessionRunState.completed.rawValue,
			itemCount: 0,
			agentKindRaw: nil,
			agentModelRaw: nil,
			agentReasoningEffortRaw: nil,
			autoEditEnabled: true
		)
		let metadata = MCPServerViewModel.RequestMetadata(
			connectionID: UUID(),
			clientName: "test-client",
			windowID: windowState.windowID
		)
		let service = AgentManageMCPToolService(
			toolName: "agent_manage",
			captureRequestMetadata: { metadata },
			requireTargetWindow: { windowState },
			resolveSpawnSourceTabID: { _ in nil },
			resolveSpawnParentSessionID: { _, _ in nil },
			bindCurrentRequestToTab: { _, _ in }
		)

		for waitingState in [
			AgentSessionRunState.waitingForUser,
			.waitingForQuestion,
			.waitingForApproval
		] {
			session.runState = waitingState
			let value = try await service.execute(args: [
				"op": .string("list_sessions"),
				"state": .string(AgentRunMCPSnapshot.Status.waitingForInput.rawValue)
			])
			let object = try XCTUnwrap(value.objectValue)
			let sessions = object["sessions"]?.arrayValue ?? []
			let listed = try XCTUnwrap(sessions.first?.objectValue)

			XCTAssertEqual(sessions.count, 1)
			XCTAssertEqual(listed["session_id"]?.stringValue, sessionID.uuidString)
			XCTAssertEqual(listed["state"]?.stringValue, AgentRunMCPSnapshot.Status.waitingForInput.rawValue)
			XCTAssertEqual(listed["raw_state"]?.stringValue, waitingState.rawValue)
		}

		session.runState = .waitingForApproval
		let legacyValue = try await service.execute(args: [
			"op": .string("list_sessions"),
			"state": .string(AgentSessionRunState.waitingForApproval.rawValue)
		])
		let legacyObject = try XCTUnwrap(legacyValue.objectValue)
		let legacySessions = legacyObject["sessions"]?.arrayValue ?? []

		XCTAssertEqual(legacySessions.count, 1)
	}

	func testAgentManageListSessionsIgnoresNameArgument() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }

		let agentModeVM = windowState.agentModeViewModel
		let firstSessionID = UUID()
		let secondSessionID = UUID()
		agentModeVM.test_upsertSessionIndex(
			sessionID: firstSessionID,
			tabID: UUID(),
			name: "Alpha Session",
			lastUserMessageAt: nil,
			savedAt: Date(timeIntervalSince1970: 200),
			lastRunStateRaw: AgentSessionRunState.completed.rawValue,
			itemCount: 0,
			agentKindRaw: nil,
			agentModelRaw: nil,
			agentReasoningEffortRaw: nil,
			autoEditEnabled: true
		)
		agentModeVM.test_upsertSessionIndex(
			sessionID: secondSessionID,
			tabID: UUID(),
			name: "Beta Session",
			lastUserMessageAt: nil,
			savedAt: Date(timeIntervalSince1970: 100),
			lastRunStateRaw: AgentSessionRunState.completed.rawValue,
			itemCount: 0,
			agentKindRaw: nil,
			agentModelRaw: nil,
			agentReasoningEffortRaw: nil,
			autoEditEnabled: true
		)

		let value = try await makeAgentManageService(windowState: windowState).execute(args: [
			"op": .string("list_sessions"),
			"name": .string("does-not-match-any-session")
		])
		let object = try XCTUnwrap(value.objectValue)
		let sessions = object["sessions"]?.arrayValue ?? []
		let names = Set(sessions.compactMap { $0.objectValue?["name"]?.stringValue })

		XCTAssertEqual(sessions.count, 2)
		XCTAssertEqual(names, ["Alpha Session", "Beta Session"])
	}

	func testAgentManageGetLogResolvesLiveSessionByLowercaseUUID() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }

		let agentModeVM = windowState.agentModeViewModel
		agentModeVM.ensureSession(for: sourceTabID)
		let session = try XCTUnwrap(agentModeVM.sessions[sourceTabID])
		let sessionID = try XCTUnwrap(session.activeAgentSessionID)
		session.transcript = AgentTranscriptIO.importLegacyItems([
			.user("Live request", sequenceIndex: 0),
			.assistant("Live answer", sequenceIndex: 1)
		])
		session.hasLoadedPersistedState = true

		let metadata = MCPServerViewModel.RequestMetadata(
			connectionID: UUID(),
			clientName: "test-client",
			windowID: windowState.windowID
		)
		let service = AgentManageMCPToolService(
			toolName: "agent_manage",
			captureRequestMetadata: { metadata },
			requireTargetWindow: { windowState },
			resolveSpawnSourceTabID: { _ in nil },
			resolveSpawnParentSessionID: { _, _ in nil },
			bindCurrentRequestToTab: { _, _ in }
		)

		let value = try await service.execute(args: [
			"op": .string("get_log"),
			"session_id": .string(sessionID.uuidString.lowercased())
		])
		let object = try XCTUnwrap(value.objectValue)
		XCTAssertEqual(object["session_id"]?.stringValue, sessionID.uuidString)
		XCTAssertEqual(object["returned_turn_count"]?.intValue, 1)
		XCTAssertEqual(object["total_turns"]?.intValue, 1)
		XCTAssertTrue(object["transcript_xml"]?.stringValue?.contains("Live request") == true)
	}

	func testAgentManageGetLogPreservesInterleavedAssistantToolOrder() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }

		let agentModeVM = windowState.agentModeViewModel
		agentModeVM.ensureSession(for: sourceTabID)
		let session = try XCTUnwrap(agentModeVM.sessions[sourceTabID])
		let sessionID = try XCTUnwrap(session.activeAgentSessionID)
		session.transcript = AgentTranscriptIO.importLegacyItems(makeInterleavedAssistantToolOrderingItems())
		session.hasLoadedPersistedState = true

		let value = try await makeAgentManageService(windowState: windowState).execute(args: [
			"op": .string("get_log"),
			"session_id": .string(sessionID.uuidString)
		])
		let object = try XCTUnwrap(value.objectValue)
		let xml = try XCTUnwrap(object["transcript_xml"]?.stringValue)

		XCTAssertEqual(object["session_id"]?.stringValue, sessionID.uuidString)
		XCTAssertEqual(object["returned_turn_count"]?.intValue, 1)
		let orderedSnippets = [
			"start calling tools read only, and between each tool say hello",
			"I'll read the README first.",
			"README.md",
			"Hello after README.",
			"GameManager.cs",
			"Hello after GameManager.",
			"BombBehavior.cs",
			"Hello final summary."
		]
		var previousUpperBound = xml.startIndex
		for snippet in orderedSnippets {
			let range = try XCTUnwrap(xml.range(of: snippet), "Missing expected snippet: \(snippet)\n\(xml)")
			XCTAssertLessThanOrEqual(previousUpperBound, range.lowerBound, "Snippet out of order: \(snippet)\n\(xml)")
			previousUpperBound = range.upperBound
		}
	}

	func testAgentManageExtractHandoffBuildsLiveTranscriptPayload() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }

		let agentModeVM = windowState.agentModeViewModel
		agentModeVM.ensureSession(for: sourceTabID)
		let session = try XCTUnwrap(agentModeVM.sessions[sourceTabID])
		let sessionID = try XCTUnwrap(session.activeAgentSessionID)
		session.selectedAgent = .codexExec
		session.selectedModelRaw = AgentModel.defaultModel.rawValue
		session.transcript = AgentTranscriptIO.importLegacyItems([
			.user("Live handoff request", sequenceIndex: 0),
			.assistant("Live handoff answer", sequenceIndex: 1)
		])
		session.hasLoadedPersistedState = true

		let value = try await makeAgentManageService(windowState: windowState).execute(args: [
			"op": .string("extract_handoff"),
			"session_id": .string(sessionID.uuidString)
		])
		let object = try XCTUnwrap(value.objectValue)
		let handoffXML = try XCTUnwrap(object["handoff_xml"]?.stringValue)

		XCTAssertEqual(object["session_id"]?.stringValue, sessionID.uuidString)
		XCTAssertEqual(object["source"]?.stringValue, "live")
		XCTAssertEqual(object["content_kind"]?.stringValue, "forked_session")
		XCTAssertTrue(handoffXML.contains("<forked_session"))
		XCTAssertTrue(handoffXML.contains("Live handoff request"))
		XCTAssertTrue(handoffXML.contains("Live handoff answer"))
	}

	func testAgentManageExtractHandoffRespectsValidUpToItemID() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }
		let workspace = try XCTUnwrap(windowState.workspaceManager.activeWorkspace)
		let sessionID = UUID()
		let firstUser = AgentChatItem.user("First request", sequenceIndex: 0)
		let firstAssistant = AgentChatItem.assistant("First answer", sequenceIndex: 1)
		let secondUser = AgentChatItem.user("Second request", sequenceIndex: 2)
		let secondAssistant = AgentChatItem.assistant("Second answer", sequenceIndex: 3)
		let transcript = AgentTranscriptIO.importLegacyItems([
			firstUser,
			firstAssistant,
			secondUser,
			secondAssistant
		])
		let persistedSession = AgentSession(
			id: sessionID,
			workspaceID: workspace.id,
			composeTabID: sourceTabID,
			name: "Cutoff Handoff",
			transcript: transcript,
			agentKind: DiscoverAgentKind.claudeCode.rawValue,
			agentModel: AgentModel.defaultModel.rawValue
		)
		_ = try await AgentSessionDataService.shared.saveAgentSession(
			persistedSession,
			for: workspace,
			preparation: .alreadyCanonicalTranscript
		)

		let value = try await makeAgentManageService(windowState: windowState).execute(args: [
			"op": .string("extract_handoff"),
			"session_id": .string(sessionID.uuidString),
			"up_to_item_id": .string(firstAssistant.id.uuidString)
		])
		let object = try XCTUnwrap(value.objectValue)
		let handoffXML = try XCTUnwrap(object["handoff_xml"]?.stringValue)

		XCTAssertEqual(object["session_id"]?.stringValue, sessionID.uuidString)
		XCTAssertEqual(object["up_to_item_id"]?.stringValue, firstAssistant.id.uuidString)
		XCTAssertTrue(handoffXML.contains("First request"))
		XCTAssertTrue(handoffXML.contains("First answer"))
		XCTAssertFalse(handoffXML.contains("Second request"))
		XCTAssertFalse(handoffXML.contains("Second answer"))
	}

	func testPrepareHandoffToNewTabUsesStructuredTranscriptForHistoricalCutoff() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }
		let agentModeVM = windowState.agentModeViewModel
		agentModeVM.ensureSession(for: sourceTabID)
		let sourceSession = agentModeVM.session(for: sourceTabID)
		let firstUser = AgentChatItem.user("Historical request", sequenceIndex: 0)
		let firstAssistant = AgentChatItem.assistant("Historical answer", sequenceIndex: 1)
		let latestUser = AgentChatItem.user("Latest request", sequenceIndex: 2)
		let latestAssistant = AgentChatItem.assistant("Latest answer", sequenceIndex: 3)
		sourceSession.selectedAgent = .claudeCode
		sourceSession.selectedModelRaw = AgentModel.defaultModel.rawValue
		sourceSession.transcript = AgentTranscriptIO.importLegacyItems([
			firstUser,
			firstAssistant,
			latestUser,
			latestAssistant
		])
		// Simulate a compacted/restored live session where `items` only contains
		// the latest mutable working suffix while historical rows live in `transcript`.
		sourceSession.setItemsSilently([latestUser, latestAssistant], reason: .testOverride)
		sourceSession.hasLoadedPersistedState = true

		let destinationTabID = try await agentModeVM.prepareHandoffToNewTab(
			upToItemID: firstAssistant.id,
			destinationAgent: .gemini,
			destinationModelRaw: AgentModel.defaultModel.rawValue,
			destinationReasoningEffortRaw: nil
		)
		let destination = agentModeVM.session(for: destinationTabID)
		let destinationText = destination.items.map(\.text).joined(separator: "\n")
		let payload = try XCTUnwrap(destination.pendingHandoff.payload)

		XCTAssertTrue(destinationText.contains("Historical request"))
		XCTAssertTrue(destinationText.contains("Historical answer"))
		XCTAssertFalse(destinationText.contains("Latest request"))
		XCTAssertFalse(destinationText.contains("Latest answer"))
		XCTAssertTrue(payload.contains("Historical request"))
		XCTAssertTrue(payload.contains("Historical answer"))
		XCTAssertFalse(payload.contains("Latest request"))
		XCTAssertFalse(payload.contains("Latest answer"))
		XCTAssertEqual(destination.pendingHandoff.sourceItemID, firstAssistant.id)
	}

	func testPrepareHandoffToNewTabPreservesLatestCutoffFromStructuredTranscript() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }
		let agentModeVM = windowState.agentModeViewModel
		agentModeVM.ensureSession(for: sourceTabID)
		let sourceSession = agentModeVM.session(for: sourceTabID)
		let firstUser = AgentChatItem.user("Preserved first request", sequenceIndex: 0)
		let firstAssistant = AgentChatItem.assistant("Preserved first answer", sequenceIndex: 1)
		let latestUser = AgentChatItem.user("Preserved latest request", sequenceIndex: 2)
		let latestAssistant = AgentChatItem.assistant("Preserved latest answer", sequenceIndex: 3)
		sourceSession.selectedAgent = .claudeCode
		sourceSession.selectedModelRaw = AgentModel.defaultModel.rawValue
		sourceSession.transcript = AgentTranscriptIO.importLegacyItems([
			firstUser,
			firstAssistant,
			latestUser,
			latestAssistant
		])
		// The live mutable suffix may only contain latest rows; a latest-row cutoff
		// should still export through that row from the authoritative transcript.
		sourceSession.setItemsSilently([latestUser, latestAssistant], reason: .testOverride)
		sourceSession.hasLoadedPersistedState = true

		let destinationTabID = try await agentModeVM.prepareHandoffToNewTab(
			upToItemID: latestAssistant.id,
			destinationAgent: .gemini,
			destinationModelRaw: AgentModel.defaultModel.rawValue,
			destinationReasoningEffortRaw: nil
		)
		let destination = agentModeVM.session(for: destinationTabID)
		let destinationText = destination.items.map(\.text).joined(separator: "\n")
		let payload = try XCTUnwrap(destination.pendingHandoff.payload)

		XCTAssertTrue(destinationText.contains("Preserved first request"))
		XCTAssertTrue(destinationText.contains("Preserved first answer"))
		XCTAssertTrue(destinationText.contains("Preserved latest request"))
		XCTAssertTrue(destinationText.contains("Preserved latest answer"))
		XCTAssertTrue(payload.contains("Preserved first request"))
		XCTAssertTrue(payload.contains("Preserved first answer"))
		XCTAssertTrue(payload.contains("Preserved latest request"))
		XCTAssertTrue(payload.contains("Preserved latest answer"))
		XCTAssertEqual(destination.pendingHandoff.sourceItemID, latestAssistant.id)
	}

	func testPrepareHandoffToNewTabRejectsCutoffPresentOnlyInItemsWhenTranscriptExists() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }
		let agentModeVM = windowState.agentModeViewModel
		agentModeVM.ensureSession(for: sourceTabID)
		let sourceSession = agentModeVM.session(for: sourceTabID)
		let transcriptUser = AgentChatItem.user("Canonical request", sequenceIndex: 0)
		let transcriptAssistant = AgentChatItem.assistant("Canonical answer", sequenceIndex: 1)
		let orphanUser = AgentChatItem.user("Orphan suffix request", sequenceIndex: 2)
		let orphanAssistant = AgentChatItem.assistant("Orphan suffix answer", sequenceIndex: 3)
		sourceSession.transcript = AgentTranscriptIO.importLegacyItems([transcriptUser, transcriptAssistant])
		sourceSession.setItemsSilently([orphanUser, orphanAssistant], reason: .testOverride)
		let composeTabCountBefore = windowState.workspaceManager.activeWorkspace?.composeTabs.count

		await XCTAssertThrowsErrorAsync(try await agentModeVM.prepareHandoffToNewTab(
			upToItemID: orphanAssistant.id,
			destinationAgent: .gemini,
			destinationModelRaw: AgentModel.defaultModel.rawValue,
			destinationReasoningEffortRaw: nil
		)) { error in
			guard case AgentSessionError.invalidHandoffCutoff = error else {
				return XCTFail("Expected invalidHandoffCutoff, got \(error)")
			}
		}
		XCTAssertEqual(windowState.workspaceManager.activeWorkspace?.composeTabs.count, composeTabCountBefore)
	}

	func testPrepareHandoffToNewTabUsesLegacyItemsFallbackWhenTranscriptIsEmpty() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }
		let agentModeVM = windowState.agentModeViewModel
		agentModeVM.ensureSession(for: sourceTabID)
		let sourceSession = agentModeVM.session(for: sourceTabID)
		let legacyUser = AgentChatItem.user("Legacy fallback request", sequenceIndex: 0)
		let legacyAssistant = AgentChatItem.assistant("Legacy fallback answer", sequenceIndex: 1)
		sourceSession.selectedAgent = .claudeCode
		sourceSession.selectedModelRaw = AgentModel.defaultModel.rawValue
		sourceSession.transcript = .empty
		sourceSession.setItemsSilently([legacyUser, legacyAssistant], reason: .testOverride)

		let destinationTabID = try await agentModeVM.prepareHandoffToNewTab(
			upToItemID: legacyAssistant.id,
			destinationAgent: .gemini,
			destinationModelRaw: AgentModel.defaultModel.rawValue,
			destinationReasoningEffortRaw: nil
		)
		let destination = agentModeVM.session(for: destinationTabID)
		let destinationText = destination.items.map(\.text).joined(separator: "\n")
		let payload = try XCTUnwrap(destination.pendingHandoff.payload)

		XCTAssertTrue(destinationText.contains("Legacy fallback request"))
		XCTAssertTrue(destinationText.contains("Legacy fallback answer"))
		XCTAssertTrue(payload.contains("Legacy fallback request"))
		XCTAssertTrue(payload.contains("Legacy fallback answer"))
		XCTAssertEqual(destination.pendingHandoff.sourceItemID, legacyAssistant.id)
	}

	func testAgentManageExtractHandoffBuildsPersistedTranscriptOnlyPayload() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }
		let workspace = try XCTUnwrap(windowState.workspaceManager.activeWorkspace)
		let sessionID = UUID()
		let transcript = AgentTranscriptIO.importLegacyItems([
			.user("Persisted request", sequenceIndex: 0),
			.assistant("Persisted answer", sequenceIndex: 1)
		])
		let persistedSession = AgentSession(
			id: sessionID,
			workspaceID: workspace.id,
			composeTabID: sourceTabID,
			name: "Persisted Handoff",
			transcript: transcript,
			agentKind: DiscoverAgentKind.claudeCode.rawValue,
			agentModel: AgentModel.defaultModel.rawValue
		)
		_ = try await AgentSessionDataService.shared.saveAgentSession(
			persistedSession,
			for: workspace,
			preparation: .alreadyCanonicalTranscript
		)

		let service = makeAgentManageService(windowState: windowState)
		let value = try await service.execute(args: [
			"op": .string("extract_handoff"),
			"session_id": .string(sessionID.uuidString)
		])
		let object = try XCTUnwrap(value.objectValue)
		let handoffXML = try XCTUnwrap(object["handoff_xml"]?.stringValue)

		XCTAssertEqual(object["session_id"]?.stringValue, sessionID.uuidString)
		XCTAssertEqual(object["content_kind"]?.stringValue, "forked_session")
		XCTAssertEqual(object["source"]?.stringValue, "persisted")
		XCTAssertEqual(object["included_file_contents"]?.boolValue, false)
		XCTAssertEqual(object["file_contents_status"]?.stringValue, "not_requested")
		XCTAssertTrue(handoffXML.contains("<forked_session"))
		XCTAssertTrue(handoffXML.contains("<transcript>"))
		XCTAssertTrue(handoffXML.contains("Persisted request"))
		XCTAssertTrue(handoffXML.contains("Persisted answer"))
		XCTAssertFalse(handoffXML.contains("<file_contents>"))
	}

	func testAgentManageExtractHandoffWritesOutputAndOmitsInlineByDefault() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }
		let workspace = try XCTUnwrap(windowState.workspaceManager.activeWorkspace)
		let sessionID = UUID()
		let transcript = AgentTranscriptIO.importLegacyItems([
			.user("Write this handoff", sequenceIndex: 0),
			.assistant("Written", sequenceIndex: 1)
		])
		let persistedSession = AgentSession(
			id: sessionID,
			workspaceID: workspace.id,
			composeTabID: sourceTabID,
			name: "Output Handoff",
			transcript: transcript,
			agentKind: DiscoverAgentKind.codexExec.rawValue,
			agentModel: AgentModel.defaultModel.rawValue
		)
		_ = try await AgentSessionDataService.shared.saveAgentSession(
			persistedSession,
			for: workspace,
			preparation: .alreadyCanonicalTranscript
		)
		let outputURL = tempRoot.appendingPathComponent("exports/handoff.xml")

		let value = try await makeAgentManageService(windowState: windowState).execute(args: [
			"op": .string("extract_handoff"),
			"session_id": .string(sessionID.uuidString),
			"output_path": .string(outputURL.path)
		])
		let object = try XCTUnwrap(value.objectValue)
		let written = try String(contentsOf: outputURL, encoding: .utf8)

		XCTAssertEqual(object["output_path"]?.stringValue, outputURL.standardizedFileURL.path)
		XCTAssertEqual(object["inline"]?.boolValue, false)
		XCTAssertNil(object["handoff_xml"]?.stringValue)
		XCTAssertEqual(object["bytes_written"]?.intValue, Data(written.utf8).count)
		XCTAssertTrue(written.contains("<forked_session"))
		XCTAssertTrue(written.contains("Write this handoff"))
	}

	func testAgentManageExtractHandoffRejectsUnsafeOptions() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let sourceTabID = UUID()
		let windowState = makeWindowState(root: tempRoot, sourceTabID: sourceTabID)
		defer { Task { await windowState.tearDown() } }
		let workspace = try XCTUnwrap(windowState.workspaceManager.activeWorkspace)
		let sessionID = UUID()
		let persistedSession = AgentSession(
			id: sessionID,
			workspaceID: workspace.id,
			composeTabID: sourceTabID,
			name: "Reject Handoff",
			transcript: AgentTranscriptIO.importLegacyItems([
				.user("Reject request", sequenceIndex: 0),
				.assistant("Reject answer", sequenceIndex: 1)
			]),
			agentKind: DiscoverAgentKind.claudeCode.rawValue,
			agentModel: AgentModel.defaultModel.rawValue
		)
		_ = try await AgentSessionDataService.shared.saveAgentSession(
			persistedSession,
			for: workspace,
			preparation: .alreadyCanonicalTranscript
		)
		let service = makeAgentManageService(windowState: windowState)
		let outputURL = tempRoot.appendingPathComponent("existing.xml")
		try "existing".write(to: outputURL, atomically: true, encoding: .utf8)

		await XCTAssertThrowsErrorAsync(try await service.execute(args: [
			"op": .string("extract_handoff"),
			"session_id": .string(sessionID.uuidString),
			"output_path": .string(outputURL.path),
			"overwrite": .bool(false)
		])) { error in
			guard case MCPError.invalidParams(let message) = error else {
				return XCTFail("Expected invalidParams error, got \(error)")
			}
			XCTAssertTrue((message ?? "").contains("overwrite=false"))
		}

		await XCTAssertThrowsErrorAsync(try await service.execute(args: [
			"op": .string("extract_handoff"),
			"session_id": .string(sessionID.uuidString),
			"include_file_contents": .bool(true)
		])) { error in
			guard case MCPError.invalidParams(let message) = error else {
				return XCTFail("Expected invalidParams error, got \(error)")
			}
			XCTAssertNotNil(message)
		}

		await XCTAssertThrowsErrorAsync(try await service.execute(args: [
			"op": .string("extract_handoff"),
			"session_id": .string(sessionID.uuidString),
			"up_to_item_id": .string("not-a-uuid")
		])) { error in
			guard case MCPError.invalidParams(let message) = error else {
				return XCTFail("Expected invalidParams error, got \(error)")
			}
			XCTAssertTrue((message ?? "").contains("up_to_item_id"))
		}

		await XCTAssertThrowsErrorAsync(try await service.execute(args: [
			"op": .string("extract_handoff"),
			"session_id": .string(sessionID.uuidString),
			"up_to_item_id": .string(UUID().uuidString)
		])) { error in
			guard case MCPError.invalidParams(let message) = error else {
				return XCTFail("Expected invalidParams error, got \(error)")
			}
			XCTAssertTrue((message ?? "").contains("not found"))
		}
	}

	/// Regression test: agent_run.wait must not return a stale terminal
	/// snapshot when the live session has restarted (split-brain condition).
	///
	/// This test bypasses the full ViewModel Combine pipeline and instead
	/// directly verifies the store-level reconciliation in the wait path.
	func testAgentRunWaitReconcilesStalTerminalWhenSessionRestarted() async throws {
		// Use the shared store directly: register a session, mark it completed,
		// then verify that agent_run.wait reconciles the stale state when the
		// live snapshot reports running.
		let sessionID = UUID()
		let tabID = UUID()
		let store = AgentRunSessionStore.shared

		await store.register(sessionID: sessionID)
		await store.noteSnapshot(
			makeSnapshot(sessionID: sessionID, tabID: tabID, status: .completed)
		)
		// Verify terminal state is cached.
		let storedBefore = await store.snapshot(for: sessionID)
		XCTAssertEqual(storedBefore?.status, .completed)

		// Simulate a restart: live state is running but store holds old completed.
		// Reset store for the new run (as prepareMCPWaitTrackingForRunStart does).
		await store.resetSnapshotForNewTurn(sessionID: sessionID)
		await store.noteSnapshot(
			makeSnapshot(sessionID: sessionID, tabID: tabID, status: .running)
		)

		// Verify the store now has running (not the old completed).
		let storedAfterReset = await store.snapshot(for: sessionID)
		XCTAssertEqual(storedAfterReset?.status, .running)

		// Start a waiter — it should block (not return the old completed).
		let waiter = Task {
			await store.waitUntilInteresting(sessionID: sessionID, timeoutSeconds: 5)
		}
		// Give the waiter time to register.
		try await Task.sleep(nanoseconds: 100_000_000)

		// Signal the new run completing.
		await store.noteSnapshot(
			makeSnapshot(sessionID: sessionID, tabID: tabID, status: .completed)
		)

		let disposition = await waiter.value
		if case .snapshotReady(let snap) = disposition {
			XCTAssertEqual(snap.status, .completed,
				"Wait should return the NEW completed snapshot, not the stale one")
		} else {
			XCTFail("Expected .snapshotReady(.completed), got \(disposition)")
		}

		await store.cleanup(sessionID: sessionID)
	}

	func testAgentRunStoreWaitCancellationDispositionDistinctFromExpired() async throws {
		let sessionID = UUID()
		let tabID = UUID()
		defer {
			Task { await AgentRunSessionStore.cleanup(sessionID: sessionID) }
		}

		await AgentRunSessionStore.register(sessionID: sessionID)
		await AgentRunSessionStore.noteSnapshot(makeSnapshot(sessionID: sessionID, tabID: tabID, status: .running))

		let waiter = Task {
			await AgentRunSessionStore.waitUntilInteresting(sessionID: sessionID, timeoutSeconds: 30)
		}
		try await waitForStoreWaiter(sessionID: sessionID)
		waiter.cancel()

		let disposition = await waiter.value
		XCTAssertEqual(disposition, .cancelled)

		await AgentRunSessionStore.cleanup(sessionID: sessionID)
		let expired = await AgentRunSessionStore.waitUntilInteresting(sessionID: sessionID, timeoutSeconds: 0)
		XCTAssertEqual(expired, .expired)
	}

	func testAgentRunWaitAnyReconcilesStaleStoreTerminalBeforeImmediateTimeout() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let windowState = makeWindowState(root: tempRoot, sourceTabID: UUID())
		defer { Task { await windowState.tearDown() } }
		let firstSessionID = UUID()
		let secondSessionID = UUID()
		let firstRunning = makeSnapshot(sessionID: firstSessionID, tabID: UUID(), status: .running)
		let secondRunning = makeSnapshot(sessionID: secondSessionID, tabID: UUID(), status: .running)
		let service = makeAgentRunWaitService(windowState: windowState, currentSnapshotProvider: { sessionID, _ in
			switch sessionID {
			case firstSessionID: return firstRunning
			case secondSessionID: return secondRunning
			default: return nil
			}
		})
		defer {
			Task {
				await AgentRunSessionStore.cleanup(sessionID: firstSessionID)
				await AgentRunSessionStore.cleanup(sessionID: secondSessionID)
			}
		}

		await AgentRunSessionStore.register(sessionID: firstSessionID)
		await AgentRunSessionStore.register(sessionID: secondSessionID)
		await AgentRunSessionStore.noteSnapshot(makeSnapshot(sessionID: firstSessionID, tabID: UUID(), status: .completed))
		await AgentRunSessionStore.noteSnapshot(secondRunning)

		let value = try await service.execute(args: [
			"op": .string("wait"),
			"session_ids": sessionIDsValue([firstSessionID, secondSessionID]),
			"timeout": .int(0)
		])
		let object = try XCTUnwrap(value.objectValue)
		let wait = try XCTUnwrap(object["wait"]?.objectValue)

		XCTAssertEqual(wait["result"]?.stringValue, "timed_out")
		XCTAssertNil(wait["winner_session_id"]?.stringValue)
		let storedStatus = await AgentRunSessionStore.snapshot(for: firstSessionID)?.status
		XCTAssertEqual(storedStatus, .running)
	}

	func testAgentRunWaitAnyReturnsLiveTerminalAfterNonActionableWakeWhenStoreMissedSnapshot() async throws {
		actor LiveSnapshots {
			var values: [UUID: AgentRunMCPSnapshot]
			init(_ values: [UUID: AgentRunMCPSnapshot]) { self.values = values }
			func snapshot(for sessionID: UUID) -> AgentRunMCPSnapshot? { values[sessionID] }
			func set(_ snapshot: AgentRunMCPSnapshot) { values[snapshot.sessionID] = snapshot }
		}

		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let windowState = makeWindowState(root: tempRoot, sourceTabID: UUID())
		defer { Task { await windowState.tearDown() } }
		let firstSessionID = UUID()
		let secondSessionID = UUID()
		let firstRunning = makeSnapshot(sessionID: firstSessionID, tabID: UUID(), status: .running)
		let secondRunning = makeSnapshot(sessionID: secondSessionID, tabID: UUID(), status: .running, latestAssistantPreview: "old assistant")
		let live = LiveSnapshots([
			firstSessionID: firstRunning,
			secondSessionID: secondRunning
		])
		let service = makeAgentRunWaitService(windowState: windowState, currentSnapshotProvider: { sessionID, _ in
			await live.snapshot(for: sessionID)
		})
		defer {
			Task {
				await AgentRunSessionStore.cleanup(sessionID: firstSessionID)
				await AgentRunSessionStore.cleanup(sessionID: secondSessionID)
			}
		}

		await AgentRunSessionStore.register(sessionID: firstSessionID)
		await AgentRunSessionStore.register(sessionID: secondSessionID)
		await AgentRunSessionStore.noteSnapshot(firstRunning)
		await AgentRunSessionStore.noteSnapshot(secondRunning)

		let waiter = Task { @MainActor in
			try await service.execute(args: [
				"op": .string("wait"),
				"session_ids": sessionIDsValue([firstSessionID, secondSessionID]),
				"timeout": .double(5)
			])
		}
		try await waitForStoreWaiter(sessionID: secondSessionID)

		let secondCompleted = makeSnapshot(sessionID: secondSessionID, tabID: UUID(), status: .completed)
		await live.set(secondCompleted)
		await AgentRunSessionStore.signalSnapshotAndWakeWaiters(
			secondRunning,
			reason: .instructionDelivered
		)

		let value = try await waiter.value
		let object = try XCTUnwrap(value.objectValue)
		let wait = try XCTUnwrap(object["wait"]?.objectValue)

		XCTAssertEqual(object["session_id"]?.stringValue, secondSessionID.uuidString)
		XCTAssertEqual(object["status"]?.stringValue, AgentRunMCPSnapshot.Status.completed.rawValue)
		XCTAssertEqual(wait["result"]?.stringValue, "snapshot_ready")
		XCTAssertEqual(wait["winner_session_id"]?.stringValue, secondSessionID.uuidString)
		let storedStatus = await AgentRunSessionStore.snapshot(for: secondSessionID)?.status
		XCTAssertEqual(storedStatus, .completed)
	}

	func testAgentRunWaitSingleTimeoutEndsWaitScopeAsTimedOut() async throws {
		actor ScopeRecorder {
			var completions: [AgentRunWaitScopeCompletion] = []
			func append(_ completion: AgentRunWaitScopeCompletion) { completions.append(completion) }
			func reasons() -> [AgentRunWaitScopeCompletion.Reason] { completions.map(\.reason) }
		}

		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let windowState = makeWindowState(root: tempRoot, sourceTabID: UUID())
		defer { Task { await windowState.tearDown() } }
		let sessionID = UUID()
		defer { Task { await AgentRunSessionStore.cleanup(sessionID: sessionID) } }

		await AgentRunSessionStore.register(sessionID: sessionID)
		await AgentRunSessionStore.noteSnapshot(makeSnapshot(sessionID: sessionID, tabID: UUID(), status: .running))

		let recorder = ScopeRecorder()
		let service = makeAgentRunWaitService(
			windowState: windowState,
			beginAgentRunWait: { _, _, _ in UUID() },
			endAgentRunWait: { _, completion in await recorder.append(completion) }
		)
		let value = try await service.execute(args: [
			"op": .string("wait"),
			"session_id": .string(sessionID.uuidString),
			"timeout": .double(0.05)
		])
		let object = try XCTUnwrap(value.objectValue)
		XCTAssertEqual(object["status"]?.stringValue, AgentRunMCPSnapshot.Status.running.rawValue)
		let reasons = await recorder.reasons()
		XCTAssertEqual(reasons, [.timedOut])
	}

	func testAgentRunWaitSingleTaskCancellationReturnsSteeringInterruptValue() async throws {
		actor ScopeRecorder {
			var completions: [AgentRunWaitScopeCompletion] = []
			func append(_ completion: AgentRunWaitScopeCompletion) { completions.append(completion) }
			func values() -> [AgentRunWaitScopeCompletion] { completions }
		}

		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let windowState = makeWindowState(root: tempRoot, sourceTabID: UUID())
		defer { Task { await windowState.tearDown() } }
		let sessionID = UUID()
		defer { Task { await AgentRunSessionStore.cleanup(sessionID: sessionID) } }

		await AgentRunSessionStore.register(sessionID: sessionID)
		await AgentRunSessionStore.noteSnapshot(
			makeSnapshot(sessionID: sessionID, tabID: UUID(), status: .running, latestAssistantPreview: "stale assistant text")
		)

		let recorder = ScopeRecorder()
		let service = makeAgentRunWaitService(
			windowState: windowState,
			beginAgentRunWait: { _, _, _ in UUID() },
			endAgentRunWait: { _, completion in await recorder.append(completion) }
		)
		let waiter = Task { @MainActor in
			try await service.execute(args: [
				"op": .string("wait"),
				"session_id": .string(sessionID.uuidString),
				"timeout": .double(30)
			])
		}
		try await waitForStoreWaiter(sessionID: sessionID)
		waiter.cancel()

		let value = try await waiter.value
		let object = try XCTUnwrap(value.objectValue)
		let meta = try XCTUnwrap(object["_meta"]?.objectValue)
		let wait = try XCTUnwrap(object["wait"]?.objectValue)
		let completions = await recorder.values()
		let completion = try XCTUnwrap(completions.first)

		XCTAssertEqual(object["session_id"]?.stringValue, sessionID.uuidString)
		XCTAssertEqual(object["status"]?.stringValue, AgentRunMCPSnapshot.Status.running.rawValue)
		XCTAssertEqual(meta["wake_reason"]?.stringValue, AgentRunSessionStore.WakeReason.steeringRequested.rawValue)
		XCTAssertEqual(wait["result"]?.stringValue, "interrupted_by_steering")
		XCTAssertTrue(wait["instruction"]?.stringValue?.contains("agent_run.wait") == true)
		XCTAssertNil(object["assistant_text"]?.stringValue)
		XCTAssertEqual(completions.count, 1)
		XCTAssertEqual(completion.reason, .cancelled)
		XCTAssertEqual(completion.result, "interrupted_by_steering")
		XCTAssertNil(completion.winnerSessionID)
		XCTAssertEqual(completion.pendingSessionIDs, [sessionID])
	}

	func testAgentRunWaitAnyTimeoutAndCancellationEndWaitScope() async throws {
		actor ScopeRecorder {
			var completions: [AgentRunWaitScopeCompletion] = []
			func append(_ completion: AgentRunWaitScopeCompletion) { completions.append(completion) }
			func reasons() -> [AgentRunWaitScopeCompletion.Reason] { completions.map(\.reason) }
			func values() -> [AgentRunWaitScopeCompletion] { completions }
		}

		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let windowState = makeWindowState(root: tempRoot, sourceTabID: UUID())
		defer { Task { await windowState.tearDown() } }
		let firstSessionID = UUID()
		let secondSessionID = UUID()
		defer {
			Task {
				await AgentRunSessionStore.cleanup(sessionID: firstSessionID)
				await AgentRunSessionStore.cleanup(sessionID: secondSessionID)
			}
		}

		await AgentRunSessionStore.register(sessionID: firstSessionID)
		await AgentRunSessionStore.register(sessionID: secondSessionID)
		await AgentRunSessionStore.noteSnapshot(makeSnapshot(sessionID: firstSessionID, tabID: UUID(), status: .running))
		await AgentRunSessionStore.noteSnapshot(makeSnapshot(sessionID: secondSessionID, tabID: UUID(), status: .running))

		let timeoutRecorder = ScopeRecorder()
		let timeoutService = makeAgentRunWaitService(
			windowState: windowState,
			beginAgentRunWait: { _, _, _ in UUID() },
			endAgentRunWait: { _, completion in await timeoutRecorder.append(completion) }
		)
		let timeoutValue = try await timeoutService.execute(args: [
			"op": .string("wait"),
			"session_ids": sessionIDsValue([firstSessionID, secondSessionID]),
			"timeout": .double(0.05)
		])
		XCTAssertEqual(timeoutValue.objectValue?["wait"]?.objectValue?["result"]?.stringValue, "timed_out")
		let timeoutReasons = await timeoutRecorder.reasons()
		XCTAssertEqual(timeoutReasons, [.timedOut])

		let cancellationRecorder = ScopeRecorder()
		let cancellationService = makeAgentRunWaitService(
			windowState: windowState,
			beginAgentRunWait: { _, _, _ in UUID() },
			endAgentRunWait: { _, completion in await cancellationRecorder.append(completion) }
		)
		let waiter = Task { @MainActor in
			try await cancellationService.execute(args: [
				"op": .string("wait"),
				"session_ids": sessionIDsValue([firstSessionID, secondSessionID]),
				"timeout": .double(30)
			])
		}
		try await waitForStoreWaiter(sessionID: firstSessionID)
		try await waitForStoreWaiter(sessionID: secondSessionID)
		waiter.cancel()

		let cancellationValue = try await waiter.value
		let object = try XCTUnwrap(cancellationValue.objectValue)
		let meta = try XCTUnwrap(object["_meta"]?.objectValue)
		let wait = try XCTUnwrap(object["wait"]?.objectValue)
		let snapshots = object["snapshots"]?.arrayValue ?? []
		let snapshotIDs = snapshots.compactMap { $0.objectValue?["session_id"]?.stringValue }
		let pendingIDs = wait["pending_session_ids"]?.arrayValue?.compactMap { $0.stringValue } ?? []
		let cancellationCompletions = await cancellationRecorder.values()
		let cancellationCompletion = try XCTUnwrap(cancellationCompletions.first)

		XCTAssertEqual(object["status"]?.stringValue, AgentRunMCPSnapshot.Status.running.rawValue)
		XCTAssertEqual(meta["wake_reason"]?.stringValue, AgentRunSessionStore.WakeReason.steeringRequested.rawValue)
		XCTAssertEqual(wait["mode"]?.stringValue, "any")
		XCTAssertEqual(wait["result"]?.stringValue, "interrupted_by_steering")
		XCTAssertNil(wait["winner_session_id"]?.stringValue)
		XCTAssertEqual(wait["session_ids"]?.arrayValue?.compactMap { $0.stringValue }, [firstSessionID.uuidString, secondSessionID.uuidString])
		XCTAssertEqual(wait["waited_count"]?.intValue, 2)
		XCTAssertEqual(pendingIDs, [firstSessionID.uuidString, secondSessionID.uuidString])
		XCTAssertTrue(wait["instruction"]?.stringValue?.contains("agent_run.wait") == true)
		XCTAssertNil(object["assistant_text"]?.stringValue)
		XCTAssertEqual(snapshots.count, 2)
		XCTAssertEqual(Set(snapshotIDs), Set([firstSessionID.uuidString, secondSessionID.uuidString]))
		XCTAssertEqual(cancellationCompletions.count, 1)
		XCTAssertEqual(cancellationCompletion.reason, .cancelled)
		XCTAssertEqual(cancellationCompletion.result, "interrupted_by_steering")
		XCTAssertNil(cancellationCompletion.winnerSessionID)
		XCTAssertEqual(cancellationCompletion.pendingSessionIDs, Set([firstSessionID, secondSessionID]))
	}

	func testAgentRunWaitAnyReturnsFirstInterestingSession() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let windowState = makeWindowState(root: tempRoot, sourceTabID: UUID())
		defer { Task { await windowState.tearDown() } }
		let service = makeAgentRunWaitService(windowState: windowState)
		let firstSessionID = UUID()
		let secondSessionID = UUID()
		defer {
			Task {
				await AgentRunSessionStore.cleanup(sessionID: firstSessionID)
				await AgentRunSessionStore.cleanup(sessionID: secondSessionID)
			}
		}

		await AgentRunSessionStore.register(sessionID: firstSessionID)
		await AgentRunSessionStore.register(sessionID: secondSessionID)
		await AgentRunSessionStore.noteSnapshot(makeSnapshot(sessionID: firstSessionID, tabID: UUID(), status: .running))
		await AgentRunSessionStore.noteSnapshot(makeSnapshot(sessionID: secondSessionID, tabID: UUID(), status: .running))

		let waiter = Task { @MainActor in
			try await service.execute(args: [
				"op": .string("wait"),
				"session_ids": sessionIDsValue([firstSessionID, secondSessionID]),
				"timeout": .double(2)
			])
		}
		try await waitForStoreWaiter(sessionID: secondSessionID)

		await AgentRunSessionStore.noteSnapshot(makeSnapshot(sessionID: secondSessionID, tabID: UUID(), status: .completed))
		let value = try await waiter.value
		let object = try XCTUnwrap(value.objectValue)
		let wait = try XCTUnwrap(object["wait"]?.objectValue)

		XCTAssertEqual(object["session_id"]?.stringValue, secondSessionID.uuidString)
		XCTAssertEqual(object["status"]?.stringValue, AgentRunMCPSnapshot.Status.completed.rawValue)
		XCTAssertEqual(wait["mode"]?.stringValue, "any")
		XCTAssertEqual(wait["result"]?.stringValue, "snapshot_ready")
		XCTAssertEqual(wait["winner_session_id"]?.stringValue, secondSessionID.uuidString)
		XCTAssertEqual(wait["waited_count"]?.intValue, 2)
		XCTAssertEqual(wait["pending_session_ids"]?.arrayValue?.compactMap { $0.stringValue }, [firstSessionID.uuidString])
	}

	func testAgentRunWaitReturnsInstructionDeliveredWake() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let windowState = makeWindowState(root: tempRoot, sourceTabID: UUID())
		defer { Task { await windowState.tearDown() } }
		let service = makeAgentRunWaitService(windowState: windowState)
		let sessionID = UUID()
		defer {
			Task { await AgentRunSessionStore.cleanup(sessionID: sessionID) }
		}

		await AgentRunSessionStore.register(sessionID: sessionID)
		await AgentRunSessionStore.noteSnapshot(
			makeSnapshot(sessionID: sessionID, tabID: UUID(), status: .running, latestAssistantPreview: "old assistant text")
		)

		let waiter = Task { @MainActor in
			try await service.execute(args: [
				"op": .string("wait"),
				"session_id": .string(sessionID.uuidString),
				"timeout": .double(2)
			])
		}
		try await waitForStoreWaiter(sessionID: sessionID)

		await AgentRunSessionStore.signalSnapshotAndWakeWaiters(
			makeSnapshot(sessionID: sessionID, tabID: UUID(), status: .running, latestAssistantPreview: "stale assistant text"),
			reason: .instructionDelivered
		)
		let value = try await waiter.value
		let object = try XCTUnwrap(value.objectValue)
		let meta = try XCTUnwrap(object["_meta"]?.objectValue)

		XCTAssertEqual(object["session_id"]?.stringValue, sessionID.uuidString)
		XCTAssertEqual(object["status"]?.stringValue, AgentRunMCPSnapshot.Status.running.rawValue)
		XCTAssertEqual(meta["wake_reason"]?.stringValue, AgentRunSessionStore.WakeReason.instructionDelivered.rawValue)
		XCTAssertNil(object["assistant_text"]?.stringValue)
	}

	func testAgentRunWaitReturnsSteeringWakeFollowUpNote() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let windowState = makeWindowState(root: tempRoot, sourceTabID: UUID())
		defer { Task { await windowState.tearDown() } }
		let service = makeAgentRunWaitService(windowState: windowState)
		let sessionID = UUID()
		defer {
			Task { await AgentRunSessionStore.cleanup(sessionID: sessionID) }
		}

		await AgentRunSessionStore.register(sessionID: sessionID)
		await AgentRunSessionStore.noteSnapshot(
			makeSnapshot(sessionID: sessionID, tabID: UUID(), status: .running, latestAssistantPreview: "old assistant text")
		)

		let waiter = Task { @MainActor in
			try await service.execute(args: [
				"op": .string("wait"),
				"session_id": .string(sessionID.uuidString),
				"timeout": .double(2)
			])
		}
		try await waitForStoreWaiter(sessionID: sessionID)

		await AgentRunSessionStore.signalSnapshotAndWakeWaiters(
			makeSnapshot(sessionID: sessionID, tabID: UUID(), status: .running, latestAssistantPreview: "stale assistant text"),
			reason: .steeringRequested
		)
		let value = try await waiter.value
		let object = try XCTUnwrap(value.objectValue)
		let meta = try XCTUnwrap(object["_meta"]?.objectValue)
		let wait = try XCTUnwrap(object["wait"]?.objectValue)
		let note = try XCTUnwrap(meta["note"]?.stringValue)

		XCTAssertEqual(object["session_id"]?.stringValue, sessionID.uuidString)
		XCTAssertEqual(object["status"]?.stringValue, AgentRunMCPSnapshot.Status.running.rawValue)
		XCTAssertEqual(meta["wake_reason"]?.stringValue, AgentRunSessionStore.WakeReason.steeringRequested.rawValue)
		XCTAssertTrue(note.contains("has not completed"))
		XCTAssertTrue(note.contains("agent_run.wait"))
		XCTAssertEqual(wait["result"]?.stringValue, "interrupted_by_steering")
		XCTAssertEqual(wait["instruction"]?.stringValue, note)
		XCTAssertNil(object["assistant_text"]?.stringValue)
	}

	func testAgentRunStoreRegisterClearsPendingInstructionDeliveredWake() async throws {
		let sessionID = UUID()
		let tabID = UUID()
		defer {
			Task { await AgentRunSessionStore.cleanup(sessionID: sessionID) }
		}

		await AgentRunSessionStore.register(sessionID: sessionID)
		await AgentRunSessionStore.noteSnapshot(makeSnapshot(sessionID: sessionID, tabID: tabID, status: .running))
		await AgentRunSessionStore.signalSnapshotAndWakeWaiters(
			makeSnapshot(sessionID: sessionID, tabID: tabID, status: .running),
			reason: .instructionDelivered
		)

		await AgentRunSessionStore.register(sessionID: sessionID)
		await AgentRunSessionStore.noteSnapshot(makeSnapshot(sessionID: sessionID, tabID: tabID, status: .running))

		let disposition = await AgentRunSessionStore.waitUntilInteresting(sessionID: sessionID, timeoutSeconds: 0)
		XCTAssertEqual(disposition, .timedOut)
	}

	func testAgentRunWaitConsumesInstructionDeliveredWakeSignalledBeforeWaitStarts() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let windowState = makeWindowState(root: tempRoot, sourceTabID: UUID())
		defer { Task { await windowState.tearDown() } }
		let service = makeAgentRunWaitService(windowState: windowState)
		let sessionID = UUID()
		defer {
			Task { await AgentRunSessionStore.cleanup(sessionID: sessionID) }
		}

		await AgentRunSessionStore.register(sessionID: sessionID)
		await AgentRunSessionStore.noteSnapshot(
			makeSnapshot(sessionID: sessionID, tabID: UUID(), status: .running, latestAssistantPreview: "old assistant text")
		)
		await AgentRunSessionStore.signalSnapshotAndWakeWaiters(
			makeSnapshot(sessionID: sessionID, tabID: UUID(), status: .running, latestAssistantPreview: "stale assistant text"),
			reason: .instructionDelivered
		)

		let value = try await service.execute(args: [
			"op": .string("wait"),
			"session_id": .string(sessionID.uuidString),
			"timeout": .double(2)
		])
		let object = try XCTUnwrap(value.objectValue)
		let meta = try XCTUnwrap(object["_meta"]?.objectValue)

		XCTAssertEqual(object["session_id"]?.stringValue, sessionID.uuidString)
		XCTAssertEqual(object["status"]?.stringValue, AgentRunMCPSnapshot.Status.running.rawValue)
		XCTAssertEqual(meta["wake_reason"]?.stringValue, AgentRunSessionStore.WakeReason.instructionDelivered.rawValue)
		XCTAssertNil(object["assistant_text"]?.stringValue)

		let secondDisposition = await AgentRunSessionStore.waitUntilInteresting(sessionID: sessionID, timeoutSeconds: 0)
		XCTAssertEqual(secondDisposition, .timedOut)
	}

	func testAgentRunWaitAnyIgnoresInstructionDeliveredWakeUntilActionable() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let windowState = makeWindowState(root: tempRoot, sourceTabID: UUID())
		defer { Task { await windowState.tearDown() } }
		let service = makeAgentRunWaitService(windowState: windowState)
		let firstSessionID = UUID()
		let secondSessionID = UUID()
		defer {
			Task {
				await AgentRunSessionStore.cleanup(sessionID: firstSessionID)
				await AgentRunSessionStore.cleanup(sessionID: secondSessionID)
			}
		}

		await AgentRunSessionStore.register(sessionID: firstSessionID)
		await AgentRunSessionStore.register(sessionID: secondSessionID)
		await AgentRunSessionStore.noteSnapshot(makeSnapshot(sessionID: firstSessionID, tabID: UUID(), status: .running))
		await AgentRunSessionStore.noteSnapshot(
			makeSnapshot(sessionID: secondSessionID, tabID: UUID(), status: .running, latestAssistantPreview: "old assistant text")
		)

		let waiter = Task { @MainActor in
			try await service.execute(args: [
				"op": .string("wait"),
				"session_ids": sessionIDsValue([firstSessionID, secondSessionID]),
				"timeout": .double(2)
			])
		}
		try await waitForStoreWaiter(sessionID: secondSessionID)

		await AgentRunSessionStore.signalSnapshotAndWakeWaiters(
			makeSnapshot(sessionID: secondSessionID, tabID: UUID(), status: .running, latestAssistantPreview: "stale assistant text"),
			reason: .instructionDelivered
		)

		await AgentRunSessionStore.noteSnapshot(makeSnapshot(sessionID: firstSessionID, tabID: UUID(), status: .completed))
		let value = try await waiter.value
		let object = try XCTUnwrap(value.objectValue)
		let wait = try XCTUnwrap(object["wait"]?.objectValue)

		XCTAssertEqual(object["session_id"]?.stringValue, firstSessionID.uuidString)
		XCTAssertEqual(object["status"]?.stringValue, AgentRunMCPSnapshot.Status.completed.rawValue)
		XCTAssertNil(object["assistant_text"]?.stringValue)
		XCTAssertNil(object["_meta"])
		XCTAssertEqual(wait["mode"]?.stringValue, "any")
		XCTAssertEqual(wait["result"]?.stringValue, "snapshot_ready")
		XCTAssertNotEqual(wait["result"]?.stringValue, AgentRunSessionStore.WakeReason.instructionDelivered.rawValue)
		XCTAssertEqual(wait["winner_session_id"]?.stringValue, firstSessionID.uuidString)
		XCTAssertEqual(wait["pending_session_ids"]?.arrayValue?.compactMap { $0.stringValue }, [secondSessionID.uuidString])
		XCTAssertNil(wait["instruction"]?.stringValue)
	}

	func testAgentRunWaitAnySteeringWakeWinsOverFreshActionableSnapshotRace() async throws {
		actor LiveSnapshots {
			var values: [UUID: AgentRunMCPSnapshot]
			init(_ values: [UUID: AgentRunMCPSnapshot]) { self.values = values }
			func snapshot(for sessionID: UUID) -> AgentRunMCPSnapshot? { values[sessionID] }
			func set(_ snapshot: AgentRunMCPSnapshot) { values[snapshot.sessionID] = snapshot }
		}

		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let windowState = makeWindowState(root: tempRoot, sourceTabID: UUID())
		defer { Task { await windowState.tearDown() } }
		let firstSessionID = UUID()
		let secondSessionID = UUID()
		let firstRunning = makeSnapshot(sessionID: firstSessionID, tabID: UUID(), status: .running)
		let secondRunning = makeSnapshot(sessionID: secondSessionID, tabID: UUID(), status: .running, latestAssistantPreview: "old assistant text")
		let live = LiveSnapshots([
			firstSessionID: firstRunning,
			secondSessionID: secondRunning
		])
		let service = makeAgentRunWaitService(windowState: windowState, currentSnapshotProvider: { sessionID, _ in
			await live.snapshot(for: sessionID)
		})
		defer {
			Task {
				await AgentRunSessionStore.cleanup(sessionID: firstSessionID)
				await AgentRunSessionStore.cleanup(sessionID: secondSessionID)
			}
		}

		await AgentRunSessionStore.register(sessionID: firstSessionID)
		await AgentRunSessionStore.register(sessionID: secondSessionID)
		await AgentRunSessionStore.noteSnapshot(firstRunning)
		await AgentRunSessionStore.noteSnapshot(secondRunning)

		let waiter = Task { @MainActor in
			try await service.execute(args: [
				"op": .string("wait"),
				"session_ids": sessionIDsValue([firstSessionID, secondSessionID]),
				"timeout": .double(5)
			])
		}
		try await waitForStoreWaiter(sessionID: secondSessionID)

		await live.set(makeSnapshot(sessionID: firstSessionID, tabID: UUID(), status: .completed))
		await AgentRunSessionStore.wakeCurrentWaiters(
			secondRunning,
			reason: .steeringRequested
		)

		let value = try await waiter.value
		let object = try XCTUnwrap(value.objectValue)
		let meta = try XCTUnwrap(object["_meta"]?.objectValue)
		let wait = try XCTUnwrap(object["wait"]?.objectValue)
		let snapshots = object["snapshots"]?.arrayValue ?? []
		let completedSnapshot = snapshots.first { $0.objectValue?["session_id"]?.stringValue == firstSessionID.uuidString }

		XCTAssertEqual(meta["wake_reason"]?.stringValue, AgentRunSessionStore.WakeReason.steeringRequested.rawValue)
		XCTAssertEqual(wait["mode"]?.stringValue, "any")
		XCTAssertEqual(wait["result"]?.stringValue, "interrupted_by_steering")
		XCTAssertNil(wait["winner_session_id"]?.stringValue)
		XCTAssertEqual(completedSnapshot?.objectValue?["status"]?.stringValue, AgentRunMCPSnapshot.Status.completed.rawValue)
	}

	func testAgentRunWaitAnyReturnsSteeringWakeInterrupt() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let windowState = makeWindowState(root: tempRoot, sourceTabID: UUID())
		defer { Task { await windowState.tearDown() } }
		let service = makeAgentRunWaitService(windowState: windowState)
		let firstSessionID = UUID()
		let secondSessionID = UUID()
		defer {
			Task {
				await AgentRunSessionStore.cleanup(sessionID: firstSessionID)
				await AgentRunSessionStore.cleanup(sessionID: secondSessionID)
			}
		}

		await AgentRunSessionStore.register(sessionID: firstSessionID)
		await AgentRunSessionStore.register(sessionID: secondSessionID)
		await AgentRunSessionStore.noteSnapshot(makeSnapshot(sessionID: firstSessionID, tabID: UUID(), status: .running))
		await AgentRunSessionStore.noteSnapshot(
			makeSnapshot(sessionID: secondSessionID, tabID: UUID(), status: .running, latestAssistantPreview: "old assistant text")
		)

		let waiter = Task { @MainActor in
			try await service.execute(args: [
				"op": .string("wait"),
				"session_ids": sessionIDsValue([firstSessionID, secondSessionID]),
				"timeout": .double(2)
			])
		}
		try await waitForStoreWaiter(sessionID: secondSessionID)

		await AgentRunSessionStore.wakeCurrentWaiters(
			makeSnapshot(sessionID: secondSessionID, tabID: UUID(), status: .running, latestAssistantPreview: "stale assistant text"),
			reason: .steeringRequested
		)

		let value = try await waiter.value
		let object = try XCTUnwrap(value.objectValue)
		let meta = try XCTUnwrap(object["_meta"]?.objectValue)
		let wait = try XCTUnwrap(object["wait"]?.objectValue)
		let snapshots = object["snapshots"]?.arrayValue ?? []
		let snapshotIDs = snapshots.compactMap { $0.objectValue?["session_id"]?.stringValue }

		XCTAssertEqual(object["session_id"]?.stringValue, firstSessionID.uuidString)
		XCTAssertEqual(object["status"]?.stringValue, AgentRunMCPSnapshot.Status.running.rawValue)
		XCTAssertEqual(meta["wake_reason"]?.stringValue, AgentRunSessionStore.WakeReason.steeringRequested.rawValue)
		XCTAssertNil(object["assistant_text"]?.stringValue)
		XCTAssertEqual(wait["mode"]?.stringValue, "any")
		XCTAssertEqual(wait["result"]?.stringValue, "interrupted_by_steering")
		XCTAssertNil(wait["winner_session_id"]?.stringValue)
		XCTAssertEqual(wait["pending_session_ids"]?.arrayValue?.compactMap { $0.stringValue }, [firstSessionID.uuidString, secondSessionID.uuidString])
		XCTAssertTrue(wait["instruction"]?.stringValue?.contains("agent_run.wait") == true)
		XCTAssertEqual(Set(snapshotIDs), Set([firstSessionID.uuidString, secondSessionID.uuidString]))
	}

	func testAgentRunWaitAnyIgnoresPendingInstructionDeliveredWakeUntilActionable() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let windowState = makeWindowState(root: tempRoot, sourceTabID: UUID())
		defer { Task { await windowState.tearDown() } }
		let service = makeAgentRunWaitService(windowState: windowState)
		let firstSessionID = UUID()
		let secondSessionID = UUID()
		defer {
			Task {
				await AgentRunSessionStore.cleanup(sessionID: firstSessionID)
				await AgentRunSessionStore.cleanup(sessionID: secondSessionID)
			}
		}

		await AgentRunSessionStore.register(sessionID: firstSessionID)
		await AgentRunSessionStore.register(sessionID: secondSessionID)
		await AgentRunSessionStore.noteSnapshot(makeSnapshot(sessionID: firstSessionID, tabID: UUID(), status: .running))
		await AgentRunSessionStore.noteSnapshot(
			makeSnapshot(sessionID: secondSessionID, tabID: UUID(), status: .running, latestAssistantPreview: "old assistant text")
		)
		await AgentRunSessionStore.signalSnapshotAndWakeWaiters(
			makeSnapshot(sessionID: secondSessionID, tabID: UUID(), status: .running, latestAssistantPreview: "pending assistant text"),
			reason: .instructionDelivered
		)

		let waiter = Task { @MainActor in
			try await service.execute(args: [
				"op": .string("wait"),
				"session_ids": sessionIDsValue([firstSessionID, secondSessionID]),
				"timeout": .double(2)
			])
		}
		try await waitForStoreWaiter(sessionID: secondSessionID)

		await AgentRunSessionStore.noteSnapshot(makeSnapshot(sessionID: firstSessionID, tabID: UUID(), status: .completed))
		let value = try await waiter.value
		let object = try XCTUnwrap(value.objectValue)
		let wait = try XCTUnwrap(object["wait"]?.objectValue)

		XCTAssertEqual(object["session_id"]?.stringValue, firstSessionID.uuidString)
		XCTAssertEqual(object["status"]?.stringValue, AgentRunMCPSnapshot.Status.completed.rawValue)
		XCTAssertNil(object["_meta"])
		XCTAssertNil(object["assistant_text"]?.stringValue)
		XCTAssertEqual(wait["mode"]?.stringValue, "any")
		XCTAssertEqual(wait["result"]?.stringValue, "snapshot_ready")
		XCTAssertNotEqual(wait["result"]?.stringValue, AgentRunSessionStore.WakeReason.instructionDelivered.rawValue)
		XCTAssertEqual(wait["winner_session_id"]?.stringValue, firstSessionID.uuidString)
		XCTAssertEqual(wait["pending_session_ids"]?.arrayValue?.compactMap { $0.stringValue }, [secondSessionID.uuidString])
	}

	func testAgentRunWaitAnyReturnsPendingSteeringWakeInterrupt() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let windowState = makeWindowState(root: tempRoot, sourceTabID: UUID())
		defer { Task { await windowState.tearDown() } }
		let service = makeAgentRunWaitService(windowState: windowState)
		let firstSessionID = UUID()
		let secondSessionID = UUID()
		defer {
			Task {
				await AgentRunSessionStore.cleanup(sessionID: firstSessionID)
				await AgentRunSessionStore.cleanup(sessionID: secondSessionID)
			}
		}

		await AgentRunSessionStore.register(sessionID: firstSessionID)
		await AgentRunSessionStore.register(sessionID: secondSessionID)
		await AgentRunSessionStore.noteSnapshot(makeSnapshot(sessionID: firstSessionID, tabID: UUID(), status: .running))
		await AgentRunSessionStore.noteSnapshot(
			makeSnapshot(sessionID: secondSessionID, tabID: UUID(), status: .running, latestAssistantPreview: "old assistant text")
		)
		await AgentRunSessionStore.signalSnapshotAndWakeWaiters(
			makeSnapshot(sessionID: secondSessionID, tabID: UUID(), status: .running, latestAssistantPreview: "pending assistant text"),
			reason: .steeringRequested
		)

		let value = try await service.execute(args: [
			"op": .string("wait"),
			"session_ids": sessionIDsValue([firstSessionID, secondSessionID]),
			"timeout": .double(2)
		])
		let object = try XCTUnwrap(value.objectValue)
		let meta = try XCTUnwrap(object["_meta"]?.objectValue)
		let wait = try XCTUnwrap(object["wait"]?.objectValue)
		let snapshots = object["snapshots"]?.arrayValue ?? []
		let snapshotIDs = snapshots.compactMap { $0.objectValue?["session_id"]?.stringValue }

		XCTAssertEqual(object["status"]?.stringValue, AgentRunMCPSnapshot.Status.running.rawValue)
		XCTAssertEqual(meta["wake_reason"]?.stringValue, AgentRunSessionStore.WakeReason.steeringRequested.rawValue)
		XCTAssertEqual(wait["mode"]?.stringValue, "any")
		XCTAssertEqual(wait["result"]?.stringValue, "interrupted_by_steering")
		XCTAssertNil(wait["winner_session_id"]?.stringValue)
		XCTAssertEqual(wait["pending_session_ids"]?.arrayValue?.compactMap { $0.stringValue }, [firstSessionID.uuidString, secondSessionID.uuidString])
		XCTAssertEqual(Set(snapshotIDs), Set([firstSessionID.uuidString, secondSessionID.uuidString]))
	}

	func testAgentRunWaitAnyTimesOutAfterIgnoredInstructionDeliveredWake() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let windowState = makeWindowState(root: tempRoot, sourceTabID: UUID())
		defer { Task { await windowState.tearDown() } }
		let service = makeAgentRunWaitService(windowState: windowState)
		let firstSessionID = UUID()
		let secondSessionID = UUID()
		defer {
			Task {
				await AgentRunSessionStore.cleanup(sessionID: firstSessionID)
				await AgentRunSessionStore.cleanup(sessionID: secondSessionID)
			}
		}

		await AgentRunSessionStore.register(sessionID: firstSessionID)
		await AgentRunSessionStore.register(sessionID: secondSessionID)
		await AgentRunSessionStore.noteSnapshot(makeSnapshot(sessionID: firstSessionID, tabID: UUID(), status: .running))
		await AgentRunSessionStore.noteSnapshot(
			makeSnapshot(sessionID: secondSessionID, tabID: UUID(), status: .running, latestAssistantPreview: "old assistant text")
		)

		let waiter = Task { @MainActor in
			try await service.execute(args: [
				"op": .string("wait"),
				"session_ids": sessionIDsValue([firstSessionID, secondSessionID]),
				"timeout": .double(1.0)
			])
		}
		try await waitForStoreWaiter(sessionID: secondSessionID)

		await AgentRunSessionStore.signalSnapshotAndWakeWaiters(
			makeSnapshot(sessionID: secondSessionID, tabID: UUID(), status: .running, latestAssistantPreview: "stale assistant text"),
			reason: .instructionDelivered
		)

		let value = try await waiter.value
		let object = try XCTUnwrap(value.objectValue)
		let wait = try XCTUnwrap(object["wait"]?.objectValue)
		let snapshots = object["snapshots"]?.arrayValue ?? []
		let snapshotIDs = snapshots.compactMap { $0.objectValue?["session_id"]?.stringValue }

		XCTAssertEqual(wait["mode"]?.stringValue, "any")
		XCTAssertEqual(wait["result"]?.stringValue, "timed_out")
		XCTAssertNil(wait["winner_session_id"]?.stringValue)
		XCTAssertNotEqual(wait["result"]?.stringValue, AgentRunSessionStore.WakeReason.instructionDelivered.rawValue)
		XCTAssertNil(object["_meta"])
		XCTAssertNil(object["assistant_text"]?.stringValue)
		XCTAssertEqual(snapshots.count, 2)
		XCTAssertEqual(Set(snapshotIDs), Set([firstSessionID.uuidString, secondSessionID.uuidString]))
	}

	func testAgentRunWaitAnyWaitingForInputWithoutInteractionReturnsImmediately() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let windowState = makeWindowState(root: tempRoot, sourceTabID: UUID())
		defer { Task { await windowState.tearDown() } }
		let service = makeAgentRunWaitService(windowState: windowState)
		let firstSessionID = UUID()
		let secondSessionID = UUID()
		defer {
			Task {
				await AgentRunSessionStore.cleanup(sessionID: firstSessionID)
				await AgentRunSessionStore.cleanup(sessionID: secondSessionID)
			}
		}

		await AgentRunSessionStore.register(sessionID: firstSessionID)
		await AgentRunSessionStore.register(sessionID: secondSessionID)
		await AgentRunSessionStore.noteSnapshot(makeSnapshot(sessionID: firstSessionID, tabID: UUID(), status: .running))
		await AgentRunSessionStore.noteSnapshot(makeSnapshot(sessionID: secondSessionID, tabID: UUID(), status: .waitingForInput))

		let value = try await service.execute(args: [
			"op": .string("wait"),
			"session_ids": sessionIDsValue([firstSessionID, secondSessionID]),
			"timeout": .double(30)
		])
		let object = try XCTUnwrap(value.objectValue)
		let wait = try XCTUnwrap(object["wait"]?.objectValue)

		XCTAssertEqual(object["session_id"]?.stringValue, secondSessionID.uuidString)
		XCTAssertEqual(object["status"]?.stringValue, AgentRunMCPSnapshot.Status.waitingForInput.rawValue)
		XCTAssertEqual(wait["mode"]?.stringValue, "any")
		XCTAssertEqual(wait["result"]?.stringValue, "snapshot_ready")
		XCTAssertEqual(wait["winner_session_id"]?.stringValue, secondSessionID.uuidString)
		XCTAssertEqual(wait["pending_session_ids"]?.arrayValue?.compactMap { $0.stringValue }, [firstSessionID.uuidString])
	}

	func testAgentRunWaitAnyTimeoutReturnsAllSnapshots() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let windowState = makeWindowState(root: tempRoot, sourceTabID: UUID())
		defer { Task { await windowState.tearDown() } }
		let service = makeAgentRunWaitService(windowState: windowState)
		let firstSessionID = UUID()
		let secondSessionID = UUID()
		defer {
			Task {
				await AgentRunSessionStore.cleanup(sessionID: firstSessionID)
				await AgentRunSessionStore.cleanup(sessionID: secondSessionID)
			}
		}

		await AgentRunSessionStore.register(sessionID: firstSessionID)
		await AgentRunSessionStore.register(sessionID: secondSessionID)
		await AgentRunSessionStore.noteSnapshot(makeSnapshot(sessionID: firstSessionID, tabID: UUID(), status: .running))
		await AgentRunSessionStore.noteSnapshot(makeSnapshot(sessionID: secondSessionID, tabID: UUID(), status: .running))

		let value = try await service.execute(args: [
			"op": .string("wait"),
			"session_ids": sessionIDsValue([firstSessionID, secondSessionID]),
			"timeout": .int(0)
		])
		let object = try XCTUnwrap(value.objectValue)
		let wait = try XCTUnwrap(object["wait"]?.objectValue)
		let snapshots = object["snapshots"]?.arrayValue ?? []
		let snapshotIDs = snapshots.compactMap { $0.objectValue?["session_id"]?.stringValue }

		XCTAssertEqual(wait["mode"]?.stringValue, "any")
		XCTAssertEqual(wait["result"]?.stringValue, "timed_out")
		XCTAssertNil(wait["winner_session_id"]?.stringValue)
		XCTAssertEqual(snapshots.count, 2)
		XCTAssertEqual(Set(snapshotIDs), Set([firstSessionID.uuidString, secondSessionID.uuidString]))
	}

	func testAgentRunWaitAnyAlreadyInterestingReturnsImmediately() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let windowState = makeWindowState(root: tempRoot, sourceTabID: UUID())
		defer { Task { await windowState.tearDown() } }
		let service = makeAgentRunWaitService(windowState: windowState)
		let firstSessionID = UUID()
		let secondSessionID = UUID()
		defer {
			Task {
				await AgentRunSessionStore.cleanup(sessionID: firstSessionID)
				await AgentRunSessionStore.cleanup(sessionID: secondSessionID)
			}
		}

		await AgentRunSessionStore.register(sessionID: firstSessionID)
		await AgentRunSessionStore.register(sessionID: secondSessionID)
		await AgentRunSessionStore.noteSnapshot(makeSnapshot(sessionID: firstSessionID, tabID: UUID(), status: .running))
		await AgentRunSessionStore.noteSnapshot(makeSnapshot(sessionID: secondSessionID, tabID: UUID(), status: .completed))

		let value = try await service.execute(args: [
			"op": .string("wait"),
			"session_ids": sessionIDsValue([firstSessionID, secondSessionID]),
			"timeout": .double(30)
		])
		let object = try XCTUnwrap(value.objectValue)
		let wait = try XCTUnwrap(object["wait"]?.objectValue)

		XCTAssertEqual(object["session_id"]?.stringValue, secondSessionID.uuidString)
		XCTAssertEqual(object["status"]?.stringValue, AgentRunMCPSnapshot.Status.completed.rawValue)
		XCTAssertEqual(wait["result"]?.stringValue, "snapshot_ready")
		XCTAssertEqual(wait["winner_session_id"]?.stringValue, secondSessionID.uuidString)
	}

	func testAgentRunWaitAnyRejectsMixedInputs() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let windowState = makeWindowState(root: tempRoot, sourceTabID: UUID())
		defer { Task { await windowState.tearDown() } }
		let service = makeAgentRunWaitService(windowState: windowState)
		let sessionID = UUID()

		await XCTAssertThrowsErrorAsync(try await service.execute(args: [
			"op": .string("wait"),
			"session_id": .string(sessionID.uuidString),
			"session_ids": sessionIDsValue([sessionID])
		])) { error in
			guard case MCPError.invalidParams(let message) = error else {
				return XCTFail("Expected invalidParams error, got \(error)")
			}
			XCTAssertTrue((message ?? "").contains("Specify either session_id or session_ids"))
		}
	}

	func testAgentRunPollManyReturnsAllSnapshots() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let windowState = makeWindowState(root: tempRoot, sourceTabID: UUID())
		defer { Task { await windowState.tearDown() } }
		let service = makeAgentRunWaitService(windowState: windowState)
		let firstSessionID = UUID()
		let secondSessionID = UUID()
		defer {
			Task {
				await AgentRunSessionStore.cleanup(sessionID: firstSessionID)
				await AgentRunSessionStore.cleanup(sessionID: secondSessionID)
			}
		}

		await AgentRunSessionStore.register(sessionID: firstSessionID)
		await AgentRunSessionStore.register(sessionID: secondSessionID)
		await AgentRunSessionStore.noteSnapshot(makeSnapshot(sessionID: firstSessionID, tabID: UUID(), status: .running))
		await AgentRunSessionStore.noteSnapshot(makeSnapshot(sessionID: secondSessionID, tabID: UUID(), status: .completed))

		let value = try await service.execute(args: [
			"op": .string("poll"),
			"session_ids": sessionIDsValue([firstSessionID, secondSessionID])
		])
		let object = try XCTUnwrap(value.objectValue)
		let poll = try XCTUnwrap(object["poll"]?.objectValue)
		let snapshots = object["snapshots"]?.arrayValue ?? []
		let snapshotIDs = snapshots.compactMap { $0.objectValue?["session_id"]?.stringValue }

		XCTAssertEqual(poll["mode"]?.stringValue, "many")
		XCTAssertEqual(poll["polled_count"]?.intValue, 2)
		XCTAssertEqual(poll["running_session_ids"]?.arrayValue?.compactMap { $0.stringValue }, [firstSessionID.uuidString])
		XCTAssertEqual(poll["terminal_session_ids"]?.arrayValue?.compactMap { $0.stringValue }, [secondSessionID.uuidString])
		XCTAssertEqual(poll["interesting_session_ids"]?.arrayValue?.compactMap { $0.stringValue }, [secondSessionID.uuidString])
		XCTAssertEqual(snapshots.count, 2)
		XCTAssertEqual(Set(snapshotIDs), Set([firstSessionID.uuidString, secondSessionID.uuidString]))
	}

	private func makeAgentExploreService(
		windowState: WindowState,
		sourceTabID: UUID?,
		startRun: AgentRunMCPToolService.StartRun? = nil
	) -> AgentExploreMCPToolService {
		let metadata = MCPServerViewModel.RequestMetadata(
			connectionID: UUID(),
			clientName: "test-client",
			windowID: windowState.windowID
		)
		return AgentExploreMCPToolService(
			toolName: "agent_explore",
			captureRequestMetadata: { metadata },
			requireTargetWindow: { windowState },
			resolveSpawnSourceTabID: { _ in sourceTabID },
			resolveSpawnParentSessionID: { _, _ in nil },
			bindCurrentRequestToTab: { _, _ in },
			withHeartbeat: { _, _, _, _, operation in try await operation() },
			startRun: startRun ?? { _, _, _, _, _, _, _, _, _, _ in
				throw MCPError.internalError("startRun should not be used by this test")
			}
		)
	}

	private func activateMCPSource(
		windowState: WindowState,
		tabID: UUID,
		taskLabelKind: AgentModelCatalog.TaskLabelKind
	) async throws -> UUID {
		let agentModeVM = windowState.agentModeViewModel
		agentModeVM.ensureSession(for: tabID)
		let sessionID = try XCTUnwrap(agentModeVM.sessions[tabID]?.activeAgentSessionID)
		await agentModeVM.mcpActivateControlContext(
			forTabID: tabID,
			sessionID: sessionID,
			originatingConnectionID: nil,
			taskLabelKind: taskLabelKind
		)
		return sessionID
	}

	private func createMCPChild(
		windowState: WindowState,
		parentSessionID: UUID,
		taskLabelKind: AgentModelCatalog.TaskLabelKind,
		runState: AgentSessionRunState
	) async throws -> (tabID: UUID, sessionID: UUID) {
		let agentModeVM = windowState.agentModeViewModel
		let tabID = UUID()
		agentModeVM.ensureSession(for: tabID)
		let session = try XCTUnwrap(agentModeVM.sessions[tabID])
		let sessionID = try XCTUnwrap(session.activeAgentSessionID)
		agentModeVM.applySpawnParentSessionID(parentSessionID, to: session)
		await agentModeVM.mcpActivateControlContext(
			forTabID: tabID,
			sessionID: sessionID,
			originatingConnectionID: nil,
			taskLabelKind: taskLabelKind
		)
		session.runState = runState
		return (tabID, sessionID)
	}

	private func vmApplyParent(_ agentModeVM: AgentModeViewModel, tabID: UUID) {
		agentModeVM.test_applySpawnParentSessionID(UUID(), tabID: tabID)
	}

	private func makeInterleavedAssistantToolOrderingItems() -> [AgentChatItem] {
		let firstInvocationID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
		let secondInvocationID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
		let thirdInvocationID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
		return [
			.user("start calling tools read only, and between each tool say hello", sequenceIndex: 0),
			.assistant("I'll read the README first.", sequenceIndex: 1),
			.toolCall(name: "read_file", invocationID: firstInvocationID, argsJSON: #"{"path":"README.md"}"#, sequenceIndex: 2),
			.toolResult(name: "read_file", invocationID: firstInvocationID, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 3),
			.assistant("Hello after README.", sequenceIndex: 4),
			.toolCall(name: "read_file", invocationID: secondInvocationID, argsJSON: #"{"path":"Assets/Content/Scripts/GameManager.cs"}"#, sequenceIndex: 5),
			.toolResult(name: "read_file", invocationID: secondInvocationID, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 6),
			.assistant("Hello after GameManager.", sequenceIndex: 7),
			.toolCall(name: "read_file", invocationID: thirdInvocationID, argsJSON: #"{"path":"Assets/Content/Scripts/BombBehavior.cs"}"#, sequenceIndex: 8),
			.toolResult(name: "read_file", invocationID: thirdInvocationID, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 9),
			.assistant("Hello final summary.", sequenceIndex: 10)
		]
	}

	private func makeAgentManageService(windowState: WindowState) -> AgentManageMCPToolService {
		let metadata = MCPServerViewModel.RequestMetadata(
			connectionID: UUID(),
			clientName: "test-client",
			windowID: windowState.windowID
		)
		return AgentManageMCPToolService(
			toolName: "agent_manage",
			captureRequestMetadata: { metadata },
			requireTargetWindow: { windowState },
			resolveSpawnSourceTabID: { _ in nil },
			resolveSpawnParentSessionID: { _, _ in nil },
			bindCurrentRequestToTab: { _, _ in }
		)
	}

	private func makeAgentRunWaitService(
		windowState: WindowState,
		beginAgentRunWait: @escaping (_ metadata: MCPServerViewModel.RequestMetadata, _ sessionIDs: Set<UUID>, _ timeoutSeconds: TimeInterval?) async -> UUID? = { _, _, _ in nil },
		endAgentRunWait: @escaping (_ token: UUID, _ completion: AgentRunWaitScopeCompletion) async -> Void = { _, _ in },
		currentSnapshotProvider: (@Sendable (_ sessionID: UUID, _ agentModeVM: AgentModeViewModel) async -> AgentRunMCPSnapshot?)? = nil
	) -> AgentRunMCPToolService {
		let metadata = MCPServerViewModel.RequestMetadata(
			connectionID: UUID(),
			clientName: "test-client",
			windowID: windowState.windowID
		)
		return AgentRunMCPToolService(
			toolName: "agent_run",
			captureRequestMetadata: { metadata },
			requireTargetWindow: { windowState },
			resolveRequestedTabID: { _ in nil },
			resolveSpawnSourceTabID: { _ in nil },
			resolveSpawnParentSessionID: { _, _ in nil },
			bindCurrentRequestToTab: { _, _ in },
			withHeartbeat: { _, _, _, _, operation in try await operation() },
			beginAgentRunWait: beginAgentRunWait,
			endAgentRunWait: endAgentRunWait,
			startRun: { _, _, _, _, _, _, _, _, _, _ in
				throw MCPError.internalError("startRun should not be used by wait/poll tests")
			},
			currentSnapshotProvider: currentSnapshotProvider
		)
	}

	private func sessionIDsValue(_ sessionIDs: [UUID]) -> Value {
		.array(sessionIDs.map { .string($0.uuidString) })
	}

	private func waitForStoreWaiter(
		sessionID: UUID,
		file: StaticString = #filePath,
		line: UInt = #line
	) async throws {
		#if DEBUG
		for _ in 0..<300 {
			if await AgentRunSessionStore.shared.test_waiterCount(sessionID: sessionID) > 0 {
				return
			}
			try await Task.sleep(nanoseconds: 10_000_000)
		}
		XCTFail("Timed out waiting for store waiter", file: file, line: line)
		#else
		try await Task.sleep(nanoseconds: 100_000_000)
		#endif
	}

	private func makeSnapshot(
		sessionID: UUID,
		tabID: UUID,
		agentRaw: String? = nil,
		modelRaw: String? = nil,
		reasoningEffortRaw: String? = nil,
		status: AgentRunMCPSnapshot.Status,
		latestAssistantPreview: String? = nil
	) -> AgentRunMCPSnapshot {
		AgentRunMCPSnapshot(
			sessionID: sessionID,
			tabID: tabID,
			sessionName: nil,
			agentRaw: agentRaw,
			agentDisplayName: nil,
			modelRaw: modelRaw,
			reasoningEffortRaw: reasoningEffortRaw,
			status: status,
			statusText: nil,
			latestAssistantPreview: latestAssistantPreview,
			interaction: nil,
			transcriptItemCount: 0,
			updatedAt: Date(),
			parentSessionID: nil,
			failureReason: nil
		)
	}

	private func assertNoWorkspaceActiveAgentSessionReferences(
		windowState: WindowState,
		sessionID: UUID,
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		let activeWorkspaceID = windowState.workspaceManager.activeWorkspace?.id
		var composeReferences: [String] = []
		var stashedReferences: [String] = []
		for workspace in windowState.workspaceManager.workspaces {
			let activeMarker = workspace.id == activeWorkspaceID ? "active" : "inactive"
			for tab in workspace.composeTabs where tab.activeAgentSessionID == sessionID {
				composeReferences.append("\(activeMarker):\(workspace.name):\(workspace.id):\(tab.name):\(tab.id)")
			}
			for stashed in workspace.stashedTabs where stashed.tab.activeAgentSessionID == sessionID {
				stashedReferences.append("\(activeMarker):\(workspace.name):\(workspace.id):\(stashed.tab.name):\(stashed.tab.id)")
			}
		}
		XCTAssertTrue(composeReferences.isEmpty, "Expected no compose tab to reference deleted agent session; refs=\(composeReferences)", file: file, line: line)
		XCTAssertTrue(stashedReferences.isEmpty, "Expected no stashed tab to reference deleted agent session; refs=\(stashedReferences)", file: file, line: line)
	}

	private func makeWindowState(root: URL, sourceTabID: UUID, isSystemWorkspace: Bool = false) -> WindowState {
		let windowState = WindowState()
		let workspace = WorkspaceModel(
			name: "Tool Service Tests",
			repoPaths: isSystemWorkspace ? [] : [root.path],
			isSystemWorkspace: isSystemWorkspace,
			customStoragePath: root,
			composeTabs: [
				ComposeTabState(
					id: sourceTabID,
					name: "Source",
					lastModified: Date(),
					activeAgentSessionID: nil
				)
			],
			activeComposeTabID: sourceTabID
		)
		windowState.workspaceManager.workspaces = [workspace]
		windowState.workspaceManager.activeWorkspace = workspace
		windowState.promptManager.loadComposeTabsFromWorkspace(workspace)
		return windowState
	}

	private func makeTempDirectory() -> URL {
		let base = FileManager.default.temporaryDirectory
		let dir = base.appendingPathComponent("RepoPrompt-AgentMCPToolServiceTests-\(UUID().uuidString)", isDirectory: true)
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir
	}
}
