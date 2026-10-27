import XCTest
@testable import RepoPrompt

/// The test host shares its settings with the installed debug app, so the catalog root a test
/// process uses must never end up in the `GlobalCustomStorageURL` setting.
@MainActor
final class WorkspaceStoragePathsTests: XCTestCase {
	private var savedSetting: String?
	private var shell: WorkspaceShellViewModel?

	override func setUp() async throws {
		try await super.setUp()
		savedSetting = UserDefaults.standard.string(forKey: "GlobalCustomStorageURL")
		UserDefaults.standard.removeObject(forKey: "GlobalCustomStorageURL")
	}

	override func tearDown() async throws {
		await shell?.stop()
		shell = nil
		if let savedSetting {
			UserDefaults.standard.set(savedSetting, forKey: "GlobalCustomStorageURL")
		} else {
			UserDefaults.standard.removeObject(forKey: "GlobalCustomStorageURL")
		}
		try await super.tearDown()
	}

	func testATestProcessKeepsItsTemporaryCatalogOutOfTheSetting() async throws {
		let shell = WorkspaceShellViewModel()
		self.shell = shell
		await shell.start()

		let indexURL = try XCTUnwrap(shell.hostRuntime).workspaceManager.workspaceIndexFileURL
		XCTAssertNil(UserDefaults.standard.string(forKey: "GlobalCustomStorageURL"))
		XCTAssertTrue(indexURL.path.hasPrefix(FileManager.default.temporaryDirectory.path))
		XCTAssertEqual(WorkspaceStoragePaths.currentRoot, WorkspaceStoragePaths.defaultRoot)
	}
}
