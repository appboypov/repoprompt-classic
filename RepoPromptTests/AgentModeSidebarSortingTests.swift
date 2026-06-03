import XCTest
@testable import RepoPrompt

@MainActor
final class AgentModeSidebarSortingTests: XCTestCase {
	func testAutoArchivePolicyLeavesTwentyFiveOrFewerSessionsAlone() {
		let now = Date(timeIntervalSince1970: 1_000_000)
		let rows = (0..<25).map { index in
			makePolicyRow(index: index, lastUserMessageAt: now.addingTimeInterval(-10 * 24 * 60 * 60))
		}

		let decision = AgentModeSidebarAutoArchivePolicy().decision(
			for: rows,
			currentTabID: nil,
			protectedTabIDs: [],
			now: now
		)

		XCTAssertEqual(decision.evaluatedSessionCount, 25)
		XCTAssertTrue(decision.tabIDsToArchive.isEmpty)
	}

	func testAutoArchivePolicyArchivesInactiveOlderGroupsOnlyAfterThreshold() {
		let now = Date(timeIntervalSince1970: 1_000_000)
		let recentRows = (0..<25).map { index in
			makePolicyRow(index: index, lastUserMessageAt: now.addingTimeInterval(-60 * TimeInterval(index + 1)))
		}
		let inactiveRows = (25..<30).map { index in
			makePolicyRow(index: index, lastUserMessageAt: now.addingTimeInterval(-6 * 24 * 60 * 60))
		}
		let rows = recentRows + inactiveRows

		let decision = AgentModeSidebarAutoArchivePolicy().decision(
			for: rows,
			currentTabID: nil,
			protectedTabIDs: [],
			now: now
		)

		XCTAssertEqual(decision.normalInactiveTabIDs, Set(inactiveRows.map(\.tabID)))
		XCTAssertTrue(decision.overflowTabIDs.isEmpty)
		XCTAssertEqual(decision.tabIDsToArchive, Set(inactiveRows.map(\.tabID)))
	}

	func testAutoArchivePolicyProtectsParentThreadWithRecentChildEngagement() {
		let now = Date(timeIntervalSince1970: 1_000_000)
		let parentSessionID = UUID()
		let childSessionID = UUID()
		let parent = makePolicyRow(
			index: 0,
			sessionID: parentSessionID,
			lastUserMessageAt: now.addingTimeInterval(-10 * 24 * 60 * 60)
		)
		let child = makePolicyRow(
			index: 1,
			sessionID: childSessionID,
			parentSessionID: parentSessionID,
			lastUserMessageAt: now.addingTimeInterval(-60)
		)
		let inactiveRows = (2..<30).map { index in
			makePolicyRow(index: index, lastUserMessageAt: now.addingTimeInterval(-8 * 24 * 60 * 60 - TimeInterval(index * 60)))
		}

		let decision = AgentModeSidebarAutoArchivePolicy().decision(
			for: [parent, child] + inactiveRows,
			currentTabID: nil,
			protectedTabIDs: [],
			now: now
		)

		XCTAssertFalse(decision.tabIDsToArchive.contains(parent.tabID))
		XCTAssertFalse(decision.tabIDsToArchive.contains(child.tabID))
		XCTAssertEqual(decision.tabIDsToArchive, Set(inactiveRows.suffix(5).map(\.tabID)))
	}

	func testAutoArchivePolicyProtectsCurrentPinnedMCPAndRuntimeProtectedRows() {
		let now = Date(timeIntervalSince1970: 1_000_000)
		let current = makePolicyRow(index: 0, lastUserMessageAt: now.addingTimeInterval(-10 * 24 * 60 * 60))
		let pinned = makePolicyRow(index: 1, lastUserMessageAt: now.addingTimeInterval(-10 * 24 * 60 * 60), isPinned: true)
		let mcp = makePolicyRow(index: 2, lastUserMessageAt: now.addingTimeInterval(-10 * 24 * 60 * 60), isMCPControlled: true)
		let runtimeProtected = makePolicyRow(index: 3, lastUserMessageAt: now.addingTimeInterval(-10 * 24 * 60 * 60))
		let archiveable = (4..<30).map { index in
			makePolicyRow(index: index, lastUserMessageAt: now.addingTimeInterval(-10 * 24 * 60 * 60 - TimeInterval(index * 60)))
		}

		let decision = AgentModeSidebarAutoArchivePolicy().decision(
			for: [current, pinned, mcp, runtimeProtected] + archiveable,
			currentTabID: current.tabID,
			protectedTabIDs: [runtimeProtected.tabID],
			now: now
		)

		XCTAssertFalse(decision.tabIDsToArchive.contains(current.tabID))
		XCTAssertFalse(decision.tabIDsToArchive.contains(pinned.tabID))
		XCTAssertFalse(decision.tabIDsToArchive.contains(mcp.tabID))
		XCTAssertFalse(decision.tabIDsToArchive.contains(runtimeProtected.tabID))
		XCTAssertEqual(decision.tabIDsToArchive, Set(archiveable.suffix(5).map(\.tabID)))
	}

	func testAutoArchivePolicyDoesNotArchiveRecentRowsAboveFifty() {
		let now = Date(timeIntervalSince1970: 1_000_000)
		let rows = (0..<55).map { index in
			makePolicyRow(index: index, lastUserMessageAt: now.addingTimeInterval(-60 * TimeInterval(index + 1)))
		}

		let decision = AgentModeSidebarAutoArchivePolicy().decision(
			for: rows,
			currentTabID: nil,
			protectedTabIDs: [],
			now: now
		)

		XCTAssertTrue(decision.normalInactiveTabIDs.isEmpty)
		XCTAssertTrue(decision.overflowTabIDs.isEmpty)
		XCTAssertTrue(decision.tabIDsToArchive.isEmpty)
	}

	func testAutoArchivePolicyLeavesTwentyFiveMostRecentRowsWhenAllRowsAreOld() {
		let now = Date(timeIntervalSince1970: 1_000_000)
		let rows = (0..<55).map { index in
			makePolicyRow(index: index, lastUserMessageAt: now.addingTimeInterval(-10 * 24 * 60 * 60 - TimeInterval(index * 60)))
		}

		let decision = AgentModeSidebarAutoArchivePolicy().decision(
			for: rows,
			currentTabID: nil,
			protectedTabIDs: [],
			now: now
		)

		XCTAssertEqual(decision.normalInactiveTabIDs, Set(rows.suffix(30).map(\.tabID)))
		XCTAssertTrue(decision.overflowTabIDs.isEmpty)
		XCTAssertEqual(decision.tabIDsToArchive, Set(rows.suffix(30).map(\.tabID)))
	}

	func testSidebarAutoArchiveProtectedTabIDsIncludesUnloadedPersistedActiveRunState() {
		let vm = makeViewModel()
		let protectedTabID = UUID()
		let protectedSessionID = UUID()
		let completedTabID = UUID()
		let completedSessionID = UUID()
		vm.test_upsertSessionIndex(
			sessionID: protectedSessionID,
			tabID: protectedTabID,
			name: "Waiting Persisted Session",
			lastUserMessageAt: Date(timeIntervalSince1970: 100),
			savedAt: Date(timeIntervalSince1970: 100),
			lastRunStateRaw: AgentSessionRunState.waitingForApproval.rawValue,
			itemCount: 1,
			agentKindRaw: nil,
			agentModelRaw: nil,
			agentReasoningEffortRaw: nil,
			autoEditEnabled: true
		)
		vm.test_upsertSessionIndex(
			sessionID: completedSessionID,
			tabID: completedTabID,
			name: "Completed Persisted Session",
			lastUserMessageAt: Date(timeIntervalSince1970: 100),
			savedAt: Date(timeIntervalSince1970: 100),
			lastRunStateRaw: AgentSessionRunState.completed.rawValue,
			itemCount: 1,
			agentKindRaw: nil,
			agentModelRaw: nil,
			agentReasoningEffortRaw: nil,
			autoEditEnabled: true
		)

		let protectedIDs = vm.sidebarAutoArchiveProtectedTabIDs(for: [
			makePolicyRow(index: 0, tabID: protectedTabID, sessionID: protectedSessionID, lastUserMessageAt: Date(timeIntervalSince1970: 100)),
			makePolicyRow(index: 1, tabID: completedTabID, sessionID: completedSessionID, lastUserMessageAt: Date(timeIntervalSince1970: 100))
		])

		XCTAssertTrue(protectedIDs.contains(protectedTabID))
		XCTAssertFalse(protectedIDs.contains(completedTabID))
	}

	func testSidebarSessionExposesActivityDateFallbackForPolicyDecisions() {
		let vm = makeViewModel()
		let tabID = UUID()
		let sessionID = UUID()
		let activityDate = Date(timeIntervalSince1970: 500)
		vm.ensureSession(for: tabID)
		guard let session = vm.sessions[tabID] else {
			return XCTFail("Expected session for tab")
		}
		session.activeAgentSessionID = sessionID
		session.hasLoadedPersistedState = true
		session.lastUserMessageAt = nil
		session.lastActivityAt = activityDate

		let rows = vm.sidebarSessions(for: [
			ComposeTabState(
				id: tabID,
				name: "Activity Fallback",
				lastModified: Date(timeIntervalSince1970: 100),
				activeAgentSessionID: sessionID
			)
		])

		XCTAssertEqual(rows.first?.lastUserMessageAt, nil)
		XCTAssertEqual(rows.first?.activityDate, activityDate)
	}

	func testSortedArchivedSessionTabsUsesSessionActivityBeforeStashedTime() {
		let vm = makeViewModel()
		let pinnedTabID = UUID(uuidString: "00000000-0000-0000-0000-00000000A001")!
		let engagedTabID = UUID(uuidString: "00000000-0000-0000-0000-00000000A002")!
		let updatedTabID = UUID(uuidString: "00000000-0000-0000-0000-00000000A003")!
		let staleTabID = UUID(uuidString: "00000000-0000-0000-0000-00000000A004")!
		let pinnedSessionID = UUID()
		let engagedSessionID = UUID()
		let updatedSessionID = UUID()
		let staleSessionID = UUID()

		vm.test_upsertSessionIndex(
			sessionID: pinnedSessionID,
			tabID: pinnedTabID,
			name: "Pinned Old",
			lastUserMessageAt: Date(timeIntervalSince1970: 100),
			savedAt: Date(timeIntervalSince1970: 100),
			lastRunStateRaw: nil,
			itemCount: 1,
			agentKindRaw: nil,
			agentModelRaw: nil,
			agentReasoningEffortRaw: nil,
			autoEditEnabled: true
		)
		vm.test_upsertSessionIndex(
			sessionID: engagedSessionID,
			tabID: engagedTabID,
			name: "Recently Engaged",
			lastUserMessageAt: Date(timeIntervalSince1970: 300),
			savedAt: Date(timeIntervalSince1970: 10),
			lastRunStateRaw: nil,
			itemCount: 1,
			agentKindRaw: nil,
			agentModelRaw: nil,
			agentReasoningEffortRaw: nil,
			autoEditEnabled: true
		)
		vm.test_upsertSessionIndex(
			sessionID: updatedSessionID,
			tabID: updatedTabID,
			name: "Updated Fallback",
			lastUserMessageAt: nil,
			savedAt: Date(timeIntervalSince1970: 250),
			lastRunStateRaw: nil,
			itemCount: 1,
			agentKindRaw: nil,
			agentModelRaw: nil,
			agentReasoningEffortRaw: nil,
			autoEditEnabled: true
		)
		vm.test_upsertSessionIndex(
			sessionID: staleSessionID,
			tabID: staleTabID,
			name: "Stale But Newly Archived",
			lastUserMessageAt: Date(timeIntervalSince1970: 50),
			savedAt: Date(timeIntervalSince1970: 50),
			lastRunStateRaw: nil,
			itemCount: 1,
			agentKindRaw: nil,
			agentModelRaw: nil,
			agentReasoningEffortRaw: nil,
			autoEditEnabled: true
		)

		let stashedTabs = [
			makeStashedTab(tabID: staleTabID, sessionID: staleSessionID, name: "Stale But Newly Archived", stashedAt: Date(timeIntervalSince1970: 2_000)),
			makeStashedTab(tabID: updatedTabID, sessionID: updatedSessionID, name: "Updated Fallback", stashedAt: Date(timeIntervalSince1970: 1_000)),
			makeStashedTab(tabID: engagedTabID, sessionID: engagedSessionID, name: "Recently Engaged", stashedAt: Date(timeIntervalSince1970: 10)),
			makeStashedTab(tabID: pinnedTabID, sessionID: pinnedSessionID, name: "Pinned Old", isPinned: true, stashedAt: Date(timeIntervalSince1970: 20))
		]

		let sorted = vm.sortedArchivedSessionTabs(stashedTabs)

		XCTAssertEqual(sorted.map(\.tab.id), [pinnedTabID, engagedTabID, updatedTabID, staleTabID])
		XCTAssertEqual(vm.archivedSessionDateInfo(for: stashedTabs[1]).lastEngagementAt, nil)
		XCTAssertEqual(vm.archivedSessionDateInfo(for: stashedTabs[1]).activityDate, Date(timeIntervalSince1970: 250))
		XCTAssertEqual(vm.sortedArchivedSessionTabs(stashedTabs, searchText: "Updated").map(\.tab.id), [updatedTabID])
	}

	func testFilteredArchivedSessionTabsPreservesInputOrderAndSearch() {
		let vm = makeViewModel()
		let firstMatchTabID = UUID(uuidString: "00000000-0000-0000-0000-00000000B001")!
		let secondMatchTabID = UUID(uuidString: "00000000-0000-0000-0000-00000000B002")!
		let otherMatchTabID = UUID(uuidString: "00000000-0000-0000-0000-00000000B003")!
		let nonAgentTabID = UUID(uuidString: "00000000-0000-0000-0000-00000000B004")!
		let firstMatchSessionID = UUID()
		let secondMatchSessionID = UUID()
		let otherMatchSessionID = UUID()
		let missingSessionID = UUID()

		func upsertIndexedSession(sessionID: UUID, tabID: UUID, name: String) {
			vm.test_upsertSessionIndex(
				sessionID: sessionID,
				tabID: tabID,
				name: name,
				lastUserMessageAt: Date(timeIntervalSince1970: 100),
				savedAt: Date(timeIntervalSince1970: 100),
				lastRunStateRaw: nil,
				itemCount: 1,
				agentKindRaw: nil,
				agentModelRaw: nil,
				agentReasoningEffortRaw: nil,
				autoEditEnabled: true
			)
		}

		upsertIndexedSession(sessionID: firstMatchSessionID, tabID: firstMatchTabID, name: "Needle First")
		upsertIndexedSession(sessionID: secondMatchSessionID, tabID: secondMatchTabID, name: "Needle Second")
		upsertIndexedSession(sessionID: otherMatchSessionID, tabID: otherMatchTabID, name: "Other Archived")

		let stashedTabs = [
			makeStashedTab(tabID: secondMatchTabID, sessionID: secondMatchSessionID, name: "Needle Second", stashedAt: Date(timeIntervalSince1970: 200)),
			makeStashedTab(tabID: nonAgentTabID, sessionID: missingSessionID, name: "Needle Missing", stashedAt: Date(timeIntervalSince1970: 300)),
			makeStashedTab(tabID: firstMatchTabID, sessionID: firstMatchSessionID, name: "Needle First", stashedAt: Date(timeIntervalSince1970: 100)),
			makeStashedTab(tabID: otherMatchTabID, sessionID: otherMatchSessionID, name: "Other Archived", stashedAt: Date(timeIntervalSince1970: 400))
		]

		XCTAssertEqual(
			vm.filteredArchivedSessionTabs(stashedTabs).map(\.tab.id),
			[secondMatchTabID, firstMatchTabID, otherMatchTabID]
		)
		XCTAssertEqual(
			vm.filteredArchivedSessionTabs(stashedTabs, searchText: " needle ").map(\.tab.id),
			[secondMatchTabID, firstMatchTabID]
		)
	}

	func testSortedFilteredArchivedSessionTabsMatchesExistingSortedArchivedSessionTabs() {
		let vm = makeViewModel()
		let pinnedTabID = UUID(uuidString: "00000000-0000-0000-0000-00000000C001")!
		let newestTabID = UUID(uuidString: "00000000-0000-0000-0000-00000000C002")!
		let olderTabID = UUID(uuidString: "00000000-0000-0000-0000-00000000C003")!
		let ignoredTabID = UUID(uuidString: "00000000-0000-0000-0000-00000000C004")!
		let pinnedSessionID = UUID()
		let newestSessionID = UUID()
		let olderSessionID = UUID()

		for (sessionID, tabID, name, lastUserMessageAt) in [
			(pinnedSessionID, pinnedTabID, "Needle Pinned", Date(timeIntervalSince1970: 50)),
			(newestSessionID, newestTabID, "Needle Newest", Date(timeIntervalSince1970: 300)),
			(olderSessionID, olderTabID, "Needle Older", Date(timeIntervalSince1970: 100))
		] {
			vm.test_upsertSessionIndex(
				sessionID: sessionID,
				tabID: tabID,
				name: name,
				lastUserMessageAt: lastUserMessageAt,
				savedAt: lastUserMessageAt,
				lastRunStateRaw: nil,
				itemCount: 1,
				agentKindRaw: nil,
				agentModelRaw: nil,
				agentReasoningEffortRaw: nil,
				autoEditEnabled: true
			)
		}

		let stashedTabs = [
			makeStashedTab(tabID: olderTabID, sessionID: olderSessionID, name: "Needle Older", stashedAt: Date(timeIntervalSince1970: 500)),
			makeStashedTab(tabID: pinnedTabID, sessionID: pinnedSessionID, name: "Needle Pinned", isPinned: true, stashedAt: Date(timeIntervalSince1970: 100)),
			makeStashedTab(tabID: ignoredTabID, sessionID: UUID(), name: "Other Missing", stashedAt: Date(timeIntervalSince1970: 900)),
			makeStashedTab(tabID: newestTabID, sessionID: newestSessionID, name: "Needle Newest", stashedAt: Date(timeIntervalSince1970: 200))
		]

		let filtered = vm.filteredArchivedSessionTabs(stashedTabs, searchText: "Needle")
		let sortedFiltered = vm.sortedFilteredArchivedSessionTabs(filtered)
		let existingSorted = vm.sortedArchivedSessionTabs(stashedTabs, searchText: "Needle")

		XCTAssertEqual(sortedFiltered.map(\.tab.id), existingSorted.map(\.tab.id))
		XCTAssertEqual(sortedFiltered.map(\.tab.id), [pinnedTabID, newestTabID, olderTabID])
	}

	func testSidebarDateSectionBucketUsesTodayYesterdayPrevious() {
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = TimeZone(secondsFromGMT: 0)!
		let now = calendar.date(from: DateComponents(year: 2026, month: 4, day: 23, hour: 12))!
		let today = calendar.date(byAdding: .hour, value: -2, to: now)!
		let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
		let previous = calendar.date(byAdding: .day, value: -2, to: now)!
		let future = calendar.date(byAdding: .day, value: 1, to: now)!

		XCTAssertEqual(AgentSidebarDateSectionBucket.bucket(for: today, relativeTo: now, calendar: calendar), .today)
		XCTAssertEqual(AgentSidebarDateSectionBucket.bucket(for: yesterday, relativeTo: now, calendar: calendar), .yesterday)
		XCTAssertEqual(AgentSidebarDateSectionBucket.bucket(for: previous, relativeTo: now, calendar: calendar), .previous)
		XCTAssertEqual(AgentSidebarDateSectionBucket.bucket(for: future, relativeTo: now, calendar: calendar), .today)
	}

	func testSidebarDateSectionsKeepThreadGroupsContiguousInDisplayedOrder() {
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = TimeZone(secondsFromGMT: 0)!
		let now = calendar.date(from: DateComponents(year: 2026, month: 4, day: 23, hour: 12))!
		let today = calendar.date(byAdding: .hour, value: -2, to: now)!
		let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
		let previous = calendar.date(byAdding: .day, value: -2, to: now)!
		let parentTabID = UUID()
		let childTabID = UUID()
		let yesterdayTabID = UUID()
		let previousTabID = UUID()
		let laterTodayTabID = UUID()
		let parentSessionID = UUID()

		let rows = [
			makePolicyRow(index: 0, tabID: parentTabID, sessionID: parentSessionID, lastUserMessageAt: previous),
			makePolicyRow(index: 1, tabID: childTabID, parentSessionID: parentSessionID, lastUserMessageAt: today),
			makePolicyRow(index: 2, tabID: yesterdayTabID, lastUserMessageAt: yesterday),
			makePolicyRow(index: 3, tabID: previousTabID, lastUserMessageAt: previous),
			makePolicyRow(index: 4, tabID: laterTodayTabID, lastUserMessageAt: today)
		]

		let sections = AgentSidebarDateSectionBuilder.activeSections(
			for: rows,
			now: now,
			calendar: calendar
		)

		XCTAssertEqual(sections.map(\.bucket), [.today, .yesterday, .previous, .today])
		XCTAssertEqual(sections[0].groups.flatMap { $0.rows.map(\.tabID) }, [parentTabID, childTabID])
		XCTAssertEqual(sections[1].groups.flatMap { $0.rows.map(\.tabID) }, [yesterdayTabID])
		XCTAssertEqual(sections[2].groups.flatMap { $0.rows.map(\.tabID) }, [previousTabID])
		XCTAssertEqual(sections[3].groups.flatMap { $0.rows.map(\.tabID) }, [laterTodayTabID])
	}

	func testArchivedDateSectionsUseEngagementActivityAndFallbackDates() {
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = TimeZone(secondsFromGMT: 0)!
		let now = calendar.date(from: DateComponents(year: 2026, month: 4, day: 23, hour: 12))!
		let today = calendar.date(byAdding: .hour, value: -2, to: now)!
		let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
		let previous = calendar.date(byAdding: .day, value: -2, to: now)!
		let todayEngagedTabID = UUID()
		let todayUpdatedTabID = UUID()
		let yesterdayTabID = UUID()
		let previousFallbackTabID = UUID()
		let todayEngaged = makeStashedTab(tabID: todayEngagedTabID, sessionID: UUID(), name: "Today Engaged", stashedAt: previous)
		let todayUpdated = makeStashedTab(tabID: todayUpdatedTabID, sessionID: UUID(), name: "Today Updated", stashedAt: previous)
		let yesterdayEngaged = makeStashedTab(tabID: yesterdayTabID, sessionID: UUID(), name: "Yesterday", stashedAt: previous)
		let previousFallback = makeStashedTab(tabID: previousFallbackTabID, sessionID: UUID(), name: "Previous", stashedAt: previous)
		let infoByID: [UUID: AgentModeViewModel.SidebarSessionDateInfo] = [
			todayEngaged.id: AgentModeViewModel.SidebarSessionDateInfo(lastEngagementAt: today, activityDate: previous),
			todayUpdated.id: AgentModeViewModel.SidebarSessionDateInfo(lastEngagementAt: nil, activityDate: today),
			yesterdayEngaged.id: AgentModeViewModel.SidebarSessionDateInfo(lastEngagementAt: yesterday, activityDate: today),
			previousFallback.id: AgentModeViewModel.SidebarSessionDateInfo(lastEngagementAt: nil, activityDate: nil)
		]

		let sections = AgentSidebarDateSectionBuilder.archivedSections(
			for: [todayEngaged, todayUpdated, yesterdayEngaged, previousFallback],
			now: now,
			calendar: calendar,
			dateInfo: { infoByID[$0.id]! }
		)

		XCTAssertEqual(sections.map(\.bucket), [.today, .yesterday, .previous])
		XCTAssertEqual(sections[0].rows.map { $0.stashed.tab.id }, [todayEngagedTabID, todayUpdatedTabID])
		XCTAssertEqual(sections[1].rows.map { $0.stashed.tab.id }, [yesterdayTabID])
		XCTAssertEqual(sections[2].rows.map { $0.stashed.tab.id }, [previousFallbackTabID])
	}

	func testSidebarSessionsPrefixesPinnedSessionsWithoutChangingBaseOrder() {
		let vm = makeViewModel()
		let firstPinnedID = UUID(uuidString: "00000000-0000-0000-0000-0000000000E1")!
		let secondPinnedID = UUID(uuidString: "00000000-0000-0000-0000-0000000000E2")!
		let unpinnedID = UUID(uuidString: "00000000-0000-0000-0000-0000000000E3")!

		for tabID in [firstPinnedID, secondPinnedID, unpinnedID] {
			vm.ensureSession(for: tabID)
		}
		guard let firstPinnedSession = vm.sessions[firstPinnedID],
			let secondPinnedSession = vm.sessions[secondPinnedID],
			let unpinnedSession = vm.sessions[unpinnedID] else {
			return XCTFail("Expected sessions for all tabs")
		}
		firstPinnedSession.lastUserMessageAt = Date(timeIntervalSince1970: 100)
		secondPinnedSession.lastUserMessageAt = Date(timeIntervalSince1970: 300)
		unpinnedSession.lastUserMessageAt = Date(timeIntervalSince1970: 200)

		let tabs = [
			ComposeTabState(id: firstPinnedID, name: "First Pinned", lastModified: Date(timeIntervalSince1970: 1), isPinned: true),
			ComposeTabState(id: secondPinnedID, name: "Second Pinned", lastModified: Date(timeIntervalSince1970: 2), isPinned: true),
			ComposeTabState(id: unpinnedID, name: "Unpinned", lastModified: Date(timeIntervalSince1970: 3), isPinned: false)
		]

		XCTAssertEqual(vm.sidebarSessions(for: tabs).map(\.tabID), [secondPinnedID, firstPinnedID, unpinnedID])
	}

	#if DEBUG
	func testFingerprintDeltaDiagnosticsClassifiesLastActivityOnly() {
		let tabID = UUID()
		let before = makeDebugFingerprint(
			sessionSignatures: [makeDebugSessionSignature(tabID: tabID, lastActivityAt: Date(timeIntervalSince1970: 10))]
		)
		let after = makeDebugFingerprint(
			sessionSignatures: [makeDebugSessionSignature(tabID: tabID, lastActivityAt: Date(timeIntervalSince1970: 20))]
		)

		let delta = after.debugDeltaDiagnostics(from: before)

		XCTAssertEqual(delta.categories, ["session.lastActivityAt"])
		XCTAssertEqual(delta.changedSessionSignatureCount, 1)
		XCTAssertEqual(delta.changedSessionLastActivityCount, 1)
		XCTAssertEqual(delta.changedSessionLastUserMessageCount, 0)
		XCTAssertEqual(delta.changedSessionRunStateCount, 0)
	}

	func testFingerprintDeltaDiagnosticsClassifiesTabMetadataChanges() {
		let tabID = UUID()
		let sessionID = UUID()
		let before = makeDebugFingerprint(
			tabMetadataSignatures: [
				makeDebugTabMetadata(
					tabID: tabID,
					normalizedName: "before",
					isPinned: false,
					lastModified: Date(timeIntervalSince1970: 10),
					activeAgentSessionID: sessionID
				)
			]
		)
		let after = makeDebugFingerprint(
			tabMetadataSignatures: [
				makeDebugTabMetadata(
					tabID: tabID,
					normalizedName: "after",
					isPinned: true,
					lastModified: Date(timeIntervalSince1970: 20),
					activeAgentSessionID: sessionID
				)
			]
		)

		let delta = after.debugDeltaDiagnostics(from: before)

		XCTAssertEqual(delta.categories, ["tabMetadata.name", "tabMetadata.isPinned", "tabMetadata.lastModified"])
		XCTAssertEqual(delta.changedTabMetadataCount, 1)
		XCTAssertEqual(delta.changedTabNameCount, 1)
		XCTAssertEqual(delta.changedTabLastModifiedCount, 1)
	}

	func testFingerprintDeltaDiagnosticsClassifiesSessionIndexChange() {
		let tabID = UUID()
		let sessionID = UUID()
		let before = makeDebugFingerprint(sessionIndex: [:])
		let after = makeDebugFingerprint(sessionIndex: [sessionID: makeDebugIndexEntry(sessionID: sessionID, tabID: tabID)])

		let delta = after.debugDeltaDiagnostics(from: before)

		XCTAssertEqual(delta.categories, ["sessionIndex"])
		XCTAssertTrue(delta.sessionIndexChanged)
		XCTAssertFalse(delta.sortDatesChanged)
	}

	func testFingerprintDeltaDiagnosticsClassifiesNoneAndInitial() {
		let fingerprint = makeDebugFingerprint()

		XCTAssertEqual(fingerprint.debugDeltaDiagnostics(from: nil).categories, ["initial"])
		XCTAssertEqual(fingerprint.debugDeltaDiagnostics(from: fingerprint).categories, ["none"])
	}
	#endif

	func testForcedSidebarRefreshPublishesWhenRenderedTabTitleChanges() {
		let vm = makeViewModel()
		let tabID = UUID(uuidString: "00000000-0000-0000-0000-0000000000F1")!
		let sessionID = UUID(uuidString: "00000000-0000-0000-0000-0000000000F2")!
		vm.ensureSession(for: tabID)
		guard let session = vm.sessions[tabID] else {
			return XCTFail("Expected session for tab")
		}
		session.activeAgentSessionID = sessionID
		session.hasLoadedPersistedState = false

		let originalTabs = [
			ComposeTabState(
				id: tabID,
				name: "Original Title",
				lastModified: Date(timeIntervalSince1970: 1),
				activeAgentSessionID: sessionID
			)
		]
		vm.syncSidebarUIState(refresh: true, reason: .sessionName, sidebarTabs: originalTabs)
		let firstRevision = vm.ui.sessionSidebar.snapshot.revision
		vm.syncSidebarUIState(refresh: true, reason: .sessionName, sidebarTabs: originalTabs)
		XCTAssertEqual(vm.ui.sessionSidebar.snapshot.revision, firstRevision)

		let renamedTabs = [
			ComposeTabState(
				id: tabID,
				name: "Renamed Title",
				lastModified: Date(timeIntervalSince1970: 1),
				activeAgentSessionID: sessionID
			)
		]
		XCTAssertEqual(vm.sidebarSessions(for: renamedTabs).first?.title, "Renamed Title")
		vm.syncSidebarUIState(refresh: true, reason: .sessionName, sidebarTabs: renamedTabs)

		XCTAssertEqual(vm.ui.sessionSidebar.snapshot.revision, firstRevision + 1)
	}

	func testForcedSidebarRefreshPublishesWhenRenderedTabPinMetadataChanges() {
		let vm = makeViewModel()
		let tabID = UUID(uuidString: "00000000-0000-0000-0000-0000000000F3")!
		let sessionID = UUID(uuidString: "00000000-0000-0000-0000-0000000000F4")!
		vm.ensureSession(for: tabID)
		guard let session = vm.sessions[tabID] else {
			return XCTFail("Expected session for tab")
		}
		session.activeAgentSessionID = sessionID

		let unpinnedTabs = [
			ComposeTabState(
				id: tabID,
				name: "Pinned Boundary",
				lastModified: Date(timeIntervalSince1970: 1),
				isPinned: false,
				activeAgentSessionID: sessionID
			)
		]
		vm.syncSidebarUIState(refresh: true, reason: .sessionList, sidebarTabs: unpinnedTabs)
		let firstRevision = vm.ui.sessionSidebar.snapshot.revision

		let pinnedTabs = [
			ComposeTabState(
				id: tabID,
				name: "Pinned Boundary",
				lastModified: Date(timeIntervalSince1970: 1),
				isPinned: true,
				activeAgentSessionID: sessionID
			)
		]
		vm.syncSidebarUIState(refresh: true, reason: .sessionList, sidebarTabs: pinnedTabs)

		XCTAssertEqual(vm.ui.sessionSidebar.snapshot.revision, firstRevision + 1)
	}

	func testSidebarSessionsUnpinReturnsSessionToBaseOrder() {
		let vm = makeViewModel()
		let pinnedID = UUID(uuidString: "00000000-0000-0000-0000-0000000000E8")!
		let middleID = UUID(uuidString: "00000000-0000-0000-0000-0000000000E9")!
		let oldestID = UUID(uuidString: "00000000-0000-0000-0000-0000000000EA")!

		for tabID in [pinnedID, middleID, oldestID] {
			vm.ensureSession(for: tabID)
		}
		guard let pinnedSession = vm.sessions[pinnedID],
			let middleSession = vm.sessions[middleID],
			let oldestSession = vm.sessions[oldestID] else {
			return XCTFail("Expected sessions for all tabs")
		}
		pinnedSession.lastUserMessageAt = Date(timeIntervalSince1970: 100)
		middleSession.lastUserMessageAt = Date(timeIntervalSince1970: 200)
		oldestSession.lastUserMessageAt = Date(timeIntervalSince1970: 50)

		let baseTabs = [
			ComposeTabState(id: pinnedID, name: "Pinned", lastModified: Date(timeIntervalSince1970: 1), isPinned: true),
			ComposeTabState(id: middleID, name: "Middle", lastModified: Date(timeIntervalSince1970: 2), isPinned: false),
			ComposeTabState(id: oldestID, name: "Oldest", lastModified: Date(timeIntervalSince1970: 3), isPinned: false)
		]
		XCTAssertEqual(vm.sidebarSessions(for: baseTabs).map(\.tabID), [pinnedID, middleID, oldestID])

		let unpinnedTabs = [
			ComposeTabState(id: pinnedID, name: "Pinned", lastModified: Date(timeIntervalSince1970: 1), isPinned: false),
			ComposeTabState(id: middleID, name: "Middle", lastModified: Date(timeIntervalSince1970: 2), isPinned: false),
			ComposeTabState(id: oldestID, name: "Oldest", lastModified: Date(timeIntervalSince1970: 3), isPinned: false)
		]
		XCTAssertEqual(vm.sidebarSessions(for: unpinnedTabs).map(\.tabID), [middleID, pinnedID, oldestID])
	}

	func testSortTabsForSessionSidebarPlacesPinnedTabsFirst() {
		let vm = makeViewModel()
		let pinnedID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
		let recentUnpinnedID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C2")!

		vm.ensureSession(for: pinnedID)
		vm.ensureSession(for: recentUnpinnedID)
		guard let pinnedSession = vm.sessions[pinnedID],
			let recentSession = vm.sessions[recentUnpinnedID] else {
			return XCTFail("Expected sessions for both tabs")
		}
		pinnedSession.lastUserMessageAt = Date(timeIntervalSince1970: 100)
		recentSession.lastUserMessageAt = Date(timeIntervalSince1970: 200)

		let tabs = [
			ComposeTabState(id: pinnedID, name: "Pinned", lastModified: Date(timeIntervalSince1970: 1), isPinned: true),
			ComposeTabState(id: recentUnpinnedID, name: "Recent", lastModified: Date(timeIntervalSince1970: 2), isPinned: false)
		]

		XCTAssertEqual(vm.sortTabsForSessionSidebar(tabs).map(\.id), [pinnedID, recentUnpinnedID])
		XCTAssertEqual(vm.sidebarSessions(for: tabs).map(\.tabID), [pinnedID, recentUnpinnedID])
	}

	func testSortTabsForSessionSidebarPreservesInputOrderWhenMessageTimestampsTie() {
		let vm = makeViewModel()
		let sharedDate = Date(timeIntervalSince1970: 500)
		let id1 = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
		let id2 = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
		let id3 = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
		let id4 = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
		
		for id in [id1, id2, id3, id4] {
			vm.ensureSession(for: id)
			guard let session = vm.sessions[id] else {
				return XCTFail("Expected session for tab \(id)")
			}
			session.lastUserMessageAt = sharedDate
		}
		
		let tabs: [ComposeTabState] = [
			ComposeTabState(id: id1, name: "Gamma", lastModified: Date(timeIntervalSince1970: 100)),
			ComposeTabState(id: id2, name: "Alpha", lastModified: Date(timeIntervalSince1970: 100)),
			ComposeTabState(id: id3, name: "Alpha", lastModified: Date(timeIntervalSince1970: 100)),
			ComposeTabState(id: id4, name: "Zulu", lastModified: Date(timeIntervalSince1970: 120))
		]
		
		let sorted = vm.sortTabsForSessionSidebar(tabs)
		XCTAssertEqual(sorted.map(\.id), [id1, id2, id3, id4])
	}

	func testSortTabsForSessionSidebarIgnoresTabLastModified() {
		let vm = makeViewModel()
		let newerMessage = Date(timeIntervalSince1970: 1_000)
		let olderMessage = Date(timeIntervalSince1970: 500)
		let firstID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
		let secondID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!

		vm.ensureSession(for: firstID)
		vm.ensureSession(for: secondID)
		guard let firstSession = vm.sessions[firstID],
			let secondSession = vm.sessions[secondID] else {
			return XCTFail("Expected sessions for both tabs")
		}
		firstSession.lastUserMessageAt = newerMessage
		secondSession.lastUserMessageAt = olderMessage

		let tabs: [ComposeTabState] = [
			ComposeTabState(id: firstID, name: "First", lastModified: Date(timeIntervalSince1970: 1)),
			ComposeTabState(id: secondID, name: "Second", lastModified: Date(timeIntervalSince1970: 9_999))
		]

		let sorted = vm.sortTabsForSessionSidebar(tabs)
		XCTAssertEqual(sorted.map(\.id), [firstID, secondID])
	}

	func testSortTabsForSessionSidebarPreservesInputOrderWhenNoMessagesExist() {
		let vm = makeViewModel()
		let firstID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
		let secondID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!

		vm.ensureSession(for: firstID)
		vm.ensureSession(for: secondID)

		let tabs: [ComposeTabState] = [
			ComposeTabState(id: firstID, name: "Older", lastModified: Date(timeIntervalSince1970: 1)),
			ComposeTabState(id: secondID, name: "Newer", lastModified: Date(timeIntervalSince1970: 9_999))
		]

		let sorted = vm.sortTabsForSessionSidebar(tabs)
		XCTAssertEqual(sorted.map(\.id), [firstID, secondID])
	}
	
	func testSortTabsForSessionSidebarDoesNotMutateSortCache() {
		let vm = makeViewModel()
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		guard let session = vm.sessions[tabID] else {
			return XCTFail("Expected session for tab \(tabID)")
		}
		session.lastUserMessageAt = Date(timeIntervalSince1970: 1234)
		
		let before = vm.sessionListSortDates
		let tabs = [ComposeTabState(id: tabID, name: "A", lastModified: Date(timeIntervalSince1970: 1))]
		_ = vm.sortTabsForSessionSidebar(tabs)
		
		XCTAssertEqual(vm.sessionListSortDates, before)
	}

	func testShouldSwallowNewSessionClickWhenCurrentSessionIsUntouched() {
		let vm = makeViewModel()
		let tabID = UUID()
		vm.ensureSession(for: tabID)

		XCTAssertTrue(vm.shouldSwallowNewSessionClick(for: tabID))
	}

	func testShouldNotSwallowNewSessionClickWithoutExistingSession() {
		let vm = makeViewModel()
		let tabID = UUID()

		XCTAssertFalse(vm.shouldSwallowNewSessionClick(for: tabID))
	}

	func testShouldNotSwallowNewSessionClickForUnlinkedTransientSession() {
		let vm = makeViewModel()
		let tabID = UUID()

		_ = vm.test_visibleTranscriptSequenceIndices(tabID: tabID)

		XCTAssertFalse(vm.shouldSwallowNewSessionClick(for: tabID))
	}

	func testShouldNotSwallowNewSessionClickWhenSessionHasInput() {
		let vm = makeViewModel()
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		vm.storeDraftText(for: tabID, "hello")

		XCTAssertFalse(vm.shouldSwallowNewSessionClick(for: tabID))
	}

	func testShouldNotSwallowNewSessionClickWhenSessionHasPendingImageAttachment() {
		let vm = makeViewModel()
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		guard let session = vm.sessions[tabID] else {
			return XCTFail("Expected session for tab \(tabID)")
		}
		session.pendingImageAttachments = [
			AgentImageAttachment(source: .localFile(path: "/tmp/test-image.png"), title: "test-image.png")
		]

		XCTAssertFalse(vm.shouldSwallowNewSessionClick(for: tabID))
	}

	func testShouldNotSwallowNewSessionClickWhenOnlyStructuredTranscriptRemains() {
		let vm = makeViewModel()
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		guard let session = vm.sessions[tabID] else {
			return XCTFail("Expected session for tab \(tabID)")
		}
		let transcript = AgentTranscriptCompactor.compact(
			AgentTranscriptIO.importLegacyItems([
				.user("Investigate", sequenceIndex: 0),
				.assistant("Done", sequenceIndex: 1)
			])
		)
		session.setItemsSilently([], reason: .testOverride)
		session.transcript = transcript
		session.hasLoadedPersistedState = true

		XCTAssertFalse(vm.shouldSwallowNewSessionClick(for: tabID))
	}

	func testClearBindingsPreservesSelection() {
		let vm = makeViewModel()
		vm.selectedAgent = .gemini
		vm.selectedModelRaw = AgentModel.geminiPro25.rawValue
		vm.selectedReasoningEffortRaw = CodexReasoningEffort.high.rawValue

		vm.test_clearBindings()

		XCTAssertEqual(vm.selectedAgent, .gemini)
		XCTAssertEqual(vm.selectedModelRaw, AgentModel.geminiPro25.rawValue)
		XCTAssertEqual(vm.selectedReasoningEffortRaw, CodexReasoningEffort.high.rawValue)
	}

	func testCodexModelSwitchRestoresSavedReasoningEffortForNewModel() {
		let restoreDefaults = preserveUserDefaults(keys: [
			"agentMode.lastUsedAgent",
			"agentMode.lastUsedModelsByAgent",
			"codexAgent.reasoning.lastUsedEffort",
			"agentMode.codex.lastUsedReasoningEffort",
			"codexAgent.reasoning.lastUsedEffortByModelSlug"
		])
		defer { restoreDefaults() }
		let defaults = UserDefaults.standard
		defaults.removeObject(forKey: "agentMode.lastUsedAgent")
		defaults.removeObject(forKey: "agentMode.lastUsedModelsByAgent")
		CodexAgentToolPreferences.setLastUsedReasoningEffort(nil, defaults: defaults)
		defaults.removeObject(forKey: "agentMode.codex.lastUsedReasoningEffort")
		defaults.removeObject(forKey: "codexAgent.reasoning.lastUsedEffortByModelSlug")
		CodexAgentToolPreferences.setLastUsedReasoningEffort(.high, forModelRaw: "gpt-5.3-codex", defaults: defaults)
		CodexAgentToolPreferences.setLastUsedReasoningEffort(.medium, forModelRaw: "gpt-5.4", defaults: defaults)

		let vm = makeViewModel()
		let tabID = UUID()
		vm.test_setCurrentTabIDOverride(tabID)
		vm.ensureSession(for: tabID)
		vm.selectedAgent = .codexExec
		vm.selectedModelRaw = "gpt-5.3-codex"
		XCTAssertEqual(vm.selectedReasoningEffortRaw, CodexReasoningEffort.high.rawValue)

		vm.selectedModelRaw = "gpt-5.4"

		XCTAssertEqual(vm.selectedReasoningEffortRaw, CodexReasoningEffort.medium.rawValue)
		XCTAssertEqual(vm.session(for: tabID).selectedReasoningEffortRaw, CodexReasoningEffort.medium.rawValue)
	}

	func testCodexReasoningEffortSelectionPersistsForCurrentModel() {
		let restoreDefaults = preserveUserDefaults(keys: [
			"agentMode.lastUsedAgent",
			"agentMode.lastUsedModelsByAgent",
			"codexAgent.reasoning.lastUsedEffort",
			"agentMode.codex.lastUsedReasoningEffort",
			"codexAgent.reasoning.lastUsedEffortByModelSlug"
		])
		defer { restoreDefaults() }
		let defaults = UserDefaults.standard
		defaults.removeObject(forKey: "agentMode.lastUsedAgent")
		defaults.removeObject(forKey: "agentMode.lastUsedModelsByAgent")
		CodexAgentToolPreferences.setLastUsedReasoningEffort(nil, defaults: defaults)
		defaults.removeObject(forKey: "agentMode.codex.lastUsedReasoningEffort")
		defaults.removeObject(forKey: "codexAgent.reasoning.lastUsedEffortByModelSlug")

		let vm = makeViewModel()
		let tabID = UUID()
		vm.test_setCurrentTabIDOverride(tabID)
		vm.ensureSession(for: tabID)
		vm.selectedAgent = .codexExec
		vm.selectedModelRaw = "gpt-5.4"

		vm.selectReasoningEffort(.xhigh)

		XCTAssertEqual(vm.selectedReasoningEffortRaw, CodexReasoningEffort.xhigh.rawValue)
		XCTAssertEqual(CodexAgentToolPreferences.lastUsedReasoningEffortsByModelSlug(defaults: defaults)["gpt-5.4"], .xhigh)
		XCTAssertEqual(vm.test_codexCoordinator.lastUsedReasoningEffortByModelSlug["gpt-5.4"], .xhigh)
	}

	func testClaudeModelSwitchRefreshesModelSpecificEffortBinding() throws {
		let restoreDefaults = preserveUserDefaults(keys: [
			"agentMode.lastUsedAgent",
			"agentMode.lastUsedModelsByAgent",
			"claudeCodeEffortLevel",
			"claudeCodeEffortLevelsByModelSlug"
		])
		defer { restoreDefaults() }
		let defaults = UserDefaults.standard
		defaults.removeObject(forKey: "agentMode.lastUsedAgent")
		defaults.removeObject(forKey: "agentMode.lastUsedModelsByAgent")
		ClaudeAgentToolPreferences.setEffortLevel(.medium, defaults: defaults)
		defaults.removeObject(forKey: "claudeCodeEffortLevelsByModelSlug")
		ClaudeAgentToolPreferences.setEffortLevel(.xhigh, forModelRaw: AgentModel.claudeOpus.rawValue, agentKind: .claudeCode, defaults: defaults)
		ClaudeAgentToolPreferences.setEffortLevel(.high, forModelRaw: AgentModel.claudeSonnet.rawValue, agentKind: .claudeCode, defaults: defaults)

		let vm = makeViewModel()
		let tabID = UUID()
		vm.test_setCurrentTabIDOverride(tabID)
		vm.ensureSession(for: tabID)
		vm.selectedAgent = .claudeCode
		vm.selectedModelRaw = AgentModel.claudeOpus.rawValue
		XCTAssertEqual(try XCTUnwrap(vm.activeProviderControlsBinding?.claudeTools).effortLevel, .xhigh)

		vm.selectedModelRaw = AgentModel.claudeSonnet.rawValue

		XCTAssertEqual(try XCTUnwrap(vm.activeProviderControlsBinding?.claudeTools).effortLevel, .high)
	}

	func testInputBarModelDisplayNameOmitsClaudeEffortSuffix() {
		let restoreDefaults = preserveUserDefaults(keys: [
			"agentMode.lastUsedAgent",
			"agentMode.lastUsedModelsByAgent",
			"claudeCodeEffortLevel",
			"claudeCodeEffortLevelsByModelSlug"
		])
		defer { restoreDefaults() }
		let defaults = UserDefaults.standard
		defaults.removeObject(forKey: "agentMode.lastUsedAgent")
		defaults.removeObject(forKey: "agentMode.lastUsedModelsByAgent")
		ClaudeAgentToolPreferences.setEffortLevel(.medium, defaults: defaults)
		defaults.removeObject(forKey: "claudeCodeEffortLevelsByModelSlug")
		ClaudeAgentToolPreferences.setEffortLevel(.xhigh, forModelRaw: AgentModel.claudeOpus1m.rawValue, agentKind: .claudeCode, defaults: defaults)

		let vm = makeViewModel()
		vm.selectedAgent = .claudeCode
		vm.selectedModelRaw = AgentModel.claudeOpus1m.rawValue

		XCTAssertEqual(vm.selectedModelDisplayName, "Opus Latest (1M)")
		XCTAssertEqual(
			AgentModelCatalog.displayName(for: AgentModel.claudeOpus1m.rawValue, agentKind: .claudeCode, defaults: defaults),
			"Opus Latest (1M) XHigh"
		)
	}

	func testInputBarModelDisplayNameOmitsCodexReasoningEffortSuffix() {
		let restoreDefaults = preserveUserDefaults(keys: [
			"agentMode.lastUsedAgent",
			"agentMode.lastUsedModelsByAgent",
			"codexAgent.reasoning.lastUsedEffort",
			"agentMode.codex.lastUsedReasoningEffort",
			"codexAgent.reasoning.lastUsedEffortByModelSlug"
		])
		defer { restoreDefaults() }
		let defaults = UserDefaults.standard
		defaults.removeObject(forKey: "agentMode.lastUsedAgent")
		defaults.removeObject(forKey: "agentMode.lastUsedModelsByAgent")
		CodexAgentToolPreferences.setLastUsedReasoningEffort(nil, defaults: defaults)
		defaults.removeObject(forKey: "agentMode.codex.lastUsedReasoningEffort")
		defaults.removeObject(forKey: "codexAgent.reasoning.lastUsedEffortByModelSlug")
		CodexAgentToolPreferences.setLastUsedReasoningEffort(.xhigh, forModelRaw: "gpt-5.4", defaults: defaults)

		let vm = makeViewModel()
		vm.selectedAgent = .codexExec
		vm.selectedModelRaw = "gpt-5.4"

		XCTAssertEqual(vm.selectedModelDisplayName, "GPT-5.4")
		XCTAssertEqual(
			AgentModelCatalog.displayName(for: "gpt-5.4", agentKind: .codexExec, defaults: defaults),
			"GPT-5.4 XHigh"
		)
	}

	func testClaudeEffortSelectionPersistsForCurrentModel() {
		let restoreDefaults = preserveUserDefaults(keys: [
			"agentMode.lastUsedAgent",
			"agentMode.lastUsedModelsByAgent",
			"claudeCodeEffortLevel",
			"claudeCodeEffortLevelsByModelSlug"
		])
		defer { restoreDefaults() }
		let defaults = UserDefaults.standard
		defaults.removeObject(forKey: "agentMode.lastUsedAgent")
		defaults.removeObject(forKey: "agentMode.lastUsedModelsByAgent")
		ClaudeAgentToolPreferences.setEffortLevel(.medium, defaults: defaults)
		defaults.removeObject(forKey: "claudeCodeEffortLevelsByModelSlug")

		let vm = makeViewModel()
		let tabID = UUID()
		vm.test_setCurrentTabIDOverride(tabID)
		vm.ensureSession(for: tabID)
		vm.selectedAgent = .claudeCode
		vm.selectedModelRaw = AgentModel.claudeSonnet.rawValue

		vm.setClaudeEffortLevel(.high)

		XCTAssertEqual(
			ClaudeAgentToolPreferences.storedEffortLevel(
				forModelRaw: AgentModel.claudeSonnet.rawValue,
				agentKind: .claudeCode,
				defaults: defaults,
				includeLegacyFallback: false
			),
			.high
		)
		XCTAssertNil(
			ClaudeAgentToolPreferences.storedEffortLevel(
				forModelRaw: AgentModel.claudeOpus.rawValue,
				agentKind: .claudeCode,
				defaults: defaults,
				includeLegacyFallback: false
			)
		)
		XCTAssertEqual(vm.activeProviderControlsBinding?.claudeTools?.effortLevel, .high)
	}

	func testMakeSessionInheritsAgentModelAndReasoningSelections() {
		let vm = makeViewModel()
		vm.selectedAgent = .codexExec
		vm.selectedModelRaw = AgentModel.codexHigh.rawValue
		vm.selectedReasoningEffortRaw = CodexReasoningEffort.medium.rawValue

		let tabID = UUID()
		vm.ensureSession(for: tabID)

		guard let session = vm.sessions[tabID] else {
			return XCTFail("Expected session for tab \(tabID)")
		}

		XCTAssertEqual(session.selectedAgent, .codexExec)
		XCTAssertEqual(session.selectedModelRaw, AgentModel.codexHigh.rawValue)
		XCTAssertEqual(session.selectedReasoningEffortRaw, CodexReasoningEffort.medium.rawValue)
	}

	func testColdInitRestoresCursorAutoWithoutStartingCursorModelPolling() {
		let defaults = UserDefaults.standard
		let previousAgent = defaults.string(forKey: "agentMode.lastUsedAgent")
		let previousModels = defaults.dictionary(forKey: "agentMode.lastUsedModelsByAgent")
		defer {
			if let previousAgent {
				defaults.set(previousAgent, forKey: "agentMode.lastUsedAgent")
			} else {
				defaults.removeObject(forKey: "agentMode.lastUsedAgent")
			}
			if let previousModels {
				defaults.set(previousModels, forKey: "agentMode.lastUsedModelsByAgent")
			} else {
				defaults.removeObject(forKey: "agentMode.lastUsedModelsByAgent")
			}
		}

		defaults.set(DiscoverAgentKind.cursor.rawValue, forKey: "agentMode.lastUsedAgent")
		defaults.set(
			[DiscoverAgentKind.cursor.rawValue: AgentModel.cursorAuto.rawValue],
			forKey: "agentMode.lastUsedModelsByAgent"
		)

		let vm = makeViewModel()

		XCTAssertEqual(vm.selectedAgent, .cursor)
		XCTAssertEqual(vm.selectedModelRaw, AgentModel.cursorAuto.rawValue)
		XCTAssertFalse(vm.test_isCursorModelPollingActive)
	}

	func testSidebarSessionsOmitsUnlinkedBlankComposeTabs() {
		let vm = makeViewModel()
		let tabID = UUID()
		let tabs = [ComposeTabState(id: tabID, name: "Blank", lastModified: Date())]

		XCTAssertTrue(vm.sidebarSessions(for: tabs).isEmpty)
	}

	func testSidebarSessionsShowsNewChatForEmptySession() {
		let vm = makeViewModel()
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		let tabs = [ComposeTabState(id: tabID, name: "T1", lastModified: Date())]

		let sessions = vm.sidebarSessions(for: tabs)
		XCTAssertEqual(sessions.count, 1)
		XCTAssertEqual(sessions.first?.tabID, tabID)
		XCTAssertEqual(sessions.first?.title, "New Chat")
	}

	func testSidebarSessionsShowsRenamedEmptyAgentSessionTitle() {
		let vm = makeViewModel()
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		let tabs = [ComposeTabState(id: tabID, name: "Project Cleanup", lastModified: Date())]

		let sessions = vm.sidebarSessions(for: tabs)
		XCTAssertEqual(sessions.count, 1)
		XCTAssertEqual(sessions.first?.tabID, tabID)
		XCTAssertEqual(sessions.first?.title, "Project Cleanup")
	}

	func testSidebarSessionsReorderOnlyAfterUserMessageTimestampChanges() {
		let vm = makeViewModel()
		let firstTab = UUID()
		let secondTab = UUID()
		vm.ensureSession(for: firstTab)
		vm.ensureSession(for: secondTab)
		vm.storeDraftText(for: firstTab, "draft-1")
		vm.storeDraftText(for: secondTab, "draft-2")
		guard let firstSession = vm.sessions[firstTab],
			let secondSession = vm.sessions[secondTab] else {
			return XCTFail("Expected both sessions")
		}
		firstSession.lastActivityAt = Date(timeIntervalSince1970: 2_000)
		secondSession.lastActivityAt = Date(timeIntervalSince1970: 1_000)

		let tabs = [
			ComposeTabState(id: firstTab, name: "First", lastModified: Date(timeIntervalSince1970: 10)),
			ComposeTabState(id: secondTab, name: "Second", lastModified: Date(timeIntervalSince1970: 20))
		]

		// No sent user messages yet, so order follows newest session recency.
		XCTAssertEqual(vm.sidebarSessions(for: tabs).map(\.tabID), [firstTab, secondTab])

		vm.storeDraftText(for: secondTab, "updated draft")
		XCTAssertEqual(vm.sidebarSessions(for: tabs).map(\.tabID), [firstTab, secondTab])

		secondSession.lastUserMessageAt = Date(timeIntervalSince1970: 3_000)
		XCTAssertEqual(vm.sidebarSessions(for: tabs).map(\.tabID), [secondTab, firstTab])
	}

	func testSidebarSessionsPlacesNewestUnsentChatAtTop() {
		let vm = makeViewModel()
		let firstTab = UUID()
		let secondTab = UUID()
		vm.ensureSession(for: firstTab)
		vm.ensureSession(for: secondTab)
		guard let firstSession = vm.sessions[firstTab],
			let secondSession = vm.sessions[secondTab] else {
			return XCTFail("Expected both sessions")
		}
		firstSession.lastActivityAt = Date(timeIntervalSince1970: 100)
		secondSession.lastActivityAt = Date(timeIntervalSince1970: 200)

		let tabs = [
			ComposeTabState(id: firstTab, name: "First", lastModified: Date(timeIntervalSince1970: 1)),
			ComposeTabState(id: secondTab, name: "Second", lastModified: Date(timeIntervalSince1970: 9_999))
		]

		XCTAssertEqual(vm.sidebarSessions(for: tabs).map(\.tabID), [secondTab, firstTab])
	}

	func testRefreshSessionListCacheRestoresRecencySortingForPersistedUnsentSessions() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let service = AgentSessionDataService.shared
		let olderTab = UUID()
		let newerTab = UUID()
		let olderSessionID = UUID()
		let newerSessionID = UUID()
		let workspace = makeWorkspace(
			name: "Persisted Unsent Recency",
			root: tempRoot,
			composeTabs: [
				ComposeTabState(id: olderTab, name: "Older", lastModified: Date(timeIntervalSince1970: 100), activeAgentSessionID: olderSessionID),
				ComposeTabState(id: newerTab, name: "Newer", lastModified: Date(timeIntervalSince1970: 200), activeAgentSessionID: newerSessionID)
			]
		)
		_ = try await service.saveAgentSession(
			AgentSession(
				id: olderSessionID,
				workspaceID: workspace.id,
				composeTabID: olderTab,
				name: "Older",
				savedAt: Date(timeIntervalSince1970: 300),
				items: [],
				itemCount: 0,
				lastUserMessageAt: nil
			),
			for: workspace
		)
		_ = try await service.saveAgentSession(
			AgentSession(
				id: newerSessionID,
				workspaceID: workspace.id,
				composeTabID: newerTab,
				name: "Newer",
				savedAt: Date(timeIntervalSince1970: 400),
				items: [],
				itemCount: 0,
				lastUserMessageAt: nil
			),
			for: workspace
		)

		let vm = makeViewModel(testWorkspaceDirectory: tempRoot)
		await vm.test_handleWorkspaceSwitch(workspace)
		let deadline = Date().addingTimeInterval(2)
		while !vm.sessionListCacheReady && Date() < deadline {
			await Task.yield()
			try? await Task.sleep(nanoseconds: 10_000_000)
		}

		let sidebar = vm.sidebarSessions(for: workspace.composeTabs)
		XCTAssertEqual(sidebar.map(\.tabID), [newerTab, olderTab])
	}

	func testSidebarSessionsPreserveCachedOrderWhileBoundSessionHydrates() {
		let vm = makeViewModel()
		let firstTab = UUID(uuidString: "00000000-0000-0000-0000-0000000000F4")!
		let secondTab = UUID(uuidString: "00000000-0000-0000-0000-0000000000F5")!
		let firstSessionID = UUID(uuidString: "00000000-0000-0000-0000-0000000000F6")!
		let secondSessionID = UUID(uuidString: "00000000-0000-0000-0000-0000000000F7")!

		vm.test_upsertSessionIndex(
			sessionID: firstSessionID,
			tabID: firstTab,
			name: "First",
			lastUserMessageAt: Date(timeIntervalSince1970: 300),
			savedAt: Date(timeIntervalSince1970: 250),
			lastRunStateRaw: nil,
			itemCount: 3,
			agentKindRaw: nil,
			agentModelRaw: nil,
			agentReasoningEffortRaw: nil,
			autoEditEnabled: false
		)
		vm.test_upsertSessionIndex(
			sessionID: secondSessionID,
			tabID: secondTab,
			name: "Second",
			lastUserMessageAt: Date(timeIntervalSince1970: 200),
			savedAt: Date(timeIntervalSince1970: 150),
			lastRunStateRaw: nil,
			itemCount: 2,
			agentKindRaw: nil,
			agentModelRaw: nil,
			agentReasoningEffortRaw: nil,
			autoEditEnabled: false
		)

		vm.ensureSession(for: firstTab)
		guard let firstSession = vm.sessions[firstTab] else {
			return XCTFail("Expected session for first tab")
		}
		firstSession.activeAgentSessionID = firstSessionID
		firstSession.hasLoadedPersistedState = false
		firstSession.lastActivityAt = Date(timeIntervalSince1970: 9_999)
		firstSession.lastUserMessageAt = nil

		let tabs = [
			ComposeTabState(
				id: firstTab,
				name: "First",
				lastModified: Date(timeIntervalSince1970: 100),
				activeAgentSessionID: firstSessionID
			),
			ComposeTabState(
				id: secondTab,
				name: "Second",
				lastModified: Date(timeIntervalSince1970: 200),
				activeAgentSessionID: secondSessionID
			)
		]

		let sidebar = vm.sidebarSessions(for: tabs)
		XCTAssertEqual(sidebar.map(\.tabID), [firstTab, secondTab])
		let hydratingSession = sidebar.first(where: { $0.tabID == firstTab })
		XCTAssertEqual(hydratingSession?.title, "First")
	}

	func testSidebarSessionsUsesTabLastModifiedWhileBoundSessionHydrates() {
		let vm = makeViewModel()
		let firstTab = UUID()
		let secondTab = UUID()
		let firstSessionID = UUID()
		let secondSessionID = UUID()

		vm.ensureSession(for: firstTab)
		guard let firstSession = vm.sessions[firstTab] else {
			return XCTFail("Expected session for first tab")
		}
		firstSession.activeAgentSessionID = firstSessionID
		firstSession.hasLoadedPersistedState = false
		firstSession.lastActivityAt = Date(timeIntervalSince1970: 9_999)
		firstSession.lastUserMessageAt = nil

		let tabs = [
			ComposeTabState(
				id: firstTab,
				name: "First",
				lastModified: Date(timeIntervalSince1970: 100),
				activeAgentSessionID: firstSessionID
			),
			ComposeTabState(
				id: secondTab,
				name: "Second",
				lastModified: Date(timeIntervalSince1970: 200),
				activeAgentSessionID: secondSessionID
			)
		]

		let sidebar = vm.sidebarSessions(for: tabs)
		// Hydrating sessions should be ordered by persisted tab metadata, not transient in-memory "now".
		XCTAssertEqual(sidebar.map(\.tabID), [secondTab, firstTab])
		// Hydrating bound sessions should retain stable tab titles (avoid "New Chat" flicker).
		let hydratingSession = sidebar.first(where: { $0.tabID == firstTab })
		XCTAssertEqual(hydratingSession?.title, "First")
	}

	func testMarkSessionAsFreshlyCreatedPromotesProvisionalSessionToTop() {
		let vm = makeViewModel()
		let firstTab = UUID()
		let secondTab = UUID()
		let newTab = UUID()
		let firstSessionID = UUID()
		let secondSessionID = UUID()
		let newSessionID = UUID()

		vm.ensureSession(for: firstTab)
		guard let firstSession = vm.sessions[firstTab] else {
			return XCTFail("Expected first session")
		}
		firstSession.activeAgentSessionID = firstSessionID
		firstSession.hasLoadedPersistedState = true
		firstSession.lastActivityAt = Date(timeIntervalSince1970: 100)

		vm.ensureSession(for: secondTab)
		guard let secondSession = vm.sessions[secondTab] else {
			return XCTFail("Expected second session")
		}
		secondSession.activeAgentSessionID = secondSessionID
		secondSession.hasLoadedPersistedState = true
		secondSession.lastActivityAt = Date(timeIntervalSince1970: 200)

		vm.ensureSession(for: newTab)
		guard let newSession = vm.sessions[newTab] else {
			return XCTFail("Expected new session")
		}
		newSession.activeAgentSessionID = newSessionID
		newSession.hasLoadedPersistedState = false
		newSession.lastActivityAt = Date(timeIntervalSince1970: 50)
		vm.test_markSessionAsFreshlyCreated(tabID: newTab)

		let tabs = [
			ComposeTabState(id: firstTab, name: "First", lastModified: Date(timeIntervalSince1970: 1), activeAgentSessionID: firstSessionID),
			ComposeTabState(id: secondTab, name: "Second", lastModified: Date(timeIntervalSince1970: 2), activeAgentSessionID: secondSessionID),
			ComposeTabState(id: newTab, name: "New Session", lastModified: Date(timeIntervalSince1970: 3), activeAgentSessionID: newSessionID)
		]

		XCTAssertEqual(vm.sidebarSessions(for: tabs).first?.tabID, newTab)
		XCTAssertEqual(vm.sidebarSessions(for: tabs).first?.title, "New Chat")
	}

	func testFreshUnfrozenSessionSortsByActivityDuringPartialRestoreFreeze() {
		let vm = makeViewModel()
		let firstTab = UUID()
		let secondTab = UUID()
		let newTab = UUID()
		let firstSessionID = UUID()
		let secondSessionID = UUID()
		let newSessionID = UUID()

		vm.test_upsertSessionIndex(
			sessionID: firstSessionID,
			tabID: firstTab,
			name: "T7",
			lastUserMessageAt: Date(timeIntervalSince1970: 100),
			savedAt: Date(timeIntervalSince1970: 100),
			lastRunStateRaw: nil,
			itemCount: 1,
			agentKindRaw: nil,
			agentModelRaw: nil,
			agentReasoningEffortRaw: nil,
			autoEditEnabled: false
		)
		vm.test_upsertSessionIndex(
			sessionID: secondSessionID,
			tabID: secondTab,
			name: "Tell a Joke",
			lastUserMessageAt: Date(timeIntervalSince1970: 200),
			savedAt: Date(timeIntervalSince1970: 200),
			lastRunStateRaw: nil,
			itemCount: 1,
			agentKindRaw: nil,
			agentModelRaw: nil,
			agentReasoningEffortRaw: nil,
			autoEditEnabled: false
		)

		vm.ensureSession(for: newTab)
		guard let newSession = vm.sessions[newTab] else {
			return XCTFail("Expected new session")
		}
		newSession.activeAgentSessionID = newSessionID
		newSession.hasLoadedPersistedState = true
		newSession.lastActivityAt = Date(timeIntervalSince1970: 300)

		let tabs = [
			ComposeTabState(id: firstTab, name: "T7", lastModified: Date(timeIntervalSince1970: 100), activeAgentSessionID: firstSessionID),
			ComposeTabState(id: secondTab, name: "Tell a Joke", lastModified: Date(timeIntervalSince1970: 200), activeAgentSessionID: secondSessionID),
			ComposeTabState(id: newTab, name: "New Session", lastModified: Date(timeIntervalSince1970: 300), activeAgentSessionID: newSessionID)
		]

		let sidebar = AgentModeSidebarSessionBuilder(
			allTabs: tabs,
			linkedTabs: tabs,
			sessions: vm.sessions,
			sessionIndex: vm.sessionIndex,
			sessionListSortDates: vm.sessionListSortDates,
			sessionListCacheReady: false,
			sidebarRestoreFrozenOrderByTabID: [firstTab: 0, secondTab: 1],
			mcpControlledTabIDs: vm.mcpControlledTabIDs
		).build()

		XCTAssertEqual(sidebar.map(\.tabID), [newTab, secondTab, firstTab])
		XCTAssertEqual(sidebar.first?.title, "New Chat")
	}

	func testRefreshSessionListCacheUsesHeaderOnlyLegacyMetadataForSidebarTitles() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let service = AgentSessionDataService.shared
		let tabID = UUID()
		let workspace = makeWorkspace(
			name: "Sidebar Legacy Metadata",
			root: tempRoot,
			composeTabs: [
				ComposeTabState(
					id: tabID,
					name: "Recovered Session",
					lastModified: Date(timeIntervalSince1970: 500),
					activeAgentSessionID: nil
				)
			]
		)
		let session = AgentSession(
			workspaceID: workspace.id,
			composeTabID: tabID,
			name: "Recovered Session",
			savedAt: Date(timeIntervalSince1970: 400),
			items: [
				AgentChatItemPersist(from: AgentChatItem(timestamp: Date(timeIntervalSince1970: 100), kind: .user, text: "Hello", sequenceIndex: 0)),
				AgentChatItemPersist(from: AgentChatItem(timestamp: Date(timeIntervalSince1970: 200), kind: .assistant, text: "Hi", sequenceIndex: 1))
			],
			itemCount: nil,
			lastUserMessageAt: nil
		)

		let fileURL = try await service.saveAgentSession(session, for: workspace)
		var storedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
		storedObject.removeValue(forKey: "itemCount")
		storedObject.removeValue(forKey: "transcriptProjectionCounts")
		storedObject.removeValue(forKey: "lastUserMessageAt")
		let legacyData = try JSONSerialization.data(withJSONObject: storedObject)
		try legacyData.write(to: fileURL, options: .atomic)
		try? FileManager.default.removeItem(at: metadataIndexURL(root: tempRoot))

		let vm = makeViewModel(testWorkspaceDirectory: tempRoot)
		await vm.test_handleWorkspaceSwitch(workspace)
		let deadline = Date().addingTimeInterval(2)
		while !vm.sessionListCacheReady && Date() < deadline {
			await Task.yield()
			try? await Task.sleep(nanoseconds: 10_000_000)
		}

		let sidebar = vm.sidebarSessions(for: workspace.composeTabs)
		let rewrittenObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
		XCTAssertEqual(sidebar.count, 1)
		XCTAssertEqual(sidebar.first?.tabID, tabID)
		XCTAssertEqual(sidebar.first?.title, "Recovered Session")
		XCTAssertNil(vm.sessionListSortDates[tabID])
		XCTAssertNil(rewrittenObject["itemCount"])
		XCTAssertNil(rewrittenObject["transcriptProjectionCounts"])
		XCTAssertNil(rewrittenObject["lastUserMessageAt"])
	}

	func testRefreshSessionListCachePreservesArchivedLegacySessionVisibilityUntilHydration() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let service = AgentSessionDataService.shared
		let tabID = UUID()
		var workspace = makeWorkspace(name: "Archived Legacy Session", root: tempRoot)
		workspace.stashedTabs = [
			StashedTab(
				tab: ComposeTabState(
					id: tabID,
					name: "Recovered Archived Session",
					lastModified: Date(timeIntervalSince1970: 500),
					activeAgentSessionID: nil
				)
			)
		]
		let session = AgentSession(
			workspaceID: workspace.id,
			composeTabID: tabID,
			name: "Recovered Archived Session",
			savedAt: Date(timeIntervalSince1970: 400),
			items: [
				AgentChatItemPersist(from: AgentChatItem(timestamp: Date(timeIntervalSince1970: 100), kind: .user, text: "Hello", sequenceIndex: 0)),
				AgentChatItemPersist(from: AgentChatItem(timestamp: Date(timeIntervalSince1970: 200), kind: .assistant, text: "Hi", sequenceIndex: 1))
			],
			itemCount: nil,
			lastUserMessageAt: nil
		)

		let fileURL = try await service.saveAgentSession(session, for: workspace)
		var storedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
		storedObject.removeValue(forKey: "itemCount")
		storedObject.removeValue(forKey: "transcriptProjectionCounts")
		storedObject.removeValue(forKey: "lastUserMessageAt")
		let legacyData = try JSONSerialization.data(withJSONObject: storedObject)
		try legacyData.write(to: fileURL, options: .atomic)
		try? FileManager.default.removeItem(at: metadataIndexURL(root: tempRoot))

		let vm = makeViewModel(testWorkspaceDirectory: tempRoot)
		await vm.test_handleWorkspaceSwitch(workspace)
		let deadline = Date().addingTimeInterval(2)
		while !vm.sessionListCacheReady && Date() < deadline {
			await Task.yield()
			try? await Task.sleep(nanoseconds: 10_000_000)
		}

		let archivedTab = try XCTUnwrap(workspace.stashedTabs.first)
		let sidebar = vm.sidebarSessions(for: [archivedTab.tab])
		XCTAssertTrue(vm.shouldShowArchivedSession(for: archivedTab))
		XCTAssertEqual(sidebar.count, 1)
		XCTAssertEqual(sidebar.first?.tabID, tabID)
		XCTAssertEqual(sidebar.first?.title, "Recovered Archived Session")
	}

	func testHandleWorkspaceSwitchDoesNotActiveBindSessionIDFromSidebarBatchWithoutExplicitBinding() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let service = AgentSessionDataService.shared
		let tabID = UUID()
		let workspace = makeWorkspace(
			name: "Active Restore Retry",
			root: tempRoot,
			composeTabs: [
				ComposeTabState(
					id: tabID,
					name: "Restored Active Session",
					lastModified: Date(timeIntervalSince1970: 500),
					activeAgentSessionID: nil
				)
			]
		)
		let session = AgentSession(
			workspaceID: workspace.id,
			composeTabID: tabID,
			name: "Restored Active Session",
			savedAt: Date(timeIntervalSince1970: 400),
			items: [
				AgentChatItemPersist(from: AgentChatItem(timestamp: Date(timeIntervalSince1970: 100), kind: .user, text: "Hello", sequenceIndex: 0)),
				AgentChatItemPersist(from: AgentChatItem(timestamp: Date(timeIntervalSince1970: 200), kind: .assistant, text: "Hi", sequenceIndex: 1))
			],
			itemCount: 2,
			lastUserMessageAt: Date(timeIntervalSince1970: 100)
		)

		_ = try await service.saveAgentSession(session, for: workspace)

		let vm = makeViewModel(testWorkspaceDirectory: tempRoot)
		vm.setAgentModeActive(true)
		await vm.test_handleWorkspaceSwitch(workspace)
		let deadline = Date().addingTimeInterval(2)
		while !vm.sessionListCacheReady && Date() < deadline {
			await Task.yield()
			try? await Task.sleep(nanoseconds: 10_000_000)
		}

		XCTAssertNil(vm.test_resolvedSessionID(for: tabID))
		XCTAssertNil(vm.sessions[tabID])
		let sidebar = vm.sidebarSessions(for: workspace.composeTabs)
		XCTAssertEqual(sidebar.count, 1)
		XCTAssertEqual(sidebar.first?.tabID, tabID)
		XCTAssertEqual(sidebar.first?.title, "Restored Active Session")
	}

	func testHandleWorkspaceSwitchRestoresExplicitActiveSessionBinding() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let service = AgentSessionDataService.shared
		let tabID = UUID()
		let sessionID = UUID()
		let workspace = makeWorkspace(
			name: "Explicit Active Restore",
			root: tempRoot,
			composeTabs: [
				ComposeTabState(
					id: tabID,
					name: "Restored Active Session",
					lastModified: Date(timeIntervalSince1970: 500),
					activeAgentSessionID: sessionID
				)
			]
		)
		let session = AgentSession(
			id: sessionID,
			workspaceID: workspace.id,
			composeTabID: tabID,
			name: "Restored Active Session",
			savedAt: Date(timeIntervalSince1970: 400),
			items: [
				AgentChatItemPersist(from: AgentChatItem(timestamp: Date(timeIntervalSince1970: 100), kind: .user, text: "Hello", sequenceIndex: 0)),
				AgentChatItemPersist(from: AgentChatItem(timestamp: Date(timeIntervalSince1970: 200), kind: .assistant, text: "Hi", sequenceIndex: 1))
			],
			itemCount: 2,
			lastUserMessageAt: Date(timeIntervalSince1970: 100)
		)

		_ = try await service.saveAgentSession(session, for: workspace)

		let vm = makeViewModel(testWorkspaceDirectory: tempRoot)
		vm.setAgentModeActive(true)
		await vm.test_handleWorkspaceSwitch(workspace)
		let deadline = Date().addingTimeInterval(2)
		while (vm.sessions[tabID]?.hasLoadedPersistedState != true) && Date() < deadline {
			await Task.yield()
			try? await Task.sleep(nanoseconds: 10_000_000)
		}

		let restoredSession = try XCTUnwrap(vm.sessions[tabID])
		XCTAssertEqual(restoredSession.activeAgentSessionID, sessionID)
		XCTAssertTrue(restoredSession.hasLoadedPersistedState)
		XCTAssertEqual(restoredSession.items.count, 2)
		XCTAssertEqual(restoredSession.items.first?.text, "Hello")
	}

	func testRefreshSessionListCacheRestoresRecencyOrderAfterIncrementalRestoreCompletes() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let service = AgentSessionDataService.shared
		let firstTab = UUID()
		let secondTab = UUID()
		let workspace = makeWorkspace(
			name: "Stable Restore Order",
			root: tempRoot,
			composeTabs: [
				ComposeTabState(id: firstTab, name: "First", lastModified: Date(timeIntervalSince1970: 100), activeAgentSessionID: nil),
				ComposeTabState(id: secondTab, name: "Second", lastModified: Date(timeIntervalSince1970: 200), activeAgentSessionID: nil)
			]
		)
		let olderSession = AgentSession(
			workspaceID: workspace.id,
			composeTabID: firstTab,
			name: "First",
			savedAt: Date(timeIntervalSince1970: 300),
			items: [
				AgentChatItemPersist(from: AgentChatItem(timestamp: Date(timeIntervalSince1970: 100), kind: .user, text: "older", sequenceIndex: 0))
			],
			itemCount: 1,
			lastUserMessageAt: Date(timeIntervalSince1970: 100)
		)
		let newerSession = AgentSession(
			workspaceID: workspace.id,
			composeTabID: secondTab,
			name: "Second",
			savedAt: Date(timeIntervalSince1970: 400),
			items: [
				AgentChatItemPersist(from: AgentChatItem(timestamp: Date(timeIntervalSince1970: 250), kind: .user, text: "newer", sequenceIndex: 0))
			],
			itemCount: 1,
			lastUserMessageAt: Date(timeIntervalSince1970: 250)
		)

		_ = try await service.saveAgentSession(olderSession, for: workspace)
		_ = try await service.saveAgentSession(newerSession, for: workspace)

		let vm = makeViewModel(testWorkspaceDirectory: tempRoot)
		await vm.test_handleWorkspaceSwitch(workspace)
		let deadline = Date().addingTimeInterval(2)
		while !vm.sessionListCacheReady && Date() < deadline {
			await Task.yield()
			try? await Task.sleep(nanoseconds: 10_000_000)
		}

		let sidebar = vm.sidebarSessions(for: workspace.composeTabs)
		XCTAssertEqual(sidebar.map(\.tabID), [secondTab, firstTab])
	}

	func testRefreshSessionListCacheIgnoresArchivedDuplicateOfActiveTab() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let service = AgentSessionDataService.shared
		let tabID = UUID()
		let composeTab = ComposeTabState(
			id: tabID,
			name: "Active Session",
			lastModified: Date(timeIntervalSince1970: 500),
			activeAgentSessionID: nil
		)
		var workspace = makeWorkspace(
			name: "Duplicate Archived Session",
			root: tempRoot,
			composeTabs: [composeTab]
		)
		workspace.stashedTabs = [
			StashedTab(
				tab: ComposeTabState(
					id: tabID,
					name: "Archived Duplicate",
					lastModified: Date(timeIntervalSince1970: 250),
					activeAgentSessionID: nil
				)
			)
		]
		let session = AgentSession(
			workspaceID: workspace.id,
			composeTabID: tabID,
			name: "Persisted Session",
			savedAt: Date(timeIntervalSince1970: 400),
			items: [
				AgentChatItemPersist(from: AgentChatItem(timestamp: Date(timeIntervalSince1970: 100), kind: .user, text: "Hello", sequenceIndex: 0))
			],
			itemCount: 1,
			lastUserMessageAt: Date(timeIntervalSince1970: 100)
		)

		_ = try await service.saveAgentSession(session, for: workspace)

		let vm = makeViewModel(testWorkspaceDirectory: tempRoot)
		vm.setAgentModeActive(true)
		await vm.test_handleWorkspaceSwitch(workspace)
		let deadline = Date().addingTimeInterval(2)
		while !vm.sessionListCacheReady && Date() < deadline {
			await Task.yield()
			try? await Task.sleep(nanoseconds: 10_000_000)
		}

		let sidebar = vm.sidebarSessions(for: workspace.composeTabs)
		XCTAssertEqual(sidebar.count, 1)
		XCTAssertEqual(sidebar.first?.tabID, tabID)
		XCTAssertEqual(sidebar.first?.title, "Active Session")
	}

	func testHandleWorkspaceSwitchKeepsNewestPersistedSessionAsSidebarOnlyWithoutExplicitBinding() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let service = AgentSessionDataService.shared
		let tabID = UUID()
		let composeTab = ComposeTabState(
			id: tabID,
			name: "Active Session",
			lastModified: Date(timeIntervalSince1970: 500),
			activeAgentSessionID: nil
		)
		let workspace = makeWorkspace(
			name: "Preferred Session Resolution",
			root: tempRoot,
			composeTabs: [composeTab]
		)
		let olderSession = AgentSession(
			workspaceID: workspace.id,
			composeTabID: tabID,
			name: "Older Session",
			savedAt: Date(timeIntervalSince1970: 300),
			items: [
				AgentChatItemPersist(from: AgentChatItem(timestamp: Date(timeIntervalSince1970: 100), kind: .user, text: "older", sequenceIndex: 0))
			],
			itemCount: 1,
			lastUserMessageAt: Date(timeIntervalSince1970: 100)
		)
		let newerSession = AgentSession(
			workspaceID: workspace.id,
			composeTabID: tabID,
			name: "Newer Session",
			savedAt: Date(timeIntervalSince1970: 400),
			items: [
				AgentChatItemPersist(from: AgentChatItem(timestamp: Date(timeIntervalSince1970: 250), kind: .user, text: "newer", sequenceIndex: 0))
			],
			itemCount: 1,
			lastUserMessageAt: Date(timeIntervalSince1970: 250)
		)

		_ = try await service.saveAgentSession(olderSession, for: workspace)
		_ = try await service.saveAgentSession(newerSession, for: workspace)

		let vm = makeViewModel(testWorkspaceDirectory: tempRoot)
		await vm.test_handleWorkspaceSwitch(workspace)
		let deadline = Date().addingTimeInterval(2)
		while !vm.sessionListCacheReady && Date() < deadline {
			await Task.yield()
			try? await Task.sleep(nanoseconds: 10_000_000)
		}

		XCTAssertNil(vm.test_resolvedSessionID(for: tabID))
		let sidebar = vm.sidebarSessions(for: workspace.composeTabs)
		XCTAssertEqual(sidebar.count, 1)
		XCTAssertEqual(sidebar.first?.sessionID, newerSession.id)
		XCTAssertEqual(sidebar.first?.title, "Active Session")
	}

	func testRenameSessionPersistsSidebarOnlySessionFileAndMetadataIndex() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let service = AgentSessionDataService.shared
		let tabID = UUID()
		let workspace = makeWorkspace(
			name: "Sidebar Only Rename",
			root: tempRoot,
			composeTabs: [
				ComposeTabState(
					id: tabID,
					name: "Before Rename",
					lastModified: Date(timeIntervalSince1970: 500),
					activeAgentSessionID: nil
				)
			]
		)
		let session = AgentSession(
			workspaceID: workspace.id,
			composeTabID: tabID,
			name: "Before Rename",
			savedAt: Date(timeIntervalSince1970: 400),
			items: [
				AgentChatItemPersist(from: AgentChatItem(timestamp: Date(timeIntervalSince1970: 100), kind: .user, text: "rename", sequenceIndex: 0))
			],
			itemCount: 1,
			lastUserMessageAt: Date(timeIntervalSince1970: 100)
		)

		_ = try await service.saveAgentSession(session, for: workspace)
		let vm = makeViewModel(testWorkspaceDirectory: tempRoot)
		await vm.test_handleWorkspaceSwitch(workspace)
		let cacheDeadline = Date().addingTimeInterval(2)
		while (vm.sidebarSessions(for: workspace.composeTabs).first?.sessionID != session.id || !vm.sessionListCacheReady) && Date() < cacheDeadline {
			await Task.yield()
			try? await Task.sleep(nanoseconds: 10_000_000)
		}
		XCTAssertNil(vm.sessions[tabID])
		XCTAssertEqual(vm.sidebarSessions(for: workspace.composeTabs).first?.sessionID, session.id)

		vm.renameSession(tabID: tabID, to: "  After Rename  ")
		let renameDeadline = Date().addingTimeInterval(2)
		var loaded = try await service.loadAgentSession(id: session.id, for: workspace)
		while loaded?.name != "After Rename" && Date() < renameDeadline {
			await Task.yield()
			try? await Task.sleep(nanoseconds: 10_000_000)
			loaded = try await service.loadAgentSession(id: session.id, for: workspace)
		}
		let metadata = try await service.listAgentSessionsMeta(for: workspace)
		let meta = try XCTUnwrap(metadata.first(where: { $0.id == session.id }))
		let renamedTabs = [
			ComposeTabState(
				id: tabID,
				name: "After Rename",
				lastModified: Date(timeIntervalSince1970: 600),
				activeAgentSessionID: nil
			)
		]
		let sidebar = vm.sidebarSessions(for: renamedTabs)

		XCTAssertEqual(loaded?.name, "After Rename")
		XCTAssertEqual(meta.name, "After Rename")
		XCTAssertEqual(vm.sessionIndex[session.id]?.name, "After Rename")
		XCTAssertEqual(sidebar.first?.title, "After Rename")
	}

	func testHandleWorkspaceSwitchRestoresExplicitActiveSessionBindingOverNewerDuplicate() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let service = AgentSessionDataService.shared
		let tabID = UUID()
		let olderSessionID = UUID()
		let newerSessionID = UUID()
		let composeTab = ComposeTabState(
			id: tabID,
			name: "Active Session",
			lastModified: Date(timeIntervalSince1970: 500),
			activeAgentSessionID: olderSessionID
		)
		let workspace = makeWorkspace(
			name: "Explicit Preferred Session Resolution",
			root: tempRoot,
			composeTabs: [composeTab]
		)
		let olderSession = AgentSession(
			id: olderSessionID,
			workspaceID: workspace.id,
			composeTabID: tabID,
			name: "Older Explicit Session",
			savedAt: Date(timeIntervalSince1970: 300),
			items: [
				AgentChatItemPersist(from: AgentChatItem(timestamp: Date(timeIntervalSince1970: 100), kind: .user, text: "older", sequenceIndex: 0))
			],
			itemCount: 1,
			lastUserMessageAt: Date(timeIntervalSince1970: 100)
		)
		let newerSession = AgentSession(
			id: newerSessionID,
			workspaceID: workspace.id,
			composeTabID: tabID,
			name: "Newer Duplicate Session",
			savedAt: Date(timeIntervalSince1970: 400),
			items: [
				AgentChatItemPersist(from: AgentChatItem(timestamp: Date(timeIntervalSince1970: 250), kind: .user, text: "newer", sequenceIndex: 0))
			],
			itemCount: 1,
			lastUserMessageAt: Date(timeIntervalSince1970: 250)
		)

		_ = try await service.saveAgentSession(olderSession, for: workspace)
		_ = try await service.saveAgentSession(newerSession, for: workspace)

		let vm = makeViewModel(testWorkspaceDirectory: tempRoot)
		vm.setAgentModeActive(true)
		await vm.test_handleWorkspaceSwitch(workspace)
		let deadline = Date().addingTimeInterval(2)
		while (vm.sessions[tabID]?.hasLoadedPersistedState != true || !vm.sessionListCacheReady) && Date() < deadline {
			await Task.yield()
			try? await Task.sleep(nanoseconds: 10_000_000)
		}

		let restoredSession = try XCTUnwrap(vm.sessions[tabID])
		XCTAssertEqual(restoredSession.activeAgentSessionID, olderSessionID)
		XCTAssertTrue(restoredSession.hasLoadedPersistedState)
		XCTAssertEqual(vm.test_resolvedSessionID(for: tabID), olderSessionID)
		let sidebar = vm.sidebarSessions(for: workspace.composeTabs)
		XCTAssertEqual(sidebar.count, 1)
		XCTAssertEqual(sidebar.first?.sessionID, olderSessionID)
		XCTAssertEqual(sidebar.first?.title, "Active Session")
	}

	func testSidebarSessionsDoesNotShowExplicitBindingUnderStaleComposeTabID() {
		let vm = makeViewModel()
		let explicitTabID = UUID()
		let staleTabID = UUID()
		let sessionID = UUID()
		vm.test_upsertSessionIndex(
			sessionID: sessionID,
			tabID: staleTabID,
			name: "Stale Metadata Session",
			lastUserMessageAt: Date(timeIntervalSince1970: 250),
			savedAt: Date(timeIntervalSince1970: 400),
			lastRunStateRaw: nil,
			itemCount: 1,
			agentKindRaw: nil,
			agentModelRaw: nil,
			agentReasoningEffortRaw: nil,
			autoEditEnabled: false
		)
		let tabs = [
			ComposeTabState(
				id: explicitTabID,
				name: "Explicit Tab",
				lastModified: Date(timeIntervalSince1970: 500),
				activeAgentSessionID: sessionID
			),
			ComposeTabState(
				id: staleTabID,
				name: "Stale Tab",
				lastModified: Date(timeIntervalSince1970: 400),
				activeAgentSessionID: nil
			)
		]

		let sidebar = vm.sidebarSessions(for: tabs)

		XCTAssertEqual(sidebar.count, 1)
		XCTAssertEqual(sidebar.first?.tabID, explicitTabID)
		XCTAssertEqual(sidebar.first?.sessionID, sessionID)
		XCTAssertEqual(sidebar.first?.title, "Explicit Tab")
	}

	func testArchivedExplicitBindingUsesSessionContentDespiteStaleComposeTabID() {
		let vm = makeViewModel()
		let archivedTabID = UUID()
		let staleTabID = UUID()
		let sessionID = UUID()
		vm.test_upsertSessionIndex(
			sessionID: sessionID,
			tabID: staleTabID,
			name: "Stale Archived Metadata Session",
			lastUserMessageAt: Date(timeIntervalSince1970: 250),
			savedAt: Date(timeIntervalSince1970: 400),
			lastRunStateRaw: nil,
			itemCount: 1,
			agentKindRaw: nil,
			agentModelRaw: nil,
			agentReasoningEffortRaw: nil,
			autoEditEnabled: false
		)
		let stashedTab = StashedTab(
			tab: ComposeTabState(
				id: archivedTabID,
				name: "Archived Explicit Tab",
				lastModified: Date(timeIntervalSince1970: 500),
				activeAgentSessionID: sessionID
			)
		)

		XCTAssertTrue(vm.shouldShowArchivedSession(for: stashedTab))
		let sidebar = vm.sidebarSessions(for: [stashedTab.tab])
		XCTAssertEqual(sidebar.count, 1)
		XCTAssertEqual(sidebar.first?.tabID, archivedTabID)
		XCTAssertEqual(sidebar.first?.sessionID, sessionID)
		XCTAssertEqual(sidebar.first?.title, "Archived Explicit Tab")
	}

	func testWorkspaceModelNormalizationDropsArchivedTabsDuplicatingActiveTabIDs() {
		let tabID = UUID()
		let workspace = WorkspaceModel(
			name: "Normalized Workspace",
			repoPaths: [],
			composeTabs: [
				ComposeTabState(
					id: tabID,
					name: "Active Session",
					lastModified: Date(timeIntervalSince1970: 500),
					activeAgentSessionID: nil
				)
			],
			stashedTabs: [
				StashedTab(
					tab: ComposeTabState(
						id: tabID,
						name: "Archived Duplicate",
						lastModified: Date(timeIntervalSince1970: 250),
						activeAgentSessionID: nil
					)
				)
			]
		)

		XCTAssertTrue(workspace.stashedTabs.isEmpty)
	}

	func testWorkspaceModelDecodeNormalizationDropsArchivedTabsDuplicatingActiveTabIDs() throws {
		let tabID = UUID()
		let composeTab = ComposeTabState(
			id: tabID,
			name: "Active Session",
			lastModified: Date(timeIntervalSince1970: 500),
			activeAgentSessionID: nil
		)
		let baseWorkspace = WorkspaceModel(
			name: "Decoded Workspace",
			repoPaths: [],
			composeTabs: [composeTab]
		)
		let duplicateArchivedTab = StashedTab(
			tab: ComposeTabState(
				id: tabID,
				name: "Archived Duplicate",
				lastModified: Date(timeIntervalSince1970: 250),
				activeAgentSessionID: nil
			)
		)

		let encoder = JSONEncoder()
		let workspaceData = try encoder.encode(baseWorkspace)
		var workspaceObject = try XCTUnwrap(JSONSerialization.jsonObject(with: workspaceData) as? [String: Any])
		let stashedData = try encoder.encode([duplicateArchivedTab])
		workspaceObject["stashedTabs"] = try JSONSerialization.jsonObject(with: stashedData)

		let decodedData = try JSONSerialization.data(withJSONObject: workspaceObject)
		let decodedWorkspace = try JSONDecoder().decode(WorkspaceModel.self, from: decodedData)

		XCTAssertEqual(decodedWorkspace.composeTabs.map(\.id), [tabID])
		XCTAssertTrue(decodedWorkspace.stashedTabs.isEmpty)
	}

	func testFilteredSidebarSessionsPreserveDisplayedActiveSessionWhileSearching() {
		let vm = makeViewModel()
		let alphaTab = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
		let betaTab = UUID(uuidString: "00000000-0000-0000-0000-0000000000C2")!
		let gammaTab = UUID(uuidString: "00000000-0000-0000-0000-0000000000C3")!

		for tabID in [alphaTab, betaTab, gammaTab] {
			vm.ensureSession(for: tabID)
		}
		guard let alphaSession = vm.sessions[alphaTab],
			let betaSession = vm.sessions[betaTab],
			let gammaSession = vm.sessions[gammaTab] else {
			return XCTFail("Expected sessions for all tabs")
		}
		alphaSession.lastUserMessageAt = Date(timeIntervalSince1970: 100)
		betaSession.lastUserMessageAt = Date(timeIntervalSince1970: 300)
		gammaSession.lastUserMessageAt = Date(timeIntervalSince1970: 200)

		let tabs = [
			ComposeTabState(id: alphaTab, name: "Alpha", lastModified: Date(timeIntervalSince1970: 1)),
			ComposeTabState(id: betaTab, name: "Beta", lastModified: Date(timeIntervalSince1970: 2)),
			ComposeTabState(id: gammaTab, name: "Gamma", lastModified: Date(timeIntervalSince1970: 3))
		]

		let filtered = vm.filteredSidebarSessions(for: tabs, currentTabID: alphaTab, searchText: "Gamma")
		XCTAssertEqual(filtered.map(\.tabID), [alphaTab, gammaTab])
	}

	func testAdjacentSidebarSessionTabIDUsesDisplayedSidebarOrder() {
		let vm = makeViewModel()
		let alphaTab = UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!
		let betaTab = UUID(uuidString: "00000000-0000-0000-0000-0000000000D2")!
		let gammaTab = UUID(uuidString: "00000000-0000-0000-0000-0000000000D3")!

		for tabID in [alphaTab, betaTab, gammaTab] {
			vm.ensureSession(for: tabID)
		}
		guard let alphaSession = vm.sessions[alphaTab],
			let betaSession = vm.sessions[betaTab],
			let gammaSession = vm.sessions[gammaTab] else {
			return XCTFail("Expected sessions for all tabs")
		}
		alphaSession.lastUserMessageAt = Date(timeIntervalSince1970: 100)
		betaSession.lastUserMessageAt = Date(timeIntervalSince1970: 300)
		gammaSession.lastUserMessageAt = Date(timeIntervalSince1970: 200)

		let tabs = [
			ComposeTabState(id: alphaTab, name: "Alpha", lastModified: Date(timeIntervalSince1970: 1)),
			ComposeTabState(id: betaTab, name: "Beta", lastModified: Date(timeIntervalSince1970: 2)),
			ComposeTabState(id: gammaTab, name: "Gamma", lastModified: Date(timeIntervalSince1970: 3))
		]

		XCTAssertEqual(
			vm.adjacentSidebarSessionTabID(
				from: gammaTab,
				forward: true,
				in: tabs,
				currentTabID: gammaTab
			),
			alphaTab
		)
		XCTAssertEqual(
			vm.adjacentSidebarSessionTabID(
				from: alphaTab,
				forward: true,
				in: tabs,
				currentTabID: alphaTab
			),
			betaTab
		)
	}

	func testSessionSidebarShortcutTabIDUsesVisibleDisplayedOrder() {
		let vm = makeViewModel()
		let alphaTab = UUID(uuidString: "00000000-0000-0000-0000-0000000000E1")!
		let betaTab = UUID(uuidString: "00000000-0000-0000-0000-0000000000E2")!
		let gammaTab = UUID(uuidString: "00000000-0000-0000-0000-0000000000E3")!

		for tabID in [alphaTab, betaTab, gammaTab] {
			vm.ensureSession(for: tabID)
		}
		guard let alphaSession = vm.sessions[alphaTab],
			let betaSession = vm.sessions[betaTab],
			let gammaSession = vm.sessions[gammaTab] else {
			return XCTFail("Expected sessions for all tabs")
		}
		alphaSession.lastUserMessageAt = Date(timeIntervalSince1970: 100)
		betaSession.lastUserMessageAt = Date(timeIntervalSince1970: 300)
		gammaSession.lastUserMessageAt = Date(timeIntervalSince1970: 200)

		let tabs = [
			ComposeTabState(id: alphaTab, name: "Alpha", lastModified: Date(timeIntervalSince1970: 1)),
			ComposeTabState(id: betaTab, name: "Beta", lastModified: Date(timeIntervalSince1970: 2)),
			ComposeTabState(id: gammaTab, name: "Gamma", lastModified: Date(timeIntervalSince1970: 3))
		]

		XCTAssertEqual(
			vm.sessionSidebarShortcutTabID(
				at: 0,
				in: tabs,
				currentTabID: betaTab,
				visibleSessionCount: 2
			),
			betaTab
		)
		XCTAssertEqual(
			vm.sessionSidebarShortcutTabID(
				at: 1,
				in: tabs,
				currentTabID: betaTab,
				visibleSessionCount: 2
			),
			gammaTab
		)
		XCTAssertNil(
			vm.sessionSidebarShortcutTabID(
				at: 2,
				in: tabs,
				currentTabID: betaTab,
				visibleSessionCount: 2
			)
		)
	}

	func testAdjacentSidebarSessionTabIDRespectsVisiblePageLimit() {
		let vm = makeViewModel()
		let alphaTab = UUID(uuidString: "00000000-0000-0000-0000-0000000000F1")!
		let betaTab = UUID(uuidString: "00000000-0000-0000-0000-0000000000F2")!
		let gammaTab = UUID(uuidString: "00000000-0000-0000-0000-0000000000F3")!

		for tabID in [alphaTab, betaTab, gammaTab] {
			vm.ensureSession(for: tabID)
		}
		guard let alphaSession = vm.sessions[alphaTab],
			let betaSession = vm.sessions[betaTab],
			let gammaSession = vm.sessions[gammaTab] else {
			return XCTFail("Expected sessions for all tabs")
		}
		alphaSession.lastUserMessageAt = Date(timeIntervalSince1970: 100)
		betaSession.lastUserMessageAt = Date(timeIntervalSince1970: 300)
		gammaSession.lastUserMessageAt = Date(timeIntervalSince1970: 200)

		let tabs = [
			ComposeTabState(id: alphaTab, name: "Alpha", lastModified: Date(timeIntervalSince1970: 1)),
			ComposeTabState(id: betaTab, name: "Beta", lastModified: Date(timeIntervalSince1970: 2)),
			ComposeTabState(id: gammaTab, name: "Gamma", lastModified: Date(timeIntervalSince1970: 3))
		]

		XCTAssertEqual(
			vm.adjacentSidebarSessionTabID(
				from: gammaTab,
				forward: true,
				in: tabs,
				currentTabID: gammaTab,
				visibleSessionCount: 2
			),
			betaTab
		)
	}

	func testPagedSidebarSessionsExpandsToKeepActiveSessionVisible() {
		let vm = makeViewModel()
		let alphaTab = UUID(uuidString: "00000000-0000-0000-0000-0000000000F1")!
		let betaTab = UUID(uuidString: "00000000-0000-0000-0000-0000000000F2")!
		let gammaTab = UUID(uuidString: "00000000-0000-0000-0000-0000000000F3")!

		for tabID in [alphaTab, betaTab, gammaTab] {
			vm.ensureSession(for: tabID)
		}
		guard let alphaSession = vm.sessions[alphaTab],
			let betaSession = vm.sessions[betaTab],
			let gammaSession = vm.sessions[gammaTab] else {
			return XCTFail("Expected sessions for all tabs")
		}
		alphaSession.lastUserMessageAt = Date(timeIntervalSince1970: 100)
		betaSession.lastUserMessageAt = Date(timeIntervalSince1970: 300)
		gammaSession.lastUserMessageAt = Date(timeIntervalSince1970: 200)

		let tabs = [
			ComposeTabState(id: alphaTab, name: "Alpha", lastModified: Date(timeIntervalSince1970: 1)),
			ComposeTabState(id: betaTab, name: "Beta", lastModified: Date(timeIntervalSince1970: 2)),
			ComposeTabState(id: gammaTab, name: "Gamma", lastModified: Date(timeIntervalSince1970: 3))
		]

		let paged = vm.pagedSidebarSessions(
			for: tabs,
			currentTabID: alphaTab,
			visibleSessionCount: 2
		)
		XCTAssertEqual(paged.map(\.tabID), [betaTab, gammaTab, alphaTab])
		XCTAssertEqual(
			vm.effectiveSidebarVisibleSessionCount(
				for: tabs,
				currentTabID: alphaTab,
				visibleSessionCount: 2
			),
			3
		)
	}

	func testSidebarSessionsNestLiveChildSessionsUnderTheirParent() {
		let vm = makeViewModel()
		let parentTab = UUID()
		let childTab = UUID()
		let parentSessionID = vm.test_mcpSpawnParentSessionID(sourceTabID: parentTab)
		XCTAssertNotNil(parentSessionID)
		vm.test_applySpawnParentSessionID(parentSessionID, tabID: childTab)
		guard let childSession = vm.sessions[childTab] else {
			return XCTFail("Expected child session")
		}
		let tabs = [
			ComposeTabState(
				id: childTab,
				name: "Child",
				lastModified: Date(timeIntervalSince1970: 300),
				activeAgentSessionID: childSession.activeAgentSessionID
			),
			ComposeTabState(
				id: parentTab,
				name: "Parent",
				lastModified: Date(timeIntervalSince1970: 100),
				activeAgentSessionID: parentSessionID
			)
		]

		let sidebar = vm.sidebarSessions(for: tabs)
		XCTAssertEqual(sidebar.map(\.tabID), [parentTab, childTab])
		XCTAssertEqual(sidebar.map(\.depth), [0, 1])
		XCTAssertEqual(childSession.parentSessionID, parentSessionID)
	}

	func testCollapsedSidebarThreadHidesDescendantsButKeepsCanonicalRows() {
		let vm = makeViewModel()
		let parentTab = UUID()
		let childTab = UUID()
		guard let parentSessionID = vm.test_mcpSpawnParentSessionID(sourceTabID: parentTab) else {
			return XCTFail("Expected parent session ID")
		}
		vm.test_applySpawnParentSessionID(parentSessionID, tabID: childTab)
		guard let childSession = vm.sessions[childTab] else {
			return XCTFail("Expected child session")
		}
		let tabs = [
			ComposeTabState(id: childTab, name: "Child", lastModified: Date(timeIntervalSince1970: 300), activeAgentSessionID: childSession.activeAgentSessionID),
			ComposeTabState(id: parentTab, name: "Parent", lastModified: Date(timeIntervalSince1970: 100), activeAgentSessionID: parentSessionID)
		]

		vm.setSidebarThreadCollapsed(true, for: .session(parentSessionID))

		let canonical = vm.sidebarSessions(for: tabs)
		let displayed = vm.filteredSidebarSessions(for: tabs, currentTabID: nil)
		XCTAssertEqual(canonical.map(\.tabID), [parentTab, childTab])
		XCTAssertEqual(displayed.map(\.tabID), [parentTab])
		XCTAssertEqual(displayed.first?.threadKey, .session(parentSessionID))
		XCTAssertEqual(displayed.first?.hasThreadChildren, true)
		XCTAssertEqual(displayed.first?.isThreadCollapsed, true)
		XCTAssertEqual(displayed.first?.hiddenThreadDescendantCount, 1)
	}

	func testCollapsedSidebarThreadTemporarilyExpandsForActiveDescendant() {
		let vm = makeViewModel()
		let parentTab = UUID()
		let childTab = UUID()
		guard let parentSessionID = vm.test_mcpSpawnParentSessionID(sourceTabID: parentTab) else {
			return XCTFail("Expected parent session ID")
		}
		vm.test_applySpawnParentSessionID(parentSessionID, tabID: childTab)
		guard let childSession = vm.sessions[childTab] else {
			return XCTFail("Expected child session")
		}
		let tabs = [
			ComposeTabState(id: childTab, name: "Child", lastModified: Date(timeIntervalSince1970: 300), activeAgentSessionID: childSession.activeAgentSessionID),
			ComposeTabState(id: parentTab, name: "Parent", lastModified: Date(timeIntervalSince1970: 100), activeAgentSessionID: parentSessionID)
		]

		vm.setSidebarThreadCollapsed(true, for: .session(parentSessionID))

		let activeChildDisplayed = vm.filteredSidebarSessions(for: tabs, currentTabID: childTab)
		XCTAssertEqual(activeChildDisplayed.map(\.tabID), [parentTab, childTab])
		XCTAssertEqual(activeChildDisplayed.first?.isThreadCollapsed, false)
		XCTAssertTrue(vm.isSidebarThreadCollapsed(.session(parentSessionID)))

		let inactiveDisplayed = vm.filteredSidebarSessions(for: tabs, currentTabID: nil)
		XCTAssertEqual(inactiveDisplayed.map(\.tabID), [parentTab])
	}

	func testSidebarSearchIgnoresCollapsedThreadStateAndShowsMatchingChild() {
		let vm = makeViewModel()
		let parentTab = UUID()
		let childTab = UUID()
		guard let parentSessionID = vm.test_mcpSpawnParentSessionID(sourceTabID: parentTab) else {
			return XCTFail("Expected parent session ID")
		}
		vm.test_applySpawnParentSessionID(parentSessionID, tabID: childTab)
		guard let childSession = vm.sessions[childTab] else {
			return XCTFail("Expected child session")
		}
		let tabs = [
			ComposeTabState(id: childTab, name: "Child Needle", lastModified: Date(timeIntervalSince1970: 300), activeAgentSessionID: childSession.activeAgentSessionID),
			ComposeTabState(id: parentTab, name: "Parent", lastModified: Date(timeIntervalSince1970: 100), activeAgentSessionID: parentSessionID)
		]

		vm.setSidebarThreadCollapsed(true, for: .session(parentSessionID))

		let displayed = vm.filteredSidebarSessions(for: tabs, currentTabID: nil, searchText: "Needle")
		XCTAssertEqual(displayed.map(\.tabID), [parentTab, childTab])
		XCTAssertEqual(displayed.first?.isThreadCollapsed, false)
		XCTAssertEqual(displayed.first?.hiddenThreadDescendantCount, 0)
	}

	func testSidebarSearchPromotesActiveChildThreadWithoutBreakingParentMetadata() {
		let vm = makeViewModel()
		let parentTab = UUID()
		let childTab = UUID()
		let otherTab = UUID()
		let otherSessionID = UUID()
		guard let parentSessionID = vm.test_mcpSpawnParentSessionID(sourceTabID: parentTab) else {
			return XCTFail("Expected parent session ID")
		}
		vm.test_applySpawnParentSessionID(parentSessionID, tabID: childTab)
		guard let childSession = vm.sessions[childTab] else {
			return XCTFail("Expected child session")
		}
		vm.ensureSession(for: otherTab)
		guard let otherSession = vm.sessions[otherTab] else {
			return XCTFail("Expected other session")
		}
		otherSession.activeAgentSessionID = otherSessionID
		otherSession.hasLoadedPersistedState = true
		otherSession.lastUserMessageAt = Date(timeIntervalSince1970: 400)
		let tabs = [
			ComposeTabState(id: childTab, name: "Child", lastModified: Date(timeIntervalSince1970: 200), activeAgentSessionID: childSession.activeAgentSessionID),
			ComposeTabState(id: parentTab, name: "Parent", lastModified: Date(timeIntervalSince1970: 100), activeAgentSessionID: parentSessionID),
			ComposeTabState(id: otherTab, name: "Other Needle", lastModified: Date(timeIntervalSince1970: 400), activeAgentSessionID: otherSessionID)
		]

		vm.setSidebarThreadCollapsed(true, for: .session(parentSessionID))

		let displayed = vm.filteredSidebarSessions(for: tabs, currentTabID: childTab, searchText: "Needle")
		XCTAssertEqual(displayed.map(\.tabID), [parentTab, childTab, otherTab])
		XCTAssertEqual(displayed.first?.hasThreadChildren, true)
		XCTAssertEqual(displayed.first?.isThreadCollapsed, false)
		XCTAssertEqual(displayed.first?.hiddenThreadDescendantCount, 0)
	}

	func testCollapsedSidebarPaginationCountsOnlyDisplayedRows() {
		let vm = makeViewModel()
		let parentTab = UUID()
		let olderChildTab = UUID()
		let newerChildTab = UUID()
		let otherTab = UUID()
		let olderChildSessionID = UUID()
		let newerChildSessionID = UUID()
		let otherSessionID = UUID()
		guard let parentSessionID = vm.test_mcpSpawnParentSessionID(sourceTabID: parentTab) else {
			return XCTFail("Expected parent session ID")
		}

		for (tabID, sessionID, lastUserMessageAt) in [
			(olderChildTab, olderChildSessionID, Date(timeIntervalSince1970: 200)),
			(newerChildTab, newerChildSessionID, Date(timeIntervalSince1970: 400))
		] {
			vm.ensureSession(for: tabID)
			guard let session = vm.sessions[tabID] else {
				return XCTFail("Expected child session")
			}
			session.activeAgentSessionID = sessionID
			session.hasLoadedPersistedState = true
			session.lastUserMessageAt = lastUserMessageAt
			vm.test_applySpawnParentSessionID(parentSessionID, tabID: tabID)
		}
		vm.ensureSession(for: otherTab)
		guard let otherSession = vm.sessions[otherTab] else {
			return XCTFail("Expected other session")
		}
		otherSession.activeAgentSessionID = otherSessionID
		otherSession.hasLoadedPersistedState = true
		otherSession.lastUserMessageAt = Date(timeIntervalSince1970: 300)
		let tabs = [
			ComposeTabState(id: parentTab, name: "Parent", lastModified: Date(timeIntervalSince1970: 100), activeAgentSessionID: parentSessionID),
			ComposeTabState(id: olderChildTab, name: "Older Child", lastModified: Date(timeIntervalSince1970: 200), activeAgentSessionID: olderChildSessionID),
			ComposeTabState(id: newerChildTab, name: "Newer Child", lastModified: Date(timeIntervalSince1970: 400), activeAgentSessionID: newerChildSessionID),
			ComposeTabState(id: otherTab, name: "Other", lastModified: Date(timeIntervalSince1970: 300), activeAgentSessionID: otherSessionID)
		]

		vm.setSidebarThreadCollapsed(true, for: .session(parentSessionID))

		let filtered = vm.filteredSidebarSessions(for: tabs, currentTabID: nil)
		let paged = vm.pagedSidebarSessions(filteredSessions: filtered, currentTabID: nil, visibleSessionCount: 1)
		XCTAssertEqual(filtered.map(\.tabID), [parentTab, otherTab])
		XCTAssertEqual(filtered.first?.hiddenThreadDescendantCount, 2)
		XCTAssertEqual(paged.map(\.tabID), [parentTab])
		XCTAssertEqual(
			vm.effectiveSidebarVisibleSessionCount(filteredSessions: filtered, currentTabID: nil, visibleSessionCount: 1),
			1
		)
	}

	func testCollapsedThreadDateSectionUsesHiddenDescendantActivity() {
		let vm = makeViewModel()
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = TimeZone(secondsFromGMT: 0)!
		let now = calendar.date(from: DateComponents(year: 2026, month: 4, day: 23, hour: 12))!
		let today = calendar.date(byAdding: .hour, value: -2, to: now)!
		let previous = calendar.date(byAdding: .day, value: -2, to: now)!
		let parentTab = UUID()
		let childTab = UUID()
		guard let parentSessionID = vm.test_mcpSpawnParentSessionID(sourceTabID: parentTab) else {
			return XCTFail("Expected parent session ID")
		}
		vm.sessions[parentTab]?.lastUserMessageAt = previous
		vm.test_applySpawnParentSessionID(parentSessionID, tabID: childTab)
		guard let childSession = vm.sessions[childTab] else {
			return XCTFail("Expected child session")
		}
		childSession.lastUserMessageAt = today
		let tabs = [
			ComposeTabState(id: childTab, name: "Child", lastModified: today, activeAgentSessionID: childSession.activeAgentSessionID),
			ComposeTabState(id: parentTab, name: "Parent", lastModified: previous, activeAgentSessionID: parentSessionID)
		]

		vm.setSidebarThreadCollapsed(true, for: .session(parentSessionID))
		let displayed = vm.filteredSidebarSessions(for: tabs, currentTabID: nil)
		let sections = AgentSidebarDateSectionBuilder.activeSections(
			for: displayed,
			now: now,
			calendar: calendar
		)

		XCTAssertEqual(displayed.map(\.tabID), [parentTab])
		XCTAssertEqual(displayed.first?.threadActivityDate, today)
		XCTAssertEqual(sections.map(\.bucket), [.today])
	}

	func testCollapsedPersistedThreadGroupHidesRestoredChildWhenDepthIsEmitted() {
		let vm = makeViewModel()
		let parentTab = UUID()
		let childTab = UUID()
		let parentSessionID = UUID()
		let childSessionID = UUID()
		vm.test_upsertSessionIndex(
			sessionID: parentSessionID,
			tabID: parentTab,
			name: "Parent",
			lastUserMessageAt: Date(timeIntervalSince1970: 100),
			savedAt: Date(timeIntervalSince1970: 100),
			lastRunStateRaw: nil,
			itemCount: 1,
			agentKindRaw: nil,
			agentModelRaw: nil,
			agentReasoningEffortRaw: nil,
			autoEditEnabled: false
		)
		vm.test_upsertSessionIndex(
			sessionID: childSessionID,
			tabID: childTab,
			name: "Child",
			lastUserMessageAt: Date(timeIntervalSince1970: 300),
			savedAt: Date(timeIntervalSince1970: 300),
			lastRunStateRaw: nil,
			itemCount: 1,
			agentKindRaw: nil,
			agentModelRaw: nil,
			agentReasoningEffortRaw: nil,
			autoEditEnabled: false,
			parentSessionID: parentSessionID
		)
		let tabs = [
			ComposeTabState(id: parentTab, name: "Parent", lastModified: Date(timeIntervalSince1970: 100), activeAgentSessionID: parentSessionID),
			ComposeTabState(id: childTab, name: "Child", lastModified: Date(timeIntervalSince1970: 300), activeAgentSessionID: childSessionID)
		]

		vm.setSidebarThreadCollapsed(true, for: .session(parentSessionID))

		let canonical = vm.sidebarSessions(for: tabs)
		let displayed = vm.filteredSidebarSessions(for: tabs, currentTabID: nil)
		XCTAssertEqual(canonical.map(\.tabID), [parentTab, childTab])
		XCTAssertEqual(canonical.map(\.depth), [0, 1])
		XCTAssertEqual(displayed.map(\.tabID), [parentTab])
		XCTAssertEqual(displayed.first?.hiddenThreadDescendantCount, 1)
	}

	func testSidebarThreadCollapseStoreToggleUpdatesSnapshotRevision() {
		let store = AgentSessionSidebarUIStore()
		let key = AgentSidebarThreadKey.session(UUID())
		let initialRevision = store.snapshot.revision

		store.toggleThreadCollapse(key)
		XCTAssertTrue(store.snapshot.collapsedThreadKeys.contains(key))
		XCTAssertEqual(store.snapshot.revision, initialRevision + 1)

		store.setThreadCollapsed(true, for: key)
		XCTAssertEqual(store.snapshot.revision, initialRevision + 1)

		store.setThreadCollapsed(false, for: key)
		XCTAssertFalse(store.snapshot.collapsedThreadKeys.contains(key))
		XCTAssertEqual(store.snapshot.revision, initialRevision + 2)
	}

	func testSidebarSessionsPreferLiveParentOverStaleIndexParentForLiveChild() {
		let vm = makeViewModel()
		let parentTab = UUID()
		let childTab = UUID()
		let parentSessionID = UUID()
		let childSessionID = UUID()
		let staleParentSessionID = UUID()

		vm.test_upsertSessionIndex(
			sessionID: parentSessionID,
			tabID: parentTab,
			name: "Parent",
			lastUserMessageAt: Date(timeIntervalSince1970: 100),
			savedAt: Date(timeIntervalSince1970: 100),
			lastRunStateRaw: nil,
			itemCount: 1,
			agentKindRaw: nil,
			agentModelRaw: nil,
			agentReasoningEffortRaw: nil,
			autoEditEnabled: false
		)
		vm.test_upsertSessionIndex(
			sessionID: childSessionID,
			tabID: childTab,
			name: "Child",
			lastUserMessageAt: Date(timeIntervalSince1970: 300),
			savedAt: Date(timeIntervalSince1970: 300),
			lastRunStateRaw: nil,
			itemCount: 1,
			agentKindRaw: nil,
			agentModelRaw: nil,
			agentReasoningEffortRaw: nil,
			autoEditEnabled: false,
			parentSessionID: staleParentSessionID
		)
		vm.ensureSession(for: childTab)
		guard let childSession = vm.sessions[childTab] else {
			return XCTFail("Expected child session")
		}
		childSession.activeAgentSessionID = childSessionID
		childSession.parentSessionID = parentSessionID
		childSession.hasLoadedPersistedState = true
		childSession.lastUserMessageAt = Date(timeIntervalSince1970: 300)

		let tabs = [
			ComposeTabState(id: childTab, name: "Child", lastModified: Date(timeIntervalSince1970: 300), activeAgentSessionID: childSessionID),
			ComposeTabState(id: parentTab, name: "Parent", lastModified: Date(timeIntervalSince1970: 100), activeAgentSessionID: parentSessionID)
		]

		let sidebar = vm.sidebarSessions(for: tabs)
		XCTAssertEqual(sidebar.map(\.tabID), [parentTab, childTab])
		XCTAssertEqual(sidebar.map(\.depth), [0, 1])
		XCTAssertEqual(sidebar.last?.parentSessionID, parentSessionID)
	}

	func testApplySpawnParentSessionIDRepairsIndexImmediatelyForNewChild() {
		let vm = makeViewModel()
		let parentTab = UUID()
		let childTab = UUID()
		let childSessionID = UUID()
		let parentSessionID = vm.test_mcpSpawnParentSessionID(sourceTabID: parentTab)
		XCTAssertNotNil(parentSessionID)

		vm.ensureSession(for: childTab)
		guard let childSession = vm.sessions[childTab] else {
			return XCTFail("Expected child session")
		}
		childSession.activeAgentSessionID = childSessionID
		childSession.hasLoadedPersistedState = true

		vm.test_applySpawnParentSessionID(parentSessionID, tabID: childTab)

		XCTAssertEqual(childSession.parentSessionID, parentSessionID)
		XCTAssertEqual(vm.sessionIndex[childSessionID]?.parentSessionID, parentSessionID)
		let tabs = [
			ComposeTabState(id: childTab, name: "Child", lastModified: Date(timeIntervalSince1970: 300), activeAgentSessionID: childSessionID),
			ComposeTabState(id: parentTab, name: "Parent", lastModified: Date(timeIntervalSince1970: 100), activeAgentSessionID: parentSessionID)
		]
		let sidebar = vm.sidebarSessions(for: tabs)
		XCTAssertEqual(sidebar.map(\.tabID), [parentTab, childTab])
		XCTAssertEqual(sidebar.map(\.depth), [0, 1])
	}

	func testApplySpawnParentSessionIDRepairsStaleIndexWhenLiveParentAlreadySet() {
		let vm = makeViewModel()
		let parentTab = UUID()
		let childTab = UUID()
		let childSessionID = UUID()
		let staleParentSessionID = UUID()
		let parentSessionID = vm.test_mcpSpawnParentSessionID(sourceTabID: parentTab)
		XCTAssertNotNil(parentSessionID)

		vm.ensureSession(for: childTab)
		guard let childSession = vm.sessions[childTab] else {
			return XCTFail("Expected child session")
		}
		childSession.activeAgentSessionID = childSessionID
		childSession.parentSessionID = parentSessionID
		childSession.hasLoadedPersistedState = true
		vm.test_upsertSessionIndex(
			sessionID: childSessionID,
			tabID: childTab,
			name: "Child",
			lastUserMessageAt: nil,
			savedAt: Date(timeIntervalSince1970: 200),
			lastRunStateRaw: nil,
			itemCount: 0,
			agentKindRaw: nil,
			agentModelRaw: nil,
			agentReasoningEffortRaw: nil,
			autoEditEnabled: false,
			parentSessionID: staleParentSessionID
		)

		vm.test_applySpawnParentSessionID(parentSessionID, tabID: childTab)

		XCTAssertEqual(childSession.parentSessionID, parentSessionID)
		XCTAssertEqual(vm.sessionIndex[childSessionID]?.parentSessionID, parentSessionID)
	}

	func testSidebarSessionsKeepReopenedLiveChildSubtreeAtChildRecency() {
		let vm = makeViewModel()
		let parentTab = UUID()
		let childTab = UUID()
		let otherTab = UUID()
		let parentSessionID = UUID()
		let childSessionID = UUID()
		let otherSessionID = UUID()

		vm.test_upsertSessionIndex(
			sessionID: parentSessionID,
			tabID: parentTab,
			name: "Parent",
			lastUserMessageAt: Date(timeIntervalSince1970: 100),
			savedAt: Date(timeIntervalSince1970: 100),
			lastRunStateRaw: nil,
			itemCount: 1,
			agentKindRaw: nil,
			agentModelRaw: nil,
			agentReasoningEffortRaw: nil,
			autoEditEnabled: false
		)
		vm.test_upsertSessionIndex(
			sessionID: childSessionID,
			tabID: childTab,
			name: "Child",
			lastUserMessageAt: Date(timeIntervalSince1970: 300),
			savedAt: Date(timeIntervalSince1970: 300),
			lastRunStateRaw: nil,
			itemCount: 1,
			agentKindRaw: nil,
			agentModelRaw: nil,
			agentReasoningEffortRaw: nil,
			autoEditEnabled: false,
			parentSessionID: parentSessionID
		)
		vm.test_upsertSessionIndex(
			sessionID: otherSessionID,
			tabID: otherTab,
			name: "Other",
			lastUserMessageAt: Date(timeIntervalSince1970: 200),
			savedAt: Date(timeIntervalSince1970: 200),
			lastRunStateRaw: nil,
			itemCount: 1,
			agentKindRaw: nil,
			agentModelRaw: nil,
			agentReasoningEffortRaw: nil,
			autoEditEnabled: false
		)

		vm.ensureSession(for: childTab)
		guard let childSession = vm.sessions[childTab] else {
			return XCTFail("Expected child session")
		}
		childSession.activeAgentSessionID = childSessionID
		childSession.parentSessionID = parentSessionID
		childSession.hasLoadedPersistedState = true
		childSession.lastUserMessageAt = Date(timeIntervalSince1970: 300)

		let tabs = [
			ComposeTabState(id: parentTab, name: "Parent", lastModified: Date(timeIntervalSince1970: 100), activeAgentSessionID: parentSessionID),
			ComposeTabState(id: childTab, name: "Child", lastModified: Date(timeIntervalSince1970: 300), activeAgentSessionID: childSessionID),
			ComposeTabState(id: otherTab, name: "Other", lastModified: Date(timeIntervalSince1970: 200), activeAgentSessionID: otherSessionID)
		]

		let sidebar = vm.sidebarSessions(for: tabs)
		XCTAssertEqual(sidebar.map(\.tabID), [parentTab, childTab, otherTab])
		XCTAssertEqual(sidebar.map(\.depth), [0, 1, 0])
	}

	func testSidebarSessionsUseStubDatesAfterHydration() {
		let vm = makeViewModel()
		let newerStubTab = UUID()
		let hydratedOlderStubTab = UUID()
		let newerStubSessionID = UUID()
		let hydratedOlderStubSessionID = UUID()

		vm.test_upsertSessionIndex(
			sessionID: newerStubSessionID,
			tabID: newerStubTab,
			name: "Newer Stub",
			lastUserMessageAt: Date(timeIntervalSince1970: 300),
			savedAt: Date(timeIntervalSince1970: 300),
			lastRunStateRaw: nil,
			itemCount: 1,
			agentKindRaw: nil,
			agentModelRaw: nil,
			agentReasoningEffortRaw: nil,
			autoEditEnabled: false
		)
		vm.test_upsertSessionIndex(
			sessionID: hydratedOlderStubSessionID,
			tabID: hydratedOlderStubTab,
			name: "Hydrated Older Stub",
			lastUserMessageAt: Date(timeIntervalSince1970: 200),
			savedAt: Date(timeIntervalSince1970: 200),
			lastRunStateRaw: nil,
			itemCount: 1,
			agentKindRaw: nil,
			agentModelRaw: nil,
			agentReasoningEffortRaw: nil,
			autoEditEnabled: false
		)

		vm.ensureSession(for: hydratedOlderStubTab)
		guard let hydratedSession = vm.sessions[hydratedOlderStubTab] else {
			return XCTFail("Expected hydrated session")
		}
		hydratedSession.activeAgentSessionID = hydratedOlderStubSessionID
		hydratedSession.hasLoadedPersistedState = true
		hydratedSession.lastUserMessageAt = Date(timeIntervalSince1970: 400)
		hydratedSession.lastActivityAt = Date(timeIntervalSince1970: 400)

		let tabs = [
			ComposeTabState(id: newerStubTab, name: "Newer Stub", lastModified: Date(timeIntervalSince1970: 300), activeAgentSessionID: newerStubSessionID),
			ComposeTabState(id: hydratedOlderStubTab, name: "Hydrated Older Stub", lastModified: Date(timeIntervalSince1970: 400), activeAgentSessionID: hydratedOlderStubSessionID)
		]

		let sidebar = vm.sidebarSessions(for: tabs)
		XCTAssertEqual(sidebar.map(\.tabID), [newerStubTab, hydratedOlderStubTab])
	}

	func testSidebarSessionsKeepSpawnedLiveSiblingsNewestFirstAfterIndexRepair() {
		let vm = makeViewModel()
		let parentTab = UUID()
		let olderChildTab = UUID()
		let newerChildTab = UUID()
		let olderChildSessionID = UUID()
		let newerChildSessionID = UUID()
		let parentSessionID = vm.test_mcpSpawnParentSessionID(sourceTabID: parentTab)
		XCTAssertNotNil(parentSessionID)

		for (tabID, sessionID, lastUserMessageAt) in [
			(olderChildTab, olderChildSessionID, Date(timeIntervalSince1970: 200)),
			(newerChildTab, newerChildSessionID, Date(timeIntervalSince1970: 300))
		] {
			vm.ensureSession(for: tabID)
			guard let session = vm.sessions[tabID] else {
				return XCTFail("Expected live child session")
			}
			session.activeAgentSessionID = sessionID
			session.hasLoadedPersistedState = true
			session.lastUserMessageAt = lastUserMessageAt
			vm.test_applySpawnParentSessionID(parentSessionID, tabID: tabID)
		}

		let tabs = [
			ComposeTabState(id: parentTab, name: "Parent", lastModified: Date(timeIntervalSince1970: 100), activeAgentSessionID: parentSessionID),
			ComposeTabState(id: olderChildTab, name: "Older Child", lastModified: Date(timeIntervalSince1970: 200), activeAgentSessionID: olderChildSessionID),
			ComposeTabState(id: newerChildTab, name: "Newer Child", lastModified: Date(timeIntervalSince1970: 300), activeAgentSessionID: newerChildSessionID)
		]

		let sidebar = vm.sidebarSessions(for: tabs)
		XCTAssertEqual(sidebar.map(\.tabID), [parentTab, newerChildTab, olderChildTab])
		XCTAssertEqual(sidebar.map(\.depth), [0, 1, 1])
		XCTAssertEqual(vm.sessionIndex[olderChildSessionID]?.parentSessionID, parentSessionID)
		XCTAssertEqual(vm.sessionIndex[newerChildSessionID]?.parentSessionID, parentSessionID)
	}

	func testSidebarSessionsKeepFullyLiveSiblingsNewestFirst() {
		let vm = makeViewModel()
		let parentTab = UUID()
		let olderChildTab = UUID()
		let newerChildTab = UUID()
		let parentSessionID = UUID()
		let olderChildSessionID = UUID()
		let newerChildSessionID = UUID()

		for (tabID, sessionID, parentID, lastUserMessageAt) in [
			(parentTab, parentSessionID, Optional<UUID>.none, Date(timeIntervalSince1970: 100)),
			(olderChildTab, olderChildSessionID, parentSessionID, Date(timeIntervalSince1970: 200)),
			(newerChildTab, newerChildSessionID, parentSessionID, Date(timeIntervalSince1970: 300))
		] {
			vm.ensureSession(for: tabID)
			guard let session = vm.sessions[tabID] else {
				return XCTFail("Expected live session")
			}
			session.activeAgentSessionID = sessionID
			session.parentSessionID = parentID
			session.hasLoadedPersistedState = true
			session.lastUserMessageAt = lastUserMessageAt
		}

		let tabs = [
			ComposeTabState(id: parentTab, name: "Parent", lastModified: Date(timeIntervalSince1970: 100), activeAgentSessionID: parentSessionID),
			ComposeTabState(id: olderChildTab, name: "Older Child", lastModified: Date(timeIntervalSince1970: 200), activeAgentSessionID: olderChildSessionID),
			ComposeTabState(id: newerChildTab, name: "Newer Child", lastModified: Date(timeIntervalSince1970: 300), activeAgentSessionID: newerChildSessionID)
		]

		let sidebar = vm.sidebarSessions(for: tabs)
		XCTAssertEqual(sidebar.map(\.tabID), [parentTab, newerChildTab, olderChildTab])
		XCTAssertEqual(sidebar.map(\.depth), [0, 1, 1])
	}

	func testSidebarSessionsKeepChildOrderStableWhenPersistedChildHydratesLive() {
		let vm = makeViewModel()
		let parentTab = UUID()
		let firstChildTab = UUID()
		let secondChildTab = UUID()
		let parentSessionID = UUID()
		let firstChildSessionID = UUID()
		let secondChildSessionID = UUID()

		vm.test_upsertSessionIndex(
			sessionID: parentSessionID,
			tabID: parentTab,
			name: "Parent",
			lastUserMessageAt: Date(timeIntervalSince1970: 100),
			savedAt: Date(timeIntervalSince1970: 100),
			lastRunStateRaw: nil,
			itemCount: 1,
			agentKindRaw: nil,
			agentModelRaw: nil,
			agentReasoningEffortRaw: nil,
			autoEditEnabled: false
		)
		vm.test_upsertSessionIndex(
			sessionID: firstChildSessionID,
			tabID: firstChildTab,
			name: "First Child",
			lastUserMessageAt: Date(timeIntervalSince1970: 200),
			savedAt: Date(timeIntervalSince1970: 200),
			lastRunStateRaw: nil,
			itemCount: 1,
			agentKindRaw: nil,
			agentModelRaw: nil,
			agentReasoningEffortRaw: nil,
			autoEditEnabled: false,
			parentSessionID: parentSessionID
		)
		vm.test_upsertSessionIndex(
			sessionID: secondChildSessionID,
			tabID: secondChildTab,
			name: "Second Child",
			lastUserMessageAt: Date(timeIntervalSince1970: 300),
			savedAt: Date(timeIntervalSince1970: 300),
			lastRunStateRaw: nil,
			itemCount: 1,
			agentKindRaw: nil,
			agentModelRaw: nil,
			agentReasoningEffortRaw: nil,
			autoEditEnabled: false,
			parentSessionID: parentSessionID
		)

		vm.ensureSession(for: secondChildTab)
		guard let secondChildSession = vm.sessions[secondChildTab] else {
			return XCTFail("Expected live child session")
		}
		secondChildSession.activeAgentSessionID = secondChildSessionID
		secondChildSession.parentSessionID = parentSessionID
		secondChildSession.hasLoadedPersistedState = true
		secondChildSession.lastUserMessageAt = Date(timeIntervalSince1970: 300)

		let tabs = [
			ComposeTabState(id: parentTab, name: "Parent", lastModified: Date(timeIntervalSince1970: 100), activeAgentSessionID: parentSessionID),
			ComposeTabState(id: firstChildTab, name: "First Child", lastModified: Date(timeIntervalSince1970: 200), activeAgentSessionID: firstChildSessionID),
			ComposeTabState(id: secondChildTab, name: "Second Child", lastModified: Date(timeIntervalSince1970: 300), activeAgentSessionID: secondChildSessionID)
		]

		let sidebar = vm.sidebarSessions(for: tabs)
		XCTAssertEqual(sidebar.map(\.tabID), [parentTab, firstChildTab, secondChildTab])
		XCTAssertEqual(sidebar.map(\.depth), [0, 1, 1])
	}

	func testSidebarSessionsKeepPinnedRootAheadOfUnpinnedParentWithPinnedChild() {
		let vm = makeViewModel()
		let parentTab = UUID()
		let childTab = UUID()
		let pinnedRootTab = UUID()
		let parentSessionID = UUID()
		let childSessionID = UUID()
		let pinnedRootSessionID = UUID()

		vm.test_upsertSessionIndex(
			sessionID: parentSessionID,
			tabID: parentTab,
			name: "Parent",
			lastUserMessageAt: Date(timeIntervalSince1970: 100),
			savedAt: Date(timeIntervalSince1970: 100),
			lastRunStateRaw: nil,
			itemCount: 1,
			agentKindRaw: nil,
			agentModelRaw: nil,
			agentReasoningEffortRaw: nil,
			autoEditEnabled: false
		)
		vm.test_upsertSessionIndex(
			sessionID: childSessionID,
			tabID: childTab,
			name: "Pinned Child",
			lastUserMessageAt: Date(timeIntervalSince1970: 300),
			savedAt: Date(timeIntervalSince1970: 300),
			lastRunStateRaw: nil,
			itemCount: 1,
			agentKindRaw: nil,
			agentModelRaw: nil,
			agentReasoningEffortRaw: nil,
			autoEditEnabled: false,
			parentSessionID: parentSessionID
		)
		vm.test_upsertSessionIndex(
			sessionID: pinnedRootSessionID,
			tabID: pinnedRootTab,
			name: "Pinned Root",
			lastUserMessageAt: Date(timeIntervalSince1970: 250),
			savedAt: Date(timeIntervalSince1970: 250),
			lastRunStateRaw: nil,
			itemCount: 1,
			agentKindRaw: nil,
			agentModelRaw: nil,
			agentReasoningEffortRaw: nil,
			autoEditEnabled: false
		)

		vm.ensureSession(for: childTab)
		guard let childSession = vm.sessions[childTab] else {
			return XCTFail("Expected child session")
		}
		childSession.activeAgentSessionID = childSessionID
		childSession.parentSessionID = parentSessionID
		childSession.hasLoadedPersistedState = true
		childSession.lastUserMessageAt = Date(timeIntervalSince1970: 300)

		let tabs = [
			ComposeTabState(id: parentTab, name: "Parent", lastModified: Date(timeIntervalSince1970: 100), isPinned: false, activeAgentSessionID: parentSessionID),
			ComposeTabState(id: childTab, name: "Pinned Child", lastModified: Date(timeIntervalSince1970: 300), isPinned: true, activeAgentSessionID: childSessionID),
			ComposeTabState(id: pinnedRootTab, name: "Pinned Root", lastModified: Date(timeIntervalSince1970: 250), isPinned: true, activeAgentSessionID: pinnedRootSessionID)
		]

		let sidebar = vm.sidebarSessions(for: tabs)
		XCTAssertEqual(sidebar.map(\.tabID), [pinnedRootTab, parentTab, childTab])
		XCTAssertEqual(sidebar.map(\.depth), [0, 0, 1])
	}

	func testSidebarSessionsKeepFreshProvisionalSessionAbovePersistedThreadGroup() {
		let vm = makeViewModel()
		let parentTab = UUID()
		let childTab = UUID()
		let freshTab = UUID()
		let parentSessionID = UUID()
		let childSessionID = UUID()

		vm.test_upsertSessionIndex(
			sessionID: parentSessionID,
			tabID: parentTab,
			name: "Parent",
			lastUserMessageAt: Date(timeIntervalSince1970: 100),
			savedAt: Date(timeIntervalSince1970: 100),
			lastRunStateRaw: nil,
			itemCount: 1,
			agentKindRaw: nil,
			agentModelRaw: nil,
			agentReasoningEffortRaw: nil,
			autoEditEnabled: false
		)
		vm.test_upsertSessionIndex(
			sessionID: childSessionID,
			tabID: childTab,
			name: "Child",
			lastUserMessageAt: Date(timeIntervalSince1970: 200),
			savedAt: Date(timeIntervalSince1970: 200),
			lastRunStateRaw: nil,
			itemCount: 1,
			agentKindRaw: nil,
			agentModelRaw: nil,
			agentReasoningEffortRaw: nil,
			autoEditEnabled: false,
			parentSessionID: parentSessionID
		)

		vm.ensureSession(for: freshTab)
		guard let freshSession = vm.sessions[freshTab] else {
			return XCTFail("Expected fresh session")
		}
		freshSession.hasLoadedPersistedState = true
		freshSession.lastActivityAt = Date(timeIntervalSince1970: 300)
		freshSession.lastUserMessageAt = nil

		let tabs = [
			ComposeTabState(id: parentTab, name: "Parent", lastModified: Date(timeIntervalSince1970: 100), activeAgentSessionID: parentSessionID),
			ComposeTabState(id: childTab, name: "Child", lastModified: Date(timeIntervalSince1970: 200), activeAgentSessionID: childSessionID),
			ComposeTabState(id: freshTab, name: "New Chat", lastModified: Date(timeIntervalSince1970: 300), activeAgentSessionID: nil)
		]

		let sidebar = vm.sidebarSessions(for: tabs)
		XCTAssertEqual(sidebar.map(\.tabID), [freshTab, parentTab, childTab])
		XCTAssertEqual(sidebar.map(\.depth), [0, 0, 1])
		XCTAssertEqual(sidebar.first?.title, "New Chat")
	}

	func testSidebarSessionsKeepPersistedParentCycleFlat() {
		let vm = makeViewModel()
		let firstTab = UUID()
		let secondTab = UUID()
		let firstSessionID = UUID()
		let secondSessionID = UUID()

		vm.test_upsertSessionIndex(
			sessionID: firstSessionID,
			tabID: firstTab,
			name: "First",
			lastUserMessageAt: Date(timeIntervalSince1970: 200),
			savedAt: Date(timeIntervalSince1970: 200),
			lastRunStateRaw: nil,
			itemCount: 1,
			agentKindRaw: nil,
			agentModelRaw: nil,
			agentReasoningEffortRaw: nil,
			autoEditEnabled: false,
			parentSessionID: secondSessionID
		)
		vm.test_upsertSessionIndex(
			sessionID: secondSessionID,
			tabID: secondTab,
			name: "Second",
			lastUserMessageAt: Date(timeIntervalSince1970: 100),
			savedAt: Date(timeIntervalSince1970: 100),
			lastRunStateRaw: nil,
			itemCount: 1,
			agentKindRaw: nil,
			agentModelRaw: nil,
			agentReasoningEffortRaw: nil,
			autoEditEnabled: false,
			parentSessionID: firstSessionID
		)

		let tabs = [
			ComposeTabState(id: firstTab, name: "First", lastModified: Date(timeIntervalSince1970: 200), activeAgentSessionID: firstSessionID),
			ComposeTabState(id: secondTab, name: "Second", lastModified: Date(timeIntervalSince1970: 100), activeAgentSessionID: secondSessionID)
		]

		let sidebar = vm.sidebarSessions(for: tabs)
		XCTAssertEqual(sidebar.map(\.depth), [0, 0])
	}

	func testRefreshSessionListCacheKeepsWorkspaceOrderWhenPersistedThreadingMetadataArrives() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let service = AgentSessionDataService.shared
		let childTab = UUID()
		let parentTab = UUID()
		let parentSessionID = UUID()
		let childSessionID = UUID()
		let workspace = makeWorkspace(
			name: "Stable Restore Thread Order",
			root: tempRoot,
			composeTabs: [
				ComposeTabState(
					id: childTab,
					name: "Child",
					lastModified: Date(timeIntervalSince1970: 300),
					activeAgentSessionID: childSessionID
				),
				ComposeTabState(
					id: parentTab,
					name: "Parent",
					lastModified: Date(timeIntervalSince1970: 100),
					activeAgentSessionID: parentSessionID
				)
			]
		)
		_ = try await service.saveAgentSession(
			AgentSession(
				id: parentSessionID,
				workspaceID: workspace.id,
				composeTabID: parentTab,
				name: "Parent",
				savedAt: Date(timeIntervalSince1970: 100),
				items: [
					AgentChatItemPersist(from: AgentChatItem(timestamp: Date(timeIntervalSince1970: 100), kind: .user, text: "Parent", sequenceIndex: 0))
				],
				itemCount: 1,
				lastUserMessageAt: Date(timeIntervalSince1970: 100)
			),
			for: workspace
		)
		_ = try await service.saveAgentSession(
			AgentSession(
				id: childSessionID,
				workspaceID: workspace.id,
				composeTabID: childTab,
				name: "Child",
				savedAt: Date(timeIntervalSince1970: 300),
				items: [
					AgentChatItemPersist(from: AgentChatItem(timestamp: Date(timeIntervalSince1970: 300), kind: .user, text: "Child", sequenceIndex: 0))
				],
				itemCount: 1,
				lastUserMessageAt: Date(timeIntervalSince1970: 300),
				parentSessionID: parentSessionID
			),
			for: workspace
		)

		let vm = makeViewModel(testWorkspaceDirectory: tempRoot)
		await vm.test_handleWorkspaceSwitch(workspace)
		let deadline = Date().addingTimeInterval(2)
		while !vm.sessionListCacheReady && Date() < deadline {
			await Task.yield()
			try? await Task.sleep(nanoseconds: 10_000_000)
		}

		let sidebar = vm.sidebarSessions(for: workspace.composeTabs)
		XCTAssertEqual(sidebar.map(\.tabID), [childTab, parentTab])
		XCTAssertEqual(sidebar.map(\.depth), [0, 0])
		XCTAssertEqual(sidebar.first?.parentSessionID, parentSessionID)
	}

	func testRefreshSessionListCachePreservesPersistedParentSessionThreading() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let service = AgentSessionDataService.shared
		let parentTab = UUID()
		let childTab = UUID()
		let parentSessionID = UUID()
		let childSessionID = UUID()
		let workspace = makeWorkspace(
			name: "Persisted Parent Threading",
			root: tempRoot,
			composeTabs: [
				ComposeTabState(
					id: parentTab,
					name: "Parent",
					lastModified: Date(timeIntervalSince1970: 100),
					activeAgentSessionID: parentSessionID
				),
				ComposeTabState(
					id: childTab,
					name: "Child",
					lastModified: Date(timeIntervalSince1970: 300),
					activeAgentSessionID: childSessionID
				)
			]
		)
		_ = try await service.saveAgentSession(
			AgentSession(
				id: parentSessionID,
				workspaceID: workspace.id,
				composeTabID: parentTab,
				name: "Parent",
				savedAt: Date(timeIntervalSince1970: 100),
				items: [
					AgentChatItemPersist(from: AgentChatItem(timestamp: Date(timeIntervalSince1970: 100), kind: .user, text: "Parent", sequenceIndex: 0))
				],
				itemCount: 1,
				lastUserMessageAt: Date(timeIntervalSince1970: 100)
			),
			for: workspace
		)
		_ = try await service.saveAgentSession(
			AgentSession(
				id: childSessionID,
				workspaceID: workspace.id,
				composeTabID: childTab,
				name: "Child",
				savedAt: Date(timeIntervalSince1970: 300),
				items: [
					AgentChatItemPersist(from: AgentChatItem(timestamp: Date(timeIntervalSince1970: 300), kind: .user, text: "Child", sequenceIndex: 0))
				],
				itemCount: 1,
				lastUserMessageAt: Date(timeIntervalSince1970: 300),
				parentSessionID: parentSessionID
			),
			for: workspace
		)

		let vm = makeViewModel(testWorkspaceDirectory: tempRoot)
		await vm.test_handleWorkspaceSwitch(workspace)
		let deadline = Date().addingTimeInterval(2)
		while !vm.sessionListCacheReady && Date() < deadline {
			await Task.yield()
			try? await Task.sleep(nanoseconds: 10_000_000)
		}

		let sidebar = vm.sidebarSessions(for: workspace.composeTabs)
		XCTAssertEqual(sidebar.map(\.tabID), [parentTab, childTab])
		XCTAssertEqual(sidebar.map(\.depth), [0, 1])
		XCTAssertEqual(sidebar.last?.parentSessionID, parentSessionID)
	}
	
	// MARK: - Sidebar Run-State Attention

	func testSidebarStoreMarkAndClearAttentionBumpsRevision() {
		let store = AgentSessionSidebarUIStore()
		let tabA = UUID()
		let tabB = UUID()

		XCTAssertNil(store.attentionRunState(for: tabA))
		let baselineRevision = store.snapshot.revision

		// Mark two tabs as having attention.
		XCTAssertTrue(store.markRunStateAttention(tabID: tabA, state: .completed))
		XCTAssertEqual(store.attentionRunState(for: tabA), .completed)
		XCTAssertGreaterThan(store.snapshot.revision, baselineRevision)

		let afterFirstMark = store.snapshot.revision
		XCTAssertTrue(store.markRunStateAttention(tabID: tabB, state: .failed))
		XCTAssertEqual(store.attentionRunState(for: tabB), .failed)
		XCTAssertGreaterThan(store.snapshot.revision, afterFirstMark)

		// Idempotent — same state shouldn't bump revision.
		let stableRevision = store.snapshot.revision
		XCTAssertFalse(store.markRunStateAttention(tabID: tabA, state: .completed))
		XCTAssertEqual(store.snapshot.revision, stableRevision)

		// Clear one tab.
		XCTAssertTrue(store.clearRunStateAttention(tabID: tabA))
		XCTAssertNil(store.attentionRunState(for: tabA))
		XCTAssertEqual(store.attentionRunState(for: tabB), .failed)
		XCTAssertGreaterThan(store.snapshot.revision, stableRevision)

		// Double-clear is a no-op.
		let afterClear = store.snapshot.revision
		XCTAssertFalse(store.clearRunStateAttention(tabID: tabA))
		XCTAssertEqual(store.snapshot.revision, afterClear)
	}

	func testSidebarStoreIgnoresNonAttentionStates() {
		let store = AgentSessionSidebarUIStore()
		let tabID = UUID()

		// `.running`, `.idle`, `.cancelled` are not attention-eligible.
		XCTAssertFalse(store.markRunStateAttention(tabID: tabID, state: .running))
		XCTAssertFalse(store.markRunStateAttention(tabID: tabID, state: .idle))
		XCTAssertFalse(store.markRunStateAttention(tabID: tabID, state: .cancelled))
		XCTAssertNil(store.attentionRunState(for: tabID))

		// Waiting variants are all attention-eligible.
		XCTAssertTrue(store.markRunStateAttention(tabID: tabID, state: .waitingForUser))
		XCTAssertEqual(store.attentionRunState(for: tabID), .waitingForUser)
		XCTAssertTrue(store.markRunStateAttention(tabID: tabID, state: .waitingForApproval))
		XCTAssertEqual(store.attentionRunState(for: tabID), .waitingForApproval)
	}

	func testSidebarStoreBatchClearAttentionHandlesEmptyAndMissing() {
		let store = AgentSessionSidebarUIStore()
		XCTAssertFalse(store.clearRunStateAttention(for: []))

		let tabA = UUID()
		let tabB = UUID()
		let tabC = UUID()
		store.markRunStateAttention(tabID: tabA, state: .completed)
		store.markRunStateAttention(tabID: tabB, state: .failed)

		// Batch clear including an unknown tab should still succeed.
		XCTAssertTrue(store.clearRunStateAttention(for: [tabA, tabC]))
		XCTAssertNil(store.attentionRunState(for: tabA))
		XCTAssertEqual(store.attentionRunState(for: tabB), .failed)

		// Batch with no matches returns false.
		XCTAssertFalse(store.clearRunStateAttention(for: [tabC]))
	}

	func testBackgroundCompletionRaisesAttention() {
		let vm = makeViewModel()
		let backgroundTab = UUID()
		let foregroundTab = UUID()
		vm.ensureSession(for: backgroundTab)
		vm.ensureSession(for: foregroundTab)
		vm.test_setCurrentTabIDOverride(foregroundTab)
		guard let session = vm.session(for: backgroundTab, createIfNeeded: false) else {
			return XCTFail("Expected session for background tab")
		}

		// Seed the observer with the starting state (restored-session semantics).
		session.runState = .running
		vm.observeSidebarRunStateTransition(for: session)
		XCTAssertNil(vm.ui.sessionSidebar.attentionRunState(for: backgroundTab))

		// Background transition → attention raised.
		session.runState = .completed
		vm.observeSidebarRunStateTransition(for: session)
		XCTAssertEqual(vm.ui.sessionSidebar.attentionRunState(for: backgroundTab), .completed)
	}

	func testForegroundCompletionDoesNotRaiseAttention() {
		let vm = makeViewModel()
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		vm.test_setCurrentTabIDOverride(tabID)
		guard let session = vm.session(for: tabID, createIfNeeded: false) else {
			return XCTFail("Expected session for tab")
		}

		session.runState = .running
		vm.observeSidebarRunStateTransition(for: session)
		session.runState = .completed
		vm.observeSidebarRunStateTransition(for: session)

		XCTAssertNil(vm.ui.sessionSidebar.attentionRunState(for: tabID))
	}

	func testBackgroundWaitingForApprovalRaisesAttention() {
		let vm = makeViewModel()
		let tabID = UUID()
		let otherTabID = UUID()
		vm.ensureSession(for: tabID)
		vm.ensureSession(for: otherTabID)
		vm.test_setCurrentTabIDOverride(otherTabID)
		guard let session = vm.session(for: tabID, createIfNeeded: false) else {
			return XCTFail("Expected session for tab")
		}

		session.runState = .running
		vm.observeSidebarRunStateTransition(for: session)
		session.runState = .waitingForApproval
		vm.observeSidebarRunStateTransition(for: session)

		XCTAssertEqual(vm.ui.sessionSidebar.attentionRunState(for: tabID), .waitingForApproval)
	}

	func testResumedRunClearsStaleAttentionBadge() {
		let vm = makeViewModel()
		let tabID = UUID()
		let otherTabID = UUID()
		vm.ensureSession(for: tabID)
		vm.ensureSession(for: otherTabID)
		vm.test_setCurrentTabIDOverride(otherTabID)
		guard let session = vm.session(for: tabID, createIfNeeded: false) else {
			return XCTFail("Expected session for tab")
		}

		// Raise a completed-in-background badge.
		session.runState = .running
		vm.observeSidebarRunStateTransition(for: session)
		session.runState = .completed
		vm.observeSidebarRunStateTransition(for: session)
		XCTAssertEqual(vm.ui.sessionSidebar.attentionRunState(for: tabID), .completed)

		// A fresh run on the same background tab should clear the stale badge.
		session.runState = .running
		vm.observeSidebarRunStateTransition(for: session)
		XCTAssertNil(vm.ui.sessionSidebar.attentionRunState(for: tabID))
	}

	func testAcknowledgeAndDismissClearAttention() {
		let vm = makeViewModel()
		let tabID = UUID()
		vm.ui.sessionSidebar.markRunStateAttention(tabID: tabID, state: .completed)
		XCTAssertNotNil(vm.ui.sessionSidebar.attentionRunState(for: tabID))

		vm.acknowledgeSidebarRunAttention(tabID: tabID)
		XCTAssertNil(vm.ui.sessionSidebar.attentionRunState(for: tabID))

		vm.ui.sessionSidebar.markRunStateAttention(tabID: tabID, state: .failed)
		vm.dismissSidebarRunAttention(tabID: tabID)
		XCTAssertNil(vm.ui.sessionSidebar.attentionRunState(for: tabID))
	}

	func testStartingRunClearsAttentionOnSameTab() {
		let vm = makeViewModel()
		let tabID = UUID()
		vm.ensureSession(for: tabID)

		// Seed an unseen badge the user hasn't cleared yet.
		vm.ui.sessionSidebar.markRunStateAttention(tabID: tabID, state: .completed)
		XCTAssertEqual(vm.ui.sessionSidebar.attentionRunState(for: tabID), .completed)

		// Calling setAgentRunActive(true) models the user kicking off a new run.
		vm.setAgentRunActive(tabID, isActive: true)
		XCTAssertNil(vm.ui.sessionSidebar.attentionRunState(for: tabID))
	}

	func testCleanupSidebarRunAttentionRemovesEntriesForClosingTabs() {
		let vm = makeViewModel()
		let tabA = UUID()
		let tabB = UUID()
		let tabC = UUID()
		vm.ensureSession(for: tabA)
		vm.ensureSession(for: tabB)
		vm.ensureSession(for: tabC)

		vm.ui.sessionSidebar.markRunStateAttention(tabID: tabA, state: .completed)
		vm.ui.sessionSidebar.markRunStateAttention(tabID: tabB, state: .failed)
		vm.ui.sessionSidebar.markRunStateAttention(tabID: tabC, state: .waitingForApproval)
		vm.sidebarObservedRunStateByTabID[tabA] = .completed
		vm.sidebarObservedRunStateByTabID[tabB] = .failed

		vm.cleanupSidebarRunAttention(tabIDs: [tabA, tabB])

		XCTAssertNil(vm.ui.sessionSidebar.attentionRunState(for: tabA))
		XCTAssertNil(vm.ui.sessionSidebar.attentionRunState(for: tabB))
		XCTAssertEqual(vm.ui.sessionSidebar.attentionRunState(for: tabC), .waitingForApproval)
		XCTAssertNil(vm.sidebarObservedRunStateByTabID[tabA])
		XCTAssertNil(vm.sidebarObservedRunStateByTabID[tabB])
	}

	func testCollapsedParentReportsHiddenDescendantAttention() {
		let vm = makeViewModel()
		let parentTabID = UUID()
		let childTabID = UUID()
		let parentSessionID = UUID()
		let childSessionID = UUID()

		vm.ensureSession(for: parentTabID)
		vm.ensureSession(for: childTabID)
		guard let parentSession = vm.session(for: parentTabID, createIfNeeded: false),
			let childSession = vm.session(for: childTabID, createIfNeeded: false) else {
			return XCTFail("Expected parent + child sessions")
		}
		parentSession.activeAgentSessionID = parentSessionID
		childSession.activeAgentSessionID = childSessionID
		childSession.parentSessionID = parentSessionID

		let now = Date(timeIntervalSince1970: 1_000_000)
		parentSession.lastActivityAt = now.addingTimeInterval(-60)
		childSession.lastActivityAt = now
		parentSession.lastUserMessageAt = now.addingTimeInterval(-60)
		childSession.lastUserMessageAt = now

		let tabs = [
			ComposeTabState(
				id: parentTabID,
				name: "Parent",
				lastModified: now.addingTimeInterval(-60),
				activeAgentSessionID: parentSessionID
			),
			ComposeTabState(
				id: childTabID,
				name: "Child",
				lastModified: now,
				activeAgentSessionID: childSessionID
			)
		]

		// Child has an unseen attention badge while the parent thread is collapsed.
		vm.ui.sessionSidebar.markRunStateAttention(tabID: childTabID, state: .completed)
		vm.setSidebarThreadCollapsed(true, for: .session(parentSessionID))

		let rows = vm.filteredSidebarSessions(for: tabs, currentTabID: nil, searchText: "")
		guard let parentRow = rows.first(where: { $0.tabID == parentTabID }) else {
			return XCTFail("Expected parent row")
		}
		XCTAssertTrue(parentRow.isThreadCollapsed)
		XCTAssertGreaterThanOrEqual(parentRow.hiddenThreadDescendantCount, 1)
		XCTAssertEqual(parentRow.hiddenThreadDescendantAttentionCount, 1)
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

	#if DEBUG
	private func makeDebugFingerprint(
		currentTabID: UUID? = nil,
		sessionListCacheReady: Bool = true,
		tabsWithActiveAgentRun: Set<UUID> = [],
		mcpControlledTabIDs: Set<UUID> = [],
		tabMetadataSignatures: [AgentModeViewModel.AgentSessionSidebarTabMetadataSignature] = [],
		sessionSignatures: [AgentModeViewModel.AgentSessionSidebarTabSignature] = [],
		sessionIndex: [UUID: AgentSessionIndexEntry] = [:],
		sessionListSortDates: [UUID: Date] = [:],
		sidebarRestoreFrozenOrderByTabID: [UUID: Int] = [:]
	) -> AgentModeViewModel.AgentSessionSidebarContentFingerprint {
		AgentModeViewModel.AgentSessionSidebarContentFingerprint(
			currentTabID: currentTabID,
			sessionListCacheReady: sessionListCacheReady,
			tabsWithActiveAgentRun: tabsWithActiveAgentRun,
			mcpControlledTabIDs: mcpControlledTabIDs,
			tabMetadataSignatures: tabMetadataSignatures,
			sessionSignatures: sessionSignatures,
			sessionIndex: sessionIndex,
			sessionListSortDates: sessionListSortDates,
			sidebarRestoreFrozenOrderByTabID: sidebarRestoreFrozenOrderByTabID
		)
	}

	private func makeDebugTabMetadata(
		tabID: UUID,
		order: Int = 0,
		normalizedName: String = "tab",
		isPinned: Bool = false,
		lastModified: Date = Date(timeIntervalSince1970: 1),
		activeAgentSessionID: UUID? = nil
	) -> AgentModeViewModel.AgentSessionSidebarTabMetadataSignature {
		AgentModeViewModel.AgentSessionSidebarTabMetadataSignature(
			tabID: tabID,
			order: order,
			normalizedName: normalizedName,
			activeAgentSessionID: activeAgentSessionID,
			isPinned: isPinned,
			lastModified: lastModified
		)
	}

	private func makeDebugSessionSignature(
		tabID: UUID,
		activeAgentSessionID: UUID? = nil,
		parentSessionID: UUID? = nil,
		hasLoadedPersistedState: Bool = true,
		itemsIsEmpty: Bool = false,
		runState: AgentSessionRunState = .idle,
		lastActivityAt: Date = Date(timeIntervalSince1970: 1),
		lastUserMessageAt: Date? = nil
	) -> AgentModeViewModel.AgentSessionSidebarTabSignature {
		AgentModeViewModel.AgentSessionSidebarTabSignature(
			tabID: tabID,
			activeAgentSessionID: activeAgentSessionID,
			parentSessionID: parentSessionID,
			hasLoadedPersistedState: hasLoadedPersistedState,
			itemsIsEmpty: itemsIsEmpty,
			runState: runState,
			lastActivityAt: lastActivityAt,
			lastUserMessageAt: lastUserMessageAt
		)
	}

	private func makeDebugIndexEntry(sessionID: UUID, tabID: UUID) -> AgentSessionIndexEntry {
		AgentSessionIndexEntry(
			id: sessionID,
			tabID: tabID,
			name: "Indexed",
			lastUserMessageAt: Date(timeIntervalSince1970: 1),
			savedAt: Date(timeIntervalSince1970: 2),
			lastRunStateRaw: nil,
			itemCount: 1,
			agentKindRaw: nil,
			agentModelRaw: nil,
			agentReasoningEffortRaw: nil,
			autoEditEnabled: false,
			parentSessionID: nil,
			hasUnknownConversationContent: false,
			isMCPOriginated: false
		)
	}
	#endif

	private func makeViewModel(testWorkspaceDirectory: URL? = nil) -> AgentModeViewModel {
		AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath,
			testWorkspaceDirectory: testWorkspaceDirectory
		) { _, _, _, _, _, _ in
			NoOpCodexController()
		}
	}

	private func makePolicyRow(
		index: Int,
		tabID: UUID = UUID(),
		sessionID: UUID? = nil,
		parentSessionID: UUID? = nil,
		lastUserMessageAt: Date?,
		activityDate: Date? = nil,
		isPinned: Bool = false,
		isMCPControlled: Bool = false
	) -> AgentModeViewModel.SidebarSession {
		let resolvedSessionID = sessionID ?? UUID()
		let resolvedActivityDate = activityDate ?? lastUserMessageAt ?? .distantPast
		return AgentModeViewModel.SidebarSession(
			id: tabID,
			tabID: tabID,
			title: "Session \(index)",
			lastUserMessageAt: lastUserMessageAt,
			activityDate: resolvedActivityDate,
			isPinned: isPinned,
			sessionID: resolvedSessionID,
			parentSessionID: parentSessionID,
			depth: parentSessionID == nil ? 0 : 1,
			isMCPControlled: isMCPControlled
		)
	}

	private func makeStashedTab(
		tabID: UUID,
		sessionID: UUID,
		name: String,
		isPinned: Bool = false,
		stashedAt: Date
	) -> StashedTab {
		StashedTab(
			tab: ComposeTabState(
				id: tabID,
				name: name,
				lastModified: Date(timeIntervalSince1970: 1),
				isPinned: isPinned,
				activeAgentSessionID: sessionID
			),
			stashedAt: stashedAt
		)
	}

	private func makeWorkspace(name: String, root: URL, composeTabs: [ComposeTabState] = []) -> WorkspaceModel {
		WorkspaceModel(
			name: name,
			repoPaths: [],
			customStoragePath: root,
			composeTabs: composeTabs,
			activeComposeTabID: composeTabs.first?.id
		)
	}

	private func metadataIndexURL(root: URL) -> URL {
		root
			.appendingPathComponent("AgentSessions", isDirectory: true)
			.appendingPathComponent("AgentSessionIndex.json")
	}

	private func makeTempDirectory() -> URL {
		let base = FileManager.default.temporaryDirectory
		let dir = base.appendingPathComponent("RepoPrompt-AgentModeSidebarSortingTests-\(UUID().uuidString)", isDirectory: true)
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir
	}
}

private final class NoOpCodexController: CodexSessionControlling {
	var events: AsyncStream<CodexNativeSessionController.Event> {
		AsyncStream { continuation in
			continuation.finish()
		}
	}
	
	var hasActiveThread: Bool { false }
	
	func ensureEventsStreamReady() {}
	
	func startOrResume(
		existing: CodexNativeSessionController.SessionRef?,
		baseInstructions: String
	) async throws -> CodexNativeSessionController.SessionRef {
		CodexNativeSessionController.SessionRef(
			conversationID: existing?.conversationID ?? "noop",
			rolloutPath: existing?.rolloutPath,
			model: existing?.model,
			reasoningEffort: existing?.reasoningEffort
		)
	}
	
	func sendUserMessage(_ text: String) async throws {}

	func sendUserTurn(text: String, images: [AgentImageAttachment]) async throws {}
	
	func cancelCurrentTurn() async {}
	
	func shutdown() async {}
	
	func respondToServerRequest(id: CodexAppServerRequestID, result: [String : Any]) async {}
}
