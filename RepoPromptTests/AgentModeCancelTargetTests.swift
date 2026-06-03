import XCTest
@testable import RepoPrompt

@MainActor
final class AgentModeCancelTargetTests: XCTestCase {
	func testComposerCancelTargetUsesExplicitTabSessionIdentity() throws {
		let vm = makeViewModel()
		let runningTabID = UUID()
		let idleTabID = UUID()
		vm.ensureSession(for: runningTabID)
		vm.ensureSession(for: idleTabID)
		let runningSession = try XCTUnwrap(vm.sessions[runningTabID])
		let idleSession = try XCTUnwrap(vm.sessions[idleTabID])
		let runID = UUID()
		let agentSessionID = UUID()
		let attemptID = UUID()
		runningSession.runState = .running
		runningSession.runID = runID
		runningSession.activeAgentSessionID = agentSessionID
		runningSession.activeHeadlessRunAttemptID = attemptID
		idleSession.runState = .idle

		// Simulate the mixed-props hazard: global active run state says "running",
		// but the explicit composer tab is idle. Stop must not render for the idle tab.
		vm.runState = .running

		let idleProps = vm.makeComposerProps(tabID: idleTabID)
		XCTAssertNil(idleProps.cancelTarget)

		let runningProps = vm.makeComposerProps(tabID: runningTabID)
		XCTAssertEqual(runningProps.cancelTarget?.tabID, runningTabID)
		XCTAssertEqual(runningProps.cancelTarget?.expectedRunID, runID)
		XCTAssertEqual(runningProps.cancelTarget?.expectedActiveAgentSessionID, agentSessionID)
		XCTAssertEqual(runningProps.cancelTarget?.expectedRunAttemptID, attemptID)
	}

	func testGuardedCancelRejectsMismatchedRunIdentity() async throws {
		var cancelledRunIDs: [UUID] = []
		let vm = makeViewModel { runID, _ in
			cancelledRunIDs.append(runID)
			return 0
		}
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		let session = try XCTUnwrap(vm.sessions[tabID])
		let liveRunID = UUID()
		let agentSessionID = UUID()
		let attemptID = UUID()
		session.runState = .running
		session.runID = liveRunID
		session.activeAgentSessionID = agentSessionID
		session.activeHeadlessRunAttemptID = attemptID

		let missingRunTarget = AgentRunCancelTarget(
			tabID: tabID,
			expectedRunID: nil,
			expectedActiveAgentSessionID: agentSessionID,
			expectedRunAttemptID: attemptID,
			expectedPendingUserInputRequestID: nil
		)
		let missingRunAccepted = await vm.cancelAgentRun(target: missingRunTarget, waitForCleanup: false)
		XCTAssertFalse(missingRunAccepted)

		let staleTarget = AgentRunCancelTarget(
			tabID: tabID,
			expectedRunID: UUID(),
			expectedActiveAgentSessionID: agentSessionID,
			expectedRunAttemptID: attemptID,
			expectedPendingUserInputRequestID: nil
		)

		let accepted = await vm.cancelAgentRun(target: staleTarget, waitForCleanup: false)

		XCTAssertFalse(accepted)
		XCTAssertEqual(session.runState, .running)
		XCTAssertTrue(cancelledRunIDs.isEmpty)
	}

	func testGuardedCancelRoutesToRenderTimeTargetTab() async throws {
		var cancelledRunIDs: [UUID] = []
		let vm = makeViewModel { runID, _ in
			cancelledRunIDs.append(runID)
			return 0
		}
		let targetTabID = UUID()
		let otherTabID = UUID()
		vm.ensureSession(for: targetTabID)
		vm.ensureSession(for: otherTabID)
		let targetSession = try XCTUnwrap(vm.sessions[targetTabID])
		let otherSession = try XCTUnwrap(vm.sessions[otherTabID])
		let targetRunID = UUID()
		let otherRunID = UUID()
		targetSession.runState = .running
		targetSession.runID = targetRunID
		targetSession.activeAgentSessionID = UUID()
		targetSession.activeHeadlessRunAttemptID = UUID()
		otherSession.runState = .running
		otherSession.runID = otherRunID
		otherSession.activeAgentSessionID = UUID()
		otherSession.activeHeadlessRunAttemptID = UUID()
		let cancelTarget = vm.makeRunCancelTarget(tabID: targetTabID, session: targetSession)

		let accepted = await vm.cancelAgentRun(target: cancelTarget, waitForCleanup: false)

		XCTAssertTrue(accepted)
		XCTAssertEqual(cancelledRunIDs, [targetRunID])
		XCTAssertEqual(targetSession.runState, .cancelled)
		XCTAssertEqual(otherSession.runState, .running)
	}

	func testComposerSubmitTargetUsesExplicitTabSessionIdentity() throws {
		let vm = makeViewModel()
		let runningTabID = UUID()
		let idleTabID = UUID()
		vm.ensureSession(for: runningTabID)
		vm.ensureSession(for: idleTabID)
		let runningSession = try XCTUnwrap(vm.sessions[runningTabID])
		let idleSession = try XCTUnwrap(vm.sessions[idleTabID])
		let runID = UUID()
		let agentSessionID = UUID()
		let attemptID = UUID()
		runningSession.runState = .running
		runningSession.runID = runID
		runningSession.activeAgentSessionID = agentSessionID
		runningSession.activeHeadlessRunAttemptID = attemptID
		idleSession.runState = .idle

		// Simulate mixed props: global active state is running, but each target must
		// reflect the explicit tab session that rendered the composer.
		vm.runState = .running

		let idleTarget = try XCTUnwrap(vm.makeComposerProps(tabID: idleTabID).submitTarget)
		XCTAssertEqual(idleTarget.tabID, idleTabID)
		XCTAssertEqual(idleTarget.route, .existingAgentSession)
		XCTAssertEqual(idleTarget.expectedSourceAgentSessionID, idleSession.activeAgentSessionID)
		XCTAssertEqual(idleTarget.expectedRunState, .idle)
		XCTAssertNil(idleTarget.expectedRunID)
		XCTAssertNil(idleTarget.expectedRunAttemptID)

		let runningTarget = try XCTUnwrap(vm.makeComposerProps(tabID: runningTabID).submitTarget)
		XCTAssertEqual(runningTarget.tabID, runningTabID)
		XCTAssertEqual(runningTarget.route, .existingAgentSession)
		XCTAssertEqual(runningTarget.expectedSourceAgentSessionID, agentSessionID)
		XCTAssertEqual(runningTarget.expectedRunState, .running)
		XCTAssertEqual(runningTarget.expectedRunID, runID)
		XCTAssertEqual(runningTarget.expectedRunAttemptID, attemptID)
	}

	func testGuardedSubmitRejectsMismatchedRunIdentityWithoutMutatingSession() async throws {
		let vm = makeViewModel()
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		let session = try XCTUnwrap(vm.sessions[tabID])
		session.runState = .running
		session.runID = UUID()
		session.activeHeadlessRunAttemptID = UUID()
		let staleTarget = AgentComposerSubmitTarget(
			tabID: tabID,
			route: .existingAgentSession,
			expectedSourceAgentSessionID: session.activeAgentSessionID,
			expectedRunState: .running,
			expectedRunID: UUID(),
			expectedRunAttemptID: session.activeHeadlessRunAttemptID
		)

		let result = await vm.submitUserTurnCreatingSessionIfNeeded(text: "stale steering", target: staleTarget)

		guard case .blocked(let message) = result else {
			return XCTFail("Expected stale target to be blocked")
		}
		XCTAssertFalse(message.isEmpty)
		XCTAssertTrue(session.items.isEmpty)
		XCTAssertTrue(session.pendingInstructions.isEmpty)
		XCTAssertTrue(session.pendingClaudeSteeringInstructions.isEmpty)
		XCTAssertTrue(session.pendingACPSteeringInstructions.isEmpty)
	}

	func testGuardedSubmitRoutesToRenderTimeTargetTabWhenAmbientCurrentTabChanged() async throws {
		let vm = makeViewModel()
		let targetTabID = UUID()
		let otherTabID = UUID()
		vm.ensureSession(for: targetTabID)
		vm.ensureSession(for: otherTabID)
		let targetSession = try XCTUnwrap(vm.sessions[targetTabID])
		let otherSession = try XCTUnwrap(vm.sessions[otherTabID])
		targetSession.selectedAgent = .codexExec
		otherSession.selectedAgent = .codexExec
		let target = try XCTUnwrap(vm.makeComposerSubmitTarget(tabID: targetTabID, session: targetSession))
		vm.test_setCurrentTabIDOverride(otherTabID)

		let result = await vm.submitUserTurnCreatingSessionIfNeeded(
			text: "send to rendered tab",
			target: target,
			createAndActivateSessionTab: {
				XCTFail("Existing-session submit should not create a new tab")
				return nil
			}
		)

		XCTAssertEqual(result, .submitted)
		XCTAssertEqual(targetSession.items.filter { $0.kind == .user }.map(\.text), ["send to rendered tab"])
		XCTAssertTrue(otherSession.items.isEmpty)
	}

	func testGuardedFirstSendUsesRenderTimeSourceTab() async throws {
		let vm = makeViewModel()
		vm.selectedAgent = .codexExec
		let sourceTabID = UUID()
		let ambientTabID = UUID()
		let destinationTabID = UUID()
		let sourceSession = await vm.ensureSessionReady(tabID: sourceTabID)
		let ambientSession = await vm.ensureSessionReady(tabID: ambientTabID)
		let imageAttachment = AgentImageAttachment(
			source: .localFile(path: "/tmp/render-target-image.png"),
			title: "render-target-image.png"
		)
		sourceSession.selectedWorkflow = AgentWorkflow.build.definition
		sourceSession.pendingImageAttachments = [imageAttachment]
		let target = try XCTUnwrap(vm.makeComposerSubmitTarget(tabID: sourceTabID, session: sourceSession))
		XCTAssertEqual(target.route, .createAgentSessionFromSourceTab)
		vm.test_setCurrentTabIDOverride(ambientTabID)

		let result = await vm.submitUserTurnCreatingSessionIfNeeded(
			text: "first send from rendered source",
			target: target,
			createAndActivateSessionTab: {
				vm.selectedAgent = .claudeCode
				return destinationTabID
			}
		)

		XCTAssertEqual(result, .submitted)
		XCTAssertNil(sourceSession.selectedWorkflow)
		XCTAssertTrue(sourceSession.pendingImageAttachments.isEmpty)
		XCTAssertTrue(ambientSession.items.isEmpty)
		XCTAssertTrue(ambientSession.pendingImageAttachments.isEmpty)
		let destinationSession = try XCTUnwrap(vm.sessions[destinationTabID])
		guard let userItem = destinationSession.items.first else {
			return XCTFail("Expected destination to receive optimistic user item")
		}
		XCTAssertEqual(userItem.kind, .user)
		XCTAssertEqual(userItem.text, "first send from rendered source")
		XCTAssertEqual(userItem.workflow?.builtInWorkflow, .build)
		XCTAssertEqual(userItem.attachments, [imageAttachment])
		XCTAssertEqual(destinationSession.selectedAgent, .codexExec)
	}

	func testGuardedFirstSendRejectsIfSourcePendingStateChangesDuringCreate() async throws {
		let vm = makeViewModel()
		vm.selectedAgent = .codexExec
		let sourceTabID = UUID()
		let destinationTabID = UUID()
		let sourceSession = await vm.ensureSessionReady(tabID: sourceTabID)
		sourceSession.pendingImageAttachments = [
			AgentImageAttachment(
				source: .localFile(path: "/tmp/source-state-changed.png"),
				title: "source-state-changed.png"
			)
		]
		let target = try XCTUnwrap(vm.makeComposerSubmitTarget(tabID: sourceTabID, session: sourceSession))

		let result = await vm.submitUserTurnCreatingSessionIfNeeded(
			text: "should not consume changed source",
			target: target,
			createAndActivateSessionTab: {
				_ = vm.session(for: destinationTabID)
				sourceSession.pendingImageAttachments.removeAll()
				return destinationTabID
			}
		)

		guard case .blocked(let message) = result else {
			return XCTFail("Expected changed source state to be blocked")
		}
		XCTAssertFalse(message.isEmpty)
		XCTAssertTrue(sourceSession.items.isEmpty)
		XCTAssertNil(vm.sessions[destinationTabID])
	}

	func testGuardedFirstSendRejectsIfSourceAutoEditChangesDuringCreate() async throws {
		let vm = makeViewModel()
		vm.selectedAgent = .codexExec
		let sourceTabID = UUID()
		let destinationTabID = UUID()
		let sourceSession = await vm.ensureSessionReady(tabID: sourceTabID)
		sourceSession.autoEditEnabled = true
		sourceSession.pendingImageAttachments = [
			AgentImageAttachment(
				source: .localFile(path: "/tmp/source-auto-edit-changed.png"),
				title: "source-auto-edit-changed.png"
			)
		]
		let target = try XCTUnwrap(vm.makeComposerSubmitTarget(tabID: sourceTabID, session: sourceSession))

		let result = await vm.submitUserTurnCreatingSessionIfNeeded(
			text: "should not consume changed auto edit",
			target: target,
			createAndActivateSessionTab: {
				_ = vm.session(for: destinationTabID)
				sourceSession.autoEditEnabled = false
				return destinationTabID
			}
		)

		guard case .blocked(let message) = result else {
			return XCTFail("Expected changed auto-edit state to be blocked")
		}
		XCTAssertFalse(message.isEmpty)
		XCTAssertEqual(sourceSession.pendingImageAttachments.count, 1)
		XCTAssertTrue(sourceSession.items.isEmpty)
		XCTAssertNil(vm.sessions[destinationTabID])
	}

	func testGuardedFirstSendRejectsIfSourceBecameLinkedBeforeCreate() async throws {
		let vm = makeViewModel()
		let sourceTabID = UUID()
		let sourceSession = await vm.ensureSessionReady(tabID: sourceTabID)
		sourceSession.pendingImageAttachments = [
			AgentImageAttachment(
				source: .localFile(path: "/tmp/stale-source-image.png"),
				title: "stale-source-image.png"
			)
		]
		let target = try XCTUnwrap(vm.makeComposerSubmitTarget(tabID: sourceTabID, session: sourceSession))
		XCTAssertEqual(target.route, .createAgentSessionFromSourceTab)
		sourceSession.activeAgentSessionID = UUID()
		var createWasCalled = false

		let result = await vm.submitUserTurnCreatingSessionIfNeeded(
			text: "should not send",
			target: target,
			createAndActivateSessionTab: {
				createWasCalled = true
				return UUID()
			}
		)

		guard case .blocked(let message) = result else {
			return XCTFail("Expected relinked source to be blocked")
		}
		XCTAssertFalse(message.isEmpty)
		XCTAssertFalse(createWasCalled)
		XCTAssertEqual(sourceSession.pendingImageAttachments.count, 1)
		XCTAssertTrue(sourceSession.items.isEmpty)
	}

	func testPendingUserInputCancelTargetBindsSnapshotTabAndRequestIdentity() {
		let tabID = UUID()
		let runID = UUID()
		let agentSessionID = UUID()
		let attemptID = UUID()
		let requestID = CodexAppServerRequestID.string("request-1")
		let request = AgentRequestUserInputRequest(
			requestID: requestID,
			method: "request_user_input",
			threadID: "thread",
			turnID: "turn",
			itemID: "item",
			questions: [
				AgentRequestUserInputQuestion(
					id: "q1",
					header: "Question",
					question: "Continue?",
					isOther: false,
					isSecret: false,
					options: []
				)
			]
		)
		let snapshot = AgentRunInteractionUISnapshot(
			currentTabID: tabID,
			runState: .waitingForUser,
			runningStatusText: nil,
			activeAgentRunStartedAt: nil,
			waitingPrompt: nil,
			pendingAskUser: nil,
			pendingUserInputRequest: request,
			pendingApproval: nil,
			pendingPermissionsRequest: nil,
			pendingMCPElicitationRequest: nil,
			pendingApplyEditsReview: nil,
			activeRunID: runID,
			activeAgentSessionID: agentSessionID,
			activeRunAttemptID: attemptID,
			latestUserSequenceIndex: nil,
			canForkCurrentSession: false,
			selectedAgent: .codexExec,
			selectedModelRaw: AgentModel.defaultModel.rawValue,
			selectedReasoningEffortRaw: nil
		)

		let cancelTarget = snapshot.pendingUserInputCancelTarget

		XCTAssertEqual(cancelTarget?.tabID, tabID)
		XCTAssertEqual(cancelTarget?.expectedRunID, runID)
		XCTAssertEqual(cancelTarget?.expectedActiveAgentSessionID, agentSessionID)
		XCTAssertEqual(cancelTarget?.expectedRunAttemptID, attemptID)
		XCTAssertEqual(cancelTarget?.expectedPendingUserInputRequestID, requestID)
	}

	private func makeViewModel(
		onCancelTools: @escaping AgentModeViewModel.MCPRunToolCanceller = { _, _ in 0 }
	) -> AgentModeViewModel {
		AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath,
			codexControllerFactory: { _, _, _, _, _, _ in
				CancelTargetNoopCodexController()
			},
			mcpRunToolCanceller: onCancelTools
		)
	}
}

private final class CancelTargetNoopCodexController: CodexSessionControlling {
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
