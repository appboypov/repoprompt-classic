import XCTest
@testable import RepoPrompt

@MainActor
final class WorkspaceCatalogServiceTests: XCTestCase {
	private var storageRoot: URL!
	private var shell: WorkspaceShellViewModel?

	override func setUp() async throws {
		try await super.setUp()
		storageRoot = FileManager.default.temporaryDirectory
			.appendingPathComponent("WorkspaceCatalogServiceTests-\(UUID().uuidString)", isDirectory: true)
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

	private func makeShell(workspaces names: [String]) async throws -> (WorkspaceShellViewModel, [UUID]) {
		let shell = WorkspaceShellViewModel()
		self.shell = shell
		await shell.start()
		var ids: [UUID] = []
		for name in names {
			let root = storageRoot.appendingPathComponent(name, isDirectory: true)
			try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
			ids.append(try await shell.add(name: name, folderPath: root.path, makeVisible: false))
		}
		return (shell, ids)
	}

	private func indexOrder(_ shell: WorkspaceShellViewModel) throws -> [UUID] {
		let url = try XCTUnwrap(shell.hostRuntime).workspaceManager.workspaceIndexFileURL
		return WorkspaceManagerViewModel.loadWorkspaceIndex(from: url).filter { !$0.isSystemWorkspace }.map(\.id)
	}

	func testReorderRejectsMissingDuplicateAndUnknownIDs() async throws {
		let (shell, ids) = try await makeShell(workspaces: ["A", "B", "C"])

		for bad in [Array(ids.dropLast()), [ids[0], ids[0], ids[1]], [ids[0], ids[1], UUID()]] {
			do {
				try await shell.reorder(ids: bad)
				XCTFail("\(bad) must be rejected")
			} catch let error as WorkspaceShellError {
				guard case .invalidOrder = error else { return XCTFail("unexpected \(error)") }
			}
		}
		XCTAssertEqual(try indexOrder(shell), ids, "rejected reorders leave the index untouched")
	}

	func testRenameRejectsEmptyAndDuplicateNames() async throws {
		let (shell, ids) = try await makeShell(workspaces: ["A", "B"])

		do {
			try await shell.rename(id: ids[0], name: "   ")
			XCTFail("empty name must be rejected")
		} catch let error as WorkspaceShellError {
			XCTAssertEqual(error, .emptyName)
		}
		do {
			try await shell.rename(id: ids[0], name: "b")
			XCTFail("duplicate name must be rejected")
		} catch let error as WorkspaceShellError {
			XCTAssertEqual(error, .duplicateName("b"))
		}
		XCTAssertEqual(shell.snapshot.workspaces.map(\.name), ["A", "B"])

		try await shell.rename(id: ids[0], name: " A2 ")
		XCTAssertEqual(shell.snapshot.workspaces.map(\.name), ["A2", "B"])
		XCTAssertEqual(shell.runtime(for: ids[1])?.workspaceManager.workspaces.first { $0.id == ids[0] }?.name, "A2", "other runtimes reload the rename")
	}

	func testReorderWritesIndexArrayOrder() async throws {
		let (shell, ids) = try await makeShell(workspaces: ["A", "B", "C"])
		let reordered = [ids[2], ids[0], ids[1]]

		try await shell.reorder(ids: reordered)

		XCTAssertEqual(try indexOrder(shell), reordered)
		XCTAssertEqual(shell.snapshot.workspaces.map(\.id), reordered)
		XCTAssertEqual(shell.runtime(for: ids[0])?.workspaceManager.workspaces.filter { !$0.isSystemWorkspace }.map(\.id), reordered)
	}

	func testMutationPreservesUnsavedDraftInOtherRuntime() async throws {
		let (shell, ids) = try await makeShell(workspaces: ["A", "B"])
		let other = try XCTUnwrap(shell.runtime(for: ids[1]))
		let tab = await other.promptManager.ensureActiveComposeTab(nil, name: "Draft")
		XCTAssertNotNil(tab)
		// The tab switch applies its stored state on a later turn; the draft is typed after that.
		try await Task.sleep(nanoseconds: 500_000_000)
		other.promptManager.promptText = "draft kept across a catalog write"
		try await Task.sleep(nanoseconds: 300_000_000)

		try await shell.rename(id: ids[0], name: "Renamed")

		XCTAssertEqual(other.promptManager.promptText, "draft kept across a catalog write")
		XCTAssertEqual(other.workspaceManager.activeWorkspace?.id, ids[1])
	}
}
