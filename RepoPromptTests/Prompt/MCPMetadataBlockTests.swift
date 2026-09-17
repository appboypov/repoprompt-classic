import XCTest
@testable import RepoPrompt

/// Runs a real shell on a temporary workspace root (`GlobalCustomStorageURL`).
@MainActor
final class MCPMetadataBlockTests: XCTestCase {
	private var storageRoot: URL!
	private var viewModel: WorkspaceShellViewModel?

	override func setUp() async throws {
		try await super.setUp()
		storageRoot = FileManager.default.temporaryDirectory
			.appendingPathComponent("MCPMetadataBlockTests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
		UserDefaults.standard.set(storageRoot.path, forKey: "GlobalCustomStorageURL")
	}

	override func tearDown() async throws {
		await viewModel?.stop()
		viewModel = nil
		UserDefaults.standard.removeObject(forKey: "GlobalCustomStorageURL")
		try? FileManager.default.removeItem(at: storageRoot)
		try await super.tearDown()
	}

	func testMetadataBlockEmitsShellWindowIDAndWorkspaceName() async throws {
		let shell = WorkspaceShellViewModel(preparesRemainingInBackground: false)
		viewModel = shell
		await shell.start()
		let root = storageRoot.appendingPathComponent("b", isDirectory: true)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		let b = try await shell.add(name: "Background B", folderPath: root.path, makeVisible: false)
		let runtime = try XCTUnwrap(shell.runtime(for: b))
		let shellWindowID = try XCTUnwrap(WindowStatesManager.shared.shellWindowID)

		let block = try XCTUnwrap(runtime.promptManager.generateMCPMetadataBlock())

		XCTAssertTrue(block.contains("window_id: \(shellWindowID)"), "the public shell ID, never the runtime's: \(block)")
		XCTAssertFalse(block.contains("window_id: \(runtime.windowID)\n"), "runtime IDs stay internal: \(block)")
		XCTAssertTrue(block.contains("workspace_name: Background B"), block)
	}
}
