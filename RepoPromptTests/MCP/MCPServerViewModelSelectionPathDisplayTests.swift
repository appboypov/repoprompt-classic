import XCTest
import MCP
@testable import RepoPrompt

@MainActor
final class MCPServerViewModelSelectionPathDisplayTests: XCTestCase {
	func testManageSelectionReplyHonorsFullPathDisplayForFilesAndSlices() async throws {
		let fixture = try await makeWindowFixture()
		defer { try? FileManager.default.removeItem(at: fixture.tempRoot.deletingLastPathComponent()) }
		addTeardownBlock {
			await fixture.windowState.tearDown()
		}

		let reply = await fixture.windowState.mcpServer.buildTabSelectionReply(
			from: makeStoredSelection(for: fixture.file),
			includeBlocks: false,
			display: .full,
			codeMapUsageOverride: .auto
		)

		let fileInfo = try XCTUnwrap(reply.files?.first)
		XCTAssertEqual(fileInfo.path, fixture.file.fullPath)
		XCTAssertEqual(fileInfo.rootPath, fixture.file.standardizedRootFolderPath)
		XCTAssertEqual(fileInfo.pathWithinRoot, fixture.file.standardizedRelativePath)
		let sliceInfo = try XCTUnwrap(reply.fileSlices?.first)
		XCTAssertEqual(sliceInfo.path, fixture.file.fullPath)
		XCTAssertEqual(sliceInfo.rootPath, fixture.file.standardizedRootFolderPath)
		XCTAssertEqual(sliceInfo.pathWithinRoot, fixture.file.standardizedRelativePath)
	}

	func testManageSelectionReplyDefaultsToRelativePathDisplay() async throws {
		let fixture = try await makeWindowFixture()
		defer { try? FileManager.default.removeItem(at: fixture.tempRoot.deletingLastPathComponent()) }
		addTeardownBlock {
			await fixture.windowState.tearDown()
		}

		let reply = await fixture.windowState.mcpServer.buildTabSelectionReply(
			from: makeStoredSelection(for: fixture.file),
			includeBlocks: false,
			display: .relative,
			codeMapUsageOverride: .auto
		)

		let expectedDisplayPath = fixture.windowState.fileManager.mcpDisplayPath(for: fixture.file)
		let fileInfo = try XCTUnwrap(reply.files?.first)
		XCTAssertEqual(fileInfo.path, expectedDisplayPath)
		XCTAssertEqual(fileInfo.rootPath, fixture.file.standardizedRootFolderPath)
		XCTAssertEqual(fileInfo.pathWithinRoot, fixture.file.standardizedRelativePath)

		let sliceInfo = try XCTUnwrap(reply.fileSlices?.first)
		XCTAssertEqual(sliceInfo.path, expectedDisplayPath)
		XCTAssertEqual(sliceInfo.rootPath, fixture.file.standardizedRootFolderPath)
		XCTAssertEqual(sliceInfo.pathWithinRoot, fixture.file.standardizedRelativePath)
	}

	func testFileSearchDisplayPathCacheKeepsSameRelativePathsDistinctAcrossRoots() async throws {
		let windowState = WindowState()
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tempParent, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }
		addTeardownBlock {
			await windowState.tearDown()
		}

		let rootAURL = tempParent.appendingPathComponent("RootA", isDirectory: true)
		let rootBURL = tempParent.appendingPathComponent("RootB", isDirectory: true)
		try FileManager.default.createDirectory(at: rootAURL, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: rootBURL, withIntermediateDirectories: true)

		await windowState.workspaceManager.awaitInitialized()
		let tabID = UUID()
		let workspace = WorkspaceModel(
			name: "File Search Cache Test",
			repoPaths: [rootAURL.path, rootBURL.path],
			customStoragePath: tempParent,
			composeTabs: [
				ComposeTabState(id: tabID, name: "Test", lastModified: Date())
			],
			activeComposeTabID: tabID
		)
		windowState.workspaceManager.workspaces = [workspace]
		windowState.workspaceManager.activeWorkspace = workspace
		windowState.promptManager.loadComposeTabsFromWorkspace(workspace)

		func registerRoot(at rootURL: URL) async throws -> FileViewModel {
			let fileURL = rootURL.appendingPathComponent("App.swift")
			try "struct \(rootURL.lastPathComponent) {}".write(to: fileURL, atomically: true, encoding: .utf8)

			let service = try await FileSystemService(
				path: rootURL.path,
				respectGitignore: false,
				skipSymlinks: true,
				isTestMode: true
			)
			let rootFolder = FolderViewModel(
				folder: Folder(name: rootURL.lastPathComponent, path: rootURL.path, modificationDate: Date()),
				rootPath: rootURL.path,
				isExpanded: true
			)
			let file = FileViewModel(
				file: File(name: fileURL.lastPathComponent, path: fileURL.path, modificationDate: Date()),
				rootPath: rootURL.path,
				hierarchyLevel: 0,
				rootIdentifier: rootFolder.id,
				rootFolderPath: rootURL.path,
				fileSystemService: service,
				parentFolder: rootFolder
			)
			rootFolder.addFile(file)
			windowState.fileManager.registerRootFolderForTesting(rootFolder, service: service)
			return file
		}

		let fileA = try await registerRoot(at: rootAURL)
		let fileB = try await registerRoot(at: rootBURL)

		let expected = [
			windowState.fileManager.mcpDisplayPath(forAbsolutePath: fileA.standardizedFullPath),
			windowState.fileManager.mcpDisplayPath(forAbsolutePath: fileB.standardizedFullPath)
		]

		let args: [String: Value] = [
			"pattern": .string("*.swift"),
			"mode": .string("path"),
			"regex": .bool(false),
			"max_results": .int(10)
		]
		let reply = try await windowState.mcpServer.executeFileSearchTool(args: args)
		XCTAssertEqual(reply.pathMatches, 2)
		XCTAssertEqual(reply.totalMatches, 2)
		XCTAssertEqual(reply.pathMatchLines.sorted(), expected.sorted())

		var countArgs = args
		countArgs["count_only"] = .bool(true)
		let countReply = try await windowState.mcpServer.executeFileSearchTool(args: countArgs)
		XCTAssertEqual(countReply.pathMatches, 2)
		XCTAssertEqual(countReply.totalMatches, 2)
		XCTAssertEqual(countReply.matchedFiles, 2)
		XCTAssertEqual(countReply.pathMatchLines.sorted(), expected.sorted())
	}

	private func makeStoredSelection(for file: FileViewModel) -> StoredSelection {
		StoredSelection(
			selectedPaths: [file.standardizedFullPath],
			autoCodemapPaths: [],
			slices: [file.standardizedFullPath: [LineRange(start: 1, end: 2)]],
			codemapAutoEnabled: false
		)
	}

	private struct WindowFixture {
		let windowState: WindowState
		let tempRoot: URL
		let file: FileViewModel
	}

	private func makeWindowFixture() async throws -> WindowFixture {
		let windowState = WindowState()
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("WorkspaceRoot", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		let fileURL = rootURL.appendingPathComponent("App.swift")
		try "line 1\nline 2\nline 3\n".write(to: fileURL, atomically: true, encoding: .utf8)

		let service = try await FileSystemService(
			path: rootURL.path,
			respectGitignore: false,
			skipSymlinks: true,
			isTestMode: true
		)
		let rootFolder = FolderViewModel(
			folder: Folder(name: rootURL.lastPathComponent, path: rootURL.path, modificationDate: Date()),
			rootPath: rootURL.path,
			isExpanded: true
		)
		let file = FileViewModel(
			file: File(name: fileURL.lastPathComponent, path: fileURL.path, modificationDate: Date()),
			rootPath: rootURL.path,
			hierarchyLevel: 0,
			rootIdentifier: rootFolder.id,
			rootFolderPath: rootURL.path,
			fileSystemService: service,
			parentFolder: rootFolder
		)
		rootFolder.addFile(file)
		windowState.fileManager.registerRootFolderForTesting(rootFolder, service: service)

		return WindowFixture(windowState: windowState, tempRoot: rootURL, file: file)
	}
}
