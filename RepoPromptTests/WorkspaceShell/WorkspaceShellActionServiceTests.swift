import XCTest
@testable import RepoPrompt

/// Runs the action service against real runtimes on a temporary workspace root (`GlobalCustomStorageURL`).
@MainActor
final class WorkspaceShellActionServiceTests: XCTestCase {
	private var storageRoot: URL!
	private var previousStoragePath: String?
	private var viewModel: WorkspaceShellViewModel?

	override func setUp() async throws {
		try await super.setUp()
		storageRoot = FileManager.default.temporaryDirectory
			.appendingPathComponent("WorkspaceShellActionServiceTests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
		previousStoragePath = UserDefaults.standard.string(forKey: "GlobalCustomStorageURL")
		UserDefaults.standard.set(storageRoot.path, forKey: "GlobalCustomStorageURL")
		resetApprovals()
	}

	override func tearDown() async throws {
		resetApprovals()
		await viewModel?.stop()
		viewModel = nil
		if let previousStoragePath {
			UserDefaults.standard.set(previousStoragePath, forKey: "GlobalCustomStorageURL")
		} else {
			UserDefaults.standard.removeObject(forKey: "GlobalCustomStorageURL")
		}
		try? FileManager.default.removeItem(at: storageRoot)
		try await super.tearDown()
	}

	private func makeStartedService() async -> WorkspaceShellActionService {
		let shell = WorkspaceShellViewModel(preparesRemainingInBackground: false)
		viewModel = shell
		let service = WorkspaceShellActionService(viewModel: shell)
		await shell.start()
		return service
	}

	private func makeRoot(_ name: String) throws -> String {
		let url = storageRoot.appendingPathComponent(name, isDirectory: true)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		return url.path
	}

	private func resetApprovals() {
		let manager = WorkspaceApprovalManager.shared
		manager.cancelAllPending()
		manager.setAutoApproveAll(false)
		for operation in WorkspaceApprovalOperation.allCases {
			manager.setAutoApproveOperation(operation, enabled: false)
		}
		for client in manager.trustedClients {
			manager.removeAllAutoApprovals(for: client.clientID)
		}
	}

	private func waitForPendingApproval(timeoutIterations: Int = 200) async {
		for _ in 0..<timeoutIterations where WorkspaceApprovalManager.shared.pendingRequest == nil {
			await Task.yield()
		}
	}

	func testDispatchSelectReturnsSnapshotWithVisibleID() async throws {
		let service = await makeStartedService()
		let shell = service.viewModel
		let a = try await shell.add(name: "A", folderPath: try makeRoot("a"), makeVisible: true)
		let b = try await shell.add(name: "B", folderPath: try makeRoot("b"), makeVisible: false)
		XCTAssertEqual(shell.visibleWorkspaceID, a)

		let snapshot = try await service.dispatch(.select(SelectWorkspacePayload(workspaceID: b)))

		XCTAssertEqual(snapshot.visibleWorkspaceID, b)
		XCTAssertEqual(snapshot.workspaces.first(where: { $0.id == b })?.isVisible, true)
		XCTAssertEqual(snapshot.workspaces.first(where: { $0.id == a })?.isVisible, false)
	}

	func testDispatchRemoveWithRunningAgentRequiresConfirmation() async throws {
		let service = await makeStartedService()
		let shell = service.viewModel
		let a = try await shell.add(name: "A", folderPath: try makeRoot("a"), makeVisible: true)
		try XCTUnwrap(shell.runtime(for: a)).agentModeViewModel.setAgentRunActive(UUID(), isActive: true)
		WorkspaceApprovalManager.shared.setAutoApproveAll(true)

		let removal = Task { @MainActor in
			try await service.dispatch(.remove(RemoveWorkspacePayload(workspaceID: a, source: .tool(clientID: "test-client"))))
		}
		await waitForPendingApproval()

		let pending = try XCTUnwrap(WorkspaceApprovalManager.shared.pendingRequest, "a busy removal prompts even with auto-approve")
		XCTAssertTrue(pending.hasRunningAgents)
		XCTAssertEqual(pending.workspaceID, a)

		WorkspaceApprovalManager.shared.resolveApproval(allow: true)
		let snapshot = try await removal.value
		XCTAssertNil(shell.runtime(for: a))
		XCTAssertFalse(snapshot.workspaces.contains(where: { $0.id == a }))
	}

	func testDispatchRemoveCancelLeavesWorkspaceAndAgent() async throws {
		let service = await makeStartedService()
		let shell = service.viewModel
		let a = try await shell.add(name: "A", folderPath: try makeRoot("a"), makeVisible: true)
		let runtime = try XCTUnwrap(shell.runtime(for: a))
		let tabID = UUID()
		runtime.agentModeViewModel.setAgentRunActive(tabID, isActive: true)

		let removal = Task { @MainActor in
			try await service.dispatch(.remove(RemoveWorkspacePayload(workspaceID: a, source: .tool(clientID: "test-client"))))
		}
		await waitForPendingApproval()
		XCTAssertNotNil(WorkspaceApprovalManager.shared.pendingRequest)

		WorkspaceApprovalManager.shared.resolveApproval(allow: false)
		do {
			_ = try await removal.value
			XCTFail("cancelled removal throws")
		} catch WorkspaceShellError.cancelled {
		}
		XCTAssertTrue(shell.runtime(for: a) === runtime)
		XCTAssertTrue(runtime.agentModeViewModel.tabsWithActiveAgentRun.contains(tabID))
		XCTAssertTrue(shell.snapshot.workspaces.contains(where: { $0.id == a }))
	}

	func testForwardSwitchToSystemWorkspaceIsBlocked() async throws {
		let service = await makeStartedService()
		let shell = service.viewModel
		let a = try await shell.add(name: "A", folderPath: try makeRoot("a"), makeVisible: true)
		let system = try XCTUnwrap(shell.hostRuntime?.workspaceManager.workspaces.first(where: { $0.isSystemWorkspace }))

		let result = await service.forwardSwitch(system)

		guard case .blocked = result else {
			return XCTFail("expected blocked, got \(result)")
		}
		XCTAssertEqual(shell.visibleWorkspaceID, a)
	}

	func testSetSidebarCollapsedPersistsPreference() async throws {
		let key = WorkspaceShellViewModel.sidebarCollapsedDefaultsKey
		let previous = UserDefaults.standard.object(forKey: key)
		defer {
			if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
		}
		UserDefaults.standard.removeObject(forKey: key)
		let service = await makeStartedService()

		let collapsed = try await service.dispatch(.setSidebarCollapsed(SetSidebarCollapsedPayload(isCollapsed: true)))
		XCTAssertTrue(collapsed.isWorkspaceSidebarCollapsed)
		XCTAssertTrue(UserDefaults.standard.bool(forKey: key))
		XCTAssertTrue(WorkspaceShellViewModel(preparesRemainingInBackground: false).isWorkspaceSidebarCollapsed)

		let expanded = try await service.dispatch(.setSidebarCollapsed(SetSidebarCollapsedPayload(isCollapsed: false)))
		XCTAssertFalse(expanded.isWorkspaceSidebarCollapsed)
		XCTAssertFalse(UserDefaults.standard.bool(forKey: key))
	}

	func testCaptureRejectsRelativePathAndMissingDirectory() throws {
		XCTAssertThrowsError(try WorkspaceShellActionService.validateCaptureOutputPath("shot.png")) { error in
			guard case WorkspaceShellError.invalidOutputPath = error else { return XCTFail("unexpected \(error)") }
		}
		let missing = storageRoot.appendingPathComponent("missing", isDirectory: true).appendingPathComponent("shot.png").path
		XCTAssertThrowsError(try WorkspaceShellActionService.validateCaptureOutputPath(missing)) { error in
			guard case WorkspaceShellError.invalidOutputPath = error else { return XCTFail("unexpected \(error)") }
		}
		XCTAssertThrowsError(try WorkspaceShellActionService.validateCaptureOutputPath(storageRoot.appendingPathComponent("shot.jpg").path))
		XCTAssertEqual(
			try WorkspaceShellActionService.validateCaptureOutputPath(storageRoot.appendingPathComponent("shot.png").path).lastPathComponent,
			"shot.png"
		)
	}

	func testOpenRouteWithUnknownWorkspaceLeavesVisibleUnchanged() async throws {
		let service = await makeStartedService()
		let shell = service.viewModel
		let a = try await shell.add(name: "A", folderPath: try makeRoot("a"), makeVisible: true)
		_ = try await shell.add(name: "B", folderPath: try makeRoot("b"), makeVisible: false)

		let byID = try await service.dispatch(.openRoute(OpenRoutePayload(target: .workspace(id: UUID(), name: nil))))
		XCTAssertEqual(byID.visibleWorkspaceID, a)

		let byName = try await service.dispatch(.openRoute(OpenRoutePayload(target: .workspace(id: nil, name: "Nope"))))
		XCTAssertEqual(byName.visibleWorkspaceID, a)
	}

	func testEveryActionNameHasAHandler() async {
		let service = await makeStartedService()
		XCTAssertEqual(service.registeredActionNames, Set(WorkspaceShellActionName.allCases))
	}
}
