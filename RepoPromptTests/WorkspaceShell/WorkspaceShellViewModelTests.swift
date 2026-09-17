import AppKit
import XCTest
@testable import RepoPrompt

/// Runs real runtimes against a temporary workspace root (`GlobalCustomStorageURL`).
@MainActor
final class WorkspaceShellViewModelTests: XCTestCase {
	private var storageRoot: URL!
	private var previousStoragePath: String?
	private var viewModel: WorkspaceShellViewModel?

	override func setUp() async throws {
		try await super.setUp()
		storageRoot = FileManager.default.temporaryDirectory
			.appendingPathComponent("WorkspaceShellViewModelTests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
		previousStoragePath = UserDefaults.standard.string(forKey: "GlobalCustomStorageURL")
		UserDefaults.standard.set(storageRoot.path, forKey: "GlobalCustomStorageURL")
	}

	override func tearDown() async throws {
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

	private func makeStartedShell(preparesRemainingInBackground: Bool = true) async -> WorkspaceShellViewModel {
		let shell = WorkspaceShellViewModel(preparesRemainingInBackground: preparesRemainingInBackground)
		viewModel = shell
		await shell.start()
		return shell
	}

	private func makeRoot(_ name: String) throws -> String {
		let url = storageRoot.appendingPathComponent(name, isDirectory: true)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		return url.path
	}

	func testStartWithEmptyCatalogPublishesNilVisibleWorkspace() async {
		let shell = await makeStartedShell()

		XCTAssertNil(shell.visibleWorkspaceID)
		XCTAssertNil(shell.snapshot.visibleWorkspaceID)
		XCTAssertTrue(shell.snapshot.workspaces.isEmpty)
		XCTAssertTrue(shell.isStarted)
		XCTAssertNotNil(shell.hostRuntime)
		XCTAssertTrue(WindowStatesManager.shared.visibleWindowState === shell.hostRuntime)
		XCTAssertEqual(WindowStatesManager.shared.shellWindowID, shell.hostRuntime?.windowID)
	}

	func testStartSelectsRestoredEntryThenFallsBackToFirstCatalogEntry() async throws {
		let a = UUID(), b = UUID()
		let entries = [
			WorkspaceIndexEntry(id: a, name: "A", customStoragePath: nil, isSystemWorkspace: false, isHiddenInMenus: false),
			WorkspaceIndexEntry(id: b, name: "B", customStoragePath: nil, isSystemWorkspace: false, isHiddenInMenus: false)
		]
		let models = [WorkspaceModel(name: "A", repoPaths: ["/tmp/a"]), WorkspaceModel(name: "B", repoPaths: ["/tmp/b"])]
		func entry(id: UUID?, root: String?, name: String?) -> WindowSessionEntry {
			WindowSessionEntry(windowKind: .standard, workspaceID: id, workspaceName: name, isSystemWorkspace: false, isEphemeral: false, primaryRepoPath: root, lastFocused: true, uiMode: nil, workspaceInstanceNumber: nil)
		}

		XCTAssertEqual(WorkspaceShellViewModel.resolveInitialWorkspaceID(restoreEntry: entry(id: b, root: nil, name: nil), entries: entries, models: models), b)
		XCTAssertEqual(WorkspaceShellViewModel.resolveInitialWorkspaceID(restoreEntry: entry(id: UUID(), root: nil, name: "B"), entries: entries, models: models), b)
		XCTAssertEqual(WorkspaceShellViewModel.resolveInitialWorkspaceID(restoreEntry: entry(id: UUID(), root: nil, name: "Gone"), entries: entries, models: models), a)
		XCTAssertEqual(WorkspaceShellViewModel.resolveInitialWorkspaceID(restoreEntry: nil, entries: entries, models: models), a)
		XCTAssertNil(WorkspaceShellViewModel.resolveInitialWorkspaceID(restoreEntry: nil, entries: [], models: []))

		// A started shell over a catalog with no restore entry shows the first entry.
		let seed = await makeStartedShell()
		let first = try await seed.add(name: "First", folderPath: try makeRoot("first"), makeVisible: false)
		_ = try await seed.add(name: "Second", folderPath: try makeRoot("second"), makeVisible: false)
		await seed.stop()
		let shell = await makeStartedShell()
		XCTAssertEqual(shell.visibleWorkspaceID, first)
		XCTAssertEqual(shell.snapshot.workspaces.map(\.name), ["First", "Second"])
	}

	func testSelectMovesIDToFrontOfRecency() async throws {
		let shell = await makeStartedShell()
		let a = try await shell.add(name: "A", folderPath: try makeRoot("a"), makeVisible: true)
		let b = try await shell.add(name: "B", folderPath: try makeRoot("b"), makeVisible: true)
		try await shell.select(a)

		XCTAssertEqual(shell.visibleWorkspaceRecency, [a, b])
		XCTAssertEqual(shell.visibleWorkspaceID, a)
		XCTAssertTrue(WindowStatesManager.shared.visibleWindowState === shell.runtime(for: a))
		XCTAssertEqual(shell.snapshot.workspaces.first { $0.id == a }?.isVisible, true)
		XCTAssertEqual(shell.snapshot.workspaces.first { $0.id == b }?.isVisible, false)

		try await shell.select(a)
		XCTAssertEqual(shell.visibleWorkspaceRecency, [a, b], "re-selecting the visible workspace is a no-op")

		do {
			try await shell.select(UUID())
			XCTFail("unknown id must throw")
		} catch let error as WorkspaceShellError {
			guard case .unknownWorkspace = error else { return XCTFail("unexpected \(error)") }
		}
	}

	func testRemoveVisibleWorkspaceFallsBackToMostRecentThenCatalogOrder() async throws {
		let shell = await makeStartedShell()
		let a = try await shell.add(name: "A", folderPath: try makeRoot("a"), makeVisible: true)
		let b = try await shell.add(name: "B", folderPath: try makeRoot("b"), makeVisible: true)
		let c = try await shell.add(name: "C", folderPath: try makeRoot("c"), makeVisible: true)
		try await shell.select(b)

		await shell.disposeRuntime(for: b, reason: .removal)
		XCTAssertEqual(shell.visibleWorkspaceID, c, "most recent other workspace wins")
		XCTAssertEqual(shell.snapshot.workspaces.map(\.id), [a, c])

		await shell.disposeRuntime(for: c, reason: .removal)
		XCTAssertEqual(shell.visibleWorkspaceID, a)

		await shell.disposeRuntime(for: a, reason: .removal)
		XCTAssertNil(shell.visibleWorkspaceID)
		XCTAssertTrue(shell.snapshot.workspaces.isEmpty)
		XCTAssertTrue(WindowStatesManager.shared.visibleWindowState === shell.hostRuntime)
	}

	func testRemovePurgesRuntimeFromCache() async throws {
		let shell = await makeStartedShell()
		let a = try await shell.add(name: "A", folderPath: try makeRoot("a"), makeVisible: true)
		let b = try await shell.add(name: "B", folderPath: try makeRoot("b"), makeVisible: false)
		let runtime = try XCTUnwrap(shell.runtime(for: b))
		let windowID = runtime.windowID
		let folder = runtime.workspaceManager.workspaceDirectory(for: try XCTUnwrap(runtime.workspaceManager.activeWorkspace))

		await shell.disposeRuntime(for: b, reason: .removal)

		XCTAssertNil(shell.runtime(for: b))
		XCTAssertFalse(shell.visibleWorkspaceRecency.contains(b))
		XCTAssertFalse(WindowStatesManager.shared.hasWindow(id: windowID))
		XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "catalog document folder is deleted")
		XCTAssertTrue(FileManager.default.fileExists(atPath: storageRoot.appendingPathComponent("b").path), "repository root stays")
		XCTAssertEqual(shell.visibleWorkspaceID, a)
	}

	func testDuplicateCleanupDisposesRuntimeWithoutTouchingCatalog() async throws {
		let shell = await makeStartedShell()
		let a = try await shell.add(name: "A", folderPath: try makeRoot("a"), makeVisible: true)
		let b = try await shell.add(name: "B", folderPath: try makeRoot("b"), makeVisible: false)

		await shell.disposeRuntime(for: b, reason: .duplicateCleanup)

		XCTAssertNil(shell.runtime(for: b))
		XCTAssertEqual(shell.snapshot.workspaces.map(\.id), [a, b], "catalog entry is left for the cleanup's own delete")
	}

	func testPreparationQueueMovesSelectedWorkspaceFirst() async throws {
		let seed = await makeStartedShell()
		_ = try await seed.add(name: "A", folderPath: try makeRoot("a"), makeVisible: false)
		let b = try await seed.add(name: "B", folderPath: try makeRoot("b"), makeVisible: false)
		let c = try await seed.add(name: "C", folderPath: try makeRoot("c"), makeVisible: false)
		await seed.stop()

		let shell = await makeStartedShell(preparesRemainingInBackground: false)
		XCTAssertEqual(shell.preparationQueue, [b, c], "visible runtime is prepared during start, the rest wait in catalog order")
		XCTAssertNil(shell.runtime(for: c))

		try await shell.select(c)
		XCTAssertEqual(shell.preparationQueue, [b])
		XCTAssertNotNil(shell.runtime(for: c))
		XCTAssertEqual(shell.visibleWorkspaceID, c)
	}

	func testPrepareRuntimeSkipsDefaultActivationAndSwitchesOnce() async throws {
		let seed = await makeStartedShell()
		let a = try await seed.add(name: "A", folderPath: try makeRoot("a"), makeVisible: false)
		await seed.stop()

		let deferred = WindowState(launch: .shellRuntime)
		await deferred.workspaceManager.awaitInitialized()
		XCTAssertNil(deferred.workspaceManager.activeWorkspace, "a shell runtime never activates Default")
		await deferred.tearDown()
		deferred.beginClose()

		let shell = await makeStartedShell()
		let runtime = try XCTUnwrap(shell.runtime(for: a))
		XCTAssertEqual(runtime.workspaceManager.activeWorkspace?.id, a)
		XCTAssertEqual(runtime.launch, .shellRuntime)
		XCTAssertEqual(shell.hostRuntime?.launch, .shellHost)
		XCTAssertEqual(shell.hostRuntime?.workspaceManager.activeWorkspace?.isSystemWorkspace, true)
	}

	func testAttachNativeWindowAttachesVisibleRuntimeAndDetachesPrevious() async throws {
		let shell = await makeStartedShell()
		let a = try await shell.add(name: "A", folderPath: try makeRoot("a"), makeVisible: true)
		let b = try await shell.add(name: "B", folderPath: try makeRoot("b"), makeVisible: false)
		let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)

		shell.attachNativeWindow(window)
		XCTAssertTrue(shell.runtime(for: a)?.nsWindow === window)
		XCTAssertTrue(WindowStatesManager.shared.visibleWindowState === shell.runtime(for: a))
		XCTAssertTrue(shell.contentRuntime === shell.runtime(for: a))

		try await shell.select(b)
		XCTAssertNil(shell.runtime(for: a)?.nsWindow, "the previous runtime lets go of the window")
		XCTAssertTrue(shell.runtime(for: b)?.nsWindow === window)
		XCTAssertTrue(WindowStatesManager.shared.visibleWindowState === shell.runtime(for: b))
		XCTAssertTrue(shell.contentRuntime === shell.runtime(for: b))
		XCTAssertNotNil(shell.installedWindowDelegateProxy?.willCloseHandler)
		window.delegate = nil
	}

	func testAttachABAKeepsSingleProxyWithNonProxyForwardedDelegate() async throws {
		final class OriginalDelegate: NSObject, NSWindowDelegate {}
		let shell = await makeStartedShell()
		let a = try await shell.add(name: "A", folderPath: try makeRoot("a"), makeVisible: true)
		let b = try await shell.add(name: "B", folderPath: try makeRoot("b"), makeVisible: false)
		let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
		let original = OriginalDelegate()
		window.delegate = original

		shell.attachNativeWindow(window)
		let proxy = try XCTUnwrap(shell.installedWindowDelegateProxy)
		try await shell.select(b)
		try await shell.select(a)
		try await shell.select(b)

		XCTAssertTrue(window.delegate === proxy)
		XCTAssertTrue(shell.installedWindowDelegateProxy === proxy)
		XCTAssertTrue(proxy.forwardedDelegate === original)
		XCTAssertFalse(proxy.forwardedDelegate is InterceptingWindowDelegateProxy)
		XCTAssertTrue(proxy.windowState === shell.runtime(for: b))
		XCTAssertTrue(shell.runtime(for: b)?.nsWindow === window)
		XCTAssertNil(shell.runtime(for: a)?.nsWindow)
		XCTAssertTrue(WindowStatesManager.shared.shellNSWindow === window)
		window.delegate = nil
	}

	func testResolveRuntimeWindowIDMapsShellIDToBoundRuntime() async throws {
		let manager = WindowStatesManager.shared
		let shell = await makeStartedShell()
		let a = try await shell.add(name: "A", folderPath: try makeRoot("a"), makeVisible: true)
		let shellID = try XCTUnwrap(manager.shellWindowID)
		let visibleID = try XCTUnwrap(shell.runtime(for: a)?.windowID)

		let resolvedNil = try await manager.resolveRuntimeWindowID(publicWindowID: nil, connectionID: nil)
		XCTAssertNil(resolvedNil)
		let resolved = try await manager.resolveRuntimeWindowID(publicWindowID: shellID, connectionID: UUID())
		XCTAssertEqual(resolved, visibleID, "an unbound connection lands on the visible runtime")
		do {
			_ = try await manager.resolveRuntimeWindowID(publicWindowID: shellID + 1000, connectionID: nil)
			XCTFail("foreign ids are rejected")
		} catch {
			XCTAssertTrue("\(error)".contains("Valid window ID: \(shellID)"))
		}
	}

	func testMCPToolsFlagFansOutToEveryRuntime() async throws {
		let shell = await makeStartedShell()
		let a = try await shell.add(name: "A", folderPath: try makeRoot("a"), makeVisible: true)
		let b = try await shell.add(name: "B", folderPath: try makeRoot("b"), makeVisible: false)

		shell.isMCPToolsEnabled = true
		XCTAssertEqual(shell.hostRuntime?.mcpServer.windowToolsEnabled, true)
		XCTAssertEqual(shell.runtime(for: a)?.mcpServer.windowToolsEnabled, true)
		XCTAssertEqual(shell.runtime(for: b)?.mcpServer.windowToolsEnabled, true)
		XCTAssertTrue(WindowStatesManager.shared.firstMCPEnabledWindow() === shell.runtime(for: a))
		XCTAssertTrue(shell.makeCloseImpactSnapshot().isLastMCPEnabledWindow)

		shell.isMCPToolsEnabled = false
		XCTAssertEqual(shell.runtime(for: b)?.mcpServer.windowToolsEnabled, false)
		shell.runtime(for: b)?.mcpServer.windowToolsEnabled = true
		XCTAssertTrue(shell.isMCPToolsEnabled, "enabling on one runtime enables the shell")
		XCTAssertEqual(shell.runtime(for: a)?.mcpServer.windowToolsEnabled, true)
	}
}
