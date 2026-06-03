import XCTest
@testable import RepoPrompt

@MainActor
final class AgentModeViewModelSessionMutationTests: XCTestCase {
	func testColdLoadRebuildDegradesCollapsedGroupedHistorySections() async throws {
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			SessionMutationFakeCodexController()
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		let toolNames = ["read_file", "search", "read_file", "search", "read_file", "search", "read_file", "search", "read_file"]
		var items: [AgentChatItem] = [.user("Investigate", sequenceIndex: 0)]
		var sequenceIndex = 1
		for (offset, toolName) in toolNames.enumerated() {
			let invocationID = UUID()
			let argsJSON = toolName == "search"
				? #"{"pattern":"\#(Character(UnicodeScalar(65 + offset)!))"}"#
				: #"{"path":"\#(Character(UnicodeScalar(65 + offset)!)).swift"}"#
			items.append(.toolCall(name: toolName, invocationID: invocationID, argsJSON: argsJSON, sequenceIndex: sequenceIndex))
			sequenceIndex += 1
			items.append(.toolResult(name: toolName, invocationID: invocationID, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: sequenceIndex))
			sequenceIndex += 1
		}
		items.append(.assistant("Done", sequenceIndex: sequenceIndex))
		session.replaceItems(items)

		vm.test_rebuildStructuredTranscript(tabID: tabID)
		let warmGroupedHistoryBlock = try XCTUnwrap(
			session.transcriptProjection.workingBlocks.first(where: { $0.kind == .groupedHistory })
		)
		let warmGroupedHistory = try XCTUnwrap(warmGroupedHistoryBlock.groupedHistory)
		XCTAssertEqual(warmGroupedHistoryBlock.defaultPresentation, .collapsed)
		XCTAssertFalse(warmGroupedHistory.sections.isEmpty)

		vm.test_rebuildStructuredTranscript(tabID: tabID, isColdLoad: true)
		let restoredGroupedHistoryBlock = try XCTUnwrap(
			session.transcriptProjection.workingBlocks.first(where: { $0.kind == .groupedHistory })
		)
		let restoredGroupedHistory = try XCTUnwrap(restoredGroupedHistoryBlock.groupedHistory)

		XCTAssertTrue(restoredGroupedHistory.sections.isEmpty)
		XCTAssertEqual(restoredGroupedHistory.summary, warmGroupedHistory.summary)
	}

	func testMutateItemsBatchNoOpSkipsCallbacksAndDirtyStateChanges() async {
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			SessionMutationFakeCodexController()
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		var callbackCount = 0
		session.onSourceItemsChanged = { _, _ in
			callbackCount += 1
		}
		let rawDiff = """
		{"status":"success","changes":[{"path":"README.md","kind":"update","diff":"@@ -1 +1 @@"}],"change_count":1}
		"""
		let toolResult = AgentChatItem.toolResult(
			name: "apply_patch",
			invocationID: UUID(),
			resultJSON: rawDiff,
			isError: false,
			sequenceIndex: 0
		)
		session.replaceItems([toolResult])
		session.isDirty = false
		let originalLastActivityAt = session.lastActivityAt

		let didMutate = session.mutateItemsBatch(touchActivity: false) { _ in }

		XCTAssertFalse(didMutate)
		XCTAssertEqual(callbackCount, 1)
		XCTAssertFalse(session.isDirty)
		XCTAssertEqual(session.lastActivityAt, originalLastActivityAt)
		XCTAssertEqual(vm.test_ephemeralToolResultPayloadMap(tabID: tabID)[toolResult.id], rawDiff)
	}

	func testBashLiveExecutionUpdatesRuntimeLivenessWithoutSidebarVisibleActivity() async {
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			SessionMutationFakeCodexController()
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		let visibleActivity = Date(timeIntervalSince1970: 1_000)
		let runtimeSignal = Date(timeIntervalSince1970: 2_000)
		session.lastActivityAt = visibleActivity
		let sidebarTab = ComposeTabState(id: tabID, name: "Runtime", lastModified: visibleActivity)
		let beforeFingerprint = vm.makeSessionSidebarContentFingerprint(for: [sidebarTab])

		let firstExecution = Self.makeBashLiveExecution(lastSignalAt: runtimeSignal, executionKey: "first")
		session.setBashLiveExecution(firstExecution)

		XCTAssertEqual(session.lastActivityAt, visibleActivity)
		XCTAssertEqual(session.runtimeOnlyLivenessAt, runtimeSignal)
		XCTAssertEqual(session.effectiveRuntimeLivenessAt, runtimeSignal)
		XCTAssertEqual(vm.makeSessionSidebarContentFingerprint(for: [sidebarTab]), beforeFingerprint)

		session.runtimeOnlyLivenessAt = nil
		XCTAssertNotNil(session.removeBashLiveExecution(forKey: firstExecution.executionKey))
		XCTAssertEqual(session.lastActivityAt, visibleActivity)
		XCTAssertNotNil(session.runtimeOnlyLivenessAt)
		XCTAssertEqual(vm.makeSessionSidebarContentFingerprint(for: [sidebarTab]), beforeFingerprint)

		session.setBashLiveExecution(Self.makeBashLiveExecution(lastSignalAt: runtimeSignal, executionKey: "second"))
		session.runtimeOnlyLivenessAt = nil
		session.clearBashLiveExecutions()
		XCTAssertEqual(session.lastActivityAt, visibleActivity)
		XCTAssertNotNil(session.runtimeOnlyLivenessAt)
		XCTAssertEqual(vm.makeSessionSidebarContentFingerprint(for: [sidebarTab]), beforeFingerprint)

		session.runtimeOnlyLivenessAt = nil
		XCTAssertTrue(session.setRunningStatus("Connecting…", source: .transport))
		XCTAssertEqual(session.lastActivityAt, visibleActivity)
		XCTAssertNotNil(session.runtimeOnlyLivenessAt)
		XCTAssertEqual(vm.makeSessionSidebarContentFingerprint(for: [sidebarTab]), beforeFingerprint)
	}

	func testLiveBashRuntimeLivenessDoesNotReorderSidebarRows() async {
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			SessionMutationFakeCodexController()
		}
		let firstTabID = UUID()
		let secondTabID = UUID()
		let firstSession = await vm.ensureSessionReady(tabID: firstTabID)
		let secondSession = await vm.ensureSessionReady(tabID: secondTabID)
		firstSession.setItemsSilently([.assistant("First", sequenceIndex: 0)], reason: .testOverride)
		secondSession.setItemsSilently([.assistant("Second", sequenceIndex: 0)], reason: .testOverride)
		let firstSessionID = UUID()
		let secondSessionID = UUID()
		firstSession.activeAgentSessionID = firstSessionID
		secondSession.activeAgentSessionID = secondSessionID
		firstSession.lastActivityAt = Date(timeIntervalSince1970: 100)
		secondSession.lastActivityAt = Date(timeIntervalSince1970: 200)
		let tabs = [
			ComposeTabState(id: firstTabID, name: "First", lastModified: firstSession.lastActivityAt, activeAgentSessionID: firstSessionID),
			ComposeTabState(id: secondTabID, name: "Second", lastModified: secondSession.lastActivityAt, activeAgentSessionID: secondSessionID)
		]

		XCTAssertEqual(vm.sidebarSessions(for: tabs).map(\.tabID), [secondTabID, firstTabID])

		firstSession.setBashLiveExecution(Self.makeBashLiveExecution(lastSignalAt: Date(timeIntervalSince1970: 1_000)))

		XCTAssertEqual(firstSession.lastActivityAt, Date(timeIntervalSince1970: 100))
		XCTAssertEqual(vm.sidebarSessions(for: tabs).map(\.tabID), [secondTabID, firstTabID])
	}

	func testRunStateWaitingAndTerminalTransitionsTouchSidebarVisibleActivity() async {
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			SessionMutationFakeCodexController()
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		let baseline = Date(timeIntervalSince1970: 100)
		session.lastActivityAt = baseline

		session.runState = .running
		XCTAssertEqual(session.lastActivityAt, baseline)

		session.runState = .waitingForUser
		XCTAssertGreaterThan(session.lastActivityAt, baseline)

		session.runState = .running
		session.lastActivityAt = baseline
		session.runState = .completed
		XCTAssertGreaterThan(session.lastActivityAt, baseline)

		session.runState = .running
		session.lastActivityAt = baseline
		session.runState = .cancelled
		XCTAssertGreaterThan(session.lastActivityAt, baseline)

		session.runState = .running
		session.lastActivityAt = baseline
		session.runState = .failed
		XCTAssertGreaterThan(session.lastActivityAt, baseline)
	}

	func testHydratingPersistedRunStateDoesNotRewriteSavedActivityDate() async throws {
		let session = AgentModeViewModel.TabSession(tabID: UUID())
		let savedActivity = Date(timeIntervalSince1970: 123)
		session.lastActivityAt = savedActivity
		XCTAssertFalse(session.hasLoadedPersistedState)

		session.runState = .completed

		XCTAssertEqual(session.lastActivityAt, savedActivity)
	}

	func testMCPSnapshotUsesExplicitRuntimeLivenessForLiveOutput() async throws {
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			SessionMutationFakeCodexController()
		}
		let tabID = UUID()
		let sessionID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		let visibleActivity = Date(timeIntervalSince1970: 1_000)
		let runtimeSignal = Date(timeIntervalSince1970: 2_000)
		session.lastActivityAt = visibleActivity
		session.activeAgentSessionID = sessionID
		session.mcpControlContext = AgentModeViewModel.AgentMCPControlContext(
			sessionID: sessionID,
			activationID: UUID(),
			originatingConnectionID: nil,
			interactionTransport: .mcp(sessionID: sessionID, originatingConnectionID: nil),
			suppressUserNotifications: false,
			forceAutoEditEnabled: false,
			autoEditEnabledBeforeOverride: false,
			taskLabelKind: nil
		)

		session.setBashLiveExecution(Self.makeBashLiveExecution(lastSignalAt: runtimeSignal))

		let snapshot = try XCTUnwrap(vm.mcpSnapshot(sessionID: sessionID))
		XCTAssertEqual(snapshot.updatedAt, runtimeSignal)
		XCTAssertEqual(session.lastActivityAt, visibleActivity)
	}

	func testRunStateOnlyWaitingTransitionsScheduleAndPersistLastRunState() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let tabID = UUID()
		let windowState = await makeWindowState(
			root: tempRoot,
			composeTabs: [ComposeTabState(id: tabID, name: "Status", lastModified: Date())],
			activeComposeTabID: tabID
		)
		let vm = windowState.agentModeViewModel
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.appendItem(.user("Initial", sequenceIndex: session.nextSequenceIndex))
		await vm.flushSave(for: tabID)
		let sessionID = try XCTUnwrap(session.activeAgentSessionID)
		XCTAssertFalse(session.isDirty)
		XCTAssertNil(session.saveDebounceTask)

		func clearPendingInteractionState() {
			session.waitingPrompt = nil
			session.pendingAskUser = nil
			session.pendingApproval = nil
		}
		func persistAndAssert(_ targetState: AgentSessionRunState, configure: () -> Void) async throws {
			clearPendingInteractionState()
			configure()
			let previousSaveGeneration = session.saveGeneration

			session.runState = targetState

			XCTAssertTrue(session.isDirty)
			XCTAssertGreaterThan(session.saveGeneration, previousSaveGeneration)
			XCTAssertNotNil(session.saveDebounceTask)

			await vm.flushSave(for: tabID)

			let fileURL = tempRoot
				.appendingPathComponent("AgentSessions")
				.appendingPathComponent("AgentSession-\(sessionID.uuidString).json")
			let saved = try JSONDecoder().decode(AgentSession.self, from: Data(contentsOf: fileURL))
			XCTAssertEqual(saved.lastRunState, targetState.rawValue)
			XCTAssertEqual(vm.sessionIndex[sessionID]?.lastRunStateRaw, targetState.rawValue)
			XCTAssertFalse(session.isDirty)
			XCTAssertNil(session.saveDebounceTask)
		}

		try await persistAndAssert(.waitingForApproval) {
			session.pendingApproval = AgentApprovalRequest(
				requestID: .codex(.string("req-waiting-save")),
				method: "item/commandExecution/requestApproval",
				kind: .commandExecution,
				threadID: "thread-1",
				turnID: "turn-1",
				itemID: "call-1",
				command: "pwd"
			)
		}
		try await persistAndAssert(.waitingForUser) {
			session.waitingPrompt = "Need input"
		}
		try await persistAndAssert(.waitingForQuestion) {
			session.pendingAskUser = AgentAskUserPendingState(
				interaction: AgentAskUserInteraction(
					questions: [AgentAskUserQuestion(id: "continue", question: "Continue?")]
				)
			)
		}
		await windowState.tearDown()
	}

	func testRunStateOnlyRunningTransitionSchedulesAndPersistsLastRunState() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let tabID = UUID()
		let windowState = await makeWindowState(
			root: tempRoot,
			composeTabs: [ComposeTabState(id: tabID, name: "Status", lastModified: Date())],
			activeComposeTabID: tabID
		)
		let vm = windowState.agentModeViewModel
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.appendItem(.user("Initial", sequenceIndex: session.nextSequenceIndex))
		await vm.flushSave(for: tabID)
		let sessionID = try XCTUnwrap(session.activeAgentSessionID)
		XCTAssertFalse(session.isDirty)
		XCTAssertNil(session.saveDebounceTask)
		let previousSaveGeneration = session.saveGeneration

		session.runState = .running

		XCTAssertTrue(session.isDirty)
		XCTAssertGreaterThan(session.saveGeneration, previousSaveGeneration)
		XCTAssertNotNil(session.saveDebounceTask)

		await vm.flushSave(for: tabID)

		let fileURL = tempRoot
			.appendingPathComponent("AgentSessions")
			.appendingPathComponent("AgentSession-\(sessionID.uuidString).json")
		let saved = try JSONDecoder().decode(AgentSession.self, from: Data(contentsOf: fileURL))
		XCTAssertEqual(saved.lastRunState, AgentSessionRunState.running.rawValue)
		XCTAssertEqual(vm.sessionIndex[sessionID]?.lastRunStateRaw, AgentSessionRunState.running.rawValue)
		XCTAssertFalse(session.isDirty)
		XCTAssertNil(session.saveDebounceTask)
		await windowState.tearDown()
	}

	func testRunStateOnlyTerminalTransitionsScheduleAndPersistLastRunState() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let tabID = UUID()
		let windowState = await makeWindowState(
			root: tempRoot,
			composeTabs: [ComposeTabState(id: tabID, name: "Status", lastModified: Date())],
			activeComposeTabID: tabID
		)
		let vm = windowState.agentModeViewModel
		let workspace = try XCTUnwrap(windowState.workspaceManager.activeWorkspace)
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.appendItem(.user("Initial", sequenceIndex: session.nextSequenceIndex))
		await vm.flushSave(for: tabID)
		let sessionID = try XCTUnwrap(session.activeAgentSessionID)
		XCTAssertFalse(session.isDirty)
		XCTAssertNil(session.saveDebounceTask)

		for targetState in [AgentSessionRunState.completed, .failed, .cancelled] {
			let previousSaveGeneration = session.saveGeneration

			session.runState = targetState

			XCTAssertTrue(session.isDirty)
			XCTAssertGreaterThan(session.saveGeneration, previousSaveGeneration)
			XCTAssertNotNil(session.saveDebounceTask)

			await vm.flushSave(for: tabID)

			let loadedSession = try await vm.test_dataService.loadAgentSession(id: sessionID, for: workspace)
			let saved = try XCTUnwrap(loadedSession)
			XCTAssertEqual(saved.lastRunState, targetState.rawValue)
			XCTAssertEqual(vm.sessionIndex[sessionID]?.lastRunStateRaw, targetState.rawValue)
			XCTAssertFalse(session.isDirty)
			XCTAssertNil(session.saveDebounceTask)
		}
		await windowState.tearDown()
	}

	func testBackgroundRunStateAttentionStillAppearsForWaitingCompletedAndFailedSessions() async {
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			SessionMutationFakeCodexController()
		}
		let transitions: [AgentSessionRunState] = [.waitingForUser, .completed, .failed]
		for targetState in transitions {
			let session = await vm.ensureSessionReady(tabID: UUID())
			session.runState = .running
			vm.observeSidebarRunStateTransition(for: session)

			session.runState = targetState
			vm.observeSidebarRunStateTransition(for: session)

			XCTAssertEqual(vm.ui.sessionSidebar.attentionRunState(for: session.tabID), targetState)
		}
	}

	func testApplyingCapturedTranscriptPresentationAfterLiveReplacementPreservesRawEphemeralPayloadForLiveItems() async throws {
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			SessionMutationFakeCodexController()
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		let firstRawDiff = """
		{"status":"success","changes":[{"path":"README.md","kind":"update","diff":"@@ -1 +1 @@"}],"change_count":1}
		"""
		let secondRawDiff = """
		{"status":"success","changes":[{"path":"Package.swift","kind":"update","diff":"@@ -2 +2 @@"}],"change_count":1}
		"""
		let firstToolResult = AgentChatItem.toolResult(
			name: "apply_patch",
			invocationID: UUID(),
			resultJSON: firstRawDiff,
			isError: false,
			sequenceIndex: 0
		)
		let secondToolResult = AgentChatItem.toolResult(
			name: "apply_patch",
			invocationID: UUID(),
			resultJSON: secondRawDiff,
			isError: false,
			sequenceIndex: 1
		)
		session.replaceItems([firstToolResult])

		vm.test_applyTranscriptPresentationFromCapturedItems(tabID: tabID) { capturedSession in
			capturedSession.replaceItems([secondToolResult])
		}

		XCTAssertEqual(session.items.count, 1)
		let compactedToolResult = try XCTUnwrap(session.items.first)
		XCTAssertEqual(compactedToolResult.id, secondToolResult.id)
		XCTAssertEqual(compactedToolResult.sequenceIndex, secondToolResult.sequenceIndex)
		XCTAssertNotEqual(compactedToolResult.toolResultJSON, secondRawDiff)
		XCTAssertFalse(compactedToolResult.toolResultJSON?.contains("@@ -2 +2 @@") == true)
		XCTAssertTrue(compactedToolResult.toolResultJSON?.contains(#""summary_only":true"#) == true)
		var payloadMap = vm.test_ephemeralToolResultPayloadMap(tabID: tabID)
		XCTAssertEqual(payloadMap[secondToolResult.id], secondRawDiff)
		XCTAssertFalse(payloadMap[secondToolResult.id]?.contains(#""summary_only":true"#) == true)
		XCTAssertNil(payloadMap[firstToolResult.id])

		session.compactSummaryOnlyToolResultsAndAlignEphemeralPayloadMap()

		payloadMap = vm.test_ephemeralToolResultPayloadMap(tabID: tabID)
		XCTAssertEqual(session.items.first?.toolResultJSON, compactedToolResult.toolResultJSON)
		XCTAssertEqual(payloadMap[secondToolResult.id], secondRawDiff)
		XCTAssertNil(payloadMap[firstToolResult.id])

		let legacySummaryOnlyJSON = #"{"status":"success","summary_only":true,"summary_text":"legacy apply_patch summary"}"#
		var legacyCompactedToolResult = compactedToolResult
		legacyCompactedToolResult.toolResultJSON = legacySummaryOnlyJSON
		legacyCompactedToolResult.text = legacySummaryOnlyJSON
		session.setItemsSilently([legacyCompactedToolResult], reason: .testOverride)
		session.ephemeralToolResultPayloadByItemID = [
			secondToolResult.id: secondRawDiff,
			firstToolResult.id: firstRawDiff
		]

		session.compactSummaryOnlyToolResultsAndAlignEphemeralPayloadMap()

		payloadMap = vm.test_ephemeralToolResultPayloadMap(tabID: tabID)
		XCTAssertEqual(payloadMap[secondToolResult.id], secondRawDiff)
		XCTAssertFalse(payloadMap[secondToolResult.id]?.contains(#""summary_only":true"#) == true)
		XCTAssertNil(payloadMap[firstToolResult.id])
	}

	func testInactivePersistenceOnlySaveDoesNotApplyPresentationState() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let activeTabID = UUID()
		let inactiveTabID = UUID()
		let windowState = await makeWindowState(
			root: tempRoot,
			composeTabs: [
				ComposeTabState(id: activeTabID, name: "Active", lastModified: Date()),
				ComposeTabState(id: inactiveTabID, name: "Inactive", lastModified: Date())
			],
			activeComposeTabID: activeTabID
		)
		let vm = windowState.agentModeViewModel
		vm.test_setCurrentTabIDOverride(activeTabID)
		defer { vm.test_setCurrentTabIDOverride(nil) }
		let workspace = try XCTUnwrap(windowState.workspaceManager.activeWorkspace)
		let activeSession = await vm.ensureSessionReady(tabID: activeTabID)
		activeSession.setItemsSilently([.user("Active", sequenceIndex: 0)], reason: .testOverride)
		vm.test_rebuildStructuredTranscript(tabID: activeTabID)
		vm.test_applySessionToBindings(tabID: activeTabID)
		let activeSnapshot = vm.activeTranscriptPresentation
		let session = await vm.ensureSessionReady(tabID: inactiveTabID)
		let userTimestamp = Date(timeIntervalSince1970: 1_700_000_000)
		let userItem = AgentChatItem(
			timestamp: userTimestamp,
			kind: .user,
			text: "Question",
			sequenceIndex: 0
		)
		let assistantItem = AgentChatItem(
			timestamp: userTimestamp.addingTimeInterval(1),
			kind: .assistant,
			text: "Answer",
			sequenceIndex: 1
		)
		// Seed canonical source items silently so this remains a persistence-only
		// save guard: durability must not depend on publishing or rebuilding
		// active UI presentation for an inactive tab.
		session.setItemsSilently([userItem, assistantItem], reason: .testOverride)
		session.lastActivityAt = Date()
		session.lastUserMessageAt = userTimestamp
		session.isDirty = true
		session.transcript = .empty
		session.baseTranscriptProjection = .empty
		session.fullTranscriptProjection = .empty
		session.workingTranscriptProjection = .empty
		session.transcriptProjection = .empty
		session.turnProjectionCaches = [:]
		session.transcriptCanonicalVisibleRowCount = 0
		session.transcriptProjectionCounts = .zero
		session.derivedTranscriptSyncState = nil

		await vm.flushSave(for: inactiveTabID)

		XCTAssertFalse(session.isDirty)
		XCTAssertEqual(vm.activeTranscriptPresentation, activeSnapshot)
		XCTAssertTrue(session.transcript.turns.isEmpty)
		XCTAssertEqual(session.transcriptProjectionCounts, .zero)
		XCTAssertNil(session.derivedTranscriptSyncState)
		let sessionID = try XCTUnwrap(session.activeAgentSessionID)
		let loadedSession = try await vm.test_dataService.loadAgentSession(id: sessionID, for: workspace)
		let saved = try XCTUnwrap(loadedSession)
		let savedItems = saved.items.map { $0.toItem() }
		XCTAssertEqual(savedItems.map(\.kind), [.user, .assistant])
		XCTAssertEqual(savedItems.map(\.text), ["Question", "Answer"])
		XCTAssertEqual(saved.lastUserMessageAt, userTimestamp)
		let transcript = try XCTUnwrap(saved.transcript)
		let projectionCounts = AgentTranscriptProjectionBuilder.projectionCounts(for: transcript)
		XCTAssertEqual(saved.itemCount, projectionCounts.canonicalVisibleRowCount)
		XCTAssertEqual(saved.transcriptProjectionCounts, projectionCounts)
		XCTAssertEqual(saved.lastRunState, session.runState.rawValue)
		XCTAssertEqual(saved.agentKind, session.selectedAgent.rawValue)
		await windowState.tearDown()
	}

	func testInactivePendingToolSaveRepairUpdatesLiveItemsAndDerivedStateBeforeActivation() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let activeTabID = UUID()
		let inactiveTabID = UUID()
		let windowState = await makeWindowState(
			root: tempRoot,
			composeTabs: [
				ComposeTabState(id: activeTabID, name: "Active", lastModified: Date()),
				ComposeTabState(id: inactiveTabID, name: "Inactive", lastModified: Date())
			],
			activeComposeTabID: activeTabID
		)
		let vm = windowState.agentModeViewModel
		vm.test_setCurrentTabIDOverride(activeTabID)
		defer { vm.test_setCurrentTabIDOverride(nil) }
		let workspace = try XCTUnwrap(windowState.workspaceManager.activeWorkspace)
		_ = await vm.ensureSessionReady(tabID: activeTabID)
		let session = await vm.ensureSessionReady(tabID: inactiveTabID)
		session.selectedAgent = .codexExec
		session.runState = .failed
		let userTimestamp = Date(timeIntervalSince1970: 1_700_005_000)
		let invocationID = UUID()
		let userItem = AgentChatItem(
			timestamp: userTimestamp,
			kind: .user,
			text: "Read the file",
			sequenceIndex: 0
		)
		let pendingToolCall = AgentChatItem.toolCall(
			name: "read_file",
			invocationID: invocationID,
			argsJSON: #"{"path":"README.md"}"#,
			sequenceIndex: 1
		)
		session.setItemsSilently([userItem, pendingToolCall], reason: .testOverride)
		session.clearDerivedTranscriptCaches()
		session.lastActivityAt = Date()
		session.lastUserMessageAt = userTimestamp
		session.isDirty = true
		let activeSnapshot = vm.activeTranscriptPresentation
		let buildCountBeforeSave = session.transcriptPerformanceSnapshot.projectionBuildCount

		await vm.flushSave(for: inactiveTabID)

		XCTAssertFalse(session.isDirty)
		XCTAssertEqual(session.items.map(\.kind), [.user, .toolResult])
		let repairedLiveToolResult = try XCTUnwrap(session.items.last)
		XCTAssertEqual(repairedLiveToolResult.toolName, "read_file")
		XCTAssertEqual(repairedLiveToolResult.toolInvocationID, invocationID)
		XCTAssertEqual(repairedLiveToolResult.toolIsError, true)
		XCTAssertTrue(repairedLiveToolResult.toolResultJSON?.contains("failed") == true)
		XCTAssertGreaterThan(session.transcriptPerformanceSnapshot.projectionBuildCount, buildCountBeforeSave)
		XCTAssertEqual(session.workingTranscriptProjection.workingRows.map(\.kind), [.user, .toolResult])
		XCTAssertEqual(session.workingTranscriptProjection.workingRows.last?.toolInvocationID, invocationID)
		XCTAssertEqual(session.workingTranscriptProjection.workingRows.last?.toolIsError, true)
		XCTAssertEqual(session.derivedTranscriptSyncState?.sourceItemsRevision, session.sourceItemsRevision)
		XCTAssertEqual(vm.activeTranscriptPresentation, activeSnapshot)

		let sessionID = try XCTUnwrap(session.activeAgentSessionID)
		let loadedSaved = try await vm.test_dataService.loadAgentSession(id: sessionID, for: workspace)
		let saved = try XCTUnwrap(loadedSaved)
		let savedTranscript = try XCTUnwrap(saved.transcript)
		let savedItems = AgentTranscriptIO.workingSourceItems(from: savedTranscript)
		XCTAssertEqual(savedItems.map(\.kind), [.user, .toolResult])
		XCTAssertEqual(savedItems.last?.toolInvocationID, invocationID)
		XCTAssertEqual(savedItems.last?.toolIsError, true)

		let buildCountBeforeActivation = session.transcriptPerformanceSnapshot.projectionBuildCount
		vm.test_setCurrentTabIDOverride(inactiveTabID)
		vm.test_applySessionToBindings(tabID: inactiveTabID)

		XCTAssertEqual(session.transcriptPerformanceSnapshot.projectionBuildCount, buildCountBeforeActivation)
		XCTAssertEqual(vm.activeTranscriptPresentation.visibleRows.map(\.kind), [.user, .toolResult])
		XCTAssertEqual(vm.activeTranscriptPresentation.visibleRows.last?.toolInvocationID, invocationID)
		XCTAssertEqual(vm.activeTranscriptPresentation.visibleRows.last?.toolIsError, true)
		await windowState.tearDown()
	}

	func testInactiveMutationPersistsAndReloadsCanonicalSourceWithFreshDerivedState() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let activeTabID = UUID()
		let inactiveTabID = UUID()
		let windowState = await makeWindowState(
			root: tempRoot,
			composeTabs: [
				ComposeTabState(id: activeTabID, name: "Active", lastModified: Date()),
				ComposeTabState(id: inactiveTabID, name: "Inactive", lastModified: Date())
			],
			activeComposeTabID: activeTabID
		)
		let vm = windowState.agentModeViewModel
		vm.test_setCurrentTabIDOverride(activeTabID)
		defer { vm.test_setCurrentTabIDOverride(nil) }
		let workspace = try XCTUnwrap(windowState.workspaceManager.activeWorkspace)
		_ = await vm.ensureSessionReady(tabID: activeTabID)
		let session = await vm.ensureSessionReady(tabID: inactiveTabID)
		session.selectedAgent = .codexExec
		session.selectedModelRaw = "gpt-5.4"
		session.selectedReasoningEffortRaw = CodexReasoningEffort.high.rawValue
		session.providerSessionID = "inactive-provider-session"
		session.codexConversationID = "inactive-thread"
		session.codexRolloutPath = "/tmp/inactive-rollout.jsonl"
		session.codexModel = "gpt-5.4"
		session.codexReasoningEffort = CodexReasoningEffort.high.rawValue
		session.runState = .failed
		let userTimestamp = Date(timeIntervalSince1970: 1_700_010_000)
		let toolInvocationID = UUID()
		let items = [
			AgentChatItem(
				timestamp: userTimestamp,
				kind: .user,
				text: "Inspect the inactive session",
				sequenceIndex: 0
			),
			AgentChatItem(
				timestamp: userTimestamp.addingTimeInterval(1),
				kind: .assistant,
				text: "I will check it.",
				sequenceIndex: 1
			),
			AgentChatItem.toolCall(
				name: "read_file",
				invocationID: toolInvocationID,
				argsJSON: #"{"path":"README.md"}"#,
				sequenceIndex: 2
			),
			AgentChatItem.toolResult(
				name: "read_file",
				invocationID: toolInvocationID,
				resultJSON: #"{"status":"success","content":"Loaded"}"#,
				isError: false,
				sequenceIndex: 3
			)
		]
		let activeSnapshot = vm.activeTranscriptPresentation
		let buildCountBeforeMutation = session.transcriptPerformanceSnapshot.projectionBuildCount

		for item in items {
			session.appendItem(item)
		}
		await vm.test_drainScheduledDerivedTranscriptRefresh(tabID: inactiveTabID)

		XCTAssertNotNil(session.saveDebounceTask)
		XCTAssertGreaterThan(session.transcriptPerformanceSnapshot.projectionBuildCount, buildCountBeforeMutation)
		XCTAssertEqual(session.workingTranscriptProjection.workingRows.map(\.kind), [.user, .assistant, .toolCall, .toolResult])
		XCTAssertEqual(session.derivedTranscriptSyncState?.sourceItemsRevision, session.sourceItemsRevision)
		XCTAssertEqual(vm.activeTranscriptPresentation, activeSnapshot)
		XCTAssertTrue(session.isDirty)

		let buildCountBeforeSave = session.transcriptPerformanceSnapshot.projectionBuildCount
		await vm.flushSave(for: inactiveTabID)

		XCTAssertFalse(session.isDirty)
		XCTAssertNil(session.saveDebounceTask)
		XCTAssertGreaterThan(session.transcriptPerformanceSnapshot.projectionBuildCount, buildCountBeforeSave)
		XCTAssertEqual(session.workingTranscriptProjection.workingRows.map(\.kind), [.user, .assistant, .toolCall, .toolResult])
		XCTAssertFalse(session.transcript.turns.isEmpty)
		XCTAssertNotEqual(session.transcriptProjectionCounts, .zero)
		XCTAssertEqual(session.derivedTranscriptSyncState?.sourceItemsRevision, session.sourceItemsRevision)
		XCTAssertEqual(vm.activeTranscriptPresentation, activeSnapshot)

		let sessionID = try XCTUnwrap(session.activeAgentSessionID)
		let loadedSaved = try await vm.test_dataService.loadAgentSession(id: sessionID, for: workspace)
		let saved = try XCTUnwrap(loadedSaved)
		let savedTranscript = try XCTUnwrap(saved.transcript)
		let reloadedItems = AgentTranscriptIO.workingSourceItems(from: savedTranscript)
		let savedProjectionCounts = AgentTranscriptProjectionBuilder.projectionCounts(for: savedTranscript)
		XCTAssertEqual(reloadedItems.count, items.count)
		XCTAssertEqual(reloadedItems.prefix(2).map(\.kind), [.user, .assistant])
		XCTAssertEqual(reloadedItems.prefix(2).map(\.text), ["Inspect the inactive session", "I will check it."])
		let reloadedToolItems = reloadedItems.dropFirst(2)
		XCTAssertEqual(reloadedToolItems.map(\.kind), [.toolResult, .toolResult])
		XCTAssertEqual(reloadedToolItems.map(\.toolName), ["read_file", "read_file"])
		XCTAssertEqual(reloadedToolItems.map(\.toolInvocationID), [toolInvocationID, toolInvocationID])
		XCTAssertEqual(saved.itemCount, savedProjectionCounts.canonicalVisibleRowCount)
		XCTAssertEqual(saved.transcriptProjectionCounts, savedProjectionCounts)
		XCTAssertEqual(saved.lastUserMessageAt, userTimestamp)
		XCTAssertEqual(saved.lastRunState, AgentSessionRunState.failed.rawValue)
		XCTAssertEqual(saved.agentKind, DiscoverAgentKind.codexExec.rawValue)
		XCTAssertEqual(saved.agentModel, "gpt-5.4")
		XCTAssertEqual(saved.agentReasoningEffort, CodexReasoningEffort.high.rawValue)
		XCTAssertEqual(saved.providerSessionID, "inactive-provider-session")
		XCTAssertEqual(saved.codexConversationID, "inactive-thread")
		XCTAssertEqual(saved.codexRolloutPath, "/tmp/inactive-rollout.jsonl")
		XCTAssertEqual(saved.codexModel, "gpt-5.4")
		XCTAssertEqual(saved.codexReasoningEffort, CodexReasoningEffort.high.rawValue)

		let relaunchedWindowState = await makeWindowState(
			root: tempRoot,
			composeTabs: [
				ComposeTabState(id: activeTabID, name: "Active", lastModified: Date()),
				ComposeTabState(id: inactiveTabID, name: "Inactive", lastModified: Date(), activeAgentSessionID: sessionID)
			],
			activeComposeTabID: activeTabID
		)
		let reloadedWorkspace = try XCTUnwrap(relaunchedWindowState.workspaceManager.activeWorkspace)
		let loadedRelaunchedSaved = try await relaunchedWindowState.agentModeViewModel.test_dataService.loadAgentSession(id: sessionID, for: reloadedWorkspace)
		let reloadedSaved = try XCTUnwrap(loadedRelaunchedSaved)
		let reloadedTranscript = try XCTUnwrap(reloadedSaved.transcript)
		let relaunchedItems = AgentTranscriptIO.workingSourceItems(from: reloadedTranscript)
		XCTAssertEqual(relaunchedItems.count, items.count)
		XCTAssertEqual(relaunchedItems.prefix(2).map(\.text), ["Inspect the inactive session", "I will check it."])
		XCTAssertEqual(relaunchedItems.dropFirst(2).map(\.toolName), ["read_file", "read_file"])
		XCTAssertEqual(reloadedSaved.itemCount, savedProjectionCounts.canonicalVisibleRowCount)
		XCTAssertEqual(reloadedSaved.lastUserMessageAt, userTimestamp)
		XCTAssertEqual(reloadedSaved.lastRunState, AgentSessionRunState.failed.rawValue)
		XCTAssertEqual(reloadedSaved.agentKind, DiscoverAgentKind.codexExec.rawValue)
		XCTAssertEqual(reloadedSaved.codexConversationID, "inactive-thread")
		await relaunchedWindowState.tearDown()
		await windowState.tearDown()
	}

	func testScheduledLiveRefreshBuildsWhenSessionTurnsInactive() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let activeTabID = UUID()
		let otherTabID = UUID()
		let windowState = await makeWindowState(
			root: tempRoot,
			composeTabs: [
				ComposeTabState(id: activeTabID, name: "Active", lastModified: Date()),
				ComposeTabState(id: otherTabID, name: "Other", lastModified: Date())
			],
			activeComposeTabID: activeTabID
		)
		let vm = windowState.agentModeViewModel
		vm.test_setCurrentTabIDOverride(activeTabID)
		let session = await vm.ensureSessionReady(tabID: activeTabID)
		session.setItemsSilently([.user("Initial", sequenceIndex: 0)], reason: .testOverride)
		vm.test_rebuildStructuredTranscript(tabID: activeTabID)
		vm.test_applySessionToBindings(tabID: activeTabID)
		let activeSnapshot = vm.activeTranscriptPresentation
		let buildCount = session.transcriptPerformanceSnapshot.projectionBuildCount

		session.appendItem(.assistant("Deferred assistant", sequenceIndex: session.nextSequenceIndex))
		XCTAssertNotNil(session.derivedTranscriptRefreshTask)

		vm.test_setCurrentTabIDOverride(otherTabID)
		await vm.test_drainScheduledDerivedTranscriptRefresh(tabID: activeTabID)

		XCTAssertNil(session.derivedTranscriptRefreshTask)
		XCTAssertGreaterThan(session.transcriptPerformanceSnapshot.projectionBuildCount, buildCount)
		XCTAssertEqual(session.workingTranscriptProjection.workingRows.last?.text, "Deferred assistant")
		XCTAssertEqual(session.derivedTranscriptSyncState?.sourceItemsRevision, session.sourceItemsRevision)
		XCTAssertEqual(vm.activeTranscriptPresentation, activeSnapshot)
		XCTAssertTrue(session.isDirty)

		let buildCountAfterDrain = session.transcriptPerformanceSnapshot.projectionBuildCount
		vm.test_setCurrentTabIDOverride(activeTabID)
		vm.test_applySessionToBindings(tabID: activeTabID)

		XCTAssertEqual(session.transcriptPerformanceSnapshot.projectionBuildCount, buildCountAfterDrain)
		XCTAssertEqual(vm.activeTranscriptPresentation.visibleRows.last?.text, "Deferred assistant")
		vm.test_setCurrentTabIDOverride(nil)
		await windowState.tearDown()
	}

	func testCoalescedScheduledRefreshBuildsOnceWithLatestSourceItems() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let activeTabID = UUID()
		let otherTabID = UUID()
		let windowState = await makeWindowState(
			root: tempRoot,
			composeTabs: [
				ComposeTabState(id: activeTabID, name: "Active", lastModified: Date()),
				ComposeTabState(id: otherTabID, name: "Other", lastModified: Date())
			],
			activeComposeTabID: activeTabID
		)
		let vm = windowState.agentModeViewModel
		vm.test_setCurrentTabIDOverride(activeTabID)
		let session = await vm.ensureSessionReady(tabID: activeTabID)
		session.setItemsSilently([.user("Initial", sequenceIndex: 0)], reason: .testOverride)
		vm.test_rebuildStructuredTranscript(tabID: activeTabID)
		vm.test_applySessionToBindings(tabID: activeTabID)
		let activeSnapshot = vm.activeTranscriptPresentation
		let buildCount = session.transcriptPerformanceSnapshot.projectionBuildCount

		session.appendItem(.assistant("First scheduled", sequenceIndex: session.nextSequenceIndex))
		XCTAssertNotNil(session.derivedTranscriptRefreshTask)
		vm.test_setCurrentTabIDOverride(otherTabID)
		session.appendItem(.assistant("Inactive replacement trigger", sequenceIndex: session.nextSequenceIndex))
		XCTAssertNotNil(session.derivedTranscriptRefreshTask)

		await vm.test_drainScheduledDerivedTranscriptRefresh(tabID: activeTabID)

		let buildCountAfterDrain = session.transcriptPerformanceSnapshot.projectionBuildCount
		XCTAssertEqual(buildCountAfterDrain, buildCount + 1)
		XCTAssertEqual(session.workingTranscriptProjection.workingRows.last?.text, "Inactive replacement trigger")
		XCTAssertEqual(session.derivedTranscriptSyncState?.sourceItemsRevision, session.sourceItemsRevision)
		XCTAssertEqual(vm.activeTranscriptPresentation, activeSnapshot)

		vm.test_setCurrentTabIDOverride(activeTabID)
		vm.test_applySessionToBindings(tabID: activeTabID)

		XCTAssertEqual(session.transcriptPerformanceSnapshot.projectionBuildCount, buildCountAfterDrain)
		XCTAssertEqual(vm.activeTranscriptPresentation.visibleRows.last?.text, "Inactive replacement trigger")
		vm.test_setCurrentTabIDOverride(nil)
		await windowState.tearDown()
	}

	func testSilentReplacementInvalidatesDerivedStateAndActivationCatchUpRebuilds() async {
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			SessionMutationFakeCodexController()
		}
		let activeTabID = UUID()
		let inactiveTabID = UUID()
		let activeSession = await vm.ensureSessionReady(tabID: activeTabID)
		let inactiveSession = await vm.ensureSessionReady(tabID: inactiveTabID)
		activeSession.setItemsSilently([.user("Active", sequenceIndex: 0)], reason: .testOverride)
		inactiveSession.setItemsSilently([.user("Inactive initial", sequenceIndex: 0)], reason: .testOverride)
		vm.test_rebuildStructuredTranscript(tabID: activeTabID)
		vm.test_rebuildStructuredTranscript(tabID: inactiveTabID)
		vm.test_applySessionToBindings(tabID: activeTabID)
		let buildCount = inactiveSession.transcriptPerformanceSnapshot.projectionBuildCount

		inactiveSession.setItemsSilently(
			[.user("Replacement source", sequenceIndex: 0), .assistant("Replacement answer", sequenceIndex: 1)],
			reason: .retentionCompaction
		)
		XCTAssertNil(inactiveSession.derivedTranscriptSyncState)
		XCTAssertEqual(inactiveSession.transcriptPerformanceSnapshot.projectionBuildCount, buildCount)

		vm.test_setCurrentTabIDOverride(inactiveTabID)
		defer { vm.test_setCurrentTabIDOverride(nil) }
		vm.test_applySessionToBindings(tabID: inactiveTabID)

		XCTAssertGreaterThan(inactiveSession.transcriptPerformanceSnapshot.projectionBuildCount, buildCount)
		XCTAssertEqual(inactiveSession.derivedTranscriptSyncState?.sourceItemsRevision, inactiveSession.sourceItemsRevision)
		XCTAssertEqual(vm.activeTranscriptPresentation.visibleRows.map(\.text), ["Replacement source", "Replacement answer"])
	}

	func testLiveSanitizedApplyEditsCardPresentationUsesEphemeralRawDiffPayload() async throws {
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			SessionMutationFakeCodexController()
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		let rawDiff = "@@ -1 +1 @@\n-old\n+new"
		let rawResult = """
		{"status":"success","edits_requested":1,"edits_applied":1,"added_lines":1,"deleted_lines":1,"card_unified_diff":"@@ -1 +1 @@\\n-old\\n+new"}
		"""
		let toolResult = AgentChatItem.toolResult(
			name: "apply_edits",
			invocationID: UUID(),
			resultJSON: rawResult,
			isError: false,
			sequenceIndex: 0
		)
		session.replaceItems([toolResult])

		vm.test_rebuildStructuredTranscript(tabID: tabID)

		let compacted = try XCTUnwrap(session.items.first)
		XCTAssertFalse(compacted.toolResultJSON?.contains("card_unified_diff") == true)
		XCTAssertFalse(compacted.toolResultJSON?.contains(rawDiff) == true)
		let rawPayload = try XCTUnwrap(vm.rawToolResultPayloadForRendering(tabID: tabID, itemID: toolResult.id))
		let source = ToolJSON.resultPayloadSource(for: compacted, rawPayload: rawPayload)
		let presentation = ApplyEditsResultPresentation.build(for: compacted, payloadSource: source)

		XCTAssertEqual(presentation.displayDiff, rawDiff)
		XCTAssertEqual(presentation.renderMode, .diffPreview)
	}

	private static func makeBashLiveExecution(
		lastSignalAt: Date,
		transcriptItemID: UUID = UUID(),
		executionKey: String = UUID().uuidString
	) -> AgentModeViewModel.BashLiveExecutionState {
		AgentModeViewModel.BashLiveExecutionState(
			executionKey: executionKey,
			transcriptItemID: transcriptItemID,
			toolName: "bash",
			invocationID: UUID(),
			fallbackSignature: "bash:\(executionKey)",
			processID: "123",
			command: "echo hi",
			statusWord: "running",
			exitCode: nil,
			output: "hi",
			isSummaryOnly: false,
			lastSignalAt: lastSignalAt
		)
	}

	func testLiveSanitizedApplyPatchCardPresentationUsesEphemeralRawDiffPayload() async throws {
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			SessionMutationFakeCodexController()
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		let rawDiff = "@@ -1 +1 @@\n-old\n+new"
		let rawResult = """
		{"status":"success","changes":[{"path":"File.swift","kind":"update","diff":"@@ -1 +1 @@\\n-old\\n+new"}],"change_count":1}
		"""
		let toolResult = AgentChatItem.toolResult(
			name: "apply_patch",
			invocationID: UUID(),
			resultJSON: rawResult,
			isError: false,
			sequenceIndex: 0
		)
		session.replaceItems([toolResult])

		vm.test_rebuildStructuredTranscript(tabID: tabID)

		let compacted = try XCTUnwrap(session.items.first)
		let compactedJSON = try XCTUnwrap(compacted.toolResultJSON)
		let compactedSummary = try XCTUnwrap(ToolJSON.decodeResult(ToolResultDTOs.ApplyPatchSummary.self, from: compactedJSON))
		XCTAssertEqual(compactedSummary.summaryOnly, true)
		XCTAssertEqual(compactedSummary.changes.first?.diff, "")
		XCTAssertFalse(compactedJSON.contains(#"@@ -1 +1 @@\\n-old\\n+new"#))
		let rawPayload = try XCTUnwrap(vm.rawToolResultPayloadForRendering(tabID: tabID, itemID: toolResult.id))
		let source = ToolJSON.resultPayloadSource(for: compacted, rawPayload: rawPayload)
		let presentation = ApplyPatchResultPresentation.build(for: compacted, payloadSource: source)

		XCTAssertEqual(presentation.dto?.changes.first?.diff, rawDiff)
		XCTAssertEqual(presentation.renderMode, .diffPreview)
	}

	func testLiveSanitizedContextBuilderDTOUsesEphemeralRawPayload() async throws {
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			SessionMutationFakeCodexController()
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		let rawResult = """
		{"status":"completed","response_type":"review","file_count":3,"total_tokens":1234,"selection":"3 files","review":{"chat_id":"review-chat-123","mode":"review","response":"Looks good","errors":[]}}
		"""
		let toolResult = AgentChatItem.toolResult(
			name: "context_builder",
			invocationID: UUID(),
			resultJSON: rawResult,
			isError: false,
			sequenceIndex: 0
		)
		session.replaceItems([toolResult])

		vm.test_rebuildStructuredTranscript(tabID: tabID)

		let compacted = try XCTUnwrap(session.items.first)
		XCTAssertFalse(compacted.toolResultJSON?.contains("review-chat-123") == true)
		let rawPayload = try XCTUnwrap(vm.rawToolResultPayloadForRendering(tabID: tabID, itemID: toolResult.id))
		let source = ToolJSON.resultPayloadSource(for: compacted, rawPayload: rawPayload)
		let dto = ToolJSON.decodeResult(ToolResultDTOs.ContextBuilderDTO.self, from: source)

		XCTAssertEqual(dto?.responseType, "review")
		XCTAssertEqual(dto?.fileCount, 3)
		XCTAssertEqual(dto?.totalTokens, 1234)
		XCTAssertEqual(dto?.review?.chatID, "review-chat-123")
	}
}

@MainActor
private func makeWindowState(
	root: URL,
	composeTabs: [ComposeTabState],
	activeComposeTabID: UUID
) async -> WindowState {
	let windowState = WindowState()
	await windowState.workspaceManager.awaitInitialized()
	let workspace = WorkspaceModel(
		name: "Agent Session Mutation Tests",
		repoPaths: [],
		customStoragePath: root,
		composeTabs: composeTabs,
		activeComposeTabID: activeComposeTabID
	)
	windowState.workspaceManager.workspaces = [workspace]
	windowState.workspaceManager.activeWorkspace = workspace
	windowState.promptManager.loadComposeTabsFromWorkspace(workspace)
	return windowState
}

private func makeTempDirectory() -> URL {
	let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
		"RepoPrompt-AgentModeViewModelSessionMutationTests-\(UUID().uuidString)",
		isDirectory: true
	)
	try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
	return directory
}

private final class SessionMutationFakeCodexController: CodexSessionControlling {
	var hasActiveThread: Bool = false
	var events: AsyncStream<CodexNativeSessionController.Event> { AsyncStream { continuation in continuation.finish() } }

	func ensureEventsStreamReady() {}

	func startOrResume(
		existing _: CodexNativeSessionController.SessionRef?,
		baseInstructions _: String
	) async throws -> CodexNativeSessionController.SessionRef {
		hasActiveThread = true
		return CodexNativeSessionController.SessionRef(
			conversationID: "test-thread",
			rolloutPath: nil,
			model: "gpt-5.2-codex",
			reasoningEffort: "medium"
		)
	}

	func readThreadSnapshot(
		includeTurns _: Bool,
		timeout _: TimeInterval?
	) async throws -> CodexNativeSessionController.ThreadSnapshot {
		CodexNativeSessionController.ThreadSnapshot(
			conversationID: "test-thread",
			rolloutPath: nil,
			model: "gpt-5.2-codex",
			reasoningEffort: "medium",
			runtimeStatus: .idle,
			currentTurnID: nil,
			activeTurnIDs: [],
			latestTurnStatus: nil
		)
	}

	func sendUserMessage(_: String) async throws {}
	func sendUserTurn(text _: String, images _: [AgentImageAttachment]) async throws {}
	func sendUserTurn(text _: String, images _: [AgentImageAttachment], model _: String?, reasoningEffort _: String?) async throws {}
	func compactThread() async throws {}
	func cancelCurrentTurn() async {}
	func shutdown() async { hasActiveThread = false }
	func respondToServerRequest(id _: CodexAppServerRequestID, result _: [String: Any]) async {}
}
