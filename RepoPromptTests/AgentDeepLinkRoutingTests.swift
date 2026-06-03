import XCTest
@testable import RepoPrompt

@MainActor
final class AgentDeepLinkRoutingTests: XCTestCase {
	func testAgentSessionRouterPrefersExactSourceWindowBeforeWorkspaceMatch() async throws {
		let sourceRoot = makeTempDirectory()
		let workspaceRoot = makeTempDirectory()
		defer {
			try? FileManager.default.removeItem(at: sourceRoot)
			try? FileManager.default.removeItem(at: workspaceRoot)
		}
		let sourceTabID = UUID()
		let workspaceTabID = UUID()
		let sourceWindow = await makeWindowState(
			root: sourceRoot,
			composeTabs: [ComposeTabState(id: sourceTabID, name: "Source", lastModified: Date())],
			activeComposeTabID: sourceTabID
		)
		let workspaceWindow = await makeWindowState(
			root: workspaceRoot,
			composeTabs: [ComposeTabState(id: workspaceTabID, name: "Workspace", lastModified: Date())],
			activeComposeTabID: workspaceTabID
		)
		defer {
			Task { await sourceWindow.tearDown() }
			Task { await workspaceWindow.tearDown() }
		}
		let workspace = try XCTUnwrap(workspaceWindow.workspaceManager.activeWorkspace)
		let route = AgentSessionDeepLinkRoute(
			windowID: sourceWindow.windowID,
			workspaceID: workspace.id,
			tabID: UUID()
		)

		let target = AppDeepLinkRouter.agentSessionPreferredExistingWindow(
			for: route,
			in: [workspaceWindow, sourceWindow]
		)

		XCTAssertEqual(target?.windowID, sourceWindow.windowID)
	}

	func testAgentSessionRouterFallsBackToWorkspaceMatchingWindowWithoutSource() async throws {
		let firstRoot = makeTempDirectory()
		let workspaceRoot = makeTempDirectory()
		defer {
			try? FileManager.default.removeItem(at: firstRoot)
			try? FileManager.default.removeItem(at: workspaceRoot)
		}
		let firstTabID = UUID()
		let workspaceTabID = UUID()
		let firstWindow = await makeWindowState(
			root: firstRoot,
			composeTabs: [ComposeTabState(id: firstTabID, name: "First", lastModified: Date())],
			activeComposeTabID: firstTabID
		)
		let workspaceWindow = await makeWindowState(
			root: workspaceRoot,
			composeTabs: [ComposeTabState(id: workspaceTabID, name: "Workspace", lastModified: Date())],
			activeComposeTabID: workspaceTabID
		)
		defer {
			Task { await firstWindow.tearDown() }
			Task { await workspaceWindow.tearDown() }
		}
		let workspace = try XCTUnwrap(workspaceWindow.workspaceManager.activeWorkspace)
		let route = AgentSessionDeepLinkRoute(workspaceID: workspace.id, tabID: UUID())

		let target = AppDeepLinkRouter.agentSessionPreferredExistingWindow(
			for: route,
			in: [firstWindow, workspaceWindow]
		)

		XCTAssertEqual(target?.windowID, workspaceWindow.windowID)
	}

	func testAgentSessionRouterDoesNotOpenOrQueueWhenNoExistingWindowCanRoute() async throws {
		let unrelatedRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: unrelatedRoot) }
		let unrelatedTabID = UUID()
		let unrelatedWindow = await makeWindowState(
			root: unrelatedRoot,
			composeTabs: [ComposeTabState(id: unrelatedTabID, name: "Unrelated", lastModified: Date())],
			activeComposeTabID: unrelatedTabID
		)
		defer { Task { await unrelatedWindow.tearDown() } }

		let manager = WindowStatesManager.shared
		let originalWindows = manager.allWindows
		let originalPendingURLs = manager.pendingURLs
		var openerCallCount = 0
		AppWindowOpener.shared.installForTesting {
			openerCallCount += 1
		}
		defer {
			manager.allWindows = originalWindows
			manager.pendingURLs = originalPendingURLs
			AppWindowOpener.shared.resetForTesting()
		}
		manager.allWindows = [unrelatedWindow]
		manager.pendingURLs = []

		let route = AgentSessionDeepLinkRoute(workspaceID: UUID(), tabID: UUID())
		await AppDeepLinkRouter(windowStatesManager: manager).route(notificationRoute: route)

		XCTAssertEqual(openerCallCount, 0)
		XCTAssertEqual(manager.allWindows.map(\.windowID), [unrelatedWindow.windowID])
		XCTAssertTrue(manager.pendingURLs.isEmpty)
		XCTAssertNotEqual(unrelatedWindow.workspaceManager.activeWorkspace?.id, route.workspaceID)
	}

	func testAgentSessionRouterUsesExistingResolvableFallbackWindowBeforeGivingUp() async throws {
		let activeRoot = makeTempDirectory()
		let targetRoot = makeTempDirectory()
		defer {
			try? FileManager.default.removeItem(at: activeRoot)
			try? FileManager.default.removeItem(at: targetRoot)
		}
		let activeTabID = UUID()
		let targetTabID = UUID()
		let sessionID = UUID()
		let windowState = await makeWindowState(
			activeRoot: activeRoot,
			activeTab: ComposeTabState(id: activeTabID, name: "Active Workspace", lastModified: Date()),
			targetRoot: targetRoot,
			targetTab: ComposeTabState(id: targetTabID, name: "Target Workspace", lastModified: Date(), activeAgentSessionID: sessionID)
		)
		defer { Task { await windowState.tearDown() } }
		let targetWorkspace = try XCTUnwrap(windowState.workspaceManager.workspaces.first(where: { workspace in
			workspace.composeTabs.contains(where: { $0.id == targetTabID })
		}))

		let manager = WindowStatesManager.shared
		let originalWindows = manager.allWindows
		let originalPendingURLs = manager.pendingURLs
		var openerCallCount = 0
		AppWindowOpener.shared.installForTesting {
			openerCallCount += 1
		}
		defer {
			manager.allWindows = originalWindows
			manager.pendingURLs = originalPendingURLs
			AppWindowOpener.shared.resetForTesting()
		}
		manager.allWindows = [windowState]
		manager.pendingURLs = []

		await AppDeepLinkRouter(windowStatesManager: manager).route(
			notificationRoute: AgentSessionDeepLinkRoute(
				workspaceID: targetWorkspace.id,
				tabID: targetTabID,
				sessionID: sessionID
			)
		)

		XCTAssertEqual(openerCallCount, 0)
		XCTAssertTrue(manager.pendingURLs.isEmpty)
		XCTAssertEqual(windowState.workspaceManager.activeWorkspace?.id, targetWorkspace.id)
		XCTAssertEqual(windowState.promptManager.activeComposeTabID, targetTabID)
		XCTAssertEqual(windowState.uiMode, .agent)
	}

	func testRouteToAgentSessionSelectsTargetTabAndHydratesMatchingBinding() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let firstTabID = UUID()
		let targetTabID = UUID()
		let sessionID = UUID()
		let windowState = await makeWindowState(
			root: tempRoot,
			composeTabs: [
				ComposeTabState(id: firstTabID, name: "First", lastModified: Date()),
				ComposeTabState(id: targetTabID, name: "Target", lastModified: Date(), activeAgentSessionID: sessionID)
			],
			activeComposeTabID: firstTabID
		)
		defer { Task { await windowState.tearDown() } }
		let workspace = try XCTUnwrap(windowState.workspaceManager.activeWorkspace)

		let result = await windowState.routeToAgentSession(
			AgentSessionDeepLinkRoute(
				windowID: windowState.windowID,
				workspaceID: workspace.id,
				tabID: targetTabID,
				sessionID: sessionID
			)
		)

		XCTAssertEqual(result, .routed)
		XCTAssertEqual(windowState.uiMode, .agent)
		XCTAssertEqual(windowState.promptManager.activeComposeTabID, targetTabID)
		let session = try XCTUnwrap(windowState.agentModeViewModel.sessions[targetTabID])
		XCTAssertEqual(session.activeAgentSessionID, sessionID)
		XCTAssertTrue(session.hasLoadedPersistedState)
	}

	func testRouteToAgentSessionRestoresStashedTargetTabBeforeShowingIt() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let activeTabID = UUID()
		let stashedTabID = UUID()
		let sessionID = UUID()
		let stashedTab = ComposeTabState(
			id: stashedTabID,
			name: "Stashed Agent",
			lastModified: Date(),
			activeAgentSessionID: sessionID
		)
		let windowState = await makeWindowState(
			root: tempRoot,
			composeTabs: [ComposeTabState(id: activeTabID, name: "Active", lastModified: Date())],
			activeComposeTabID: activeTabID,
			stashedTabs: [StashedTab(tab: stashedTab)]
		)
		defer { Task { await windowState.tearDown() } }
		let workspace = try XCTUnwrap(windowState.workspaceManager.activeWorkspace)

		let result = await windowState.routeToAgentSession(
			AgentSessionDeepLinkRoute(
				workspaceID: workspace.id,
				tabID: stashedTabID,
				sessionID: sessionID
			)
		)

		XCTAssertEqual(result, .routed)
		XCTAssertEqual(windowState.uiMode, .agent)
		XCTAssertEqual(windowState.promptManager.activeComposeTabID, stashedTabID)
		let updatedWorkspace = try XCTUnwrap(windowState.workspaceManager.activeWorkspace)
		XCTAssertTrue(updatedWorkspace.composeTabs.contains(where: { $0.id == stashedTabID }))
		XCTAssertFalse(updatedWorkspace.stashedTabs.contains(where: { $0.tab.id == stashedTabID }))
		XCTAssertEqual(windowState.agentModeViewModel.sessions[stashedTabID]?.activeAgentSessionID, sessionID)
	}

	func testRouteToAgentSessionRebindsInactiveDifferentSessionOnlyAfterPersistedSessionVerifies() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let firstTabID = UUID()
		let targetTabID = UUID()
		let staleSessionID = UUID()
		let routedSessionID = UUID()
		let windowState = await makeWindowState(
			root: tempRoot,
			composeTabs: [
				ComposeTabState(id: firstTabID, name: "First", lastModified: Date()),
				ComposeTabState(id: targetTabID, name: "Target", lastModified: Date(), activeAgentSessionID: staleSessionID)
			],
			activeComposeTabID: firstTabID
		)
		defer { Task { await windowState.tearDown() } }
		let workspace = try XCTUnwrap(windowState.workspaceManager.activeWorkspace)
		let staleSession = windowState.agentModeViewModel.session(for: targetTabID)
		staleSession.activeAgentSessionID = staleSessionID
		staleSession.hasLoadedPersistedState = true
		staleSession.appendItem(AgentChatItem.user("stale", sequenceIndex: 0))

		let persistedSession = AgentSession(
			id: routedSessionID,
			workspaceID: workspace.id,
			composeTabID: targetTabID,
			name: "Routed",
			transcript: AgentTranscriptIO.importLegacyItems([
				.user("routed", sequenceIndex: 0)
			]),
			agentKind: DiscoverAgentKind.claudeCode.rawValue,
			agentModel: AgentModel.defaultModel.rawValue
		)
		_ = try await AgentSessionDataService.shared.saveAgentSession(
			persistedSession,
			for: workspace,
			preparation: .alreadyCanonicalTranscript
		)

		let result = await windowState.routeToAgentSession(
			AgentSessionDeepLinkRoute(
				workspaceID: workspace.id,
				tabID: targetTabID,
				sessionID: routedSessionID
			)
		)

		XCTAssertEqual(result, .routed)
		XCTAssertEqual(windowState.promptManager.activeComposeTabID, targetTabID)
		let hydrated = try XCTUnwrap(windowState.agentModeViewModel.sessions[targetTabID])
		XCTAssertEqual(hydrated.activeAgentSessionID, routedSessionID)
		XCTAssertTrue(hydrated.hasLoadedPersistedState)
		XCTAssertTrue(hydrated.items.contains(where: { $0.text == "routed" }))
		XCTAssertFalse(hydrated.items.contains(where: { $0.text == "stale" }))
		XCTAssertEqual(windowState.workspaceManager.activeAgentSessionID(forTabID: targetTabID), routedSessionID)
		let maybeSavedStaleSession = try await AgentSessionDataService.shared.loadAgentSession(id: staleSessionID, for: workspace)
		let savedStaleSession = try XCTUnwrap(maybeSavedStaleSession)
		let savedStaleTranscript = try XCTUnwrap(savedStaleSession.transcript)
		XCTAssertTrue(
			AgentTranscriptIO.workingSourceItems(from: savedStaleTranscript)
				.contains(where: { $0.text == "stale" })
		)
	}

	func testRouteToAgentSessionBlocksActiveDifferentSessionWithoutSwitchingTab() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let firstTabID = UUID()
		let targetTabID = UUID()
		let activeSessionID = UUID()
		let routedSessionID = UUID()
		let windowState = await makeWindowState(
			root: tempRoot,
			composeTabs: [
				ComposeTabState(id: firstTabID, name: "First", lastModified: Date()),
				ComposeTabState(id: targetTabID, name: "Target", lastModified: Date(), activeAgentSessionID: activeSessionID)
			],
			activeComposeTabID: firstTabID
		)
		defer { Task { await windowState.tearDown() } }
		let workspace = try XCTUnwrap(windowState.workspaceManager.activeWorkspace)
		let activeSession = windowState.agentModeViewModel.session(for: targetTabID)
		activeSession.activeAgentSessionID = activeSessionID
		activeSession.runState = .running

		let result = await windowState.routeToAgentSession(
			AgentSessionDeepLinkRoute(
				workspaceID: workspace.id,
				tabID: targetTabID,
				sessionID: routedSessionID
			)
		)

		XCTAssertEqual(result, .blockedByActiveDifferentSession)
		XCTAssertEqual(windowState.promptManager.activeComposeTabID, firstTabID)
		XCTAssertEqual(windowState.agentModeViewModel.sessions[targetTabID]?.activeAgentSessionID, activeSessionID)
	}

	private func makeWindowState(
		root: URL,
		composeTabs: [ComposeTabState],
		activeComposeTabID: UUID,
		stashedTabs: [StashedTab] = []
	) async -> WindowState {
		let windowState = WindowState()
		await windowState.workspaceManager.awaitInitialized()
		let workspace = WorkspaceModel(
			name: "Agent Deep Link Tests",
			repoPaths: [],
			customStoragePath: root,
			composeTabs: composeTabs,
			activeComposeTabID: activeComposeTabID,
			stashedTabs: stashedTabs
		)
		windowState.workspaceManager.workspaces = [workspace]
		windowState.workspaceManager.activeWorkspace = workspace
		windowState.promptManager.loadComposeTabsFromWorkspace(workspace)
		return windowState
	}

	private func makeWindowState(
		activeRoot: URL,
		activeTab: ComposeTabState,
		targetRoot: URL,
		targetTab: ComposeTabState
	) async -> WindowState {
		let windowState = WindowState()
		await windowState.workspaceManager.awaitInitialized()
		let activeWorkspace = WorkspaceModel(
			name: "Active Agent Deep Link Tests",
			repoPaths: [],
			customStoragePath: activeRoot,
			composeTabs: [activeTab],
			activeComposeTabID: activeTab.id
		)
		let targetWorkspace = WorkspaceModel(
			name: "Target Agent Deep Link Tests",
			repoPaths: [],
			customStoragePath: targetRoot,
			composeTabs: [targetTab],
			activeComposeTabID: targetTab.id
		)
		windowState.workspaceManager.workspaces = [activeWorkspace, targetWorkspace]
		windowState.workspaceManager.activeWorkspace = activeWorkspace
		windowState.promptManager.loadComposeTabsFromWorkspace(activeWorkspace)
		return windowState
	}

	private func makeTempDirectory() -> URL {
		let base = FileManager.default.temporaryDirectory
		let dir = base.appendingPathComponent("RepoPrompt-AgentDeepLinkRoutingTests-\(UUID().uuidString)", isDirectory: true)
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir
	}
}
