import XCTest
import AppKit
import UniformTypeIdentifiers
import SwiftUI
import MCP
@testable import RepoPrompt

@MainActor
final class AgentModeViewModelCodexReconnectTests: XCTestCase {
	override func setUp() {
		super.setUp()
		CodexGoalSupport.setEnabledForTesting(true)
	}

	override func tearDown() {
		CodexGoalSupport.setEnabledForTesting(nil)
		CodexComputerUseWorkflow.setEnabledForTesting(nil)
		super.tearDown()
	}
	func testCodexActiveTurnMismatchParserExtractsActualTurnID() {
		let actual = CodexNativeSessionController.activeTurnMismatchActualTurnID(
			fromErrorDescription: "invalid request: expected active turn id `turn-old` but found `turn-new`"
		)

		XCTAssertEqual(actual, "turn-new")
	}

	func testCodexActiveTurnMismatchParserRejectsUnrelatedErrors() {
		XCTAssertNil(CodexNativeSessionController.activeTurnMismatchActualTurnID(fromErrorDescription: "transport closed"))
		XCTAssertNil(CodexNativeSessionController.activeTurnMismatchActualTurnID(fromErrorDescription: "expected active turn id `turn-old`"))
		XCTAssertNil(CodexNativeSessionController.activeTurnMismatchActualTurnID(fromErrorDescription: "expected active turn id `turn-old` but found ``"))
	}

	func testDraftTextIsStoredPerTabSession() {	
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			FakeCodexController()
		}

		let tabA = UUID()
		let tabB = UUID()
		vm.storeDraftText(for: tabA, "first draft")
		vm.storeDraftText(for: tabB, "second draft")

		XCTAssertEqual(vm.retrieveDraftText(for: tabA), "first draft")
		XCTAssertEqual(vm.retrieveDraftText(for: tabB), "second draft")

		vm.storeDraftText(for: tabA, "first draft updated")
		XCTAssertEqual(vm.retrieveDraftText(for: tabA), "first draft updated")
		XCTAssertEqual(vm.retrieveDraftText(for: tabB), "second draft")
	}


	func testDetachingTranscriptClearsStoredViewportAuthority() async throws {
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			FakeCodexController()
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.appendItem(AgentChatItem.user("Investigate", sequenceIndex: session.nextSequenceIndex))
		session.appendItem(AgentChatItem.assistant("Done", sequenceIndex: session.nextSequenceIndex))

		vm.setTranscriptDetachedFromLiveBottom(tabID: tabID, isDetached: true)

		XCTAssertTrue(session.transcriptViewportState.isDetachedFromLiveBottom)
		XCTAssertNil(session.transcriptViewportState.detachedAuthority)
	}

	func testApplySessionToBindingsPublishesPresentationAndAnchorMap() async {
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			FakeCodexController()
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.appendItem(AgentChatItem.user("Investigate", sequenceIndex: session.nextSequenceIndex))
		session.appendItem(AgentChatItem.assistant("Done", sequenceIndex: session.nextSequenceIndex))
		vm.test_applySessionToBindings(tabID: tabID)

		XCTAssertEqual(vm.activeTranscriptPresentation.tabID, tabID)
		XCTAssertEqual(vm.activeTranscriptPresentation.visibleRows.count, 2)
		XCTAssertFalse(vm.activeTranscriptAnchorBlockIndex.isEmpty)
	}

	func testApplySessionToBindingsRebuildsStaleProjectionThatUndercountsTranscript() async {
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			FakeCodexController()
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.runState = .completed
		session.appendItem(AgentChatItem.user("Investigate", sequenceIndex: session.nextSequenceIndex))
		vm.test_rebuildStructuredTranscript(tabID: tabID)

		let staleBaseProjection = session.baseTranscriptProjection
		let staleFullProjection = session.fullTranscriptProjection
		let staleWorkingProjection = session.workingTranscriptProjection
		let staleTranscriptProjection = session.transcriptProjection
		let staleArchivedSnapshot = session.archivedTranscriptSnapshot
		let staleProjectionProtection = session.transcriptProjectionProtection
		let staleCanonicalVisibleRowCount = session.transcriptCanonicalVisibleRowCount
		let staleProjectionCounts = session.transcriptProjectionCounts

		let invocationID = UUID()
		session.appendItem(.toolResult(
			name: "read_file",
			invocationID: invocationID,
			resultJSON: #"{"content":"tool output"}"#,
			isError: false,
			sequenceIndex: session.nextSequenceIndex
		))
		session.appendItem(.assistant("I found the tool output.", sequenceIndex: session.nextSequenceIndex))
		vm.test_rebuildStructuredTranscript(tabID: tabID)
		let completeTranscript = session.transcript
		let completeProjectionProtection = AgentModeViewModel.transcriptProjectionProtection(
			for: completeTranscript,
			viewportState: session.transcriptViewportState
		)

		session.baseTranscriptProjection = staleBaseProjection
		session.fullTranscriptProjection = staleFullProjection
		session.workingTranscriptProjection = staleWorkingProjection
		session.transcriptProjection = staleTranscriptProjection
		session.archivedTranscriptSnapshot = staleArchivedSnapshot
		session.transcriptProjectionProtection = staleProjectionProtection
		session.transcriptCanonicalVisibleRowCount = staleCanonicalVisibleRowCount
		session.transcriptProjectionCounts = staleProjectionCounts
		session.derivedTranscriptSyncState = AgentModeViewModel.DerivedTranscriptSyncState(
			sourceItemsRevision: session.sourceItemsRevision,
			nextSequenceIndex: session.nextSequenceIndex,
			runState: session.runState,
			selectedAgent: session.selectedAgent,
			hidePendingQuestionToolCall: session.hasPendingQuestionUI,
			projectionProtection: completeProjectionProtection
		)

		vm.test_setCurrentTabIDOverride(tabID)
		defer { vm.test_setCurrentTabIDOverride(nil) }
		vm.test_applySessionToBindings(tabID: tabID)

		XCTAssertEqual(vm.activeTranscriptPresentation.tabID, tabID)
		XCTAssertTrue(vm.activeTranscriptPresentation.visibleRows.contains {
			$0.kind == .toolResult && $0.toolName == "read_file"
		})
		XCTAssertTrue(vm.activeTranscriptPresentation.visibleRows.contains {
			$0.kind == .assistant && $0.text.contains("tool output")
		})
	}

	func testSetItemsSilentlySkipsDerivedTranscriptRebuild() async {
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			FakeCodexController()
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.appendItem(AgentChatItem.user("Investigate", sequenceIndex: session.nextSequenceIndex))
		let initialBuildCount = session.transcriptPerformanceSnapshot.projectionBuildCount

		session.setItemsSilently([
			AgentChatItem.user("Reloaded", sequenceIndex: 41)
		], reason: .testOverride)

		XCTAssertEqual(session.transcriptPerformanceSnapshot.projectionBuildCount, initialBuildCount)
		XCTAssertEqual(session.items.count, 1)
		XCTAssertEqual(session.nextSequenceIndex, 42)
	}

	func testNoOpSourceItemMutationsSkipDerivedTranscriptRefresh() async {
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			FakeCodexController()
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.runState = .running
		session.appendItem(AgentChatItem.user("Investigate", sequenceIndex: session.nextSequenceIndex))
		let initialRequestCount = session.transcriptPerformanceSnapshot.refreshRequestCount
		let initialBuildCount = session.transcriptPerformanceSnapshot.projectionBuildCount
		let existingItem = session.items[0]

		session.replaceItem(at: 0, with: existingItem)
		session.mutateItem(at: 0) { _ in }
		session.updateLastItem { _ in }

		XCTAssertEqual(session.transcriptPerformanceSnapshot.refreshRequestCount, initialRequestCount)
		XCTAssertEqual(session.transcriptPerformanceSnapshot.projectionBuildCount, initialBuildCount)
	}

	func testColdLoadRebuildPublishesColdLoadProjectionDuration() async {
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			FakeCodexController()
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.appendItem(AgentChatItem.user("Investigate", sequenceIndex: session.nextSequenceIndex))
		session.appendItem(AgentChatItem.assistant("Done", sequenceIndex: session.nextSequenceIndex))

		vm.test_rebuildStructuredTranscript(tabID: tabID, isColdLoad: true)
		vm.test_applySessionToBindings(tabID: tabID)

		XCTAssertNotNil(session.transcriptPerformanceSnapshot.lastColdLoadProjectionBuildDurationMS)
		XCTAssertEqual(
			vm.activeTranscriptPerformanceSnapshot.lastColdLoadProjectionBuildDurationMS,
			session.transcriptPerformanceSnapshot.lastColdLoadProjectionBuildDurationMS
		)
		XCTAssertGreaterThan(session.transcriptPerformanceSnapshot.projectionBuildCount, 0)
	}

	func testCodexActiveSessionRefreshesDerivedTranscriptImmediatelyForLiveMutations() async {
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			FakeCodexController()
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.runState = .running

		session.appendItem(.user("first", sequenceIndex: session.nextSequenceIndex))
		XCTAssertEqual(session.transcriptPerformanceSnapshot.refreshRequestCount, 1)
		XCTAssertEqual(session.transcriptPerformanceSnapshot.refreshCoalescedCount, 0)
		XCTAssertEqual(session.transcriptPerformanceSnapshot.refreshImmediateCount, 1)
		XCTAssertEqual(session.transcriptPerformanceSnapshot.projectionBuildCount, 1)

		session.appendItem(.assistant("second", sequenceIndex: session.nextSequenceIndex))
		session.appendItem(.assistant("third", sequenceIndex: session.nextSequenceIndex))

		XCTAssertEqual(session.transcriptPerformanceSnapshot.refreshRequestCount, 3)
		XCTAssertEqual(session.transcriptPerformanceSnapshot.refreshCoalescedCount, 0)
		XCTAssertEqual(session.transcriptPerformanceSnapshot.refreshImmediateCount, 3)
		XCTAssertEqual(session.transcriptPerformanceSnapshot.projectionBuildCount, 3)
		XCTAssertEqual(session.transcriptPerformanceSnapshot.lastPayloadCaptureScannedItemCount, 0)
	}

	func testTerminalSaveFlushesBufferedCodexAssistantAndCommandOutput() async throws {
		let repoRoot = try makeTemporaryWorkspace(prefix: "AgentModeTerminalSaveRaceRepoRoot")
		let workspaceDirectory = try makeTemporaryWorkspace(prefix: "AgentModeTerminalSaveRaceWorkspace")
		defer {
			try? FileManager.default.removeItem(at: repoRoot)
			try? FileManager.default.removeItem(at: workspaceDirectory)
		}
		let activeTabID = UUID()
		let tabID = UUID()
		let windowState = WindowState()
		await windowState.workspaceManager.awaitInitialized()
		let workspace = WorkspaceModel(
			name: "Terminal Save Race",
			repoPaths: [repoRoot.path],
			customStoragePath: workspaceDirectory,
			composeTabs: [
				ComposeTabState(id: activeTabID, name: "Active", lastModified: Date()),
				ComposeTabState(id: tabID, name: "Inactive", lastModified: Date())
			],
			activeComposeTabID: activeTabID
		)
		windowState.workspaceManager.workspaces = [workspace]
		windowState.workspaceManager.activeWorkspace = workspace
		windowState.promptManager.loadComposeTabsFromWorkspace(workspace)
		let vm = windowState.agentModeViewModel
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.runState = .running
		session.appendItem(.user("run the command", sequenceIndex: session.nextSequenceIndex))
		let invocationID = UUID()
		let runningJSON = #"{"type":"commandExecution","status":"running","processId":"terminal-save-race","aggregatedOutput":"initial output\n"}"#
		session.appendItem(.toolResult(
			name: "bash",
			invocationID: invocationID,
			resultJSON: runningJSON,
			isError: false,
			sequenceIndex: session.nextSequenceIndex
		))
		session.pendingAssistantDelta = "final buffered assistant response"
		session.assistantDeltaFlushTask = Task { _ = try? await Task.sleep(nanoseconds: 5_000_000_000) }
		session.pendingCommandRunningByKey["invocation:\(invocationID.uuidString)"] = .init(
			invocationID: invocationID,
			processID: "terminal-save-race",
			appendedOutput: "buffered stdout before save\n"
		)
		session.pendingCommandRunningFlushTask = Task { _ = try? await Task.sleep(nanoseconds: 5_000_000_000) }

		vm.test_setCurrentTabIDOverride(UUID())
		defer { vm.test_setCurrentTabIDOverride(nil) }
		session.runState = .completed
		session.isDirty = true

		await vm.test_flushSave(tabID: tabID)

		let sessionID = try XCTUnwrap(session.activeAgentSessionID)
		let loadedSaved = try await vm.test_dataService.loadAgentSession(id: sessionID, for: workspace)
		let saved = try XCTUnwrap(loadedSaved)
		let savedTranscript = try XCTUnwrap(saved.transcript)
		let savedItems = AgentTranscriptIO.workingSourceItems(from: savedTranscript)
		XCTAssertEqual(saved.lastRunState, AgentSessionRunState.completed.rawValue)
		XCTAssertTrue(savedItems.contains { $0.kind == .assistant && $0.text.contains("final buffered assistant response") })
		let savedBash = try XCTUnwrap(savedItems.last(where: { $0.kind == .toolResult && $0.toolName == "bash" }))
		let parsedBash = BashToolResultParser.parse(raw: savedBash.toolResultJSON, argsJSON: savedBash.toolArgsJSON)
		XCTAssertFalse(parsedBash.isRunning)
		XCTAssertNotEqual(parsedBash.statusWord, "running")
		let liveBash = try XCTUnwrap(session.items.last(where: { $0.kind == .toolResult && $0.toolName == "bash" }))
		XCTAssertTrue(liveBash.toolResultJSON?.contains("buffered stdout before save") == true)
		XCTAssertFalse(BashToolResultParser.parse(raw: liveBash.toolResultJSON, argsJSON: liveBash.toolArgsJSON).isRunning)
		XCTAssertTrue(session.pendingAssistantDelta.isEmpty)
		XCTAssertTrue(session.pendingCommandRunningByKey.isEmpty)
		XCTAssertTrue(session.bashLiveExecutionByKey.isEmpty)

		vm.test_setCurrentTabIDOverride(tabID)
		vm.test_applySessionToBindings(tabID: tabID)
		XCTAssertEqual(vm.activeTranscriptPresentation.tabID, tabID)
		XCTAssertTrue(vm.activeTranscriptPresentation.visibleRows.contains {
			$0.kind == .assistant && $0.text.contains("final buffered assistant response")
		})
		let presentedBash = try XCTUnwrap(vm.activeTranscriptPresentation.visibleRows.last(where: {
			$0.kind == .toolResult && $0.toolName == "bash"
		}))
		let presentedParsedBash = BashToolResultParser.parse(
			raw: presentedBash.toolResultJSON,
			argsJSON: presentedBash.toolArgsJSON
		)
		XCTAssertFalse(presentedParsedBash.isRunning)
		await windowState.tearDown()
	}

	func testTerminalSaveFlushesBufferedGenericAssistantOutput() async throws {
		let repoRoot = try makeTemporaryWorkspace(prefix: "AgentModeGenericTerminalSaveRaceRepoRoot")
		let workspaceDirectory = try makeTemporaryWorkspace(prefix: "AgentModeGenericTerminalSaveRaceWorkspace")
		defer {
			try? FileManager.default.removeItem(at: repoRoot)
			try? FileManager.default.removeItem(at: workspaceDirectory)
		}
		let tabID = UUID()
		let windowState = WindowState()
		await windowState.workspaceManager.awaitInitialized()
		let workspace = WorkspaceModel(
			name: "Generic Terminal Save Race",
			repoPaths: [repoRoot.path],
			customStoragePath: workspaceDirectory,
			composeTabs: [ComposeTabState(id: tabID, name: "Generic", lastModified: Date())],
			activeComposeTabID: tabID
		)
		windowState.workspaceManager.workspaces = [workspace]
		windowState.workspaceManager.activeWorkspace = workspace
		windowState.promptManager.loadComposeTabsFromWorkspace(workspace)
		let vm = windowState.agentModeViewModel
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .claudeCode
		session.runState = .running
		session.appendItem(.user("finish", sequenceIndex: session.nextSequenceIndex))
		session.pendingAssistantDelta = "generic final response"
		session.assistantDeltaFlushTask = Task { _ = try? await Task.sleep(nanoseconds: 5_000_000_000) }
		session.runState = .completed
		session.isDirty = true

		await vm.test_flushSave(tabID: tabID)

		let sessionID = try XCTUnwrap(session.activeAgentSessionID)
		let loadedSaved = try await vm.test_dataService.loadAgentSession(id: sessionID, for: workspace)
		let saved = try XCTUnwrap(loadedSaved)
		let savedTranscript = try XCTUnwrap(saved.transcript)
		let savedItems = AgentTranscriptIO.workingSourceItems(from: savedTranscript)
		XCTAssertEqual(saved.lastRunState, AgentSessionRunState.completed.rawValue)
		XCTAssertTrue(savedItems.contains { $0.kind == .assistant && $0.text.contains("generic final response") })
		XCTAssertTrue(session.pendingAssistantDelta.isEmpty)

		vm.test_setCurrentTabIDOverride(tabID)
		vm.test_applySessionToBindings(tabID: tabID)
		XCTAssertEqual(vm.activeTranscriptPresentation.tabID, tabID)
		XCTAssertTrue(vm.activeTranscriptPresentation.visibleRows.contains {
			$0.kind == .assistant && $0.text.contains("generic final response")
		})
		await windowState.tearDown()
	}

	func testCodexActiveSessionMaintainsIncrementalEphemeralPayloadMapParity() async {
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			FakeCodexController()
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.runState = .running

		let rawAgentRunResult = #"{"status":"completed","assistant_text":"done","transcript_item_count":3,"session":{"id":"child"}}"#
		session.appendItem(.user("spawn", sequenceIndex: session.nextSequenceIndex))
		session.appendItem(.toolResult(
			name: "agent_run",
			invocationID: UUID(),
			resultJSON: rawAgentRunResult,
			isError: false,
			sequenceIndex: session.nextSequenceIndex
		))

		XCTAssertEqual(
			vm.test_ephemeralToolResultPayloadMap(tabID: tabID),
			AgentModeViewModel.rebuildEphemeralToolResultPayloadMap(from: session.items)
		)
		XCTAssertEqual(session.transcriptPerformanceSnapshot.lastPayloadCaptureScannedItemCount, 0)
		XCTAssertEqual(session.transcriptPerformanceSnapshot.retainedRawPayloadEntryCount, 1)

		let resultIndex = session.items.count - 1
		session.replaceItem(
			at: resultIndex,
			with: .toolResult(
				name: "agent_run",
				invocationID: session.items[resultIndex].toolInvocationID,
				resultJSON: #"{"status":"running","assistant_text":"still running","transcript_item_count":4}"#,
				isError: nil,
				sequenceIndex: session.items[resultIndex].sequenceIndex
			)
		)
		XCTAssertEqual(
			vm.test_ephemeralToolResultPayloadMap(tabID: tabID),
			AgentModeViewModel.rebuildEphemeralToolResultPayloadMap(from: session.items)
		)

		_ = session.removeItem(at: resultIndex)
		XCTAssertEqual(vm.test_ephemeralToolResultPayloadMap(tabID: tabID), [:])
		XCTAssertEqual(
			vm.test_ephemeralToolResultPayloadMap(tabID: tabID),
			AgentModeViewModel.rebuildEphemeralToolResultPayloadMap(from: session.items)
		)
	}

	func testCodexActiveSessionKeepsFinalDerivedTranscriptStateAlignedAcrossRapidLiveBursts() async {
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			FakeCodexController()
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.runState = .running

		session.appendItem(.user("investigate", sequenceIndex: session.nextSequenceIndex))
		session.appendItem(.toolCall(name: "read_file", invocationID: UUID(), argsJSON: #"{"path":"README.md"}"#, sequenceIndex: session.nextSequenceIndex))
		session.appendItem(.toolResult(name: "read_file", invocationID: UUID(), resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: session.nextSequenceIndex))
		session.appendItem(.assistant("done", sequenceIndex: session.nextSequenceIndex))

		let immediateTranscript = session.transcript
		let immediateProjection = session.transcriptProjection
		vm.test_rebuildStructuredTranscript(tabID: tabID)

		XCTAssertEqual(session.transcriptProjection, immediateProjection)
		XCTAssertEqual(session.transcript.turns.map(\.request?.text), immediateTranscript.turns.map(\.request?.text))
		XCTAssertEqual(
			session.transcript.turns.flatMap(\.responseSpans).flatMap(\.activities).compactMap { $0.toolExecution?.status },
			immediateTranscript.turns.flatMap(\.responseSpans).flatMap(\.activities).compactMap { $0.toolExecution?.status }
		)
	}

	func testCodexActiveSessionUsesIncrementalImportForTailLiveMutations() async {
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			FakeCodexController()
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.runState = .running

		session.appendItem(.user("first", sequenceIndex: session.nextSequenceIndex))
		XCTAssertEqual(session.transcriptPerformanceSnapshot.incrementalImportAttemptCount, 0)

		session.appendItem(.assistant("second", sequenceIndex: session.nextSequenceIndex))
		session.appendItem(.assistant("third", sequenceIndex: session.nextSequenceIndex))

		XCTAssertGreaterThanOrEqual(session.transcriptPerformanceSnapshot.incrementalImportAttemptCount, 1)
		XCTAssertGreaterThanOrEqual(session.transcriptPerformanceSnapshot.incrementalImportSuccessCount, 1)
		XCTAssertEqual(session.transcriptPerformanceSnapshot.incrementalImportFallbackCount, 0)
		XCTAssertNotNil(session.transcriptPerformanceSnapshot.lastIncrementalImportDurationMS)
	}

	func testCodexActiveSessionUsesDurableFrontierForCompactedHistoryTailMutations() async throws {
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			FakeCodexController()
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.runState = .running

		let items = makeTranscriptItems(turnCount: 20)
		session.setItemsSilently(items, reason: .testOverride)
		vm.test_rebuildStructuredTranscript(tabID: tabID)
		let baselineFrontier = try XCTUnwrap(session.transcript.compactionFrontier)
		XCTAssertGreaterThan(baselineFrontier.frozenPrefixTurnCount, 0)

		let updatedSummaryIndex = try XCTUnwrap(session.items.indices.last)
		session.replaceItem(
			at: updatedSummaryIndex,
			with: AgentChatItem.assistant("updated final summary", sequenceIndex: session.items[updatedSummaryIndex].sequenceIndex)
		)

		XCTAssertGreaterThanOrEqual(session.transcriptPerformanceSnapshot.incrementalImportAttemptCount, 1)
		XCTAssertGreaterThanOrEqual(session.transcriptPerformanceSnapshot.incrementalImportSuccessCount, 1)
		XCTAssertEqual(session.transcriptPerformanceSnapshot.incrementalImportFallbackCount, 0)
		XCTAssertGreaterThanOrEqual(session.transcriptPerformanceSnapshot.frontierReuseAttemptCount, 1)
		XCTAssertGreaterThanOrEqual(session.transcriptPerformanceSnapshot.frontierReuseSuccessCount, 1)
		XCTAssertEqual(session.transcriptPerformanceSnapshot.frontierReuseFallbackCount, 0)
		XCTAssertEqual(session.transcript.compactionFrontier?.lastFrozenTurnID, baselineFrontier.lastFrozenTurnID)
	}

	func testCodexActiveSessionReusesSanitizeAndProjectionForCompactedHistoryTailMutations() async throws {
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			FakeCodexController()
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.runState = .running

		let items = makeTranscriptItems(turnCount: 20)
		session.setItemsSilently(items, reason: .testOverride)
		vm.test_rebuildStructuredTranscript(tabID: tabID)
		let baselineFrontier = try XCTUnwrap(session.transcript.compactionFrontier)
		XCTAssertGreaterThan(baselineFrontier.frozenPrefixTurnCount, 0)

		let updatedSummaryIndex = try XCTUnwrap(session.items.indices.last)
		session.replaceItem(
			at: updatedSummaryIndex,
			with: AgentChatItem.assistant("updated final summary again", sequenceIndex: session.items[updatedSummaryIndex].sequenceIndex)
		)

		XCTAssertGreaterThanOrEqual(session.transcriptPerformanceSnapshot.sanitizeReuseAttemptCount, 1)
		XCTAssertGreaterThanOrEqual(session.transcriptPerformanceSnapshot.sanitizeReuseSuccessCount, 1)
		XCTAssertEqual(session.transcriptPerformanceSnapshot.sanitizeReuseFallbackCount, 0)
		XCTAssertGreaterThanOrEqual(session.transcriptPerformanceSnapshot.lastSanitizeReusedTurnCount ?? 0, baselineFrontier.frozenPrefixTurnCount)
		XCTAssertGreaterThanOrEqual(session.transcriptPerformanceSnapshot.projectionReuseAttemptCount, 1)
		XCTAssertGreaterThanOrEqual(session.transcriptPerformanceSnapshot.projectionReuseSuccessCount, 1)
		XCTAssertEqual(session.transcriptPerformanceSnapshot.projectionReuseFallbackCount, 0)
		XCTAssertEqual(session.transcriptPerformanceSnapshot.lastProjectionReusedTurnCount, baselineFrontier.frozenPrefixTurnCount)
	}

	func testCodexActiveSessionKeepsProjectionReuseStableWhenViewportStateChanges() async throws {
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			FakeCodexController()
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.runState = .running

		let items = makeTranscriptItems(turnCount: 20)
		session.setItemsSilently(items, reason: .testOverride)
		vm.test_rebuildStructuredTranscript(tabID: tabID)
		session.transcriptViewportState = AgentTranscriptViewportState(
			isDetachedFromLiveBottom: true,
			detachedAuthority: DetachedViewportAuthority(
				targetID: nil,
				anchor: nil,
				sequenceIndex: nil,
				blockID: nil,
				viewportMinY: nil
			)
		)

		let updatedSummaryIndex = try XCTUnwrap(session.items.indices.last)
		session.replaceItem(
			at: updatedSummaryIndex,
			with: AgentChatItem.assistant("projection fallback summary", sequenceIndex: session.items[updatedSummaryIndex].sequenceIndex)
		)

		XCTAssertGreaterThanOrEqual(session.transcriptPerformanceSnapshot.projectionReuseAttemptCount, 1)
		XCTAssertGreaterThanOrEqual(session.transcriptPerformanceSnapshot.projectionReuseSuccessCount, 1)
		XCTAssertEqual(session.transcriptPerformanceSnapshot.projectionReuseFallbackCount, 0)
		XCTAssertGreaterThanOrEqual(session.transcriptPerformanceSnapshot.lastProjectionReusedTurnCount ?? 0, 1)
	}

	func testRebuildStructuredTranscriptTrimsWorkingItemsToFullDetailSuffix() async throws {
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			FakeCodexController()
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.runState = .running

		let items = makeTranscriptItems(turnCount: 20)
		session.setItemsSilently(items, reason: .testOverride)
		vm.test_rebuildStructuredTranscript(tabID: tabID)

		let compactedPrefixCount = session.transcript.turns.prefix { $0.retentionTier != .full }.count
		let expectedWorkingItems = AgentTranscriptIO.workingSourceItems(from: session.transcript)

		XCTAssertGreaterThan(compactedPrefixCount, 0)
		XCTAssertEqual(session.items, expectedWorkingItems)
		XCTAssertLessThan(session.items.count, items.count)
		XCTAssertGreaterThan(try XCTUnwrap(session.items.first?.sequenceIndex), 0)
	}

	func testDerivedTranscriptSyncStateEnablesSaveReuseWhenInputsMatch() async {
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			FakeCodexController()
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.setItemsSilently(makeTranscriptItems(turnCount: 20), reason: .testOverride)
		vm.test_rebuildStructuredTranscript(tabID: tabID)

		XCTAssertTrue(vm.test_canReuseDerivedTranscriptForSave(tabID: tabID))

		session.selectedAgent = .claudeCode
		XCTAssertFalse(vm.test_canReuseDerivedTranscriptForSave(tabID: tabID))

		session.selectedAgent = .codexExec
		session.runState = .running
		XCTAssertFalse(vm.test_canReuseDerivedTranscriptForSave(tabID: tabID))
	}

	func testRebuildStructuredTranscriptReconcilesSanitizedWorkingSuffixWithoutEnvelopeChange() async throws {
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			FakeCodexController()
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		let rawDiff = "@@ -1 +1 @@\n-old\n+new"
		let rawResult = #"{"status":"success","changes":[{"path":"/tmp/file.swift","kind":"update","diff":"@@ -1 +1 @@\n-old\n+new"}],"change_count":1}"#
		session.setItemsSilently([
			.user("Patch it", sequenceIndex: 0),
			.toolCall(name: "apply_patch", invocationID: nil, argsJSON: #"{"path":"/tmp/file.swift","change_count":1}"#, sequenceIndex: 1),
			.toolResult(name: "apply_patch", invocationID: nil, resultJSON: rawResult, isError: false, sequenceIndex: 2),
			.assistant("Done", sequenceIndex: 3)
		], reason: .testOverride)

		vm.test_rebuildStructuredTranscript(tabID: tabID)

		let sanitizedToolResult = try XCTUnwrap(session.items.first(where: { $0.kind == .toolResult }))
		XCTAssertFalse(sanitizedToolResult.toolResultJSON?.contains(rawDiff) == true)
		XCTAssertTrue(sanitizedToolResult.toolResultJSON?.contains(#""summary_only":true"#) == true)
		XCTAssertEqual(session.items, AgentTranscriptIO.workingSourceItems(from: session.transcript))
	}

	func testLiveMutationPreservesCompactedPrefixWhenOnlyWorkingSuffixItemsRemain() async throws {
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			FakeCodexController()
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.runState = .running

		let items = makeTranscriptItems(turnCount: 20)
		session.setItemsSilently(items, reason: .testOverride)
		vm.test_rebuildStructuredTranscript(tabID: tabID)

		let compactedPrefix = Array(session.transcript.turns.prefix { $0.retentionTier != .full })
		let preservedPrefixIDs = compactedPrefix.map(\.id)
		let lastSequenceIndex = try XCTUnwrap(session.items.last?.sequenceIndex)

		XCTAssertFalse(compactedPrefix.isEmpty)

		session.replaceItem(
			at: session.items.count - 1,
			with: AgentChatItem.assistant("updated final summary", sequenceIndex: lastSequenceIndex)
		)

		XCTAssertEqual(Array(session.transcript.turns.prefix(compactedPrefix.count)).map(\.id), preservedPrefixIDs)
		XCTAssertEqual(session.items, AgentTranscriptIO.workingSourceItems(from: session.transcript))
		XCTAssertEqual(session.transcriptProjection.workingRows.last?.text, "updated final summary")
	}

	func testSetItemsSilentlyRebuildsEphemeralToolResultPayloadMap() async {
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			FakeCodexController()
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
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

		session.setItemsSilently([toolResult], reason: .testOverride)

		XCTAssertEqual(vm.test_ephemeralToolResultPayloadMap(tabID: tabID)[toolResult.id], rawDiff)
	}

	func testLegacyItemMutationHelpersPreserveCategorizedCallbacksAndSilentSets() async {
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			FakeCodexController()
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		var observedMutations: [AgentModeViewModel.SourceItemsMutation] = []
		session.onSourceItemsChanged = { _, mutation in
			observedMutations.append(mutation)
		}

		session.appendItem(.user("first", sequenceIndex: session.nextSequenceIndex))
		session.mutateItem(at: 0) { $0.text = "first updated" }
		session.replaceItem(at: 0, with: .assistant("replacement", sequenceIndex: 0))
		_ = session.removeItem(at: 0)
		session.replaceItems([.user("reload", sequenceIndex: 41)])
		session.setItemsSilently([.assistant("silent", sequenceIndex: 99)], reason: .testOverride)

		XCTAssertEqual(observedMutations.count, 5)
		if case .append(let index, let itemKind) = observedMutations[0] {
			XCTAssertEqual(index, 0)
			XCTAssertEqual(itemKind, .user)
		} else {
			XCTFail("Expected append mutation, got \(observedMutations[0])")
		}
		if case .mutate(let index, let itemKind) = observedMutations[1] {
			XCTAssertEqual(index, 0)
			XCTAssertEqual(itemKind, .user)
		} else {
			XCTFail("Expected mutate mutation, got \(observedMutations[1])")
		}
		if case .replace(let index, let previousKind, let currentKind) = observedMutations[2] {
			XCTAssertEqual(index, 0)
			XCTAssertEqual(previousKind, .user)
			XCTAssertEqual(currentKind, .assistant)
		} else {
			XCTFail("Expected replace mutation, got \(observedMutations[2])")
		}
		if case .remove(let index, let itemKind) = observedMutations[3] {
			XCTAssertEqual(index, 0)
			XCTAssertEqual(itemKind, .assistant)
		} else {
			XCTFail("Expected remove mutation, got \(observedMutations[3])")
		}
		if case .replaceAll = observedMutations[4] {
		} else {
			XCTFail("Expected replaceAll mutation, got \(observedMutations[4])")
		}
		XCTAssertEqual(session.items.count, 1)
		XCTAssertEqual(session.nextSequenceIndex, 100)
	}

	func testReplaceItemsRebuildsEphemeralToolResultPayloadMapBeforeRefresh() async {
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			FakeCodexController()
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
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

		XCTAssertEqual(vm.test_ephemeralToolResultPayloadMap(tabID: tabID)[toolResult.id], rawDiff)
		XCTAssertEqual(session.transcriptPerformanceSnapshot.projectionBuildCount, 1)
		XCTAssertEqual(session.transcriptPerformanceSnapshot.lastPayloadCaptureScannedItemCount, 0)
		XCTAssertEqual(session.transcriptPerformanceSnapshot.retainedRawPayloadEntryCount, 1)
	}


	func testCodexSendClearsConsumedAttachmentFilesByDefault() async throws {
		let repoRoot = try makeTemporaryWorkspace(prefix: "AgentModeCodexRepoRoot")
		let workspaceDirectory = try makeTemporaryWorkspace(prefix: "AgentModeCodexWorkspaceData")
		defer {
			try? FileManager.default.removeItem(at: repoRoot)
			try? FileManager.default.removeItem(at: workspaceDirectory)
		}
		let storedImageURL = try makeStoredAttachmentFile(workspaceDirectory: workspaceDirectory, fileName: "image.png")
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: repoRoot.path,
			testWorkspaceDirectory: workspaceDirectory
		) { _, _, _, _, _, _ in
			fakeController
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		let attachment = AgentImageAttachment(source: .localFile(path: storedImageURL.path), title: "image.png")

		XCTAssertTrue(FileManager.default.fileExists(atPath: storedImageURL.path))
		await vm.startAgentRun(tabID: tabID, initialMessage: "", attachments: [attachment])
		XCTAssertTrue(FileManager.default.fileExists(atPath: storedImageURL.path), "File should not be deleted before turn completion")

		fakeController.emit(.turnCompleted(turnID: nil, status: .completed))
		let didComplete = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .completed
		}
		XCTAssertTrue(didComplete, "Expected Codex run to complete")
		XCTAssertFalse(FileManager.default.fileExists(atPath: storedImageURL.path))
	}

	func testCodexSendDoesNotClearConsumedAttachmentFilesWhenFlagDisabled() async throws {
		let repoRoot = try makeTemporaryWorkspace(prefix: "AgentModeCodexRepoRoot")
		let workspaceDirectory = try makeTemporaryWorkspace(prefix: "AgentModeCodexWorkspaceData")
		defer {
			try? FileManager.default.removeItem(at: repoRoot)
			try? FileManager.default.removeItem(at: workspaceDirectory)
		}
		let storedImageURL = try makeStoredAttachmentFile(workspaceDirectory: workspaceDirectory, fileName: "image.png")
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: repoRoot.path,
			testWorkspaceDirectory: workspaceDirectory,
			clearConsumedAttachmentsAfterProviderConsumption: false
		) { _, _, _, _, _, _ in
			fakeController
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		let attachment = AgentImageAttachment(source: .localFile(path: storedImageURL.path), title: "image.png")

		XCTAssertTrue(FileManager.default.fileExists(atPath: storedImageURL.path))
		await vm.startAgentRun(tabID: tabID, initialMessage: "", attachments: [attachment])

		fakeController.emit(.turnCompleted(turnID: nil, status: .completed))
		let didComplete = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .completed
		}
		XCTAssertTrue(didComplete, "Expected Codex run to complete")
		XCTAssertTrue(FileManager.default.fileExists(atPath: storedImageURL.path))
	}

	func testCodexSendClearsConsumedAttachmentFilesWhenTurnInterrupted() async throws {
		let repoRoot = try makeTemporaryWorkspace(prefix: "AgentModeCodexRepoRoot")
		let workspaceDirectory = try makeTemporaryWorkspace(prefix: "AgentModeCodexWorkspaceData")
		defer {
			try? FileManager.default.removeItem(at: repoRoot)
			try? FileManager.default.removeItem(at: workspaceDirectory)
		}
		let storedImageURL = try makeStoredAttachmentFile(workspaceDirectory: workspaceDirectory, fileName: "image.png")
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: repoRoot.path,
			testWorkspaceDirectory: workspaceDirectory
		) { _, _, _, _, _, _ in
			fakeController
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		let attachment = AgentImageAttachment(source: .localFile(path: storedImageURL.path), title: "image.png")

		XCTAssertTrue(FileManager.default.fileExists(atPath: storedImageURL.path))
		await vm.startAgentRun(tabID: tabID, initialMessage: "", attachments: [attachment])

		fakeController.emit(.turnCompleted(turnID: nil, status: .interrupted))
		let didCancel = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .cancelled
		}
		XCTAssertTrue(didCancel, "Expected Codex run to stop as cancelled")
		XCTAssertFalse(FileManager.default.fileExists(atPath: storedImageURL.path))
	}

	func testCodexCancelBeforeSendRestoresReservedAttachments() async throws {
		let repoRoot = try makeTemporaryWorkspace(prefix: "AgentModeCodexCancelBeforeSendRepoRoot")
		let workspaceDirectory = try makeTemporaryWorkspace(prefix: "AgentModeCodexCancelBeforeSendWorkspace")
		defer {
			try? FileManager.default.removeItem(at: repoRoot)
			try? FileManager.default.removeItem(at: workspaceDirectory)
		}
		let storedImageURL = try makeStoredAttachmentFile(workspaceDirectory: workspaceDirectory, fileName: "cancel-before-send.png")
		let attachment = AgentImageAttachment(source: .localFile(path: storedImageURL.path), title: "cancel-before-send.png")
		let fakeController = FakeCodexController()
		fakeController.shouldBlockStartOrResume = true
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: repoRoot.path,
			testWorkspaceDirectory: workspaceDirectory
		) { _, _, _, _, _, _ in
			fakeController
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec

		let startTask = Task {
			await vm.startAgentRun(tabID: tabID, initialMessage: "cancel immediately", attachments: [attachment])
		}

		let didAttemptStart = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.startOrResumeCallCount == 1
		}
		XCTAssertTrue(didAttemptStart, "Expected Codex start to begin before cancellation")

		await vm.cancelAgentRun(tabID: tabID)
		fakeController.unblockStartOrResume()
		_ = await startTask.value

		let restored = await waitForCondition(timeoutSeconds: 2.0) {
			session.pendingImageAttachments.contains(where: { $0.id == attachment.id })
				&& session.attachmentTurnState == .idle
		}
		XCTAssertTrue(restored, "Expected cancelled run to restore reserved attachments")
		XCTAssertTrue(FileManager.default.fileExists(atPath: storedImageURL.path), "Attachment file should remain for retry")
	}

	func testRenameSessionPropagatesValidatedNameToLiveCodexThread() async {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.codexController = fakeController
		session.codexConversationID = "  rename-thread  "

		vm.renameSession(tabID: tabID, to: "  Custom Codex Name  ")

		let didSyncName = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.setThreadNameCalls.count == 1
		}
		XCTAssertTrue(didSyncName, "Expected live Codex rename to propagate to the app-server thread")
		XCTAssertEqual(fakeController.setThreadNameCalls.last?.name, "Custom Codex Name")
		XCTAssertEqual(fakeController.setThreadNameCalls.last?.threadID, "rename-thread")
	}

	func testRapidRenameSyncSendsLatestPendingCodexThreadNameAfterInFlightRequest() async {
		let fakeController = FakeCodexController()
		fakeController.setThreadNameBlocksRemaining = 1
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.codexController = fakeController
		session.codexConversationID = "coalesced-thread"

		vm.renameSession(tabID: tabID, to: "First Name")
		let firstSyncStarted = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.setThreadNameCalls.count == 1
		}
		XCTAssertTrue(firstSyncStarted, "Expected first remote rename to start")

		vm.renameSession(tabID: tabID, to: "Second Name")
		vm.renameSession(tabID: tabID, to: "Final Name")
		fakeController.unblockSetThreadName()

		let latestSyncSent = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.setThreadNameCalls.count == 2
		}
		XCTAssertTrue(latestSyncSent, "Expected pending remote renames to coalesce to one follow-up send")
		XCTAssertEqual(fakeController.setThreadNameCalls.map { $0.name }, ["First Name", "Final Name"])
	}

	func testCodexThreadNameIsSetAfterStartUsingLocalSessionName() async {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}
		let tabID = UUID()
		let sessionID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.activeAgentSessionID = sessionID
		vm.upsertSessionIndex(
			sessionID: sessionID,
			tabID: tabID,
			name: "MCP Named Session",
			lastUserMessageAt: nil,
			savedAt: Date(),
			lastRunStateRaw: session.runState.rawValue,
			itemCount: 0,
			agentKindRaw: DiscoverAgentKind.codexExec.rawValue,
			agentModelRaw: session.selectedModelRaw,
			agentReasoningEffortRaw: session.selectedReasoningEffortRaw,
			autoEditEnabled: session.autoEditEnabled
		)

		await vm.startAgentRun(tabID: tabID, initialMessage: "hello")

		let didSyncName = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.setThreadNameCalls.contains(where: { call in
				call.name == "MCP Named Session" && call.threadID == "test-thread"
			})
		}
		XCTAssertTrue(didSyncName, "Expected Codex start/resume to propagate the local session name")
	}

	func testGoalObjectiveSetsCodexThreadGoalWithoutSendingUserTurn() async {
		CodexGoalSupport.setEnabledForTesting(true)
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.runState = .idle

		let result = vm.test_submitUserTurn(tabID: tabID, text: "/goal improve benchmark coverage")
		XCTAssertEqual(result, .submitted)
		XCTAssertFalse(session.items.isEmpty)
		let immediateUserItem = try? XCTUnwrap(session.items.last)
		XCTAssertEqual(immediateUserItem?.kind, .user)
		XCTAssertEqual(immediateUserItem?.text, "improve benchmark coverage")
		XCTAssertEqual(immediateUserItem?.isLocalControlPlaneEcho, true)
		XCTAssertEqual(immediateUserItem?.codexGoalMode?.action, .setObjective)
		XCTAssertNil(immediateUserItem?.workflow)

		let didSetGoal = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.startOrResumeCallCount == 1
				&& fakeController.setThreadGoalObjectiveCalls == ["improve benchmark coverage"]
				&& session.items.contains(where: { $0.kind == .system && $0.text.contains("Set Codex goal: improve benchmark coverage") })
		}
		XCTAssertTrue(didSetGoal, "Expected /goal <objective> to bootstrap a Codex thread and set the goal")
		XCTAssertEqual(fakeController.sendUserMessageCallCount, 0)
		XCTAssertTrue(fakeController.sentTurns.isEmpty)
	}

	func testGoalCommandWithSelectedPromptWorkflowConsumesWorkflowSelection() async {
		CodexGoalSupport.setEnabledForTesting(true)
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}
		let tabID = UUID()
		vm.test_setCurrentTabIDOverride(tabID)
		defer { vm.test_setCurrentTabIDOverride(nil) }
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		vm.selectWorkflow(AgentWorkflow.build.definition)

		let result = vm.test_submitUserTurn(tabID: tabID, text: "/goal improve benchmark coverage")

		XCTAssertEqual(result, .submitted)
		let immediateUserItem = try? XCTUnwrap(session.items.last)
		XCTAssertEqual(immediateUserItem?.kind, .user)
		XCTAssertEqual(immediateUserItem?.text, "improve benchmark coverage")
		XCTAssertEqual(immediateUserItem?.isLocalControlPlaneEcho, true)
		XCTAssertEqual(immediateUserItem?.codexGoalMode?.action, .setObjective)
		XCTAssertEqual(immediateUserItem?.workflow?.builtInWorkflow, .build)
		XCTAssertEqual(immediateUserItem?.workflow?.displayName, "Plan & Build")
		if let immediateUserItem {
			let restored = AgentChatItemPersist(from: immediateUserItem).toItem()
			XCTAssertEqual(restored.codexGoalMode?.action, .setObjective)
			XCTAssertEqual(restored.workflow?.builtInWorkflow, .build)
			XCTAssertTrue(restored.isLocalControlPlaneEcho)
		}
		XCTAssertNil(session.selectedWorkflow)
		XCTAssertNil(vm.makeStatusPillsSnapshot().selectedWorkflow)
		XCTAssertNil(vm.makeComposerProps(tabID: tabID).stagedSlashCommand)
		let didSetGoal = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.setThreadGoalObjectiveCalls.count == 1
				&& session.items.contains(where: { $0.kind == .system && $0.text.contains("Set Codex goal: improve benchmark coverage") })
		}
		XCTAssertTrue(didSetGoal)
		let payload = fakeController.setThreadGoalObjectiveCalls.first ?? ""
		XCTAssertTrue(payload.contains("improve benchmark coverage"))
		XCTAssertTrue(payload.contains("RepoPrompt workflow context"))
		XCTAssertTrue(payload.contains("Workflow: Plan & Build"))
		XCTAssertTrue(payload.contains("Workflow instructions"))
		XCTAssertLessThanOrEqual(payload.count, CodexAgentModeCoordinator.maxThreadGoalObjectiveCharacters)
		XCTAssertNil(session.selectedWorkflow)
		XCTAssertNil(vm.makeStatusPillsSnapshot().selectedWorkflow)
		XCTAssertEqual(fakeController.sendUserMessageCallCount, 0)
		XCTAssertTrue(fakeController.sentTurns.isEmpty)
	}

	func testCodexGoalModeMetadataPersistsThroughChatAndTranscriptModels() throws {
		let original = AgentChatItem.user(
			"improve benchmark coverage",
			sequenceIndex: 7,
			workflow: AgentWorkflow.build.definition,
			codexGoalMode: AgentCodexGoalModeMetadata(action: .setObjective),
			isLocalControlPlaneEcho: true
		)

		let persisted = AgentChatItemPersist(from: original)
		let encoded = try JSONEncoder().encode(persisted)
		let jsonObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
		let persistedMetadata = try XCTUnwrap(jsonObject["codexGoalMode"] as? [String: Any])
		XCTAssertEqual(persistedMetadata["action"] as? String, "setObjective")

		let restored = persisted.toItem()
		XCTAssertEqual(restored.codexGoalMode?.action, .setObjective)
		XCTAssertEqual(restored.workflow?.builtInWorkflow, .build)
		XCTAssertTrue(restored.isLocalControlPlaneEcho)

		let activity = AgentTranscriptActivity(from: original)
		XCTAssertEqual(activity.codexGoalMode?.action, .setObjective)
		XCTAssertEqual(activity.isLocalControlPlaneEcho, true)
		XCTAssertEqual(activity.toItem().codexGoalMode?.action, .setObjective)
		XCTAssertEqual(activity.toItem().workflow?.builtInWorkflow, .build)
		XCTAssertTrue(activity.toItem().isLocalControlPlaneEcho)

		let request = AgentTranscriptRequestAnchor(from: original)
		XCTAssertEqual(request.codexGoalMode?.action, .setObjective)
		XCTAssertEqual(request.isLocalControlPlaneEcho, true)
		XCTAssertEqual(request.toItem().codexGoalMode?.action, .setObjective)
		XCTAssertEqual(request.toItem().workflow?.builtInWorkflow, .build)
		XCTAssertTrue(request.toItem().isLocalControlPlaneEcho)
	}

	func testGoalObjectiveNearLimitWithSelectedWorkflowIsBlockedBeforeControllerCall() async {
		CodexGoalSupport.setEnabledForTesting(true)
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}
		let tabID = UUID()
		vm.test_setCurrentTabIDOverride(tabID)
		defer { vm.test_setCurrentTabIDOverride(nil) }
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		vm.selectWorkflow(AgentWorkflow.build.definition)
		let objective = String(repeating: "x", count: CodexAgentModeCoordinator.maxThreadGoalObjectiveCharacters - 10)

		let result = vm.test_submitUserTurn(tabID: tabID, text: "/goal \(objective)")

		guard case .blocked(let message) = result else {
			return XCTFail("Expected selected-workflow /goal objective near the limit to be blocked before async execution")
		}
		XCTAssertTrue(message.contains("selected workflow context"))
		XCTAssertEqual(fakeController.startOrResumeCallCount, 0)
		XCTAssertEqual(fakeController.setThreadGoalObjectiveCalls, [])
		XCTAssertEqual(session.selectedWorkflow?.builtInWorkflow, .build)
	}

	func testGoalControlActionsWithSelectedWorkflowDoNotApplyWorkflowContext() async {
		CodexGoalSupport.setEnabledForTesting(true)
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}
		let tabID = UUID()
		vm.test_setCurrentTabIDOverride(tabID)
		defer { vm.test_setCurrentTabIDOverride(nil) }
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		do {
			_ = try await fakeController.startOrResume(existing: nil, baseInstructions: "")
		} catch {
			return XCTFail("Failed to activate fake Codex thread: \(error)")
		}
		session.codexController = fakeController
		session.codexControllerGoalSupportEnabled = true
		fakeController.currentGoal = makeThreadGoal(objective: "Improve benchmark coverage")
		vm.selectWorkflow(AgentWorkflow.build.definition)

		XCTAssertFalse(session.items.contains { $0.kind == .user })
		XCTAssertEqual(vm.test_submitUserTurn(tabID: tabID, text: "/goal"), .submitted)
		XCTAssertFalse(session.items.contains { $0.kind == .user })
		let showedGoal = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.getThreadGoalCallCount == 1
		}
		XCTAssertTrue(showedGoal)

		XCTAssertEqual(vm.test_submitUserTurn(tabID: tabID, text: "/goal pause"), .submitted)
		XCTAssertFalse(session.items.contains { $0.kind == .user })
		let paused = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.setThreadGoalStatusCalls == [.paused]
		}
		XCTAssertTrue(paused)

		XCTAssertEqual(vm.test_submitUserTurn(tabID: tabID, text: "/goal resume"), .submitted)
		XCTAssertFalse(session.items.contains { $0.kind == .user })
		let resumed = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.setThreadGoalStatusCalls == [.paused, .active]
		}
		XCTAssertTrue(resumed)

		XCTAssertEqual(vm.test_submitUserTurn(tabID: tabID, text: "/goal clear"), .submitted)
		XCTAssertFalse(session.items.contains { $0.kind == .user })
		let cleared = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.clearThreadGoalCallCount == 1
		}
		XCTAssertTrue(cleared)
		XCTAssertEqual(fakeController.setThreadGoalObjectiveCalls, [])
		XCTAssertEqual(session.selectedWorkflow?.builtInWorkflow, .build)
		XCTAssertEqual(fakeController.sendUserMessageCallCount, 0)
	}

	func testGoalCommandShowsImmediateProgressWhileHydrating() async {
		CodexGoalSupport.setEnabledForTesting(true)
		let fakeController = FakeCodexController()
		fakeController.shouldBlockStartOrResume = true
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.runState = .idle

		let result = vm.test_submitUserTurn(tabID: tabID, text: "/goal improve benchmark coverage")

		XCTAssertEqual(result, .submitted)
		XCTAssertEqual(session.items.last?.kind, .user)
		XCTAssertEqual(session.items.last?.text, "improve benchmark coverage")
		XCTAssertEqual(session.items.last?.isLocalControlPlaneEcho, true)
		XCTAssertEqual(fakeController.setThreadGoalObjectiveCalls, [])
		XCTAssertEqual(session.runState, .running)
		XCTAssertEqual(session.runningStatusText, "Setting Codex goal…")
		let didBeginHydration = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.startOrResumeCallCount == 1
		}
		XCTAssertTrue(didBeginHydration)
		fakeController.unblockStartOrResume()
		let didSetGoal = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.setThreadGoalObjectiveCalls == ["improve benchmark coverage"]
				&& session.items.contains(where: { $0.kind == .system && $0.text.contains("Set Codex goal: improve benchmark coverage") })
		}
		XCTAssertTrue(didSetGoal)
		let didClearProgress = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .idle && session.runningStatusText == nil
		}
		XCTAssertTrue(didClearProgress)
		XCTAssertEqual(fakeController.sendUserMessageCallCount, 0)
	}

	func testStagedGoalSlashIndicatorUpdatesWhenWorkflowSelected() async {
		CodexGoalSupport.setEnabledForTesting(true)
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}
		let tabID = UUID()
		vm.test_setCurrentTabIDOverride(tabID)
		defer { vm.test_setCurrentTabIDOverride(nil) }
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec

		vm.storeDraftText(for: tabID, "/goal improve benchmark coverage")

		let stagedBeforeWorkflow = vm.makeStatusPillsSnapshot().stagedSlashCommand
		XCTAssertEqual(stagedBeforeWorkflow?.displayText, "/goal")
		XCTAssertEqual(stagedBeforeWorkflow?.action, .setObjective)
		XCTAssertEqual(stagedBeforeWorkflow?.appliesSelectedWorkflowContext, false)

		vm.selectWorkflow(AgentWorkflow.build.definition)

		let stagedAfterWorkflow = vm.makeStatusPillsSnapshot().stagedSlashCommand
		XCTAssertEqual(stagedAfterWorkflow?.displayText, "/goal")
		XCTAssertEqual(stagedAfterWorkflow?.action, .setObjective)
		XCTAssertEqual(stagedAfterWorkflow?.selectedWorkflowName, "Plan & Build")
		XCTAssertEqual(stagedAfterWorkflow?.appliesSelectedWorkflowContext, true)
		XCTAssertEqual(vm.makeComposerProps(tabID: tabID).stagedSlashCommand, stagedAfterWorkflow)
	}

	func testSkillNamespacedGoalDoesNotStageNativeGoalIndicator() async {
		CodexGoalSupport.setEnabledForTesting(true)
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}
		let tabID = UUID()
		vm.test_setCurrentTabIDOverride(tabID)
		defer { vm.test_setCurrentTabIDOverride(nil) }
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec

		vm.storeDraftText(for: tabID, "/skill:goal improve benchmark coverage")

		XCTAssertNil(vm.makeStatusPillsSnapshot().stagedSlashCommand)
		XCTAssertNil(vm.makeComposerProps(tabID: tabID).stagedSlashCommand)
	}

	func testComputerUseSlashWithSelectedPromptWorkflowIsBlocked() async {
		CodexComputerUseWorkflow.setEnabledForTesting(true)
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}
		let tabID = UUID()
		vm.test_setCurrentTabIDOverride(tabID)
		defer { vm.test_setCurrentTabIDOverride(nil) }
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		vm.selectWorkflow(AgentWorkflow.build.definition)

		let result = vm.test_submitUserTurn(tabID: tabID, text: "/computer-use inspect the browser")

		guard case .blocked(let message) = result else {
			return XCTFail("Expected /computer-use with a selected prompt workflow to be blocked")
		}
		XCTAssertTrue(message.contains("Clear the selected prompt workflow"))
		XCTAssertEqual(session.selectedWorkflow?.builtInWorkflow, .build)
		XCTAssertNil(session.pendingCodexComputerUseActivation)
		XCTAssertEqual(fakeController.sendUserMessageCallCount, 0)
	}

	func testGoalResultRowsDoNotBlockInitialThreadContextForFirstRealTurn() async {
		CodexGoalSupport.setEnabledForTesting(true)
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec

		XCTAssertEqual(vm.test_submitUserTurn(tabID: tabID, text: "/goal improve benchmark coverage"), .submitted)
		let didSetGoal = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.setThreadGoalObjectiveCalls == ["improve benchmark coverage"]
				&& session.items.contains(where: { $0.kind == .system && $0.text.contains("Set Codex goal") })
		}
		XCTAssertTrue(didSetGoal)

		let firstRealUserItem = AgentChatItem.user("first real turn", sequenceIndex: session.nextSequenceIndex)
		session.appendItem(firstRealUserItem)

		XCTAssertTrue(
			vm.test_shouldIncludeInitialThreadContext(for: session),
			"Local native /goal result rows should not make the first real provider turn skip initial RepoPrompt context"
		)
	}

	func testIdleGoalCommandReschedulesIdleShutdown() async {
		CodexGoalSupport.setEnabledForTesting(true)
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath,
			codexControllerFactory: { _, _, _, _, _, _ in
				fakeController
			},
			testCodexIdleShutdownDelayNanos: 25_000_000
		)
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.runState = .idle

		XCTAssertEqual(vm.test_submitUserTurn(tabID: tabID, text: "/goal improve benchmark coverage"), .submitted)
		let didSetGoal = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.setThreadGoalObjectiveCalls == ["improve benchmark coverage"]
		}
		XCTAssertTrue(didSetGoal)

		let idleShutdownApplied = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.shutdownCallCount >= 1
				&& session.codexController == nil
				&& session.codexNeedsReconnect
		}
		XCTAssertTrue(idleShutdownApplied, "Idle /goal should reschedule Codex idle shutdown after the control-plane request")
	}

	func testCodexSlashSuggestionsIncludeCollisionSkillsWithExplicitNamespace() async throws {
		CodexGoalSupport.setEnabledForTesting(true)
		CodexComputerUseWorkflow.setEnabledForTesting(false)
		let workspaceURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("codex-native-slash-suggestions-\(UUID().uuidString)", isDirectory: true)
		let homeURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("codex-native-slash-home-\(UUID().uuidString)", isDirectory: true)
		defer {
			try? FileManager.default.removeItem(at: workspaceURL)
			try? FileManager.default.removeItem(at: homeURL)
		}
		let slashRoot = workspaceURL.appendingPathComponent(".agents/slash", isDirectory: true)
		try FileManager.default.createDirectory(at: slashRoot, withIntermediateDirectories: true)
		try "# Compact skill\n\nThis skill should remain visible through /skill:compact for Codex.".write(
			to: slashRoot.appendingPathComponent("compact.md"),
			atomically: true,
			encoding: .utf8
		)
		try "# Computer-use skill\n\nThis skill should remain visible through /skill:computer-use for Codex.".write(
			to: slashRoot.appendingPathComponent("computer-use.md"),
			atomically: true,
			encoding: .utf8
		)
		let skillCatalog = AgentSkillCatalog(homeDirectoryURL: homeURL)
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: workspaceURL.path,
			skillCatalog: skillCatalog,
			codexControllerFactory: { _, _, _, _, _, _ in
				FakeCodexController()
			}
		)
		let tabID = UUID()
		vm.test_setCurrentTabIDOverride(tabID)
		defer { vm.test_setCurrentTabIDOverride(nil) }
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec

		let suggestions = await vm.slashSkillSuggestions(for: "")

		let relativePaths = suggestions.map(\.relativePath)
		XCTAssertTrue(relativePaths.contains("goal"))
		XCTAssertTrue(relativePaths.contains("skill:computer-use"), "Disabled native /computer-use should not hide a same-named slash skill; the explicit namespace disambiguates it")
		XCTAssertTrue(relativePaths.contains("skill:compact"), "Unavailable native /compact should not hide a same-named slash skill; the explicit namespace disambiguates it")
		XCTAssertFalse(relativePaths.contains("computer-use"), "The disabled native command itself should remain hidden")
		XCTAssertFalse(relativePaths.contains("compact"), "Unavailable native /compact itself should remain hidden")
	}

	func testNonCodexSlashSuggestionsDoNotReserveCodexNativeCommandNames() async throws {
		let workspaceURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("noncodex-native-slash-suggestions-\(UUID().uuidString)", isDirectory: true)
		let homeURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("noncodex-native-slash-home-\(UUID().uuidString)", isDirectory: true)
		defer {
			try? FileManager.default.removeItem(at: workspaceURL)
			try? FileManager.default.removeItem(at: homeURL)
		}
		let slashRoot = workspaceURL.appendingPathComponent(".agents/slash", isDirectory: true)
		try FileManager.default.createDirectory(at: slashRoot, withIntermediateDirectories: true)
		try "# Compact skill\n\nThis skill should remain visible outside Codex.".write(
			to: slashRoot.appendingPathComponent("compact.md"),
			atomically: true,
			encoding: .utf8
		)
		try "# Computer-use skill\n\nThis skill should remain visible outside Codex.".write(
			to: slashRoot.appendingPathComponent("computer-use.md"),
			atomically: true,
			encoding: .utf8
		)
		let skillCatalog = AgentSkillCatalog(homeDirectoryURL: homeURL)
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: workspaceURL.path,
			skillCatalog: skillCatalog,
			codexControllerFactory: { _, _, _, _, _, _ in
				FakeCodexController()
			}
		)
		let tabID = UUID()
		vm.test_setCurrentTabIDOverride(tabID)
		defer { vm.test_setCurrentTabIDOverride(nil) }
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .claudeCode

		let compactSuggestions = await vm.slashSkillSuggestions(for: "compact")
		let computerUseSuggestions = await vm.slashSkillSuggestions(for: "computer-use")

		XCTAssertTrue(compactSuggestions.contains(where: { $0.relativePath == "compact" }), "Codex native command names should not hide slash skills for non-Codex sessions")
		XCTAssertTrue(computerUseSuggestions.contains(where: { $0.relativePath == "computer-use" }), "Codex native /computer-use should not hide slash skills for non-Codex sessions")
	}

	func testComputerUseSlashSubmitsNormalTurnWhenFeatureDisabled() async {
		CodexComputerUseWorkflow.setEnabledForTesting(false)
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.runState = .idle

		let result = vm.test_submitUserTurn(tabID: tabID, text: "/computer-use inspect the browser")

		XCTAssertEqual(result, .submitted)
		let sent = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.sendUserMessageCallCount == 1
		}
		XCTAssertTrue(sent, "Expected disabled direct /computer-use to send as a normal Codex turn")
		XCTAssertNil(session.pendingCodexComputerUseActivation)
		let sentText = fakeController.sentTurns.first?.text ?? ""
		XCTAssertTrue(sentText.contains("/computer-use inspect the browser"))
		XCTAssertFalse(sentText.contains("<computer_use_workflow>"))
		XCTAssertFalse(sentText.contains(CodexComputerUseWorkflow.disabledMessage))
	}

	func testDisabledComputerUseDirectSlashDoesNotResolveSameNamedSkillButSkillNamespaceWorks() async throws {
		CodexComputerUseWorkflow.setEnabledForTesting(false)
		let workspaceURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("codex-disabled-computer-use-skill-\(UUID().uuidString)", isDirectory: true)
		let homeURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("codex-disabled-computer-use-home-\(UUID().uuidString)", isDirectory: true)
		defer {
			try? FileManager.default.removeItem(at: workspaceURL)
			try? FileManager.default.removeItem(at: homeURL)
		}
		let slashRoot = workspaceURL.appendingPathComponent(".agents/slash", isDirectory: true)
		try FileManager.default.createDirectory(at: slashRoot, withIntermediateDirectories: true)
		try "Skill-based computer use.\n$ARGUMENTS".write(
			to: slashRoot.appendingPathComponent("computer-use.md"),
			atomically: true,
			encoding: .utf8
		)
		let fakeController = FakeCodexController()
		let skillCatalog = AgentSkillCatalog(homeDirectoryURL: homeURL)
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: workspaceURL.path,
			skillCatalog: skillCatalog
		) { _, _, _, _, _, _ in
			fakeController
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.runState = .idle

		let result = vm.test_submitUserTurn(tabID: tabID, text: "/computer-use inspect the browser")

		XCTAssertEqual(result, .submitted)
		let sent = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.sendUserMessageCallCount == 1
		}
		XCTAssertTrue(sent)
		let sentText = fakeController.sentTurns.first?.text ?? ""
		XCTAssertTrue(sentText.contains("/computer-use inspect the browser"))
		XCTAssertFalse(sentText.contains("Skill-based computer use."))
		XCTAssertFalse(sentText.contains("<selected_skill_context name=\"computer-use\""))

		let namespacedExpansion = await vm.test_augmentUserMessageForProviderSend(
			"/skill:computer-use inspect the browser",
			agent: .codexExec
		)
		XCTAssertTrue(namespacedExpansion.contains("<selected_skill_context name=\"computer-use\""))
		XCTAssertTrue(namespacedExpansion.contains("Skill-based computer use."))
		XCTAssertTrue(namespacedExpansion.contains("<user_instructions>\ninspect the browser\n</user_instructions>"))
	}

	func testComputerUseSlashSubmitsGuidedCodexTurnWithScopedActivation() async throws {
		CodexComputerUseWorkflow.setEnabledForTesting(true)
		let computerUseController = FakeCodexController()
		let normalController = FakeCodexController()
		let createdControllers = [computerUseController, normalController]
		var nextControllerIndex = 0
		var createdComputerUseFlags: [Bool] = []
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath,
			codexControllerFactory: { _, _, _, _, _, _ in normalController },
			codexControllerFactoryWithComputerUse: { _, _, _, _, _, _, computerUseEnabled in
				createdComputerUseFlags.append(computerUseEnabled)
				defer { nextControllerIndex += 1 }
				return createdControllers[min(nextControllerIndex, createdControllers.count - 1)]
			}
		)
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec

		let result = vm.test_submitUserTurn(tabID: tabID, text: "/computer-use open example.com and summarize the page")

		XCTAssertEqual(result, .submitted)
		let sent = await waitForCondition(timeoutSeconds: 2.0) {
			computerUseController.sendUserMessageCallCount == 1
		}
		XCTAssertTrue(sent)
		XCTAssertEqual(createdComputerUseFlags, [true])
		XCTAssertEqual(session.codexControllerComputerUseEnabled, true)
		XCTAssertNotNil(session.pendingCodexComputerUseActivation)
		XCTAssertEqual(session.items.last?.workflow?.displayName, "/computer-use")
		XCTAssertEqual(session.items.last?.text, "open example.com and summarize the page")
		let sentText = try XCTUnwrap(computerUseController.sentTurns.first?.text)
		XCTAssertTrue(sentText.contains("<computer_use_workflow>"))
		XCTAssertTrue(sentText.contains("tool search"))
		XCTAssertTrue(sentText.contains("open example.com and summarize the page"))
		XCTAssertEqual(computerUseController.getThreadGoalCallCount, 0)
		XCTAssertEqual(computerUseController.compactThreadCallCount, 0)

		computerUseController.emit(.turnStarted(turnID: "computer-use-turn"))
		computerUseController.emit(.turnCompleted(turnID: "computer-use-turn", status: .completed))
		let cleared = await waitForCondition(timeoutSeconds: 2.0) {
			session.pendingCodexComputerUseActivation == nil
				&& session.codexController == nil
				&& session.codexControllerComputerUseEnabled == false
				&& session.codexNeedsReconnect
		}
		XCTAssertTrue(cleared, "Computer-use activation should be one-shot and should not leak into the next Codex turn")

		let normalResult = vm.test_submitUserTurn(tabID: tabID, text: "continue with a normal Codex turn")
		XCTAssertEqual(normalResult, .submitted)
		let sentNormalTurn = await waitForCondition(timeoutSeconds: 2.0) {
			createdComputerUseFlags == [true, false]
				&& normalController.sendUserMessageCallCount == 1
		}
		XCTAssertTrue(sentNormalTurn, "The next normal Codex turn should recreate the controller without scoped computer-use enabled")
		XCTAssertNil(session.pendingCodexComputerUseActivation)
		XCTAssertEqual(session.codexControllerComputerUseEnabled, false)
	}

	func testComputerUseSlashRecreatesWarmNormalControllerWithFreshRunID() async throws {
		CodexComputerUseWorkflow.setEnabledForTesting(true)
		let normalController = FakeCodexController()
		let computerUseController = FakeCodexController()
		let createdControllers = [normalController, computerUseController]
		var nextControllerIndex = 0
		var factoryCalls: [(runID: UUID, computerUseEnabled: Bool)] = []
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath,
			codexControllerFactory: { _, _, _, _, _, _ in normalController },
			codexControllerFactoryWithComputerUse: { runID, _, _, _, _, _, computerUseEnabled in
				factoryCalls.append((runID: runID, computerUseEnabled: computerUseEnabled))
				defer { nextControllerIndex += 1 }
				return createdControllers[min(nextControllerIndex, createdControllers.count - 1)]
			},
			testCodexIdleShutdownDelayNanos: 60_000_000_000
		)
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec

		await vm.startAgentRun(tabID: tabID, initialMessage: "warm normal Codex controller")
		let warmed = await waitForCondition(timeoutSeconds: 2.0) {
			normalController.startOrResumeCallCount == 1
				&& normalController.sendUserMessageCallCount == 1
				&& session.runID != nil
		}
		XCTAssertTrue(warmed, "Expected a normal Codex controller to be warm before /computer-use")
		let normalRunID = try XCTUnwrap(session.runID)
		XCTAssertEqual(factoryCalls.map { $0.computerUseEnabled }, [false])
		XCTAssertEqual(session.codexControllerComputerUseEnabled, false)
		normalController.emit(.turnStarted(turnID: "normal-turn"))
		normalController.emit(.turnCompleted(turnID: "normal-turn", status: .completed))
		let normalTurnCompleted = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .completed
				&& session.codexController != nil
		}
		XCTAssertTrue(normalTurnCompleted, "Normal completed turn should leave a warm controller available for reuse")

		let result = vm.test_submitUserTurn(tabID: tabID, text: "/computer-use inspect the current browser")

		XCTAssertEqual(result, .submitted)
		let sentComputerUseTurn = await waitForCondition(timeoutSeconds: 2.0) {
			factoryCalls.map { $0.computerUseEnabled } == [false, true]
				&& computerUseController.startOrResumeCallCount == 1
				&& computerUseController.sendUserMessageCallCount == 1
				&& normalController.shutdownCallCount == 1
				&& session.runID == factoryCalls.last?.runID
		}
		XCTAssertTrue(sentComputerUseTurn, "Warm normal controller should be recreated with scoped computer-use enabled and a fresh session runID")
		let computerUseRunID = try XCTUnwrap(session.runID)
		XCTAssertNotEqual(computerUseRunID, normalRunID)
		XCTAssertEqual(session.codexControllerComputerUseEnabled, true)
		XCTAssertNotNil(session.pendingCodexComputerUseActivation)
		XCTAssertEqual(normalController.shutdownCallCount, 1)
		XCTAssertTrue(computerUseController.sentTurns.first?.text.contains("<computer_use_workflow>") == true)

		computerUseController.emit(.turnStarted(turnID: "computer-use-turn"))
		computerUseController.emit(.turnCompleted(turnID: "computer-use-turn", status: .completed))
		let cleared = await waitForCondition(timeoutSeconds: 2.0) {
			session.pendingCodexComputerUseActivation == nil
				&& session.codexController == nil
				&& session.codexControllerComputerUseEnabled == false
		}
		XCTAssertTrue(cleared, "Computer-use activation should clear after the recreated controller completes")
	}

	func testComputerUseSlashIsBlockedDuringActiveCodexRun() async {
		CodexComputerUseWorkflow.setEnabledForTesting(true)
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.runState = .running

		let result = vm.test_submitUserTurn(tabID: tabID, text: "/computer-use inspect the browser")

		guard case .blocked(let message) = result else {
			return XCTFail("Expected /computer-use to be blocked during an active Codex run")
		}
		XCTAssertTrue(message.contains("Wait for the current Codex turn to finish"))
		XCTAssertNil(session.pendingCodexComputerUseActivation)
		XCTAssertEqual(fakeController.sendUserMessageCallCount, 0)
	}

	func testGoalControlCommandsDispatchToControllerDuringActiveRun() async {
		CodexGoalSupport.setEnabledForTesting(true)
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		do {
			_ = try await fakeController.startOrResume(existing: nil, baseInstructions: "")
		} catch {
			return XCTFail("Failed to activate fake Codex thread: \(error)")
		}
		session.codexController = fakeController
		session.codexControllerGoalSupportEnabled = true
		session.runState = .running
		session.codexNeedsReconnect = true
		fakeController.currentGoal = makeThreadGoal(objective: "Improve benchmark coverage")

		XCTAssertEqual(vm.test_submitUserTurn(tabID: tabID, text: "/goal pause"), .submitted)
		let paused = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.setThreadGoalStatusCalls == [.paused]
				&& session.items.contains(where: { $0.kind == .system && $0.text.contains("Paused Codex goal") })
		}
		XCTAssertTrue(paused)

		XCTAssertEqual(vm.test_submitUserTurn(tabID: tabID, text: "/goal resume"), .submitted)
		let resumed = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.setThreadGoalStatusCalls == [.paused, .active]
				&& session.items.contains(where: { $0.kind == .system && $0.text.contains("Resumed Codex goal") })
		}
		XCTAssertTrue(resumed)

		XCTAssertEqual(vm.test_submitUserTurn(tabID: tabID, text: "/goal clear"), .submitted)
		let cleared = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.clearThreadGoalCallCount == 1
				&& session.items.contains(where: { $0.kind == .system && $0.text == "Cleared Codex goal." })
		}
		XCTAssertTrue(cleared)
		XCTAssertEqual(fakeController.sendUserMessageCallCount, 0)
		XCTAssertEqual(fakeController.startOrResumeCallCount, 1, "Active /goal control commands should not restart the thread")
		XCTAssertEqual(fakeController.shutdownCallCount, 0, "Active /goal should not tear down a live thread when reconnect is pending")
	}

	func testMCPDispatchActiveGoalResolvesCodexSteerAck() async throws {
		CodexGoalSupport.setEnabledForTesting(true)
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		_ = try await fakeController.startOrResume(existing: nil, baseInstructions: "")
		session.codexController = fakeController
		session.codexControllerGoalSupportEnabled = true
		session.runState = .running
		let sessionID = UUID()
		session.activeAgentSessionID = sessionID
		session.mcpControlContext = AgentModeViewModel.AgentMCPControlContext(
			sessionID: sessionID,
			activationID: UUID(),
			originatingConnectionID: nil,
			interactionTransport: .mcp(sessionID: sessionID, originatingConnectionID: nil),
			suppressUserNotifications: true,
			forceAutoEditEnabled: true,
			autoEditEnabledBeforeOverride: true,
			taskLabelKind: nil
		)
		fakeController.currentGoal = makeThreadGoal(objective: "Improve benchmark coverage")
		let sendCountBeforeGoal = fakeController.sendUserMessageCallCount

		let delivery = try await vm.mcpDispatchInstruction(
			sessionID: sessionID,
			text: "/goal pause",
			allowStartingRun: false
		)

		XCTAssertEqual(delivery, .dispatchedCodexTurn)
		XCTAssertEqual(fakeController.setThreadGoalStatusCalls, [.paused])
		XCTAssertEqual(fakeController.sendUserMessageCallCount, sendCountBeforeGoal)
		await vm.mcpDeactivateControlContext(sessionID: sessionID)
		await AgentRunSessionStore.cleanup(sessionID: sessionID)
	}

	func testBareGoalShowsCurrentGoalSummary() async {
		CodexGoalSupport.setEnabledForTesting(true)
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.codexConversationID = "test-thread"
		fakeController.currentGoal = makeThreadGoal(objective: "Ship /goal support", tokenBudget: 100, tokensUsed: 12)

		XCTAssertEqual(vm.test_submitUserTurn(tabID: tabID, text: "/goal"), .submitted)
		let showedGoal = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.getThreadGoalCallCount == 1
				&& session.items.contains(where: {
					$0.kind == .system
						&& $0.text.contains("Current Codex goal:")
						&& $0.text.contains("Ship /goal support")
						&& $0.text.contains("Tokens: 12/100")
				})
		}
		XCTAssertTrue(showedGoal)
		XCTAssertEqual(fakeController.sendUserMessageCallCount, 0)
	}

	func testGoalControlWithoutKnownThreadIsBlocked() async {
		CodexGoalSupport.setEnabledForTesting(true)
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec

		let result = vm.test_submitUserTurn(tabID: tabID, text: "/goal pause")
		guard case .blocked(let message) = result else {
			return XCTFail("Expected /goal pause to be blocked without a known thread")
		}
		XCTAssertEqual(message, "Start a Codex conversation before pausing a goal.")
		XCTAssertEqual(fakeController.startOrResumeCallCount, 0)
		XCTAssertEqual(fakeController.setThreadGoalStatusCalls, [])
	}

	func testGoalObjectiveTooLongIsBlockedBeforeControllerCall() async {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		let objective = String(repeating: "x", count: CodexAgentModeCoordinator.maxThreadGoalObjectiveCharacters + 1)

		let result = vm.test_submitUserTurn(tabID: tabID, text: "/goal \(objective)")
		guard case .blocked(let message) = result else {
			return XCTFail("Expected long /goal objective to be blocked")
		}
		XCTAssertTrue(message.contains("Goal objective is too long"))
		XCTAssertEqual(fakeController.startOrResumeCallCount, 0)
		XCTAssertEqual(fakeController.setThreadGoalObjectiveCalls, [])
	}

	func testCompactFromIdleBootstrapsPolicyBeforeStartingThread() async {
		let fakeController = FakeCodexController()
		var policyCalls: [CodexPolicyInstallCall] = []
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath,
			shouldManageCodexTooling: true,
			codexControllerFactory: { _, _, _, _, _, _ in
				fakeController
			},
			connectionPolicyInstaller: { clientName, policyWindowID, restrictedTools, oneShot, reason, ttl, policyTabID, policyRunID, additionalTools, purpose, _, _, _ in
				policyCalls.append(
					CodexPolicyInstallCall(
						clientName: clientName,
						windowID: policyWindowID,
						restrictedTools: restrictedTools,
						oneShot: oneShot,
						reason: reason,
						ttl: ttl,
						tabID: policyTabID,
						runID: policyRunID,
						additionalTools: additionalTools,
						purpose: purpose
					)
				)
			},
			testCodexLeaseRoutingTimeoutMs: 10
		)
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.codexConversationID = "thread-1"
		session.runState = .idle

		let compactResult = vm.test_submitUserTurn(tabID: tabID, text: "/compact")
		XCTAssertEqual(compactResult, .submitted)

		let didBootstrapAndCompact = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.startOrResumeCallCount == 1
				&& fakeController.compactThreadCallCount == 1
				&& policyCalls.count == 1
				&& session.runID != nil
		}
		XCTAssertTrue(didBootstrapAndCompact, "Expected idle /compact to install policy before starting the Codex thread")
		XCTAssertEqual(policyCalls.first?.tabID, tabID)
		XCTAssertEqual(policyCalls.first?.runID, session.runID)
		XCTAssertEqual(policyCalls.first?.purpose, .agentModeRun)
	}

	func testCompactQueuesImmediateFollowUpUntilCompactionCompletesAndKeepsExplicitRepoPromptToolCardsVisible() async {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.codexConversationID = "thread-1"

		let compactResult = vm.test_submitUserTurn(tabID: tabID, text: "/compact")
		XCTAssertEqual(compactResult, .submitted)
		let compactRequested = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.compactThreadCallCount == 1
				&& session.runState == .running
				&& session.runningStatusText == "Compacting context…"
		}
		XCTAssertTrue(compactRequested, "Expected /compact to enter local running state immediately")

		let followUpResult = vm.test_submitUserTurn(tabID: tabID, text: "continue after compact")
		XCTAssertEqual(followUpResult, .submitted)
		XCTAssertEqual(fakeController.sendUserMessageCallCount, 0, "Follow-up should wait for compaction to finish")
		XCTAssertEqual(session.pendingCodexCompactionInstructions, ["continue after compact"])

		fakeController.emit(.turnStarted(turnID: "compact-turn"))
		fakeController.emit(.contextCompacted(turnID: "compact-turn"))
		let didMarkCompacted = await waitForCondition(timeoutSeconds: 2.0) {
			session.contextCompactedAt != nil
		}
		XCTAssertTrue(didMarkCompacted, "Expected thread/compacted to update local compaction state")

		fakeController.emit(.turnCompleted(turnID: "compact-turn", status: .completed))
		let didSendQueuedFollowUp = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.sendUserMessageCallCount == 1
				&& session.pendingCodexCompactionInstructions.isEmpty
		}
		XCTAssertTrue(didSendQueuedFollowUp, "Expected queued follow-up to start after compaction completion")
		XCTAssertEqual(fakeController.sentTurns.last?.text, "continue after compact")
		XCTAssertEqual(session.runState, .running)

		let toolInvocationID = UUID()
		let resultJSON = #"{"files":["README.md"]}"#
		fakeController.emit(.turnStarted(turnID: "user-turn"))
		vm.testSimulateCodexRepoPromptToolCall(
			tabID: tabID,
			invocationID: toolInvocationID,
			toolName: "mcp__RepoPrompt__manage_selection",
			args: ["op": .string("get"), "view": .string("files")]
		)
		vm.testSimulateCodexRepoPromptToolResult(
			tabID: tabID,
			invocationID: toolInvocationID,
			toolName: "mcp__RepoPrompt__manage_selection",
			args: ["op": .string("get"), "view": .string("files")],
			resultJSON: resultJSON,
			isError: false
		)
		let didRenderTool = await waitForCondition(timeoutSeconds: 2.0) {
			session.items.contains(where: {
				$0.toolInvocationID == toolInvocationID
					&& $0.toolName == "mcp__RepoPrompt__manage_selection"
					&& $0.kind == .toolResult
					&& $0.toolResultJSON == resultJSON
			})
		}
		XCTAssertTrue(didRenderTool, "Expected post-compaction RepoPrompt tool cards to remain visible in the feed")
	}

	func testCompactTurnStartBeforeRequestReturnsStillQueuesFollowUp() async {
		let fakeController = FakeCodexController()
		fakeController.onCompactThread = { [weak fakeController] in
			fakeController?.emit(.turnStarted(turnID: "compact-turn"))
		}
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.codexConversationID = "thread-1"

		XCTAssertEqual(vm.test_submitUserTurn(tabID: tabID, text: "/compact"), .submitted)
		let compactStartedEarly = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.compactThreadCallCount == 1
				&& session.codexTurnKindsByID["compact-turn"] == .compact
		}
		XCTAssertTrue(compactStartedEarly, "Expected compaction turn to remain tagged as compact even if turnStarted arrives before compactThread returns")

		let followUpResult = vm.test_submitUserTurn(tabID: tabID, text: "continue after compact")
		XCTAssertEqual(followUpResult, .submitted)
		XCTAssertEqual(fakeController.sendUserMessageCallCount, 0, "Follow-up should still queue while compact turn is active")
		XCTAssertEqual(session.pendingCodexCompactionInstructions, ["continue after compact"])

		fakeController.emit(.turnCompleted(turnID: "compact-turn", status: .completed))
		let didDrain = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.sendUserMessageCallCount == 1
				&& session.pendingCodexCompactionInstructions.isEmpty
		}
		XCTAssertTrue(didDrain)
	}

	func testSecondFollowUpDuringCompactionIsBlockedAndRestoredToDraft() async {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.codexConversationID = "thread-1"

		XCTAssertEqual(vm.test_submitUserTurn(tabID: tabID, text: "/compact"), .submitted)
		let compactRequested = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.compactThreadCallCount == 1 && session.runState == .running
		}
		XCTAssertTrue(compactRequested)

		XCTAssertEqual(vm.test_submitUserTurn(tabID: tabID, text: "first follow-up"), .submitted)
		let secondResult = vm.test_submitUserTurn(tabID: tabID, text: "second follow-up")
		guard case .blocked(let message) = secondResult else {
			return XCTFail("Expected second follow-up to be blocked while compaction is in flight")
		}
		XCTAssertTrue(message.contains("Wait for Codex compaction to finish"))
		XCTAssertEqual(session.pendingCodexCompactionInstructions, ["first follow-up"])
		XCTAssertEqual(vm.retrieveDraftText(for: tabID), "second follow-up")
		XCTAssertEqual(fakeController.sendUserMessageCallCount, 0)
	}

	func testBlockedCompactionFollowUpPreservesSelectedWorkflow() async {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.codexConversationID = "thread-1"

		XCTAssertEqual(vm.test_submitUserTurn(tabID: tabID, text: "/compact"), .submitted)
		let compactRequested = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.compactThreadCallCount == 1 && session.runState == .running
		}
		XCTAssertTrue(compactRequested)

		XCTAssertEqual(vm.test_submitUserTurn(tabID: tabID, text: "first follow-up"), .submitted)
		let workflow = AgentWorkflow.build.definition
		session.selectedWorkflow = workflow

		let blockedResult = vm.test_submitUserTurn(tabID: tabID, text: "second follow-up")
		guard case .blocked(let message) = blockedResult else {
			return XCTFail("Expected second follow-up to be blocked while compaction is in flight")
		}
		XCTAssertTrue(message.contains("Wait for Codex compaction to finish"))
		XCTAssertEqual(session.selectedWorkflow, workflow)
		XCTAssertEqual(vm.retrieveDraftText(for: tabID), "second follow-up")
	}

	func testCompactFailureRestoresQueuedFollowUpToDraft() async {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.codexConversationID = "thread-1"

		XCTAssertEqual(vm.test_submitUserTurn(tabID: tabID, text: "/compact"), .submitted)
		let compactRequested = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.compactThreadCallCount == 1 && session.runState == .running
		}
		XCTAssertTrue(compactRequested)

		XCTAssertEqual(vm.test_submitUserTurn(tabID: tabID, text: "continue after compact"), .submitted)
		fakeController.emit(.turnStarted(turnID: "compact-turn"))
		fakeController.emit(.turnCompleted(turnID: "compact-turn", status: .failed))
		let restored = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .failed
				&& session.pendingCodexCompactionInstructions.isEmpty
				&& vm.retrieveDraftText(for: tabID) == "continue after compact"
		}
		XCTAssertTrue(restored, "Expected failed compaction to restore queued follow-up to the draft")
		XCTAssertEqual(fakeController.sendUserMessageCallCount, 0)
	}

	func testSubmitUserTurnForwardsPendingImageAttachmentsToCodexController() async {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		let imagePath = "/tmp/codex-forwarded-image-\(UUID().uuidString).png"
		let attachment = AgentImageAttachment(source: .localFile(path: imagePath), title: "forwarded.png")
		session.pendingImageAttachments = [attachment]

		let result = vm.test_submitUserTurn(tabID: tabID, text: "Describe the attached image")
		XCTAssertEqual(result, .submitted)

		let didSend = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.sentTurns.count == 1
		}
		XCTAssertTrue(didSend, "Expected Codex controller to receive exactly one turn")
		guard let sentTurn = fakeController.sentTurns.first else {
			return XCTFail("Expected recorded sent turn")
		}
		XCTAssertEqual(sentTurn.text, "Describe the attached image")
		XCTAssertEqual(sentTurn.images, [attachment])
		XCTAssertTrue(session.pendingImageAttachments.isEmpty, "Pending attachments should clear after submit")
	}

	func testCodexFollowUpDuringStreamingAssistantKeepsAssistantContiguous() async {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.runState = .running
		session.codexConversationID = "thread-1"

		var assistantItem = AgentChatItem.assistant("Hello", sequenceIndex: session.nextSequenceIndex)
		assistantItem.isStreaming = true
		session.appendItem(assistantItem)
		session.pendingAssistantDelta = " there"

		let result = vm.test_submitUserTurn(tabID: tabID, text: "follow up")
		XCTAssertEqual(result, .submitted)
		XCTAssertEqual(session.items.map(\.kind), [.assistant, .user])
		XCTAssertEqual(session.items[0].text, "Hello there")
		XCTAssertEqual(session.items[1].text, "follow up")

		vm.enqueueAssistantDelta("!", session: session)
		vm.flushPendingAssistantDelta(session)

		XCTAssertEqual(session.items.map(\.kind), [.assistant, .user])
		XCTAssertEqual(session.items[0].text, "Hello there!")
	}

	func testCodexActiveSendWaitsForAgentRunWaitDrainBeforeNativeSend() async {
		let fakeController = FakeCodexController()
		let drainStarted = LockedBool(false)
		let drainGate = AsyncDrainGate()
		let drainedRunIDs = LockedUUIDArray()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath,
			codexControllerFactory: { _, _, _, _, _, _ in
				fakeController
			},
			testCodexAgentRunWaitDrain: { runID, _ in
				drainedRunIDs.append(runID)
				drainStarted.set(true)
				await drainGate.wait()
				return true
			}
		)

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec

		await vm.startAgentRun(tabID: tabID, initialMessage: "initial turn")
		let initialSent = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.sendUserMessageCallCount == 1 && session.runID != nil
		}
		XCTAssertTrue(initialSent)
		guard let runID = session.runID else {
			return XCTFail("Expected initial Codex turn to establish a runID")
		}

		XCTAssertEqual(vm.test_submitUserTurn(tabID: tabID, text: "active steer"), .submitted)
		let drainObserved = await waitForCondition(timeoutSeconds: 2.0) {
			drainStarted.get()
		}
		XCTAssertTrue(drainObserved)
		XCTAssertEqual(fakeController.sendUserMessageCallCount, 1, "Native active send should wait for the drain gate")

		await drainGate.release()
		let activeSendFinished = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.sendUserMessageCallCount == 2
		}
		XCTAssertTrue(activeSendFinished)
		XCTAssertEqual(drainedRunIDs.snapshot(), [runID])
	}

	func testCodexActiveSendDrainTimeoutDoesNotSendNativeTurn() async {
		let fakeController = FakeCodexController()
		let failDrain = LockedBool(false)
		let drainedRunIDs = LockedUUIDArray()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath,
			codexControllerFactory: { _, _, _, _, _, _ in
				fakeController
			},
			testCodexAgentRunWaitDrain: { runID, _ in
				drainedRunIDs.append(runID)
				return !failDrain.get()
			}
		)

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec

		await vm.startAgentRun(tabID: tabID, initialMessage: "initial turn")
		let initialSent = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.sendUserMessageCallCount == 1 && session.runID != nil
		}
		XCTAssertTrue(initialSent)
		guard let runID = session.runID else {
			return XCTFail("Expected initial Codex turn to establish a runID")
		}

		failDrain.set(true)
		XCTAssertEqual(vm.test_submitUserTurn(tabID: tabID, text: "active steer blocked by child wait"), .submitted)
		let failedSafely = await waitForCondition(timeoutSeconds: 2.0) {
			session.items.contains { $0.kind == .error && $0.text.contains("child agent_run.wait scopes did not drain") }
		}
		XCTAssertTrue(failedSafely)
		XCTAssertEqual(fakeController.sendUserMessageCallCount, 1, "Drain timeout must not send a native Codex turn")
		XCTAssertEqual(session.runState, .running)
		XCTAssertEqual(drainedRunIDs.snapshot(), [runID])
	}

	func testSteerRestartsActiveRunElapsedTimerForRunningSession() async {
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			FakeCodexController()
		}

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.runState = .running
		session.codexConversationID = "thread-1"
		let previousRunStartedAt = Date(timeIntervalSinceNow: -300)
		session.activeAgentRunStartedAt = previousRunStartedAt

		let result = vm.test_submitUserTurn(tabID: tabID, text: "steer onto this follow-up")

		XCTAssertEqual(result, .submitted)
		guard let restartedAt = session.activeAgentRunStartedAt else {
			return XCTFail("Expected the active-run elapsed anchor to remain populated after steering")
		}
		XCTAssertNotEqual(restartedAt, previousRunStartedAt)
		XCTAssertLessThan(abs(restartedAt.timeIntervalSinceNow), 2)
	}

	func testAttachImagesStoresFilesUnderTemporaryDirectoryNotRepoRoot() async throws {
		let repoRoot = try makeTemporaryWorkspace(prefix: "AgentModeAttachmentRepoRoot")
		defer {
			try? FileManager.default.removeItem(at: repoRoot)
		}

		let sourceImageURL = repoRoot.appendingPathComponent("source.png")
		try Data([0x89, 0x50, 0x4E, 0x47]).write(to: sourceImageURL)

		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: repoRoot.path
		) { _, _, _, _, _, _ in
			FakeCodexController()
		}

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		vm.attachImages(tabID: tabID, urls: [sourceImageURL])
		guard let attachment = session.pendingImageAttachments.first else {
			return XCTFail("Expected one pending image attachment")
		}
		guard case let .localFile(path) = attachment.source else {
			return XCTFail("Expected local file attachment source")
		}

		let expectedPrefix = AgentAttachmentStore.managedStorageRootURL(for: FileManager.default.temporaryDirectory).path + "/"
		XCTAssertTrue(path.hasPrefix(expectedPrefix), "Expected attachment under the agent temp directory")
		XCTAssertFalse(path.hasPrefix(repoRoot.path + "/"), "Attachment should not be stored under repo root")
	}

	func testAttachImagesSkipsDuplicateSourcePathAcrossMultiplePastes() async throws {
		let repoRoot = try makeTemporaryWorkspace(prefix: "AgentModeDuplicatePastePathRepo")
		let workspaceDirectory = try makeTemporaryWorkspace(prefix: "AgentModeDuplicatePastePathWorkspace")
		defer {
			try? FileManager.default.removeItem(at: repoRoot)
			try? FileManager.default.removeItem(at: workspaceDirectory)
		}

		let sourceImageURL = repoRoot.appendingPathComponent("duplicate.png")
		try Data([0x89, 0x50, 0x4E, 0x47]).write(to: sourceImageURL)

		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: repoRoot.path,
			testWorkspaceDirectory: workspaceDirectory
		) { _, _, _, _, _, _ in
			FakeCodexController()
		}

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		vm.attachImages(tabID: tabID, urls: [sourceImageURL])
		vm.attachImages(tabID: tabID, urls: [sourceImageURL])

		XCTAssertEqual(session.pendingImageAttachments.count, 1)
	}

	func testAttachImagesSkipsDuplicateContentAcrossDifferentSourcePaths() async throws {
		let repoRoot = try makeTemporaryWorkspace(prefix: "AgentModeDuplicatePasteContentRepo")
		let workspaceDirectory = try makeTemporaryWorkspace(prefix: "AgentModeDuplicatePasteContentWorkspace")
		defer {
			try? FileManager.default.removeItem(at: repoRoot)
			try? FileManager.default.removeItem(at: workspaceDirectory)
		}

		let sharedPNGData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
		let sourceImageA = repoRoot.appendingPathComponent("duplicate-a.png")
		let sourceImageB = repoRoot.appendingPathComponent("duplicate-b.png")
		try sharedPNGData.write(to: sourceImageA)
		try sharedPNGData.write(to: sourceImageB)

		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: repoRoot.path,
			testWorkspaceDirectory: workspaceDirectory
		) { _, _, _, _, _, _ in
			FakeCodexController()
		}

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		vm.attachImages(tabID: tabID, urls: [sourceImageA, sourceImageB])

		XCTAssertEqual(session.pendingImageAttachments.count, 1)
	}

	func testImageInputAdapterExtractsOnlyImageFileURLsFromPasteboard() throws {
		let tempRoot = try makeTemporaryWorkspace(prefix: "AgentImageInputPasteboardURLs")
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let adapter = AgentImageInputAdapter(
			fileManager: .default,
			temporaryRoot: tempRoot.appendingPathComponent("tmp-images", isDirectory: true)
		)
		let imageURL = tempRoot.appendingPathComponent("drop-image.png")
		let textURL = tempRoot.appendingPathComponent("drop-note.txt")
		try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)
		try Data("hello".utf8).write(to: textURL)

		let pasteboard = NSPasteboard(name: NSPasteboard.Name("AgentImageInputAdapter-\(UUID().uuidString)"))
		pasteboard.clearContents()
		pasteboard.writeObjects([imageURL as NSURL, textURL as NSURL])

		let prepared = adapter.preparedImages(from: pasteboard)
		XCTAssertEqual(prepared.count, 1)
		XCTAssertEqual(prepared.first?.url.standardizedFileURL, imageURL.standardizedFileURL)
		XCTAssertEqual(prepared.first?.isTemporary, false)
	}

	func testImageInputAdapterAcceptsDiverseImageFileExtensions() throws {
		let tempRoot = try makeTemporaryWorkspace(prefix: "AgentImageInputDiverseExtensions")
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let adapter = AgentImageInputAdapter(
			fileManager: .default,
			temporaryRoot: tempRoot.appendingPathComponent("tmp-images", isDirectory: true)
		)
		let extensions = ["png", "JPG", "jpeg", "jfif", "webp", "avif", "heic", "heif", "gif", "bmp", "tif", "tiff", "svg", "ico"]
		var urls: [URL] = []
		for ext in extensions {
			let url = tempRoot.appendingPathComponent("image-\(ext)").appendingPathExtension(ext)
			try samplePNGData().write(to: url)
			urls.append(url)
		}

		let pasteboard = NSPasteboard(name: NSPasteboard.Name("AgentImageInputAdapter-\(UUID().uuidString)"))
		pasteboard.clearContents()
		pasteboard.writeObjects(urls.map { $0 as NSURL })

		let prepared = adapter.preparedImages(from: pasteboard)
		XCTAssertEqual(prepared.count, urls.count)
		let returned = Set(prepared.map { $0.url.standardizedFileURL.path })
		let expected = Set(urls.map { $0.standardizedFileURL.path })
		XCTAssertEqual(returned, expected)
		XCTAssertTrue(prepared.allSatisfy { !$0.isTemporary })
	}

	func testImageInputAdapterRejectsUnknownNonImageExtension() throws {
		let tempRoot = try makeTemporaryWorkspace(prefix: "AgentImageInputUnknownExtension")
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let adapter = AgentImageInputAdapter(
			fileManager: .default,
			temporaryRoot: tempRoot.appendingPathComponent("tmp-images", isDirectory: true)
		)
		let nonImageURL = tempRoot.appendingPathComponent("image.rawdata")
		try samplePNGData().write(to: nonImageURL)

		let pasteboard = NSPasteboard(name: NSPasteboard.Name("AgentImageInputAdapter-\(UUID().uuidString)"))
		pasteboard.clearContents()
		pasteboard.writeObjects([nonImageURL as NSURL])

		let prepared = adapter.preparedImages(from: pasteboard)
		XCTAssertTrue(prepared.isEmpty)
	}

	func testImageInputAdapterExtractsImageFileURLStringFromPasteboardItem() throws {
		let tempRoot = try makeTemporaryWorkspace(prefix: "AgentImageInputPasteboardURLString")
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let adapter = AgentImageInputAdapter(
			fileManager: .default,
			temporaryRoot: tempRoot.appendingPathComponent("tmp-images", isDirectory: true)
		)
		let imageURL = tempRoot.appendingPathComponent("drop-image.png")
		try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)

		let pasteboard = NSPasteboard(name: NSPasteboard.Name("AgentImageInputAdapter-\(UUID().uuidString)"))
		pasteboard.clearContents()
		let item = NSPasteboardItem()
		item.setString(imageURL.absoluteString, forType: .fileURL)
		pasteboard.writeObjects([item])

		let prepared = adapter.preparedImages(from: pasteboard)
		XCTAssertEqual(prepared.count, 1)
		XCTAssertEqual(prepared.first?.url.standardizedFileURL, imageURL.standardizedFileURL)
		XCTAssertEqual(prepared.first?.isTemporary, false)
	}

	func testImageInputAdapterExtractsImagePathFromPlainTextPasteboard() throws {
		let tempRoot = try makeTemporaryWorkspace(prefix: "AgentImageInputPasteboardPathText")
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let adapter = AgentImageInputAdapter(
			fileManager: .default,
			temporaryRoot: tempRoot.appendingPathComponent("tmp-images", isDirectory: true)
		)
		let imageURL = tempRoot.appendingPathComponent("drop-image.png")
		try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)

		let pasteboard = NSPasteboard(name: NSPasteboard.Name("AgentImageInputAdapter-\(UUID().uuidString)"))
		pasteboard.clearContents()
		pasteboard.setString(imageURL.path, forType: .string)

		let prepared = adapter.preparedImages(from: pasteboard)
		XCTAssertEqual(prepared.count, 1)
		XCTAssertEqual(prepared.first?.url.standardizedFileURL, imageURL.standardizedFileURL)
		XCTAssertEqual(prepared.first?.isTemporary, false)
	}

	func testImageInputAdapterExtractsImagePathWithSpacesAndAccentsFromPlainTextPasteboard() throws {
		let tempRoot = try makeTemporaryWorkspace(prefix: "AgentImageInputPasteboardPathTextAccents")
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let adapter = AgentImageInputAdapter(
			fileManager: .default,
			temporaryRoot: tempRoot.appendingPathComponent("tmp-images", isDirectory: true)
		)
		let imageURL = tempRoot.appendingPathComponent("capture à été 01.png")
		try samplePNGData().write(to: imageURL)

		let pasteboard = NSPasteboard(name: NSPasteboard.Name("AgentImageInputAdapter-\(UUID().uuidString)"))
		pasteboard.clearContents()
		pasteboard.setString(imageURL.path, forType: .string)

		XCTAssertTrue(adapter.shouldConsumePasteAsImageAttachment(from: pasteboard))
		let prepared = adapter.preparedImages(from: pasteboard)
		XCTAssertEqual(prepared.count, 1)
		XCTAssertEqual(prepared.first?.url.standardizedFileURL.path, imageURL.standardizedFileURL.path)
		XCTAssertEqual(prepared.first?.isTemporary, false)
	}

	func testImageInputAdapterExtractsPercentEncodedAccentedFileURLFromPlainTextPasteboard() throws {
		let tempRoot = try makeTemporaryWorkspace(prefix: "AgentImageInputPasteboardPercentEncodedAccents")
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let adapter = AgentImageInputAdapter(
			fileManager: .default,
			temporaryRoot: tempRoot.appendingPathComponent("tmp-images", isDirectory: true)
		)
		let imageURL = tempRoot.appendingPathComponent("capture à été encoded.png")
		try samplePNGData().write(to: imageURL)

		let pasteboard = NSPasteboard(name: NSPasteboard.Name("AgentImageInputAdapter-\(UUID().uuidString)"))
		pasteboard.clearContents()
		pasteboard.setString(imageURL.absoluteString, forType: .string)

		XCTAssertTrue(adapter.shouldConsumePasteAsImageAttachment(from: pasteboard))
		let prepared = adapter.preparedImages(from: pasteboard)
		XCTAssertEqual(prepared.count, 1)
		XCTAssertEqual(prepared.first?.url.standardizedFileURL.path, imageURL.standardizedFileURL.path)
		XCTAssertEqual(prepared.first?.isTemporary, false)
	}

	func testImageInputAdapterConsumesPlainTextPathOnlyPaste() throws {
		let tempRoot = try makeTemporaryWorkspace(prefix: "AgentImageInputConsumePathOnly")
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let adapter = AgentImageInputAdapter(fileManager: .default)
		let imageURL = tempRoot.appendingPathComponent("drop-image.png")
		try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)

		let pasteboard = NSPasteboard(name: NSPasteboard.Name("AgentImageInputAdapter-\(UUID().uuidString)"))
		pasteboard.clearContents()
		pasteboard.setString(imageURL.path, forType: .string)

		XCTAssertTrue(adapter.shouldConsumePasteAsImageAttachment(from: pasteboard))
	}

	func testImageInputAdapterDoesNotConsumeMixedPlainTextPaste() throws {
		let tempRoot = try makeTemporaryWorkspace(prefix: "AgentImageInputConsumeMixedText")
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let adapter = AgentImageInputAdapter(fileManager: .default)
		let imageURL = tempRoot.appendingPathComponent("drop-image.png")
		try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)

		let pasteboard = NSPasteboard(name: NSPasteboard.Name("AgentImageInputAdapter-\(UUID().uuidString)"))
		pasteboard.clearContents()
		pasteboard.setString("Please review this screenshot path: \(imageURL.path)", forType: .string)

		XCTAssertFalse(adapter.shouldConsumePasteAsImageAttachment(from: pasteboard))
	}

	func testImageInputAdapterExtractsImagePathEmbeddedInMarkdownTextPasteboard() throws {
		let tempRoot = try makeTemporaryWorkspace(prefix: "AgentImageInputPasteboardMarkdown")
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let adapter = AgentImageInputAdapter(
			fileManager: .default,
			temporaryRoot: tempRoot.appendingPathComponent("tmp-images", isDirectory: true)
		)
		let imageURL = tempRoot.appendingPathComponent("drop image.png")
		try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)

		let pasteboard = NSPasteboard(name: NSPasteboard.Name("AgentImageInputAdapter-\(UUID().uuidString)"))
		pasteboard.clearContents()
		pasteboard.setString("Please attach ![screenshot](\(imageURL.absoluteString)) thanks", forType: .string)

		let prepared = adapter.preparedImages(from: pasteboard)
		XCTAssertEqual(prepared.count, 1)
		XCTAssertEqual(prepared.first?.url.standardizedFileURL, imageURL.standardizedFileURL)
		XCTAssertEqual(prepared.first?.isTemporary, false)
	}

	func testImageInputAdapterExtractsEscapedQuotedImagePathFromPlainTextPasteboard() throws {
		let tempRoot = try makeTemporaryWorkspace(prefix: "AgentImageInputPasteboardEscapedQuoted")
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let adapter = AgentImageInputAdapter(
			fileManager: .default,
			temporaryRoot: tempRoot.appendingPathComponent("tmp-images", isDirectory: true)
		)
		let imageURL = tempRoot.appendingPathComponent("drop image.png")
		try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)
		let escapedPath = imageURL.path.replacingOccurrences(of: " ", with: "\\ ")

		let pasteboard = NSPasteboard(name: NSPasteboard.Name("AgentImageInputAdapter-\(UUID().uuidString)"))
		pasteboard.clearContents()
		pasteboard.setString("Attach \"\(escapedPath)\".", forType: .string)

		let prepared = adapter.preparedImages(from: pasteboard)
		XCTAssertEqual(prepared.count, 1)
		XCTAssertEqual(prepared.first?.url.standardizedFileURL, imageURL.standardizedFileURL)
		XCTAssertEqual(prepared.first?.isTemporary, false)
	}

	func testImageInputAdapterExtractsMarkdownImagePathWithParenthesesInFilename() throws {
		let tempRoot = try makeTemporaryWorkspace(prefix: "AgentImageInputMarkdownParens")
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let adapter = AgentImageInputAdapter(
			fileManager: .default,
			temporaryRoot: tempRoot.appendingPathComponent("tmp-images", isDirectory: true)
		)
		let imageURL = tempRoot.appendingPathComponent("drop image (1).png")
		try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)

		let pasteboard = NSPasteboard(name: NSPasteboard.Name("AgentImageInputAdapter-\(UUID().uuidString)"))
		pasteboard.clearContents()
		pasteboard.setString("Please attach ![shot](\(imageURL.path)) thanks", forType: .string)

		let prepared = adapter.preparedImages(from: pasteboard)
		XCTAssertEqual(prepared.count, 1)
		XCTAssertEqual(prepared.first?.url.standardizedFileURL, imageURL.standardizedFileURL)
		XCTAssertEqual(prepared.first?.isTemporary, false)
	}

	func testImageInputAdapterConsumesStandaloneEscapedMarkdownImagePathWithParentheses() throws {
		let tempRoot = try makeTemporaryWorkspace(prefix: "AgentImageInputMarkdownEscapedParens")
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let adapter = AgentImageInputAdapter(
			fileManager: .default,
			temporaryRoot: tempRoot.appendingPathComponent("tmp-images", isDirectory: true)
		)
		let imageURL = tempRoot.appendingPathComponent("drop image (1).png")
		try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)
		let escapedPath = imageURL.path
			.replacingOccurrences(of: " ", with: "\\ ")
			.replacingOccurrences(of: "(", with: "\\(")
			.replacingOccurrences(of: ")", with: "\\)")

		let pasteboard = NSPasteboard(name: NSPasteboard.Name("AgentImageInputAdapter-\(UUID().uuidString)"))
		pasteboard.clearContents()
		pasteboard.setString("![shot](\(escapedPath))", forType: .string)

		XCTAssertTrue(adapter.shouldConsumePasteAsImageAttachment(from: pasteboard))
		let prepared = adapter.preparedImages(from: pasteboard)
		XCTAssertEqual(prepared.count, 1)
		XCTAssertEqual(prepared.first?.url.standardizedFileURL, imageURL.standardizedFileURL)
		XCTAssertEqual(prepared.first?.isTemporary, false)
	}

	func testImageInputAdapterIgnoresNonexistentPlainTextImagePath() throws {
		let tempRoot = try makeTemporaryWorkspace(prefix: "AgentImageInputPasteboardMissing")
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let adapter = AgentImageInputAdapter(
			fileManager: .default,
			temporaryRoot: tempRoot.appendingPathComponent("tmp-images", isDirectory: true)
		)
		let missingImagePath = tempRoot.appendingPathComponent("missing.png").path

		let pasteboard = NSPasteboard(name: NSPasteboard.Name("AgentImageInputAdapter-\(UUID().uuidString)"))
		pasteboard.clearContents()
		pasteboard.setString("\(missingImagePath)", forType: .string)

		let prepared = adapter.preparedImages(from: pasteboard)
		XCTAssertTrue(prepared.isEmpty)
	}

	func testImageInputAdapterCreatesTemporaryFileFromPasteboardImageData() throws {
		let tempRoot = try makeTemporaryWorkspace(prefix: "AgentImageInputPasteboardData")
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let adapter = AgentImageInputAdapter(
			fileManager: .default,
			temporaryRoot: tempRoot.appendingPathComponent("tmp-images", isDirectory: true)
		)

		let pasteboard = NSPasteboard(name: NSPasteboard.Name("AgentImageInputAdapter-\(UUID().uuidString)"))
		pasteboard.clearContents()
		pasteboard.setData(samplePNGData(), forType: NSPasteboard.PasteboardType(UTType.png.identifier))

		let prepared = adapter.preparedImages(from: pasteboard)
		XCTAssertEqual(prepared.count, 1)
		guard let entry = prepared.first else {
			return XCTFail("Expected one prepared image")
		}
		XCTAssertTrue(entry.isTemporary)
		XCTAssertTrue(FileManager.default.fileExists(atPath: entry.url.path))

		adapter.cleanupTemporaryFiles(prepared)
		XCTAssertFalse(FileManager.default.fileExists(atPath: entry.url.path))
	}

	func testImageInputAdapterFallsBackToAlternateImagePasteboardTypeWhenPreferredDataIsEmpty() throws {
		let tempRoot = try makeTemporaryWorkspace(prefix: "AgentImageInputPasteboardFallback")
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let adapter = AgentImageInputAdapter(
			fileManager: .default,
			temporaryRoot: tempRoot.appendingPathComponent("tmp-images", isDirectory: true)
		)

		let pasteboard = NSPasteboard(name: NSPasteboard.Name("AgentImageInputAdapter-\(UUID().uuidString)"))
		pasteboard.clearContents()
		let item = NSPasteboardItem()
		item.setData(Data(), forType: NSPasteboard.PasteboardType(UTType.png.identifier))
		item.setData(samplePNGData(), forType: NSPasteboard.PasteboardType(UTType.tiff.identifier))
		pasteboard.writeObjects([item])

		XCTAssertTrue(adapter.shouldConsumePasteAsImageAttachment(from: pasteboard))
		let prepared = adapter.preparedImages(from: pasteboard)
		XCTAssertEqual(prepared.count, 1)
		guard let entry = prepared.first else {
			return XCTFail("Expected one prepared image")
		}
		XCTAssertTrue(entry.isTemporary)
		XCTAssertTrue(FileManager.default.fileExists(atPath: entry.url.path))

		adapter.cleanupTemporaryFiles(prepared)
		XCTAssertFalse(FileManager.default.fileExists(atPath: entry.url.path))
	}

	func testImageInputAdapterHandlesPNGPasteboardWithLegacyAliasTypesPresent() throws {
		let tempRoot = try makeTemporaryWorkspace(prefix: "AgentImageInputPasteboardLegacyPNG")
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let adapter = AgentImageInputAdapter(
			fileManager: .default,
			temporaryRoot: tempRoot.appendingPathComponent("tmp-images", isDirectory: true)
		)

		let pasteboard = NSPasteboard(name: NSPasteboard.Name("AgentImageInputAdapter-\(UUID().uuidString)"))
		pasteboard.clearContents()
		pasteboard.setData(samplePNGData(), forType: NSPasteboard.PasteboardType(UTType.png.identifier))

		let types = pasteboard.types?.map(\.rawValue) ?? []
		XCTAssertTrue(types.contains(UTType.png.identifier))
		XCTAssertTrue(types.contains("Apple PNG pasteboard type"))

		XCTAssertTrue(adapter.shouldConsumePasteAsImageAttachment(from: pasteboard))
		let prepared = adapter.preparedImages(from: pasteboard)
		XCTAssertEqual(prepared.count, 1)
		guard let entry = prepared.first else {
			return XCTFail("Expected one prepared image")
		}
		XCTAssertTrue(entry.isTemporary)
		XCTAssertTrue(FileManager.default.fileExists(atPath: entry.url.path))

		adapter.cleanupTemporaryFiles(prepared)
		XCTAssertFalse(FileManager.default.fileExists(atPath: entry.url.path))
	}

	func testImageAwareTextViewReadablePasteboardTypesExcludeImageAliasesWhenImageHandlingDisabled() {
		let textView = ImageAwareTextView(frame: .zero)
		textView.enablesImagePasteHandling = false
		let types = Set(textView.readablePasteboardTypes.map(\.rawValue))

		XCTAssertFalse(types.contains(ImagePasteboardTypes.legacyApplePNG.rawValue))
		XCTAssertFalse(types.contains(ImagePasteboardTypes.legacyNeXTTIFF.rawValue))
	}

	func testImageAwareTextViewReadablePasteboardTypesIncludeImageAliasesWhenImageHandlingEnabled() {
		let textView = ImageAwareTextView(frame: .zero)
		textView.enablesImagePasteHandling = true
		let types = Set(textView.readablePasteboardTypes.map(\.rawValue))

		XCTAssertTrue(types.contains(UTType.image.identifier))
		XCTAssertTrue(types.contains(UTType.png.identifier))
		XCTAssertTrue(types.contains(UTType.tiff.identifier))
		XCTAssertTrue(types.contains(ImagePasteboardTypes.legacyApplePNG.rawValue))
		XCTAssertTrue(types.contains(ImagePasteboardTypes.legacyNeXTTIFF.rawValue))
	}

	func testImageAwareTextViewReadSelectionUsesImagePasteHandlerForImageTypes() throws {
		let textView = ImageAwareTextView(frame: .zero)
		textView.enablesImagePasteHandling = true
		let pasteboard = NSPasteboard(name: NSPasteboard.Name("ImageAwareTextViewReadSelection-\(UUID().uuidString)"))
		pasteboard.clearContents()
		pasteboard.setData(samplePNGData(), forType: NSPasteboard.PasteboardType(UTType.png.identifier))

		var handlerCallCount = 0
		textView.imagePasteHandler = { board in
			handlerCallCount += 1
			return board == pasteboard
		}

		let didConsume = textView.readSelection(from: pasteboard, type: NSPasteboard.PasteboardType(UTType.png.identifier))
		XCTAssertTrue(didConsume)
		XCTAssertEqual(handlerCallCount, 1)
	}

	func testCustomTextFieldCoordinatorPasteCommandUsesLiveTextViewImagePasteHandler() {
		var text = ""
		var currentHeightPresetIndex = 0
		let staleParent = CustomTextField(
			text: Binding(get: { text }, set: { text = $0 }),
			placeholder: "",
			onReturn: { },
			onImagePaste: { _ in false },
			currentHeightPresetIndex: Binding(
				get: { currentHeightPresetIndex },
				set: { currentHeightPresetIndex = $0 }
			),
			onHeightChange: { _ in }
		)
		let coordinator = staleParent.makeCoordinator()
		let textView = ImageAwareTextView(frame: .zero)
		textView.enablesImagePasteHandling = true
		var liveHandlerCalled = false
		textView.imagePasteHandler = { _ in
			liveHandlerCalled = true
			return true
		}

		let consumed = coordinator.textView(textView, doCommandBy: #selector(NSText.paste(_:)))
		XCTAssertTrue(consumed)
		XCTAssertTrue(liveHandlerCalled)
	}

	func testImageInputAdapterLoadsImageDropFromURLsAndRawData() throws {
		let tempRoot = try makeTemporaryWorkspace(prefix: "AgentImageInputDrop")
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let adapter = AgentImageInputAdapter(
			fileManager: .default,
			temporaryRoot: tempRoot.appendingPathComponent("tmp-images", isDirectory: true)
		)
		let imageURL = tempRoot.appendingPathComponent("drop-image.png")
		try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)

		let fileProvider = NSItemProvider(object: imageURL as NSURL)
		let rawProvider = NSItemProvider(item: samplePNGData() as NSData, typeIdentifier: UTType.png.identifier)
		let exp = expectation(description: "drop completion")
		var loaded: [AgentImageInputAdapter.PreparedImage] = []

		let accepted = adapter.loadPreparedImages(from: [fileProvider, rawProvider]) { prepared in
			loaded = prepared
			exp.fulfill()
		}
		XCTAssertTrue(accepted)
		wait(for: [exp], timeout: 2.0)

		XCTAssertTrue(
			loaded.contains(where: {
				$0.url.standardizedFileURL == imageURL.standardizedFileURL && $0.isTemporary == false
			})
		)
		XCTAssertTrue(loaded.contains(where: { $0.isTemporary }))
		let temporaryFiles = loaded.filter(\.isTemporary)
		for entry in temporaryFiles {
			XCTAssertTrue(FileManager.default.fileExists(atPath: entry.url.path))
		}
		adapter.cleanupTemporaryFiles(loaded)
		for entry in temporaryFiles {
			XCTAssertFalse(FileManager.default.fileExists(atPath: entry.url.path))
		}
	}

	func testImageInputAdapterRejectsNonImageDropProviders() {
		let adapter = AgentImageInputAdapter()
		let textProvider = NSItemProvider(item: "hello" as NSString, typeIdentifier: UTType.plainText.identifier)
		let accepted = adapter.loadPreparedImages(from: [textProvider]) { _ in
			XCTFail("Completion should not run for rejected providers")
		}
		XCTAssertFalse(accepted)
	}

	func testParallelCodexTabsKeepIndependentRunAndControllerState() async throws {
		var controllersByTab: [UUID: FakeCodexController] = [:]
		var factoryCallCount = 0
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, tabID, _, _, _, _ in
			factoryCallCount += 1
			if let existing = controllersByTab[tabID] {
				return existing
			}
			let created = FakeCodexController()
			controllersByTab[tabID] = created
			return created
		}

		let tabA = UUID()
		let tabB = UUID()
		for tabID in [tabA, tabB] {
			let session = await vm.ensureSessionReady(tabID: tabID)
			session.selectedAgent = .codexExec
		}

		await vm.startAgentRun(tabID: tabA, initialMessage: "tab-a first")
		await vm.startAgentRun(tabID: tabB, initialMessage: "tab-b first")

		let controllersReady = await waitForCondition(timeoutSeconds: 2.0) {
			factoryCallCount == 2 && controllersByTab[tabA] != nil && controllersByTab[tabB] != nil
		}
		XCTAssertTrue(controllersReady, "Expected each tab to create a Codex controller")

		guard
			let sessionA = vm.sessions[tabA],
			let sessionB = vm.sessions[tabB],
			let runIDA = sessionA.runID,
			let runIDB = sessionB.runID
		else {
			return XCTFail("Expected session run IDs for both tabs")
		}

		XCTAssertNotEqual(runIDA, runIDB, "Parallel tabs must not share run IDs")
		XCTAssertEqual(factoryCallCount, 2, "Each tab should get its own controller instance")

		guard
			let controllerA = controllersByTab[tabA],
			let controllerB = controllersByTab[tabB]
		else {
			return XCTFail("Expected controllers for both tabs")
		}

		XCTAssertEqual(controllerA.startOrResumeCallCount, 1)
		XCTAssertEqual(controllerA.sendUserMessageCallCount, 1)
		XCTAssertEqual(controllerB.startOrResumeCallCount, 1)
		XCTAssertEqual(controllerB.sendUserMessageCallCount, 1)

		await vm.startAgentRun(tabID: tabA, initialMessage: "tab-a second")

		XCTAssertEqual(controllerA.startOrResumeCallCount, 1, "Existing tab thread should be reused")
		XCTAssertEqual(controllerA.sendUserMessageCallCount, 2)
		XCTAssertEqual(controllerB.startOrResumeCallCount, 1, "Tab B must be unaffected by tab A activity")
		XCTAssertEqual(controllerB.sendUserMessageCallCount, 1)
	}

	func testCoordinatorStaggeredRunsRouteToolEventsToCorrectRunIDs() async throws {
		let tabA = UUID()
		let tabB = UUID()
		let windowID = 1
		let codexClientName = DiscoverAgentKind.codexExec.mcpClientNameHint ?? "codex-mcp-client"

		let trackerA = AgentToolTracker()
		let trackerB = AgentToolTracker()
		let historyA = ToolRoutingState()
		let historyB = ToolRoutingState()
		let runAToolCompleted = expectation(description: "run A get_file_tree completion")
		let runBToolCompleted = expectation(description: "run B manage_selection completion")
		runAToolCompleted.assertForOverFulfill = false
		runBToolCompleted.assertForOverFulfill = false

		let runIDLock = NSLock()
		var actualRunIDsByTabID: [UUID: UUID] = [:]
		var trackedRunIDs: Set<UUID> = []
		func registerTrackerIfNeeded(for tabID: UUID, runID: UUID) async {
			let tracker: AgentToolTracker
			let history: ToolRoutingState
			let expectedToolName: String
			let completedExpectation: XCTestExpectation
			switch tabID {
			case tabA:
				tracker = trackerA
				history = historyA
				expectedToolName = "get_file_tree"
				completedExpectation = runAToolCompleted
			case tabB:
				tracker = trackerB
				history = historyB
				expectedToolName = "manage_selection"
				completedExpectation = runBToolCompleted
			default:
				return
			}

			let shouldStartTracker: Bool = {
				runIDLock.lock()
				defer { runIDLock.unlock() }
				actualRunIDsByTabID[tabID] = runID
				return trackedRunIDs.insert(runID).inserted
			}()
			guard shouldStartTracker else { return }

			await tracker.startEnhanced(
				runID: runID,
				clientNameHint: codexClientName,
				connectionTimeoutSeconds: 0,
				fallbackTimeoutSeconds: 0,
				keepObserversOnTimeout: true,
				onCalled: { _, _, _ in },
				onCompleted: { invocationID, toolName, _, _, isError in
					let normalizedToolName = toolName.hasPrefix("mcp__RepoPrompt__")
						? String(toolName.dropFirst("mcp__RepoPrompt__".count))
						: toolName
					Task {
						let isNew = await history.recordCompleted(
							invocationID: invocationID,
							toolName: normalizedToolName,
							isError: isError
						)
						if isNew, normalizedToolName == expectedToolName {
							completedExpectation.fulfill()
						}
					}
				}
			)
		}

		var policyCalls: [CodexPolicyInstallCall] = []
		let vm = AgentModeViewModel(
			testWindowID: windowID,
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
					clientShutdownBehavior: .stopOnShutdown,
					expectedMCPClientName: DiscoverAgentKind.codexExec.mcpClientNameHint
				)
			},
			connectionPolicyInstaller: { clientName, policyWindowID, restrictedTools, oneShot, reason, ttl, policyTabID, policyRunID, additionalTools, purpose, taskLabelKind, allowsAgentExternalControlTools, requiresExpectedAgentPID in
				policyCalls.append(
					CodexPolicyInstallCall(
						clientName: clientName,
						windowID: policyWindowID,
						restrictedTools: restrictedTools,
						oneShot: oneShot,
						reason: reason,
						ttl: ttl,
						tabID: policyTabID,
						runID: policyRunID,
						additionalTools: additionalTools,
						purpose: purpose,
						requiresExpectedAgentPID: requiresExpectedAgentPID
					)
				)
				if let policyTabID, let policyRunID {
					await registerTrackerIfNeeded(for: policyTabID, runID: policyRunID)
				}
				await ServerNetworkManager.shared.installClientConnectionPolicy(
					for: clientName,
					windowID: policyWindowID,
					restrictedTools: restrictedTools,
					oneShot: oneShot,
					reason: reason,
					ttl: ttl,
					tabID: policyTabID,
					runID: policyRunID,
					additionalTools: additionalTools,
					purpose: purpose,
					taskLabelKind: taskLabelKind,
					allowsAgentExternalControlTools: allowsAgentExternalControlTools,
					requiresExpectedAgentPID: requiresExpectedAgentPID
				)
			}
		)

		let sessionA = await vm.ensureSessionReady(tabID: tabA)
		sessionA.selectedAgent = DiscoverAgentKind.codexExec

		let sessionB = await vm.ensureSessionReady(tabID: tabB)
		sessionB.selectedAgent = DiscoverAgentKind.codexExec

		let runAStartedAt = Date()
		await vm.startAgentRun(
			tabID: tabA,
			initialMessage: "Call get_file_tree exactly once with type=files and mode=folders, then reply with 'run-a done'. Do not call any other tools."
		)
		try await Task.sleep(nanoseconds: 1_000_000_000)
		XCTAssertLessThan(Date().timeIntervalSince(runAStartedAt), 15.0, "Second run should begin within policy TTL")
		await vm.startAgentRun(
			tabID: tabB,
			initialMessage: "Call manage_selection exactly once with op=get and view=files, then reply with 'run-b done'. Do not call any other tools."
		)

		await fulfillment(of: [runAToolCompleted, runBToolCompleted], timeout: 120)

		let didAssignRunIDs = await waitForCondition(timeoutSeconds: 2.0) {
			sessionA.runID != nil && sessionB.runID != nil
		}
		XCTAssertTrue(didAssignRunIDs, "Expected both staggered runs to mint live run IDs")
		let runIDA = try XCTUnwrap(sessionA.runID)
		let runIDB = try XCTUnwrap(sessionB.runID)
		XCTAssertNotEqual(runIDA, runIDB, "Parallel tabs must not share run IDs")
		let observedRunIDsByTabID: [UUID: UUID] = {
			runIDLock.lock()
			defer { runIDLock.unlock() }
			return actualRunIDsByTabID
		}()
		XCTAssertEqual(observedRunIDsByTabID[tabA], Optional(runIDA))
		XCTAssertEqual(observedRunIDsByTabID[tabB], Optional(runIDB))

		let snapshotA = await historyA.snapshot()
		let snapshotB = await historyB.snapshot()
		XCTAssertGreaterThanOrEqual(snapshotA["get_file_tree", default: 0], 1)
		XCTAssertEqual(snapshotA["manage_selection", default: 0], 0)
		XCTAssertEqual(snapshotA["bind_context", default: 0], 0)
		XCTAssertGreaterThanOrEqual(snapshotB["manage_selection", default: 0], 1)
		XCTAssertEqual(snapshotB["get_file_tree", default: 0], 0)
		XCTAssertEqual(snapshotB["bind_context", default: 0], 0)

		let runAPolicyCalls = policyCalls.filter { $0.tabID == tabA && $0.runID == runIDA }
		let runBPolicyCalls = policyCalls.filter { $0.tabID == tabB && $0.runID == runIDB }
		XCTAssertFalse(runAPolicyCalls.isEmpty, "Expected policy install for run A")
		XCTAssertFalse(runBPolicyCalls.isEmpty, "Expected policy install for run B")
		for call in policyCalls {
			XCTAssertEqual(call.clientName, codexClientName)
			XCTAssertEqual(call.windowID, windowID)
			XCTAssertEqual(call.restrictedTools, AgentModeMCPToolPolicy.restrictedTools)
			XCTAssertTrue(call.oneShot)
			XCTAssertEqual(call.reason, "agent-mode-run")
			XCTAssertEqual(call.ttl, AgentModeMCPPolicyInstaller.policyTTL, accuracy: 0.001)
			XCTAssertEqual(call.additionalTools, AgentModeMCPToolPolicy.codexNativeGrantedTools)
			XCTAssertEqual(call.purpose, .agentModeRun)
			XCTAssertTrue(call.requiresExpectedAgentPID)
		}

		await vm.cancelAgentRun(tabID: tabA)
		await vm.cancelAgentRun(tabID: tabB)
		await vm.deleteSession(tabID: tabA)
		await vm.deleteSession(tabID: tabB)
		await trackerA.stop()
		await trackerB.stop()
		await ServerNetworkManager.shared.clearClientConnectionPolicy(for: codexClientName, windowID: windowID)
	}

	func testEnsureSessionReadyDoesNotWarmCodexForIdleSessionHistory() async {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		vm.storeDraftText(for: tabID, "seed")
		session.selectedAgent = .codexExec
		session.hasSentFirstMessage = true
		session.runState = .idle

		_ = await vm.ensureSessionReady(tabID: tabID)

		XCTAssertEqual(fakeController.startOrResumeCallCount, 0, "Idle restored sessions should not warm Codex until user input is non-empty")
	}

	func testCodexNativeToolEventsRenderBashAndSearchAndUseRepoPromptFallbackWithoutDuplicatesAcrossInvocationIDMismatch() async {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec

		await vm.startAgentRun(tabID: tabID, initialMessage: "trigger")
		let repoPromptNativeInvocationID = UUID()
		let repoPromptTrackerInvocationID = UUID()
		let repoPromptArgs: [String: Value] = [
			"encoding": .string("utf8"),
			"path": .string("README.md")
		]
		let repoPromptResultJSON = #"{"path":"README.md","content":"hello"}"#
		fakeController.emit(.toolCall(name: "bash", invocationID: nil, argsJSON: #"{"command":"pwd"}"#))
		fakeController.emit(.toolResult(name: "bash", invocationID: nil, argsJSON: #"{"command":"pwd"}"#, resultJSON: "/tmp/repo\n", isError: false))
		fakeController.emit(.toolCall(name: "search", invocationID: nil, argsJSON: #"{"query":"swift mcp"}"#))
		fakeController.emit(.toolCall(name: "mcp__RepoPrompt__read_file", invocationID: repoPromptNativeInvocationID, argsJSON: #"{"path":"README.md","encoding":"utf8"}"#))
		vm.testSimulateCodexRepoPromptToolCall(
			tabID: tabID,
			invocationID: repoPromptTrackerInvocationID,
			toolName: "mcp__RepoPrompt__read_file",
			args: repoPromptArgs
		)
		fakeController.emit(.toolResult(name: "mcp__RepoPrompt__read_file", invocationID: repoPromptNativeInvocationID, argsJSON: #"{ "encoding" : "utf8", "path" : "README.md" }"#, resultJSON: repoPromptResultJSON, isError: false))
		vm.testSimulateCodexRepoPromptToolResult(
			tabID: tabID,
			invocationID: repoPromptTrackerInvocationID,
			toolName: "mcp__RepoPrompt__read_file",
			args: repoPromptArgs,
			resultJSON: repoPromptResultJSON,
			isError: false
		)

		let observed = await waitForCondition(timeoutSeconds: 2.0) {
			session.items.contains(where: { $0.kind == .toolResult && $0.toolName == "bash" })
				&& session.items.contains(where: { $0.kind == .toolCall && $0.toolName == "search" })
				&& session.items.contains(where: {
					$0.kind == .toolResult
						&& $0.toolInvocationID == repoPromptTrackerInvocationID
						&& $0.toolName == "mcp__RepoPrompt__read_file"
						&& $0.toolResultJSON == repoPromptResultJSON
				})
		}
		XCTAssertTrue(observed, "Expected bash/search native tool events and tracker-owned RepoPrompt tool events to render in transcript")
		XCTAssertEqual(
			session.items.filter {
				$0.toolName == "mcp__RepoPrompt__read_file"
			}.count,
			1,
			"RepoPrompt native fallback and tracker callbacks should coalesce into one tool card"
		)
	}

	func testCodexTrackerRichRepoPromptResultOutranksLaterNativeFallbackPayload() async {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec

		await vm.startAgentRun(tabID: tabID, initialMessage: "trigger")
		let nativeInvocationID = UUID()
		let trackerInvocationID = UUID()
		let repoPromptArgs: [String: Value] = [
			"path": .string("AgentModeView.swift")
		]
		let richResultJSON = #"{"status":"success","edits_requested":1,"edits_applied":1,"card_unified_diff":"@@ -1 +1 @@\n-old\n+new","unified_diff":"@@ -1 +1 @@\n-old\n+new"}"#
		let nativeFallbackJSON = #"{"status":"completed","note":"native fallback payload"}"#

		fakeController.emit(.toolCall(name: "mcp__RepoPrompt__apply_edits", invocationID: nativeInvocationID, argsJSON: #"{"path":"AgentModeView.swift"}"#))
		vm.testSimulateCodexRepoPromptToolCall(
			tabID: tabID,
			invocationID: trackerInvocationID,
			toolName: "mcp__RepoPrompt__apply_edits",
			args: repoPromptArgs
		)
		vm.testSimulateCodexRepoPromptToolResult(
			tabID: tabID,
			invocationID: trackerInvocationID,
			toolName: "mcp__RepoPrompt__apply_edits",
			args: repoPromptArgs,
			resultJSON: richResultJSON,
			isError: false
		)
		fakeController.emit(.toolResult(name: "mcp__RepoPrompt__apply_edits", invocationID: nativeInvocationID, argsJSON: #"{"path":"AgentModeView.swift"}"#, resultJSON: nativeFallbackJSON, isError: false))

		let observed = await waitForCondition(timeoutSeconds: 2.0) {
			guard let item = session.items.first(where: {
				$0.kind == .toolResult && normalizedToolCardName($0.toolName) == "apply_edits"
			}) else {
				return false
			}
			guard let dto = ToolJSON.decode(ToolResultDTOs.EditSummary.self, from: item.toolResultJSON) else {
				return false
			}
			return dto.editsRequested == 1
				&& dto.editsApplied == 1
				&& dto.cardUnifiedDiff?.contains("+new") == true
				&& item.toolInvocationID == trackerInvocationID
		}

		XCTAssertTrue(observed, "Expected tracker EditSummary payload to survive a later native fallback result")
		XCTAssertEqual(
			session.items.filter {
				normalizedToolCardName($0.toolName) == "apply_edits"
			}.count,
			1,
			"Tracker/native apply_edits events should still coalesce into one tool card"
		)
	}

	func testWriteStdinResultReconcilesLinkedBashLaunchToRunning() async {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec

		await vm.startAgentRun(tabID: tabID, initialMessage: "trigger")
		let bashResultJSON = """
		{
		  "type": "commandExecution",
		  "status": "failed",
		  "exitCode": 1,
		  "processId": "59802",
		  "command": "npm start"
		}
		"""
		fakeController.emit(.toolResult(
			name: "bash",
			invocationID: nil,
			argsJSON: #"{"command":"npm start"}"#,
			resultJSON: bashResultJSON,
			isError: true
		))

		_ = await waitForCondition(timeoutSeconds: 2.0) {
			session.items.contains(where: { $0.toolName == "bash" && $0.toolIsError == true })
		}

		fakeController.emit(.toolResult(
			name: "functions.write_stdin",
			invocationID: nil,
			argsJSON: #"{"session_id":59802,"chars":"","yield_time_ms":1000}"#,
			resultJSON: #"{"status":"running"}"#,
			isError: false
		))

		let reconciled = await waitForCondition(timeoutSeconds: 2.0) {
			session.items.contains(where: { item in
				guard item.toolName == "bash" else { return false }
				guard item.toolIsError == false else { return false }
				guard let json = item.toolResultJSON else { return false }
				return json.contains(#""status":"running""#) && !json.contains(#""exitCode":1"#)
			})
		}
		XCTAssertTrue(reconciled, "Expected structured write_stdin running result to reconcile linked bash launch")
	}

	func testCommandExecutionRunningEventReconcilesLinkedBashLaunchToRunning() async {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec

		await vm.startAgentRun(tabID: tabID, initialMessage: "trigger")
		let bashResultJSON = """
		{
		  "type": "commandExecution",
		  "status": "failed",
		  "exitCode": 1,
		  "processId": "27588",
		  "command": "npm start"
		}
		"""
		fakeController.emit(.toolResult(
			name: "bash",
			invocationID: nil,
			argsJSON: #"{"command":"npm start"}"#,
			resultJSON: bashResultJSON,
			isError: true
		))

		fakeController.emit(.commandExecutionRunning(
			.init(invocationID: nil, processID: "27588", appendedOutput: "ready\n")
		))

		let reconciled = await waitForCondition(timeoutSeconds: 2.0) {
			session.items.contains(where: { item in
				guard item.toolName == "bash" else { return false }
				guard item.toolIsError == false else { return false }
				guard let json = item.toolResultJSON else { return false }
				return json.contains(#""status":"running""#)
					&& json.contains(#""aggregatedOutput":"ready\n""#)
			})
		}
		XCTAssertTrue(reconciled, "Expected native command running event to reconcile linked bash launch")
	}

	func testWriteStdinTextOutputDoesNotReconcileLinkedBashLaunch() async {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec

		await vm.startAgentRun(tabID: tabID, initialMessage: "trigger")
		let bashResultJSON = """
		{
		  "type": "commandExecution",
		  "status": "failed",
		  "exitCode": 1,
		  "processId": "27588",
		  "command": "npm start"
		}
		"""
		fakeController.emit(.toolResult(
			name: "bash",
			invocationID: nil,
			argsJSON: #"{"command":"npm start"}"#,
			resultJSON: bashResultJSON,
			isError: true
		))

		fakeController.emit(.toolResult(
			name: "functions.write_stdin",
			invocationID: nil,
			argsJSON: #"{"session_id":27588,"chars":"","yield_time_ms":1000}"#,
			resultJSON: "Process running with session ID 27588",
			isError: nil
		))

		try? await Task.sleep(nanoseconds: 250_000_000)
		let remainsFailed = session.items.contains(where: { item in
			guard item.toolName == "bash" else { return false }
			return item.toolIsError == true
		})
		XCTAssertTrue(remainsFailed, "Unstructured write_stdin text output should not drive reconciliation")
	}

	func testWriteStdinFailedOutputDoesNotReconcileLinkedBashLaunch() async {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec

		await vm.startAgentRun(tabID: tabID, initialMessage: "trigger")
		let bashResultJSON = """
		{
		  "type": "commandExecution",
		  "status": "failed",
		  "exitCode": 1,
		  "processId": "59802",
		  "command": "npm start"
		}
		"""
		fakeController.emit(.toolResult(
			name: "bash",
			invocationID: nil,
			argsJSON: #"{"command":"npm start"}"#,
			resultJSON: bashResultJSON,
			isError: true
		))

		fakeController.emit(.toolResult(
			name: "functions.write_stdin",
			invocationID: nil,
			argsJSON: #"{"session_id":59802,"chars":"","yield_time_ms":1000}"#,
			resultJSON: "write_stdin failed: Unknown process id 59802",
			isError: nil
		))

		try? await Task.sleep(nanoseconds: 250_000_000)
		let remainsFailed = session.items.contains(where: { item in
			guard item.toolName == "bash" else { return false }
			return item.toolIsError == true
		})
		XCTAssertTrue(remainsFailed, "Failed write_stdin output should not flip linked bash launch to success")
	}

	func testTurnCompletionFinalizesPendingCodexToolCallsWithoutResult() async {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec

		await vm.startAgentRun(tabID: tabID, initialMessage: "trigger")
		fakeController.emit(.toolCall(name: "search", invocationID: nil, argsJSON: #"{"query":"swift"}"#))

		let sawToolCall = await waitForCondition(timeoutSeconds: 2.0) {
			session.items.contains(where: { $0.kind == .toolCall && $0.toolName == "search" })
		}
		XCTAssertTrue(sawToolCall, "Expected pending search tool call before turn completion")

		fakeController.emit(.turnCompleted(turnID: nil, status: .completed))
		let finalized = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .completed
				&& session.items.contains(where: {
					$0.kind == .toolResult
						&& $0.toolName == "search"
						&& ($0.toolResultJSON?.contains("No tool result payload was received before the turn ended.") == true)
				})
				&& !session.items.contains(where: { $0.kind == .toolCall && $0.toolName == "search" })
		}
		XCTAssertTrue(finalized, "Expected pending tool call to be closed on turn completion")
	}

	func testTurnCompletionLeavesExplicitRepoPromptToolCallsPendingUntilTrackerResultArrives() async {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}

		let tabID = UUID()
		let invocationID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec

		await vm.startAgentRun(tabID: tabID, initialMessage: "trigger")
		vm.testSimulateCodexRepoPromptToolCall(
			tabID: tabID,
			invocationID: invocationID,
			toolName: "mcp__RepoPrompt__ask_user",
			args: ["question": .string("What should I compare against?")]
		)

		let sawToolCall = await waitForCondition(timeoutSeconds: 2.0) {
			session.items.contains(where: {
				$0.kind == .toolCall
					&& $0.toolInvocationID == invocationID
					&& $0.toolName == "mcp__RepoPrompt__ask_user"
			})
		}
		XCTAssertTrue(sawToolCall, "Expected explicit RepoPrompt tool call before turn completion")

		fakeController.emit(.turnCompleted(turnID: nil, status: .completed))
		let remainedPending = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .completed
				&& session.items.contains(where: {
					$0.kind == .toolCall
						&& $0.toolInvocationID == invocationID
						&& $0.toolName == "mcp__RepoPrompt__ask_user"
				})
				&& !session.items.contains(where: {
					$0.toolInvocationID == invocationID
						&& ($0.toolResultJSON?.contains("No tool result payload was received before the turn ended.") == true)
				})
		}
		XCTAssertTrue(remainedPending, "Turn completion should not synthesize fallback results for explicit RepoPrompt tools")

		let answeredJSON = #"{"response":"main","skipped":false,"timed_out":false,"elapsed_seconds":1}"#
		vm.testSimulateCodexRepoPromptToolResult(
			tabID: tabID,
			invocationID: invocationID,
			toolName: "mcp__RepoPrompt__ask_user",
			args: ["question": .string("What should I compare against?")],
			resultJSON: answeredJSON,
			isError: false
		)

		let appliedLateResult = await waitForCondition(timeoutSeconds: 2.0) {
			session.items.contains(where: {
				$0.kind == .toolResult
					&& $0.toolInvocationID == invocationID
					&& $0.toolName == "mcp__RepoPrompt__ask_user"
					&& $0.toolResultJSON == answeredJSON
			})
		}
		XCTAssertTrue(appliedLateResult, "Late tracker results should still replace explicit RepoPrompt tool calls after turn completion")
	}

	func testCodexFinalizerClosesExplicitAgentControlButLeavesOtherExplicitRepoPromptToolsPending() async {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}

		let tabID = UUID()
		let agentRunInvocationID = UUID()
		let readFileInvocationID = UUID()
		let childSessionID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.setItemsSilently([
			.user("control child", sequenceIndex: 0),
			.toolCall(
				name: "mcp__RepoPrompt__agent_run",
				invocationID: agentRunInvocationID,
				argsJSON: "{\"op\":\"steer\",\"session_id\":\"\(childSessionID.uuidString)\",\"message\":\"ask for Toronto weather\"}",
				sequenceIndex: 1
			),
			.toolCall(
				name: "mcp__RepoPrompt__read_file",
				invocationID: readFileInvocationID,
				argsJSON: "{\"path\":\"README.md\"}",
				sequenceIndex: 2
			)
		], reason: .testOverride)

		vm.test_codexCoordinator.testFinalizePendingToolCalls(in: session, turnStatus: .completed)

		guard let agentRunResult = session.items.first(where: { $0.toolInvocationID == agentRunInvocationID }) else {
			XCTFail("Expected agent_run item to remain present")
			return
		}
		XCTAssertEqual(agentRunResult.kind, .toolResult)
		XCTAssertEqual(agentRunResult.toolIsError, false)
		let agentRunObject = agentRunResult.toolResultJSON.flatMap { AgentTranscriptToolNormalizer.jsonObject(from: $0) }
		XCTAssertEqual(agentRunObject?["status"] as? String, "completed")
		XCTAssertEqual(agentRunObject?["reason"] as? String, "result_missing_after_turn_completed")

		guard let readFileCall = session.items.first(where: { $0.toolInvocationID == readFileInvocationID }) else {
			XCTFail("Expected read_file item to remain present")
			return
		}
		XCTAssertEqual(readFileCall.kind, .toolCall)
		XCTAssertNil(readFileCall.toolResultJSON)
	}

	func testTurnCompletionFinalizesLingeringRunningBashResult() async {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec

		await vm.startAgentRun(tabID: tabID, initialMessage: "trigger")
		fakeController.emit(.toolCall(name: "functions.bash", invocationID: nil, argsJSON: #"{"command":"sleep 300"}"#))

		let sawRunning = await waitForCondition(timeoutSeconds: 2.0) {
			session.items.contains(where: { item in
				guard item.toolName == "functions.bash" else { return false }
				guard item.kind == .toolResult else { return false }
				let parsed = BashToolResultParser.parse(raw: item.toolResultJSON, argsJSON: item.toolArgsJSON)
				return parsed.isRunning
			})
		}
		XCTAssertTrue(sawRunning, "Expected bash tool call to render as running result card")

		fakeController.emit(.turnCompleted(turnID: nil, status: .completed))
		let finalized = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .completed
				&& session.items.contains(where: { item in
					guard item.toolName == "functions.bash" else { return false }
					guard item.kind == .toolResult else { return false }
					let parsed = BashToolResultParser.parse(raw: item.toolResultJSON, argsJSON: item.toolArgsJSON)
					return parsed.isRunning == false
						&& parsed.exitCode == 0
						&& parsed.statusWord == "completed"
				})
		}
		XCTAssertTrue(finalized, "Expected lingering running bash item to be finalized on turn completion")
	}

	func testLateCommandExecutionRunningAfterTurnCompletionIsIgnored() async {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec

		await vm.startAgentRun(tabID: tabID, initialMessage: "trigger")
		fakeController.emit(.toolCall(name: "functions.bash", invocationID: nil, argsJSON: #"{"command":"sleep 300"}"#))

		let sawRunning = await waitForCondition(timeoutSeconds: 2.0) {
			session.items.contains(where: { item in
				guard item.toolName == "functions.bash" else { return false }
				guard item.kind == .toolResult else { return false }
				return BashToolResultParser.parse(raw: item.toolResultJSON, argsJSON: item.toolArgsJSON).isRunning
			})
		}
		XCTAssertTrue(sawRunning)

		fakeController.emit(.turnCompleted(turnID: nil, status: .completed))
		let finalized = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .completed
				&& session.items.contains(where: { item in
					guard item.toolName == "functions.bash" else { return false }
					let parsed = BashToolResultParser.parse(raw: item.toolResultJSON, argsJSON: item.toolArgsJSON)
					return parsed.isRunning == false && parsed.statusWord == "completed"
				})
		}
		XCTAssertTrue(finalized)
		let beforeLateDelta = session.items.first(where: { $0.toolName == "functions.bash" })?.toolResultJSON

		fakeController.emit(.commandExecutionRunning(.init(invocationID: nil, processID: nil, appendedOutput: "late output\n")))
		try? await Task.sleep(nanoseconds: 300_000_000)

		let bashItem = session.items.first(where: { $0.toolName == "functions.bash" })
		let parsed = BashToolResultParser.parse(raw: bashItem?.toolResultJSON, argsJSON: bashItem?.toolArgsJSON)
		XCTAssertFalse(parsed.isRunning)
		XCTAssertEqual(parsed.statusWord, "completed")
		XCTAssertEqual(bashItem?.toolResultJSON, beforeLateDelta)
	}

	func testCompletedBashToolResultDoesNotReconcileBackToRunning() async {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec

		await vm.startAgentRun(tabID: tabID, initialMessage: "trigger")
		let completedResult = """
		{
		  "type": "commandExecution",
		  "status": "completed",
		  "processId": "39006",
		  "command": "lsof -nP -iTCP:3000 -sTCP:LISTEN || true"
		}
		"""
		fakeController.emit(
			.toolResult(
				name: "bash",
				invocationID: nil,
				argsJSON: #"{"command":"lsof -nP -iTCP:3000 -sTCP:LISTEN || true"}"#,
				resultJSON: completedResult,
				isError: false
			)
		)

		let remainedCompleted = await waitForCondition(timeoutSeconds: 2.0) {
			session.items.contains(where: { item in
				guard item.toolName == "bash" else { return false }
				let parsed = BashToolResultParser.parse(raw: item.toolResultJSON, argsJSON: item.toolArgsJSON)
				return parsed.isRunning == false
					&& parsed.statusWord == "completed"
			})
		}
		XCTAssertTrue(remainedCompleted, "Completed bash tool result should not be rewritten to running")
	}

	func testBashToolResultWithoutInvocationIDUpdatesExistingRunningCard() async {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec

		await vm.startAgentRun(tabID: tabID, initialMessage: "trigger")
		let argsJSON = #"{"command":"lsof -nP -iTCP:3000 -sTCP:LISTEN || true"}"#
		fakeController.emit(.toolCall(name: "functions.bash", invocationID: nil, argsJSON: argsJSON))

		let runningInserted = await waitForCondition(timeoutSeconds: 2.0) {
			session.items.contains(where: { item in
				guard item.toolName == "functions.bash" else { return false }
				guard item.kind == .toolResult else { return false }
				return BashToolResultParser.parse(raw: item.toolResultJSON, argsJSON: item.toolArgsJSON).isRunning
			})
		}
		XCTAssertTrue(runningInserted, "Expected running bash card after tool call")

		let completedResult = """
		{
		  "type": "commandExecution",
		  "status": "completed",
		  "exitCode": 0,
		  "command": "lsof -nP -iTCP:3000 -sTCP:LISTEN || true"
		}
		"""
		fakeController.emit(
			.toolResult(
				name: "functions.bash",
				invocationID: nil,
				argsJSON: argsJSON,
				resultJSON: completedResult,
				isError: false
			)
		)

		let updatedInPlace = await waitForCondition(timeoutSeconds: 2.0) {
			let bashItems = session.items.filter { $0.toolName == "functions.bash" }
			guard bashItems.count == 1, let item = bashItems.first else { return false }
			let parsed = BashToolResultParser.parse(raw: item.toolResultJSON, argsJSON: item.toolArgsJSON)
			return parsed.isRunning == false && parsed.exitCode == 0 && parsed.statusWord == "completed"
		}
		XCTAssertTrue(updatedInPlace, "Expected completion to update existing running bash card (not append a second card)")
	}

	func testBashApprovalRequestShowsPendingApprovalCardState() async {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec

		await vm.startAgentRun(tabID: tabID, initialMessage: "trigger")
		let approval = AgentApprovalRequest(
			requestID: .codex(.string("approval-1")),
			method: "item/commandExecution/requestApproval",
			kind: .commandExecution,
			threadID: "test-thread",
			turnID: "turn-1",
			itemID: "call_abc",
			reason: "Command requires escalation",
			command: "/bin/zsh -lc 'pwd; echo EXIT:$?'",
			cwd: "/Users/example/Documents/Git/BombSquad",
			details: [
				AgentApprovalDetail(label: "Command", value: "/bin/zsh -lc 'pwd; echo EXIT:$?'", isCode: true)
			]
		)
		fakeController.emit(.approvalRequest(approval))

		let observed = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .waitingForApproval
				&& session.pendingApproval?.command == "/bin/zsh -lc 'pwd; echo EXIT:$?'"
				&& session.pendingApproval?.kind == .commandExecution
		}
		XCTAssertTrue(observed, "Expected bash approval request to move session into waiting-for-approval state")
	}

	func testSubmittingBashApprovalDecisionRespondsToController() async {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec

		await vm.startAgentRun(tabID: tabID, initialMessage: "trigger")
		let approval = AgentApprovalRequest(
			requestID: .codex(.int(42)),
			method: "item/commandExecution/requestApproval",
			kind: .commandExecution,
			threadID: "test-thread",
			turnID: "turn-9",
			itemID: "call_99",
			command: "pwd",
			cwd: "/Users/example/Documents/Git/BombSquad"
		)
		fakeController.emit(.approvalRequest(approval))
		_ = await waitForCondition(timeoutSeconds: 2.0) {
			session.pendingApproval?.requestID == .codex(.int(42))
		}

		vm.submitApprovalDecision(tabID: tabID, decision: .accept)
		let responded = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.respondToServerRequestCallCount == 1
		}
			XCTAssertTrue(responded, "Expected approval decision to be sent to Codex controller")
			XCTAssertNil(session.pendingApproval)
			XCTAssertEqual(session.runState, .running)
			XCTAssertEqual(fakeController.lastRespondedRequestID, .int(42))
			XCTAssertEqual(fakeController.lastRespondedResult["decision"] as? String, "accept")
			XCTAssertNil(fakeController.lastRespondedResult["threadId"])
			XCTAssertNil(fakeController.lastRespondedResult["turnId"])
			XCTAssertNil(fakeController.lastRespondedResult["itemId"])
			XCTAssertEqual(fakeController.lastRespondedResult.count, 1)
		}

	func testSubmittingBashApprovalDecisionAcceptForSessionMapsToAcceptForSession() async {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec

		await vm.startAgentRun(tabID: tabID, initialMessage: "trigger")
		let approval = AgentApprovalRequest(
			requestID: .codex(.string("req-accept-for-session")),
			method: "item/commandExecution/requestApproval",
			kind: .commandExecution,
			threadID: "test-thread",
			turnID: "turn-1",
			itemID: "call_1",
			command: "pwd"
		)
		fakeController.emit(.approvalRequest(approval))
		_ = await waitForCondition(timeoutSeconds: 2.0) {
			session.pendingApproval?.requestID == .codex(.string("req-accept-for-session"))
		}

		vm.submitApprovalDecision(tabID: tabID, decision: .acceptForSession)
		let responded = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.respondToServerRequestCallCount == 1
		}

		XCTAssertTrue(responded, "Expected approval decision to be sent to Codex controller")
		XCTAssertEqual(fakeController.lastRespondedRequestID, .string("req-accept-for-session"))
		XCTAssertEqual(fakeController.lastRespondedResult["decision"] as? String, "acceptForSession")
		XCTAssertEqual(fakeController.lastRespondedResult.count, 1)
	}

	func testSubmittingBashApprovalDecisionExecpolicyAmendmentMapsToStructuredDecision() async throws {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec

		await vm.startAgentRun(tabID: tabID, initialMessage: "trigger")
		let sessionID = try XCTUnwrap(session.activeAgentSessionID)
		await vm.mcpActivateControlContext(forTabID: tabID, sessionID: sessionID, originatingConnectionID: nil)
		let approval = AgentApprovalRequest(
			requestID: .codex(.string("req-amend")),
			method: "item/commandExecution/requestApproval",
			kind: .commandExecution,
			threadID: "test-thread",
			turnID: "turn-2",
			itemID: "call_2",
			command: "pwd"
		)
		fakeController.emit(.approvalRequest(approval))
		_ = await waitForCondition(timeoutSeconds: 2.0) {
			session.pendingApproval?.requestID == .codex(.string("req-amend"))
		}

		let optionLabels = try XCTUnwrap(vm.mcpSnapshot(sessionID: sessionID)?.interaction?.options.map(\.label))
		XCTAssertTrue(optionLabels.contains("accept_with_amendment"))

		vm.submitApprovalDecision(
			tabID: tabID,
			decision: .acceptWithExecpolicyAmendment(#"{"allow":["pwd"]}"#)
		)
		let responded = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.respondToServerRequestCallCount == 1
		}

		XCTAssertTrue(responded, "Expected approval decision to be sent to Codex controller")
		XCTAssertEqual(fakeController.lastRespondedRequestID, .string("req-amend"))
		let decision = fakeController.lastRespondedResult["decision"] as? [String: Any]
		let amendmentDecision = decision?["acceptWithExecpolicyAmendment"] as? [String: Any]
		let amendment = amendmentDecision?["execpolicy_amendment"] as? [String: Any]
		XCTAssertEqual(amendment?["allow"] as? [String], ["pwd"])
		XCTAssertEqual(fakeController.lastRespondedResult.count, 1)

		await vm.mcpDeactivateControlContext(sessionID: sessionID)
		await AgentRunSessionStore.cleanup(sessionID: sessionID)
	}

	func testMCPControlledCodexFileChangeApprovalWakesWaitersAsWaitingForInput() async throws {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		await vm.startAgentRun(tabID: tabID, initialMessage: "trigger")
		let sessionID = try XCTUnwrap(session.activeAgentSessionID)
		await vm.mcpActivateControlContext(forTabID: tabID, sessionID: sessionID, originatingConnectionID: nil)

		let waiter = Task {
			await AgentRunSessionStore.waitUntilInteresting(sessionID: sessionID, timeoutSeconds: 2)
		}
		try? await Task.sleep(nanoseconds: 50_000_000)

		fakeController.emit(.approvalRequest(AgentApprovalRequest(
			requestID: .codex(.string("req-file-change")),
			method: "item/fileChange/requestApproval",
			kind: .fileChange,
			threadID: "test-thread",
			turnID: "turn-file",
			itemID: "patch-1",
			reason: "apply_patch wants to edit files",
			grantRoot: "/tmp/repo"
		)))

		let disposition = await waiter.value
		guard case .snapshotReady(let snapshot) = disposition else {
			return XCTFail("Expected file-change approval snapshot to wake waiters, got \(disposition)")
		}
		XCTAssertEqual(snapshot.status, .waitingForInput)
		XCTAssertEqual(snapshot.interaction?.kind, .approval)
		XCTAssertEqual(snapshot.interaction?.details.first(where: { $0.label == "Approval Type" })?.value, AgentApprovalKind.fileChange.rawValue)
		let optionLabels = snapshot.interaction?.options.map(\.label) ?? []
		XCTAssertEqual(optionLabels, ["accept", "accept_for_session", "decline", "cancel"])

		await vm.mcpDeactivateControlContext(sessionID: sessionID)
		await AgentRunSessionStore.cleanup(sessionID: sessionID)
	}

	func testMCPRespondToFileChangeApprovalSendsAcceptForSessionPayload() async throws {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		await vm.startAgentRun(tabID: tabID, initialMessage: "trigger")
		let sessionID = try XCTUnwrap(session.activeAgentSessionID)
		await vm.mcpActivateControlContext(forTabID: tabID, sessionID: sessionID, originatingConnectionID: nil)
		let approval = AgentApprovalRequest(
			requestID: .codex(.string("req-file-accept-session")),
			method: "item/fileChange/requestApproval",
			kind: .fileChange,
			threadID: "test-thread",
			turnID: "turn-file",
			itemID: "patch-2",
			reason: "apply_patch wants to edit files"
		)
		fakeController.emit(.approvalRequest(approval))
		_ = await waitForCondition(timeoutSeconds: 2.0) {
			session.pendingApproval?.id == approval.id
		}

		_ = try await vm.mcpResolvePendingInteraction(
			sessionID: sessionID,
			interactionID: approval.id,
			payload: AgentModeViewModel.MCPInteractionResponsePayload(
				text: nil,
				skip: false,
				decisionRaw: "accept_for_session",
				amendment: nil,
				answersByQuestionID: [:]
			)
		)
		let responded = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.respondToServerRequestCallCount == 1
		}
		XCTAssertTrue(responded, "Expected MCP approval response to be sent to Codex controller")
		XCTAssertEqual(fakeController.lastRespondedRequestID, .string("req-file-accept-session"))
		XCTAssertEqual(fakeController.lastRespondedResult["decision"] as? String, "acceptForSession")
		XCTAssertEqual(fakeController.lastRespondedResult.count, 1)

		await vm.mcpDeactivateControlContext(sessionID: sessionID)
		await AgentRunSessionStore.cleanup(sessionID: sessionID)
	}

	func testMCPFileChangeApprovalRejectsAcceptWithAmendment() async throws {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		await vm.startAgentRun(tabID: tabID, initialMessage: "trigger")
		let sessionID = try XCTUnwrap(session.activeAgentSessionID)
		await vm.mcpActivateControlContext(forTabID: tabID, sessionID: sessionID, originatingConnectionID: nil)
		let approval = AgentApprovalRequest(
			requestID: .codex(.string("req-file-amend")),
			method: "item/fileChange/requestApproval",
			kind: .fileChange,
			threadID: "test-thread",
			turnID: "turn-file",
			itemID: "patch-3",
			reason: "apply_patch wants to edit files"
		)
		fakeController.emit(.approvalRequest(approval))
		_ = await waitForCondition(timeoutSeconds: 2.0) {
			session.pendingApproval?.id == approval.id
		}

		do {
			_ = try await vm.mcpResolvePendingInteraction(
				sessionID: sessionID,
				interactionID: approval.id,
				payload: AgentModeViewModel.MCPInteractionResponsePayload(
					text: nil,
					skip: false,
					decisionRaw: "accept_with_amendment",
					amendment: #"{"allow":["apply_patch"]}"#,
					answersByQuestionID: [:]
				)
			)
			XCTFail("Expected file-change approval amendment to be rejected")
		} catch let error as MCPError {
			guard case .invalidParams(let message) = error else {
				return XCTFail("Unexpected MCPError: \(error)")
			}
			XCTAssertTrue((message ?? "").contains("only supported for command approvals"))
		} catch {
			XCTFail("Unexpected error: \(error)")
		}
		XCTAssertEqual(fakeController.respondToServerRequestCallCount, 0)
		XCTAssertEqual(session.pendingApproval?.id, approval.id)

		await vm.mcpDeactivateControlContext(sessionID: sessionID)
		await AgentRunSessionStore.cleanup(sessionID: sessionID)
	}

	func testMCPControlledCodexPermissionsRequestWakesWaitersAsWaitingForInput() async throws {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		await vm.startAgentRun(tabID: tabID, initialMessage: "trigger")
		let sessionID = try XCTUnwrap(session.activeAgentSessionID)
		await vm.mcpActivateControlContext(forTabID: tabID, sessionID: sessionID, originatingConnectionID: nil)

		let waiter = Task {
			await AgentRunSessionStore.waitUntilInteresting(sessionID: sessionID, timeoutSeconds: 2)
		}
		try? await Task.sleep(nanoseconds: 50_000_000)

		let request = AgentPermissionsRequest(
			requestID: .string("req-permissions-wait"),
			method: "item/permissions/requestApproval",
			threadID: "test-thread",
			turnID: "turn-perm",
			itemID: "perm-1",
			cwd: "/tmp/repo",
			reason: "Need workspace write access",
			permissionsJSON: #"{"sandbox":{"mode":"workspace-write"},"networkAccess":true}"#
		)
		fakeController.emit(.permissionsRequest(request))

		let disposition = await waiter.value
		guard case .snapshotReady(let snapshot) = disposition else {
			return XCTFail("Expected permissions approval snapshot to wake waiters, got \(disposition)")
		}
		XCTAssertEqual(snapshot.status, .waitingForInput)
		XCTAssertEqual(snapshot.interaction?.kind, .approval)
		XCTAssertEqual(snapshot.interaction?.details.first(where: { $0.label == "Approval Type" })?.value, "permissions")
		XCTAssertEqual(snapshot.interaction?.details.first(where: { $0.label == "Working Directory" })?.value, "/tmp/repo")
		XCTAssertEqual(snapshot.interaction?.options.map(\.label) ?? [], ["accept", "accept_for_session", "decline", "cancel"])

		await vm.mcpDeactivateControlContext(sessionID: sessionID)
		await AgentRunSessionStore.cleanup(sessionID: sessionID)
	}

	func testMCPRespondToPermissionsApprovalAcceptSendsTurnScopedGrant() async throws {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		await vm.startAgentRun(tabID: tabID, initialMessage: "trigger")
		let sessionID = try XCTUnwrap(session.activeAgentSessionID)
		await vm.mcpActivateControlContext(forTabID: tabID, sessionID: sessionID, originatingConnectionID: nil)
		let request = AgentPermissionsRequest(
			requestID: .string("req-permissions-accept"),
			method: "item/permissions/requestApproval",
			threadID: "test-thread",
			turnID: "turn-perm",
			itemID: "perm-2",
			cwd: "/tmp/repo",
			permissionsJSON: #"{"sandbox":{"mode":"workspace-write"},"networkAccess":true}"#
		)
		fakeController.emit(.permissionsRequest(request))
		_ = await waitForCondition(timeoutSeconds: 2.0) { session.pendingPermissionsRequest?.id == request.id }

		_ = try await vm.mcpResolvePendingInteraction(
			sessionID: sessionID,
			interactionID: request.id,
			payload: AgentModeViewModel.MCPInteractionResponsePayload(text: nil, skip: false, decisionRaw: "accept", amendment: nil, answersByQuestionID: [:])
		)
		let responded = await waitForCondition(timeoutSeconds: 2.0) { fakeController.respondToServerRequestCallCount == 1 }
		XCTAssertTrue(responded)
		XCTAssertEqual(fakeController.lastRespondedRequestID, .string("req-permissions-accept"))
		XCTAssertEqual(fakeController.lastRespondedResult["scope"] as? String, "turn")
		XCTAssertEqual(fakeController.lastRespondedResult["strictAutoReview"] as? Bool, false)
		let permissions = fakeController.lastRespondedResult["permissions"] as? [String: Any]
		XCTAssertEqual(permissions?["networkAccess"] as? Bool, true)

		await vm.mcpDeactivateControlContext(sessionID: sessionID)
		await AgentRunSessionStore.cleanup(sessionID: sessionID)
	}

	func testMCPRespondToPermissionsApprovalAcceptForSessionSendsSessionScope() async throws {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		await vm.startAgentRun(tabID: tabID, initialMessage: "trigger")
		let sessionID = try XCTUnwrap(session.activeAgentSessionID)
		await vm.mcpActivateControlContext(forTabID: tabID, sessionID: sessionID, originatingConnectionID: nil)
		let request = AgentPermissionsRequest(
			requestID: .string("req-permissions-session"),
			method: "item/permissions/requestApproval",
			threadID: "test-thread",
			turnID: "turn-perm",
			itemID: "perm-3",
			cwd: "/tmp/repo",
			permissionsJSON: #"{"sandbox":{"mode":"workspace-write"}}"#
		)
		fakeController.emit(.permissionsRequest(request))
		_ = await waitForCondition(timeoutSeconds: 2.0) { session.pendingPermissionsRequest?.id == request.id }

		_ = try await vm.mcpResolvePendingInteraction(
			sessionID: sessionID,
			interactionID: request.id,
			payload: AgentModeViewModel.MCPInteractionResponsePayload(text: nil, skip: false, decisionRaw: "accept_for_session", amendment: nil, answersByQuestionID: [:])
		)
		let responded = await waitForCondition(timeoutSeconds: 2.0) { fakeController.respondToServerRequestCallCount == 1 }
		XCTAssertTrue(responded)
		XCTAssertEqual(fakeController.lastRespondedResult["scope"] as? String, "session")
		XCTAssertEqual((fakeController.lastRespondedResult["permissions"] as? [String: Any])?.isEmpty, false)

		await vm.mcpDeactivateControlContext(sessionID: sessionID)
		await AgentRunSessionStore.cleanup(sessionID: sessionID)
	}

	func testMCPRespondToPermissionsApprovalDeclineSendsEmptyTurnScopedGrant() async throws {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		await vm.startAgentRun(tabID: tabID, initialMessage: "trigger")
		let sessionID = try XCTUnwrap(session.activeAgentSessionID)
		await vm.mcpActivateControlContext(forTabID: tabID, sessionID: sessionID, originatingConnectionID: nil)
		let request = AgentPermissionsRequest(
			requestID: .string("req-permissions-decline"),
			method: "item/permissions/requestApproval",
			threadID: "test-thread",
			turnID: "turn-perm",
			itemID: "perm-4",
			cwd: "/tmp/repo",
			permissionsJSON: #"{"sandbox":{"mode":"workspace-write"}}"#
		)
		fakeController.emit(.permissionsRequest(request))
		_ = await waitForCondition(timeoutSeconds: 2.0) { session.pendingPermissionsRequest?.id == request.id }

		_ = try await vm.mcpResolvePendingInteraction(
			sessionID: sessionID,
			interactionID: request.id,
			payload: AgentModeViewModel.MCPInteractionResponsePayload(text: nil, skip: false, decisionRaw: "decline", amendment: nil, answersByQuestionID: [:])
		)
		let responded = await waitForCondition(timeoutSeconds: 2.0) { fakeController.respondToServerRequestCallCount == 1 }
		XCTAssertTrue(responded)
		XCTAssertEqual(fakeController.lastRespondedResult["scope"] as? String, "turn")
		XCTAssertEqual((fakeController.lastRespondedResult["permissions"] as? [String: Any])?.isEmpty, true)

		await vm.mcpDeactivateControlContext(sessionID: sessionID)
		await AgentRunSessionStore.cleanup(sessionID: sessionID)
	}

	func testMCPRespondToPermissionsApprovalCancelSendsEmptyGrantAndCancelsTurn() async throws {
		let fakeController = FakeCodexController()
		fakeController.cancelKeepsThreadAlive = true
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		await vm.startAgentRun(tabID: tabID, initialMessage: "trigger")
		let sessionID = try XCTUnwrap(session.activeAgentSessionID)
		await vm.mcpActivateControlContext(forTabID: tabID, sessionID: sessionID, originatingConnectionID: nil)
		let request = AgentPermissionsRequest(
			requestID: .string("req-permissions-cancel"),
			method: "item/permissions/requestApproval",
			threadID: "test-thread",
			turnID: "turn-perm",
			itemID: "perm-5",
			cwd: "/tmp/repo",
			permissionsJSON: #"{"sandbox":{"mode":"workspace-write"}}"#
		)
		fakeController.emit(.permissionsRequest(request))
		_ = await waitForCondition(timeoutSeconds: 2.0) { session.pendingPermissionsRequest?.id == request.id }

		_ = try await vm.mcpResolvePendingInteraction(
			sessionID: sessionID,
			interactionID: request.id,
			payload: AgentModeViewModel.MCPInteractionResponsePayload(text: nil, skip: false, decisionRaw: "cancel", amendment: nil, answersByQuestionID: [:])
		)
		let cancelled = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.respondToServerRequestCallCount == 1 && fakeController.cancelCurrentTurnCallCount == 1
		}
		XCTAssertTrue(cancelled)
		XCTAssertEqual((fakeController.lastRespondedResult["permissions"] as? [String: Any])?.isEmpty, true)
		XCTAssertEqual(fakeController.lastRespondedResult["scope"] as? String, "turn")

		await vm.mcpDeactivateControlContext(sessionID: sessionID)
		await AgentRunSessionStore.cleanup(sessionID: sessionID)
	}

	func testMCPPermissionsApprovalRejectsAcceptWithAmendment() async throws {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		await vm.startAgentRun(tabID: tabID, initialMessage: "trigger")
		let sessionID = try XCTUnwrap(session.activeAgentSessionID)
		await vm.mcpActivateControlContext(forTabID: tabID, sessionID: sessionID, originatingConnectionID: nil)
		let request = AgentPermissionsRequest(
			requestID: .string("req-permissions-amend"),
			method: "item/permissions/requestApproval",
			threadID: "test-thread",
			turnID: "turn-perm",
			itemID: "perm-6",
			cwd: "/tmp/repo",
			permissionsJSON: #"{"sandbox":{"mode":"workspace-write"}}"#
		)
		fakeController.emit(.permissionsRequest(request))
		_ = await waitForCondition(timeoutSeconds: 2.0) { session.pendingPermissionsRequest?.id == request.id }

		do {
			_ = try await vm.mcpResolvePendingInteraction(
				sessionID: sessionID,
				interactionID: request.id,
				payload: AgentModeViewModel.MCPInteractionResponsePayload(text: nil, skip: false, decisionRaw: "accept_with_amendment", amendment: #"{"allow":["pwd"]}"#, answersByQuestionID: [:])
			)
			XCTFail("Expected permission amendment to be rejected")
		} catch let error as MCPError {
			guard case .invalidParams(let message) = error else {
				return XCTFail("Unexpected MCPError: \(error)")
			}
			XCTAssertTrue((message ?? "").contains("not supported for permission approvals"))
		} catch {
			XCTFail("Unexpected error: \(error)")
		}
		XCTAssertEqual(fakeController.respondToServerRequestCallCount, 0)
		XCTAssertEqual(session.pendingPermissionsRequest?.id, request.id)

		await vm.mcpDeactivateControlContext(sessionID: sessionID)
		await AgentRunSessionStore.cleanup(sessionID: sessionID)
	}

	func testSubmittingFileChangeApprovalDecisionExecpolicyAmendmentDoesNotRespond() async {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		await vm.startAgentRun(tabID: tabID, initialMessage: "trigger")
		let approval = AgentApprovalRequest(
			requestID: .codex(.string("req-file-direct-amend")),
			method: "item/fileChange/requestApproval",
			kind: .fileChange,
			threadID: "test-thread",
			turnID: "turn-file",
			itemID: "patch-4",
			reason: "apply_patch wants to edit files"
		)
		fakeController.emit(.approvalRequest(approval))
		_ = await waitForCondition(timeoutSeconds: 2.0) {
			session.pendingApproval?.id == approval.id
		}

		vm.submitApprovalDecision(
			tabID: tabID,
			decision: .acceptWithExecpolicyAmendment(#"{"allow":["apply_patch"]}"#)
		)
		try? await Task.sleep(nanoseconds: 50_000_000)

		XCTAssertEqual(fakeController.respondToServerRequestCallCount, 0)
		XCTAssertEqual(session.pendingApproval?.id, approval.id)
	}

	func testSubmittingApprovalDecisionAcceptAcrossSandboxPermissionModes() async {
		let previousApprovalPolicy = CodexAgentToolPreferences.approvalPolicy()
		let previousSandboxMode = CodexAgentToolPreferences.sandboxMode()
		let previousApprovalReviewer = CodexAgentToolPreferences.approvalReviewer()
		defer {
			CodexAgentToolPreferences.setApprovalPolicy(previousApprovalPolicy)
			CodexAgentToolPreferences.setSandboxMode(previousSandboxMode)
			CodexAgentToolPreferences.setApprovalReviewer(previousApprovalReviewer)
		}

		let modeCases: [(permission: CodexAgentToolPreferences.PermissionLevel, expectedSandbox: CodexAgentToolPreferences.SandboxMode, expectedPolicy: CodexAgentToolPreferences.ApprovalPolicy, expectedReviewer: CodexAgentToolPreferences.ApprovalReviewer)] = [
			(.readOnly, .readOnly, .onRequest, .user),
			(.defaultPermission, .workspaceWrite, .onRequest, .user),
			(.autoReview, .workspaceWrite, .onRequest, .autoReview),
			(.fullAccess, .dangerFullAccess, .never, .user)
		]

		for (index, modeCase) in modeCases.enumerated() {
			CodexAgentToolPreferences.setPermissionLevel(modeCase.permission)
			XCTAssertEqual(CodexAgentToolPreferences.sandboxMode(), modeCase.expectedSandbox)
			XCTAssertEqual(CodexAgentToolPreferences.approvalPolicy(), modeCase.expectedPolicy)
			XCTAssertEqual(CodexAgentToolPreferences.approvalReviewer(), modeCase.expectedReviewer)

			let fakeController = FakeCodexController()
			let vm = AgentModeViewModel(
				testWindowID: 1,
				testWorkspacePath: FileManager.default.currentDirectoryPath
			) { _, _, _, _, _, _ in
				fakeController
			}

			let tabID = UUID()
			let session = await vm.ensureSessionReady(tabID: tabID)
			session.selectedAgent = .codexExec
			await vm.startAgentRun(tabID: tabID, initialMessage: "trigger-\(index)")

			let requestID: CodexAppServerRequestID = .string("req-mode-\(index)")
			let approval = AgentApprovalRequest(
				requestID: .codex(requestID),
				method: "item/commandExecution/requestApproval",
				kind: .commandExecution,
				threadID: "thread-\(index)",
				turnID: "turn-\(index)",
				itemID: "call-\(index)",
				command: "uv --version"
			)
			fakeController.emit(.approvalRequest(approval))
			_ = await waitForCondition(timeoutSeconds: 2.0) {
				session.pendingApproval?.requestID == .codex(requestID)
			}

			vm.submitApprovalDecision(tabID: tabID, decision: .accept)
			let responded = await waitForCondition(timeoutSeconds: 2.0) {
				fakeController.respondToServerRequestCallCount == 1
			}

			XCTAssertTrue(
				responded,
				"Expected acceptance response in mode \(modeCase.permission.rawValue)"
			)
			XCTAssertEqual(fakeController.lastRespondedRequestID, requestID)
			XCTAssertEqual(fakeController.lastRespondedResult["decision"] as? String, "accept")
			XCTAssertEqual(fakeController.lastRespondedResult.count, 1)
		}
	}

	func testCancelThenFollowUpRestartsCodexSessionViaAgentVM() async throws {
		let fakeController = FakeCodexController()
		var factoryCallCount = 0
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			factoryCallCount += 1
			return fakeController
		}

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.selectedModel = .codexMedium

		await runAndReconnectCycle(viewModel: vm, tabID: tabID, fakeController: fakeController, session: session)

		XCTAssertEqual(factoryCallCount, 1, "Controller should be created once and reused")
		XCTAssertEqual(fakeController.cancelCurrentTurnCallCount, 1)
		XCTAssertEqual(fakeController.sendUserMessageCallCount, 2)
		XCTAssertEqual(fakeController.startOrResumeCallCount, 2, "Follow-up should force startOrResume after cancel")
		XCTAssertFalse(session.codexNeedsReconnect, "Reconnect flag should clear after successful follow-up start")
	}

	func testCancelWithLiveThreadDoesNotRequireReconnect() async throws {
		let fakeController = FakeCodexController()
		fakeController.cancelKeepsThreadAlive = true
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.selectedModel = .codexMedium

		await vm.startAgentRun(tabID: tabID, initialMessage: "first turn")
		XCTAssertEqual(fakeController.startOrResumeCallCount, 1)
		XCTAssertEqual(fakeController.sendUserMessageCallCount, 1)

		await vm.cancelAgentRun(tabID: tabID)
		XCTAssertFalse(session.codexNeedsReconnect, "Cancel should not require reconnect while thread is still live")

		await vm.startAgentRun(tabID: tabID, initialMessage: "follow-up turn")
		XCTAssertEqual(fakeController.startOrResumeCallCount, 1, "Follow-up should reuse the live Codex thread")
		XCTAssertEqual(fakeController.sendUserMessageCallCount, 2)
	}

	func testTransportClosedEventThenStreamEndRecoversBeforeManualReconnect() async throws {
		let firstController = FakeCodexController()
		let secondController = FakeCodexController()
		var factoryCallCount = 0
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			defer { factoryCallCount += 1 }
			return factoryCallCount == 0 ? firstController : secondController
		}

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.selectedModel = .codexHigh

		await vm.startAgentRun(tabID: tabID, initialMessage: "first turn")
		let didSendFirstTurn = await waitForCondition(timeoutSeconds: 2.0) {
			firstController.startOrResumeCallCount == 1
				&& firstController.sendUserMessageCallCount == 1
		}
		XCTAssertTrue(didSendFirstTurn, "Expected initial Codex turn to start")

		firstController.emit(.error("Transport closed"))
		let awaitingStreamEnd = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .running
				&& session.runningStatusText == "Reconnecting…"
				&& session.codexController != nil
				&& session.codexEventTask != nil
				&& !session.codexNeedsReconnect
		}
		XCTAssertTrue(
			awaitingStreamEnd,
			"Transport-closed errors during active runs should wait for stream end before tearing down the session"
		)
		XCTAssertEqual(factoryCallCount, 1)
		XCTAssertEqual(firstController.sendUserMessageCallCount, 1, "Transport-closed retry flow should not resend the active turn")

		await firstController.shutdown()
		let recovered = await waitForCondition(timeoutSeconds: 3.0) {
			factoryCallCount == 2
				&& secondController.startOrResumeCallCount == 1
				&& secondController.sendUserMessageCallCount == 0
				&& session.runState == .running
				&& !session.codexNeedsReconnect
		}
		XCTAssertTrue(recovered, "Stream end after a transport-closed error should trigger automatic recovery")
		XCTAssertEqual(firstController.startOrResumeCallCount, 1, "Original controller should not be reused after transport close")
		XCTAssertEqual(firstController.sendUserMessageCallCount, 1, "Original controller should not receive an extra turn during recovery")

		secondController.emit(.turnCompleted(turnID: nil, status: .completed))
		let completed = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .completed
		}
		XCTAssertTrue(completed)
	}

	func testTransportClosedWithoutStreamEndRecoversAfterGracePeriod() async throws {
		let firstController = FakeCodexController()
		let secondController = FakeCodexController()
		var factoryCallCount = 0
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath,
			codexControllerFactory: { _, _, _, _, _, _ in
				defer { factoryCallCount += 1 }
				return factoryCallCount == 0 ? firstController : secondController
			},
			testCodexTransportClosedRecoveryGraceInterval: 0.05
		)

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.selectedModel = .codexHigh

		await vm.startAgentRun(tabID: tabID, initialMessage: "first turn")
		let didSendFirstTurn = await waitForCondition(timeoutSeconds: 2.0) {
			firstController.startOrResumeCallCount == 1
				&& firstController.sendUserMessageCallCount == 1
		}
		XCTAssertTrue(didSendFirstTurn, "Expected initial Codex turn to start")

		firstController.emit(.error("Transport closed"))
		let recovered = await waitForCondition(timeoutSeconds: 2.0) {
			factoryCallCount == 2
				&& firstController.shutdownCallCount == 1
				&& secondController.startOrResumeCallCount == 1
				&& secondController.sendUserMessageCallCount == 0
				&& session.runState == .running
				&& session.runningStatusText == "Reconnecting…"
				&& session.codexController.map { ObjectIdentifier($0 as AnyObject) } == ObjectIdentifier(secondController)
				&& !session.codexNeedsReconnect
		}
		XCTAssertTrue(recovered, "Transport-closed errors without EOF should recover after the grace period")
		XCTAssertEqual(firstController.sendUserMessageCallCount, 1, "Recovery should not resend the active turn")

		secondController.emit(.turnCompleted(turnID: nil, status: .completed))
		let completed = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .completed
		}
		XCTAssertTrue(completed)
	}

	func testStreamEndAfterCompletedTurnMarksReconnectAndRecreatesController() async throws {
		let firstController = FakeCodexController()
		let secondController = FakeCodexController()
		var factoryCallCount = 0
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			defer { factoryCallCount += 1 }
			return factoryCallCount == 0 ? firstController : secondController
		}

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.selectedModel = .codexHigh

		await vm.startAgentRun(tabID: tabID, initialMessage: "first turn")
		let didSendFirstTurn = await waitForCondition(timeoutSeconds: 2.0) {
			firstController.startOrResumeCallCount == 1
				&& firstController.sendUserMessageCallCount == 1
		}
		XCTAssertTrue(didSendFirstTurn, "Expected initial Codex turn to start")

		firstController.emit(.turnCompleted(turnID: nil, status: .completed))
		let completed = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .completed
		}
		XCTAssertTrue(completed, "Expected first turn to complete")

		await firstController.shutdown()
		let reconnectMarked = await waitForCondition(timeoutSeconds: 2.0) {
			session.codexNeedsReconnect
				&& session.codexController == nil
				&& session.codexEventTask == nil
				&& session.runState == .completed
		}
		XCTAssertTrue(reconnectMarked, "Stream end between turns should mark reconnect without changing completed state")

		await vm.startAgentRun(tabID: tabID, initialMessage: "follow-up turn")
		let didSendFollowUpTurn = await waitForCondition(timeoutSeconds: 2.0) {
			factoryCallCount == 2
				&& secondController.startOrResumeCallCount == 1
				&& secondController.sendUserMessageCallCount == 1
				&& !session.codexNeedsReconnect
		}
		XCTAssertTrue(didSendFollowUpTurn, "Follow-up should recreate controller after stream end while idle")
	}

	func testTransportClosedAfterCompletedTurnPreservesStateAndSkipsErrorItem() async {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.selectedModel = .codexHigh

		await vm.startAgentRun(tabID: tabID, initialMessage: "first turn")
		let started = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.startOrResumeCallCount == 1 && fakeController.sendUserMessageCallCount == 1
		}
		XCTAssertTrue(started)

		fakeController.emit(.turnCompleted(turnID: nil, status: .completed))
		let completed = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .completed
		}
		XCTAssertTrue(completed)
		let errorCountBeforeTransportClose = session.items.filter { $0.kind == .error }.count

		fakeController.emit(.error("Codex transport closed unexpectedly."))
		let preserved = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .completed
				&& session.codexNeedsReconnect
				&& session.codexController == nil
				&& session.codexEventTask == nil
		}
		XCTAssertTrue(preserved, "Idle transport close should preserve completed run state and only mark reconnect")
		assertCodexIdleReconnectInvariants(session)
		let itemCountBeforeStaleEvent = session.items.count
		fakeController.emit(.assistantDelta("stale-delta"))
		try? await Task.sleep(nanoseconds: 150_000_000)
		XCTAssertEqual(session.items.count, itemCountBeforeStaleEvent, "Events from invalidated controllers should be ignored")
		let errorCountAfterTransportClose = session.items.filter { $0.kind == .error }.count
		XCTAssertEqual(errorCountAfterTransportClose, errorCountBeforeTransportClose)
	}

	func testStreamEndWhileRunActiveRecoversViaResumeBeforeFailing() async {
		let firstController = FakeCodexController()
		let secondController = FakeCodexController()
		let controllers = [firstController, secondController]
		var factoryCallCount = 0
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			defer { factoryCallCount += 1 }
			return controllers[min(factoryCallCount, controllers.count - 1)]
		}

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.selectedModel = .codexHigh

		await vm.startAgentRun(tabID: tabID, initialMessage: "first turn")
		let started = await waitForCondition(timeoutSeconds: 2.0) {
			firstController.startOrResumeCallCount == 1 && firstController.sendUserMessageCallCount == 1
		}
		XCTAssertTrue(started)

		await firstController.shutdown()
		let recovered = await waitForCondition(timeoutSeconds: 3.0) {
			factoryCallCount == 2
				&& secondController.startOrResumeCallCount == 1
				&& secondController.sendUserMessageCallCount == 0
				&& session.runState == .running
				&& !session.codexNeedsReconnect
		}
		XCTAssertTrue(recovered, "Unexpected stream end during an active run should attempt automatic recovery before failing")
		XCTAssertEqual(secondController.startOrResumeExistingRefs.first??.conversationID, "test-thread")
		XCTAssertFalse(
			session.items.contains(where: { $0.kind == .error && $0.text.contains("events stream ended unexpectedly") }),
			"Successful recovery should avoid a terminal stream-end error item"
		)

		secondController.emit(.turnCompleted(turnID: nil, status: .completed))
		let completed = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .completed
		}
		XCTAssertTrue(completed)
	}

	func testStreamEndWhileRunActiveFailsAfterRecoveryAttempt() async {
		let firstController = FakeCodexController()
		let secondController = FakeCodexController()
		secondController.startOrResumeErrorDescriptions = ["resume failed after disconnect"]
		let controllers = [firstController, secondController]
		var factoryCallCount = 0
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			defer { factoryCallCount += 1 }
			return controllers[min(factoryCallCount, controllers.count - 1)]
		}

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.selectedModel = .codexHigh

		await vm.startAgentRun(tabID: tabID, initialMessage: "first turn")
		let started = await waitForCondition(timeoutSeconds: 2.0) {
			firstController.startOrResumeCallCount == 1 && firstController.sendUserMessageCallCount == 1
		}
		XCTAssertTrue(started)

		await firstController.shutdown()
		let failed = await waitForCondition(timeoutSeconds: 3.0) {
			session.runState == .failed
				&& session.codexNeedsReconnect
				&& secondController.startOrResumeCallCount == 1
				&& secondController.sendUserMessageCallCount == 0
		}
		XCTAssertTrue(failed, "Unexpected stream end should fail only after the automatic recovery attempt cannot restore the session")
		assertCodexTerminalInvariants(session, expectedRunState: .failed)
		XCTAssertEqual(secondController.startOrResumeCallCount, 1)
		XCTAssertEqual(secondController.sendUserMessageCallCount, 0)
		XCTAssertEqual(secondController.startOrResumeExistingRefs.first??.conversationID, "test-thread")
		XCTAssertTrue(
			session.items.contains(where: { $0.kind == .error && $0.text.hasPrefix("Codex native resume failed:") }),
			"Failed recovery should surface the recovery resume failure"
		)
	}

	func testStreamEndWhileWaitingForApprovalClearsTransientState() async {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.selectedModel = .codexHigh

		await vm.startAgentRun(tabID: tabID, initialMessage: "needs approval")
		let started = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.startOrResumeCallCount == 1 && fakeController.sendUserMessageCallCount == 1
		}
		XCTAssertTrue(started)

		let invocationID = UUID()
		fakeController.emit(.toolCall(name: "search", invocationID: invocationID, argsJSON: "{}"))
		let approval = AgentApprovalRequest(
			requestID: .codex(.string("req-stream-end-approval")),
			method: "item/commandExecution/requestApproval",
			kind: .commandExecution,
			threadID: "thread-1",
			turnID: "turn-1",
			itemID: "item-1",
			command: "echo hello"
		)
		fakeController.emit(.approvalRequest(approval))

		let waitingForApproval = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .waitingForApproval
				&& session.pendingApproval != nil
				&& session.items.contains(where: { $0.kind == .toolCall && $0.toolInvocationID == invocationID })
		}
		XCTAssertTrue(waitingForApproval)

		await fakeController.shutdown()
		let failed = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .failed
		}
		XCTAssertTrue(failed)
		assertCodexTerminalInvariants(session, expectedRunState: .failed)
		XCTAssertTrue(
			session.items.contains(where: { $0.kind == .error && $0.text.contains("events stream ended unexpectedly") }),
			"Expected stream-end error item after unexpected shutdown"
		)
		XCTAssertEqual(fakeController.readThreadSnapshotCallCount, 0, "Approval waits should skip automatic recovery in the first pass")
	}

	func testStreamEndWhileWaitingForUserInputClearsTransientState() async {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.selectedModel = .codexHigh

		await vm.startAgentRun(tabID: tabID, initialMessage: "needs user input")
		let started = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.startOrResumeCallCount == 1 && fakeController.sendUserMessageCallCount == 1
		}
		XCTAssertTrue(started)

		let request = makeUserInputRequest(id: "input-stream-ended", questionID: "choice")
		fakeController.emit(.requestUserInput(request))
		let waitingForUserInput = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .waitingForQuestion
				&& session.pendingUserInputRequest?.requestID == request.requestID
		}
		XCTAssertTrue(waitingForUserInput)

		await fakeController.shutdown()
		let failed = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .failed
		}
		XCTAssertTrue(failed)
		assertCodexTerminalInvariants(session, expectedRunState: .failed)
		XCTAssertTrue(
			session.items.contains(where: { $0.kind == .error && $0.text.contains("events stream ended unexpectedly") }),
			"Expected stream-end error item after unexpected shutdown while waiting on Codex user input"
		)
		XCTAssertEqual(fakeController.readThreadSnapshotCallCount, 0, "User-input waits should skip automatic recovery in the first pass")
	}

	func testStallWatchdogTreatsRepeatedActiveSnapshotsAsLiveness() async {
		let firstController = FakeCodexController()
		firstController.queuedThreadSnapshots = [
			makeThreadSnapshot(runtimeStatus: .active(activeFlags: [])),
			makeThreadSnapshot(runtimeStatus: .active(activeFlags: [])),
			makeThreadSnapshot(runtimeStatus: .active(activeFlags: []))
		]
		let secondController = FakeCodexController()
		let controllers = [firstController, secondController]
		var factoryCallCount = 0
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath,
			codexControllerFactory: { _, _, _, _, _, _ in
				defer { factoryCallCount += 1 }
				return controllers[min(factoryCallCount, controllers.count - 1)]
			},
			testCodexStallWatchdogPollIntervalNanos: 20_000_000,
			testCodexStallWatchdogProbeThreshold: 1,
			testCodexStallWatchdogRecoveryThreshold: 2
		)

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.selectedModel = .codexHigh

		await vm.startAgentRun(tabID: tabID, initialMessage: "watchdog me")
		let started = await waitForCondition(timeoutSeconds: 2.0) {
			firstController.startOrResumeCallCount == 1 && firstController.sendUserMessageCallCount == 1
		}
		XCTAssertTrue(started)

		let reprobed = await waitForCondition(timeoutSeconds: 4.0) {
			firstController.readThreadSnapshotCallCount >= 2
				&& secondController.startOrResumeCallCount == 0
				&& secondController.sendUserMessageCallCount == 0
				&& session.runState == .running
				&& !session.codexNeedsReconnect
				&& !session.codexWatchdogState.isPausedAfterWarning
				&& !self.hasCodexStallTimeoutWarning(session)
		}
		XCTAssertTrue(reprobed, "Active thread/read snapshots should reset liveness and avoid the red stall warning")
		XCTAssertEqual(firstController.readThreadSnapshotIncludeTurnsValues, Array(repeating: false, count: firstController.readThreadSnapshotCallCount))
		await vm.cancelAgentRun(tabID: tabID)
	}

	func testLegacyStallWatchdogInactivityThresholdTreatsActiveSnapshotsAsLiveness() async {
		let firstController = FakeCodexController()
		firstController.queuedThreadSnapshots = [
			makeThreadSnapshot(runtimeStatus: .active(activeFlags: [])),
			makeThreadSnapshot(runtimeStatus: .active(activeFlags: []))
		]
		let secondController = FakeCodexController()
		let controllers = [firstController, secondController]
		var factoryCallCount = 0
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath,
			codexControllerFactory: { _, _, _, _, _, _ in
				defer { factoryCallCount += 1 }
				return controllers[min(factoryCallCount, controllers.count - 1)]
			},
			testCodexStallWatchdogPollIntervalNanos: 20_000_000,
			testCodexStallWatchdogInactivityThreshold: 1
		)

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.selectedModel = .codexHigh

		await vm.startAgentRun(tabID: tabID, initialMessage: "legacy watchdog")
		let started = await waitForCondition(timeoutSeconds: 2.0) {
			firstController.startOrResumeCallCount == 1 && firstController.sendUserMessageCallCount == 1
		}
		XCTAssertTrue(started)

		let reprobed = await waitForCondition(timeoutSeconds: 3.0) {
			firstController.readThreadSnapshotCallCount >= 2
				&& secondController.startOrResumeCallCount == 0
				&& session.runState == .running
				&& !session.codexNeedsReconnect
				&& !session.codexWatchdogState.isPausedAfterWarning
				&& !self.hasCodexStallTimeoutWarning(session)
		}
		XCTAssertTrue(reprobed, "The legacy single-threshold test seam should still treat active snapshots as positive liveness")
		await vm.cancelAgentRun(tabID: tabID)
	}

	func testStallWatchdogStartsProbeBeforeRecoveryThreshold() async {
		let fakeController = FakeCodexController()
		fakeController.shouldBlockReadThreadSnapshot = true
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath,
			codexControllerFactory: { _, _, _, _, _, _ in
				fakeController
			},
			testCodexStallWatchdogPollIntervalNanos: 20_000_000,
			testCodexStallWatchdogProbeThreshold: 0.75,
			testCodexStallWatchdogRecoveryThreshold: 2.5
		)

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.selectedModel = .codexHigh

		await vm.startAgentRun(tabID: tabID, initialMessage: "probe early")
		let started = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.startOrResumeCallCount == 1 && fakeController.sendUserMessageCallCount == 1
		}
		XCTAssertTrue(started)

		let probeStarted = await waitForCondition(timeoutSeconds: 1.6) {
			fakeController.readThreadSnapshotCallCount == 1
				&& fakeController.readThreadSnapshotIncludeTurnsValues == [false]
				&& session.runState == .running
				&& !session.codexNeedsReconnect
		}
		XCTAssertTrue(probeStarted, "The watchdog should start probing before the later recovery threshold is reached")
		XCTAssertEqual(fakeController.startOrResumeCallCount, 1, "The blocked probe should not have triggered an early recovery")

		fakeController.shouldBlockReadThreadSnapshot = false
		fakeController.unblockReadThreadSnapshot()
		await vm.cancelAgentRun(tabID: tabID)
	}

	func testStallWatchdogWarnsInsteadOfAttemptingRecoveryWhenSilencePersists() async {
		let firstController = FakeCodexController()
		firstController.queuedThreadSnapshots = [makeIdleThreadSnapshot()]
		let secondController = FakeCodexController()
		secondController.startOrResumeErrorDescriptions = ["resume failed after stall"]
		let controllers = [firstController, secondController]
		var factoryCallCount = 0
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath,
			codexControllerFactory: { _, _, _, _, _, _ in
				defer { factoryCallCount += 1 }
				return controllers[min(factoryCallCount, controllers.count - 1)]
			},
			testCodexStallWatchdogPollIntervalNanos: 20_000_000,
			testCodexStallWatchdogProbeThreshold: 0.75,
			testCodexStallWatchdogRecoveryThreshold: 2.5
		)

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.selectedModel = .codexHigh

		await vm.startAgentRun(tabID: tabID, initialMessage: "watchdog me")
		let started = await waitForCondition(timeoutSeconds: 2.0) {
			firstController.startOrResumeCallCount == 1 && firstController.sendUserMessageCallCount == 1
		}
		XCTAssertTrue(started)

		let warned = await waitForCondition(timeoutSeconds: 5.0) {
			firstController.readThreadSnapshotCallCount == 1
				&& session.runState == .running
				&& !session.codexNeedsReconnect
				&& secondController.startOrResumeCallCount == 0
				&& secondController.sendUserMessageCallCount == 0
				&& session.codexWatchdogState.isPausedAfterWarning
				&& self.hasCodexStallTimeoutWarning(session)
		}
		XCTAssertTrue(warned, "Stall watchdog should warn in-stream instead of attempting reconnect/recovery when silence persists")
		XCTAssertEqual(firstController.readThreadSnapshotIncludeTurnsValues, [false])
		XCTAssertEqual(secondController.startOrResumeCallCount, 0)
		XCTAssertEqual(secondController.sendUserMessageCallCount, 0)
		XCTAssertFalse(
			session.items.contains(where: { $0.kind == .error && $0.text.hasPrefix("Codex native resume failed:") }),
			"Warning-only watchdog behavior should avoid attempted reconnect/resume failures"
		)
		try? await Task.sleep(nanoseconds: 400_000_000)
		XCTAssertEqual(firstController.readThreadSnapshotCallCount, 1, "The watchdog should pause after surfacing the stall warning")
		await vm.cancelAgentRun(tabID: tabID)
	}

	func testStallWatchdogSuppressesProbeWhileRepoPromptToolStillActive() async {
		let firstController = FakeCodexController()
		firstController.queuedThreadSnapshots = [makeIdleThreadSnapshot()]
		let secondController = FakeCodexController()
		let controllers = [firstController, secondController]
		var factoryCallCount = 0
		var hasActiveToolExecutions = true
		let queriedRunIDs = LockedUUIDArray()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath,
			codexControllerFactory: { _, _, _, _, _, _ in
				defer { factoryCallCount += 1 }
				return controllers[min(factoryCallCount, controllers.count - 1)]
			},
			testCodexActiveToolQuery: { runID in
				queriedRunIDs.append(runID)
				return hasActiveToolExecutions
			},
			testCodexStallWatchdogPollIntervalNanos: 20_000_000,
			testCodexStallWatchdogProbeThreshold: 1,
			testCodexStallWatchdogRecoveryThreshold: 2
		)

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.selectedModel = .codexHigh

		await vm.startAgentRun(tabID: tabID, initialMessage: "watchdog me")
		let started = await waitForCondition(timeoutSeconds: 2.0) {
			firstController.startOrResumeCallCount == 1 && firstController.sendUserMessageCallCount == 1
		}
		XCTAssertTrue(started)
		guard let expectedRunID = session.runID else {
			XCTFail("Expected active run ID")
			return
		}

		try? await Task.sleep(nanoseconds: 1_300_000_000)
		XCTAssertEqual(firstController.readThreadSnapshotCallCount, 0, "Active RepoPrompt tools should suppress watchdog probing")
		XCTAssertEqual(secondController.startOrResumeCallCount, 0)
		XCTAssertEqual(session.runState, .running)
		XCTAssertFalse(self.hasCodexStallTimeoutWarning(session), "Suppressed RepoPrompt tool activity should not emit a stall warning")

		hasActiveToolExecutions = false
		try? await Task.sleep(nanoseconds: 400_000_000)
		XCTAssertEqual(firstController.readThreadSnapshotCallCount, 0, "When tool activity stops, the watchdog should wait for a fresh inactivity window before probing")

		let warned = await waitForCondition(timeoutSeconds: 3.0) {
			firstController.readThreadSnapshotCallCount == 1
				&& secondController.startOrResumeCallCount == 0
				&& secondController.sendUserMessageCallCount == 0
				&& session.runState == .running
				&& !session.codexNeedsReconnect
				&& session.codexWatchdogState.isPausedAfterWarning
				&& self.hasCodexStallTimeoutWarning(session)
		}
		XCTAssertTrue(warned, "Once RepoPrompt tools go idle, the watchdog should resume normal probe-then-warning behavior")
		let queriedRunIDsSnapshot = queriedRunIDs.snapshot()
		XCTAssertFalse(queriedRunIDsSnapshot.isEmpty)
		XCTAssertTrue(queriedRunIDsSnapshot.allSatisfy { $0 == expectedRunID }, "Active-tool checks should always use the current run ID")
		await vm.cancelAgentRun(tabID: tabID)
	}

	func testStallWatchdogSuppressesProbeWhileAgentRunWaitIsActive() async {
		let firstController = FakeCodexController()
		firstController.queuedThreadSnapshots = [makeIdleThreadSnapshot()]
		let secondController = FakeCodexController()
		let controllers = [firstController, secondController]
		var factoryCallCount = 0
		var hasActiveAgentRunWait = true
		let queriedRunIDs = LockedUUIDArray()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath,
			codexControllerFactory: { _, _, _, _, _, _ in
				defer { factoryCallCount += 1 }
				return controllers[min(factoryCallCount, controllers.count - 1)]
			},
			testCodexActiveAgentRunWaitQuery: { runID in
				queriedRunIDs.append(runID)
				return hasActiveAgentRunWait
			},
			testCodexStallWatchdogPollIntervalNanos: 20_000_000,
			testCodexStallWatchdogProbeThreshold: 1,
			testCodexStallWatchdogRecoveryThreshold: 2
		)

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.selectedModel = .codexHigh

		await vm.startAgentRun(tabID: tabID, initialMessage: "watchdog me")
		let started = await waitForCondition(timeoutSeconds: 2.0) {
			firstController.startOrResumeCallCount == 1 && firstController.sendUserMessageCallCount == 1
		}
		XCTAssertTrue(started)
		guard let expectedRunID = session.runID else {
			XCTFail("Expected active run ID")
			return
		}

		try? await Task.sleep(nanoseconds: 1_300_000_000)
		XCTAssertEqual(firstController.readThreadSnapshotCallCount, 0, "Active agent_run waits should suppress watchdog probing")
		XCTAssertEqual(secondController.startOrResumeCallCount, 0)
		XCTAssertEqual(session.runState, .running)
		XCTAssertFalse(self.hasCodexStallTimeoutWarning(session), "Suppressed agent_run wait activity should not emit a stall warning")

		hasActiveAgentRunWait = false
		try? await Task.sleep(nanoseconds: 400_000_000)
		XCTAssertEqual(firstController.readThreadSnapshotCallCount, 0, "When the agent_run wait ends, the watchdog should wait for a fresh inactivity window before probing")

		let warned = await waitForCondition(timeoutSeconds: 3.0) {
			firstController.readThreadSnapshotCallCount == 1
				&& secondController.startOrResumeCallCount == 0
				&& secondController.sendUserMessageCallCount == 0
				&& session.runState == .running
				&& !session.codexNeedsReconnect
				&& session.codexWatchdogState.isPausedAfterWarning
				&& self.hasCodexStallTimeoutWarning(session)
		}
		XCTAssertTrue(warned, "Once the agent_run wait clears, the watchdog should resume normal probe-then-warning behavior")
		let queriedRunIDsSnapshot = queriedRunIDs.snapshot()
		XCTAssertFalse(queriedRunIDsSnapshot.isEmpty)
		XCTAssertTrue(queriedRunIDsSnapshot.allSatisfy { $0 == expectedRunID }, "Agent-run wait checks should always use the current run ID")
		await vm.cancelAgentRun(tabID: tabID)
	}

	func testStallWatchdogSuppressesProbeWhileObservedBashProcessStillAlive() async {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath,
			codexControllerFactory: { _, _, _, _, _, _ in
				fakeController
			},
			testCodexStallWatchdogPollIntervalNanos: 20_000_000,
			testCodexStallWatchdogProbeThreshold: 1,
			testCodexStallWatchdogRecoveryThreshold: 2
		)

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.selectedModel = .codexHigh

		await vm.startAgentRun(tabID: tabID, initialMessage: "watchdog me")
		let started = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.startOrResumeCallCount == 1 && fakeController.sendUserMessageCallCount == 1
		}
		XCTAssertTrue(started)

		let liveProcessID = String(ProcessInfo.processInfo.processIdentifier)
		let runningResultJSON = #"{"type":"commandExecution","status":"running","command":"sleep 30","processId":"__PID__"}"#
			.replacingOccurrences(of: "__PID__", with: liveProcessID)
		fakeController.emit(.toolResult(
			name: "bash",
			invocationID: nil,
			argsJSON: #"{"command":"sleep 30"}"#,
			resultJSON: runningResultJSON,
			isError: false
		))

		let renderedRunningBash = await waitForCondition(timeoutSeconds: 2.0) {
			session.items.contains(where: { item in
				guard item.toolName == "bash" else { return false }
				guard let json = item.toolResultJSON else { return false }
				return json.contains(#""status":"running""#)
					&& json.contains(liveProcessID)
			})
		}
		XCTAssertTrue(renderedRunningBash, "Expected a running bash result with a live PID before watchdog evaluation")

		try? await Task.sleep(nanoseconds: 1_300_000_000)
		XCTAssertEqual(fakeController.readThreadSnapshotCallCount, 0, "An observed live bash PID should hard-suppress watchdog probing")
		XCTAssertEqual(session.runState, .running)
		XCTAssertFalse(session.codexNeedsReconnect)
		XCTAssertFalse(self.hasCodexStallTimeoutWarning(session), "Observed live bash activity should not emit a stall warning")

		fakeController.emit(.turnCompleted(turnID: nil, status: .completed))
		let completed = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .completed
		}
		XCTAssertTrue(completed)
	}

	func testStallWatchdogKeepsProbingButAvoidsRecoveryWhileNonRepoPromptToolRemainsInFlight() async {
		let firstController = FakeCodexController()
		firstController.queuedThreadSnapshots = [
			makeThreadSnapshot(runtimeStatus: .active(activeFlags: ["toolRunning"])),
			makeThreadSnapshot(runtimeStatus: .active(activeFlags: ["toolRunning"])),
			makeThreadSnapshot(runtimeStatus: .active(activeFlags: ["toolRunning"]))
		]
		let secondController = FakeCodexController()
		let controllers = [firstController, secondController]
		var factoryCallCount = 0
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath,
			codexControllerFactory: { _, _, _, _, _, _ in
				defer { factoryCallCount += 1 }
				return controllers[min(factoryCallCount, controllers.count - 1)]
			},
			testCodexStallWatchdogPollIntervalNanos: 20_000_000,
			testCodexStallWatchdogProbeThreshold: 1,
			testCodexStallWatchdogRecoveryThreshold: 2
		)

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.selectedModel = .codexHigh

		await vm.startAgentRun(tabID: tabID, initialMessage: "watchdog me")
		let started = await waitForCondition(timeoutSeconds: 2.0) {
			firstController.startOrResumeCallCount == 1 && firstController.sendUserMessageCallCount == 1
		}
		XCTAssertTrue(started)

		let invocationID = UUID()
		firstController.emit(.toolCall(
			name: "search",
			invocationID: invocationID,
			argsJSON: #"{"query":"swift watchdog"}"#
		))

		let renderedToolCall = await waitForCondition(timeoutSeconds: 2.0) {
			session.items.contains(where: {
				$0.kind == .toolCall
					&& $0.toolInvocationID == invocationID
					&& $0.toolName == "search"
			})
		}
		XCTAssertTrue(renderedToolCall)

		let stayedRunning = await waitForCondition(timeoutSeconds: 4.5) {
			firstController.readThreadSnapshotCallCount >= 2
				&& secondController.startOrResumeCallCount == 0
				&& session.runState == .running
				&& !session.codexNeedsReconnect
		}
		XCTAssertTrue(
			stayedRunning,
			"The watchdog should keep probing, but avoid recovery while a non-RepoPrompt tool remains in flight and probes still show tool-running activity (probeCount=\(firstController.readThreadSnapshotCallCount), recoveryStarts=\(secondController.startOrResumeCallCount), runState=\(session.runState), needsReconnect=\(session.codexNeedsReconnect))"
		)
		XCTAssertFalse(self.hasCodexStallTimeoutWarning(session), "Soft native-tool liveness corroboration should defer without surfacing a stall warning")

		firstController.emit(.toolResult(
			name: "search",
			invocationID: invocationID,
			argsJSON: #"{"query":"swift watchdog"}"#,
			resultJSON: #"{"results":[]}"#,
			isError: false
		))
		firstController.emit(.turnCompleted(turnID: nil, status: .completed))
		let completed = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .completed
		}
		XCTAssertTrue(
			completed,
			"Expected cleanup turn completion after native tool suppression test (runState=\(session.runState), recoveryStarts=\(secondController.startOrResumeCallCount), probeCount=\(firstController.readThreadSnapshotCallCount))"
		)
	}

	func testStallWatchdogIgnoresStaleRunningBashTranscriptWithoutLiveLivenessState() async {
		let firstController = FakeCodexController()
		firstController.queuedThreadSnapshots = [makeIdleThreadSnapshot()]
		let secondController = FakeCodexController()
		let controllers = [firstController, secondController]
		var factoryCallCount = 0
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath,
			codexControllerFactory: { _, _, _, _, _, _ in
				defer { factoryCallCount += 1 }
				return controllers[min(factoryCallCount, controllers.count - 1)]
			},
			testCodexStallWatchdogPollIntervalNanos: 20_000_000,
			testCodexStallWatchdogProbeThreshold: 1,
			testCodexStallWatchdogRecoveryThreshold: 2
		)

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.selectedModel = .codexHigh

		await vm.startAgentRun(tabID: tabID, initialMessage: "watchdog me")
		let started = await waitForCondition(timeoutSeconds: 2.0) {
			firstController.startOrResumeCallCount == 1 && firstController.sendUserMessageCallCount == 1
		}
		XCTAssertTrue(started)

		var staleRunningItem = AgentChatItem.toolResult(
			name: "bash",
			invocationID: nil,
			resultJSON: #"{"type":"commandExecution","status":"running","command":"sleep 30","processId":"999999"}"#,
			isError: false,
			sequenceIndex: session.nextSequenceIndex
		)
		staleRunningItem.toolArgsJSON = #"{"command":"sleep 30"}"#
		session.appendItem(staleRunningItem)

		let warned = await waitForCondition(timeoutSeconds: 3.5) {
			firstController.readThreadSnapshotCallCount == 1
				&& firstController.readThreadSnapshotIncludeTurnsValues == [false]
				&& secondController.startOrResumeCallCount == 0
				&& secondController.sendUserMessageCallCount == 0
				&& session.runState == .running
				&& !session.codexNeedsReconnect
				&& session.codexWatchdogState.isPausedAfterWarning
				&& self.hasCodexStallTimeoutWarning(session)
		}
		XCTAssertTrue(
			warned,
			"A stale running bash transcript item without current liveness state should not keep suppressing the watchdog; it should eventually warn"
		)
		await vm.cancelAgentRun(tabID: tabID)
	}

	func testStallWatchdogSuppressesWarningWhenRepoPromptToolBecomesActiveDuringProbeThenWarnsLater() async {
		let firstController = FakeCodexController()
		firstController.shouldBlockReadThreadSnapshot = true
		firstController.queuedThreadSnapshots = [
			makeIdleThreadSnapshot(),
			makeIdleThreadSnapshot()
		]
		let secondController = FakeCodexController()
		let controllers = [firstController, secondController]
		var factoryCallCount = 0
		let hasActiveToolExecutions = LockedBool(false)
		let queriedRunIDs = LockedUUIDArray()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath,
			codexControllerFactory: { _, _, _, _, _, _ in
				defer { factoryCallCount += 1 }
				return controllers[min(factoryCallCount, controllers.count - 1)]
			},
			testCodexActiveToolQuery: { runID in
				queriedRunIDs.append(runID)
				return hasActiveToolExecutions.get()
			},
			testCodexStallWatchdogPollIntervalNanos: 20_000_000,
			testCodexStallWatchdogProbeThreshold: 1,
			testCodexStallWatchdogRecoveryThreshold: 2
		)

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.selectedModel = .codexHigh

		await vm.startAgentRun(tabID: tabID, initialMessage: "watchdog me")
		let started = await waitForCondition(timeoutSeconds: 2.0) {
			firstController.startOrResumeCallCount == 1 && firstController.sendUserMessageCallCount == 1
		}
		XCTAssertTrue(started)
		guard let expectedRunID = session.runID else {
			XCTFail("Expected active run ID")
			return
		}

		let probeStarted = await waitForCondition(timeoutSeconds: 2.0) {
			firstController.readThreadSnapshotCallCount == 1
		}
		XCTAssertTrue(probeStarted, "Expected the watchdog to begin a thread/read probe")

		let progressBeforeUnblock = session.codexWatchdogState.lastProgressAt
		hasActiveToolExecutions.set(true)
		firstController.shouldBlockReadThreadSnapshot = false
		firstController.unblockReadThreadSnapshot()

		let suppressed = await waitForCondition(timeoutSeconds: 2.0) {
			firstController.readThreadSnapshotCallCount == 1
				&& secondController.startOrResumeCallCount == 0
				&& session.runState == .running
				&& !session.codexNeedsReconnect
				&& (session.codexWatchdogState.lastProgressAt ?? .distantPast) > (progressBeforeUnblock ?? .distantPast)
		}
		XCTAssertTrue(suppressed, "A RepoPrompt tool that becomes active during the probe should suppress immediate recovery")

		try? await Task.sleep(nanoseconds: 400_000_000)
		XCTAssertEqual(firstController.readThreadSnapshotCallCount, 1, "Probe-time tool activity should reset the inactivity window")

		hasActiveToolExecutions.set(false)
		let warned = await waitForCondition(timeoutSeconds: 5.0) {
			firstController.readThreadSnapshotCallCount >= 2
				&& secondController.startOrResumeCallCount == 0
				&& secondController.sendUserMessageCallCount == 0
				&& session.runState == .running
				&& !session.codexNeedsReconnect
				&& session.codexWatchdogState.isPausedAfterWarning
				&& self.hasCodexStallTimeoutWarning(session)
		}
		XCTAssertTrue(warned, "Once probe-time tool activity clears, the watchdog should return to normal probe/warning behavior")
		let queriedRunIDsSnapshot = queriedRunIDs.snapshot()
		XCTAssertFalse(queriedRunIDsSnapshot.isEmpty)
		XCTAssertTrue(queriedRunIDsSnapshot.allSatisfy { $0 == expectedRunID }, "Active-tool checks should always use the current run ID")
		await vm.cancelAgentRun(tabID: tabID)
	}

	func testNativeCodexEventsRestartWatchdogAfterStallWarning() async {
		let fakeController = FakeCodexController()
		fakeController.cancelKeepsThreadAlive = true
		fakeController.queuedThreadSnapshots = [makeIdleThreadSnapshot()]
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath,
			codexControllerFactory: { _, _, _, _, _, _ in
				fakeController
			},
			testCodexStallWatchdogPollIntervalNanos: 20_000_000,
			testCodexStallWatchdogProbeThreshold: 1,
			testCodexStallWatchdogRecoveryThreshold: 2
		)

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.selectedModel = .codexHigh

		await vm.startAgentRun(tabID: tabID, initialMessage: "watchdog me")
		let started = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.startOrResumeCallCount == 1 && fakeController.sendUserMessageCallCount == 1
		}
		XCTAssertTrue(started)

		let warned = await waitForCondition(timeoutSeconds: 3.5) {
			fakeController.readThreadSnapshotCallCount == 1
				&& session.codexWatchdogState.isPausedAfterWarning
				&& self.hasCodexStallTimeoutWarning(session)
		}
		XCTAssertTrue(warned, "Expected the watchdog to pause itself after surfacing the stall warning")

		let probeCountAtWarning = fakeController.readThreadSnapshotCallCount
		fakeController.emit(.assistantDelta("still alive"))

		let resumedAfterNativeEvent = await waitForCondition(timeoutSeconds: 2.0) {
			!session.codexWatchdogState.isPausedAfterWarning
				&& !session.codexWatchdogState.warnedSinceLastProgress
				&& !session.codexWatchdogState.requiresColdTeardownOnCancel
				&& session.items.contains(where: {
					$0.kind == .assistant
						&& $0.text.contains("still alive")
				})
		}
		XCTAssertTrue(resumedAfterNativeEvent, "A native Codex event should clear the paused-after-warning state")

		try? await Task.sleep(nanoseconds: 400_000_000)
		XCTAssertEqual(fakeController.readThreadSnapshotCallCount, probeCountAtWarning, "Fresh native progress should reset the watchdog clock after a warning")

		let reprobedAfterNativeEvent = await waitForCondition(timeoutSeconds: 3.0) {
			fakeController.readThreadSnapshotCallCount == probeCountAtWarning + 1
				&& session.runState == .running
				&& !session.codexNeedsReconnect
				&& !session.codexWatchdogState.isPausedAfterWarning
				&& !session.codexWatchdogState.warnedSinceLastProgress
				&& !session.codexWatchdogState.requiresColdTeardownOnCancel
		}
		XCTAssertTrue(reprobedAfterNativeEvent, "Native Codex events should restart the watchdog once progress resumes after a warning")
		await vm.cancelAgentRun(tabID: tabID)
		XCTAssertFalse(session.codexNeedsReconnect, "Once native progress returns after the warning, a later stop should not force a reconnect")
		XCTAssertEqual(fakeController.shutdownCallCount, 0, "Once native progress returns after the warning, stop should not tear down the live Codex session")
	}

	func testCancelAfterStallWarningTearsDownCodexSessionAndReconnectsCold() async {
		let firstController = FakeCodexController()
		firstController.queuedThreadSnapshots = [makeIdleThreadSnapshot()]
		let secondController = FakeCodexController()
		let controllers = [firstController, secondController]
		var factoryCallCount = 0
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath,
			codexControllerFactory: { _, _, _, _, _, _ in
				defer { factoryCallCount += 1 }
				return controllers[min(factoryCallCount, controllers.count - 1)]
			},
			testCodexStallWatchdogPollIntervalNanos: 20_000_000,
			testCodexStallWatchdogProbeThreshold: 1,
			testCodexStallWatchdogRecoveryThreshold: 2
		)

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.selectedModel = .codexHigh

		await vm.startAgentRun(tabID: tabID, initialMessage: "watchdog me")
		let started = await waitForCondition(timeoutSeconds: 2.0) {
			firstController.startOrResumeCallCount == 1 && firstController.sendUserMessageCallCount == 1
		}
		XCTAssertTrue(started)

		let warned = await waitForCondition(timeoutSeconds: 3.5) {
			firstController.readThreadSnapshotCallCount == 1
				&& session.codexWatchdogState.isPausedAfterWarning
				&& session.codexWatchdogState.requiresColdTeardownOnCancel
				&& self.hasCodexStallTimeoutWarning(session)
		}
		XCTAssertTrue(warned, "Expected the watchdog to pause itself after surfacing the stall warning")

		await vm.cancelAgentRun(tabID: tabID)
		let tornDown = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .cancelled
				&& firstController.shutdownCallCount == 1
				&& session.codexController == nil
				&& session.codexEventTask == nil
				&& session.codexNeedsReconnect
				&& session.codexConversationID == "test-thread"
		}
		XCTAssertTrue(tornDown, "Stopping after a stall warning should tear down the live Codex session and mark reconnect needed")

		await vm.startAgentRun(tabID: tabID, initialMessage: "resume after stall stop")
		let restartedCold = await waitForCondition(timeoutSeconds: 2.0) {
			secondController.startOrResumeCallCount == 1
				&& secondController.sendUserMessageCallCount == 1
				&& secondController.startOrResumeExistingRefs.first??.conversationID == "test-thread"
		}
		XCTAssertTrue(restartedCold, "The next send should reconnect from cold using the stored conversation metadata")
	}

	func testRepoPromptToolCallbacksRestartWatchdogAfterStallWarning() async {
		let fakeController = FakeCodexController()
		fakeController.cancelKeepsThreadAlive = true
		fakeController.queuedThreadSnapshots = [makeIdleThreadSnapshot()]
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath,
			codexControllerFactory: { _, _, _, _, _, _ in
				fakeController
			},
			testCodexStallWatchdogPollIntervalNanos: 20_000_000,
			testCodexStallWatchdogProbeThreshold: 1,
			testCodexStallWatchdogRecoveryThreshold: 2
		)

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.selectedModel = .codexHigh

		await vm.startAgentRun(tabID: tabID, initialMessage: "watchdog me")
		let started = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.startOrResumeCallCount == 1 && fakeController.sendUserMessageCallCount == 1
		}
		XCTAssertTrue(started)

		let warned = await waitForCondition(timeoutSeconds: 3.5) {
			fakeController.readThreadSnapshotCallCount == 1
				&& session.codexWatchdogState.isPausedAfterWarning
				&& self.hasCodexStallTimeoutWarning(session)
		}
		XCTAssertTrue(warned, "Expected the watchdog to pause itself after surfacing the stall warning")

		let probeCountAtWarning = fakeController.readThreadSnapshotCallCount
		let invocationID = UUID()
		let toolArgs: [String: Value] = ["path": .string("README.md")]
		vm.testSimulateCodexRepoPromptToolCall(
			tabID: tabID,
			invocationID: invocationID,
			toolName: "mcp__RepoPrompt__read_file",
			args: toolArgs
		)

		let resumed = await waitForCondition(timeoutSeconds: 2.0) {
			!session.codexWatchdogState.isPausedAfterWarning
				&& !session.codexWatchdogState.warnedSinceLastProgress
				&& !session.codexWatchdogState.requiresColdTeardownOnCancel
				&& session.items.contains(where: {
					$0.kind == .toolCall
						&& $0.toolInvocationID == invocationID
						&& $0.toolName == "mcp__RepoPrompt__read_file"
				})
		}
		XCTAssertTrue(resumed, "A RepoPrompt tool callback should clear the paused-after-warning state and render the tool call immediately")

		try? await Task.sleep(nanoseconds: 400_000_000)
		XCTAssertEqual(fakeController.readThreadSnapshotCallCount, probeCountAtWarning, "Fresh tool progress should reset the watchdog clock after a warning")

		let reprobed = await waitForCondition(timeoutSeconds: 3.0) {
			fakeController.readThreadSnapshotCallCount == probeCountAtWarning + 1
				&& session.runState == .running
				&& !session.codexNeedsReconnect
				&& !session.codexWatchdogState.isPausedAfterWarning
				&& !session.codexWatchdogState.warnedSinceLastProgress
				&& !session.codexWatchdogState.requiresColdTeardownOnCancel
		}
		XCTAssertTrue(reprobed, "RepoPrompt tool callbacks should restart the watchdog once progress resumes after a warning")
		await vm.cancelAgentRun(tabID: tabID)
		XCTAssertFalse(session.codexNeedsReconnect, "Once progress returns after the warning, a later stop should not force a reconnect")
		XCTAssertEqual(fakeController.shutdownCallCount, 0, "Once progress returns after the warning, stop should not tear down the live Codex session")
	}

	func testRepoPromptToolCallbacksResetWatchdogClockWithoutNativeEvents() async {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath,
			codexControllerFactory: { _, _, _, _, _, _ in
				fakeController
			},
			testCodexStallWatchdogPollIntervalNanos: 20_000_000,
			testCodexStallWatchdogProbeThreshold: 1,
			testCodexStallWatchdogRecoveryThreshold: 2
		)

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.selectedModel = .codexHigh

		await vm.startAgentRun(tabID: tabID, initialMessage: "watchdog me")
		let started = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.startOrResumeCallCount == 1 && fakeController.sendUserMessageCallCount == 1
		}
		XCTAssertTrue(started)

		let invocationID = UUID()
		let toolArgs: [String: Value] = ["path": .string("README.md")]

		try? await Task.sleep(nanoseconds: 700_000_000)
		let toolName = "mcp__RepoPrompt__read_file"
		let canonicalToolName = MCPIntegrationHelper.canonicalRepoPromptToolName(toolName) ?? toolName
		let probeCountBeforeCall = fakeController.readThreadSnapshotCallCount
		vm.testSimulateCodexRepoPromptToolCall(
			tabID: tabID,
			invocationID: invocationID,
			toolName: toolName,
			args: toolArgs
		)
		let observedCall = await waitForCondition(timeoutSeconds: 2.0) {
			session.items.contains(where: {
				$0.kind == .toolCall
					&& $0.toolInvocationID == invocationID
					&& (MCPIntegrationHelper.canonicalRepoPromptToolName($0.toolName) ?? $0.toolName) == canonicalToolName
			})
		}
		XCTAssertTrue(observedCall, "Tracker RepoPrompt tool calls should render immediately")
		try? await Task.sleep(nanoseconds: 450_000_000)
		XCTAssertEqual(fakeController.readThreadSnapshotCallCount, probeCountBeforeCall, "RepoPrompt tool-call callbacks should reset the watchdog clock")

		let probeCountBeforeResult = fakeController.readThreadSnapshotCallCount
		vm.testSimulateCodexRepoPromptToolResult(
			tabID: tabID,
			invocationID: invocationID,
			toolName: toolName,
			args: toolArgs,
			resultJSON: #"{"path":"README.md"}"#,
			isError: false
		)
		try? await Task.sleep(nanoseconds: 450_000_000)
		XCTAssertEqual(fakeController.readThreadSnapshotCallCount, probeCountBeforeResult, "RepoPrompt tool-result callbacks should also reset the watchdog clock")

		let deferredProbe = await waitForCondition(timeoutSeconds: 3.0) {
			fakeController.readThreadSnapshotCallCount > probeCountBeforeResult
				&& session.runState == .running
				&& !session.codexNeedsReconnect
		}
		XCTAssertTrue(deferredProbe, "Once tool callbacks go quiet for a full inactivity window, the watchdog should probe again")
	}

	func testAgentToolTrackerBridgeResetsWatchdogClockWithoutNativeEvents() async {
		let fakeController = FakeCodexController()
		var installedPolicyRunIDs: [UUID] = []
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath,
			shouldManageCodexTooling: true,
			codexControllerFactory: { _, _, _, _, _, _ in
				fakeController
			},
			connectionPolicyInstaller: { _, _, _, _, _, _, _, runID, _, _, _, _, _ in
				guard let runID else { return }
				installedPolicyRunIDs.append(runID)
				MCPRoutingWaiter.signalRouted(runID)
			},
			testCodexStallWatchdogPollIntervalNanos: 20_000_000,
			testCodexStallWatchdogProbeThreshold: 3,
			testCodexStallWatchdogRecoveryThreshold: 5
		)

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.selectedModel = .codexHigh

		await vm.startAgentRun(tabID: tabID, initialMessage: "watchdog me")
		let started = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.startOrResumeCallCount == 1
				&& fakeController.sendUserMessageCallCount == 1
				&& session.runID != nil
		}
		XCTAssertTrue(started)
		guard let runID = session.runID else {
			XCTFail("Expected active run ID")
			return
		}

		let observerRegistered = await waitForAsyncCondition(timeoutSeconds: 2.0) {
			await ServerNetworkManager.shared.toolEventObserverCount(for: runID) == 1
		}
		XCTAssertTrue(observerRegistered, "Expected Codex tool tracker to register a real tool-event observer")
		XCTAssertEqual(installedPolicyRunIDs.last, runID)
		let lastNativeEventAt = session.codexLastEventAt
		XCTAssertNotNil(lastNativeEventAt, "Send start should seed the native-event timestamp")

		let invocationID = UUID()
		let toolName = "mcp__RepoPrompt__read_file"
		let canonicalToolName = MCPIntegrationHelper.canonicalRepoPromptToolName(toolName) ?? toolName
		let toolArgs: [String: Value] = ["path": .string("README.md")]
		let resultJSON = #"{"path":"README.md"}"#

		try? await Task.sleep(nanoseconds: 700_000_000)
		let probeCountBeforeCall = fakeController.readThreadSnapshotCallCount
		let progressBeforeCall = session.codexWatchdogState.lastProgressAt
		let calledObserverCount = await ServerNetworkManager.shared.debugFireToolCalledObservers(
			runID: runID,
			invocationID: invocationID,
			toolName: toolName,
			args: toolArgs
		)
		XCTAssertEqual(calledObserverCount, 1, "Expected exactly one real tracker observer to receive the tool-call event")

		let observedCall = await waitForCondition(timeoutSeconds: 2.0) {
			session.items.contains(where: {
				$0.kind == .toolCall
					&& $0.toolInvocationID == invocationID
					&& (MCPIntegrationHelper.canonicalRepoPromptToolName($0.toolName) ?? $0.toolName) == canonicalToolName
			})
				&& (session.codexWatchdogState.lastProgressAt ?? .distantPast) > (progressBeforeCall ?? .distantPast)
		}
		XCTAssertTrue(observedCall, "Tracker-bridge tool calls should render immediately and still advance watchdog progress")
		XCTAssertEqual(session.codexLastEventAt, lastNativeEventAt, "Tool tracker callbacks should not mutate native-event liveness")
		XCTAssertTrue(
			(session.codexWatchdogState.lastProgressAt ?? .distantPast) > (lastNativeEventAt ?? .distantPast),
			"Tracker callbacks should advance watchdog progress beyond the last native event timestamp"
		)

		try? await Task.sleep(nanoseconds: 800_000_000)
		XCTAssertEqual(fakeController.readThreadSnapshotCallCount, probeCountBeforeCall, "A real tracker tool-call callback should reset the watchdog clock")

		let probeCountBeforeResult = fakeController.readThreadSnapshotCallCount
		let progressBeforeResult = session.codexWatchdogState.lastProgressAt
		let completedObserverCount = await ServerNetworkManager.shared.debugFireToolCompletedObservers(
			runID: runID,
			invocationID: invocationID,
			toolName: toolName,
			args: toolArgs,
			resultJSON: resultJSON,
			isError: false
		)
		XCTAssertEqual(completedObserverCount, 1, "Expected exactly one real tracker observer to receive the tool-result event")

		let observedResult = await waitForCondition(timeoutSeconds: 2.0) {
			session.items.contains(where: {
				$0.kind == .toolResult
					&& $0.toolInvocationID == invocationID
					&& (MCPIntegrationHelper.canonicalRepoPromptToolName($0.toolName) ?? $0.toolName) == canonicalToolName
					&& $0.toolResultJSON?.isEmpty == false
			})
				&& (session.codexWatchdogState.lastProgressAt ?? .distantPast) > (progressBeforeResult ?? .distantPast)
		}
		XCTAssertTrue(observedResult, "Tracker-bridge tool results should finalize the transcript item and advance watchdog progress")
		XCTAssertEqual(session.codexLastEventAt, lastNativeEventAt, "Tracker-bridge tool results should still leave native-event liveness untouched")
		XCTAssertTrue(
			(session.codexWatchdogState.lastProgressAt ?? .distantPast) > (lastNativeEventAt ?? .distantPast),
			"Tracker tool results should keep watchdog progress ahead of the native-event clock"
		)

		try? await Task.sleep(nanoseconds: 800_000_000)
		XCTAssertEqual(fakeController.readThreadSnapshotCallCount, probeCountBeforeResult, "A real tracker tool-result callback should also reset the watchdog clock")

		let deferredProbe = await waitForCondition(timeoutSeconds: 5.0) {
			fakeController.readThreadSnapshotCallCount > probeCountBeforeResult
				&& session.runState == .running
				&& !session.codexNeedsReconnect
		}
		XCTAssertTrue(deferredProbe, "Once real tracker activity goes quiet for a full inactivity window, the watchdog should probe again")

		await ServerNetworkManager.shared.unregisterToolObservers(for: runID)
		await vm.cancelAgentRun(tabID: tabID)
		await vm.deleteSession(tabID: tabID)
	}

	func testStallWatchdogWarnsWhenThreadReadShowsNoActiveTurn() async {
		let fakeController = FakeCodexController()
		fakeController.queuedThreadSnapshots = [
			makeThreadSnapshot(
				runtimeStatus: .idle,
				currentTurnID: nil,
				activeTurnIDs: [],
				latestTurnStatus: .completed
			)
		]
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath,
			codexControllerFactory: { _, _, _, _, _, _ in
				fakeController
			},
			testCodexStallWatchdogPollIntervalNanos: 20_000_000,
			testCodexStallWatchdogProbeThreshold: 1,
			testCodexStallWatchdogRecoveryThreshold: 2
		)

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.selectedModel = .codexHigh

		await vm.startAgentRun(tabID: tabID, initialMessage: "watchdog me")
		let started = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.startOrResumeCallCount == 1 && fakeController.sendUserMessageCallCount == 1
		}
		XCTAssertTrue(started)

		let warned = await waitForCondition(timeoutSeconds: 3.0) {
			fakeController.readThreadSnapshotCallCount == 1
				&& session.runState == .running
				&& !session.codexNeedsReconnect
				&& session.codexController != nil
				&& session.codexWatchdogState.isPausedAfterWarning
				&& self.hasCodexStallTimeoutWarning(session)
		}
		XCTAssertTrue(warned, "A watchdog probe that reports no active turn should warn in-stream and leave the run for manual stop/resume")
		try? await Task.sleep(nanoseconds: 400_000_000)
		XCTAssertEqual(fakeController.readThreadSnapshotCallCount, 1, "Once warned, the watchdog should pause instead of continuing to probe")
		await vm.cancelAgentRun(tabID: tabID)
	}

	func testStallWatchdogSuppressesProbeWhileUserInputPendingAndRestartsAfterSubmit() async {
		let fakeController = FakeCodexController()
		fakeController.queuedThreadSnapshots = [makeIdleThreadSnapshot()]
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath,
			codexControllerFactory: { _, _, _, _, _, _ in
				fakeController
			},
			testCodexStallWatchdogPollIntervalNanos: 20_000_000,
			testCodexStallWatchdogProbeThreshold: 1,
			testCodexStallWatchdogRecoveryThreshold: 2
		)

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.selectedModel = .codexHigh

		await vm.startAgentRun(tabID: tabID, initialMessage: "need input")
		let request = makeUserInputRequest(id: "input-1", questionID: "choice")
		fakeController.emit(.requestUserInput(request))
		let pending = await waitForCondition(timeoutSeconds: 2.0) {
			session.pendingUserInputRequest?.requestID == request.requestID
				&& session.runState == .waitingForQuestion
		}
		XCTAssertTrue(pending)

		try? await Task.sleep(nanoseconds: 1_300_000_000)
		XCTAssertEqual(fakeController.readThreadSnapshotCallCount, 0, "Pending Codex user input should suppress watchdog probes")
		XCTAssertFalse(hasCodexStallTimeoutWarning(session))

		vm.submitUserInputResponse(
			tabID: tabID,
			requestID: request.requestID,
			response: AgentRequestUserInputResponse(answersByQuestionID: ["choice": ["Yes"]])
		)
		let restartedAndWarned = await waitForCondition(timeoutSeconds: 3.0) {
			fakeController.respondToServerRequestCallCount == 1
				&& session.pendingUserInputRequest == nil
				&& session.runState == .running
				&& fakeController.readThreadSnapshotCallCount == 1
				&& session.codexWatchdogState.isPausedAfterWarning
				&& self.hasCodexStallTimeoutWarning(session)
		}
		XCTAssertTrue(restartedAndWarned, "After user input clears, the watchdog should restart and preserve no-active-turn warning behavior")
	}

	func testStallWatchdogSuppressesProbeWhileQueuedUserInputExists() async {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath,
			codexControllerFactory: { _, _, _, _, _, _ in
				fakeController
			},
			testCodexStallWatchdogPollIntervalNanos: 20_000_000,
			testCodexStallWatchdogProbeThreshold: 1,
			testCodexStallWatchdogRecoveryThreshold: 2
		)

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.selectedModel = .codexHigh

		await vm.startAgentRun(tabID: tabID, initialMessage: "need input")
		let first = makeUserInputRequest(id: "input-1", questionID: "first")
		let second = makeUserInputRequest(id: "input-2", questionID: "second")
		fakeController.emit(.requestUserInput(first))
		fakeController.emit(.requestUserInput(second))
		let queued = await waitForCondition(timeoutSeconds: 2.0) {
			session.pendingUserInputRequest?.requestID == first.requestID
				&& session.queuedUserInputRequests.map(\.requestID) == [second.requestID]
		}
		XCTAssertTrue(queued)

		try? await Task.sleep(nanoseconds: 1_300_000_000)
		XCTAssertEqual(fakeController.readThreadSnapshotCallCount, 0, "Queued Codex user input should suppress watchdog probes")
		XCTAssertFalse(hasCodexStallTimeoutWarning(session))
	}

	func testStallWatchdogTreatsWaitingUserInputActiveSnapshotAsLiveness() async {
		let fakeController = FakeCodexController()
		fakeController.queuedThreadSnapshots = [
			makeThreadSnapshot(runtimeStatus: .active(activeFlags: ["waitingOnUserInput"]))
		]
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath,
			codexControllerFactory: { _, _, _, _, _, _ in
				fakeController
			},
			testCodexStallWatchdogPollIntervalNanos: 20_000_000,
			testCodexStallWatchdogProbeThreshold: 1,
			testCodexStallWatchdogRecoveryThreshold: 2
		)

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.selectedModel = .codexHigh

		await vm.startAgentRun(tabID: tabID, initialMessage: "active flag")
		let activeProbe = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.readThreadSnapshotCallCount >= 1
				&& session.runningStatusText == "Codex reports it is waiting for user input…"
				&& !session.codexWatchdogState.isPausedAfterWarning
				&& !self.hasCodexStallTimeoutWarning(session)
		}
		XCTAssertTrue(activeProbe, "Active snapshots with waiting flags should count as liveness instead of warning")
	}

	func testCodexLivenessActivityResetsWatchdogWithoutTranscriptNoise() async {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath,
			codexControllerFactory: { _, _, _, _, _, _ in
				fakeController
			},
			testCodexStallWatchdogPollIntervalNanos: 20_000_000,
			testCodexStallWatchdogProbeThreshold: 1,
			testCodexStallWatchdogRecoveryThreshold: 2
		)

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.selectedModel = .codexHigh

		await vm.startAgentRun(tabID: tabID, initialMessage: "liveness")
		let started = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.sendUserMessageCallCount == 1
		}
		XCTAssertTrue(started)
		let itemCountBefore = session.items.count
		let progressBefore = session.codexWatchdogState.lastProgressAt

		try? await Task.sleep(nanoseconds: 700_000_000)
		fakeController.emit(.livenessActivity(.init(
			kind: .turnPlanUpdated,
			method: "turn/plan/updated",
			threadID: "test-thread",
			turnID: "turn-1",
			itemID: nil,
			activeFlags: [],
			message: nil
		)))

		let progressed = await waitForCondition(timeoutSeconds: 2.0) {
			(session.codexWatchdogState.lastProgressAt ?? .distantPast) > (progressBefore ?? .distantPast)
				&& session.items.count == itemCountBefore
		}
		XCTAssertTrue(progressed, "Liveness-only events should advance watchdog progress without transcript rows")
		try? await Task.sleep(nanoseconds: 500_000_000)
		XCTAssertEqual(fakeController.readThreadSnapshotCallCount, 0, "Liveness-only activity should reset the probe window")
	}

	func testRetryableStructuredErrorDoesNotFinalizeRun() async {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.selectedModel = .codexHigh

		await vm.startAgentRun(tabID: tabID, initialMessage: "retryable")
		fakeController.emit(.errorNotification(.init(
			message: "Temporary Codex error; retrying…",
			willRetry: true,
			threadID: "test-thread",
			turnID: "turn-1"
		)))

		let keptRunning = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .running
				&& session.runningStatusText == "Temporary Codex error; retrying…"
				&& !session.items.contains(where: { $0.kind == .error && $0.text.contains("Temporary Codex error") })
		}
		XCTAssertTrue(keptRunning, "Retryable structured errors should be liveness/status, not terminal failure")
	}

	func testNonRetryableStructuredErrorFinalizesRun() async {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.selectedModel = .codexHigh

		await vm.startAgentRun(tabID: tabID, initialMessage: "nonretryable")
		fakeController.emit(.errorNotification(.init(
			message: "Fatal Codex error; will retry flag is false",
			willRetry: false,
			threadID: "test-thread",
			turnID: "turn-1"
		)))

		let failed = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .failed
				&& session.items.contains(where: { $0.kind == .error && $0.text.contains("Fatal Codex error") })
		}
		XCTAssertTrue(failed, "Nonretryable structured errors should preserve terminal failure behavior even when the message text looks retryable")
	}

	func testIdleShutdownTimerShutsDownCompletedCodexSession() async {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath,
			codexControllerFactory: { _, _, _, _, _, _ in
				fakeController
			},
			testCodexIdleShutdownDelayNanos: 25_000_000
		)

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.selectedModel = .codexHigh

		await vm.startAgentRun(tabID: tabID, initialMessage: "first turn")
		let started = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.startOrResumeCallCount == 1 && fakeController.sendUserMessageCallCount == 1
		}
		XCTAssertTrue(started)

		fakeController.emit(.turnCompleted(turnID: nil, status: .completed))
		let completed = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .completed
		}
		XCTAssertTrue(completed)

		let idleShutdownApplied = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.shutdownCallCount >= 1
				&& session.codexNeedsReconnect
				&& session.codexController == nil
				&& session.codexEventTask == nil
				&& session.runState == .completed
		}
		XCTAssertTrue(idleShutdownApplied, "Idle timeout should shutdown controller between turns and preserve completed state")
	}

	func testReconnectingErrorKeepsCodexRunActive() async {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.selectedModel = .codexHigh

		await vm.startAgentRun(tabID: tabID, initialMessage: "first turn")
		let didSendFirstTurn = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.startOrResumeCallCount == 1
				&& fakeController.sendUserMessageCallCount == 1
		}
		XCTAssertTrue(didSendFirstTurn, "Expected initial Codex turn to start before reconnecting error")

		fakeController.emit(.error("Reconnecting... 1/5"))
		let stayedActive = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .running
				&& vm.isTabRunning(tabID)
				&& session.runningStatusText == "Reconnecting... 1/5"
		}
		XCTAssertTrue(stayedActive, "Retriable reconnect errors should keep the run active")
		XCTAssertFalse(
			session.items.contains { $0.kind == .error && $0.text == "Reconnecting... 1/5" },
			"Retriable reconnect errors should not append fatal transcript errors"
		)
	}

	func testCodexToolPreferencesChangeKeepsIdleSessionWarm() async {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec

		await vm.startAgentRun(tabID: tabID, initialMessage: "first turn")
		fakeController.emit(.turnCompleted(turnID: nil, status: .completed))
		let completed = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .completed
		}
		XCTAssertTrue(completed, "Expected first turn to complete")
		XCTAssertNotNil(session.codexController, "Controller should exist after first turn")

		let conversationID = session.codexConversationID
		let rolloutPath = session.codexRolloutPath
		let generationBefore = session.codexToolPreferencesGeneration

		vm.providerPreferenceDidChange(.codex)
		let updated = await waitForCondition(timeoutSeconds: 2.0) {
			session.codexToolPreferencesGeneration == generationBefore + 1
		}
		XCTAssertTrue(updated, "Preference changes should still advance the Codex tool-preference generation")
		XCTAssertTrue(session.codexNeedsReconnect, "Preference changes should mark reconnect needed so the next turn refreshes thread-level Codex config")
		XCTAssertNotNil(session.codexController, "Idle preference changes should not tear down the live controller")
		XCTAssertEqual(fakeController.startOrResumeCallCount, 1, "Idle preference changes should not restart Codex immediately")
		XCTAssertEqual(session.codexConversationID, conversationID, "Conversation ID should be preserved for the next turn")
		XCTAssertEqual(session.codexRolloutPath, rolloutPath, "Rollout path should be preserved for the next turn")
	}

	func testCodexReconnectFromWarmControllerCreatesFreshControllerBeforeFollowUp() async {
		let firstController = FakeCodexController()
		let secondController = FakeCodexController()
		var factoryCallCount = 0
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath,
			codexControllerFactory: { _, _, _, _, _, _ in
				defer { factoryCallCount += 1 }
				return factoryCallCount == 0 ? firstController : secondController
			}
		)

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec

		await vm.startAgentRun(tabID: tabID, initialMessage: "first turn")
		let firstTurnStarted = await waitForCondition(timeoutSeconds: 2.0) {
			firstController.startOrResumeCallCount == 1
				&& firstController.sendUserMessageCallCount == 1
		}
		XCTAssertTrue(firstTurnStarted, "Expected initial Codex turn to start")

		firstController.emit(.turnCompleted(turnID: nil, status: .completed))
		let completed = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .completed
		}
		XCTAssertTrue(completed, "Expected first turn to complete")
		let firstRunID = try? XCTUnwrap(session.runID)
		let preservedConversationID = session.codexConversationID
		let preservedRolloutPath = session.codexRolloutPath

		vm.providerPreferenceDidChange(.codex)
		let reconnectMarked = await waitForCondition(timeoutSeconds: 2.0) {
			session.codexNeedsReconnect
				&& session.codexController.map { ObjectIdentifier($0 as AnyObject) } == ObjectIdentifier(firstController)
		}
		XCTAssertTrue(reconnectMarked, "Preference changes should mark reconnect without tearing down the warm controller")

		await vm.startAgentRun(tabID: tabID, initialMessage: "follow-up turn")
		let followUpStarted = await waitForCondition(timeoutSeconds: 2.0) {
			factoryCallCount == 2
				&& firstController.shutdownCallCount == 1
				&& firstController.startOrResumeCallCount == 1
				&& secondController.startOrResumeCallCount == 1
				&& secondController.sendUserMessageCallCount == 1
				&& !session.codexNeedsReconnect
				&& session.codexController.map { ObjectIdentifier($0 as AnyObject) } == ObjectIdentifier(secondController)
		}
		XCTAssertTrue(followUpStarted, "Reconnect follow-up should rotate to a fresh controller before starting/resuming")
		XCTAssertEqual(secondController.startOrResumeExistingRefs.count, 1)
		XCTAssertEqual(secondController.startOrResumeExistingRefs[0]?.conversationID, preservedConversationID)
		XCTAssertEqual(secondController.startOrResumeExistingRefs[0]?.rolloutPath, preservedRolloutPath)
		if let firstRunID {
			XCTAssertNotEqual(session.runID, firstRunID, "Reconnect should mint a fresh run ID when rotating controllers")
		}
		XCTAssertFalse(
			session.items.contains(where: { $0.kind == .error && $0.text.contains("already active") }),
			"Reconnect should not surface an active-controller lifecycle error to the transcript"
		)
	}

	func testCodexToolPreferencesChangeAvoidsDirtyReconnectMutation() async {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec

		await vm.startAgentRun(tabID: tabID, initialMessage: "first turn")
		fakeController.emit(.turnCompleted(turnID: nil, status: .completed))
		let completed = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .completed
		}
		XCTAssertTrue(completed)

		session.isDirty = false
		let generationBefore = session.codexToolPreferencesGeneration
		vm.providerPreferenceDidChange(.codex)
		let updated = await waitForCondition(timeoutSeconds: 2.0) {
			session.codexToolPreferencesGeneration == generationBefore + 1
		}
		XCTAssertTrue(updated)
		XCTAssertTrue(session.codexNeedsReconnect, "Preference changes should mark reconnect needed even for idle Codex sessions")
		XCTAssertFalse(session.isDirty, "The generation bump is ephemeral session state and should not force persistence by itself")
	}

	func testCodexToolPreferencesChangeDuringActiveRunMarksReconnectNeeded() async {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec

		await vm.startAgentRun(tabID: tabID, initialMessage: "first turn")
		let running = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .running
		}
		XCTAssertTrue(running, "Expected Codex run to be active before changing preferences")
		XCTAssertEqual(fakeController.startOrResumeCallCount, 1)

		let generationBefore = session.codexToolPreferencesGeneration
		vm.providerPreferenceDidChange(.codex)

		let updated = await waitForCondition(timeoutSeconds: 2.0) {
			session.codexToolPreferencesGeneration == generationBefore + 1
		}
		XCTAssertTrue(updated)
		XCTAssertTrue(session.codexNeedsReconnect, "Active preference changes should force reconnect before the next turn so thread-level config updates apply")
		XCTAssertEqual(fakeController.startOrResumeCallCount, 1, "Preference changes should not restart the active Codex run immediately")
	}

	func testCodexReconnectMarkedDuringActiveRunDefersUntilThreadGoesIdle() async {
		let firstController = FakeCodexController()
		let secondController = FakeCodexController()
		var factoryCallCount = 0
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath,
			codexControllerFactory: { _, _, _, _, _, _ in
				defer { factoryCallCount += 1 }
				return factoryCallCount == 0 ? firstController : secondController
			}
		)

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec

		await vm.startAgentRun(tabID: tabID, initialMessage: "first turn")
		let started = await waitForCondition(timeoutSeconds: 2.0) {
			firstController.startOrResumeCallCount == 1
				&& firstController.sendUserMessageCallCount == 1
				&& session.runState == .running
		}
		XCTAssertTrue(started, "Expected initial Codex turn to start")

		vm.providerPreferenceDidChange(.codex)
		let reconnectMarked = await waitForCondition(timeoutSeconds: 2.0) {
			session.codexNeedsReconnect
		}
		XCTAssertTrue(reconnectMarked, "Preference changes during an active run should mark reconnect")

		let steerResult = vm.test_submitUserTurn(tabID: tabID, text: "steer now")
		XCTAssertEqual(steerResult, .submitted)
		let steerSent = await waitForCondition(timeoutSeconds: 2.0) {
			firstController.sendUserMessageCallCount == 2
				&& firstController.startOrResumeCallCount == 1
				&& firstController.shutdownCallCount == 0
				&& factoryCallCount == 1
				&& session.codexController.map { ObjectIdentifier($0 as AnyObject) } == ObjectIdentifier(firstController)
				&& session.codexNeedsReconnect
		}
		XCTAssertTrue(steerSent, "Steering an active Codex thread should defer reconnect and keep using the current controller")

		firstController.emit(.turnCompleted(turnID: nil, status: .completed))
		let completed = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .completed
		}
		XCTAssertTrue(completed, "Expected active thread to go idle after completion")

		await vm.startAgentRun(tabID: tabID, initialMessage: "follow-up turn")
		let reconnectedAfterIdle = await waitForCondition(timeoutSeconds: 2.0) {
			firstController.shutdownCallCount == 1
				&& factoryCallCount == 2
				&& secondController.startOrResumeCallCount == 1
				&& secondController.sendUserMessageCallCount == 1
				&& !session.codexNeedsReconnect
		}
		XCTAssertTrue(reconnectedAfterIdle, "Once the active thread is idle, the next turn should reconnect on a fresh controller")
	}

	func testCodexInitFailureThenRetryReinstallsPolicyAndRecovers() async {
		let fakeController = FakeCodexController()
		fakeController.startOrResumeFailuresRemaining = 1
		var policyCalls: [CodexPolicyInstallCall] = []
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath,
			shouldManageCodexTooling: true,
			codexControllerFactory: { _, _, _, _, _, _ in
				fakeController
			},
			connectionPolicyInstaller: { clientName, windowID, restrictedTools, oneShot, reason, ttl, tabID, runID, additionalTools, purpose, _, _, _ in
				policyCalls.append(
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
				if let runID {
					MCPRoutingWaiter.signalRouted(runID)
				}
			}
		)

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec

		await vm.startAgentRun(tabID: tabID, initialMessage: "first turn")
		let firstFailureObserved = await waitForCondition(timeoutSeconds: 2.0) {
			session.codexNeedsReconnect && fakeController.startOrResumeCallCount == 1
		}
		XCTAssertTrue(firstFailureObserved, "Expected first startOrResume failure to mark reconnect")
		XCTAssertEqual(fakeController.sendUserMessageCallCount, 0, "Send should fail before a thread is active")
		let firstErrorItems = session.items.filter { $0.kind == .error }
		XCTAssertEqual(firstErrorItems.count, 1, "Start failure should not add an extra send error when no thread is active")
		XCTAssertTrue(firstErrorItems.first?.text.hasPrefix("Codex native start failed:") == true)
		XCTAssertEqual(policyCalls.count, 1, "Expected policy install before first Codex start")

		await vm.startAgentRun(tabID: tabID, initialMessage: "retry turn")
		let retryStarted = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.startOrResumeCallCount == 2
				&& fakeController.sendUserMessageCallCount == 1
				&& session.codexNeedsReconnect == false
		}
		XCTAssertTrue(retryStarted, "Expected retry to start Codex session and send user turn")

		fakeController.emit(.turnCompleted(turnID: nil, status: .completed))
		let completed = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .completed
		}
		XCTAssertTrue(completed, "Expected retry turn to complete")

		XCTAssertEqual(policyCalls.count, 2, "Policy should be installed for both failed and retry starts")
		for call in policyCalls {
			XCTAssertEqual(call.clientName, DiscoverAgentKind.codexExec.mcpClientNameHint)
			XCTAssertEqual(call.windowID, 1)
			XCTAssertEqual(call.restrictedTools, AgentModeMCPToolPolicy.restrictedTools)
			XCTAssertTrue(call.oneShot)
			XCTAssertEqual(call.reason, "agent-mode-run")
			XCTAssertEqual(call.ttl, AgentModeMCPPolicyInstaller.policyTTL, accuracy: 0.001)
			XCTAssertEqual(call.tabID, tabID)
			XCTAssertEqual(call.additionalTools, AgentModeMCPToolPolicy.codexNativeGrantedTools)
			XCTAssertEqual(call.purpose, .agentModeRun)
		}
		guard let firstRunID = policyCalls.first?.runID else {
			return XCTFail("Expected first start attempt to install a run policy")
		}
		guard let retryRunID = policyCalls.last?.runID else {
			return XCTFail("Expected retry to install a run policy")
		}
		XCTAssertEqual(firstRunID, retryRunID, "Retry should preserve the existing Codex run ID when the failed bootstrap did not rotate the underlying session")
		XCTAssertEqual(session.runID, retryRunID)
	}

	func testCodexResumeTimeoutMarksReconnectAndSurfacesResumeFailure() async {
		let fakeController = FakeCodexController()
		fakeController.startOrResumeErrorDescriptions = ["Request timed out after 120.0s"]
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.appendItem(.assistant("previous reply", sequenceIndex: session.nextSequenceIndex))
		session.codexNeedsReconnect = true
		session.codexConversationID = "stale-thread"
		session.codexRolloutPath = "/tmp/stale-rollout.jsonl"

		await vm.startAgentRun(tabID: tabID, initialMessage: "retry now")
		let failed = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.startOrResumeCallCount == 1
				&& fakeController.sendUserMessageCallCount == 0
				&& session.codexNeedsReconnect
		}
		XCTAssertTrue(failed, "A timed-out resume should fail the send and leave reconnect required")
		XCTAssertEqual(fakeController.startOrResumeExistingRefs.count, 1)
		XCTAssertEqual(fakeController.startOrResumeExistingRefs[0]?.conversationID, "stale-thread")
		XCTAssertEqual(fakeController.startOrResumeExistingRefs[0]?.rolloutPath, "/tmp/stale-rollout.jsonl")
		XCTAssertTrue(
			session.items.contains(where: {
				$0.kind == .error &&
					$0.text == "Codex native resume failed: Request timed out after 120.0s"
			}),
			"The first timed-out reconnect should be labeled as a resume failure"
		)
	}

	func testRepeatedCodexResumeTimeoutRetriesFreshThreadStartOnSecondUserRetry() async {
		let firstResumeController = FakeCodexController()
		firstResumeController.startOrResumeErrorDescriptions = ["Request timed out after 120.0s"]
		let secondResumeController = FakeCodexController()
		secondResumeController.startOrResumeErrorDescriptions = ["Request timed out after 120.0s"]
		let freshStartController = FakeCodexController()
		let controllers = [firstResumeController, secondResumeController, freshStartController]
		var factoryCallCount = 0
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			let index = min(factoryCallCount, controllers.count - 1)
			factoryCallCount += 1
			return controllers[index]
		}

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.appendItem(.assistant("previous reply", sequenceIndex: session.nextSequenceIndex))
		session.codexNeedsReconnect = true
		session.codexConversationID = "stale-thread"
		session.codexRolloutPath = "/tmp/stale-rollout.jsonl"

		await vm.startAgentRun(tabID: tabID, initialMessage: "retry once")
		let firstFailure = await waitForCondition(timeoutSeconds: 2.0) {
			firstResumeController.startOrResumeCallCount == 1
				&& firstResumeController.sendUserMessageCallCount == 0
				&& session.codexNeedsReconnect
		}
		XCTAssertTrue(firstFailure, "The first timed-out resume should not immediately fresh-start")

		await vm.startAgentRun(tabID: tabID, initialMessage: "retry twice")
		let recovered = await waitForCondition(timeoutSeconds: 2.0) {
			secondResumeController.startOrResumeCallCount == 1
				&& freshStartController.startOrResumeCallCount == 1
				&& freshStartController.sendUserMessageCallCount == 1
				&& session.codexNeedsReconnect == false
		}
		XCTAssertTrue(recovered, "A repeated timeout on the same resume target should retry with a fresh thread start")
		XCTAssertEqual(factoryCallCount, 3)
		XCTAssertEqual(firstResumeController.startOrResumeExistingRefs.count, 1)
		XCTAssertEqual(firstResumeController.startOrResumeExistingRefs[0]?.conversationID, "stale-thread")
		XCTAssertEqual(secondResumeController.startOrResumeExistingRefs.count, 1)
		XCTAssertEqual(secondResumeController.startOrResumeExistingRefs[0]?.conversationID, "stale-thread")
		XCTAssertEqual(freshStartController.startOrResumeExistingRefs.count, 1)
		XCTAssertNil(freshStartController.startOrResumeExistingRefs[0], "Repeated timeout fallback should fresh-start without an existing ref")
		XCTAssertEqual(
			session.items.filter {
				$0.kind == .error &&
					$0.text == "Codex native resume failed: Request timed out after 120.0s"
			}.count,
			1,
			"Successful repeated-timeout fallback should not append another terminal resume failure"
		)
		XCTAssertTrue(
			session.items.contains(where: {
				$0.kind == .system &&
					$0.text.contains("after repeated timeout")
			}),
			"Successful repeated-timeout fallback should surface a recovery notice"
		)
		XCTAssertEqual(session.codexConversationID, "test-thread")
		XCTAssertNil(session.codexRolloutPath)

		freshStartController.emit(.turnCompleted(turnID: nil, status: .completed))
		let completed = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .completed
		}
		XCTAssertTrue(completed)
	}

	func testTimedOutAutomaticRecoveryCountsTowardNextRepeatedResumeFallback() async {
		let firstController = FakeCodexController()
		let recoveryController = FakeCodexController()
		recoveryController.startOrResumeErrorDescriptions = ["Request timed out after 120.0s"]
		let retryResumeController = FakeCodexController()
		retryResumeController.startOrResumeErrorDescriptions = ["Request timed out after 120.0s"]
		let freshStartController = FakeCodexController()
		let controllers = [firstController, recoveryController, retryResumeController, freshStartController]
		var factoryCallCount = 0
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			let index = min(factoryCallCount, controllers.count - 1)
			factoryCallCount += 1
			return controllers[index]
		}

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.selectedModel = .codexHigh

		await vm.startAgentRun(tabID: tabID, initialMessage: "first turn")
		let started = await waitForCondition(timeoutSeconds: 2.0) {
			firstController.startOrResumeCallCount == 1 && firstController.sendUserMessageCallCount == 1
		}
		XCTAssertTrue(started)

		await firstController.shutdown()
		let recoveryFailed = await waitForCondition(timeoutSeconds: 3.0) {
			session.runState == .failed
				&& session.codexNeedsReconnect
				&& recoveryController.startOrResumeCallCount == 1
				&& recoveryController.sendUserMessageCallCount == 0
		}
		XCTAssertTrue(recoveryFailed, "Timed-out automatic recovery should fail the run and leave reconnect required")
		XCTAssertEqual(recoveryController.startOrResumeExistingRefs.first??.conversationID, "test-thread")
		XCTAssertEqual(
			session.items.filter {
				$0.kind == .error &&
					$0.text == "Codex native resume failed: Request timed out after 120.0s"
			}.count,
			1
		)

		await vm.startAgentRun(tabID: tabID, initialMessage: "retry after timed-out recovery")
		let recovered = await waitForCondition(timeoutSeconds: 3.0) {
			retryResumeController.startOrResumeCallCount == 1
				&& freshStartController.startOrResumeCallCount == 1
				&& freshStartController.sendUserMessageCallCount == 1
				&& session.codexNeedsReconnect == false
				&& session.runState == .running
		}
		XCTAssertTrue(recovered, "A timed-out automatic recovery should count toward the next repeated-timeout fresh-start fallback")
		XCTAssertEqual(factoryCallCount, 4)
		XCTAssertEqual(retryResumeController.startOrResumeExistingRefs.first??.conversationID, "test-thread")
		XCTAssertEqual(freshStartController.startOrResumeExistingRefs.count, 1)
		XCTAssertNil(freshStartController.startOrResumeExistingRefs[0])
		XCTAssertEqual(
			session.items.filter {
				$0.kind == .error &&
					$0.text == "Codex native resume failed: Request timed out after 120.0s"
			}.count,
			1,
			"Successful repeated-timeout fallback after an automatic recovery timeout should not append another terminal resume failure"
		)
		XCTAssertTrue(
			session.items.contains(where: {
				$0.kind == .system &&
					$0.text.contains("after repeated timeout")
			}),
			"The eventual fresh-start fallback should surface a recovery notice"
		)

		freshStartController.emit(.turnCompleted(turnID: nil, status: .completed))
		let completed = await waitForCondition(timeoutSeconds: 2.0) {
			session.runState == .completed
		}
		XCTAssertTrue(completed)
	}

	func testBoundColdCodexSessionMintsFreshRunIDBeforePolicyInstall() async {
		let fakeController = FakeCodexController()
		var policyCalls: [CodexPolicyInstallCall] = []
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath,
			shouldManageCodexTooling: true,
			codexControllerFactory: { _, _, _, _, _, _ in
				fakeController
			},
			connectionPolicyInstaller: { clientName, windowID, restrictedTools, oneShot, reason, ttl, tabID, runID, additionalTools, purpose, _, _, _ in
				policyCalls.append(
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
				if let runID {
					MCPRoutingWaiter.signalRouted(runID)
				}
			}
		)

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		let persistedSessionID = UUID()
		session.activeAgentSessionID = persistedSessionID
		session.hasLoadedPersistedState = false
		session.runID = nil
		vm.test_seedSessionIndexEntry(sessionID: persistedSessionID, tabID: tabID)

		await vm.startAgentRun(tabID: tabID, initialMessage: "resume after hydration")
		let didStart = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.sendUserMessageCallCount == 1 && !policyCalls.isEmpty && session.runID != nil
		}
		XCTAssertTrue(didStart, "Expected Codex turn to start")
		guard let activeRunID = session.runID else {
			return XCTFail("Expected Codex turn to mint a live run ID")
		}
		XCTAssertEqual(policyCalls.first?.runID, activeRunID)
	}

	func testCodexResumeWithoutCachedRunPolicyKeepsRunIDAndReinstallsPolicy() async {
		let fakeController = FakeCodexController()
		var policyCalls: [CodexPolicyInstallCall] = []
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath,
			shouldManageCodexTooling: true,
			codexControllerFactory: { _, _, _, _, _, _ in
				fakeController
			},
			connectionPolicyInstaller: { clientName, windowID, restrictedTools, oneShot, reason, ttl, tabID, runID, additionalTools, purpose, _, _, _ in
				policyCalls.append(
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
				if let runID {
					MCPRoutingWaiter.signalRouted(runID)
				}
			}
		)

		let staleRunID = UUID()
		await ServerNetworkManager.shared.cleanupRunRoutingState(for: staleRunID)

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.codexNeedsReconnect = true
		session.codexConversationID = "stale-thread"
		session.codexRolloutPath = "/tmp/missing-rollout.jsonl"
		session.runID = staleRunID
		session.appendItem(.assistant("previous reply", sequenceIndex: session.nextSequenceIndex))

		await vm.startAgentRun(tabID: tabID, initialMessage: "resume turn")

		let resumed = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.startOrResumeCallCount == 1 && !policyCalls.isEmpty
		}
		XCTAssertTrue(resumed, "Expected resume to mint a fresh live run ID and reinstall policy before start")
		guard let resumedRunID = session.runID else {
			return XCTFail("Expected resumed Codex session to have a live run ID")
		}
		XCTAssertNotEqual(resumedRunID, staleRunID)
		XCTAssertGreaterThanOrEqual(policyCalls.count, 1)
		XCTAssertTrue(policyCalls.contains(where: { $0.runID == resumedRunID }))
		XCTAssertEqual(policyCalls.last?.runID, resumedRunID)
	}

	func testCodexReconnectWithCachedPolicyAndStaleHistoricalRunMappingReinstallsPolicy() async {
		let fakeController = FakeCodexController()
		var policyCalls: [CodexPolicyInstallCall] = []
		let windowState = WindowState()
		let mcpServer = windowState.mcpServer
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath,
			shouldManageCodexTooling: true,
			codexControllerFactory: { _, _, _, _, _, _ in
				fakeController
			},
			connectionPolicyInstaller: { clientName, windowID, restrictedTools, oneShot, reason, ttl, tabID, runID, additionalTools, purpose, _, _, _ in
				policyCalls.append(
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
				if let runID {
					MCPRoutingWaiter.signalRouted(runID)
				}
			},
			testMCPServer: mcpServer
		)

		let tabID = UUID()
		let runID = UUID()
		let staleConnectionID = UUID()
		let codexClientName = DiscoverAgentKind.codexExec.mcpClientNameHint
		await ServerNetworkManager.shared.cleanupRunRoutingState(for: runID)
		await ServerNetworkManager.shared.debugSeedRunPolicyState(
			runID: runID,
			windowID: 1,
			restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
			additionalTools: AgentModeMCPToolPolicy.codexNativeGrantedTools,
			purpose: .agentModeRun
		)

		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.codexNeedsReconnect = true
		session.codexConversationID = "stale-thread"
		session.codexRolloutPath = "/tmp/stale-rollout.jsonl"
		session.runID = runID
		session.appendItem(.assistant("previous reply", sequenceIndex: session.nextSequenceIndex))

		let snapshot = ComposeTabState(id: tabID, name: "T1", promptText: "")
		mcpServer.installTabContext(
			clientID: staleConnectionID.uuidString,
			clientName: codexClientName,
			windowID: 1,
			snapshot: snapshot,
			runID: runID
		)
		mcpServer.removeTabContext(
			forConnectionID: staleConnectionID,
			clientName: codexClientName,
			windowID: 1,
			runID: nil
		)

		XCTAssertFalse(mcpServer.hasRunID(runID), "Historical run mappings should be cleared after connection churn")
		XCTAssertFalse(mcpServer.hasLiveRunID(runID), "Live run routing should be false once forward mapping is removed")

		await vm.startAgentRun(tabID: tabID, initialMessage: "resume turn")
		let resumed = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.startOrResumeCallCount == 1
				&& fakeController.sendUserMessageCallCount == 1
				&& session.runID != nil
				&& !policyCalls.isEmpty
		}
		XCTAssertTrue(resumed, "Expected reconnect resume to establish a fresh live run and policy")
		guard let freshRunID = session.runID else {
			return XCTFail("Expected reconnect to mint a fresh live run ID")
		}
		XCTAssertNotEqual(freshRunID, runID)
		let matchingCalls = policyCalls.filter { $0.runID == freshRunID }
		XCTAssertFalse(matchingCalls.isEmpty)
		XCTAssertEqual(matchingCalls.last?.additionalTools, AgentModeMCPToolPolicy.codexNativeGrantedTools)
		XCTAssertEqual(matchingCalls.last?.purpose, .agentModeRun)
		XCTAssertTrue(matchingCalls.last?.oneShot == true)

		await ServerNetworkManager.shared.cleanupRunRoutingState(for: freshRunID)
	}

	func testCodexActiveThreadWithCachedPolicyButNoLiveRunRouteForcesReconnectBeforeSend() async {
		let firstController = FakeCodexController()
		let reconnectController = FakeCodexController()
		var policyCalls: [CodexPolicyInstallCall] = []
		let windowState = WindowState()
		let mcpServer = windowState.mcpServer
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath,
			shouldManageCodexTooling: true,
			codexControllerFactory: { _, _, _, _, _, _ in
				reconnectController
			},
			connectionPolicyInstaller: { clientName, windowID, restrictedTools, oneShot, reason, ttl, tabID, runID, additionalTools, purpose, _, _, _ in
				policyCalls.append(
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
				if let runID {
					MCPRoutingWaiter.signalRouted(runID)
				}
			},
			testMCPServer: mcpServer
		)

		let tabID = UUID()
		let runID = UUID()
		await ServerNetworkManager.shared.cleanupRunRoutingState(for: runID)
		await ServerNetworkManager.shared.debugSeedRunPolicyState(
			runID: runID,
			windowID: 1,
			tabID: tabID,
			restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
			additionalTools: AgentModeMCPToolPolicy.codexNativeGrantedTools,
			purpose: .agentModeRun
		)

		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.runID = runID
		session.codexConversationID = "stale-thread"
		session.codexRolloutPath = "/tmp/stale-rollout.jsonl"
		session.codexController = firstController
		session.appendItem(.assistant("previous reply", sequenceIndex: session.nextSequenceIndex))
		_ = try? await firstController.startOrResume(
			existing: CodexNativeSessionController.SessionRef(
				conversationID: "stale-thread",
				rolloutPath: "/tmp/stale-rollout.jsonl",
				model: nil,
				reasoningEffort: nil
			),
			baseInstructions: "bootstrap"
		)

		XCTAssertFalse(mcpServer.hasLiveRunID(runID), "Precondition: cached policy should not imply a live run route")

		await vm.startAgentRun(tabID: tabID, initialMessage: "follow up after compact")
		let reconnected = await waitForCondition(timeoutSeconds: 2.0) {
			reconnectController.startOrResumeCallCount == 1
				&& reconnectController.sendUserMessageCallCount == 1
				&& firstController.shutdownCallCount == 1
				&& session.runID != nil
				&& !policyCalls.isEmpty
		}
		XCTAssertTrue(reconnected, "Expected an unbound active Codex thread to force reconnect before sending the follow-up turn")
		XCTAssertEqual(firstController.sendUserMessageCallCount, 0, "The stale unbound controller should not send the follow-up turn")
		XCTAssertEqual(reconnectController.startOrResumeExistingRefs.last??.conversationID, "stale-thread")
		XCTAssertFalse(session.codexNeedsReconnect, "Reconnect flag should clear after the repaired turn starts")
		guard let freshRunID = session.runID else {
			return XCTFail("Expected reconnect to mint a fresh live run ID")
		}
		XCTAssertNotEqual(freshRunID, runID)
		XCTAssertTrue(policyCalls.contains(where: { $0.runID == freshRunID }))

		await ServerNetworkManager.shared.cleanupRunRoutingState(for: freshRunID)
	}

	func testFreshCodexConversationReconnectSkipsStaleResumeThread() async {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.codexNeedsReconnect = true
		session.codexConversationID = "stale-thread"
		session.codexRolloutPath = "/tmp/missing-rollout.jsonl"
		session.appendItem(
			.user("first turn", sequenceIndex: session.nextSequenceIndex)
		)

		await vm.startAgentRun(tabID: tabID, initialMessage: "retry now")
		let started = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.startOrResumeCallCount == 1
				&& fakeController.sendUserMessageCallCount == 1
		}
		XCTAssertTrue(started, "Fresh conversations should immediately start a new thread")
		XCTAssertEqual(fakeController.startOrResumeExistingRefs.count, 1)
		XCTAssertNil(fakeController.startOrResumeExistingRefs[0], "Fresh conversations must not attempt stale thread resume")
		XCTAssertFalse(session.codexNeedsReconnect, "Reconnect flag should clear after fresh thread start")
	}

	func testCodexStartMissingRolloutRetriesImmediatelyWithFreshThreadFallbackForNonFreshConversation() async {
		let fakeController = FakeCodexController()
		fakeController.startOrResumeErrorDescriptions = [
			"failed to load rollout '/tmp/missing-rollout.jsonl': No such file or directory (os error 2)"
		]
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}

		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec
		session.appendItem(.assistant("previous reply", sequenceIndex: session.nextSequenceIndex))
		session.codexNeedsReconnect = true
		session.codexConversationID = "stale-thread"
		session.codexRolloutPath = "/tmp/missing-rollout.jsonl"

		await vm.startAgentRun(tabID: tabID, initialMessage: "retry now")
		let completedStart = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.startOrResumeCallCount == 2
				&& fakeController.sendUserMessageCallCount == 1
		}
		XCTAssertTrue(completedStart, "Expected immediate retry after stale rollout resume failure")
		XCTAssertEqual(fakeController.startOrResumeExistingRefs.count, 2)
		XCTAssertEqual(fakeController.startOrResumeExistingRefs[0]?.conversationID, "stale-thread")
		XCTAssertEqual(fakeController.startOrResumeExistingRefs[0]?.rolloutPath, "/tmp/missing-rollout.jsonl")
		XCTAssertNil(fakeController.startOrResumeExistingRefs[1], "Retry should force a fresh start without existing ref")
		XCTAssertFalse(session.codexNeedsReconnect, "Reconnect flag should clear after immediate retry succeeds")

		let startErrors = session.items.filter { $0.kind == .error && $0.text.contains("Codex native start failed:") }
		XCTAssertTrue(startErrors.isEmpty, "Successful fallback retry should not append start failure errors")
		let recoveryNotices = session.items.filter {
			$0.kind == .system &&
				$0.text.contains("rollout file was missing")
		}
		XCTAssertEqual(
			recoveryNotices.count,
			1,
			"Fallback from missing-rollout resume should surface an explicit user-visible notice"
		)
	}

	func testCommandExecutionRunningBurstIsCoalescedForUIRefresh() async throws {
		let fakeController = FakeCodexController()
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			fakeController
		}
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .codexExec

		await vm.startAgentRun(tabID: tabID, initialMessage: "start")
		let started = await waitForCondition(timeoutSeconds: 2.0) {
			fakeController.sendUserMessageCallCount == 1
		}
		XCTAssertTrue(started, "Expected Codex run to start")

		let failedResult = """
		{
		  "type": "commandExecution",
		  "status": "failed",
		  "exitCode": 1,
		  "processId": "4242",
		  "command": "xcodebuild"
		}
		"""
		fakeController.emit(.toolResult(name: "bash", invocationID: nil, argsJSON: nil, resultJSON: failedResult, isError: true))
		let inserted = await waitForCondition(timeoutSeconds: 2.0) {
			session.items.contains(where: { $0.kind == .toolResult && $0.toolName == "bash" })
		}
		XCTAssertTrue(inserted, "Expected initial bash tool result")

		vm.test_resetUpdateBindingsCallCount()
		for index in 0..<50 {
			fakeController.emit(
				.commandExecutionRunning(
					.init(invocationID: nil, processID: "4242", appendedOutput: "line-\(index)\n")
				)
			)
		}

			let applied = await waitForCondition(timeoutSeconds: 2.0) {
				session.items.last?.toolResultJSON?.contains("line-49") == true
			}
			XCTAssertTrue(applied, "Expected coalesced running output to be applied")
			let refreshed = await waitForCondition(timeoutSeconds: 2.0) {
				vm.test_updateBindingsCallCount > 0
			}
			XCTAssertTrue(refreshed, "Expected at least one coalesced UI refresh after applying running output")
			XCTAssertLessThanOrEqual(
				vm.test_updateBindingsCallCount,
				10,
			"Running bursts should be coalesced into a small number of UI refreshes"
		)
	}

	private func assertCodexTerminalInvariants(
		_ session: AgentModeViewModel.TabSession,
		expectedRunState: AgentSessionRunState,
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		XCTAssertEqual(session.runState, expectedRunState, file: file, line: line)
		XCTAssertNil(session.runningStatusText, file: file, line: line)
		XCTAssertNil(session.pendingApproval, file: file, line: line)
		XCTAssertNil(session.activeReasoningItemID, file: file, line: line)
		XCTAssertTrue(session.reasoningItemIDsByGroupID.isEmpty, file: file, line: line)
		XCTAssertTrue(session.pendingAssistantDelta.isEmpty, file: file, line: line)
		XCTAssertNil(session.assistantDeltaFlushTask, file: file, line: line)
		XCTAssertTrue(session.pendingCommandRunningByKey.isEmpty, file: file, line: line)
		XCTAssertFalse(
			session.items.contains(where: { $0.kind == .toolCall }),
			"Expected all toolCall items to be finalized before terminalization",
			file: file,
			line: line
		)
	}

	private func assertCodexIdleReconnectInvariants(
		_ session: AgentModeViewModel.TabSession,
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		XCTAssertEqual(session.runState, .completed, file: file, line: line)
		XCTAssertNil(session.runningStatusText, file: file, line: line)
		XCTAssertNil(session.pendingApproval, file: file, line: line)
		XCTAssertNil(session.activeReasoningItemID, file: file, line: line)
		XCTAssertTrue(session.reasoningItemIDsByGroupID.isEmpty, file: file, line: line)
		XCTAssertTrue(session.codexNeedsReconnect, file: file, line: line)
		XCTAssertNil(session.codexController, file: file, line: line)
		XCTAssertNil(session.codexEventTask, file: file, line: line)
	}

	private func runAndReconnectCycle(
		viewModel: AgentModeViewModel,
		tabID: UUID,
		fakeController: FakeCodexController,
		session: AgentModeViewModel.TabSession
	) async {
		await viewModel.startAgentRun(tabID: tabID, initialMessage: "first turn")
		XCTAssertEqual(fakeController.startOrResumeCallCount, 1)
		XCTAssertEqual(fakeController.sendUserMessageCallCount, 1)
		await viewModel.cancelAgentRun(tabID: tabID)
		XCTAssertTrue(session.codexNeedsReconnect, "Cancel should mark reconnect needed")

		await viewModel.startAgentRun(tabID: tabID, initialMessage: "follow-up turn")
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

	private func makeTranscriptItems(turnCount: Int) -> [AgentChatItem] {
		var items: [AgentChatItem] = []
		var sequenceIndex = 0
		for turn in 0..<turnCount {
			let baseDate = Date(timeIntervalSince1970: TimeInterval(turn * 10))
			items.append(AgentChatItem(timestamp: baseDate, kind: .user, text: "user \(turn)", sequenceIndex: sequenceIndex))
			sequenceIndex += 1
			items.append(AgentChatItem(timestamp: baseDate.addingTimeInterval(1), kind: .assistantInline, text: "checking \(turn)", sequenceIndex: sequenceIndex))
			sequenceIndex += 1
			items.append(AgentChatItem.toolCall(name: "read_file", invocationID: nil, argsJSON: "{\"path\":\"file\(turn).swift\"}", sequenceIndex: sequenceIndex))
			sequenceIndex += 1
			items.append(AgentChatItem.toolResult(name: "read_file", invocationID: nil, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: sequenceIndex))
			sequenceIndex += 1
			items.append(AgentChatItem(timestamp: baseDate.addingTimeInterval(2), kind: .assistant, text: "final summary \(turn)", sequenceIndex: sequenceIndex))
			sequenceIndex += 1
		}
		return items
	}

	private func makeTemporaryWorkspace(prefix: String = "AgentModeAttachmentCleanupTests") throws -> URL {
		let workspaceRoot = FileManager.default.temporaryDirectory
			.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
		return workspaceRoot
	}

	private func makeStoredAttachmentFile(workspaceDirectory: URL, fileName: String) throws -> URL {
		let storageFolder = AgentAttachmentStore.managedStorageRootURL(for: workspaceDirectory)
		try FileManager.default.createDirectory(at: storageFolder, withIntermediateDirectories: true)
		let fileURL = storageFolder.appendingPathComponent(fileName)
		try Data([0x89, 0x50, 0x4E, 0x47]).write(to: fileURL)
		return fileURL
	}

	private func hasCodexStallTimeoutWarning(_ session: AgentModeViewModel.TabSession) -> Bool {
		session.items.contains(where: {
			$0.kind == .error
				&& $0.text.contains("Repo Prompt thinks Codex has stalled or timed out")
		})
	}

	private func samplePNGData() -> Data {
		Data([
			0x89, 0x50, 0x4E, 0x47,
			0x0D, 0x0A, 0x1A, 0x0A,
			0x00, 0x00, 0x00, 0x0D,
			0x49, 0x48, 0x44, 0x52,
			0x00, 0x00, 0x00, 0x01,
			0x00, 0x00, 0x00, 0x01,
			0x08, 0x02, 0x00, 0x00,
			0x00, 0x90, 0x77, 0x53,
			0xDE, 0x00, 0x00, 0x00,
			0x0C, 0x49, 0x44, 0x41,
			0x54, 0x08, 0xD7, 0x63,
			0xF8, 0xCF, 0xC0, 0x00,
			0x00, 0x04, 0x01, 0x01,
			0x00, 0x18, 0xDD, 0x8D,
			0xB1, 0x00, 0x00, 0x00,
			0x00, 0x49, 0x45, 0x4E,
			0x44, 0xAE, 0x42, 0x60,
			0x82
		])
	}
}

private actor ToolRoutingState {
	private var seenInvocationIDs: Set<UUID> = []
	private(set) var completedByTool: [String: Int] = [:]

	func recordCompleted(invocationID: UUID, toolName: String, isError _: Bool) -> Bool {
		if seenInvocationIDs.contains(invocationID) {
			return false
		}
		seenInvocationIDs.insert(invocationID)
		completedByTool[toolName, default: 0] += 1
		return true
	}

	func snapshot() -> [String: Int] {
		completedByTool
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
	let requiresExpectedAgentPID: Bool

	init(
		clientName: String,
		windowID: Int,
		restrictedTools: Set<String>,
		oneShot: Bool,
		reason: String?,
		ttl: TimeInterval,
		tabID: UUID?,
		runID: UUID?,
		additionalTools: Set<String>?,
		purpose: MCPRunPurpose,
		requiresExpectedAgentPID: Bool = false
	) {
		self.clientName = clientName
		self.windowID = windowID
		self.restrictedTools = restrictedTools
		self.oneShot = oneShot
		self.reason = reason
		self.ttl = ttl
		self.tabID = tabID
		self.runID = runID
		self.additionalTools = additionalTools
		self.purpose = purpose
		self.requiresExpectedAgentPID = requiresExpectedAgentPID
	}
}

private func makeThreadSnapshot(
	conversationID: String = "test-thread",
	rolloutPath: String? = "/tmp/test-rollout.jsonl",
	runtimeStatus: CodexNativeSessionController.ThreadSnapshot.RuntimeStatus = .active(activeFlags: []),
	currentTurnID: String? = "turn-1",
	activeTurnIDs: [String] = ["turn-1"],
	latestTurnStatus: CodexNativeSessionController.TurnStatus? = nil
) -> CodexNativeSessionController.ThreadSnapshot {
	CodexNativeSessionController.ThreadSnapshot(
		conversationID: conversationID,
		rolloutPath: rolloutPath,
		model: "gpt-5.2-codex",
		reasoningEffort: "medium",
		runtimeStatus: runtimeStatus,
		currentTurnID: currentTurnID,
		activeTurnIDs: activeTurnIDs,
		latestTurnStatus: latestTurnStatus
	)
}

private func makeIdleThreadSnapshot() -> CodexNativeSessionController.ThreadSnapshot {
	makeThreadSnapshot(
		runtimeStatus: .idle,
		currentTurnID: nil,
		activeTurnIDs: [],
		latestTurnStatus: .completed
	)
}

private func makeUserInputRequest(id: String, questionID: String) -> AgentRequestUserInputRequest {
	AgentRequestUserInputRequest(
		requestID: .string(id),
		method: "item/tool/requestUserInput",
		threadID: "test-thread",
		turnID: "turn-1",
		itemID: "item-1-\(id)",
		questions: [
			AgentRequestUserInputQuestion(
				id: questionID,
				header: "Question",
				question: "Continue?",
				isOther: false,
				isSecret: false,
				options: [AgentRequestUserInputOption(label: "Yes", description: "Continue")]
			)
		]
	)
}

private func makeThreadGoal(
	threadID: String = "test-thread",
	objective: String = "Improve benchmark coverage",
	status: CodexNativeSessionController.ThreadGoalStatus = .active,
	tokenBudget: Int64? = nil,
	tokensUsed: Int64 = 12
) -> CodexNativeSessionController.ThreadGoal {
	CodexNativeSessionController.ThreadGoal(
		threadID: threadID,
		objective: objective,
		status: status,
		tokenBudget: tokenBudget,
		tokensUsed: tokensUsed,
		timeUsedSeconds: 3,
		createdAt: 1,
		updatedAt: 2
	)
}

private final class FakeCodexController: CodexSessionControlling {
	private var eventsContinuation: AsyncStream<CodexNativeSessionController.Event>.Continuation?
	private let eventsStream: AsyncStream<CodexNativeSessionController.Event>

	private(set) var hasActiveThread = false
	private(set) var startOrResumeCallCount = 0
	private(set) var startOrResumeExistingRefs: [CodexNativeSessionController.SessionRef?] = []
	private(set) var sendUserMessageCallCount = 0
	private(set) var compactThreadCallCount = 0
	private(set) var getThreadGoalCallCount = 0
	private(set) var setThreadGoalObjectiveCalls: [String] = []
	private(set) var setThreadGoalStatusCalls: [CodexNativeSessionController.ThreadGoalStatus] = []
	private(set) var clearThreadGoalCallCount = 0
	var currentGoal: CodexNativeSessionController.ThreadGoal?
	private(set) var setThreadNameCalls: [(name: String, threadID: String?)] = []
	private(set) var sentTurns: [(text: String, images: [AgentImageAttachment], model: String?, reasoningEffort: String?)] = []
	private(set) var cancelCurrentTurnCallCount = 0
	private(set) var shutdownCallCount = 0
	private(set) var respondToServerRequestCallCount = 0
	private(set) var lastRespondedRequestID: CodexAppServerRequestID?
	private(set) var lastRespondedResult: [String: Any] = [:]
	private(set) var readThreadSnapshotCallCount = 0
	private(set) var readThreadSnapshotIncludeTurnsValues: [Bool] = []
	var queuedThreadSnapshots: [CodexNativeSessionController.ThreadSnapshot] = []
	var queuedThreadSnapshotErrors: [Error] = []
	var startOrResumeFailuresRemaining = 0
	var startOrResumeErrorDescriptions: [String] = []
	var shouldBlockStartOrResume = false
	var shouldBlockReadThreadSnapshot = false
	var cancelKeepsThreadAlive = false
	var setThreadNameBlocksRemaining = 0
	var onCompactThread: (() -> Void)?
	private var blockedStartContinuations: [CheckedContinuation<Void, Never>] = []
	private var blockedReadThreadSnapshotContinuations: [CheckedContinuation<Void, Never>] = []
	private var blockedSetThreadNameContinuations: [CheckedContinuation<Void, Never>] = []

	var events: AsyncStream<CodexNativeSessionController.Event> {
		eventsStream
	}

	init() {
		var continuationRef: AsyncStream<CodexNativeSessionController.Event>.Continuation?
		self.eventsStream = AsyncStream { continuation in
			continuationRef = continuation
		}
		self.eventsContinuation = continuationRef
	}

	func ensureEventsStreamReady() {}

	func startOrResume(
		existing: CodexNativeSessionController.SessionRef?,
		baseInstructions: String
	) async throws -> CodexNativeSessionController.SessionRef {
		startOrResumeCallCount += 1
		startOrResumeExistingRefs.append(existing)
		if hasActiveThread {
			throw NSError(
				domain: "FakeCodexController",
				code: 5,
				userInfo: [
					NSLocalizedDescriptionKey: "This Codex session controller cannot be started because it is already active. Create a new controller instance."
				]
			)
		}
		if shouldBlockStartOrResume {
			await withCheckedContinuation { continuation in
				blockedStartContinuations.append(continuation)
			}
		}
		if !startOrResumeErrorDescriptions.isEmpty {
			let message = startOrResumeErrorDescriptions.removeFirst()
			hasActiveThread = false
			throw NSError(
				domain: "FakeCodexController",
				code: 3,
				userInfo: [NSLocalizedDescriptionKey: message]
			)
		}
		if startOrResumeFailuresRemaining > 0 {
			startOrResumeFailuresRemaining -= 1
			hasActiveThread = false
			throw NSError(
				domain: "FakeCodexController",
				code: 1,
				userInfo: [NSLocalizedDescriptionKey: "invalid reuse after initialization failure"]
			)
		}
		hasActiveThread = true
		return CodexNativeSessionController.SessionRef(
			conversationID: existing?.conversationID.isEmpty == false ? existing?.conversationID ?? "test-thread" : "test-thread",
			rolloutPath: existing?.rolloutPath,
			model: "gpt-5.2-codex",
			reasoningEffort: "medium"
		)
	}

	func setThreadName(_ name: String, threadID: String?) async throws {
		let trimmedThreadID = threadID?.trimmingCharacters(in: .whitespacesAndNewlines)
		setThreadNameCalls.append((
			name: AgentSession.validatedName(name),
			threadID: trimmedThreadID?.isEmpty == false ? trimmedThreadID : nil
		))
		if setThreadNameBlocksRemaining > 0 {
			setThreadNameBlocksRemaining -= 1
			await withCheckedContinuation { continuation in
				blockedSetThreadNameContinuations.append(continuation)
			}
		}
	}

	func readThreadSnapshot(
		includeTurns: Bool,
		timeout _: TimeInterval?
	) async throws -> CodexNativeSessionController.ThreadSnapshot {
		readThreadSnapshotCallCount += 1
		readThreadSnapshotIncludeTurnsValues.append(includeTurns)
		if shouldBlockReadThreadSnapshot {
			await withCheckedContinuation { continuation in
				blockedReadThreadSnapshotContinuations.append(continuation)
			}
		}
		if !queuedThreadSnapshotErrors.isEmpty {
			throw queuedThreadSnapshotErrors.removeFirst()
		}
		if !queuedThreadSnapshots.isEmpty {
			return queuedThreadSnapshots.removeFirst()
		}
		return makeThreadSnapshot()
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
		guard hasActiveThread else {
			throw NSError(
				domain: "FakeCodexController",
				code: 2,
				userInfo: [NSLocalizedDescriptionKey: "transport closed"]
			)
		}
		sendUserMessageCallCount += 1
		sentTurns.append((text: text, images: images, model: model, reasoningEffort: reasoningEffort))
	}

	func compactThread() async throws {
		guard hasActiveThread else {
			throw NSError(
				domain: "FakeCodexController",
				code: 4,
				userInfo: [NSLocalizedDescriptionKey: "no active thread"]
			)
		}
		compactThreadCallCount += 1
		onCompactThread?()
	}

	func getThreadGoal() async throws -> CodexNativeSessionController.ThreadGoal? {
		guard hasActiveThread else {
			throw NSError(
				domain: "FakeCodexController",
				code: 6,
				userInfo: [NSLocalizedDescriptionKey: "no active thread"]
			)
		}
		getThreadGoalCallCount += 1
		return currentGoal
	}

	func setThreadGoalObjective(_ objective: String) async throws -> CodexNativeSessionController.ThreadGoal {
		guard hasActiveThread else {
			throw NSError(
				domain: "FakeCodexController",
				code: 7,
				userInfo: [NSLocalizedDescriptionKey: "no active thread"]
			)
		}
		let trimmedObjective = objective.trimmingCharacters(in: .whitespacesAndNewlines)
		setThreadGoalObjectiveCalls.append(trimmedObjective)
		let goal = makeThreadGoal(objective: trimmedObjective, status: .active)
		currentGoal = goal
		return goal
	}

	func setThreadGoalStatus(_ status: CodexNativeSessionController.ThreadGoalStatus) async throws -> CodexNativeSessionController.ThreadGoal {
		guard hasActiveThread else {
			throw NSError(
				domain: "FakeCodexController",
				code: 8,
				userInfo: [NSLocalizedDescriptionKey: "no active thread"]
			)
		}
		setThreadGoalStatusCalls.append(status)
		let objective = currentGoal?.objective ?? "Improve benchmark coverage"
		let goal = makeThreadGoal(objective: objective, status: status)
		currentGoal = goal
		return goal
	}

	func clearThreadGoal() async throws -> Bool {
		guard hasActiveThread else {
			throw NSError(
				domain: "FakeCodexController",
				code: 9,
				userInfo: [NSLocalizedDescriptionKey: "no active thread"]
			)
		}
		clearThreadGoalCallCount += 1
		let hadGoal = currentGoal != nil
		currentGoal = nil
		return hadGoal
	}

	func cancelCurrentTurn() async {
		cancelCurrentTurnCallCount += 1
		if !cancelKeepsThreadAlive {
			hasActiveThread = false
		}
	}

	func shutdown() async {
		shutdownCallCount += 1
		hasActiveThread = false
		unblockStartOrResume()
		unblockReadThreadSnapshot()
		unblockSetThreadName()
		eventsContinuation?.finish()
	}

	func respondToServerRequest(id: CodexAppServerRequestID, result: [String: Any]) async {
		respondToServerRequestCallCount += 1
		lastRespondedRequestID = id
		lastRespondedResult = result
	}

	func emit(_ event: CodexNativeSessionController.Event) {
		eventsContinuation?.yield(event)
	}

	func unblockStartOrResume() {
		guard !blockedStartContinuations.isEmpty else { return }
		let continuations = blockedStartContinuations
		blockedStartContinuations.removeAll()
		for continuation in continuations {
			continuation.resume()
		}
	}

	func unblockReadThreadSnapshot() {
		guard !blockedReadThreadSnapshotContinuations.isEmpty else { return }
		let continuations = blockedReadThreadSnapshotContinuations
		blockedReadThreadSnapshotContinuations.removeAll()
		for continuation in continuations {
			continuation.resume()
		}
	}

	func unblockSetThreadName() {
		guard !blockedSetThreadNameContinuations.isEmpty else { return }
		let continuations = blockedSetThreadNameContinuations
		blockedSetThreadNameContinuations.removeAll()
		for continuation in continuations {
			continuation.resume()
		}
	}
}

private actor AsyncDrainGate {
	private var isReleased = false
	private var waiters: [CheckedContinuation<Void, Never>] = []

	func wait() async {
		guard !isReleased else { return }
		await withCheckedContinuation { continuation in
			waiters.append(continuation)
		}
	}

	func release() {
		guard !isReleased else { return }
		isReleased = true
		let continuations = waiters
		waiters.removeAll()
		for continuation in continuations {
			continuation.resume()
		}
	}
}

private final class LockedBool: @unchecked Sendable {
	private let lock = NSLock()
	private var value: Bool

	init(_ initialValue: Bool) {
		self.value = initialValue
	}

	func get() -> Bool {
		lock.lock()
		defer { lock.unlock() }
		return value
	}

	func set(_ newValue: Bool) {
		lock.lock()
		value = newValue
		lock.unlock()
	}
}

private final class LockedUUIDArray: @unchecked Sendable {
	private let lock = NSLock()
	private var values: [UUID] = []

	func append(_ value: UUID) {
		lock.lock()
		values.append(value)
		lock.unlock()
	}

	func snapshot() -> [UUID] {
		lock.lock()
		defer { lock.unlock() }
		return values
	}
}
