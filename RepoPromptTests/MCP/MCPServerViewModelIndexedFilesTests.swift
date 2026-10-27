import XCTest
import MCP
@testable import RepoPrompt

/// Agent tools answer from the index of each root folder, whichever folders the file tree has opened.
@MainActor
final class MCPServerViewModelIndexedFilesTests: XCTestCase {
	@MainActor
	private struct Fixture {
		let windowState: WindowState
		let rootURL: URL
		let index: RootFolderIndex

		var fileManager: RepoFileManagerViewModel { windowState.fileManager }
		var mcpServer: MCPServerViewModel { windowState.mcpServer }

		func fullPath(_ relativePath: String) -> String {
			StandardizedPath.join(standardizedRoot: index.rootPath, standardizedRelativePath: relativePath)
		}

		/// Drops the tree items of `src/deep`, as when the user never opened that folder.
		func closeDeepFolder() {
			fileManager.removeTreeItemsForTesting(underFolder: rootURL.appendingPathComponent("src/deep").path)
		}
	}

	private func makeFixture() async throws -> Fixture {
		let tempParent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("CodeRoot", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL.appendingPathComponent("src/deep", isDirectory: true), withIntermediateDirectories: true)
		try "final class Top {\n\tfunc run() {}\n}\n".write(to: rootURL.appendingPathComponent("Top.swift"), atomically: true, encoding: .utf8)
		try "final class Middle {\n\tfunc run() {}\n}\n".write(to: rootURL.appendingPathComponent("src/Middle.swift"), atomically: true, encoding: .utf8)
		try "final class Deep {\n\tfunc run() {}\n}\n".write(to: rootURL.appendingPathComponent("src/deep/Deep.swift"), atomically: true, encoding: .utf8)
		try "# Notes\n".write(to: rootURL.appendingPathComponent("src/deep/notes.md"), atomically: true, encoding: .utf8)

		let windowState = WindowState()
		addTeardownBlock {
			await windowState.tearDown()
			try? FileManager.default.removeItem(at: tempParent)
		}
		await windowState.workspaceManager.awaitInitialized()
		let tabID = UUID()
		let workspace = WorkspaceModel(
			name: "Indexed Files Test",
			repoPaths: [rootURL.path],
			customStoragePath: tempParent,
			composeTabs: [ComposeTabState(id: tabID, name: "Test", lastModified: Date())],
			activeComposeTabID: tabID
		)
		windowState.workspaceManager.workspaces = [workspace]
		windowState.workspaceManager.activeWorkspace = workspace
		windowState.promptManager.loadComposeTabsFromWorkspace(workspace)

		let fileManager = windowState.fileManager
		fileManager.beginDeferringInitialRootLoadScans()
		try await fileManager.loadFolder(at: rootURL, for: workspace, freshStart: true)
		let root = try XCTUnwrap(fileManager.rootFolders.first)
		let index = try XCTUnwrap(fileManager.rootFolderIndexes[root.standardizedFullPath])
		return Fixture(windowState: windowState, rootURL: rootURL, index: index)
	}

	private func pathSearchArgs(_ pattern: String) -> [String: Value] {
		[
			"pattern": .string(pattern),
			"mode": .string("path"),
			"regex": .bool(false),
			"max_results": .int(20)
		]
	}

	func testAFileTreeRequestedDuringReadingAnswersAfterReadingWithTheCompleteTree() async throws {
		let fixture = try await makeFixture()
		fixture.closeDeepFolder()
		fixture.fileManager.readingFileCounts.value[fixture.index.rootPath] = fixture.index.filePaths.count

		let request = Task {
			await fixture.mcpServer.buildFileTreeResult(mode: "full", maxDepth: nil, includeHidden: false, startPath: nil, selectedPaths: [])
		}
		try await Task.sleep(nanoseconds: 200_000_000)
		fixture.index.addFile("src/deep/Later.swift")
		fixture.fileManager.readingFileCounts.value.removeValue(forKey: fixture.index.rootPath)

		let tree = await request.value.tree
		for name in ["Top.swift", "Middle.swift", "Deep.swift", "notes.md", "Later.swift"] {
			XCTAssertTrue(tree.contains(name), "\(name) missing from:\n\(tree)")
		}
	}

	func testTheFileTreeIsTheSameInEveryModeWhenAFolderIsNotOpened() async throws {
		let fixture = try await makeFixture()
		let selectedPaths: Set<String> = [fixture.fullPath("Top.swift"), fixture.fullPath("src/deep/Deep.swift")]
		let requests: [(mode: String, maxDepth: Int?, startPath: String?)] = [
			("auto", nil, nil), ("full", nil, nil), ("folders", nil, nil), ("selected", nil, nil),
			("full", 0, nil), ("full", 1, nil), ("full", nil, "src"), ("full", nil, "src/deep")
		]
		func trees() async -> [String] {
			var result: [String] = []
			for request in requests {
				result.append(await fixture.mcpServer.buildFileTreeResult(
					mode: request.mode,
					maxDepth: request.maxDepth,
					includeHidden: false,
					startPath: request.startPath,
					selectedPaths: selectedPaths
				).tree)
			}
			return result
		}
		let treesWithEveryFolderOpened = await trees()

		fixture.closeDeepFolder()

		let result = await trees()
		XCTAssertEqual(result, treesWithEveryFolderOpened)
		XCTAssertTrue(result[1].contains("Deep.swift *"), result[1])
		XCTAssertTrue(result[7].contains("notes.md"), result[7])
	}

	func testFileSearchDuringReadingAnswersFromTheCompleteIndex() async throws {
		let fixture = try await makeFixture()
		let matchesWithEveryFolderOpened = try await fixture.mcpServer.executeFileSearchTool(args: pathSearchArgs("Deep")).pathMatchLines
		fixture.closeDeepFolder()
		fixture.fileManager.readingFileCounts.value[fixture.index.rootPath] = fixture.index.filePaths.count

		let request = Task { try await fixture.mcpServer.executeFileSearchTool(args: self.pathSearchArgs("Deep")) }
		try await Task.sleep(nanoseconds: 200_000_000)
		fixture.index.addFile("src/deep/DeepLater.swift")
		fixture.fileManager.readingFileCounts.value.removeValue(forKey: fixture.index.rootPath)

		let reply = try await request.value
		XCTAssertEqual(
			Set(reply.pathMatchLines),
			Set(matchesWithEveryFolderOpened + [fixture.fileManager.mcpDisplayPath(forAbsolutePath: fixture.fullPath("src/deep/DeepLater.swift"))])
		)
		XCTAssertTrue(reply.pathMatchLines.contains(fixture.fileManager.mcpDisplayPath(forAbsolutePath: fixture.fullPath("src/deep/Deep.swift"))), "\(reply.pathMatchLines)")
	}

	func testReadingAFileByPathWorksInAFolderThatIsNotOpened() async throws {
		let fixture = try await makeFixture()
		fixture.closeDeepFolder()

		let reply = try await fixture.mcpServer.readFile(path: "src/deep/Deep.swift").reply

		XCTAssertEqual(reply.content, "final class Deep {\n\tfunc run() {}\n}\n")
	}

	func testSelectingAFolderThatWasNeverOpenedSelectsEveryFileUnderIt() async throws {
		let fixture = try await makeFixture()
		fixture.closeDeepFolder()

		let result = await fixture.mcpServer.addStoredSelectionPaths(
			existing: StoredSelection(),
			paths: ["src/deep"],
			rawPaths: ["src/deep"],
			mode: "full"
		)

		XCTAssertEqual(
			Set(result.selection.selectedPaths),
			[fixture.fullPath("src/deep/Deep.swift"), fixture.fullPath("src/deep/notes.md")]
		)
	}

	func testWorkspaceContextIsTheSameWhenASelectedFileIsInAFolderThatIsNotOpened() async throws {
		let fixture = try await makeFixture()
		let context = MCPServerViewModel.TabScopedContext(
			tabID: UUID(),
			windowID: fixture.windowState.windowID,
			workspaceID: nil,
			promptText: "",
			selection: StoredSelection(
				selectedPaths: [fixture.fullPath("Top.swift"), fixture.fullPath("src/deep/Deep.swift")],
				autoCodemapPaths: [],
				slices: [:],
				codemapAutoEnabled: false
			),
			selectedMetaPromptIDs: [],
			tabName: "Test Tab",
			runID: nil,
			explicitlyBound: false
		)
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
		func workspaceContext() async throws -> String {
			let dto = await fixture.mcpServer.buildTabWorkspaceContext(
				context: context,
				include: ["selection", "tokens", "tree"],
				display: .relative
			)
			return String(decoding: try encoder.encode(dto), as: UTF8.self)
		}
		let withEveryFolderOpened = try await workspaceContext()

		fixture.closeDeepFolder()

		let result = try await workspaceContext()
		XCTAssertEqual(result, withEveryFolderOpened)
		XCTAssertTrue(result.contains("Deep.swift"), result)
	}

	func testAFileAnAgentCreatesInAFolderThatIsNotOpenedIsFoundByTheNextSearch() async throws {
		let fixture = try await makeFixture()
		fixture.closeDeepFolder()

		try await fixture.fileManager.createFile(atRelativePath: "src/deep/Created.swift", content: "struct Created {}\n", selectAfterCreate: false)
		let reply = try await fixture.mcpServer.executeFileSearchTool(args: pathSearchArgs("Created"))

		XCTAssertEqual(
			reply.pathMatchLines,
			[fixture.fileManager.mcpDisplayPath(forAbsolutePath: fixture.fullPath("src/deep/Created.swift"))]
		)
	}
}
