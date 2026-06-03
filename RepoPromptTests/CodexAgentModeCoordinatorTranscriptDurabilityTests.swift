import XCTest
@_spi(TestSupport) @testable import RepoPrompt

@MainActor
final class CodexAgentModeCoordinatorTranscriptDurabilityTests: XCTestCase {
	func testSummaryOnlyReasoningUpdatesStatusWithoutTranscriptItem() async {
		let coordinator = makeCoordinator()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec
		session.runState = .running

		await coordinator.test_handleCodexNativeEvent(
			.reasoningDelta(makeReasoningPayload(text: "**Doing X**", kind: .summary, itemID: "reasoning-1", groupID: "summary-1")),
			session: session
		)

		XCTAssertEqual(session.runningStatusText, "Doing X")
		XCTAssertEqual(session.runningStatusSource, .reasoning)
		assertNoThinkingItems(in: session)
		XCTAssertEqual(session.codexReasoningSegmentsByKey["reasoning:reasoning-1:0"]?.statusTitle, "Doing X")
	}

	func testSummaryTitleAndBodyStayOutOfTranscriptWhileStatusUpdates() async {
		let coordinator = makeCoordinator()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec
		session.runState = .running

		await coordinator.test_handleCodexNativeEvent(
			.reasoningDelta(makeReasoningPayload(text: "**Inspecting logs**", kind: .summary, itemID: "reasoning-1", groupID: "summary-1")),
			session: session
		)
		await coordinator.test_handleCodexNativeEvent(
			.reasoningDelta(makeReasoningPayload(text: "Looking at the last stack trace.", kind: .text, itemID: "reasoning-1", groupID: "text-1")),
			session: session
		)

		assertNoThinkingItems(in: session)
		XCTAssertEqual(session.runningStatusText, "Inspecting logs")
		XCTAssertEqual(session.codexReasoningSegmentsByKey["reasoning:reasoning-1:0"]?.summaryMarkdown, "**Inspecting logs**")
		XCTAssertEqual(session.codexReasoningSegmentsByKey["reasoning:reasoning-1:0"]?.bodyMarkdown, "Looking at the last stack trace.")
	}

	func testNonActivitySummaryDoesNotTakeStatusOrCreateTranscriptItem() async {
		let coordinator = makeCoordinator()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec
		session.runState = .running

		await coordinator.test_handleCodexNativeEvent(
			.reasoningDelta(makeReasoningPayload(text: "**Plan**", kind: .summary, itemID: "reasoning-2", groupID: "summary-2")),
			session: session
		)
		await coordinator.test_handleCodexNativeEvent(
			.reasoningDelta(makeReasoningPayload(text: "Compare the latest failures before editing.", kind: .text, itemID: "reasoning-2", groupID: "text-2")),
			session: session
		)

		assertNoThinkingItems(in: session)
		XCTAssertNil(session.runningStatusText)
		XCTAssertNil(session.runningStatusSource)
		XCTAssertEqual(session.codexReasoningSegmentsByKey["reasoning:reasoning-2:0"]?.summaryMarkdown, "**Plan**")
		XCTAssertEqual(session.codexReasoningSegmentsByKey["reasoning:reasoning-2:0"]?.bodyMarkdown, "Compare the latest failures before editing.")
	}

	func testReasoningWithoutItemIDStillMergesSummaryAndBodyByIndex() async {
		let coordinator = makeCoordinator()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec
		session.runState = .running

		await coordinator.test_handleCodexNativeEvent(
			.reasoningDelta(makeReasoningPayload(text: "**Inspecting logs**", kind: .summary, itemID: nil, groupID: nil, index: 0)),
			session: session
		)
		await coordinator.test_handleCodexNativeEvent(
			.reasoningDelta(makeReasoningPayload(text: "Found the failing request path.", kind: .text, itemID: nil, groupID: nil, index: 0)),
			session: session
		)

		assertNoThinkingItems(in: session)
		XCTAssertEqual(session.runningStatusText, "Inspecting logs")
		XCTAssertEqual(session.codexReasoningSegmentsByKey["reasoning-0"]?.summaryMarkdown, "**Inspecting logs**")
		XCTAssertEqual(session.codexReasoningSegmentsByKey["reasoning-0"]?.bodyMarkdown, "Found the failing request path.")
	}

	func testTextOnlyReasoningDoesNotCreateTranscriptItemOrStatus() async {
		let coordinator = makeCoordinator()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec
		session.runState = .running

		await coordinator.test_handleCodexNativeEvent(
			.reasoningDelta(makeReasoningPayload(text: "Inspecting stack traces without a summary.", kind: .text, itemID: "reasoning-text-only", groupID: "text-only")),
			session: session
		)

		assertNoThinkingItems(in: session)
		XCTAssertNil(session.runningStatusText)
		XCTAssertNil(session.runningStatusSource)
		XCTAssertEqual(session.codexReasoningSegmentsByKey["reasoning:reasoning-text-only:0"]?.bodyMarkdown, "Inspecting stack traces without a summary.")
	}

	func testAdjacentSummaryHeadersAreSeparatedBeforeStatusParsing() async {
		let coordinator = makeCoordinator()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec
		session.runState = .running

		await coordinator.test_handleCodexNativeEvent(
			.reasoningDelta(makeReasoningPayload(text: "**Analyzing skill invocation architecture**", kind: .summary, itemID: "reasoning-3", groupID: "summary-3")),
			session: session
		)
		await coordinator.test_handleCodexNativeEvent(
			.reasoningDelta(makeReasoningPayload(text: "**Planning**", kind: .summary, itemID: "reasoning-3", groupID: "summary-3")),
			session: session
		)
		await coordinator.test_handleCodexNativeEvent(
			.reasoningDelta(makeReasoningPayload(text: "Compare the current invocation path before editing.", kind: .text, itemID: "reasoning-3", groupID: "text-3")),
			session: session
		)

		let segment = session.codexReasoningSegmentsByKey["reasoning:reasoning-3:0"]
		assertNoThinkingItems(in: session)
		XCTAssertEqual(
			segment?.summaryMarkdown,
			"**Analyzing skill invocation architecture**\n\n**Planning**"
		)
		XCTAssertFalse(segment?.summaryMarkdown.contains("****") ?? true)
		XCTAssertEqual(segment?.bodyMarkdown, "Compare the current invocation path before editing.")
		XCTAssertEqual(session.runningStatusText, "Planning")
	}

	func testLaterSummaryHeaderBecomesRunningStatusInsteadOfAppendingIntoFirstTitle() async {
		let coordinator = makeCoordinator()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec
		session.runState = .running

		await coordinator.test_handleCodexNativeEvent(
			.reasoningDelta(makeReasoningPayload(text: "**Designing prompt helper**", kind: .summary, itemID: "reasoning-4", groupID: "summary:reasoning-4:0")),
			session: session
		)
		await coordinator.test_handleCodexNativeEvent(
			.reasoningDelta(makeReasoningPayload(text: "**Planning**", kind: .summary, itemID: "reasoning-4", groupID: "summary:reasoning-4:0")),
			session: session
		)

		assertNoThinkingItems(in: session)
		XCTAssertEqual(session.runningStatusText, "Planning")
		XCTAssertFalse(session.runningStatusText?.contains("Designing") ?? true)
	}

	func testNonQualifyingSummaryClearsPreviousReasoningStatus() async {
		let coordinator = makeCoordinator()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec
		session.runState = .running

		await coordinator.test_handleCodexNativeEvent(
			.reasoningDelta(makeReasoningPayload(text: "**Inspecting logs**", kind: .summary, itemID: "reasoning-4b", groupID: "summary:reasoning-4b:0")),
			session: session
		)
		XCTAssertEqual(session.runningStatusText, "Inspecting logs")
		XCTAssertEqual(session.runningStatusSource, .reasoning)

		await coordinator.test_handleCodexNativeEvent(
			.reasoningDelta(makeReasoningPayload(text: "**Plan**", kind: .summary, itemID: "reasoning-4b", groupID: "summary:reasoning-4b:0")),
			session: session
		)

		assertNoThinkingItems(in: session)
		XCTAssertNil(session.runningStatusText)
		XCTAssertNil(session.runningStatusSource)
	}

	func testDistinctReasoningIndicesDoNotMergeWhenItemIDIsShared() async {
		let coordinator = makeCoordinator()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec
		session.runState = .running

		await coordinator.test_handleCodexNativeEvent(
			.reasoningDelta(makeReasoningPayload(text: "**Inspecting logs**", kind: .summary, itemID: "reasoning-5", groupID: "summary:reasoning-5:0", index: 0)),
			session: session
		)
		await coordinator.test_handleCodexNativeEvent(
			.reasoningDelta(makeReasoningPayload(text: "Found the failing request path.", kind: .text, itemID: "reasoning-5", groupID: "text:reasoning-5:0", index: 0)),
			session: session
		)
		await coordinator.test_handleCodexNativeEvent(
			.reasoningDelta(makeReasoningPayload(text: "**Planning**", kind: .summary, itemID: "reasoning-5", groupID: "summary:reasoning-5:1", index: 1)),
			session: session
		)
		await coordinator.test_handleCodexNativeEvent(
			.reasoningDelta(makeReasoningPayload(text: "Drafting the patch steps.", kind: .text, itemID: "reasoning-5", groupID: "text:reasoning-5:1", index: 1)),
			session: session
		)

		assertNoThinkingItems(in: session)
		XCTAssertEqual(session.codexReasoningSegmentsByKey["reasoning:reasoning-5:0"]?.bodyMarkdown, "Found the failing request path.")
		XCTAssertEqual(session.codexReasoningSegmentsByKey["reasoning:reasoning-5:1"]?.bodyMarkdown, "Drafting the patch steps.")
		XCTAssertEqual(session.runningStatusText, "Planning")
	}

	func testScheduledAssistantDeltaFlushMutatesSessionWithoutViewModel() async {
		let coordinator = makeCoordinator()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.runState = .running

		await coordinator.test_handleCodexNativeEvent(.assistantDelta("stream"), session: session)
		let didFlush = await waitForCondition(timeoutSeconds: 1.0) {
			session.pendingAssistantDelta.isEmpty
				&& session.items.contains(where: { $0.kind == .assistant && $0.text.contains("stream") })
		}

		XCTAssertTrue(didFlush)
		let assistantItem = session.items.first(where: { $0.kind == .assistant && $0.text.contains("stream") })
		XCTAssertTrue(assistantItem?.isStreaming ?? false)
	}

	func testWhitespaceAssistantDeltaAppendsToExistingStreamingAssistant() async {
		let coordinator = makeCoordinator()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.runState = .running

		await coordinator.test_handleCodexNativeEvent(.assistantDelta("Hello"), session: session)
		let didFlush = await waitForCondition(timeoutSeconds: 1.0) {
			session.pendingAssistantDelta.isEmpty
				&& session.items.contains(where: { $0.kind == .assistant && $0.text == "Hello" && $0.isStreaming })
		}
		XCTAssertTrue(didFlush)

		await coordinator.test_handleCodexNativeEvent(.assistantDelta(" \n\t"), session: session)
		await coordinator.test_handleCodexNativeEvent(.turnCompleted(turnID: nil, status: .completed), session: session)

		let assistantRows = session.items.filter { $0.kind == .assistant }
		XCTAssertEqual(assistantRows.map(\.text), ["Hello \n\t"])
		XCTAssertFalse(assistantRows.first?.isStreaming ?? true)
	}

	func testAssistantDeltaBufferInsertsNewlineAcrossSentenceSeam() async {
		let coordinator = makeCoordinator()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec
		session.runState = .running

		await coordinator.test_handleCodexNativeEvent(.assistantDelta("Build is still running."), session: session)
		await coordinator.test_handleCodexNativeEvent(.assistantDelta("I’m keeping the same xcodetester job active."), session: session)

		XCTAssertEqual(
			session.pendingAssistantDelta,
			"Build is still running.\nI’m keeping the same xcodetester job active."
		)

		await coordinator.test_handleCodexNativeEvent(
			.commandExecutionRunning(.init(invocationID: nil, processID: "4242", appendedOutput: nil)),
			session: session
		)

		XCTAssertEqual(session.items.last?.kind, .assistant)
		XCTAssertEqual(
			session.items.last?.text,
			"Build is still running.\nI’m keeping the same xcodetester job active."
		)
	}

	func testTurnCompletedFlushesPendingAssistantDeltaWithoutViewModel() async {
		let coordinator = makeCoordinator()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.runState = .running

		await coordinator.test_handleCodexNativeEvent(.assistantDelta("hello"), session: session)
		await coordinator.test_handleCodexNativeEvent(.turnCompleted(turnID: nil, status: .completed), session: session)

		XCTAssertTrue(session.pendingAssistantDelta.isEmpty)
		XCTAssertNil(session.assistantDeltaFlushTask)
		let assistantItem = session.items.first(where: { $0.kind == .assistant && $0.text.contains("hello") })
		XCTAssertNotNil(assistantItem)
		XCTAssertFalse(assistantItem?.isStreaming ?? true)
		XCTAssertTrue(session.codexReasoningSegmentsByKey.isEmpty)
		XCTAssertNil(session.runningStatusSource)
	}

	func testErrorFlushesPendingAssistantDeltaWithoutViewModel() async {
		let coordinator = makeCoordinator()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.runState = .running

		await coordinator.test_handleCodexNativeEvent(.assistantDelta("partial"), session: session)
		await coordinator.test_handleCodexNativeEvent(.error("boom"), session: session)

		XCTAssertTrue(session.pendingAssistantDelta.isEmpty)
		XCTAssertNil(session.assistantDeltaFlushTask)

		guard let assistantIndex = session.items.firstIndex(where: { $0.kind == .assistant && $0.text.contains("partial") }) else {
			return XCTFail("Expected flushed assistant item before error")
		}
		guard let errorIndex = session.items.firstIndex(where: { $0.kind == .error && $0.text.contains("boom") }) else {
			return XCTFail("Expected error item")
		}
		XCTAssertLessThan(assistantIndex, errorIndex)
	}

	func testServerRequestIssueFlushesPendingAssistantDeltaAndFinalizesRun() async {
		let coordinator = makeCoordinator()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.runState = .running

		await coordinator.test_handleCodexNativeEvent(.assistantDelta("partial"), session: session)
		await coordinator.test_handleCodexNativeEvent(
			.serverRequestIssue(
				.init(
					requestID: .string("req-unsupported"),
					method: "workspace/unknownOperation",
					kind: .unsupportedMethod,
					message: "Unsupported Codex server request method: workspace/unknownOperation"
				)
			),
			session: session
		)

		XCTAssertTrue(session.pendingAssistantDelta.isEmpty)
		XCTAssertNil(session.assistantDeltaFlushTask)
		XCTAssertEqual(session.runState, .failed)

		guard let assistantIndex = session.items.firstIndex(where: { $0.kind == .assistant && $0.text.contains("partial") }) else {
			return XCTFail("Expected flushed assistant item before server request issue")
		}
		guard let errorIndex = session.items.firstIndex(where: { $0.kind == .error && $0.text.contains("Unsupported Codex server request method") }) else {
			return XCTFail("Expected server request issue error item")
		}
		XCTAssertLessThan(assistantIndex, errorIndex)
	}

	func testRawUnauthorizedErrorTriggersManagedAuthRecoveryReplay() async {
		let controller = TranscriptDurabilityAuthRecoveryController()
		let authRecovery = TranscriptDurabilityMockAuthRecovery(results: [.recovered])
		let coordinator = makeCoordinator(
			controllerFactory: { controller },
			authRecovery: authRecovery
		)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec
		session.runState = .running
		session.runID = UUID()
		session.codexPendingAuthRetryTurn = .init(
			text: "retry me",
			images: [],
			model: nil,
			reasoningEffort: nil,
			serviceTier: nil,
			attachmentReservationID: nil
		)

		await coordinator.test_handleCodexNativeEvent(
			.error("unexpected status 401 Unauthorized: Missing bearer or basic authentication in header, url: https://api.openai.com/v1/responses"),
			session: session
		)

		let refreshCallCount = await authRecovery.refreshCallCount()
		XCTAssertEqual(refreshCallCount, 1)
		XCTAssertEqual(controller.startCallCount(), 1)
		XCTAssertEqual(controller.sendTexts(), ["retry me"])
		XCTAssertEqual(session.runState, .running)
		XCTAssertEqual(session.runningStatusText, "Waiting for response…")
		XCTAssertTrue(session.items.allSatisfy { $0.kind != .error })
	}

	func testManagedAuthRecoveryManualLoginFallbackMarksReconnectNeededForNextTurn() async {
		let authRecovery = TranscriptDurabilityMockAuthRecovery(results: [
			.requiresUserLogin(message: CodexManagedAuthRecoveryClassifier.manualLoginGuidanceMessage)
		])
		let coordinator = makeCoordinator(authRecovery: authRecovery)
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec
		session.runState = .running
		session.runID = UUID()
		session.codexPendingAuthRetryTurn = .init(
			text: "retry me",
			images: [],
			model: nil,
			reasoningEffort: nil,
			serviceTier: nil,
			attachmentReservationID: nil
		)

		await coordinator.test_handleCodexNativeEvent(
			.error("unexpected status 401 Unauthorized: Missing bearer or basic authentication in header, url: https://api.openai.com/v1/responses"),
			session: session
		)

		let refreshCallCount = await authRecovery.refreshCallCount()
		XCTAssertEqual(refreshCallCount, 1)
		XCTAssertEqual(session.runState, .failed)
		XCTAssertTrue(session.codexNeedsReconnect, "Manual login fallback should force a fresh app-server session on the next turn")
		XCTAssertEqual(session.items.last?.kind, .error)
		XCTAssertEqual(session.items.last?.text, CodexManagedAuthRecoveryClassifier.manualLoginGuidanceMessage)
	}

	func testPendingAssistantDeltaFlushesBeforeNativeRepoPromptToolCallRenders() async {
		let coordinator = makeCoordinator()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec
		session.runState = .running

		await coordinator.test_handleCodexNativeEvent(.assistantDelta("before"), session: session)
		await coordinator.test_handleCodexNativeEvent(
			.toolCall(
				name: "mcp__RepoPrompt__read_file",
				invocationID: UUID(),
				argsJSON: #"{"path":"README.md"}"#
			),
			session: session
		)

		XCTAssertTrue(session.pendingAssistantDelta.isEmpty)
		guard let assistantIndex = session.items.firstIndex(where: { $0.kind == .assistant && $0.text == "before" }) else {
			return XCTFail("Expected flushed assistant item before native RepoPrompt tool call")
		}
		if let toolIndex = session.items.firstIndex(where: { $0.kind == .toolCall && $0.toolName == "mcp__RepoPrompt__read_file" }) {
			XCTAssertLessThan(session.items[assistantIndex].sequenceIndex, session.items[toolIndex].sequenceIndex)
		} else {
			XCTAssertEqual(session.items[assistantIndex].kind, .assistant)
			XCTAssertEqual(session.items[assistantIndex].text, "before")
		}
	}

	func testSuppressedRepoPromptToolCallStillSplitsAssistantTranscript() async {
		let coordinator = makeCoordinator()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec
		session.runState = .running

		await coordinator.test_handleCodexNativeEvent(.assistantDelta("before "), session: session)
		await coordinator.test_handleCodexNativeEvent(
			.toolCall(
				name: "mcp__RepoPrompt__read_file",
				invocationID: nil,
				argsJSON: #"{"path":"README.md"}"#
			),
			session: session
		)
		await coordinator.test_handleCodexNativeEvent(.assistantDelta("after"), session: session)
		await coordinator.test_handleCodexNativeEvent(.turnCompleted(turnID: nil, status: .completed), session: session)

		assertAssistantTexts(["before ", "after"], in: session)
		XCTAssertFalse(session.items.contains {
			($0.kind == .toolCall || $0.kind == .toolResult)
				&& $0.toolName == "mcp__RepoPrompt__read_file"
		})
	}

	func testPendingAssistantDeltaFlushesBeforeNativeRepoPromptToolResultRenders() async {
		let coordinator = makeCoordinator()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec
		session.runState = .running

		await coordinator.test_handleCodexNativeEvent(.assistantDelta("before"), session: session)
		await coordinator.test_handleCodexNativeEvent(
			.toolResult(
				name: "mcp__RepoPrompt__read_file",
				invocationID: UUID(),
				argsJSON: #"{"path":"README.md"}"#,
				resultJSON: #"{"content":"ok"}"#,
				isError: false
			),
			session: session
		)

		XCTAssertTrue(session.pendingAssistantDelta.isEmpty)
		guard let assistantIndex = session.items.firstIndex(where: { $0.kind == .assistant && $0.text == "before" }) else {
			return XCTFail("Expected flushed assistant item before native RepoPrompt tool result")
		}
		if let toolIndex = session.items.firstIndex(where: { $0.kind == .toolResult && $0.toolName == "mcp__RepoPrompt__read_file" }) {
			XCTAssertLessThan(session.items[assistantIndex].sequenceIndex, session.items[toolIndex].sequenceIndex)
		} else {
			XCTAssertEqual(session.items[assistantIndex].kind, .assistant)
			XCTAssertEqual(session.items[assistantIndex].text, "before")
		}
	}

	func testHiddenToolResultStillSplitsAssistantTranscript() async {
		let coordinator = makeCoordinator()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec
		session.runState = .running

		await coordinator.test_handleCodexNativeEvent(.assistantDelta("before "), session: session)
		await coordinator.test_handleCodexNativeEvent(
			.toolResult(
				name: "share_thoughts",
				invocationID: nil,
				argsJSON: nil,
				resultJSON: #"{"status":"completed"}"#,
				isError: false
			),
			session: session
		)
		await coordinator.test_handleCodexNativeEvent(.assistantDelta("after"), session: session)
		await coordinator.test_handleCodexNativeEvent(.turnCompleted(turnID: nil, status: .completed), session: session)

		assertAssistantTexts(["before ", "after"], in: session)
		XCTAssertFalse(session.items.contains { $0.toolName == "share_thoughts" })
	}

	func testRequestUserInputSetsPendingQuestionStateAndQueuesFollowUps() async {
		let coordinator = makeCoordinator()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec
		session.runState = .running

		await coordinator.test_handleCodexNativeEvent(.assistantDelta("before "), session: session)
		await coordinator.test_handleCodexNativeEvent(.requestUserInput(makeUserInputRequest(id: "first", questionID: "q1")), session: session)
		await coordinator.test_handleCodexNativeEvent(.requestUserInput(makeUserInputRequest(id: "second", questionID: "q2")), session: session)

		XCTAssertEqual(session.runState, .waitingForQuestion)
		XCTAssertEqual(session.pendingUserInputRequest?.requestID, .string("first"))
		XCTAssertEqual(session.queuedUserInputRequests.map(\.requestID), [.string("second")])
		assertAssistantTexts(["before "], in: session)
	}

	func testTurnCompletionClearsPendingRequestUserInputState() async {
		let coordinator = makeCoordinator()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec
		session.runState = .running
		session.pendingUserInputRequest = makeUserInputRequest(id: "pending", questionID: "q1")
		session.queuedUserInputRequests = [makeUserInputRequest(id: "queued", questionID: "q2")]

		await coordinator.test_handleCodexNativeEvent(.turnCompleted(turnID: nil, status: .completed), session: session)

		XCTAssertNil(session.pendingUserInputRequest)
		XCTAssertTrue(session.queuedUserInputRequests.isEmpty)
		XCTAssertEqual(session.runState, .completed)
	}

	func testApprovalRequestStillSplitsAssistantTranscript() async {
		let coordinator = makeCoordinator()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec
		session.runState = .running

		await coordinator.test_handleCodexNativeEvent(.assistantDelta("before "), session: session)
		await coordinator.test_handleCodexNativeEvent(.approvalRequest(makeApprovalRequest()), session: session)

		XCTAssertEqual(session.runState, .waitingForApproval)
		XCTAssertNotNil(session.pendingApproval)
		guard let firstAssistant = session.items.first(where: { $0.kind == .assistant }) else {
			return XCTFail("Expected first assistant item")
		}
		XCTAssertFalse(firstAssistant.isStreaming)

		session.pendingApproval = nil
		session.runState = .running
		await coordinator.test_handleCodexNativeEvent(.assistantDelta("after"), session: session)
		await coordinator.test_handleCodexNativeEvent(.turnCompleted(turnID: nil, status: .completed), session: session)

		assertAssistantTexts(["before ", "after"], in: session)
	}

	func testPollRunningUpdateStillSplitsAssistantTranscript() async {
		let coordinator = makeCoordinator()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec
		session.runState = .running

		await coordinator.test_handleCodexNativeEvent(.assistantDelta("before "), session: session)
		await coordinator.test_handleCodexNativeEvent(
			.commandExecutionRunning(
				.init(
					invocationID: nil,
					processID: "session:27588",
					appendedOutput: nil,
					sealsAssistantBoundary: true
				)
			),
			session: session
		)
		await coordinator.test_handleCodexNativeEvent(.assistantDelta("after"), session: session)
		await coordinator.test_handleCodexNativeEvent(.turnCompleted(turnID: nil, status: .completed), session: session)

		assertAssistantTexts(["before ", "after"], in: session)
	}

	func testStreamingCommandOutputDoesNotSplitAssistantTranscript() async {
		let coordinator = makeCoordinator()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec
		session.runState = .running

		await coordinator.test_handleCodexNativeEvent(.assistantDelta("before "), session: session)
		await coordinator.test_handleCodexNativeEvent(
			.commandExecutionRunning(
				.init(
					invocationID: nil,
					processID: "27588",
					appendedOutput: "chunk\n",
					sealsAssistantBoundary: false
				)
			),
			session: session
		)
		await coordinator.test_handleCodexNativeEvent(.assistantDelta("after"), session: session)
		await coordinator.test_handleCodexNativeEvent(.turnCompleted(turnID: nil, status: .completed), session: session)

		assertAssistantTexts(["before after"], in: session)
	}

	func testTrackerHiddenRepoPromptToolCallStillSplitsAssistantTranscript() async {
		let coordinator = makeCoordinator()
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		session.selectedAgent = .codexExec
		session.runState = .running

		await coordinator.test_handleCodexNativeEvent(.assistantDelta("before "), session: session)
		coordinator.testSimulateRepoPromptToolCall(
			invocationID: UUID(),
			toolName: "set_status",
			args: nil,
			session: session
		)
		await coordinator.test_handleCodexNativeEvent(.assistantDelta("after"), session: session)
		await coordinator.test_handleCodexNativeEvent(.turnCompleted(turnID: nil, status: .completed), session: session)

		assertAssistantTexts(["before ", "after"], in: session)
		XCTAssertFalse(session.items.contains { $0.toolName == "set_status" })
	}

	private func assertNoThinkingItems(in session: AgentModeViewModel.TabSession, file: StaticString = #filePath, line: UInt = #line) {
		XCTAssertTrue(session.items.allSatisfy { $0.kind != .thinking }, file: file, line: line)
	}

	private func assertAssistantTexts(
		_ expected: [String],
		in session: AgentModeViewModel.TabSession,
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		let assistants = session.items.filter { $0.kind == .assistant }
		XCTAssertEqual(assistants.map(\.text), expected, file: file, line: line)
		XCTAssertTrue(assistants.allSatisfy { !$0.isStreaming }, file: file, line: line)
	}

	private func makeReasoningPayload(
		text: String,
		kind: CodexNativeSessionController.ReasoningDeltaPayload.Kind,
		itemID: String?,
		groupID: String?,
		index: Int? = 0
	) -> CodexNativeSessionController.ReasoningDeltaPayload {
		.init(text: text, kind: kind, itemID: itemID, groupID: groupID, index: index)
	}

	private func makeApprovalRequest() -> AgentApprovalRequest {
		AgentApprovalRequest(
			requestID: .codex(.int(1)),
			method: "approval/request",
			kind: .commandExecution,
			threadID: "thread-1",
			turnID: "turn-1",
			itemID: "item-1",
			reason: "Need approval",
			command: "ls"
		)
	}

	private func makeUserInputRequest(id: String, questionID: String) -> AgentRequestUserInputRequest {
		AgentRequestUserInputRequest(
			requestID: .string(id),
			method: "item/tool/requestUserInput",
			threadID: "thread-1",
			turnID: "turn-1",
			itemID: "item-\(id)",
			questions: [
				.init(
					id: questionID,
					header: "Header",
					question: "What now?",
					isOther: false,
					isSecret: false,
					options: []
				)
			]
		)
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

	private func makeCoordinator(
		controllerFactory: @escaping () -> any CodexSessionControlling = { TranscriptDurabilityNoopCodexController() },
		authRecovery: any CodexManagedAuthRecovering = TranscriptDurabilityMockAuthRecovery(
			results: [.requiresUserLogin(message: CodexManagedAuthRecoveryClassifier.manualLoginGuidanceMessage)]
		)
	) -> CodexAgentModeCoordinator {
		CodexAgentModeCoordinator(
			windowID: 1,
			workspacePathProvider: { nil },
			codexControllerFactory: { _, _, _, _, _, _, _ in controllerFactory() },
			connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
			shouldManageCodexTooling: false,
			authRecovery: authRecovery
		)
	}
}

private actor TranscriptDurabilityMockAuthRecovery: CodexManagedAuthRecovering {
	private var queuedResults: [CodexManagedAuthRefreshResult]
	private var recordedRefreshCallCount = 0

	init(results: [CodexManagedAuthRefreshResult]) {
		self.queuedResults = results
	}

	func refreshManagedAccount() async -> CodexManagedAuthRefreshResult {
		recordedRefreshCallCount += 1
		if queuedResults.isEmpty {
			return .requiresUserLogin(message: CodexManagedAuthRecoveryClassifier.manualLoginGuidanceMessage)
		}
		return queuedResults.removeFirst()
	}

	func startManagedChatgptLogin(
		openURL: @MainActor @escaping @Sendable (URL) -> Void
	) async -> CodexManagedChatgptLoginResult {
		_ = openURL
		return .failed(message: "unused")
	}

	func refreshCallCount() -> Int {
		recordedRefreshCallCount
	}
}

private final class TranscriptDurabilityAuthRecoveryController: CodexSessionControlling {
	private let lock = NSLock()
	private var continuation: AsyncStream<CodexNativeSessionController.Event>.Continuation?
	private let stream: AsyncStream<CodexNativeSessionController.Event>
	private var recordedStartCallCount = 0
	private var recordedSendTexts: [String] = []

	var hasActiveThread: Bool {
		true
	}

	var events: AsyncStream<CodexNativeSessionController.Event> {
		stream
	}

	init() {
		var continuationRef: AsyncStream<CodexNativeSessionController.Event>.Continuation?
		stream = AsyncStream { continuation in
			continuationRef = continuation
		}
		continuation = continuationRef
	}

	func ensureEventsStreamReady() {}

	func startOrResume(
		existing: CodexNativeSessionController.SessionRef?,
		baseInstructions: String
	) async throws -> CodexNativeSessionController.SessionRef {
		try await startOrResume(existing: existing, baseInstructions: baseInstructions, model: nil, reasoningEffort: nil)
	}

	func startOrResume(
		existing: CodexNativeSessionController.SessionRef?,
		baseInstructions: String,
		model: String?,
		reasoningEffort: String?
	) async throws -> CodexNativeSessionController.SessionRef {
		lock.lock()
		recordedStartCallCount += 1
		lock.unlock()
		return CodexNativeSessionController.SessionRef(
			conversationID: "thread-1",
			rolloutPath: nil,
			model: model,
			reasoningEffort: reasoningEffort
		)
	}

	func sendUserMessage(_ text: String) async throws {
		try await sendUserTurn(text: text, images: [], model: nil, reasoningEffort: nil)
	}

	func sendUserTurn(text: String, images: [AgentImageAttachment]) async throws {
		try await sendUserTurn(text: text, images: images, model: nil, reasoningEffort: nil)
	}

	func sendUserTurn(
		text: String,
		images: [AgentImageAttachment],
		model: String?,
		reasoningEffort: String?
	) async throws {
		_ = images
		_ = model
		_ = reasoningEffort
		lock.lock()
		recordedSendTexts.append(text)
		lock.unlock()
	}

	func cancelCurrentTurn() async {}

	func shutdown() async {
		continuation?.finish()
	}

	func respondToServerRequest(id: CodexAppServerRequestID, result: [String: Any]) async {}

	func startCallCount() -> Int {
		lock.lock()
		defer { lock.unlock() }
		return recordedStartCallCount
	}

	func sendTexts() -> [String] {
		lock.lock()
		defer { lock.unlock() }
		return recordedSendTexts
	}
}

private final class TranscriptDurabilityNoopCodexController: CodexSessionControlling {
	private var continuation: AsyncStream<CodexNativeSessionController.Event>.Continuation?
	private let stream: AsyncStream<CodexNativeSessionController.Event>

	var hasActiveThread: Bool {
		false
	}

	var events: AsyncStream<CodexNativeSessionController.Event> {
		stream
	}

	init() {
		var continuationRef: AsyncStream<CodexNativeSessionController.Event>.Continuation?
		stream = AsyncStream { continuation in
			continuationRef = continuation
		}
		continuation = continuationRef
	}

	func ensureEventsStreamReady() {}

	func startOrResume(
		existing: CodexNativeSessionController.SessionRef?,
		baseInstructions: String
	) async throws -> CodexNativeSessionController.SessionRef {
		CodexNativeSessionController.SessionRef(conversationID: "", rolloutPath: nil, model: nil, reasoningEffort: nil)
	}

	func startOrResume(
		existing: CodexNativeSessionController.SessionRef?,
		baseInstructions: String,
		model: String?,
		reasoningEffort: String?
	) async throws -> CodexNativeSessionController.SessionRef {
		CodexNativeSessionController.SessionRef(conversationID: "", rolloutPath: nil, model: nil, reasoningEffort: nil)
	}

	func sendUserMessage(_ text: String) async throws {}

	func sendUserTurn(text: String, images: [AgentImageAttachment]) async throws {}

	func sendUserTurn(
		text: String,
		images: [AgentImageAttachment],
		model: String?,
		reasoningEffort: String?
	) async throws {}

	func cancelCurrentTurn() async {}

	func shutdown() async {
		continuation?.finish()
	}

	func respondToServerRequest(id: CodexAppServerRequestID, result: [String: Any]) async {}
}
