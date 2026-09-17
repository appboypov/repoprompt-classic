import XCTest
@testable import RepoPrompt

@MainActor
final class AgentDeepLinkRoutingTests: XCTestCase {
	private var storageRoot: URL!
	private var shell: WorkspaceShellViewModel?

	override func setUp() async throws {
		try await super.setUp()
		storageRoot = FileManager.default.temporaryDirectory
			.appendingPathComponent("AgentDeepLinkRoutingTests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
		UserDefaults.standard.set(storageRoot.path, forKey: "GlobalCustomStorageURL")
	}

	override func tearDown() async throws {
		await shell?.stop()
		shell = nil
		UserDefaults.standard.removeObject(forKey: "GlobalCustomStorageURL")
		try? FileManager.default.removeItem(at: storageRoot)
		try await super.tearDown()
	}

	/// A shell with workspaces A (visible) and B, plus the router wired to its action service.
	private func makeStartedRouter() async throws -> (router: AppDeepLinkRouter, a: UUID, b: UUID) {
		let shell = WorkspaceShellViewModel(preparesRemainingInBackground: false)
		self.shell = shell
		let service = WorkspaceShellActionService(viewModel: shell)
		await shell.start()
		let a = try await shell.add(name: "A", folderPath: makeRoot("a"), makeVisible: true)
		let b = try await shell.add(name: "B", folderPath: makeRoot("b"), makeVisible: false)
		let router = AppDeepLinkRouter(windowStatesManager: WindowStatesManager.shared, actionService: service)
		return (router, a, b)
	}

	private func makeRoot(_ name: String) throws -> String {
		let url = storageRoot.appendingPathComponent(name, isDirectory: true)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		return url.path
	}

	func testOpenRouteSelectsWorkspaceBeforeRoutingSession() async throws {
		let (router, a, b) = try await makeStartedRouter()
		let shell = try XCTUnwrap(shell)
		XCTAssertEqual(shell.snapshot.visibleWorkspaceID, a)
		let tabID = try XCTUnwrap(shell.runtime(for: b)?.promptManager.activeComposeTabID)

		await router.route(url: AgentSessionDeepLinkRoute(workspaceID: b, tabID: tabID).url)

		XCTAssertEqual(shell.snapshot.visibleWorkspaceID, b)
		XCTAssertEqual(shell.runtime(for: b)?.promptManager.activeComposeTabID, tabID)
		XCTAssertTrue(WindowStatesManager.shared.pendingURLs.isEmpty)
	}

	func testOpenRouteWithUnknownWorkspaceActivatesAppOnly() async throws {
		let (router, a, _) = try await makeStartedRouter()
		let shell = try XCTUnwrap(shell)

		await router.route(url: URL(string: "repoprompt://workspace?id=\(UUID().uuidString)")!)

		XCTAssertEqual(shell.snapshot.visibleWorkspaceID, a)
		XCTAssertTrue(WindowStatesManager.shared.pendingURLs.isEmpty)
	}

	func testRouteBeforeShellStartQueuesURLAndStartDrainsIt() async throws {
		let shell = WorkspaceShellViewModel(preparesRemainingInBackground: false)
		self.shell = shell
		let service = WorkspaceShellActionService(viewModel: shell)
		let router = AppDeepLinkRouter(windowStatesManager: WindowStatesManager.shared, actionService: service)
		WindowStatesManager.shared.pendingURLs = []
		let url = URL(string: "repoprompt://workspace?name=Nowhere")!

		await router.route(url: url)
		XCTAssertEqual(WindowStatesManager.shared.pendingURLs, [url])

		await shell.start()
		XCTAssertTrue(WindowStatesManager.shared.pendingURLs.isEmpty)
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
