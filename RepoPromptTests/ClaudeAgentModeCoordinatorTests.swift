import XCTest
import MCP
@testable import RepoPrompt

@MainActor
final class ClaudeAgentModeCoordinatorTests: XCTestCase {
	override func setUp() {
		super.setUp()
		ClaudeAgentToolPreferences.setAgentModePromptDelivery(.userMessageXML)
		ClaudeAgentToolPreferences.setEffortLevel(.medium)
	}

	func testEnsureClaudeNativeSessionCreatesControllerAndPersistsProviderSessionID() async {
		let controller = FakeClaudeController(returnedSessionID: "new-session")
		let coordinator = ClaudeAgentModeCoordinator(
			windowID: 7,
			workspacePathProvider: { "/tmp/workspace" },
			claudeControllerFactory: { _, _, _, _, _, _, _ in controller }
		)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .claudeCode
		session.providerSessionID = "old-session"

		await coordinator.ensureClaudeNativeSession(session: session)
		let snapshot = await controller.snapshot()

		XCTAssertNotNil(session.claudeController)
		XCTAssertNotNil(session.runID)
		XCTAssertEqual(session.providerSessionID, "new-session")
		XCTAssertTrue(session.isDirty)
		XCTAssertEqual(snapshot.ensureEventsStreamReadyCallCount, 1)
		XCTAssertEqual(snapshot.startOrResumeCalls.count, 1)
		XCTAssertEqual(snapshot.startOrResumeCalls.first?.existingSessionID, "old-session")
		XCTAssertNil(snapshot.startOrResumeCalls.first?.model)
		XCTAssertNil(snapshot.startOrResumeCalls.first?.systemPromptOverride)
	}

	func testEnsureClaudeNativeSessionUsesEmptySystemPromptOverrideForEmptySystemPromptMode() async {
		ClaudeAgentToolPreferences.setAgentModePromptDelivery(.userMessageXMLWithEmptySystemPrompt)
		let controller = FakeClaudeController(returnedSessionID: "new-session")
		let coordinator = ClaudeAgentModeCoordinator(
			windowID: 7,
			workspacePathProvider: { "/tmp/workspace" },
			claudeControllerFactory: { _, _, _, _, _, _, _ in controller }
		)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .claudeCode

		await coordinator.ensureClaudeNativeSession(session: session)
		let snapshot = await controller.snapshot()

		XCTAssertEqual(snapshot.startOrResumeCalls.count, 1)
		XCTAssertEqual(snapshot.startOrResumeCalls.first?.systemPromptOverride, "")
	}

	func testEnsureClaudeNativeSessionUsesRepoPromptSystemPromptOverrideForNativeSystemPromptMode() async {
		ClaudeAgentToolPreferences.setAgentModePromptDelivery(.nativeSystemPrompt)
		let controller = FakeClaudeController(returnedSessionID: "new-session")
		let coordinator = ClaudeAgentModeCoordinator(
			windowID: 7,
			workspacePathProvider: { "/tmp/workspace" },
			claudeControllerFactory: { _, _, _, _, _, _, _ in controller }
		)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .claudeCode

		await coordinator.ensureClaudeNativeSession(session: session)
		let snapshot = await controller.snapshot()
		let systemPromptOverride = snapshot.startOrResumeCalls.first?.systemPromptOverride ?? ""

		XCTAssertEqual(snapshot.startOrResumeCalls.count, 1)
		XCTAssertTrue(systemPromptOverride.contains("`set_status`"), "systemPromptOverride=\(systemPromptOverride)")
		XCTAssertTrue(systemPromptOverride.contains("session_name"), "systemPromptOverride=\(systemPromptOverride)")
		XCTAssertFalse(systemPromptOverride.contains("wait_for_next_user_instruction"), "systemPromptOverride=\(systemPromptOverride)")
	}

	func testEnsureClaudeNativeSessionPassesGLMRuntimeVariantToFactory() async {
		let controller = FakeClaudeController(returnedSessionID: "glm-session")
		var capturedVariant: ClaudeCodeRuntimeVariant?
		let coordinator = ClaudeAgentModeCoordinator(
			windowID: 7,
			workspacePathProvider: { "/tmp/workspace" },
			claudeControllerFactory: { _, _, _, _, runtimeVariant, _, _ in
				capturedVariant = runtimeVariant
				return controller
			}
		)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .claudeCodeGLM

		await coordinator.ensureClaudeNativeSession(session: session)

		XCTAssertEqual(capturedVariant, .glm)
		XCTAssertEqual(session.claudeControllerRuntimeVariant, .glm)
		XCTAssertEqual(session.providerSessionID, "glm-session")
	}

	func testEnsureClaudeNativeSessionRecyclesControllerAndClearsResumeIDWhenRuntimeVariantChanges() async {
		let existingController = FakeClaudeController(returnedSessionID: "standard-session")
		_ = await existingController.interruptTurn(reason: "make-idle")
		let replacementController = FakeClaudeController(returnedSessionID: "kimi-session")
		var capturedVariant: ClaudeCodeRuntimeVariant?
		let coordinator = ClaudeAgentModeCoordinator(
			windowID: 7,
			workspacePathProvider: { "/tmp/workspace" },
			claudeControllerFactory: { _, _, _, _, runtimeVariant, _, _ in
				capturedVariant = runtimeVariant
				return replacementController
			}
		)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .kimiCode
		session.selectedModelRaw = AgentModel.kimiCode.rawValue
		session.providerSessionID = "standard-session"
		session.claudeController = existingController
		session.claudeControllerRuntimeVariant = .standard
		session.claudeControllerPermissionMode = ClaudeAgentToolPreferences.permissionMode()

		await coordinator.ensureClaudeNativeSession(session: session)
		let existingSnapshot = await existingController.snapshot()
		let replacementSnapshot = await replacementController.snapshot()

		XCTAssertEqual(existingSnapshot.shutdownCallCount, 1)
		XCTAssertEqual(capturedVariant, .kimi)
		XCTAssertEqual(session.claudeControllerRuntimeVariant, .kimi)
		XCTAssertEqual(replacementSnapshot.startOrResumeCalls.count, 1)
		XCTAssertNil(replacementSnapshot.startOrResumeCalls.first?.existingSessionID)
		XCTAssertEqual(replacementSnapshot.startOrResumeCalls.first?.model, AgentModel.kimiCode.rawValue)
		XCTAssertEqual(session.providerSessionID, "kimi-session")
	}

	func testEnsureClaudeNativeSessionPassesEffectiveAutoPermissionModeToFactory() async {
		let originalMode = ClaudeAgentToolPreferences.permissionMode()
		defer { ClaudeAgentToolPreferences.setPermissionMode(originalMode) }
		ClaudeAgentToolPreferences.setPermissionLevel(.auto)

		let cases: [(name: String, agentKind: DiscoverAgentKind, modelRaw: String, parentSessionID: UUID?, expectedMode: String)] = [
			(
				"top-level unsupported auto falls back to acceptEdits",
				.claudeCode,
				AgentModel.claudeSonnet.rawValue,
				nil,
				ClaudeAgentToolPreferences.PermissionLevel.autoApproveEdits.permissionMode
			),
			(
				"sub-agent unsupported auto falls back to bypassPermissions",
				.claudeCode,
				AgentModel.claudeSonnet.rawValue,
				UUID(),
				ClaudeAgentToolPreferences.PermissionLevel.fullAccess.permissionMode
			),
			(
				"Opus Latest keeps auto",
				.claudeCode,
				AgentModel.claudeOpus.rawValue,
				nil,
				ClaudeAgentToolPreferences.PermissionLevel.auto.permissionMode
			),
			(
				"compatible Claude backend with Opus falls back to acceptEdits",
				.claudeCodeGLM,
				AgentModel.claudeOpus.rawValue,
				nil,
				ClaudeAgentToolPreferences.PermissionLevel.autoApproveEdits.permissionMode
			)
		]

		for testCase in cases {
			let controller = FakeClaudeController(returnedSessionID: "session")
			var capturedPermissionMode: String?
			let coordinator = ClaudeAgentModeCoordinator(
				windowID: 7,
				workspacePathProvider: { "/tmp/workspace" },
				claudeControllerFactory: { _, _, _, _, _, _, permissionMode in
					capturedPermissionMode = permissionMode
					return controller
				}
			)
			let session = AgentModeViewModel.TabSession(tabID: UUID())
			session.selectedAgent = testCase.agentKind
			session.selectedModelRaw = testCase.modelRaw
			session.parentSessionID = testCase.parentSessionID

			await coordinator.ensureClaudeNativeSession(session: session)

			XCTAssertEqual(capturedPermissionMode, testCase.expectedMode, testCase.name)
			XCTAssertEqual(session.claudeControllerPermissionMode, testCase.expectedMode, testCase.name)
		}
	}

	func testEnsureClaudeNativeSessionRecyclesWhenEffectiveAutoFallbackChangesForModel() async {
		let originalMode = ClaudeAgentToolPreferences.permissionMode()
		defer { ClaudeAgentToolPreferences.setPermissionMode(originalMode) }
		ClaudeAgentToolPreferences.setPermissionLevel(.auto)

		let existingController = FakeClaudeController(returnedSessionID: "old-session")
		_ = await existingController.interruptTurn(reason: "make-idle")
		let replacementController = FakeClaudeController(returnedSessionID: "new-session")
		var capturedPermissionMode: String?
		let coordinator = ClaudeAgentModeCoordinator(
			windowID: 7,
			workspacePathProvider: { "/tmp/workspace" },
			claudeControllerFactory: { _, _, _, _, _, _, permissionMode in
				capturedPermissionMode = permissionMode
				return replacementController
			}
		)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .claudeCode
		session.selectedModelRaw = AgentModel.claudeSonnet.rawValue
		session.claudeController = existingController
		session.claudeControllerPermissionMode = ClaudeAgentToolPreferences.PermissionLevel.auto.permissionMode

		await coordinator.ensureClaudeNativeSession(session: session)
		let existingSnapshot = await existingController.snapshot()
		let replacementSnapshot = await replacementController.snapshot()

		XCTAssertEqual(existingSnapshot.shutdownCallCount, 1)
		XCTAssertEqual(replacementSnapshot.startOrResumeCalls.count, 1)
		XCTAssertEqual(capturedPermissionMode, ClaudeAgentToolPreferences.PermissionLevel.autoApproveEdits.permissionMode)
		XCTAssertEqual(session.claudeControllerPermissionMode, ClaudeAgentToolPreferences.PermissionLevel.autoApproveEdits.permissionMode)
	}

	func testApplyCurrentClaudeModelAndEffortUsesSessionModelAndPreference() async {
		let restoreDefaults = preserveUserDefaults(keys: [
			"claudeCodeEffortLevel",
			"claudeCodeEffortLevelsByModelSlug"
		])
		defer { restoreDefaults() }
		let defaults = UserDefaults.standard
		ClaudeAgentToolPreferences.setEffortLevel(.low, defaults: defaults)
		defaults.removeObject(forKey: "claudeCodeEffortLevelsByModelSlug")
		ClaudeAgentToolPreferences.setEffortLevel(
			.high,
			forModelRaw: AgentModel.claudeOpus.rawValue,
			agentKind: .claudeCode,
			defaults: defaults
		)
		let controller = FakeClaudeController(returnedSessionID: "session")
		let coordinator = ClaudeAgentModeCoordinator(
			windowID: 7,
			workspacePathProvider: { "/tmp/workspace" },
			claudeControllerFactory: { _, _, _, _, _, _, _ in controller }
		)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .claudeCode
		session.selectedModelRaw = AgentModel.claudeOpus.rawValue
		session.claudeController = controller

		await coordinator.applyCurrentClaudeModelAndEffortIfPossible(for: session, reason: "test")
		let snapshot = await controller.snapshot()

		XCTAssertEqual(snapshot.applyModelAndEffortCalls.count, 1)
		XCTAssertEqual(snapshot.applyModelAndEffortCalls.first?.model, AgentModel.claudeOpus.rawValue)
		XCTAssertEqual(snapshot.applyModelAndEffortCalls.first?.effortLevel, .high)
	}

	func testClaudeRawEventLoggingIsUserDefaultsControlledAndDefaultOff() {
		let key = "claudeRawEventLoggingEnabled"
		let restoreDefaults = preserveUserDefaults(keys: [key])
		defer { restoreDefaults() }
		let defaults = UserDefaults.standard

		defaults.removeObject(forKey: key)
		XCTAssertFalse(ClaudeNativeProcessSessionController.test_isRawEventFileLoggingEnabled())

		defaults.set(true, forKey: key)
		XCTAssertTrue(ClaudeNativeProcessSessionController.test_isRawEventFileLoggingEnabled())

		defaults.set(false, forKey: key)
		XCTAssertFalse(ClaudeNativeProcessSessionController.test_isRawEventFileLoggingEnabled())
	}

	func testEnsureClaudeNativeSessionPassesModelSpecificEffortToStartOrResume() async {
		let restoreDefaults = preserveUserDefaults(keys: [
			"claudeCodeEffortLevel",
			"claudeCodeEffortLevelsByModelSlug"
		])
		defer { restoreDefaults() }
		let defaults = UserDefaults.standard
		ClaudeAgentToolPreferences.setEffortLevel(.medium, defaults: defaults)
		defaults.removeObject(forKey: "claudeCodeEffortLevelsByModelSlug")
		ClaudeAgentToolPreferences.setEffortLevel(
			.xhigh,
			forModelRaw: AgentModel.claudeOpus.rawValue,
			agentKind: .claudeCode,
			defaults: defaults
		)
		let controller = FakeClaudeController(returnedSessionID: "session")
		let coordinator = ClaudeAgentModeCoordinator(
			windowID: 7,
			workspacePathProvider: { "/tmp/workspace" },
			claudeControllerFactory: { _, _, _, _, _, _, _ in controller }
		)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .claudeCode
		session.selectedModelRaw = AgentModel.claudeOpus.rawValue

		await coordinator.ensureClaudeNativeSession(session: session)
		let snapshot = await controller.snapshot()

		XCTAssertEqual(snapshot.startOrResumeCalls.count, 1)
		XCTAssertEqual(snapshot.startOrResumeCalls.first?.model, AgentModel.claudeOpus.rawValue)
		XCTAssertEqual(snapshot.startOrResumeCalls.first?.effortLevel, .xhigh)
	}

	func testApplyCurrentClaudeModelAndEffortNoOpsForNonNativeClaudeSession() async {
		ClaudeAgentToolPreferences.setEffortLevel(.low)
		let controller = FakeClaudeController(returnedSessionID: "session")
		let coordinator = ClaudeAgentModeCoordinator(
			windowID: 7,
			workspacePathProvider: { "/tmp/workspace" },
			claudeControllerFactory: { _, _, _, _, _, _, _ in controller }
		)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec
		session.selectedModelRaw = AgentModel.claudeOpus.rawValue
		session.claudeController = controller

		await coordinator.applyCurrentClaudeModelAndEffortIfPossible(for: session, reason: "test")
		let snapshot = await controller.snapshot()

		XCTAssertTrue(snapshot.applyModelAndEffortCalls.isEmpty)
	}

	func testEnsureClaudeNativeSessionDoesNotForceNativeBashOffForExploreRole() async {
		let controller = FakeClaudeController(returnedSessionID: "explore-session")
		var capturedAllowNativeBashTool: Bool?
		let coordinator = ClaudeAgentModeCoordinator(
			windowID: 7,
			workspacePathProvider: { "/tmp/workspace" },
			claudeControllerFactory: { _, _, _, _, _, allowNativeBashTool, _ in
				capturedAllowNativeBashTool = allowNativeBashTool
				return controller
			}
		)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .claudeCode
		session.mcpControlContext = AgentModeViewModel.AgentMCPControlContext(
			sessionID: UUID(),
			activationID: UUID(),
			originatingConnectionID: nil,
			interactionTransport: .mcp(sessionID: UUID(), originatingConnectionID: nil),
			suppressUserNotifications: true,
			forceAutoEditEnabled: true,
			autoEditEnabledBeforeOverride: true,
			taskLabelKind: .explore
		)

		await coordinator.ensureClaudeNativeSession(session: session)

		XCTAssertNil(capturedAllowNativeBashTool)
		XCTAssertEqual(session.providerSessionID, "explore-session")
	}

	func testEnsureClaudeNativeSessionRetriesWithoutResumeWhenStaleSessionFailsToStart() async {
		let staleController = FakeClaudeController(
			returnedSessionID: nil,
			startOrResumeErrors: [.processNotRunning]
		)
		let freshController = FakeClaudeController(returnedSessionID: "fresh-session")
		var factoryCalls = 0
		var capturedAllowNativeBashTools: [Bool?] = []
		let coordinator = ClaudeAgentModeCoordinator(
			windowID: 7,
			workspacePathProvider: { "/tmp/workspace" },
			claudeControllerFactory: { _, _, _, _, _, allowNativeBashTool, _ in
				factoryCalls += 1
				capturedAllowNativeBashTools.append(allowNativeBashTool)
				return factoryCalls == 1 ? staleController : freshController
			}
		)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .claudeCode
		session.providerSessionID = "stale-session"
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

		await coordinator.ensureClaudeNativeSession(session: session)
		let staleSnapshot = await staleController.snapshot()
		let freshSnapshot = await freshController.snapshot()

		XCTAssertEqual(factoryCalls, 2, "Expected controller recreation for fresh fallback start")
		XCTAssertEqual(capturedAllowNativeBashTools.count, 2)
		XCTAssertTrue(capturedAllowNativeBashTools.allSatisfy { $0 == nil })
		XCTAssertEqual(staleSnapshot.startOrResumeCalls.count, 1)
		XCTAssertEqual(staleSnapshot.startOrResumeCalls.first?.existingSessionID, "stale-session")
		XCTAssertEqual(freshSnapshot.ensureEventsStreamReadyCallCount, 0)
		XCTAssertEqual(freshSnapshot.startOrResumeCalls.count, 1)
		XCTAssertNil(freshSnapshot.startOrResumeCalls.first?.existingSessionID)
		XCTAssertEqual(session.providerSessionID, "fresh-session")
		XCTAssertEqual(session.runState, .idle)
		XCTAssertFalse(session.items.contains(where: { $0.kind == .error }))
	}

	func testEnsureClaudeNativeSessionRetriesWithoutResumeForResumeHandshakeFailures() async {
		let resumeFailures: [(String, ClaudeNativeProcessSessionController.ControllerError)] = [
			("initializationFailed", .initializationFailed("resume session missing")),
			("invalidControlResponse", .invalidControlResponse("invalid resume session")),
			("controlRequestTimedOut", .controlRequestTimedOut(requestID: "initialize"))
		]

		for (label, error) in resumeFailures {
			let staleController = FakeClaudeController(
				returnedSessionID: nil,
				startOrResumeErrors: [error]
			)
			let freshController = FakeClaudeController(returnedSessionID: "fresh-session")
			var factoryCalls = 0
			let coordinator = ClaudeAgentModeCoordinator(
				windowID: 7,
				workspacePathProvider: { "/tmp/workspace" },
				claudeControllerFactory: { _, _, _, _, _, _, _ in
					factoryCalls += 1
					return factoryCalls == 1 ? staleController : freshController
				}
			)
			let session = AgentModeViewModel.TabSession(tabID: UUID())
			session.selectedAgent = .claudeCode
			session.providerSessionID = "stale-session"

			await coordinator.ensureClaudeNativeSession(session: session)
			let staleSnapshot = await staleController.snapshot()
			let freshSnapshot = await freshController.snapshot()

			XCTAssertEqual(factoryCalls, 2, "Expected fallback fresh start for \(label)")
			XCTAssertEqual(staleSnapshot.startOrResumeCalls.count, 1, "Expected one failed resume attempt for \(label)")
			XCTAssertEqual(freshSnapshot.startOrResumeCalls.count, 1, "Expected one fresh start after \(label)")
			XCTAssertNil(freshSnapshot.startOrResumeCalls.first?.existingSessionID, "Fresh retry should clear stale session ID for \(label)")
			XCTAssertEqual(session.providerSessionID, "fresh-session", "Expected fresh session ID after \(label)")
			XCTAssertFalse(session.items.contains(where: { $0.kind == .error }), "Fallback should avoid surfacing a start error for \(label)")
		}
	}

	func testSendClaudeNativeMessageStagesResumeRecoveryHandoffAndPrefixesNextSend() async {
		let staleController = FakeClaudeController(
			returnedSessionID: nil,
			startOrResumeErrors: [.processNotRunning]
		)
		let freshController = FakeClaudeController(returnedSessionID: "fresh-session")
		var factoryCalls = 0
		let coordinator = ClaudeAgentModeCoordinator(
			windowID: 7,
			workspacePathProvider: { "/tmp/workspace" },
			claudeControllerFactory: { _, _, _, _, _, _, _ in
				factoryCalls += 1
				return factoryCalls == 1 ? staleController : freshController
			}
		)
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath,
			codexControllerFactory: { _, _, _, _, _, _ in StubCodexController() }
		)
		coordinator.attach(viewModel: vm)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .claudeCode
		session.providerSessionID = "stale-session"
		session.appendItem(.user("Question before restart", sequenceIndex: session.nextSequenceIndex))
		session.appendItem(.assistant("Answer before restart", sequenceIndex: session.nextSequenceIndex))

		let sent = await coordinator.sendClaudeNativeMessage(
			session: session,
			text: "Continue from here",
			attachments: []
		)
		let freshSnapshot = await freshController.snapshot()

		XCTAssertTrue(sent)
		XCTAssertEqual(factoryCalls, 2)
		let sentText = freshSnapshot.sendUserMessages.first ?? ""
		XCTAssertTrue(sentText.contains("<claude_code_instructions>"), "sentText=\(sentText)")
		XCTAssertTrue(sentText.contains("`set_status`"), "sentText=\(sentText)")
		XCTAssertTrue(sentText.contains("<forked_session source=\""), "sentText=\(sentText)")
		XCTAssertTrue(sentText.contains("delivery_id=\""), "sentText=\(sentText)")
		XCTAssertTrue(sentText.contains("restarted after a native resume failed"), "sentText=\(sentText)")
		XCTAssertTrue(sentText.contains("<transcript>"), "sentText=\(sentText)")
		XCTAssertTrue(sentText.contains("Continue from here"), "sentText=\(sentText)")
		XCTAssertTrue(session.pendingHandoff.isStagedForSend)
		XCTAssertFalse(session.items.contains(where: { $0.kind == .error }))
	}

	func testEnsureClaudeNativeSessionSkipsWhenSelectedAgentIsNotClaude() async {
		let controller = FakeClaudeController(returnedSessionID: "unused")
		let coordinator = ClaudeAgentModeCoordinator(
			windowID: 7,
			workspacePathProvider: { "/tmp/workspace" },
			claudeControllerFactory: { _, _, _, _, _, _, _ in controller }
		)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec

		await coordinator.ensureClaudeNativeSession(session: session)
		let snapshot = await controller.snapshot()

		XCTAssertNil(session.claudeController)
		XCTAssertEqual(snapshot.startOrResumeCalls.count, 0)
		XCTAssertEqual(snapshot.ensureEventsStreamReadyCallCount, 0)
	}

	func testSubmitApprovalDecisionRoutesToControllerAndClearsPendingApproval() async {
		let controller = FakeClaudeController(returnedSessionID: "session")
		let coordinator = ClaudeAgentModeCoordinator(
			windowID: 7,
			workspacePathProvider: { "/tmp/workspace" },
			claudeControllerFactory: { _, _, _, _, _, _, _ in controller }
		)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .claudeCode
		session.claudeController = controller
		session.runState = .waitingForApproval
		session.pendingApproval = AgentApprovalRequest(
			requestID: .claudeControl("perm-1"),
			method: "control/can_use_tool",
			kind: .commandExecution,
			threadID: "thread",
			turnID: "turn",
			itemID: "item",
			command: "pwd"
		)

		coordinator.submitApprovalDecision(session: session, decision: .acceptForSession)
		let didRespond = await waitForCondition(timeoutSeconds: 1.0) {
			let snapshot = await controller.snapshot()
			return snapshot.respondedPermissionRequests.count == 1
		}
		let snapshot = await controller.snapshot()

		XCTAssertTrue(didRespond)
		XCTAssertNil(session.pendingApproval)
		XCTAssertEqual(session.runState, .running)
		XCTAssertEqual(snapshot.respondedPermissionRequests.first?.id, "perm-1")
		XCTAssertEqual(snapshot.respondedPermissionRequests.first?.decision, .acceptForSession)
	}

	func testCancelClaudeRunCallsControllerCancelAndShutdown() async {
		let controller = FakeClaudeController(returnedSessionID: "session")
		let coordinator = ClaudeAgentModeCoordinator(
			windowID: 7,
			workspacePathProvider: { "/tmp/workspace" },
			claudeControllerFactory: { _, _, _, _, _, _, _ in controller }
		)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .claudeCode
		session.claudeController = controller

		// Step 1: prepareClaudeCancelSync nils the controller immediately.
		let oldController = coordinator.prepareClaudeCancelSync(session)
		XCTAssertNotNil(oldController, "prepareClaudeCancelSync should return the old controller")
		XCTAssertNil(session.claudeController, "Controller must be nil'd immediately for race safety")

		// Step 2: cancelClaudeRun does async interrupt + shutdown.
		await coordinator.cancelClaudeRun(session, oldController: oldController)
		let snapshot = await controller.snapshot()
		XCTAssertEqual(snapshot.interruptTurnCallCount, 1)
		XCTAssertEqual(snapshot.interruptTurnReasons, ["interrupt"])
		XCTAssertEqual(snapshot.shutdownCallCount, 1)
	}

	func testAwaitPendingClaudeResumeTransferPersistsTransferredSessionID() async {
		let coordinator = ClaudeAgentModeCoordinator(
			windowID: 7,
			workspacePathProvider: { "/tmp/workspace" },
			claudeControllerFactory: { _, _, _, _, _, _, _ in FakeClaudeController(returnedSessionID: nil) }
		)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .claudeCode
		session.pendingClaudeResumeTransferTask = Task {
			ClaudeNativeProcessSessionController.SessionRef(sessionID: "transferred-session")
		}

		await coordinator.awaitPendingClaudeResumeTransferIfNeeded(for: session)

		XCTAssertEqual(session.providerSessionID, "transferred-session")
		XCTAssertNil(session.pendingClaudeResumeTransferTask)
		XCTAssertTrue(session.isDirty)
	}

	func testEnsureClaudeNativeSessionAwaitsPendingResumeTransferBeforeResume() async {
		let freshController = FakeClaudeController(returnedSessionID: nil)
		let coordinator = ClaudeAgentModeCoordinator(
			windowID: 7,
			workspacePathProvider: { "/tmp/workspace" },
			claudeControllerFactory: { _, _, _, _, _, _, _ in freshController }
		)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .claudeCode
		session.pendingClaudeResumeTransferTask = Task {
			try? await Task.sleep(nanoseconds: 50_000_000)
			return ClaudeNativeProcessSessionController.SessionRef(sessionID: "transferred-session")
		}

		await coordinator.ensureClaudeNativeSession(session: session)
		let snapshot = await freshController.snapshot()

		XCTAssertEqual(snapshot.startOrResumeCalls.count, 1)
		XCTAssertEqual(snapshot.startOrResumeCalls.first?.existingSessionID, "transferred-session")
		XCTAssertEqual(session.providerSessionID, "transferred-session")
		XCTAssertNil(session.pendingClaudeResumeTransferTask)
	}

	func testImmediateFollowUpAfterCancelUsesTransferredSessionID() async {
		let staleController = FakeClaudeController(
			returnedSessionID: nil,
			currentSessionID: "live-session"
		)
		let freshController = FakeClaudeController(returnedSessionID: nil)
		let coordinator = ClaudeAgentModeCoordinator(
			windowID: 7,
			workspacePathProvider: { "/tmp/workspace" },
			claudeControllerFactory: { _, _, _, _, _, _, _ in freshController }
		)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .claudeCode
		session.claudeController = staleController
		session.runID = UUID()

		let oldController = coordinator.prepareClaudeCancelSync(session)
		coordinator.beginClaudeResumeTransferIfNeeded(for: session, oldController: oldController)
		await coordinator.ensureClaudeNativeSession(session: session)

		let staleSnapshot = await staleController.snapshot()
		let freshSnapshot = await freshController.snapshot()
		XCTAssertEqual(staleSnapshot.interruptTurnCallCount, 1)
		XCTAssertEqual(staleSnapshot.shutdownCallCount, 1)
		XCTAssertEqual(freshSnapshot.startOrResumeCalls.count, 1)
		XCTAssertEqual(freshSnapshot.startOrResumeCalls.first?.existingSessionID, "live-session")
		XCTAssertEqual(session.providerSessionID, "live-session")
		XCTAssertNil(session.pendingClaudeResumeTransferTask)
	}

	func testSendClaudeNativeMessageInterruptsBeforeSendingMessage() async {
		let controller = FakeClaudeController(returnedSessionID: "session")
		let coordinator = ClaudeAgentModeCoordinator(
			windowID: 7,
			workspacePathProvider: { "/tmp/workspace" },
			claudeControllerFactory: { _, _, _, _, _, _, _ in controller }
		)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .claudeCode
		session.claudeController = controller
		session.runState = .running

		let sent = await coordinator.sendClaudeNativeMessage(
			session: session,
			text: "steer now",
			attachments: []
		)
		let snapshot = await controller.snapshot()

		XCTAssertTrue(sent)
		XCTAssertEqual(snapshot.interruptTurnCallCount, 1)
		XCTAssertEqual(snapshot.interruptTurnReasons, ["interrupt"])
		let sentText = snapshot.sendUserMessages.first ?? ""
		XCTAssertEqual(snapshot.sendUserMessages.count, 1)
		XCTAssertTrue(sentText.contains("<claude_code_instructions>"), "sentText=\(sentText)")
		XCTAssertTrue(sentText.contains("`set_status`"), "sentText=\(sentText)")
		XCTAssertTrue(sentText.hasSuffix("steer now"), "sentText=\(sentText)")
	}

	func testSendClaudeNativeMessageStillInjectsInstructionsWhenEmptySystemPromptModeEnabled() async {
		ClaudeAgentToolPreferences.setAgentModePromptDelivery(.userMessageXMLWithEmptySystemPrompt)
		let controller = FakeClaudeController(returnedSessionID: "session")
		let coordinator = ClaudeAgentModeCoordinator(
			windowID: 7,
			workspacePathProvider: { "/tmp/workspace" },
			claudeControllerFactory: { _, _, _, _, _, _, _ in controller }
		)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .claudeCode
		session.claudeController = controller

		let sent = await coordinator.sendClaudeNativeMessage(
			session: session,
			text: "plain steering",
			attachments: []
		)
		let snapshot = await controller.snapshot()
		let sentText = snapshot.sendUserMessages.first ?? ""

		XCTAssertTrue(sent)
		XCTAssertEqual(snapshot.sendUserMessages.count, 1)
		XCTAssertTrue(sentText.contains("<claude_code_instructions>"), "sentText=\(sentText)")
		XCTAssertTrue(sentText.contains("`set_status`"), "sentText=\(sentText)")
		XCTAssertTrue(sentText.hasSuffix("plain steering"), "sentText=\(sentText)")
	}

	func testSendClaudeNativeMessageLeavesUserMessagePlainForNativeSystemPromptMode() async {
		ClaudeAgentToolPreferences.setAgentModePromptDelivery(.nativeSystemPrompt)
		let controller = FakeClaudeController(returnedSessionID: "session")
		let coordinator = ClaudeAgentModeCoordinator(
			windowID: 7,
			workspacePathProvider: { "/tmp/workspace" },
			claudeControllerFactory: { _, _, _, _, _, _, _ in controller }
		)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .claudeCode
		session.claudeController = controller

		let sent = await coordinator.sendClaudeNativeMessage(
			session: session,
			text: "plain steering",
			attachments: []
		)
		let snapshot = await controller.snapshot()

		XCTAssertTrue(sent)
		XCTAssertEqual(snapshot.sendUserMessages, ["plain steering"])
	}

	func testSendClaudeNativeMessageWaitsForProviderAckParityBeforeInterrupting() async {
		let controller = FakeClaudeController(returnedSessionID: "session")
		let coordinator = ClaudeAgentModeCoordinator(
			windowID: 7,
			workspacePathProvider: { "/tmp/workspace" },
			claudeControllerFactory: { _, _, _, _, _, _, _ in controller },
			awaitNoActiveMCPTools: { _ in },
			toolEndedCount: { _ in 1 },
			hasActiveMCPTools: { _ in false }
		)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		let runID = UUID()
		session.selectedAgent = .claudeCode
		session.runID = runID
		session.claudeController = controller
		session.runState = .running
		await ServerNetworkManager.shared.unregisterToolObservers(for: runID)
		await coordinator.ensureClaudeToolTrackingIfNeeded(for: session, runID: runID)

		let sendTask = Task { @MainActor in
			await coordinator.sendClaudeNativeMessage(
				session: session,
				text: "steer after ack",
				attachments: []
			)
		}

		let stayedBlocked = await waitForCondition(timeoutSeconds: 0.25) {
			let snapshot = await controller.snapshot()
			return snapshot.interruptTurnCallCount == 0 && snapshot.sendUserMessages.isEmpty
		}
		XCTAssertTrue(stayedBlocked)

		coordinator.handleToolStreamEvent(
			.toolResult(
				.init(
					toolName: "mcp__RepoPrompt__context_builder",
					invocationID: UUID(),
					argsJSON: nil,
					resultJSON: #"{"status":"ok"}"#,
					isError: false
				)
			),
			session: session
		)

		let sent = await sendTask.value
		let snapshot = await controller.snapshot()
		await coordinator.shutdownClaudeSession(session)

		XCTAssertTrue(sent)
		XCTAssertEqual(snapshot.interruptTurnCallCount, 1)
		let sentText = snapshot.sendUserMessages.first ?? ""
		XCTAssertEqual(snapshot.sendUserMessages.count, 1)
		XCTAssertTrue(sentText.contains("<claude_code_instructions>"), "sentText=\(sentText)")
		XCTAssertTrue(sentText.hasSuffix("steer after ack"), "sentText=\(sentText)")
	}

	func testSendClaudeNativeMessagePreservesProviderAckStateAcrossTurnReset() async {
		let controller = FakeClaudeController(returnedSessionID: "session")
		let coordinator = ClaudeAgentModeCoordinator(
			windowID: 7,
			workspacePathProvider: { "/tmp/workspace" },
			claudeControllerFactory: { _, _, _, _, _, _, _ in controller },
			awaitNoActiveMCPTools: { _ in },
			toolEndedCount: { _ in 1 },
			hasActiveMCPTools: { _ in false }
		)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		let runID = UUID()
		session.selectedAgent = .claudeCode
		session.runID = runID
		session.claudeController = controller
		session.runState = .running
		await ServerNetworkManager.shared.unregisterToolObservers(for: runID)
		await coordinator.ensureClaudeToolTrackingIfNeeded(for: session, runID: runID)

		coordinator.handleToolStreamEvent(
			.toolResult(
				.init(
					toolName: "mcp__RepoPrompt__ask_oracle",
					invocationID: UUID(),
					argsJSON: nil,
					resultJSON: #"{"status":"ok"}"#,
					isError: false
				)
			),
			session: session
		)

		let sent = await coordinator.sendClaudeNativeMessage(
			session: session,
			text: "use existing ack",
			attachments: []
		)
		let snapshot = await controller.snapshot()
		await coordinator.shutdownClaudeSession(session)

		XCTAssertTrue(sent)
		XCTAssertEqual(snapshot.interruptTurnCallCount, 1)
		let sentText = snapshot.sendUserMessages.first ?? ""
		XCTAssertEqual(snapshot.sendUserMessages.count, 1)
		XCTAssertTrue(sentText.contains("<claude_code_instructions>"), "sentText=\(sentText)")
		XCTAssertTrue(sentText.hasSuffix("use existing ack"), "sentText=\(sentText)")
	}

	func testSendClaudeNativeMessageAllowsInterruptWhenProviderAckLagsButLocalMCPIdle() async {
		let controller = FakeClaudeController(returnedSessionID: "session")
		let coordinator = ClaudeAgentModeCoordinator(
			windowID: 7,
			workspacePathProvider: { "/tmp/workspace" },
			claudeControllerFactory: { _, _, _, _, _, _, _ in controller },
			awaitNoActiveMCPTools: { _ in },
			toolEndedCount: { _ in 1 },
			hasActiveMCPTools: { _ in false }
		)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		let runID = UUID()
		session.selectedAgent = .claudeCode
		session.runID = runID
		session.claudeController = controller
		session.runState = .running
		await ServerNetworkManager.shared.unregisterToolObservers(for: runID)
		await coordinator.ensureClaudeToolTrackingIfNeeded(for: session, runID: runID)

		let sent = await coordinator.sendClaudeNativeMessage(
			session: session,
			text: "steer after idle ack lag",
			attachments: []
		)
		let snapshot = await controller.snapshot()
		await coordinator.shutdownClaudeSession(session)

		XCTAssertTrue(sent)
		XCTAssertEqual(snapshot.interruptTurnCallCount, 1)
		let sentText = snapshot.sendUserMessages.first ?? ""
		XCTAssertEqual(snapshot.sendUserMessages.count, 1)
		XCTAssertTrue(sentText.contains("<claude_code_instructions>"), "sentText=\(sentText)")
		XCTAssertTrue(sentText.hasSuffix("steer after idle ack lag"), "sentText=\(sentText)")
	}

	func testSendClaudeNativeMessageWaitsForChildAgentRunWaitScopesBeforeInterrupting() async {
		let controller = FakeClaudeController(returnedSessionID: "session")
		let childWaitGate = CoordinatorChildAgentWaitGate()
		let coordinator = ClaudeAgentModeCoordinator(
			windowID: 7,
			workspacePathProvider: { "/tmp/workspace" },
			claudeControllerFactory: { _, _, _, _, _, _, _ in controller },
			awaitNoActiveMCPTools: { _ in },
			toolEndedCount: { _ in 0 },
			hasActiveMCPTools: { _ in false },
			hasActiveChildAgentRunWaits: { _ in childWaitGate.recordQueryAndReturnIsActive() },
			steeringInterruptSafePointTimeoutSeconds: 5.0
		)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		let runID = UUID()
		session.selectedAgent = .claudeCode
		session.runID = runID
		session.claudeController = controller
		session.runState = .running

		let sendTask = Task { @MainActor in
			await coordinator.sendClaudeNativeMessage(
				session: session,
				text: "wait for child scope",
				attachments: []
			)
		}

		let observedChildWaitGate = await waitForCondition(timeoutSeconds: 1.0) {
			childWaitGate.queryCallCount > 0
		}
		XCTAssertTrue(observedChildWaitGate, "Expected Claude safe point to consult child agent_run wait scopes")
		try? await Task.sleep(nanoseconds: 100_000_000)
		let blockedSnapshot = await controller.snapshot()
		XCTAssertEqual(blockedSnapshot.interruptTurnCallCount, 0)
		XCTAssertTrue(blockedSnapshot.sendUserMessages.isEmpty)

		childWaitGate.isActive = false
		let sent = await sendTask.value
		let snapshot = await controller.snapshot()
		await coordinator.shutdownClaudeSession(session)

		XCTAssertTrue(sent)
		XCTAssertEqual(snapshot.interruptTurnCallCount, 1)
		XCTAssertEqual(snapshot.sendUserMessages.count, 1)
		XCTAssertTrue(snapshot.sendUserMessages.first?.contains("wait for child scope") == true)
	}

	func testSendClaudeNativeMessageFailsClosedWhileChildAgentRunWaitScopesRemainActive() async {
		let controller = FakeClaudeController(returnedSessionID: "session")
		let coordinator = ClaudeAgentModeCoordinator(
			windowID: 7,
			workspacePathProvider: { "/tmp/workspace" },
			claudeControllerFactory: { _, _, _, _, _, _, _ in controller },
			awaitNoActiveMCPTools: { _ in },
			toolEndedCount: { _ in 0 },
			hasActiveMCPTools: { _ in false },
			hasActiveChildAgentRunWaits: { _ in true },
			steeringInterruptSafePointTimeoutSeconds: 0.05
		)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .claudeCode
		session.runID = UUID()
		session.claudeController = controller
		session.runState = .running

		let sent = await coordinator.sendClaudeNativeMessage(
			session: session,
			text: "must not interrupt",
			attachments: []
		)
		let snapshot = await controller.snapshot()
		await coordinator.shutdownClaudeSession(session)

		XCTAssertFalse(sent)
		XCTAssertEqual(snapshot.interruptTurnCallCount, 0)
		XCTAssertTrue(snapshot.sendUserMessages.isEmpty)
	}

	func testSendClaudeNativeMessageFailsClosedWhenProviderAckParityTimesOutAndMCPStillActive() async {
		let controller = FakeClaudeController(returnedSessionID: "session")
		let coordinator = ClaudeAgentModeCoordinator(
			windowID: 7,
			workspacePathProvider: { "/tmp/workspace" },
			claudeControllerFactory: { _, _, _, _, _, _, _ in controller },
			awaitNoActiveMCPTools: { _ in },
			toolEndedCount: { _ in 1 },
			hasActiveMCPTools: { _ in true }
		)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		let runID = UUID()
		session.selectedAgent = .claudeCode
		session.runID = runID
		session.claudeController = controller
		session.runState = .running
		await ServerNetworkManager.shared.unregisterToolObservers(for: runID)
		await coordinator.ensureClaudeToolTrackingIfNeeded(for: session, runID: runID)

		let sent = await coordinator.sendClaudeNativeMessage(
			session: session,
			text: "should time out",
			attachments: []
		)
		let snapshot = await controller.snapshot()
		await coordinator.shutdownClaudeSession(session)

		XCTAssertFalse(sent)
		XCTAssertEqual(snapshot.interruptTurnCallCount, 0)
		XCTAssertTrue(snapshot.sendUserMessages.isEmpty)
	}

	func testShutdownClaudeSessionNilsControllerAfterShutdownCall() async {
		let controller = FakeClaudeController(returnedSessionID: "session")
		let coordinator = ClaudeAgentModeCoordinator(
			windowID: 7,
			workspacePathProvider: { "/tmp/workspace" },
			claudeControllerFactory: { _, _, _, _, _, _, _ in controller }
		)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .claudeCode
		session.claudeController = controller

		await coordinator.shutdownClaudeSession(session)
		let snapshot = await controller.snapshot()

		XCTAssertNil(session.claudeController)
		XCTAssertEqual(snapshot.shutdownCallCount, 1)
	}

	func testEnsureClaudeToolTrackingRegistersToolEventObserver() async {
		let controller = FakeClaudeController(returnedSessionID: nil)
		let coordinator = ClaudeAgentModeCoordinator(
			windowID: 7,
			workspacePathProvider: { "/tmp/workspace" },
			claudeControllerFactory: { _, _, _, _, _, _, _ in controller }
		)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		let runID = UUID()
		await ServerNetworkManager.shared.unregisterToolObservers(for: runID)

		await coordinator.ensureClaudeToolTrackingIfNeeded(for: session, runID: runID)

		let registered = await waitForCondition(timeoutSeconds: 1.0) {
			await ServerNetworkManager.shared.toolEventObserverCount(for: runID) == 1
		}
		XCTAssertTrue(registered)

		await coordinator.shutdownClaudeSession(session)
		let observersCleared = await waitForCondition(timeoutSeconds: 1.0) {
			await ServerNetworkManager.shared.toolEventObserverCount(for: runID) == 0
		}
		XCTAssertTrue(observersCleared)
	}

	func testShutdownClaudeSessionClearsToolTrackingStateAndObservers() async {
		let controller = FakeClaudeController(returnedSessionID: nil)
		let coordinator = ClaudeAgentModeCoordinator(
			windowID: 7,
			workspacePathProvider: { "/tmp/workspace" },
			claudeControllerFactory: { _, _, _, _, _, _, _ in controller }
		)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		let runID = UUID()
		await ServerNetworkManager.shared.unregisterToolObservers(for: runID)

		await coordinator.ensureClaudeToolTrackingIfNeeded(for: session, runID: runID)
		_ = await waitForCondition(timeoutSeconds: 1.0) {
			await ServerNetworkManager.shared.toolEventObserverCount(for: runID) == 1
		}

		await coordinator.shutdownClaudeSession(session)

		let observersCleared = await waitForCondition(timeoutSeconds: 1.0) {
			await ServerNetworkManager.shared.toolEventObserverCount(for: runID) == 0
		}
		XCTAssertTrue(observersCleared)
	}

	func testProviderRepoPromptToolCallLateAfterToolResultInTurnIsSuppressed() {
		let coordinator = ClaudeAgentModeCoordinator(
			windowID: 7,
			workspacePathProvider: { "/tmp/workspace" },
			claudeControllerFactory: { _, _, _, _, _, _, _ in FakeClaudeController(returnedSessionID: nil) }
		)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .claudeCode
		coordinator.resetToolCorrelation(for: session)
		let argsJSON = #"{"path":"README.md"}"#
		var existingResult = AgentChatItem.toolResult(
			name: "read_file",
			invocationID: UUID(),
			resultJSON: #"{"status":"ok"}"#,
			isError: false,
			sequenceIndex: session.nextSequenceIndex
		)
		existingResult.toolArgsJSON = argsJSON
		session.appendItem(existingResult)
		let countBefore = session.items.count

		coordinator.handleClaudeProviderRepoPromptToolCall(
			invocationID: nil,
			toolName: "mcp__RepoPrompt__read_file",
			argsJSON: argsJSON,
			session: session
		)

		XCTAssertEqual(session.items.count, countBefore)
		XCTAssertFalse(session.items.contains(where: {
			$0.kind == .toolCall
				&& MCPIntegrationHelper.normalizedRepoPromptToolName($0.toolName ?? "") == "read_file"
		}))
	}

	func testProviderRepoPromptToolCallDoesNotCorrelateAgainstPriorTurnResult() {
		let coordinator = ClaudeAgentModeCoordinator(
			windowID: 7,
			workspacePathProvider: { "/tmp/workspace" },
			claudeControllerFactory: { _, _, _, _, _, _, _ in FakeClaudeController(returnedSessionID: nil) }
		)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .claudeCode
		let argsJSON = #"{"path":"README.md"}"#
		var priorTurnResult = AgentChatItem.toolResult(
			name: "read_file",
			invocationID: UUID(),
			resultJSON: #"{"status":"ok"}"#,
			isError: false,
			sequenceIndex: session.nextSequenceIndex
		)
		priorTurnResult.toolArgsJSON = argsJSON
		session.appendItem(priorTurnResult)
		coordinator.resetToolCorrelation(for: session)

		coordinator.handleClaudeProviderRepoPromptToolCall(
			invocationID: nil,
			toolName: "mcp__RepoPrompt__read_file",
			argsJSON: argsJSON,
			session: session
		)

		XCTAssertEqual(session.items.count, 2)
		XCTAssertEqual(session.items.last?.kind, .toolCall)
		XCTAssertEqual(session.items.last?.toolName, "mcp__RepoPrompt__read_file")
	}

	func testProviderRepoPromptToolCallCorrelatesByNormalizedNameToToolResult() {
		let coordinator = ClaudeAgentModeCoordinator(
			windowID: 7,
			workspacePathProvider: { "/tmp/workspace" },
			claudeControllerFactory: { _, _, _, _, _, _, _ in FakeClaudeController(returnedSessionID: nil) }
		)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .claudeCode
		coordinator.resetToolCorrelation(for: session)
		var existingResult = AgentChatItem.toolResult(
			name: "read_file",
			invocationID: UUID(),
			resultJSON: #"{"status":"ok"}"#,
			isError: false,
			sequenceIndex: session.nextSequenceIndex
		)
		existingResult.toolArgsJSON = nil
		session.appendItem(existingResult)
		let providerArgsJSON = #"{"path":"Package.swift"}"#

		coordinator.handleClaudeProviderRepoPromptToolCall(
			invocationID: nil,
			toolName: "mcp__RepoPrompt__read_file",
			argsJSON: providerArgsJSON,
			session: session
		)

		XCTAssertEqual(session.items.count, 1, "items=\(session.items.map { "\($0.kind.rawValue):\($0.toolName ?? "nil") args=\($0.toolArgsJSON ?? "nil")" })")
		XCTAssertEqual(session.items[0].toolArgsJSON, providerArgsJSON, "items=\(session.items.map { "\($0.kind.rawValue):\($0.toolName ?? "nil") args=\($0.toolArgsJSON ?? "nil")" })")
		XCTAssertEqual(session.items[0].kind, .toolResult, "items=\(session.items.map { "\($0.kind.rawValue):\($0.toolName ?? "nil") args=\($0.toolArgsJSON ?? "nil")" })")
	}

	func testHandlerExactProviderResultClosesProviderCreatedRepoPromptSlot() {
		let handler = ClaudeAgentToolTrackingHandler()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .claudeCode
		handler.resetTurnState(for: session)
		let providerInvocationID = UUID()
		let argsJSON = #"{"path":"README.md"}"#
		let providerResultJSON = #"{"status":"ok","source":"provider"}"#

		let callConsumed = handler.handleProviderToolEvent(
			.toolCall(.init(
				toolName: "mcp__RepoPrompt__read_file",
				invocationID: providerInvocationID,
				argsJSON: argsJSON
			)),
			session: session
		)

		XCTAssertTrue(callConsumed)
		XCTAssertEqual(session.items.count, 1)
		XCTAssertEqual(session.items[0].kind, .toolCall)
		XCTAssertEqual(session.items[0].toolInvocationID, providerInvocationID)

		let resultConsumed = handler.handleProviderToolEvent(
			.toolResult(.init(
				toolName: "mcp__RepoPrompt__read_file",
				invocationID: providerInvocationID,
				argsJSON: argsJSON,
				resultJSON: providerResultJSON,
				isError: false
			)),
			session: session
		)

		XCTAssertTrue(resultConsumed)
		XCTAssertEqual(session.items.count, 1)
		XCTAssertEqual(session.items[0].kind, .toolResult)
		XCTAssertEqual(session.items[0].toolInvocationID, providerInvocationID)
		XCTAssertEqual(session.items[0].toolResultJSON, providerResultJSON)
	}

	func testExactProviderResultBeforeTrackerCallStillLetsTrackerEnrichSameSlot() {
		let coordinator = ClaudeAgentModeCoordinator(
			windowID: 7,
			workspacePathProvider: { "/tmp/workspace" },
			claudeControllerFactory: { _, _, _, _, _, _, _ in FakeClaudeController(returnedSessionID: nil) }
		)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .claudeCode
		coordinator.resetToolCorrelation(for: session)
		let providerInvocationID = UUID()
		let trackerInvocationID = UUID()
		let argsJSON = #"{"path":"README.md"}"#
		let providerResultJSON = #"{"status":"ok","source":"provider"}"#
		let trackerResultJSON = #"{"status":"ok","source":"tracker"}"#

		coordinator.handleClaudeProviderRepoPromptToolCall(
			invocationID: providerInvocationID,
			toolName: "mcp__RepoPrompt__read_file",
			argsJSON: argsJSON,
			session: session
		)
		let providerConsumed = coordinator.handleToolStreamEvent(
			.toolResult(.init(
				toolName: "mcp__RepoPrompt__read_file",
				invocationID: providerInvocationID,
				argsJSON: argsJSON,
				resultJSON: providerResultJSON,
				isError: false
			)),
			session: session
		)

		XCTAssertTrue(providerConsumed)
		XCTAssertEqual(session.items.count, 1)
		XCTAssertEqual(session.items[0].kind, .toolResult)
		XCTAssertEqual(session.items[0].toolInvocationID, providerInvocationID)
		XCTAssertEqual(session.items[0].toolResultJSON, providerResultJSON)

		coordinator.handleClaudeTrackerToolCall(
			invocationID: trackerInvocationID,
			toolName: "mcp__RepoPrompt__read_file",
			args: ["path": .string("README.md")],
			session: session
		)
		coordinator.handleClaudeTrackerToolResult(
			invocationID: trackerInvocationID,
			toolName: "mcp__RepoPrompt__read_file",
			args: ["path": .string("README.md")],
			resultJSON: trackerResultJSON,
			isError: false,
			session: session
		)

		XCTAssertEqual(session.items.count, 1)
		XCTAssertEqual(session.items[0].kind, .toolResult)
		XCTAssertEqual(session.items[0].toolInvocationID, providerInvocationID)
		XCTAssertEqual(session.items[0].toolResultJSON, trackerResultJSON)
	}

	func testExactProviderErrorResultRecordsErrorState() {
		let coordinator = ClaudeAgentModeCoordinator(
			windowID: 7,
			workspacePathProvider: { "/tmp/workspace" },
			claudeControllerFactory: { _, _, _, _, _, _, _ in FakeClaudeController(returnedSessionID: nil) }
		)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .claudeCode
		coordinator.resetToolCorrelation(for: session)
		let providerInvocationID = UUID()
		let resultJSON = #"{"status":"failed","error":"denied"}"#

		coordinator.handleClaudeProviderRepoPromptToolCall(
			invocationID: providerInvocationID,
			toolName: "mcp__RepoPrompt__read_file",
			argsJSON: #"{"path":"README.md"}"#,
			session: session
		)
		let consumed = coordinator.handleToolStreamEvent(
			.toolResult(.init(
				toolName: "mcp__RepoPrompt__read_file",
				invocationID: providerInvocationID,
				argsJSON: nil,
				resultJSON: resultJSON,
				isError: true
			)),
			session: session
		)

		XCTAssertTrue(consumed)
		XCTAssertEqual(session.items.count, 1)
		XCTAssertEqual(session.items[0].kind, .toolResult)
		XCTAssertEqual(session.items[0].toolInvocationID, providerInvocationID)
		XCTAssertEqual(session.items[0].toolResultJSON, resultJSON)
		XCTAssertEqual(session.items[0].toolIsError, true)
	}

	func testNilIDProviderResultDoesNotCloseRepoPromptSlotByNameOrSignature() {
		let coordinator = ClaudeAgentModeCoordinator(
			windowID: 7,
			workspacePathProvider: { "/tmp/workspace" },
			claudeControllerFactory: { _, _, _, _, _, _, _ in FakeClaudeController(returnedSessionID: nil) }
		)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .claudeCode
		coordinator.resetToolCorrelation(for: session)
		let argsJSON = #"{"path":"README.md"}"#

		coordinator.handleClaudeProviderRepoPromptToolCall(
			invocationID: nil,
			toolName: "mcp__RepoPrompt__read_file",
			argsJSON: argsJSON,
			session: session
		)
		let consumed = coordinator.handleToolStreamEvent(
			.toolResult(.init(
				toolName: "mcp__RepoPrompt__read_file",
				invocationID: nil,
				argsJSON: argsJSON,
				resultJSON: #"{"status":"ok","source":"provider"}"#,
				isError: false
			)),
			session: session
		)

		XCTAssertTrue(consumed)
		XCTAssertEqual(session.items.count, 1)
		XCTAssertEqual(session.items[0].kind, .toolCall)
		XCTAssertNil(session.items[0].toolInvocationID)
		XCTAssertNil(session.items[0].toolResultJSON)
	}

	func testProviderResultWithDuplicateRepoPromptCardsClosesOnlyExactProviderID() {
		let coordinator = ClaudeAgentModeCoordinator(
			windowID: 7,
			workspacePathProvider: { "/tmp/workspace" },
			claudeControllerFactory: { _, _, _, _, _, _, _ in FakeClaudeController(returnedSessionID: nil) }
		)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .claudeCode
		coordinator.resetToolCorrelation(for: session)
		let firstProviderInvocationID = UUID()
		let secondProviderInvocationID = UUID()
		let firstArgsJSON = #"{"path":"README.md"}"#
		let secondArgsJSON = #"{"path":"Package.swift"}"#
		let resultJSON = #"{"status":"ok","source":"provider-second"}"#

		coordinator.handleClaudeProviderRepoPromptToolCall(
			invocationID: firstProviderInvocationID,
			toolName: "mcp__RepoPrompt__read_file",
			argsJSON: firstArgsJSON,
			session: session
		)
		coordinator.handleClaudeProviderRepoPromptToolCall(
			invocationID: secondProviderInvocationID,
			toolName: "mcp__RepoPrompt__read_file",
			argsJSON: secondArgsJSON,
			session: session
		)

		let consumed = coordinator.handleToolStreamEvent(
			.toolResult(.init(
				toolName: "mcp__RepoPrompt__read_file",
				invocationID: secondProviderInvocationID,
				argsJSON: secondArgsJSON,
				resultJSON: resultJSON,
				isError: false
			)),
			session: session
		)

		XCTAssertTrue(consumed)
		XCTAssertEqual(session.items.count, 2)
		XCTAssertEqual(session.items[0].kind, .toolCall)
		XCTAssertEqual(session.items[0].toolInvocationID, firstProviderInvocationID)
		XCTAssertNil(session.items[0].toolResultJSON)
		XCTAssertEqual(session.items[1].kind, .toolResult)
		XCTAssertEqual(session.items[1].toolInvocationID, secondProviderInvocationID)
		XCTAssertEqual(session.items[1].toolResultJSON, resultJSON)
		XCTAssertLessThan(session.items[0].sequenceIndex, session.items[1].sequenceIndex)
	}

	func testProviderRepoPromptAskUserToolCallIsStoredAsCanonicalAskUser() {
		let coordinator = ClaudeAgentModeCoordinator(
			windowID: 7,
			workspacePathProvider: { "/tmp/workspace" },
			claudeControllerFactory: { _, _, _, _, _, _, _ in FakeClaudeController(returnedSessionID: nil) }
		)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .claudeCode

		coordinator.handleClaudeProviderRepoPromptToolCall(
			invocationID: nil,
			toolName: "mcp__RepoPrompt__ask_user",
			argsJSON: #"{"question":"Proceed?"}"#,
			session: session
		)

		XCTAssertEqual(session.items.count, 1)
		XCTAssertEqual(session.items[0].kind, .toolCall)
		XCTAssertEqual(session.items[0].toolName, "ask_user")
	}

	func testTrackerAskUserToolResultRetconsExistingProviderPlaceholderToCanonicalAskUser() {
		let coordinator = ClaudeAgentModeCoordinator(
			windowID: 7,
			workspacePathProvider: { "/tmp/workspace" },
			claudeControllerFactory: { _, _, _, _, _, _, _ in FakeClaudeController(returnedSessionID: nil) }
		)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .claudeCode
		let argsJSON = #"{"question":"Proceed?"}"#
		let placeholder = AgentChatItem.toolCall(
			name: "mcp__RepoPrompt__ask_user",
			invocationID: nil,
			argsJSON: argsJSON,
			sequenceIndex: session.nextSequenceIndex
		)
		session.appendItem(placeholder)

		coordinator.handleClaudeTrackerToolResult(
			invocationID: UUID(),
			toolName: "ask_user",
			args: ["question": .string("Proceed?")],
			resultJSON: #"{"response":"Yes","skipped":false,"timed_out":false,"elapsed_seconds":0}"#,
			isError: false,
			session: session
		)

		XCTAssertEqual(session.items.count, 1)
		XCTAssertEqual(session.items[0].kind, .toolResult)
		XCTAssertEqual(session.items[0].toolName, "ask_user")
	}

	/// Regression test: when assistant text is buffered (pendingAssistantDelta) and a
	/// tracker-sourced tool call arrives, the buffered text must be flushed and materialized
	/// BEFORE the tool card is inserted. Without the flush, the assistant bubble would appear
	/// after the tool card (wrong ordering).
	func testTrackerToolCallFlushesBufferedAssistantDeltaBeforeInsertion() {
		let (coordinator, vm) = makeCoordinatorWithViewModel()
		_ = vm  // retain the view model so the coordinator's weak reference stays valid
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .claudeCode

		// 1. Simulate streaming assistant text: add a streaming assistant item + buffer more text.
		var assistantItem = AgentChatItem.assistant("Hello, ", sequenceIndex: session.nextSequenceIndex)
		assistantItem.isStreaming = true
		session.appendItem(assistantItem)
		session.pendingAssistantDelta = "I will read that file."

		// 2. Fire a tracker tool call (the path that was missing the flush).
		let invocationID = UUID()
		coordinator.handleClaudeTrackerToolCall(
			invocationID: invocationID,
			toolName: "mcp__RepoPrompt__read_file",
			args: nil as [String: Value]?,
			session: session
		)

		// 3. Verify ordering: assistant text must appear before tool card.
		let kinds = session.items.map(\.kind)
		XCTAssertEqual(kinds, [.assistant, .toolCall],
			"Expected [assistant, toolCall] but got \(kinds) — assistant delta was not flushed before tool insertion")

		// 4. Verify the assistant text includes the flushed delta.
		XCTAssertEqual(session.items[0].text, "Hello, I will read that file.")

		// 5. Verify the assistant segment is no longer streaming (ended before tool card).
		XCTAssertFalse(session.items[0].isStreaming,
			"Assistant segment should be ended (not streaming) after tool boundary")
	}

	/// Same regression test for tracker-sourced tool results.
	func testTrackerToolResultFlushesBufferedAssistantDeltaBeforeInsertion() {
		let (coordinator, vm) = makeCoordinatorWithViewModel()
		_ = vm  // retain the view model so the coordinator's weak reference stays valid
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .claudeCode

		// 1. Simulate streaming assistant text + buffered delta.
		var assistantItem = AgentChatItem.assistant("Analyzing ", sequenceIndex: session.nextSequenceIndex)
		assistantItem.isStreaming = true
		session.appendItem(assistantItem)
		session.pendingAssistantDelta = "the results."

		// 2. Fire a tracker tool result.
		let invocationID = UUID()
		coordinator.handleClaudeTrackerToolResult(
			invocationID: invocationID,
			toolName: "mcp__RepoPrompt__read_file",
			args: nil as [String: Value]?,
			resultJSON: #"{"content":"file contents"}"#,
			isError: false,
			session: session
		)

		// 3. Verify ordering: assistant text before tool result.
		let kinds = session.items.map(\.kind)
		XCTAssertEqual(kinds, [.assistant, .toolResult],
			"Expected [assistant, toolResult] but got \(kinds)")
		XCTAssertEqual(session.items[0].text, "Analyzing the results.")
		XCTAssertFalse(session.items[0].isStreaming)
	}

	/// Creates a ClaudeAgentModeCoordinator attached to a real AgentModeViewModel so that
	/// viewModel-delegated methods (flushPendingAssistantDelta, endActiveAssistantSegment, etc.) work.
	private func makeCoordinatorWithViewModel() -> (ClaudeAgentModeCoordinator, AgentModeViewModel) {
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath,
			codexControllerFactory: { _, _, _, _, _, _ in StubCodexController() }
		)
		let toolTrackingHooks = AgentToolTrackingHooks(
			flushPendingAssistantDelta: { [weak vm] session in vm?.flushPendingAssistantDelta(session) },
			endActiveAssistantSegment: { [weak vm] session in vm?.endActiveAssistantSegment(session) },
			endActiveReasoningSegment: { [weak vm] session in vm?.endActiveReasoningSegment(session) },
			sealAssistantBoundary: { [weak vm] session in
				vm?.flushPendingAssistantDelta(session)
				vm?.endActiveAssistantSegment(session)
			},
			requestUIRefresh: { _, _ in },
			scheduleSave: { _ in },
			addToolInputTokens: { _, _ in },
			addToolOutputTokens: { _, _ in }
		)
		let coordinator = ClaudeAgentModeCoordinator(
			windowID: 1,
			workspacePathProvider: { "/tmp/workspace" },
			claudeControllerFactory: { _, _, _, _, _, _, _ in FakeClaudeController(returnedSessionID: nil) }
		)
		coordinator.toolTrackingHooks = toolTrackingHooks
		coordinator.attach(viewModel: vm)
		return (coordinator, vm)
	}

	private func preserveUserDefaults(keys: [String]) -> () -> Void {
		let defaults = UserDefaults.standard
		let previousValues = keys.reduce(into: [String: Any]()) { result, key in
			if let value = defaults.object(forKey: key) {
				result[key] = value
			}
		}
		return {
			for key in keys {
				if let previousValue = previousValues[key] {
					defaults.set(previousValue, forKey: key)
				} else {
					defaults.removeObject(forKey: key)
				}
			}
		}
	}

	private func waitForCondition(
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

/// Minimal stub for CodexSessionControlling — never actually used in Claude coordinator tests,
/// but required to satisfy the AgentModeViewModel test initialiser.
private final class StubCodexController: CodexSessionControlling {
	var hasActiveThread: Bool { false }
	var events: AsyncStream<CodexNativeSessionController.Event> {
		AsyncStream { $0.finish() }
	}
	func ensureEventsStreamReady() {}
	func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String) async throws -> CodexNativeSessionController.SessionRef {
		fatalError("StubCodexController should not be called")
	}
	func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String, model: String?, reasoningEffort: String?) async throws -> CodexNativeSessionController.SessionRef {
		fatalError("StubCodexController should not be called")
	}
	func sendUserMessage(_ text: String) async throws { fatalError("StubCodexController should not be called") }
	func sendUserTurn(text: String, images: [AgentImageAttachment]) async throws { fatalError("StubCodexController should not be called") }
	func sendUserTurn(text: String, images: [AgentImageAttachment], model: String?, reasoningEffort: String?) async throws { fatalError("StubCodexController should not be called") }
	func cancelCurrentTurn() async {}
	func shutdown() async {}
	func respondToServerRequest(id: CodexAppServerRequestID, result: [String: Any]) async {}
}

private final class CoordinatorChildAgentWaitGate {
	var isActive = true
	private(set) var queryCallCount = 0

	func recordQueryAndReturnIsActive() -> Bool {
		queryCallCount += 1
		return isActive
	}
}

private actor FakeClaudeController: ClaudeSessionControlling {
	struct StartOrResumeCall: Equatable {
		let existingSessionID: String?
		let model: String?
		let effortLevel: ClaudeCodeEffortLevel?
		let systemPromptOverride: String?
	}

	struct RespondedPermissionRequest: Equatable {
		let id: String
		let decision: AgentApprovalDecision
	}

	struct ApplyModelAndEffortCall: Equatable {
		let model: String?
		let effortLevel: ClaudeCodeEffortLevel?
	}

	struct Snapshot {
		let ensureEventsStreamReadyCallCount: Int
		let startOrResumeCalls: [StartOrResumeCall]
		let applyModelAndEffortCalls: [ApplyModelAndEffortCall]
		let sendUserMessages: [String]
		let respondedPermissionRequests: [RespondedPermissionRequest]
		let interruptTurnCallCount: Int
		let interruptTurnReasons: [String]
		let shutdownCallCount: Int
	}

	private let returnedSessionID: String?
	private var currentSessionID: String?
	private let stream: AsyncStream<ClaudeNativeProcessSessionController.Event>
	private var continuation: AsyncStream<ClaudeNativeProcessSessionController.Event>.Continuation?
	private var startOrResumeErrors: [ClaudeNativeProcessSessionController.ControllerError]

	private(set) var hasActiveSession: Bool = true
	var hasTurnInFlight: Bool { turnInFlight }
	private var ensureEventsStreamReadyCallCount = 0
	private var startOrResumeCalls: [StartOrResumeCall] = []
	private var applyModelAndEffortCalls: [ApplyModelAndEffortCall] = []
	private var sendUserMessages: [String] = []
	private var respondedPermissionRequests: [RespondedPermissionRequest] = []
	private var interruptTurnCallCount = 0
	private var interruptTurnReasons: [String] = []
	private var turnInFlight = true
	private var shutdownCallCount = 0

	nonisolated var events: AsyncStream<ClaudeNativeProcessSessionController.Event> {
		stream
	}

	init(
		returnedSessionID: String?,
		currentSessionID: String? = nil,
		startOrResumeErrors: [ClaudeNativeProcessSessionController.ControllerError] = []
	) {
		self.returnedSessionID = returnedSessionID
		self.currentSessionID = currentSessionID ?? returnedSessionID
		self.startOrResumeErrors = startOrResumeErrors
		var continuationRef: AsyncStream<ClaudeNativeProcessSessionController.Event>.Continuation?
		self.stream = AsyncStream { continuation in
			continuationRef = continuation
		}
		self.continuation = continuationRef
	}

	func ensureEventsStreamReady() {
		ensureEventsStreamReadyCallCount += 1
	}

	func resetEventsStreamForNewRun() {}

	func startOrResume(
		existingSessionID: String?,
		model: String?,
		effortLevel: ClaudeCodeEffortLevel?,
		systemPromptOverride: String?
	) async throws -> ClaudeNativeProcessSessionController.SessionRef {
		startOrResumeCalls.append(
			StartOrResumeCall(
				existingSessionID: existingSessionID,
				model: model,
				effortLevel: effortLevel,
				systemPromptOverride: systemPromptOverride
			)
		)
		if !startOrResumeErrors.isEmpty {
			throw startOrResumeErrors.removeFirst()
		}
		currentSessionID = returnedSessionID ?? currentSessionID
		return ClaudeNativeProcessSessionController.SessionRef(sessionID: returnedSessionID)
	}

	func currentSessionRef() async -> ClaudeNativeProcessSessionController.SessionRef {
		ClaudeNativeProcessSessionController.SessionRef(sessionID: currentSessionID)
	}

	func applyModelAndEffort(model: String?, effortLevel: ClaudeCodeEffortLevel?) async throws {
		applyModelAndEffortCalls.append(
			ApplyModelAndEffortCall(model: model, effortLevel: effortLevel)
		)
	}

	@discardableResult
	func sendUserMessage(_ text: String) async throws -> UUID {
		sendUserMessages.append(text)
		turnInFlight = true
		return UUID()
	}

	func interruptTurn(reason: String) async -> ClaudeNativeProcessSessionController.InterruptOutcome {
		interruptTurnCallCount += 1
		interruptTurnReasons.append(reason)
		guard turnInFlight else { return .noTurnInFlight }
		turnInFlight = false
		return .acknowledged
	}

	func shutdown() async {
		shutdownCallCount += 1
		hasActiveSession = false
		continuation?.finish()
	}

	func respondToPermissionRequest(id: String, decision: AgentApprovalDecision) async {
		respondedPermissionRequests.append(RespondedPermissionRequest(id: id, decision: decision))
	}

	func snapshot() -> Snapshot {
		Snapshot(
			ensureEventsStreamReadyCallCount: ensureEventsStreamReadyCallCount,
			startOrResumeCalls: startOrResumeCalls,
			applyModelAndEffortCalls: applyModelAndEffortCalls,
			sendUserMessages: sendUserMessages,
			respondedPermissionRequests: respondedPermissionRequests,
			interruptTurnCallCount: interruptTurnCallCount,
			interruptTurnReasons: interruptTurnReasons,
			shutdownCallCount: shutdownCallCount
		)
	}
}
