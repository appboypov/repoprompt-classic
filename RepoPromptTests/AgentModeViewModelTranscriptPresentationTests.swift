import XCTest
@testable import RepoPrompt

@MainActor
final class AgentModeViewModelTranscriptPresentationTests: XCTestCase {
	func testHiddenArchivedHistoryPublishesOnlyWorkingSuffixState() async {
		let vm = makeViewModel()
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.replaceItems(makeTranscriptItems(turnCount: 40))

		vm.test_rebuildStructuredTranscript(tabID: tabID)
		vm.test_applySessionToBindings(tabID: tabID)

		let snapshot = vm.activeTranscriptPresentation

		XCTAssertTrue(session.archivedTranscriptSnapshot.historyState.hasArchivedHistory)
		XCTAssertEqual(snapshot.visibleBlocks, session.workingTranscriptProjection.workingBlocks)
		XCTAssertEqual(snapshot.workingBlocks, session.workingTranscriptProjection.workingBlocks)
		XCTAssertEqual(snapshot.visibleRows, session.workingTranscriptProjection.workingRows)
		XCTAssertEqual(snapshot.workingRows, session.workingTranscriptProjection.workingRows)
		XCTAssertEqual(snapshot.archivedHistoryState, session.archivedTranscriptSnapshot.historyState)
		XCTAssertEqual(snapshot.rowAnchorIndex, session.workingTranscriptProjection.rowAnchorIndex)
		XCTAssertEqual(snapshot.anchorBlockIndex, session.workingTranscriptProjection.anchorBlockIndex)
		XCTAssertTrue(snapshot.isWindowCappedWhileActive)
		XCTAssertEqual(vm.visibleTranscriptBlocks, snapshot.visibleBlocks)
		XCTAssertEqual(vm.items, snapshot.workingRows)
	}

	func testRevealToggleRematerializesCachedFullProjectionWithoutRebuild() async {
		let vm = makeViewModel()
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.replaceItems(makeTranscriptItems(turnCount: 40))

		vm.test_rebuildStructuredTranscript(tabID: tabID)
		vm.test_applySessionToBindings(tabID: tabID)
		let buildCountBeforeReveal = session.transcriptPerformanceSnapshot.projectionBuildCount
		let hiddenRevision = vm.test_activeTranscriptPresentationRevisionValue()

		vm.test_setCompressedHistoryVisibility(tabID: tabID, isRevealed: true)

		let revealedSnapshot = vm.activeTranscriptPresentation

		XCTAssertEqual(session.transcriptPerformanceSnapshot.projectionBuildCount, buildCountBeforeReveal)
		XCTAssertEqual(session.transcriptProjection, session.fullTranscriptProjection)
		XCTAssertEqual(
			revealedSnapshot.visibleBlocks,
			session.fullTranscriptProjection.archivedBlocks + session.fullTranscriptProjection.workingBlocks
		)
		XCTAssertEqual(
			revealedSnapshot.visibleRows,
			session.fullTranscriptProjection.archivedRows + session.fullTranscriptProjection.workingRows
		)
		XCTAssertEqual(revealedSnapshot.rowAnchorIndex, session.fullTranscriptProjection.rowAnchorIndex)
		XCTAssertEqual(revealedSnapshot.anchorBlockIndex, session.fullTranscriptProjection.anchorBlockIndex)
		XCTAssertFalse(revealedSnapshot.isWindowCappedWhileActive)
		XCTAssertGreaterThan(revealedSnapshot.revision, hiddenRevision)

		let revealedRevision = vm.test_activeTranscriptPresentationRevisionValue()
		vm.test_setCompressedHistoryVisibility(tabID: tabID, isRevealed: false)

		let hiddenSnapshot = vm.activeTranscriptPresentation

		XCTAssertEqual(session.transcriptPerformanceSnapshot.projectionBuildCount, buildCountBeforeReveal)
		XCTAssertEqual(session.transcriptProjection, session.workingTranscriptProjection)
		XCTAssertEqual(hiddenSnapshot.visibleBlocks, session.workingTranscriptProjection.workingBlocks)
		XCTAssertEqual(hiddenSnapshot.visibleRows, session.workingTranscriptProjection.workingRows)
		XCTAssertEqual(hiddenSnapshot.rowAnchorIndex, session.workingTranscriptProjection.rowAnchorIndex)
		XCTAssertEqual(hiddenSnapshot.anchorBlockIndex, session.workingTranscriptProjection.anchorBlockIndex)
		XCTAssertTrue(hiddenSnapshot.isWindowCappedWhileActive)
		XCTAssertGreaterThan(hiddenSnapshot.revision, revealedRevision)
	}

	func testPerformanceOnlyPresentationUpdateKeepsRevisionStable() async {
		let vm = makeViewModel()
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.replaceItems(makeTranscriptItems(turnCount: 6))

		vm.test_rebuildStructuredTranscript(tabID: tabID)
		vm.test_applySessionToBindings(tabID: tabID)

		let initialRevision = vm.test_activeTranscriptPresentationRevisionValue()
		let initialSnapshot = vm.activeTranscriptPresentation
		let initialBuildCount = session.transcriptPerformanceSnapshot.projectionBuildCount

		vm.test_rebuildStructuredTranscript(tabID: tabID)
		let contentChanged = vm.test_publishTranscriptPresentation(tabID: tabID)

		let refreshedSnapshot = vm.activeTranscriptPresentation
		XCTAssertFalse(contentChanged)
		XCTAssertEqual(refreshedSnapshot.revision, initialRevision)
		XCTAssertEqual(refreshedSnapshot.visibleBlocks, initialSnapshot.visibleBlocks)
		XCTAssertEqual(refreshedSnapshot.visibleRows, initialSnapshot.visibleRows)
		XCTAssertGreaterThan(session.transcriptPerformanceSnapshot.projectionBuildCount, initialBuildCount)
		XCTAssertEqual(
			refreshedSnapshot.performanceSnapshot.projectionBuildCount,
			session.transcriptPerformanceSnapshot.projectionBuildCount
		)
	}

	func testSameSessionRebindDoesNotForceTranscriptRevision() async {
		let vm = makeViewModel()
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.replaceItems(makeTranscriptItems(turnCount: 3))

		vm.test_rebuildStructuredTranscript(tabID: tabID)
		vm.test_applySessionToBindings(tabID: tabID)

		let initialRevision = vm.test_activeTranscriptPresentationRevisionValue()
		let initialSnapshot = vm.activeTranscriptPresentation

		vm.test_applySessionToBindings(tabID: tabID)

		let reboundSnapshot = vm.activeTranscriptPresentation
		XCTAssertEqual(reboundSnapshot.revision, initialRevision)
		XCTAssertEqual(reboundSnapshot.visibleBlocks, initialSnapshot.visibleBlocks)
		XCTAssertEqual(reboundSnapshot.workingBlocks, initialSnapshot.workingBlocks)
		XCTAssertEqual(reboundSnapshot.visibleRows, initialSnapshot.visibleRows)
		XCTAssertEqual(reboundSnapshot.workingRows, initialSnapshot.workingRows)
	}

	func testSwitchingBetweenLoadedRunningSessionsPublishesTargetPresentation() async {
		let vm = makeViewModel()
		let firstTabID = UUID()
		let secondTabID = UUID()
		let firstSession = await vm.ensureSessionReady(tabID: firstTabID)
		let secondSession = await vm.ensureSessionReady(tabID: secondTabID)
		firstSession.runState = .running
		secondSession.runState = .running
		firstSession.replaceItems([
			.user("first user", sequenceIndex: 0),
			.assistant("first assistant", sequenceIndex: 1)
		])
		secondSession.replaceItems([
			.user("second user", sequenceIndex: 0),
			.assistant("second assistant", sequenceIndex: 1)
		])

		vm.test_rebuildStructuredTranscript(tabID: firstTabID)
		vm.test_rebuildStructuredTranscript(tabID: secondTabID)
		vm.test_applySessionToBindings(tabID: firstTabID)
		let firstRevision = vm.test_activeTranscriptPresentationRevisionValue()

		vm.test_applySessionToBindings(tabID: secondTabID)

		XCTAssertEqual(vm.activeTranscriptPresentation.tabID, secondTabID)
		XCTAssertGreaterThan(vm.test_activeTranscriptPresentationRevisionValue(), firstRevision)
		XCTAssertEqual(vm.activeTranscriptPresentation.visibleRows, secondSession.workingTranscriptProjection.workingRows)
		XCTAssertEqual(vm.activeTranscriptPresentation.visibleBlocks, secondSession.workingTranscriptProjection.workingBlocks)
		XCTAssertEqual(vm.runState, .running)
	}

	func testSwitchingBetweenLoadedSessionsWithIdenticalRowsStillChangesTabOwnership() async {
		let vm = makeViewModel()
		let firstTabID = UUID()
		let secondTabID = UUID()
		let firstSession = await vm.ensureSessionReady(tabID: firstTabID)
		let secondSession = await vm.ensureSessionReady(tabID: secondTabID)
		let identicalItems = makeTranscriptItems(turnCount: 2)
		firstSession.replaceItems(identicalItems)
		secondSession.replaceItems(identicalItems)

		vm.test_rebuildStructuredTranscript(tabID: firstTabID)
		vm.test_rebuildStructuredTranscript(tabID: secondTabID)
		vm.test_applySessionToBindings(tabID: firstTabID)
		let firstRevision = vm.test_activeTranscriptPresentationRevisionValue()

		vm.test_applySessionToBindings(tabID: secondTabID)

		XCTAssertEqual(vm.activeTranscriptPresentation.tabID, secondTabID)
		XCTAssertTrue(vm.isActiveTranscriptPresentationHydrated(for: secondTabID))
		XCTAssertFalse(vm.isActiveTranscriptPresentationHydrated(for: firstTabID))
		XCTAssertGreaterThan(vm.test_activeTranscriptPresentationRevisionValue(), firstRevision)
		XCTAssertEqual(vm.activeTranscriptPresentation.visibleRows, secondSession.workingTranscriptProjection.workingRows)
	}

	func testRefreshingDerivedTranscriptRepublishesActivePresentation() async {
		let vm = makeViewModel()
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.replaceItems(makeTranscriptItems(turnCount: 2))

		vm.test_rebuildStructuredTranscript(tabID: tabID)
		vm.test_applySessionToBindings(tabID: tabID)

		let initialRevision = vm.test_activeTranscriptPresentationRevisionValue()
		session.appendItem(.user("steering message", sequenceIndex: session.nextSequenceIndex))

		let refreshedSnapshot = vm.activeTranscriptPresentation
		XCTAssertGreaterThan(vm.test_activeTranscriptPresentationRevisionValue(), initialRevision)
		XCTAssertEqual(refreshedSnapshot.visibleRows, session.workingTranscriptProjection.workingRows)
		XCTAssertEqual(refreshedSnapshot.workingRows, session.workingTranscriptProjection.workingRows)
		XCTAssertEqual(refreshedSnapshot.visibleRows.last?.text, "steering message")
	}

	func testRefreshingDerivedTranscriptPreservesCompletedTurnProjectionCaches() async {
		let vm = makeViewModel()
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.replaceItems(makeTranscriptItems(turnCount: 3))

		vm.test_rebuildStructuredTranscript(tabID: tabID)
		let initialTurnIDs = session.transcript.turns.map(\.id)
		guard let firstTurnID = initialTurnIDs.first,
			let initialFirstTurnCache = session.turnProjectionCaches[firstTurnID]
		else {
			return XCTFail("Expected initial completed-turn caches")
		}

		XCTAssertEqual(Set(session.turnProjectionCaches.keys), Set(initialTurnIDs))

		session.runState = .running
		session.appendItem(.user("follow up", sequenceIndex: session.nextSequenceIndex))

		let completedTurnIDs = Set(session.transcript.turns.dropLast().map(\.id))
		guard let latestTurnID = session.transcript.turns.last?.id else {
			return XCTFail("Expected latest turn after appending follow up")
		}

		XCTAssertEqual(Set(session.turnProjectionCaches.keys), completedTurnIDs)
		XCTAssertEqual(session.turnProjectionCaches[firstTurnID], initialFirstTurnCache)
		XCTAssertNil(session.turnProjectionCaches[latestTurnID])
	}

	func testRefreshingInactiveSessionDoesNotClobberActivePresentation() async {
		let vm = makeViewModel()
		let activeTabID = UUID()
		let inactiveTabID = UUID()
		let activeSession = await vm.ensureSessionReady(tabID: activeTabID)
		let inactiveSession = await vm.ensureSessionReady(tabID: inactiveTabID)
		activeSession.replaceItems(makeTranscriptItems(turnCount: 2))
		inactiveSession.replaceItems(makeTranscriptItems(turnCount: 2))

		vm.test_rebuildStructuredTranscript(tabID: activeTabID)
		vm.test_applySessionToBindings(tabID: activeTabID)
		vm.test_rebuildStructuredTranscript(tabID: inactiveTabID)

		let activeSnapshot = vm.activeTranscriptPresentation
		let inactiveBuildCount = inactiveSession.transcriptPerformanceSnapshot.projectionBuildCount
		inactiveSession.appendItem(.user("background mutation", sequenceIndex: inactiveSession.nextSequenceIndex))
		await vm.test_drainScheduledDerivedTranscriptRefresh(tabID: inactiveTabID)

		XCTAssertEqual(vm.activeTranscriptPresentation.tabID, activeTabID)
		XCTAssertEqual(vm.activeTranscriptPresentation.visibleRows, activeSnapshot.visibleRows)
		XCTAssertEqual(vm.activeTranscriptPresentation.workingRows, activeSnapshot.workingRows)
		XCTAssertGreaterThan(inactiveSession.transcriptPerformanceSnapshot.projectionBuildCount, inactiveBuildCount)
		XCTAssertEqual(inactiveSession.workingTranscriptProjection.workingRows.last?.text, "background mutation")
		XCTAssertEqual(inactiveSession.derivedTranscriptSyncState?.sourceItemsRevision, inactiveSession.sourceItemsRevision)
		XCTAssertTrue(inactiveSession.isDirty)

		let buildCountAfterBackgroundRefresh = inactiveSession.transcriptPerformanceSnapshot.projectionBuildCount
		vm.test_setCurrentTabIDOverride(inactiveTabID)
		defer { vm.test_setCurrentTabIDOverride(nil) }
		vm.test_applySessionToBindings(tabID: inactiveTabID)

		XCTAssertEqual(inactiveSession.transcriptPerformanceSnapshot.projectionBuildCount, buildCountAfterBackgroundRefresh)
		XCTAssertEqual(vm.activeTranscriptPresentation.tabID, inactiveTabID)
		XCTAssertEqual(vm.activeTranscriptPresentation.visibleRows, inactiveSession.workingTranscriptProjection.workingRows)
		XCTAssertEqual(vm.activeTranscriptPresentation.visibleRows.last?.text, "background mutation")
	}

	func testActiveBindingBuildsUnsyncedSourceItems() async {
		let vm = makeViewModel()
		let activeTabID = UUID()
		let inactiveTabID = UUID()
		let activeSession = await vm.ensureSessionReady(tabID: activeTabID)
		let inactiveSession = await vm.ensureSessionReady(tabID: inactiveTabID)
		activeSession.replaceItems(makeTranscriptItems(turnCount: 1))

		vm.test_rebuildStructuredTranscript(tabID: activeTabID)
		vm.test_applySessionToBindings(tabID: activeTabID)
		let inactiveBuildCount = inactiveSession.transcriptPerformanceSnapshot.projectionBuildCount

		inactiveSession.setItemsSilently([
			.user("optimistic child prompt", sequenceIndex: 0)
		], reason: .retentionCompaction)
		XCTAssertNil(inactiveSession.derivedTranscriptSyncState)
		XCTAssertEqual(inactiveSession.transcriptPerformanceSnapshot.projectionBuildCount, inactiveBuildCount)

		vm.test_setCurrentTabIDOverride(inactiveTabID)
		defer { vm.test_setCurrentTabIDOverride(nil) }
		vm.test_applySessionToBindings(tabID: inactiveTabID)

		XCTAssertGreaterThan(inactiveSession.transcriptPerformanceSnapshot.projectionBuildCount, inactiveBuildCount)
		XCTAssertEqual(inactiveSession.derivedTranscriptSyncState?.sourceItemsRevision, inactiveSession.sourceItemsRevision)
		XCTAssertEqual(vm.activeTranscriptPresentation.tabID, inactiveTabID)
		XCTAssertEqual(vm.activeTranscriptPresentation.visibleRows.map(\.kind), [.user])
		XCTAssertEqual(vm.activeTranscriptPresentation.workingRows.map(\.kind), [.user])
		XCTAssertEqual(vm.activeTranscriptPresentation.visibleRows.first?.text, "optimistic child prompt")
		XCTAssertEqual(vm.activeTranscriptPresentation.workingRows.first?.text, "optimistic child prompt")
	}

	func testActiveTranscriptReadinessRequiresTabOwnership() async {
		let vm = makeViewModel()
		let activeTabID = UUID()
		let foreignTabID = UUID()
		let activeSession = await vm.ensureSessionReady(tabID: activeTabID)
		activeSession.replaceItems(makeTranscriptItems(turnCount: 2))

		vm.test_rebuildStructuredTranscript(tabID: activeTabID)
		vm.test_applySessionToBindings(tabID: activeTabID)

		XCTAssertTrue(vm.isActiveTranscriptPresentationHydrated(for: activeTabID))
		XCTAssertFalse(vm.isActiveTranscriptPresentationHydrated(for: foreignTabID))
		XCTAssertFalse(vm.isActiveTranscriptPresentationHydrated(for: nil))

		let foreignPresentation = vm.scopedActiveTranscriptPresentation(for: foreignTabID)
		XCTAssertEqual(foreignPresentation.tabID, foreignTabID)
		XCTAssertFalse(foreignPresentation.bindingsHydrated)
		XCTAssertTrue(foreignPresentation.visibleRows.isEmpty)
		XCTAssertTrue(foreignPresentation.visibleBlocks.isEmpty)
		XCTAssertEqual(vm.activeTranscriptPresentationRevision(for: foreignTabID), 0)
	}

	func testLoadingTargetTabClearsPreviousVisibleRowsAndBlocks() async {
		let vm = makeViewModel()
		let previousTabID = UUID()
		let targetTabID = UUID()
		let previousSession = await vm.ensureSessionReady(tabID: previousTabID)
		previousSession.replaceItems(makeTranscriptItems(turnCount: 2))

		vm.test_rebuildStructuredTranscript(tabID: previousTabID)
		vm.test_applySessionToBindings(tabID: previousTabID)
		let previousRevision = vm.test_activeTranscriptPresentationRevisionValue()
		XCTAssertFalse(vm.activeTranscriptPresentation.visibleRows.isEmpty)
		XCTAssertFalse(vm.activeTranscriptPresentation.visibleBlocks.isEmpty)

		vm.test_publishLoadingTranscriptPresentation(tabID: targetTabID)

		let loadingSnapshot = vm.activeTranscriptPresentation
		XCTAssertEqual(loadingSnapshot.tabID, targetTabID)
		XCTAssertGreaterThan(loadingSnapshot.revision, previousRevision)

		vm.test_publishLoadingTranscriptPresentation(tabID: targetTabID)
		XCTAssertEqual(vm.test_activeTranscriptPresentationRevisionValue(), loadingSnapshot.revision)
		XCTAssertFalse(loadingSnapshot.bindingsHydrated)
		XCTAssertTrue(loadingSnapshot.visibleRows.isEmpty)
		XCTAssertTrue(loadingSnapshot.workingRows.isEmpty)
		XCTAssertTrue(loadingSnapshot.visibleBlocks.isEmpty)
		XCTAssertTrue(loadingSnapshot.workingBlocks.isEmpty)
		XCTAssertFalse(vm.isActiveTranscriptPresentationHydrated(for: targetTabID))
		XCTAssertTrue(vm.scopedActiveTranscriptPresentation(for: targetTabID).visibleRows.isEmpty)
	}

	func testRefreshingOldTabCannotRepublishStaleActivePresentationWhenCurrentTabDiffers() async {
		let vm = makeViewModel()
		let oldTabID = UUID()
		let currentTabID = UUID()
		let oldSession = await vm.ensureSessionReady(tabID: oldTabID)
		_ = await vm.ensureSessionReady(tabID: currentTabID)
		oldSession.replaceItems(makeTranscriptItems(turnCount: 2))

		vm.test_rebuildStructuredTranscript(tabID: oldTabID)
		vm.test_applySessionToBindings(tabID: oldTabID)
		vm.test_setCurrentTabIDOverride(currentTabID)
		defer { vm.test_setCurrentTabIDOverride(nil) }

		let staleSnapshot = vm.activeTranscriptPresentation
		oldSession.appendItem(.user("old-tab background mutation", sequenceIndex: oldSession.nextSequenceIndex))

		XCTAssertEqual(vm.activeTranscriptPresentation, staleSnapshot)
		XCTAssertFalse(vm.activeTranscriptPresentation.visibleRows.contains { $0.text == "old-tab background mutation" })
		XCTAssertTrue(vm.scopedActiveTranscriptPresentation(for: currentTabID).visibleRows.isEmpty)
		XCTAssertFalse(vm.isActiveTranscriptPresentationHydrated(for: currentTabID))
	}

	func testOldTabRunStateChangeCannotRepublishStaleActivePresentationWhenCurrentTabDiffers() async throws {
		let vm = makeViewModel()
		let oldTabID = UUID()
		let currentTabID = UUID()
		let oldSession = await vm.ensureSessionReady(tabID: oldTabID)
		_ = await vm.ensureSessionReady(tabID: currentTabID)
		oldSession.replaceItems(makeToolTurnItems())

		vm.test_rebuildStructuredTranscript(tabID: oldTabID)
		vm.test_applySessionToBindings(tabID: oldTabID)
		XCTAssertNil(vm.activeTranscriptPresentation.metadata.dynamicSummaryLockTargetTurnID)
		vm.test_setCurrentTabIDOverride(currentTabID)
		defer { vm.test_setCurrentTabIDOverride(nil) }

		let revisionBeforeRunStateChange = vm.test_activeTranscriptPresentationRevisionValue()
		oldSession.runState = .running

		XCTAssertEqual(vm.test_activeTranscriptPresentationRevisionValue(), revisionBeforeRunStateChange)
		XCTAssertNil(vm.activeTranscriptPresentation.metadata.dynamicSummaryLockTargetTurnID)
		XCTAssertTrue(vm.scopedActiveTranscriptPresentation(for: currentTabID).visibleBlocks.isEmpty)
	}

	func testDynamicSummaryLockTargetIsNilWhenRunActiveButNoToolActivity() async {
		let vm = makeViewModel()
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.replaceItems(makeTranscriptItems(turnCount: 1))

		vm.test_rebuildStructuredTranscript(tabID: tabID)
		vm.test_applySessionToBindings(tabID: tabID)
		let buildCountBeforeRunStateChange = session.transcriptPerformanceSnapshot.projectionBuildCount

		session.runState = .running

		XCTAssertNil(vm.activeTranscriptPresentation.metadata.dynamicSummaryLockTargetTurnID)
		XCTAssertEqual(session.transcriptPerformanceSnapshot.projectionBuildCount, buildCountBeforeRunStateChange)
	}

	func testFreshLocalSessionBindingKeepsPopulatedTranscriptHydrated() async throws {
		let vm = makeViewModel()
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		XCTAssertNil(session.activeAgentSessionID)
		session.replaceItems([
			.user("local handoff user", sequenceIndex: 0),
			.assistant("local handoff assistant", sequenceIndex: 1)
		])
		vm.test_rebuildStructuredTranscript(tabID: tabID)

		vm.ensureSession(for: tabID)
		let createdSessionID = try XCTUnwrap(session.activeAgentSessionID)
		XCTAssertEqual(session.hydratedAgentSessionID, createdSessionID)
		XCTAssertTrue(session.hasLoadedPersistedState)

		vm.test_setCurrentTabIDOverride(tabID)
		defer { vm.test_setCurrentTabIDOverride(nil) }
		vm.debugProcessTabChangedForTesting(tabID)

		XCTAssertEqual(session.activeAgentSessionID, createdSessionID)
		XCTAssertEqual(session.hydratedAgentSessionID, createdSessionID)
		XCTAssertTrue(vm.activeTranscriptPresentation.visibleRows.contains { $0.text == "local handoff user" })
		XCTAssertTrue(vm.activeTranscriptPresentation.visibleRows.contains { $0.text == "local handoff assistant" })
	}

	func testSwitchingToChangedSessionBindingColdRestoresInsteadOfPublishingStaleCache() async {
		let vm = makeViewModel()
		let tabID = UUID()
		let oldSessionID = UUID()
		let newSessionID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.markHydrationLoaded(for: oldSessionID)
		session.replaceItems([
			.user("stale user", sequenceIndex: 0),
			.assistant("stale assistant", sequenceIndex: 1)
		])
		vm.test_rebuildStructuredTranscript(tabID: tabID)
		session.isDirty = false
		vm.test_setCurrentTabIDOverride(tabID)
		defer { vm.test_setCurrentTabIDOverride(nil) }
		vm.test_applySessionToBindings(tabID: tabID)
		XCTAssertTrue(vm.activeTranscriptPresentation.visibleRows.contains { $0.text == "stale user" })

		vm.test_setLastKnownWorkspaceSnapshot(makeWorkspace(tabID: tabID, sessionID: newSessionID))
		vm.setAgentModeActive(true)

		XCTAssertEqual(session.activeAgentSessionID, newSessionID)
		XCTAssertTrue(session.hydratedAgentSessionID == nil || session.hydratedAgentSessionID == newSessionID)
		XCTAssertFalse(vm.activeTranscriptPresentation.visibleRows.contains { $0.text == "stale user" })
		XCTAssertTrue(vm.activeTranscriptPresentation.visibleRows.isEmpty)
	}

	func testSameTabSessionBindingChangeIsNotSkippedByActivationGuard() async {
		let vm = makeViewModel()
		let tabID = UUID()
		let oldSessionID = UUID()
		let newSessionID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.markHydrationLoaded(for: oldSessionID)
		session.replaceItems([
			.user("old bound user", sequenceIndex: 0),
			.assistant("old bound assistant", sequenceIndex: 1)
		])
		vm.test_rebuildStructuredTranscript(tabID: tabID)
		session.isDirty = false
		vm.test_setCurrentTabIDOverride(tabID)
		defer { vm.test_setCurrentTabIDOverride(nil) }
		vm.test_setLastKnownWorkspaceSnapshot(makeWorkspace(tabID: tabID, sessionID: oldSessionID))
		vm.setAgentModeActive(true)
		XCTAssertTrue(vm.activeTranscriptPresentation.visibleRows.contains { $0.text == "old bound user" })

		vm.test_setLastKnownWorkspaceSnapshot(makeWorkspace(tabID: tabID, sessionID: newSessionID))
		vm.test_processTabChangedPreservingActivationKey(tabID)

		XCTAssertEqual(session.activeAgentSessionID, newSessionID)
		XCTAssertTrue(session.hydratedAgentSessionID == nil || session.hydratedAgentSessionID == newSessionID)
		XCTAssertFalse(vm.activeTranscriptPresentation.visibleRows.contains { $0.text == "old bound user" })
		XCTAssertTrue(vm.activeTranscriptPresentation.visibleRows.isEmpty)
	}

	func testDirtySessionBindingChangeKeepsLoadingAndSuppressesOldPublication() async {
		let vm = makeViewModel()
		let tabID = UUID()
		let oldSessionID = UUID()
		let newSessionID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.markHydrationLoaded(for: oldSessionID)
		session.replaceItems([
			.user("dirty old user", sequenceIndex: 0),
			.assistant("dirty old assistant", sequenceIndex: 1)
		])
		vm.test_rebuildStructuredTranscript(tabID: tabID)
		vm.test_setCurrentTabIDOverride(tabID)
		defer { vm.test_setCurrentTabIDOverride(nil) }
		vm.test_applySessionToBindings(tabID: tabID)
		XCTAssertTrue(vm.activeTranscriptPresentation.visibleRows.contains { $0.text == "dirty old user" })

		session.isDirty = true
		vm.test_setLastKnownWorkspaceSnapshot(makeWorkspace(tabID: tabID, sessionID: newSessionID))
		vm.setAgentModeActive(true)

		XCTAssertEqual(session.activeAgentSessionID, oldSessionID)
		XCTAssertEqual(session.hydratedAgentSessionID, oldSessionID)
		XCTAssertFalse(vm.activeTranscriptPresentation.bindingsHydrated)
		XCTAssertTrue(vm.activeTranscriptPresentation.visibleRows.isEmpty)

		session.appendItem(.assistant("dirty old update", sequenceIndex: 2))
		await vm.test_drainScheduledDerivedTranscriptRefresh(tabID: tabID)

		XCTAssertFalse(vm.activeTranscriptPresentation.bindingsHydrated)
		XCTAssertFalse(vm.activeTranscriptPresentation.visibleRows.contains { $0.text == "dirty old update" })
		XCTAssertTrue(vm.activeTranscriptPresentation.visibleRows.isEmpty)

		session.isDirty = false
		vm.test_processTabChangedPreservingActivationKey(tabID)

		XCTAssertEqual(session.activeAgentSessionID, newSessionID)
		XCTAssertTrue(session.hydratedAgentSessionID == nil || session.hydratedAgentSessionID == newSessionID)
		XCTAssertFalse(vm.activeTranscriptPresentation.visibleRows.contains { $0.text == "dirty old user" })
	}

	func testActiveSessionBindingChangeKeepsLoadingAndSuppressesOldPublication() async {
		let vm = makeViewModel()
		let tabID = UUID()
		let oldSessionID = UUID()
		let newSessionID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.markHydrationLoaded(for: oldSessionID)
		session.replaceItems([
			.user("running old user", sequenceIndex: 0),
			.assistant("running old assistant", sequenceIndex: 1)
		])
		vm.test_rebuildStructuredTranscript(tabID: tabID)
		vm.test_setCurrentTabIDOverride(tabID)
		defer { vm.test_setCurrentTabIDOverride(nil) }
		vm.test_applySessionToBindings(tabID: tabID)
		XCTAssertTrue(vm.activeTranscriptPresentation.visibleRows.contains { $0.text == "running old user" })

		session.isDirty = false
		session.runState = .running
		vm.test_setLastKnownWorkspaceSnapshot(makeWorkspace(tabID: tabID, sessionID: newSessionID))
		vm.setAgentModeActive(true)

		XCTAssertEqual(session.activeAgentSessionID, oldSessionID)
		XCTAssertEqual(session.hydratedAgentSessionID, oldSessionID)
		XCTAssertFalse(vm.activeTranscriptPresentation.bindingsHydrated)
		XCTAssertTrue(vm.activeTranscriptPresentation.visibleRows.isEmpty)

		session.appendItem(.assistant("running old update", sequenceIndex: 2))
		await vm.test_drainScheduledDerivedTranscriptRefresh(tabID: tabID)

		XCTAssertFalse(vm.activeTranscriptPresentation.bindingsHydrated)
		XCTAssertFalse(vm.activeTranscriptPresentation.visibleRows.contains { $0.text == "running old update" })
		XCTAssertTrue(vm.activeTranscriptPresentation.visibleRows.isEmpty)
	}

	func testDynamicSummaryLockTargetArmsAfterFirstToolActivity() async {
		let vm = makeViewModel()
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.replaceItems(makeToolTurnItems())
		session.runState = .running

		vm.test_rebuildStructuredTranscript(tabID: tabID)
		vm.test_applySessionToBindings(tabID: tabID)

		XCTAssertEqual(
			vm.activeTranscriptPresentation.metadata.dynamicSummaryLockTargetTurnID,
			session.transcript.turns.last?.id
		)
	}

	func testDynamicSummaryLockTargetClearsOnRunCompletion() async {
		let vm = makeViewModel()
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.replaceItems(makeToolTurnItems())
		session.runState = .running

		vm.test_rebuildStructuredTranscript(tabID: tabID)
		vm.test_applySessionToBindings(tabID: tabID)
		XCTAssertEqual(
			vm.activeTranscriptPresentation.metadata.dynamicSummaryLockTargetTurnID,
			session.transcript.turns.last?.id
		)
		let buildCountBeforeCompletion = session.transcriptPerformanceSnapshot.projectionBuildCount
		let revisionBeforeCompletion = vm.test_activeTranscriptPresentationRevisionValue()

		session.runState = .completed

		XCTAssertNil(vm.activeTranscriptPresentation.metadata.dynamicSummaryLockTargetTurnID)
		XCTAssertEqual(session.transcriptPerformanceSnapshot.projectionBuildCount, buildCountBeforeCompletion)
		XCTAssertGreaterThan(vm.test_activeTranscriptPresentationRevisionValue(), revisionBeforeCompletion)
	}

	func testDynamicSummaryLockTargetDoesNotTargetPreviousTurnOnSend() async throws {
		let vm = makeViewModel()
		let tabID = UUID()
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.replaceItems(makeToolTurnItems())

		vm.test_rebuildStructuredTranscript(tabID: tabID)
		vm.test_applySessionToBindings(tabID: tabID)

		let previousTurnID = try XCTUnwrap(session.transcript.turns.last?.id)
		session.runState = .running
		session.appendItem(.user("follow up", sequenceIndex: session.nextSequenceIndex))

		let latestTurnID = try XCTUnwrap(session.transcript.turns.last?.id)
		XCTAssertNotEqual(latestTurnID, previousTurnID)
		XCTAssertEqual(vm.activeTranscriptPresentation.metadata.latestTurnID, latestTurnID)
		XCTAssertNil(vm.activeTranscriptPresentation.metadata.dynamicSummaryLockTargetTurnID)
	}

	private func makeViewModel() -> AgentModeViewModel {
		AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			TranscriptPresentationFakeCodexController()
		}
	}

	private func makeWorkspace(tabID: UUID, sessionID: UUID?) -> WorkspaceModel {
		let tab = ComposeTabState(
			id: tabID,
			name: "Agent Tab",
			activeAgentSessionID: sessionID
		)
		return WorkspaceModel(
			name: "Test Workspace",
			repoPaths: [FileManager.default.currentDirectoryPath],
			composeTabs: [tab],
			activeComposeTabID: tabID
		)
	}

	private func makeTranscriptItems(turnCount: Int) -> [AgentChatItem] {
		var items: [AgentChatItem] = []
		var sequenceIndex = 0
		for turn in 0..<turnCount {
			items.append(.user("user \(turn)", sequenceIndex: sequenceIndex))
			sequenceIndex += 1
			items.append(.assistant("assistant \(turn)", sequenceIndex: sequenceIndex))
			sequenceIndex += 1
		}
		return items
	}

	private func makeToolTurnItems() -> [AgentChatItem] {
		let invocationID = UUID()
		return [
			.user("investigate", sequenceIndex: 0),
			.toolCall(name: "read_file", invocationID: invocationID, argsJSON: #"{"path":"File.swift"}"#, sequenceIndex: 1),
			.toolResult(name: "read_file", invocationID: invocationID, resultJSON: #"{"status":"success"}"#, isError: false, sequenceIndex: 2),
			.assistant("done", sequenceIndex: 3)
		]
	}
}

private final class TranscriptPresentationFakeCodexController: CodexSessionControlling {
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
