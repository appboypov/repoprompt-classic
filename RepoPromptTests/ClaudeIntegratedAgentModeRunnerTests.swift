import XCTest
@testable import RepoPrompt

@MainActor
final class ClaudeIntegratedAgentModeRunnerTests: XCTestCase {
	override func setUp() async throws {
		try await super.setUp()
		await HeadlessAgentConnectionGate.cancelAll()
	}

	override func tearDown() async throws {
		await HeadlessAgentConnectionGate.cancelAll()
		try await super.tearDown()
	}

	func testApprovalRequestTransitionsSessionToWaitingForApproval() async {
		let harness = makeHarness()
		await startRun(harness)

		let approval = makeApprovalRequest(id: "perm-1")
		await harness.controller.emit(.approvalRequest(approval))

		let waiting = await waitForCondition(timeoutSeconds: 1.0) {
			harness.session.runState == .waitingForApproval
				&& harness.session.pendingApproval?.requestID == .claudeControl("perm-1")
		}
		XCTAssertTrue(waiting)

		await harness.controller.emitTurnCompleted(.cancelled)
		let finished = await waitForCondition(timeoutSeconds: 1.0) {
			harness.session.agentTask == nil && harness.session.runState == .cancelled
		}
		XCTAssertTrue(finished)
	}

	func testApprovalCancelledRestoresRunningStateWhenMatchingPendingRequest() async {
		let harness = makeHarness()
		await startRun(harness)

		await harness.controller.emit(.approvalRequest(makeApprovalRequest(id: "perm-1")))
		_ = await waitForCondition(timeoutSeconds: 1.0) {
			harness.session.runState == .waitingForApproval
		}

		await harness.controller.emit(.approvalCancelled(requestID: "perm-1"))
		let restored = await waitForCondition(timeoutSeconds: 1.0) {
			harness.session.runState == .running && harness.session.pendingApproval == nil
		}
		XCTAssertTrue(restored)

		await harness.controller.emitTurnCompleted(.cancelled)
		let finished = await waitForCondition(timeoutSeconds: 1.0) {
			harness.session.agentTask == nil && harness.session.runState == .cancelled
		}
		XCTAssertTrue(finished)
	}

	func testErrorEventAppendsErrorItemAndRunFailsOnTurnCompletedFailed() async {
		let harness = makeHarness()
		await startRun(harness)

		await harness.controller.emit(.error("boom"))
		let appended = await waitForCondition(timeoutSeconds: 1.0) {
			harness.session.items.last?.kind == .error
				&& harness.session.items.last?.text == "boom"
				&& harness.session.runState == .running
		}
		XCTAssertTrue(appended)

		await harness.controller.emitTurnCompleted(.failed)
		let failed = await waitForCondition(timeoutSeconds: 1.0) {
			harness.session.agentTask == nil && harness.session.runState == .failed
		}
		XCTAssertTrue(failed)
		XCTAssertEqual(harness.hooks.notifyAgentTurnCompleteCount, 0)
	}

	func testTurnCompletedCompletedNotifiesAndFinalizesSession() async {
		let harness = makeHarness()
		await startRun(harness)

		harness.session.pendingAskUser = AgentAskUserPendingState(
			interaction: AgentAskUserInteraction(
				questions: [AgentAskUserQuestion(id: "continue", question: "Continue?")]
			)
		)
		harness.session.pendingApproval = makeApprovalRequest(id: "perm-1")
		harness.session.pendingApplyEditsReview = PendingApplyEditsReview(
			scope: ApplyEditsApprovalScope(windowID: 1, tabID: harness.session.tabID),
			path: "file.swift",
			unifiedDiff: "@@ -1 +1 @@"
		)

		await harness.controller.emitTurnCompleted(.completed)
		let completed = await waitForCondition(timeoutSeconds: 1.0) {
			harness.session.agentTask == nil
				&& harness.session.runState == .completed
				&& harness.session.pendingAskUser == nil
				&& harness.session.pendingApproval == nil
				&& harness.session.pendingApplyEditsReview == nil
		}
		XCTAssertTrue(completed)
		XCTAssertEqual(harness.hooks.notifyAgentTurnCompleteCount, 1)
		XCTAssertEqual(harness.hooks.cancelPendingQuestionCount, 1)
		XCTAssertEqual(harness.hooks.cancelPendingApprovalCount, 1)
		XCTAssertEqual(harness.hooks.cancelPendingApplyEditsReviewReasons, ["Run completed before review decision"])
	}

	func testCompletedTurnNotSuppressedByStalePendingSteeringCompletion() async {
		let harness = makeHarness()
		await harness.controller.setInterruptCurrentTurnShouldSucceed(true)
		await startRun(harness)

		await harness.controller.emitTurnCompleted(.completed)
		let completed = await waitForCondition(timeoutSeconds: 1.0) {
			harness.session.agentTask == nil && harness.session.runState == .completed
		}
		XCTAssertTrue(completed)
	}

	func testTurnCompletedCancelledFinalizesToCancelledWithoutNotification() async {
		let harness = makeHarness()
		await startRun(harness)

		await harness.controller.emitTurnCompleted(.cancelled)
		let cancelled = await waitForCondition(timeoutSeconds: 1.0) {
			harness.session.agentTask == nil && harness.session.runState == .cancelled
		}
		XCTAssertTrue(cancelled)
		XCTAssertEqual(harness.hooks.notifyAgentTurnCompleteCount, 0)
		XCTAssertEqual(harness.hooks.cancelPendingApplyEditsReviewReasons, ["Run cancelled"])
	}

	func testCancelledTurnCompletedIsIgnoredWhenSupersedingTurnIsPending() async {
		let harness = makeHarness()
		await harness.controller.setInterruptCurrentTurnShouldSucceed(true)
		await startRun(harness)

		harness.session.pendingSupersedingTurnCompletions += 1
		let sentSteering = await harness.coordinator.sendClaudeNativeMessage(
			session: harness.session,
			text: "follow up",
			attachments: []
		)
		XCTAssertTrue(sentSteering)

		await harness.controller.emitTurnCompleted(.cancelled)

		let stayedRunning = await waitForCondition(timeoutSeconds: 1.0) {
			harness.session.agentTask != nil
				&& harness.session.runState == .running
				&& harness.session.pendingSupersedingTurnCompletions == 0
		}
		XCTAssertTrue(stayedRunning)

		await harness.controller.emitTurnCompleted(.completed)
		let completed = await waitForCondition(timeoutSeconds: 1.0) {
			harness.session.agentTask == nil && harness.session.runState == .completed
		}
		XCTAssertTrue(completed)
	}

	func testFailedTurnCompletedIsIgnoredWhenSupersedingTurnIsPending() async {
		let harness = makeHarness()
		await harness.controller.setInterruptCurrentTurnShouldSucceed(true)
		await startRun(harness)

		harness.session.pendingSupersedingTurnCompletions += 1
		let sentSteering = await harness.coordinator.sendClaudeNativeMessage(
			session: harness.session,
			text: "follow up",
			attachments: []
		)
		XCTAssertTrue(sentSteering)

		// The CLI may report error_during_execution (.failed) for abort side effects
		// (e.g. JSON parse errors from killed tool processes). The run should stay alive.
		await harness.controller.emitTurnCompleted(.failed)

		let stayedRunning = await waitForCondition(timeoutSeconds: 1.0) {
			harness.session.agentTask != nil
				&& harness.session.runState == .running
				&& harness.session.pendingSupersedingTurnCompletions == 0
		}
		XCTAssertTrue(stayedRunning)

		await harness.controller.emitTurnCompleted(.completed)
		let completed = await waitForCondition(timeoutSeconds: 1.0) {
			harness.session.agentTask == nil && harness.session.runState == .completed
		}
		XCTAssertTrue(completed)
	}

	func testCompletedTurnCompletedIsIgnoredWhenSupersedingTurnIsPending() async {
		let harness = makeHarness()
		await harness.controller.setInterruptCurrentTurnShouldSucceed(true)
		await startRun(harness)

		harness.session.pendingSupersedingTurnCompletions += 1
		let sentSteering = await harness.coordinator.sendClaudeNativeMessage(
			session: harness.session,
			text: "follow up",
			attachments: []
		)
		XCTAssertTrue(sentSteering)

		await harness.controller.emitTurnCompleted(.completed)

		let stayedRunning = await waitForCondition(timeoutSeconds: 1.0) {
			harness.session.agentTask != nil
				&& harness.session.runState == .running
				&& harness.session.pendingSupersedingTurnCompletions == 0
		}
		XCTAssertTrue(stayedRunning)

		await harness.controller.emitTurnCompleted(.completed)
		let completed = await waitForCondition(timeoutSeconds: 1.0) {
			harness.session.agentTask == nil && harness.session.runState == .completed
		}
		XCTAssertTrue(completed)
	}

	/// Regression test for Bug 3: a stale `.turnCompleted(.cancelled)` from a previous
	/// run must not prematurely terminate the current run's event loop.
	func testStaleTurnCompletedFromCancelledRunDoesNotKillNextRun() async {
		let harness = makeHarness()
		await startRun(harness)

		// The initial run's turn registered a turnID.
		let validTurnID = harness.session.claudeExpectedTurnIDs.first!
		let staleTurnID = UUID() // a turnID that was never registered

		// Inject a stale turnCompleted (as if from a prior cancelled run) followed by
		// the real completion for the current run. The runner should skip the stale one.
		await harness.controller.emitTurnCompleted(.cancelled, turnID: staleTurnID)

		// The run should still be alive since the stale turnID is not recognized.
		let stillRunning = await waitForCondition(timeoutSeconds: 0.5) {
			harness.session.agentTask != nil && harness.session.runState == .running
		}
		XCTAssertTrue(stillRunning, "Stale turnCompleted should not kill current run")

		// Now emit the real completion for the current run's turn.
		await harness.controller.emitTurnCompleted(.completed, turnID: validTurnID)
		let completed = await waitForCondition(timeoutSeconds: 1.0) {
			harness.session.agentTask == nil && harness.session.runState == .completed
		}
		XCTAssertTrue(completed)
		XCTAssertEqual(harness.hooks.notifyAgentTurnCompleteCount, 1)
	}

	func testReasoningStreamResultIsForwardedToHooks() async {
		let harness = makeHarness()
		await startRun(harness)

		await harness.controller.emit(.stream(AIStreamResult(type: "reasoning", text: nil, reasoning: "Inspecting project")))

		let forwarded = await waitForCondition(timeoutSeconds: 1.0) {
			harness.hooks.handleHeadlessStreamResultCount == 1
		}
		XCTAssertTrue(forwarded)

		await harness.controller.emitTurnCompleted(.cancelled)
		_ = await waitForCondition(timeoutSeconds: 1.0) {
			harness.session.agentTask == nil && harness.session.runState == .cancelled
		}
	}

	/// Regression test: sending a steering message while the runner's consumeEvents
	/// loop is active must NOT reset the events stream. Previously,
	/// sendClaudeNativeMessage called resetEventsStreamForNewRun() when
	/// hasTurnInFlight was false, which could replace the stream mid-iteration and
	/// cause the runner to silently drop all subsequent assistant output ("dead
	/// thread" symptom).
	func testSteeringSendDuringActiveRunDoesNotResetEventsStream() async {
		let harness = makeHarness()
		await startRun(harness)

		// Force hasTurnInFlight == false to simulate the brief gap between turns
		// (or a race where the controller reports no turn right before the next one
		// starts). This is the exact state that previously triggered the dangerous
		// resetEventsStreamForNewRun() call.
		await harness.controller.setTurnInFlight(false)

		let resetCountBefore = await harness.controller.snapshot().resetEventsStreamCallCount

		// Send steering while the run consumer is active.
		let steeringSent = await harness.coordinator.sendClaudeNativeMessage(
			session: harness.session,
			text: "steering follow-up",
			attachments: []
		)
		XCTAssertTrue(steeringSent)

		let snapshot = await harness.controller.snapshot()
		XCTAssertEqual(
			snapshot.resetEventsStreamCallCount, resetCountBefore,
			"sendClaudeNativeMessage must NOT call resetEventsStreamForNewRun — " +
			"doing so would kill the runner's active for-await event loop"
		)

		// Also verify that events emitted after the steering send are still received.
		let streamResult = AIStreamResult(type: "content", text: "post-steering content")
		await harness.controller.emit(.stream(streamResult))

		let receivedContent = await waitForCondition(timeoutSeconds: 1.0) {
			harness.hooks.handleHeadlessStreamResultCount >= 1
		}
		XCTAssertTrue(receivedContent, "Events emitted after steering send must be received by the runner")

		// Clean up: emit a turn completion so the run finalizes.
		await harness.controller.emitTurnCompleted(.completed)
		let completed = await waitForCondition(timeoutSeconds: 1.0) {
			harness.session.agentTask == nil && harness.session.runState == .completed
		}
		XCTAssertTrue(completed)
	}

	/// Verify that cancel nils the controller immediately (prepareClaudeCancelSync)
	/// and then shuts down the process asynchronously (cancelClaudeRun).
	/// The nil happens synchronously so the next startRun always creates a fresh
	/// process — no stale stream or race conditions.
	func testCancelNilsControllerAndShutsDown() async {
		let harness = makeHarness()
		await harness.controller.setInterruptCurrentTurnShouldSucceed(true)
		await startRun(harness)

		// Step 1: Synchronous — nil the controller reference.
		let oldController = harness.coordinator.prepareClaudeCancelSync(harness.session)
		XCTAssertNotNil(oldController)
		XCTAssertNil(harness.session.claudeController, "Controller must be nil'd immediately")

		// Step 2: Async — interrupt + shutdown the old process.
		await harness.coordinator.cancelClaudeRun(harness.session, oldController: oldController)

		let snapshot = await harness.controller.snapshot()
		XCTAssertEqual(snapshot.interruptTurnCallCount, 1)
		XCTAssertEqual(snapshot.shutdownCallCount, 1)
	}

	/// Regression: queued Claude steering claims superseding protection before the
	/// MCP-idle wait, so the original turn can complete during that wait without
	/// finalizing the run or restoring the steering draft.
	func testQueuedClaudeSteeringSurvivesOriginalCompletionDuringMCPIdleWait() async {
		let mcpIdleGate = RunnerMCPIdleGate()
		let harness = makeHarness()
		await harness.controller.setInterruptCurrentTurnShouldSucceed(true)
		await startRun(harness)

		guard let runID = harness.session.runID,
			let runAttemptID = harness.session.activeHeadlessRunAttemptID,
			let originalTurnID = harness.session.claudeExpectedTurnIDs.first else {
			XCTFail("Expected active Claude run with a tracked original turn")
			return
		}

		let runService = makeRunService(harness: harness) { waitedRunID in
			XCTAssertEqual(waitedRunID, runID)
			try await mcpIdleGate.wait()
		}
		let steering = AgentModeViewModel.TabSession.ClaudeSteeringInstruction(
			id: UUID(),
			targetRunID: runID,
			targetRunAttemptID: runAttemptID,
			providerText: "steer after tool",
			attachments: [],
			taggedFileAttachments: [],
			draftText: "steer after tool",
			optimisticUserItemID: nil,
			createdAt: Date(),
			supersedingProtectedTurnIDs: []
		)
		harness.session.pendingClaudeSteeringInstructions.append(steering)
		runService.protectCurrentClaudeTurnForAcceptedSteeringIfNeeded(
			session: harness.session,
			steeringID: steering.id
		)

		XCTAssertEqual(harness.session.pendingSupersedingTurnCompletions, 1)
		XCTAssertEqual(harness.session.claudeSupersedingProtectedTurnIDs, Set([originalTurnID]))

		let accepted = await runService.submitQueuedClaudeSteeringIfSupported(session: harness.session)
		XCTAssertTrue(accepted)

		let flushWaitingForMCPIdle = await waitForCondition(timeoutSeconds: 1.0) {
			await mcpIdleGate.waitCallCount() == 1
		}
		XCTAssertTrue(flushWaitingForMCPIdle, "Expected queued steering flush to wait for MCP idle")

		await harness.controller.emitTurnCompleted(.completed, turnID: originalTurnID)
		let originalCompletionSuppressed = await waitForCondition(timeoutSeconds: 1.0) {
			harness.session.agentTask != nil
				&& harness.session.runState == .running
				&& harness.session.pendingSupersedingTurnCompletions == 0
				&& harness.session.claudeSupersedingProtectedTurnIDs.isEmpty
		}
		XCTAssertTrue(originalCompletionSuppressed, "Original turn completion during MCP idle wait should not finalize the run")

		await mcpIdleGate.release()
		let steeringSent = await waitForCondition(timeoutSeconds: 1.0) {
			let snapshot = await harness.controller.snapshot()
			return snapshot.sendUserMessageCallCount == 2
				&& harness.session.pendingClaudeSteeringInstructions.isEmpty
		}
		XCTAssertTrue(steeringSent, "Queued steering should send after MCP tools go idle")
		XCTAssertTrue(harness.hooks.restoredDraftTexts.isEmpty, "Steering draft should not be restored after the original turn completed")

		guard let steeringTurnID = await harness.controller.lastSentTurnID else {
			XCTFail("Expected steering send to register a turn ID")
			return
		}
		await harness.controller.emitTurnCompleted(.completed, turnID: steeringTurnID)
		let completed = await waitForCondition(timeoutSeconds: 1.0) {
			harness.session.agentTask == nil && harness.session.runState == .completed
		}
		XCTAssertTrue(completed)
		XCTAssertTrue(harness.hooks.restoredDraftTexts.isEmpty)
	}

	func testQueuedClaudeSteeringWaitsForChildAgentRunWaitScopesBeforeInterrupting() async {
		let harness = makeHarness()
		await harness.controller.setInterruptCurrentTurnShouldSucceed(true)
		await startRun(harness)

		guard let runID = harness.session.runID,
			let runAttemptID = harness.session.activeHeadlessRunAttemptID else {
			XCTFail("Expected active Claude run")
			return
		}

		let childWaitGate = RunnerChildAgentWaitGate()
		let runService = makeRunService(
			harness: harness,
			awaitNoActiveMCPTools: { waitedRunID in
				XCTAssertEqual(waitedRunID, runID)
			},
			activeAgentRunWaitQuery: { waitedRunID in
				XCTAssertEqual(waitedRunID, runID)
				return childWaitGate.recordQueryAndReturnIsActive()
			},
			childAgentRunWaitDrainTimeoutSeconds: 5.0
		)
		let steering = AgentModeViewModel.TabSession.ClaudeSteeringInstruction(
			id: UUID(),
			targetRunID: runID,
			targetRunAttemptID: runAttemptID,
			providerText: "steer after child wait",
			attachments: [],
			taggedFileAttachments: [],
			draftText: "steer after child wait",
			optimisticUserItemID: nil,
			createdAt: Date(),
			supersedingProtectedTurnIDs: []
		)
		harness.session.pendingClaudeSteeringInstructions.append(steering)

		let accepted = await runService.submitQueuedClaudeSteeringIfSupported(session: harness.session)
		XCTAssertTrue(accepted)

		let observedChildWaitGate = await waitForCondition(timeoutSeconds: 1.0) {
			childWaitGate.queryCallCount > 0
		}
		XCTAssertTrue(observedChildWaitGate, "Expected queued steering to consult child agent_run wait scopes")
		let blockedSnapshot = await harness.controller.snapshot()
		XCTAssertEqual(blockedSnapshot.sendUserMessageCallCount, 1)
		XCTAssertEqual(blockedSnapshot.interruptTurnCallCount, 0)
		XCTAssertEqual(harness.session.pendingClaudeSteeringInstructions.count, 1)

		childWaitGate.isActive = false
		let steeringSent = await waitForCondition(timeoutSeconds: 1.0) {
			let snapshot = await harness.controller.snapshot()
			return snapshot.sendUserMessageCallCount == 2
				&& snapshot.interruptTurnCallCount == 1
				&& harness.session.pendingClaudeSteeringInstructions.isEmpty
		}
		XCTAssertTrue(steeringSent, "Queued steering should send after child agent_run wait scopes drain")
	}

	func testSubmitQueuedClaudeSteeringReturnsTrueWhenFlushTaskAlreadyActiveAndQueueEmpty() async {
		let harness = makeHarness()
		harness.session.runState = .running
		harness.session.activeHeadlessRunAttemptID = UUID()
		harness.session.pendingClaudeSteeringInstructions = []
		let activeFlushTask: Task<Void, Never> = Task {
			do {
				try await Task.sleep(nanoseconds: 5_000_000_000)
			} catch {}
		}
		harness.session.claudeSteeringFlushTask = activeFlushTask
		defer {
			activeFlushTask.cancel()
			harness.session.claudeSteeringFlushTask = nil
		}

		let runService = makeRunService(harness: harness) { _ in
			XCTFail("Already-active flush guard should return before waiting for MCP idle")
		}

		let accepted = await runService.submitQueuedClaudeSteeringIfSupported(session: harness.session)

		XCTAssertTrue(accepted)
	}

	/// Verify that sendClaudeNativeMessage calls ensureEventsStreamReady before
	/// sending, so that events emitted by the controller between the send and the
	/// runner's events(for:) subscription are buffered rather than silently dropped.
	func testSendEnsuresEventsStreamReadyBeforeSending() async {
		let harness = makeHarness()
		await startRun(harness)

		// Allow the steering interrupt to succeed (the initial send set turnInFlight).
		await harness.controller.setInterruptCurrentTurnShouldSucceed(true)

		let snapshotBefore = await harness.controller.snapshot()
		let ensureCountBefore = snapshotBefore.ensureEventsStreamReadyCallCount

		let sent = await harness.coordinator.sendClaudeNativeMessage(
			session: harness.session,
			text: "follow-up message",
			attachments: []
		)
		XCTAssertTrue(sent)

		let snapshotAfter = await harness.controller.snapshot()
		XCTAssertGreaterThan(
			snapshotAfter.ensureEventsStreamReadyCallCount, ensureCountBefore,
			"sendClaudeNativeMessage must call ensureEventsStreamReady before sending"
		)

		// Clean up.
		await harness.controller.emitTurnCompleted(.completed)
		let completed = await waitForCondition(timeoutSeconds: 1.0) {
			harness.session.agentTask == nil && harness.session.runState == .completed
		}
		XCTAssertTrue(completed)
	}

	/// Regression test: when the events stream ends unexpectedly (without a terminal
	/// turnCompleted event), the runner should surface a diagnostic error bubble.
	func testEventsStreamEndingUnexpectedlySurfacesDiagnosticError() async {
		let harness = makeHarness()
		await startRun(harness)

		// Finish the stream without emitting a turnCompleted — simulates the stream
		// being replaced or the process exiting without proper cleanup.
		await harness.controller.finish()

		let failed = await waitForCondition(timeoutSeconds: 1.0) {
			harness.session.agentTask == nil && harness.session.runState == .failed
		}
		XCTAssertTrue(failed)
		XCTAssertTrue(
			harness.session.items.contains(where: {
				$0.kind == .error && $0.text.contains("events stream ended unexpectedly")
			}),
			"Expected diagnostic error bubble when events stream ends without turnCompleted"
		)
	}

	func testStartRunRegistersClaudeToolTrackerForRunID() async {
		let harness = makeHarness()
		let runID = harness.session.runID ?? UUID()
		await ServerNetworkManager.shared.unregisterToolObservers(for: runID)

		await startRun(harness)

		let trackerRegistered = await waitForCondition(timeoutSeconds: 1.0) {
			let observerCount = await ServerNetworkManager.shared.toolEventObserverCount(for: runID)
			return observerCount == 1
		}
		XCTAssertTrue(trackerRegistered)

		await harness.controller.emitTurnCompleted(.cancelled)
		_ = await waitForCondition(timeoutSeconds: 1.0) {
			harness.session.agentTask == nil
		}
		await harness.controller.finish()
		await ServerNetworkManager.shared.unregisterToolObservers(for: runID)
	}

	func testRuntimeInitRepoPromptFailureFailsWithoutRetry() async {
		let harness = makeHarness()
		await startRun(harness)

		let failedInit = ClaudeNativeProcessSessionController.RuntimeInitStatus(
			sessionID: "session-1",
			tools: ["Bash", "TaskStop"],
			mcpServerStatuses: ["RepoPrompt": "failed"],
			initializeResponse: nil
		)

		await harness.controller.emit(.runtimeInit(failedInit))
		let failed = await waitForCondition(timeoutSeconds: 1.0) {
			harness.session.agentTask == nil && harness.session.runState == .failed
		}
		XCTAssertTrue(
			failed,
			"runState=\(harness.session.runState) agentTaskNil=\(harness.session.agentTask == nil) items=\(harness.session.items.map { $0.text })"
		)

		let snapshot = await harness.controller.snapshot()
		XCTAssertEqual(snapshot.sendUserMessageCallCount, 1, "Runner should fail immediately without retry")
		let leaseSnapshot = await harness.leaseRecorder.snapshot()
		XCTAssertEqual(leaseSnapshot.mcpEnableCount, 1)
		XCTAssertEqual(leaseSnapshot.policyInstallCount, 1)
		XCTAssertEqual(harness.hooks.notifyAgentTurnCompleteCount, 0)
		XCTAssertTrue(
			harness.session.items.contains(where: {
				$0.kind == .error && $0.text.contains("RepoPrompt MCP failed to initialize for Claude")
			}),
			"items=\(harness.session.items.map { "\($0.kind.rawValue):\($0.text)" })"
		)
	}

	func testRuntimeInitPersistsProviderSessionID() async {
		let harness = makeHarness()
		await startRun(harness)

		// Session should not have a provider session ID yet (controller returns "session-1"
		// via startOrResume, but runtime init can provide a different/updated one).
		let initialSessionID = harness.session.providerSessionID

		let status = ClaudeNativeProcessSessionController.RuntimeInitStatus(
			sessionID: "session-from-runtime-init",
			tools: ["Bash"],
			mcpServerStatuses: [:],
			initializeResponse: nil
		)
		await harness.controller.emit(.runtimeInit(status))

		// Give the event loop a moment to process.
		try? await Task.sleep(nanoseconds: 50_000_000)

		XCTAssertEqual(harness.session.providerSessionID, "session-from-runtime-init")
		XCTAssertTrue(harness.session.isDirty)

		// Emit the same session ID again — should not trigger another save.
		let saveCountBefore = harness.hooks.scheduleSaveCount
		await harness.controller.emit(.runtimeInit(status))
		try? await Task.sleep(nanoseconds: 50_000_000)
		XCTAssertEqual(harness.hooks.scheduleSaveCount, saveCountBefore, "Should not save again for same session ID")

		// Clean up
		await harness.controller.emitTurnCompleted(.completed)
		_ = await waitForCondition(timeoutSeconds: 1.0) {
			harness.session.agentTask == nil
		}
	}

	func testRuntimeInitWithNilSessionIDDoesNotOverwrite() async {
		let harness = makeHarness()
		await startRun(harness)

		// First set a session ID
		let status1 = ClaudeNativeProcessSessionController.RuntimeInitStatus(
			sessionID: "session-known",
			tools: [],
			mcpServerStatuses: [:],
			initializeResponse: nil
		)
		await harness.controller.emit(.runtimeInit(status1))
		try? await Task.sleep(nanoseconds: 50_000_000)
		XCTAssertEqual(harness.session.providerSessionID, "session-known")

		// Emit runtime init without session ID — should not clear it
		let status2 = ClaudeNativeProcessSessionController.RuntimeInitStatus(
			sessionID: nil,
			tools: ["Bash"],
			mcpServerStatuses: [:],
			initializeResponse: nil
		)
		await harness.controller.emit(.runtimeInit(status2))
		try? await Task.sleep(nanoseconds: 50_000_000)
		XCTAssertEqual(harness.session.providerSessionID, "session-known", "Nil session ID should not overwrite")

		// Clean up
		await harness.controller.emitTurnCompleted(.completed)
		_ = await waitForCondition(timeoutSeconds: 1.0) {
			harness.session.agentTask == nil
		}
	}

	func testCancelRunPublishesCancelledBeforeTerminalPersistencePrepCompletes() async {
		let harness = makeHarness()
		let terminalPersistence = SuspendedTerminalPersistence()
		let service = makeRunService(
			harness: harness,
			awaitNoActiveMCPTools: { _ in },
			prepareForTerminalPersistence: { session, terminalState, reason in
				await terminalPersistence.prepare(
					session: session,
					terminalState: terminalState,
					reason: reason
				)
			}
		)
		harness.session.runState = .running
		harness.session.runID = UUID()
		harness.session.activeAgentRunStartedAt = Date()

		let task = Task {
			await service.cancelRun(tabID: harness.session.tabID, session: harness.session, waitForCleanup: false)
		}
		let didEnterPersistencePrep = await terminalPersistence.waitUntilEntered()
		XCTAssertTrue(didEnterPersistencePrep)
		guard didEnterPersistencePrep else { return }

		XCTAssertEqual(harness.session.runState, .cancelled)
		XCTAssertNil(harness.session.activeAgentRunStartedAt)
		XCTAssertEqual(harness.hooks.setAgentRunActiveValues, [false])
		XCTAssertEqual(harness.hooks.updateBindingsCount, 1)
		XCTAssertEqual(harness.hooks.scheduleSaveCount, 0)
		XCTAssertLessThan(
			harness.hooks.events.firstIndex(of: "updateBindings") ?? Int.max,
			harness.hooks.events.firstIndex(of: "prepareForTerminalPersistence") ?? Int.max
		)

		terminalPersistence.resume()
		await task.value
		XCTAssertEqual(harness.hooks.scheduleSaveCount, 1)
	}

	func testCancelRunSkipsTerminalSaveWhenSessionRestartsDuringPersistencePrep() async {
		let harness = makeHarness()
		let terminalPersistence = SuspendedTerminalPersistence()
		let service = makeRunService(
			harness: harness,
			awaitNoActiveMCPTools: { _ in },
			prepareForTerminalPersistence: { session, terminalState, reason in
				await terminalPersistence.prepare(
					session: session,
					terminalState: terminalState,
					reason: reason
				)
			}
		)
		harness.session.runState = .running
		harness.session.runID = UUID()
		harness.session.activeAgentRunStartedAt = Date()

		let task = Task {
			await service.cancelRun(tabID: harness.session.tabID, session: harness.session, waitForCleanup: false)
		}
		let didEnterPersistencePrep = await terminalPersistence.waitUntilEntered()
		XCTAssertTrue(didEnterPersistencePrep)
		guard didEnterPersistencePrep else { return }

		harness.session.runState = .running
		harness.session.runID = UUID()
		harness.session.activeAgentRunStartedAt = Date()
		terminalPersistence.resume()
		await task.value

		XCTAssertEqual(harness.hooks.scheduleSaveCount, 0)
	}

	private typealias Harness = (
		runner: ClaudeIntegratedAgentModeRunner,
		coordinator: ClaudeAgentModeCoordinator,
		session: AgentModeViewModel.TabSession,
		controller: RunnerTestClaudeController,
		hooks: RunnerHookRecorder,
		lease: MCPBootstrapLease,
		leaseRecorder: RunnerLeaseRecorder
	)

	private func makeHarness() -> Harness {
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .claudeCode
		session.runID = UUID()

		let controller = RunnerTestClaudeController(returnedSessionID: "session-1")
		let hooks = RunnerHookRecorder()
		let leaseRecorder = RunnerLeaseRecorder()
		let coordinator = ClaudeAgentModeCoordinator(
			windowID: 1,
			workspacePathProvider: { "/tmp/workspace" },
			claudeControllerFactory: { _, _, _, _, _, _, _ in controller }
		)
		let runner = ClaudeIntegratedAgentModeRunner(
			claudeCoordinator: coordinator,
			hooks: makeHooks(recorder: hooks)
		)
		let runID = session.runID ?? UUID()
		session.runID = runID
		let tabID = session.tabID
		let makeLease: () -> MCPBootstrapLease = {
			let leaseSpec = MCPBootstrapLeaseSpec.agentMode(
				tabID: tabID,
				runID: runID,
				gateID: UUID(),
				windowID: 1,
				agent: .claudeCode
			)
			return MCPBootstrapLease(
				spec: leaseSpec,
				mcpServerEnabler: {
					await leaseRecorder.recordMcpEnable()
				},
				policyInstaller: MCPBootstrapLease.agentModePolicyInstaller({ _, _, _, _, _, _, _, runID, _, _, _, _, _ in
					await leaseRecorder.recordPolicyInstall()
					if let runID {
						MCPRoutingWaiter.signalRouted(runID)
					}
				})
			)
		}
		let lease = makeLease()

		return (runner, coordinator, session, controller, hooks, lease, leaseRecorder)
	}

	private func makeRunService(
		harness: Harness,
		awaitNoActiveMCPTools: @escaping (_ runID: UUID) async throws -> Void,
		activeAgentRunWaitQuery: @escaping (_ runID: UUID) -> Bool = { _ in false },
		childAgentRunWaitDrainTimeoutSeconds: TimeInterval = 2.0,
		prepareForTerminalPersistence: ((AgentModeViewModel.TabSession, AgentSessionRunState, String) async -> Void)? = nil
	) -> AgentModeRunService {
		let codexCoordinator = CodexAgentModeCoordinator(
			windowID: 1,
			workspacePathProvider: { "/tmp/workspace" },
			codexControllerFactory: { _, _, _, _, _, _, _ in RunnerStubCodexController() },
			connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
			shouldManageCodexTooling: false
		)
		let dependencies = AgentModeRunService.Dependencies(
			windowID: 1,
			headlessProviderFactory: { _, _ in fatalError("Headless provider should not be used in Claude steering test") },
			acpProviderFactory: { _, _ in nil },
			acpControllerFactory: { _, _ in fatalError("ACP controller should not be used in Claude steering test") },
			connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
			mcpServerEnabler: {},
			workspacePathProvider: { "/tmp/workspace" },
			codexCoordinator: codexCoordinator,
			claudeCoordinator: harness.coordinator,
			shouldManageCodexTooling: false,
			providerRuntimePermissionResolver: { _, _ in AgentProviderRuntimePermissionBinding() },
			cancelMCPToolsForRun: { _, _ in },
			awaitNoActiveMCPTools: awaitNoActiveMCPTools,
			activeAgentRunWaitQuery: activeAgentRunWaitQuery,
			childAgentRunWaitDrainTimeoutSeconds: childAgentRunWaitDrainTimeoutSeconds
		)
		return AgentModeRunService(
			dependencies: dependencies,
			hooks: makeHooks(
				recorder: harness.hooks,
				sessionForActiveRunUpdates: harness.session,
				prepareForTerminalPersistence: prepareForTerminalPersistence
			),
			toolTrackingHooks: .noOp
		)
	}

	private func makeHooks(
		recorder: RunnerHookRecorder,
		sessionForActiveRunUpdates: AgentModeViewModel.TabSession? = nil,
		prepareForTerminalPersistence: ((AgentModeViewModel.TabSession, AgentSessionRunState, String) async -> Void)? = nil
	) -> AgentModeRunService.Hooks {
		AgentModeRunService.Hooks(
			estimateRuntimeTokens: { $0.count },
			addUserInputTokensToActiveNonCodexTurn: { _, _ in },
			startNonCodexTurnAccountingIfNeeded: { _, _ in },
			reserveAttachmentsForTurn: { attachments, _ in
				attachments.isEmpty ? nil : UUID()
			},
			markAttachmentsConsumed: { _, _ in },
			stageConsumedAttachmentFilesForDeferredCleanup: { _, _ in },
			consumeDeferredAttachmentCleanup: { _, _ in
				recorder.consumeDeferredAttachmentCleanupCount += 1
			},
			finalizeAttachmentsForTurn: { _, _, _ in
				recorder.consumeDeferredAttachmentCleanupCount += 1
			},
			setAgentRunActive: { tabID, isActive in
				recorder.setAgentRunActiveValues.append(isActive)
				recorder.events.append("setAgentRunActive:\(isActive)")
				if sessionForActiveRunUpdates?.tabID == tabID {
					sessionForActiveRunUpdates?.activeAgentRunStartedAt = isActive
						? (sessionForActiveRunUpdates?.activeAgentRunStartedAt ?? Date())
						: nil
				}
			},
			updateBindings: { _ in
				recorder.updateBindingsCount += 1
				recorder.events.append("updateBindings")
			},
			requestUIRefresh: { _, _ in },
			scheduleSave: { _ in
				recorder.scheduleSaveCount += 1
				recorder.events.append("scheduleSave")
			},
			notifyAgentTurnComplete: { _ in
				recorder.notifyAgentTurnCompleteCount += 1
			},
			handleHeadlessStreamResult: { _, _, _, _ in
				recorder.handleHeadlessStreamResultCount += 1
			},
			buildHeadlessAgentMessage: { _, initialMessage, _, _, _ in
				AgentMessage(systemPrompt: "", userMessage: initialMessage)
			},
			prepareForTerminalPersistence: { session, terminalState, reason in
				recorder.events.append("prepareForTerminalPersistence")
				if let prepareForTerminalPersistence {
					await prepareForTerminalPersistence(session, terminalState, reason)
				} else {
					recorder.finalizePendingToolCallStates.append(terminalState)
					session.pendingAssistantDelta = ""
				}
			},
			finalizeStreamingItems: { _ in
				recorder.finalizeStreamingItemsCount += 1
			},
				finalizePendingToolCalls: { _, terminalState in
					recorder.finalizePendingToolCallStates.append(terminalState)
				},
				finalizePendingToolCallsWithUpperBound: { _, terminalState, upperBound in
					recorder.finalizePendingToolCallStates.append(terminalState)
					recorder.finalizePendingToolCallUpperBounds.append(upperBound)
				},
				finalizeNonCodexTurnUsage: { _, _, _, _ in
					recorder.finalizeNonCodexTurnUsageCount += 1
				},
			cancelPendingQuestion: { session in
				recorder.cancelPendingQuestionCount += 1
				session.pendingAskUser = nil
			},
			cancelPendingApproval: { session in
				recorder.cancelPendingApprovalCount += 1
				session.pendingApproval = nil
			},
			cancelPendingApplyEditsReview: { session, reason in
				recorder.cancelPendingApplyEditsReviewReasons.append(reason)
				session.pendingApplyEditsReview = nil
			},
			clearPendingAssistantDelta: { _ in },
			startFollowUpRun: { _, _ in
				recorder.startFollowUpRunCount += 1
			},
			restoreDraftText: { _, text, _, strategy in
				recorder.restoredDraftTexts.append(text)
				recorder.restoredDraftStrategies.append(strategy)
			},
			augmentUserMessageForProviderSend: { text, _, _, _ in text },
			stageResumeRecoveryHandoffIfNeeded: { _ in },
			prependPendingHandoffIfNeeded: { text, _ in text },
			recordPendingHandoffSendOutcome: { _, _ in },
			signalMCPInstructionDelivered: { _ in }
		)
	}

	private func startRun(_ harness: Harness) async {
		await harness.runner.startRun(
			tabID: harness.session.tabID,
			session: harness.session,
			initialUserMessage: "User prompt",
			initialMessageForRun: "User prompt",
			attachments: [],
			makeLease: { _ in harness.lease }
		)

		let sent = await waitForCondition(timeoutSeconds: 1.0) {
			let snapshot = await harness.controller.snapshot()
			return snapshot.sendUserMessageCallCount == 1
		}
		XCTAssertTrue(sent, "Expected runner to send initial user message")
	}

	private func makeApprovalRequest(id: String) -> AgentApprovalRequest {
		AgentApprovalRequest(
			requestID: .claudeControl(id),
			method: "control/can_use_tool",
			kind: .commandExecution,
			threadID: "thread",
			turnID: "turn",
			itemID: "item",
			command: "pwd"
		)
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

private final class RunnerChildAgentWaitGate {
	var isActive = true
	private(set) var queryCallCount = 0

	func recordQueryAndReturnIsActive() -> Bool {
		queryCallCount += 1
		return isActive
	}
}

private final class RunnerHookRecorder {
	var consumeDeferredAttachmentCleanupCount = 0
	var setAgentRunActiveValues: [Bool] = []
	var events: [String] = []
	var updateBindingsCount = 0
	var scheduleSaveCount = 0
	var notifyAgentTurnCompleteCount = 0
	var handleHeadlessStreamResultCount = 0
	var finalizeStreamingItemsCount = 0
	var finalizePendingToolCallStates: [AgentSessionRunState] = []
	var finalizePendingToolCallUpperBounds: [Int?] = []
	var finalizeNonCodexTurnUsageCount = 0
	var cancelPendingQuestionCount = 0
	var cancelPendingApprovalCount = 0
	var cancelPendingApplyEditsReviewReasons: [String] = []
	var startFollowUpRunCount = 0
	var restoredDraftTexts: [String] = []
	var restoredDraftStrategies: [AgentModeRunService.DraftRestorationStrategy] = []
}

@MainActor
private final class SuspendedTerminalPersistence {
	private var didEnter = false
	private var resumeContinuation: CheckedContinuation<Void, Never>?

	func prepare(
		session _: AgentModeViewModel.TabSession,
		terminalState _: AgentSessionRunState,
		reason _: String
	) async {
		didEnter = true
		await withCheckedContinuation { continuation in
			resumeContinuation = continuation
		}
	}

	func waitUntilEntered(timeoutSeconds: TimeInterval = 1.0) async -> Bool {
		let deadline = Date().addingTimeInterval(timeoutSeconds)
		while !didEnter && Date() < deadline {
			try? await Task.sleep(nanoseconds: 10_000_000)
		}
		return didEnter
	}

	func resume() {
		resumeContinuation?.resume()
		resumeContinuation = nil
	}
}

private actor RunnerLeaseRecorder {
	private(set) var mcpEnableCount = 0
	private(set) var policyInstallCount = 0

	func recordMcpEnable() {
		mcpEnableCount += 1
	}

	func recordPolicyInstall() {
		policyInstallCount += 1
	}

	func snapshot() -> (mcpEnableCount: Int, policyInstallCount: Int) {
		(mcpEnableCount, policyInstallCount)
	}
}

private actor RunnerMCPIdleGate {
	private var waitContinuations: [CheckedContinuation<Void, Error>] = []
	private var waits = 0

	func wait() async throws {
		try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { continuation in
				waits += 1
				waitContinuations.append(continuation)
			}
		} onCancel: {
			Task { await self.cancelAll() }
		}
	}

	func release() {
		let continuations = waitContinuations
		waitContinuations.removeAll()
		continuations.forEach { $0.resume() }
	}

	func cancelAll() {
		let continuations = waitContinuations
		waitContinuations.removeAll()
		continuations.forEach { $0.resume(throwing: CancellationError()) }
	}

	func waitCallCount() -> Int {
		waits
	}
}

private final class RunnerStubCodexController: CodexSessionControlling {
	var hasActiveThread: Bool { false }
	var events: AsyncStream<CodexNativeSessionController.Event> {
		AsyncStream { $0.finish() }
	}

	func ensureEventsStreamReady() {}
	func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String) async throws -> CodexNativeSessionController.SessionRef {
		fatalError("RunnerStubCodexController should not be called")
	}
	func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String, model: String?, reasoningEffort: String?) async throws -> CodexNativeSessionController.SessionRef {
		fatalError("RunnerStubCodexController should not be called")
	}
	func sendUserMessage(_ text: String) async throws { fatalError("RunnerStubCodexController should not be called") }
	func sendUserTurn(text: String, images: [AgentImageAttachment]) async throws { fatalError("RunnerStubCodexController should not be called") }
	func sendUserTurn(text: String, images: [AgentImageAttachment], model: String?, reasoningEffort: String?) async throws { fatalError("RunnerStubCodexController should not be called") }
	func cancelCurrentTurn() async {}
	func shutdown() async {}
	func respondToServerRequest(id: CodexAppServerRequestID, result: [String: Any]) async {}
}

private actor RunnerTestClaudeController: ClaudeSessionControlling {
	struct Snapshot {
		let startOrResumeCallCount: Int
		let applyModelAndEffortCallCount: Int
		let sendUserMessageCallCount: Int
		let interruptTurnCallCount: Int
		let shutdownCallCount: Int
		let resetEventsStreamCallCount: Int
		let ensureEventsStreamReadyCallCount: Int
	}

	private let returnedSessionID: String?
	private let stream: AsyncStream<ClaudeNativeProcessSessionController.Event>
	private var continuation: AsyncStream<ClaudeNativeProcessSessionController.Event>.Continuation?
	private var currentSessionID: String?

	private var startOrResumeCallCount = 0
	private var applyModelAndEffortCallCount = 0
	private var sendUserMessageCallCount = 0
	private var interruptTurnCallCount = 0
	private var shutdownCallCount = 0
	private var resetEventsStreamCallCount = 0
	private var ensureEventsStreamReadyCallCount = 0
	private var activeSession = true
	private var turnInFlight = false
	private var interruptCurrentTurnShouldSucceed = false

	var hasActiveSession: Bool {
		activeSession
	}

	var hasTurnInFlight: Bool {
		turnInFlight
	}

	nonisolated var events: AsyncStream<ClaudeNativeProcessSessionController.Event> {
		stream
	}

	init(returnedSessionID: String?) {
		self.returnedSessionID = returnedSessionID
		self.currentSessionID = returnedSessionID
		var continuationRef: AsyncStream<ClaudeNativeProcessSessionController.Event>.Continuation?
		self.stream = AsyncStream { continuation in
			continuationRef = continuation
		}
		self.continuation = continuationRef
	}

	func ensureEventsStreamReady() {
		ensureEventsStreamReadyCallCount += 1
	}
	func resetEventsStreamForNewRun() {
		resetEventsStreamCallCount += 1
	}

	func startOrResume(
		existingSessionID _: String?,
		model _: String?,
		effortLevel _: ClaudeCodeEffortLevel?,
		systemPromptOverride _: String?
	) async throws -> ClaudeNativeProcessSessionController.SessionRef {
		startOrResumeCallCount += 1
		activeSession = true
		currentSessionID = returnedSessionID ?? currentSessionID
		return ClaudeNativeProcessSessionController.SessionRef(sessionID: returnedSessionID)
	}

	func currentSessionRef() async -> ClaudeNativeProcessSessionController.SessionRef {
		ClaudeNativeProcessSessionController.SessionRef(sessionID: currentSessionID)
	}

	func applyModelAndEffort(model _: String?, effortLevel _: ClaudeCodeEffortLevel?) async throws {
		applyModelAndEffortCallCount += 1
	}

	private(set) var sentTurnIDs: [UUID] = []
	var lastSentTurnID: UUID? { sentTurnIDs.last }

	@discardableResult
	func sendUserMessage(_: String) async throws -> UUID {
		sendUserMessageCallCount += 1
		turnInFlight = true
		let turnID = UUID()
		sentTurnIDs.append(turnID)
		return turnID
	}

	func interruptTurn(reason: String) async -> ClaudeNativeProcessSessionController.InterruptOutcome {
		interruptTurnCallCount += 1
		guard turnInFlight else { return .noTurnInFlight }
		guard interruptCurrentTurnShouldSucceed else { return .failed }
		turnInFlight = false
		return .acknowledged
	}

	func shutdown() async {
		shutdownCallCount += 1
		activeSession = false
		turnInFlight = false
	}

	func respondToPermissionRequest(id _: String, decision _: AgentApprovalDecision) async {}

	func setInterruptCurrentTurnShouldSucceed(_ shouldSucceed: Bool) {
		interruptCurrentTurnShouldSucceed = shouldSucceed
	}

	func setTurnInFlight(_ value: Bool) {
		turnInFlight = value
	}

	func clearSentTurnIDs() {
		sentTurnIDs.removeAll()
	}

	func emit(_ event: ClaudeNativeProcessSessionController.Event) {
		if case .turnCompleted = event {
			turnInFlight = false
		}
		continuation?.yield(event)
	}

	/// Emit a turnCompleted event, consuming the oldest pending turnID (FIFO, mirroring
	/// the real controller's `pendingTurnIDs` queue).
	func emitTurnCompleted(_ status: ClaudeNativeProcessSessionController.TurnStatus) {
		let id: UUID
		if !sentTurnIDs.isEmpty {
			id = sentTurnIDs.removeFirst()
		} else {
			id = UUID()
		}
		emit(.turnCompleted(turnID: id, status: status))
	}

	/// Emit a turnCompleted event with an explicit (potentially stale) turnID.
	func emitTurnCompleted(_ status: ClaudeNativeProcessSessionController.TurnStatus, turnID: UUID) {
		emit(.turnCompleted(turnID: turnID, status: status))
	}

	func finish() {
		continuation?.finish()
	}

	func snapshot() -> Snapshot {
		Snapshot(
			startOrResumeCallCount: startOrResumeCallCount,
			applyModelAndEffortCallCount: applyModelAndEffortCallCount,
			sendUserMessageCallCount: sendUserMessageCallCount,
			interruptTurnCallCount: interruptTurnCallCount,
			shutdownCallCount: shutdownCallCount,
			resetEventsStreamCallCount: resetEventsStreamCallCount,
			ensureEventsStreamReadyCallCount: ensureEventsStreamReadyCallCount
		)
	}
}
