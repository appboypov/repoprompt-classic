//
//  RepoFileManagerTests.swift
//  RepoPromptTests
//

import XCTest
import Combine
import CryptoKit
@testable import RepoPrompt

final class RepoFileManagerTests: XCTestCase {
	private func makeTemporaryHomeDirectory() throws -> URL {
		let homeURL = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
		return homeURL
	}

	@MainActor
	private func makeWorkspaceRoot(fileNames: [String] = ["A.swift"]) async throws -> (RepoFileManagerViewModel, URL, WorkspaceModel) {
		let rootURL = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

		let sourcesURL = rootURL.appendingPathComponent("Sources", isDirectory: true)
		try FileManager.default.createDirectory(at: sourcesURL, withIntermediateDirectories: true)

		for fileName in fileNames {
			let fileURL = sourcesURL.appendingPathComponent(fileName)
			let typeName = fileName.replacingOccurrences(of: ".swift", with: "")
			try "struct \(typeName) {}".write(to: fileURL, atomically: true, encoding: .utf8)
		}

		let workspace = WorkspaceModel(name: "Test", repoPaths: [rootURL.path])
		let fileManagerVM = RepoFileManagerViewModel()
		try await fileManagerVM.loadFolder(at: rootURL, for: workspace, freshStart: true)
		return (fileManagerVM, rootURL, workspace)
	}

	@MainActor
	private func registerUnwatchedRoot(
		named rootName: String,
		under tempParent: URL,
		in fileManagerVM: RepoFileManagerViewModel
	) async throws -> (URL, FolderViewModel) {
		let rootURL = tempParent.appendingPathComponent(rootName, isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		let service = try await FileSystemService(path: rootURL.path)
		let rootFolder = FolderViewModel(
			folder: Folder(name: rootName, path: rootURL.path, modificationDate: Date()),
			rootPath: rootURL.path,
			isExpanded: true,
			sortMethod: .nameAscending
		)
		fileManagerVM.registerRootFolderForTesting(rootFolder, service: service)
		return (rootURL, rootFolder)
	}

	@MainActor
	private func makeWorkspaceWithGitData(
		userFiles: [String: String] = ["Sources/A.swift": "struct A {}"],
		gitDataFiles: [String: String] = ["MAP.txt": "artifact-only-token"]
	) async throws -> (RepoFileManagerViewModel, URL, URL, WorkspaceModel) {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("WorkspaceRoot", isDirectory: true)
		let gitDataURL = tempParent.appendingPathComponent("_git_data", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: gitDataURL, withIntermediateDirectories: true)

		for (relativePath, content) in userFiles {
			let fileURL = rootURL.appendingPathComponent(relativePath)
			try FileManager.default.createDirectory(
				at: fileURL.deletingLastPathComponent(),
				withIntermediateDirectories: true
			)
			try content.write(to: fileURL, atomically: true, encoding: .utf8)
		}

		for (relativePath, content) in gitDataFiles {
			let fileURL = gitDataURL.appendingPathComponent(relativePath)
			try FileManager.default.createDirectory(
				at: fileURL.deletingLastPathComponent(),
				withIntermediateDirectories: true
			)
			try content.write(to: fileURL, atomically: true, encoding: .utf8)
		}

		let workspace = WorkspaceModel(name: "Test", repoPaths: [rootURL.path])
		let fileManagerVM = RepoFileManagerViewModel()
		try await fileManagerVM.loadFolder(at: rootURL, for: workspace, freshStart: true)
		try await fileManagerVM.loadSupplementalRoot(at: gitDataURL, for: workspace)
		return (fileManagerVM, tempParent, gitDataURL, workspace)
	}

	private func makeMinimalFileAPI(filePath: String) -> FileAPI {
		FileAPI(
			filePath: filePath,
			imports: [],
			classes: [],
			functions: [],
			enums: [],
			globalVars: [],
			macros: [],
			referencedTypes: []
		)
	}
	
	private func renderedMessage(for error: Error) -> String {
		if let localized = error as? LocalizedError,
		   let description = localized.errorDescription {
			return description
		}
		return error.localizedDescription
	}

	private func setDiskModificationDate(_ date: Date, for fileURL: URL) throws {
		try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: fileURL.path)
	}
	
	private enum TestWorkspaceFileEditHostError: Error {
		case missingFile
	}
	
	@MainActor
	private func makeWorkspaceFileEditHost(fileManagerVM: RepoFileManagerViewModel) -> WorkspaceFileEditHost {
		WorkspaceFileEditHost(
			fileManager: fileManagerVM,
			resolveFile: { path in
				guard let fileVM = await fileManagerVM.resolveExistingFileForToolEdit(atPath: path) else {
					throw TestWorkspaceFileEditHostError.missingFile
				}
				return fileVM
			},
			fileExistsResolver: { path in
				await fileManagerVM.fileExistsStrictly(atPath: path)
			}
		)
	}

	@MainActor
	private func makeRootFolderForOrderingTest(
		named name: String,
		under parentURL: URL,
		isSystemRoot: Bool = false
	) throws -> (URL, FolderViewModel) {
		let rootURL = parentURL.appendingPathComponent(name, isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		let folder = FolderViewModel(
			folder: Folder(name: name, path: rootURL.path, modificationDate: Date()),
			rootPath: rootURL.path,
			isExpanded: true,
			isSystemRoot: isSystemRoot
		)
		return (rootURL, folder)
	}

	@MainActor
	func testReorderRootFoldersNoOpsWhenFinalOrderIsUnchanged() throws {
		let parentURL = try makeTemporaryHomeDirectory()
		defer { try? FileManager.default.removeItem(at: parentURL) }

		let (rootAURL, rootA) = try makeRootFolderForOrderingTest(named: "RootA", under: parentURL)
		let (rootBURL, rootB) = try makeRootFolderForOrderingTest(named: "RootB", under: parentURL)
		let (_, gitDataRoot) = try makeRootFolderForOrderingTest(named: "_git_data", under: parentURL, isSystemRoot: true)
		let fileManagerVM = RepoFileManagerViewModel()
		fileManagerVM.registerRootFolderForTesting(rootA)
		fileManagerVM.registerRootFolderForTesting(rootB)
		fileManagerVM.registerRootFolderForTesting(gitDataRoot)

		let initialRootIDs = fileManagerVM.rootFolders.map(\.id)
		var changedCount = 0
		fileManagerVM.onRootFoldersChanged = {
			changedCount += 1
		}

		fileManagerVM.reorderRootFolders(to: [rootAURL.path, rootBURL.path])

		XCTAssertEqual(fileManagerVM.rootFolders.map(\.id), initialRootIDs)
		XCTAssertEqual(changedCount, 0)
	}

	@MainActor
	func testRequestMoveRootFolderIgnoresSystemRootsAndEmitsUserPathsOnly() throws {
		let parentURL = try makeTemporaryHomeDirectory()
		defer { try? FileManager.default.removeItem(at: parentURL) }

		let (rootAURL, rootA) = try makeRootFolderForOrderingTest(named: "RootA", under: parentURL)
		let (gitDataURL, gitDataRoot) = try makeRootFolderForOrderingTest(named: "_git_data", under: parentURL, isSystemRoot: true)
		let (rootBURL, rootB) = try makeRootFolderForOrderingTest(named: "RootB", under: parentURL)
		let fileManagerVM = RepoFileManagerViewModel()
		fileManagerVM.registerRootFolderForTesting(rootA)
		fileManagerVM.registerRootFolderForTesting(gitDataRoot)
		fileManagerVM.registerRootFolderForTesting(rootB)

		var reorderedPayloads: [[String]] = []
		let cancellable = fileManagerVM.onRootFoldersReordered.sink { paths in
			reorderedPayloads.append(paths)
		}
		defer { cancellable.cancel() }

		let initialRootIDs = fileManagerVM.rootFolders.map(\.id)
		fileManagerVM.requestMoveRootFolderUp(path: gitDataURL.path)
		XCTAssertEqual(fileManagerVM.rootFolders.map(\.id), initialRootIDs)
		XCTAssertTrue(reorderedPayloads.isEmpty)

		fileManagerVM.requestMoveRootFolderUp(path: rootBURL.path)

		XCTAssertEqual(fileManagerVM.rootFolders.map(\.fullPath), [rootBURL.path, rootAURL.path, gitDataURL.path])
		XCTAssertEqual(reorderedPayloads, [[rootBURL.path, rootAURL.path]])
	}

	@MainActor
	func testRefreshContentsSoftPreservesRootVMsWhenOrderIsUnchanged() async throws {
		let parentURL = try makeTemporaryHomeDirectory()
		defer { try? FileManager.default.removeItem(at: parentURL) }

		let fileManagerVM = RepoFileManagerViewModel()
		let (rootAURL, _) = try await registerUnwatchedRoot(named: "RootA", under: parentURL, in: fileManagerVM)
		let (rootBURL, _) = try await registerUnwatchedRoot(named: "RootB", under: parentURL, in: fileManagerVM)
		let workspace = WorkspaceModel(name: "Test", repoPaths: [rootAURL.path, rootBURL.path])
		let initialRootIDs = fileManagerVM.rootFolders.map(\.id)
		let initialRootPaths = fileManagerVM.rootFolders.map(\.fullPath)
		var changedCount = 0
		var rootFolderPublications = 0
		fileManagerVM.onRootFoldersChanged = {
			changedCount += 1
		}
		let cancellable = fileManagerVM.$rootFolders.dropFirst().sink { _ in
			rootFolderPublications += 1
		}
		defer { cancellable.cancel() }

		let didChangeRoots = await fileManagerVM.refreshContents(model: workspace, forceRefresh: false)

		XCTAssertFalse(didChangeRoots)
		XCTAssertEqual(fileManagerVM.rootFolders.map(\.id), initialRootIDs)
		XCTAssertEqual(fileManagerVM.rootFolders.map(\.fullPath), initialRootPaths)
		XCTAssertEqual(changedCount, 0)
		XCTAssertEqual(rootFolderPublications, 0)
	}

	@MainActor
	func testRefreshContentsSoftReordersWithoutRecreatingRootVMsWhenOrderDiffers() async throws {
		let parentURL = try makeTemporaryHomeDirectory()
		defer { try? FileManager.default.removeItem(at: parentURL) }

		let fileManagerVM = RepoFileManagerViewModel()
		let (rootBURL, rootB) = try await registerUnwatchedRoot(named: "RootB", under: parentURL, in: fileManagerVM)
		let (rootAURL, rootA) = try await registerUnwatchedRoot(named: "RootA", under: parentURL, in: fileManagerVM)
		let workspace = WorkspaceModel(name: "Test", repoPaths: [rootAURL.path, rootBURL.path])
		var changedCount = 0
		var rootFolderPublications = 0
		fileManagerVM.onRootFoldersChanged = {
			changedCount += 1
		}
		let cancellable = fileManagerVM.$rootFolders.dropFirst().sink { _ in
			rootFolderPublications += 1
		}
		defer { cancellable.cancel() }

		let didChangeRoots = await fileManagerVM.refreshContents(model: workspace, forceRefresh: false)

		XCTAssertTrue(didChangeRoots)
		XCTAssertEqual(fileManagerVM.rootFolders.map(\.id), [rootA.id, rootB.id])
		XCTAssertEqual(fileManagerVM.rootFolders.map(\.fullPath), [rootAURL.path, rootBURL.path])
		XCTAssertEqual(changedCount, 1)
		XCTAssertEqual(rootFolderPublications, 1)
	}

	@MainActor
	func testSetCodeScanEnabledFalseAlwaysCancelsAndClearsScanProgress() async {
		let fileManagerVM = RepoFileManagerViewModel()
		fileManagerVM.initCodeScanState(false)
		fileManagerVM.remainingScanCount = 4
		fileManagerVM.totalFilesSeen = 9

		await fileManagerVM.setCodeScanEnabled(false)

		XCTAssertEqual(fileManagerVM.remainingScanCount, 0)
		XCTAssertEqual(fileManagerVM.totalFilesSeen, 0)
	}

	@MainActor
	func testApplyCodemapOnlySelectionFromFolderPath() async throws {
		let (fileManagerVM, rootURL, _) = try await makeWorkspaceRoot()
		defer { try? FileManager.default.removeItem(at: rootURL) }
		await fileManagerVM.applyCodemapOnlySelection(paths: ["Sources"])

		XCTAssertFalse(fileManagerVM.codemapAutoEnabled)
		let file = fileManagerVM.findFileByRelativePath("Sources/A.swift")
		XCTAssertNotNil(file)
		if let file {
			XCTAssertTrue(fileManagerVM.isAutoCodemapFile(file))
		}
	}

	@MainActor
	func testResolveFilesForFolderInputReturnsRootAlias() async throws {
		let (fileManagerVM, rootURL, _) = try await makeWorkspaceRoot()
		defer { try? FileManager.default.removeItem(at: rootURL) }
		let rootName = rootURL.lastPathComponent

		let result = await fileManagerVM.resolveFilesForFolderInput(rootName)

		XCTAssertTrue(result.handled)
		XCTAssertEqual(result.files.count, 1)
		XCTAssertEqual(result.displayPath, rootName)
	}

	@MainActor
	func testResolveFilesForFolderInputRejectsAmbiguousRelativeFolderPath() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootA = tempParent.appendingPathComponent("RootA", isDirectory: true)
		let rootB = tempParent.appendingPathComponent("RootB", isDirectory: true)
		try FileManager.default.createDirectory(at: rootA.appendingPathComponent("Sources", isDirectory: true), withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: rootB.appendingPathComponent("Sources", isDirectory: true), withIntermediateDirectories: true)
		try "struct A {}".write(to: rootA.appendingPathComponent("Sources/A.swift"), atomically: true, encoding: .utf8)
		try "struct B {}".write(to: rootB.appendingPathComponent("Sources/B.swift"), atomically: true, encoding: .utf8)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let workspace = WorkspaceModel(name: "Test", repoPaths: [rootA.path, rootB.path])
		let fileManagerVM = RepoFileManagerViewModel()
		try await fileManagerVM.loadFolder(at: rootA, for: workspace, freshStart: true)
		try await fileManagerVM.loadFolder(at: rootB, for: workspace, freshStart: false)

		let result = await fileManagerVM.resolveFilesForFolderInput("Sources")
		XCTAssertFalse(result.handled)
		guard case .ambiguousRootMatch(let input, let roots)? = result.issue else {
			return XCTFail("Expected ambiguousRootMatch, got \(String(describing: result.issue))")
		}
		XCTAssertEqual(input, "Sources")
		XCTAssertEqual(roots.count, 2)
	}

	@MainActor
	func testUnresolvedWorkspaceDisplayPathReturnsAliasPrefixedMissingFilePath() async throws {
		let (fileManagerVM, rootURL, _) = try await makeWorkspaceRoot()
		defer { try? FileManager.default.removeItem(at: rootURL) }
		let rootName = rootURL.lastPathComponent

		let displayPath = fileManagerVM.unresolvedWorkspaceDisplayPath(for: "\(rootName)/Sources/Missing.swift")
		XCTAssertEqual(displayPath, "Sources/Missing.swift")
	}
	
	@MainActor
	func testFileExistsStrictlyAcceptsAliasPrefixedPathWhenSameNameSubfolderExists() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("BombSquad", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL.appendingPathComponent("BombSquad", isDirectory: true), withIntermediateDirectories: true)
		let targetFolder = rootURL.appendingPathComponent("_mcp_test/shared", isDirectory: true)
		try FileManager.default.createDirectory(at: targetFolder, withIntermediateDirectories: true)
		try "hello".write(to: targetFolder.appendingPathComponent("test_file.txt"), atomically: true, encoding: .utf8)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let workspace = WorkspaceModel(name: "Test", repoPaths: [rootURL.path])
		let fileManagerVM = RepoFileManagerViewModel()
		try await fileManagerVM.loadFolder(at: rootURL, for: workspace, freshStart: true)

		let exists = await fileManagerVM.fileExistsStrictly(atPath: "BombSquad/_mcp_test/shared/test_file.txt")
		XCTAssertTrue(exists)
	}

	@MainActor
	func testExactPathResolutionIssueFlagsAmbiguousRelativeFilePath() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootA = tempParent.appendingPathComponent("RootA", isDirectory: true)
		let rootB = tempParent.appendingPathComponent("RootB", isDirectory: true)
		try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
		try "a".write(to: rootA.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
		try "b".write(to: rootB.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let workspace = WorkspaceModel(name: "Test", repoPaths: [rootA.path, rootB.path])
		let fileManagerVM = RepoFileManagerViewModel()
		try await fileManagerVM.loadFolder(at: rootA, for: workspace, freshStart: true)
		try await fileManagerVM.loadFolder(at: rootB, for: workspace, freshStart: false)

		guard case .ambiguousRootMatch(let input, let roots)? = fileManagerVM.exactPathResolutionIssue(for: "README.md", kind: .file) else {
			return XCTFail("Expected ambiguousRootMatch")
		}
		XCTAssertEqual(input, "README.md")
		XCTAssertEqual(roots.count, 2)
	}

	@MainActor
	func testExactPathResolutionIssueAmbiguousRelativePathPerformance() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootA = tempParent.appendingPathComponent("RootA", isDirectory: true)
		let rootB = tempParent.appendingPathComponent("RootB", isDirectory: true)
		try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
		try "a".write(to: rootA.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
		try "b".write(to: rootB.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let workspace = WorkspaceModel(name: "Test", repoPaths: [rootA.path, rootB.path])
		let fileManagerVM = RepoFileManagerViewModel()
		try await fileManagerVM.loadFolder(at: rootA, for: workspace, freshStart: true)
		try await fileManagerVM.loadFolder(at: rootB, for: workspace, freshStart: false)
		let iterationsPerMeasurement = 1_000
		var mismatchCount = 0

		measure(metrics: [XCTClockMetric()]) {
			for _ in 0..<iterationsPerMeasurement {
				guard case .ambiguousRootMatch(_, let roots)? = fileManagerVM.exactPathResolutionIssue(for: "README.md", kind: .file), roots.count == 2 else {
					mismatchCount += 1
					continue
				}
			}
		}

		XCTAssertEqual(mismatchCount, 0)
	}

	@MainActor
	func testExactPathResolutionIssueRejectsEmbeddedNULInRelativeFilePath() async throws {
		let (fileManagerVM, rootURL, _) = try await makeWorkspaceRoot()
		defer { try? FileManager.default.removeItem(at: rootURL) }
		let requestedPath = "abc\u{0}def"

		let issue = fileManagerVM.exactPathResolutionIssue(for: requestedPath, kind: .file)

		guard case .invalidPathCharacters(let input, let reason)? = issue else {
			return XCTFail("Expected invalidPathCharacters, got \(String(describing: issue))")
		}
		XCTAssertEqual(input, requestedPath)
		XCTAssertTrue(reason.contains("NUL"))
		XCTAssertTrue(PathResolutionIssueRenderer.message(for: issue!).contains("abc\\0def"))
	}

	@MainActor
	func testExactPathResolutionIssueRejectsEmbeddedNULInAliasPrefixedFilePathBeforeAliasResolution() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootA = tempParent.appendingPathComponent("RootA", isDirectory: true)
		try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let workspace = WorkspaceModel(name: "Test", repoPaths: [rootA.path])
		let fileManagerVM = RepoFileManagerViewModel()
		try await fileManagerVM.loadFolder(at: rootA, for: workspace, freshStart: true)
		let requestedPath = "RootA/abc\u{0}def"

		let issue = fileManagerVM.exactPathResolutionIssue(for: requestedPath, kind: .file)

		guard case .invalidPathCharacters(let input, let reason)? = issue else {
			return XCTFail("Expected invalidPathCharacters, got \(String(describing: issue))")
		}
		XCTAssertEqual(input, requestedPath)
		XCTAssertTrue(reason.contains("NUL"))
		XCTAssertTrue(PathResolutionIssueRenderer.message(for: issue!).contains("RootA/abc\\0def"))
	}

	@MainActor
	func testGetFileSystemServiceForRelativePathRejectsAmbiguousRelativeFileForMCPProfile() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootA = tempParent.appendingPathComponent("RootA", isDirectory: true)
		let rootB = tempParent.appendingPathComponent("RootB", isDirectory: true)
		try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
		try "a".write(to: rootA.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
		try "b".write(to: rootB.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let workspace = WorkspaceModel(name: "Test", repoPaths: [rootA.path, rootB.path])
		let fileManagerVM = RepoFileManagerViewModel()
		try await fileManagerVM.loadFolder(at: rootA, for: workspace, freshStart: true)
		try await fileManagerVM.loadFolder(at: rootB, for: workspace, freshStart: false)

		let location = await fileManagerVM.getFileSystemServiceForRelativePath("README.md", profile: .mcpRead)
		XCTAssertNil(location)
	}

	@MainActor
	func testMCPReadDoesNotResolveImplicitRelativePathIntoGitData() async throws {
		let (fileManagerVM, tempParent, _, _) = try await makeWorkspaceWithGitData()
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let location = await fileManagerVM.getFileSystemServiceForRelativePath("MAP.txt", profile: .mcpRead)
		let hits = await fileManagerVM.findFiles(atPaths: ["MAP.txt"], profile: .mcpRead)

		XCTAssertNil(location)
		XCTAssertTrue(hits.isEmpty)
	}

	@MainActor
	func testDiscoveryScopeResolvesImplicitRelativePathIntoGitData() async throws {
		let (fileManagerVM, tempParent, gitDataURL, _) = try await makeWorkspaceWithGitData()
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let location = await fileManagerVM.getFileSystemServiceForRelativePath(
			"MAP.txt",
			profile: .mcpRead,
			rootScopeOverride: .visibleWorkspacePlusGitData
		)
		let hits = await fileManagerVM.findFiles(
			atPaths: ["MAP.txt"],
			profile: .mcpRead,
			rootScopeOverride: .visibleWorkspacePlusGitData
		)

		XCTAssertEqual(location?.absolutePath, gitDataURL.appendingPathComponent("MAP.txt").path)
		XCTAssertEqual(hits["MAP.txt"]?.standardizedFullPath, gitDataURL.appendingPathComponent("MAP.txt").path)
	}

	@MainActor
	func testDiscoveryScopePrefersVisibleWorkspaceOverGitDataForImplicitRelativePath() async throws {
		let (fileManagerVM, tempParent, gitDataURL, _) = try await makeWorkspaceWithGitData(
			userFiles: ["MAP.txt": "workspace-token"],
			gitDataFiles: ["MAP.txt": "artifact-only-token"]
		)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let location = await fileManagerVM.getFileSystemServiceForRelativePath(
			"MAP.txt",
			profile: .mcpRead,
			rootScopeOverride: .visibleWorkspacePlusGitData
		)
		let hits = await fileManagerVM.findFiles(
			atPaths: ["MAP.txt"],
			profile: .mcpRead,
			rootScopeOverride: .visibleWorkspacePlusGitData
		)

		XCTAssertNotEqual(location?.absolutePath, gitDataURL.appendingPathComponent("MAP.txt").path)
		XCTAssertEqual(hits["MAP.txt"]?.standardizedFullPath, location?.absolutePath)
	}

	@MainActor
	func testMCPReadResolvesExplicitGitDataPath() async throws {
		let (fileManagerVM, tempParent, gitDataURL, _) = try await makeWorkspaceWithGitData()
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let location = await fileManagerVM.getFileSystemServiceForRelativePath("_git_data/MAP.txt", profile: .mcpRead)
		let hits = await fileManagerVM.findFiles(atPaths: ["_git_data/MAP.txt"], profile: .mcpRead)

		XCTAssertEqual(location?.absolutePath, gitDataURL.appendingPathComponent("MAP.txt").path)
		XCTAssertEqual(hits["_git_data/MAP.txt"]?.standardizedFullPath, gitDataURL.appendingPathComponent("MAP.txt").path)
	}

	@MainActor
	func testMCPReadResolvesExplicitPerFilePatchArtifactPath() async throws {
		let relativePatchPath = "repos/repopromptweb-4747bd48/2026-03-14/1455/diff/per-file/RepoPrompt__ViewModels__AgentModeViewModel.swift.patch"
		let (fileManagerVM, tempParent, gitDataURL, _) = try await makeWorkspaceWithGitData(
			gitDataFiles: [relativePatchPath: "patch-body"]
		)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let taggedPath = "_git_data/\(relativePatchPath)"
		let location = await fileManagerVM.getFileSystemServiceForRelativePath(taggedPath, profile: .mcpRead)
		let hits = await fileManagerVM.findFiles(atPaths: [taggedPath], profile: .mcpRead)

		XCTAssertEqual(location?.absolutePath, gitDataURL.appendingPathComponent(relativePatchPath).path)
		XCTAssertEqual(hits[taggedPath]?.standardizedFullPath, gitDataURL.appendingPathComponent(relativePatchPath).path)
	}

	@MainActor
	func testResolveFolderForUserInputSupportsExplicitGitDataRoot() async throws {
		let (fileManagerVM, tempParent, gitDataURL, _) = try await makeWorkspaceWithGitData(
			gitDataFiles: ["repos/snapshot/MAP.txt": "artifact-only-token"]
		)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let folder = fileManagerVM.resolveFolderForUserInput("_git_data/repos")

		XCTAssertEqual(folder?.standardizedFullPath, gitDataURL.appendingPathComponent("repos").path)
	}

	@MainActor
	func testVisibleWorkspaceSearchExcludesGitDataByDefaultButAllowsExplicitPath() async throws {
		let (fileManagerVM, tempParent, gitDataURL, _) = try await makeWorkspaceWithGitData(
			userFiles: ["Sources/A.swift": "struct A {}"],
			gitDataFiles: ["MAP.txt": "artifact-only-token"]
		)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let defaultResults = try await fileManagerVM.search(
			pattern: "artifact-only-token",
			rootScope: .visibleWorkspace
		)
		let explicitResults = try await fileManagerVM.search(
			pattern: "artifact-only-token",
			paths: ["_git_data/MAP.txt"],
			rootScope: .visibleWorkspace
		)

		XCTAssertTrue((defaultResults.matches ?? []).isEmpty)
		XCTAssertEqual(explicitResults.matches?.first?.filePath, gitDataURL.appendingPathComponent("MAP.txt").path)
	}

	@MainActor
	func testVisibleWorkspaceSearchDoesNotResolveImplicitGitDataFolderFragment() async throws {
		let (fileManagerVM, tempParent, _, _) = try await makeWorkspaceWithGitData(
			userFiles: ["Sources/A.swift": "struct A {}"],
			gitDataFiles: ["repos/one/MAP.txt": "artifact-only-token"]
		)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let results = try await fileManagerVM.search(
			pattern: "artifact-only-token",
			paths: ["repos"],
			rootScope: .visibleWorkspace
		)

		XCTAssertTrue((results.matches ?? []).isEmpty)
		XCTAssertEqual(results.scopedFileCount, 0)
	}

	@MainActor
	func testDiscoveryScopeSearchResolvesImplicitGitDataFolderFragment() async throws {
		let (fileManagerVM, tempParent, gitDataURL, _) = try await makeWorkspaceWithGitData(
			userFiles: ["Sources/A.swift": "struct A {}"],
			gitDataFiles: ["repos/one/MAP.txt": "artifact-only-token"]
		)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let results = try await fileManagerVM.search(
			pattern: "artifact-only-token",
			paths: ["repos"],
			rootScope: .visibleWorkspacePlusGitData
		)

		XCTAssertEqual(results.matches?.first?.filePath, gitDataURL.appendingPathComponent("repos/one/MAP.txt").path)
		XCTAssertEqual(results.scopedFileCount, 1)
	}

	@MainActor
	func testVisibleWorkspaceSearchAllowsExplicitGitDataWildcardScope() async throws {
		let (fileManagerVM, tempParent, gitDataURL, _) = try await makeWorkspaceWithGitData(
			gitDataFiles: [
				"repos/one/MAP.txt": "artifact-only-token",
				"repos/two/DIFF.txt": "different-token"
			]
		)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let results = try await fileManagerVM.search(
			pattern: "artifact-only-token",
			paths: ["_git_data/repos/*/MAP.txt"],
			rootScope: .visibleWorkspace
		)

		XCTAssertEqual(results.matches?.first?.filePath, gitDataURL.appendingPathComponent("repos/one/MAP.txt").path)
	}

	@MainActor
	func testMCPDisplayPathUsesGitDataAliasForSystemRootFiles() async throws {
		let (fileManagerVM, tempParent, gitDataURL, _) = try await makeWorkspaceWithGitData()
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let displayPath = fileManagerVM.mcpDisplayPath(
			forAbsolutePath: gitDataURL.appendingPathComponent("MAP.txt").path
		)

		XCTAssertEqual(displayPath, "_git_data/MAP.txt")
	}

	@MainActor
	func testEditFileFromToolRejectsExplicitGitDataPath() async throws {
		let (fileManagerVM, tempParent, _, _) = try await makeWorkspaceWithGitData()
		defer { try? FileManager.default.removeItem(at: tempParent) }

		do {
			try await fileManagerVM.editFileFromTool(
				atPath: "_git_data/MAP.txt",
				newContent: "edited"
			)
			XCTFail("Expected explicit _git_data edit to be rejected")
		} catch {
			XCTAssertTrue(renderedMessage(for: error).contains("not inside any loaded folder"))
		}
	}

	@MainActor
	func testWriteFileFromToolEligibleCreateSynchronouslyMaterializesCatalog() async throws {
		let (fileManagerVM, rootURL, _) = try await makeWorkspaceRoot(fileNames: [])
		defer { try? FileManager.default.removeItem(at: rootURL) }

		let targetURL = rootURL.appendingPathComponent("Sources/New.swift")
		try await fileManagerVM.writeFileFromTool(
			userPath: targetURL.path,
			content: "struct New {}",
			ifExists: "error",
			selectAfterCreate: false
		)

		XCTAssertTrue(FileManager.default.fileExists(atPath: targetURL.path))
		XCTAssertNotNil(fileManagerVM.findFileByFullPath(targetURL.path))
		guard case .workspace(let readableFile)? = await fileManagerVM.resolveReadableFileForUserInput(targetURL.path) else {
			return XCTFail("Expected created file to be readable from the catalog immediately")
		}
		let readableContent = await readableFile.latestContent
		XCTAssertEqual(readableContent, "struct New {}")
	}

	@MainActor
	func testPolicyIneligibleFileAddedReplayDoesNotMaterializeAfterAggressiveFlush() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }
		let rootURL = tempParent.appendingPathComponent("RepoPrompt", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		try "*.secret\n".write(to: rootURL.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)

		let service = try await FileSystemService(path: rootURL.path)
		let rootFolder = FolderViewModel(
			folder: Folder(name: "RepoPrompt", path: rootURL.path, modificationDate: Date()),
			rootPath: rootURL.path,
			isExpanded: true,
			sortMethod: .nameAscending
		)
		let fileManagerVM = RepoFileManagerViewModel()
		fileManagerVM.registerRootFolderForTesting(rootFolder, service: service)
		await fileManagerVM.connectRegisteredFileSystemServicePublisherForTesting(forRootFolder: rootFolder)
		await fileManagerVM.setWindowFocusedForTesting(false)

		try await service.createFile(atRelativePath: "Hidden.secret", content: "ignored but present on disk")
		await fileManagerVM.flushPendingDeltas(aggressive: true)

		let targetURL = rootURL.appendingPathComponent("Hidden.secret")
		XCTAssertTrue(FileManager.default.fileExists(atPath: targetURL.path))
		XCTAssertNil(fileManagerVM.findFileByFullPath(targetURL.path))
		let readableAfterFlush = await fileManagerVM.resolveReadableFileForUserInput("Hidden.secret")
		XCTAssertNil(readableAfterFlush)
	}

	@MainActor
	func testEditFileFromToolSynchronouslyRefreshesDerivedState() async throws {
		let (fileManagerVM, rootURL, _) = try await makeWorkspaceRoot(fileNames: ["A.swift"])
		defer { try? FileManager.default.removeItem(at: rootURL) }

		let fileURL = rootURL.appendingPathComponent("Sources/A.swift")
		let file = try XCTUnwrap(fileManagerVM.findFileByFullPath(fileURL.path))
		await file.setModificationDate(.distantPast)
		let staleAPI = makeMinimalFileAPI(filePath: fileURL.path)
		file.setCodeMap(staleAPI)
		let unchangedDate = file.modificationDate
		await file.setModificationDate(unchangedDate, forceInvalidation: true)
		XCTAssertNil(file.fileAPI)

		file.setCodeMap(staleAPI)
		fileManagerVM.seedCachedCodeMapAPIForTesting(fullPath: fileURL.path, api: staleAPI)
		XCTAssertNotNil(file.fileAPI)
		XCTAssertNotNil(fileManagerVM.cachedCodeMapAPIForTesting(fullPath: fileURL.path))

		var sawSynchronousModifyDigest = false
		let cancellable = fileManagerVM.fileSystemDeltasAppliedPublisher.sink { event in
			for digest in event.deltas {
				if case .fileModified("Sources/A.swift") = digest {
					sawSynchronousModifyDigest = true
				}
			}
		}
		defer { cancellable.cancel() }

		let newContent = "struct A { func changed() {} }"
		try await fileManagerVM.editFileFromTool(atPath: fileURL.path, newContent: newContent)

		let latestContent = await file.latestContent
		XCTAssertEqual(latestContent, newContent)
		XCTAssertGreaterThan(file.modificationDate, Date.distantPast)
		XCTAssertNil(file.fileAPI)
		XCTAssertNil(fileManagerVM.cachedCodeMapAPIForTesting(fullPath: fileURL.path))
		XCTAssertTrue(sawSynchronousModifyDigest)
	}

	@MainActor
	func testTrashFileFromToolMovesFileToTrashAndRemovesLiveFile() async throws {
		let rootPath = "/tmp/tool-trash-\(UUID().uuidString)"
		let targetRelativePath = "DeleteMe.swift"
		let targetPath = "\(rootPath)/\(targetRelativePath)"
		let fs = InMemoryFS()
		fs.addFolder(rootPath)
		fs.addFile(targetPath)

		let service = try await FileSystemService(
			path: rootPath,
			respectGitignore: false,
			respectRepoIgnore: false,
			respectCursorignore: false,
			skipSymlinks: true,
			isTestMode: true,
			fileManagerOverride: fs
		)
		let rootFolder = FolderViewModel(
			folder: Folder(name: URL(fileURLWithPath: rootPath).lastPathComponent, path: rootPath, modificationDate: Date()),
			rootPath: rootPath,
			isExpanded: true
		)
		let targetFile = makeIndexedFileVM(
			name: targetRelativePath,
			fullPath: targetPath,
			rootFolder: rootFolder,
			service: service
		)
		rootFolder.addFile(targetFile)
		await targetFile.updateContent("stale before trash")

		let fileManagerVM = RepoFileManagerViewModel()
		fileManagerVM.registerRootFolderForTesting(rootFolder, service: service)

		try await fileManagerVM.trashFileFromTool(atPath: targetPath)

		XCTAssertTrue(fs.trashedPathsSnapshot().contains(targetPath))
		XCTAssertFalse(fs.fileExists(atPath: targetPath, isDirectory: nil))
		XCTAssertNil(fileManagerVM.findFileByFullPath(targetPath))
		let targetExistsAfterTrash = await fileManagerVM.fileExistsStrictly(atPath: targetPath)
		let editableAfterTrash = await fileManagerVM.resolveExistingFileForToolEdit(atPath: targetPath)
		let readableAfterTrash = await fileManagerVM.resolveReadableFileForUserInput(targetPath)
		let cachedContentAfterTrash = await targetFile.latestContent
		XCTAssertFalse(targetExistsAfterTrash)
		XCTAssertNil(editableAfterTrash)
		XCTAssertNil(readableAfterTrash)
		XCTAssertNil(cachedContentAfterTrash)
	}

	@MainActor
	func testTrashFolderFromToolSynchronouslyPrunesDescendantsAndCaches() async throws {
		let rootPath = "/tmp/tool-trash-folder-\(UUID().uuidString)"
		let folderRelativePath = "Nested"
		let fileRelativePath = "Nested/DeleteMe.swift"
		let folderPath = "\(rootPath)/\(folderRelativePath)"
		let filePath = "\(rootPath)/\(fileRelativePath)"
		let fs = InMemoryFS()
		fs.addFolder(rootPath)
		fs.addFolder(folderPath)
		fs.write(filePath, data: Data("stale before folder trash".utf8))

		let service = try await FileSystemService(
			path: rootPath,
			respectGitignore: false,
			respectRepoIgnore: false,
			respectCursorignore: false,
			skipSymlinks: true,
			isTestMode: true,
			fileManagerOverride: fs
		)
		let rootFolder = FolderViewModel(
			folder: Folder(name: URL(fileURLWithPath: rootPath).lastPathComponent, path: rootPath, modificationDate: Date()),
			rootPath: rootPath,
			isExpanded: true
		)
		let nestedFolder = FolderViewModel(
			folder: Folder(name: folderRelativePath, path: folderPath, modificationDate: Date()),
			rootPath: rootPath,
			hierarchyLevel: 1,
			isExpanded: true
		)
		let nestedFile = makeIndexedFileVM(
			name: "DeleteMe.swift",
			fullPath: filePath,
			rootFolder: rootFolder,
			service: service,
			parentFolder: nestedFolder,
			hierarchyLevel: 2
		)
		nestedFolder.addFile(nestedFile)
		rootFolder.addSubfolder(nestedFolder)
		await nestedFile.updateContent("stale before folder trash")

		let fileManagerVM = RepoFileManagerViewModel()
		fileManagerVM.registerRootFolderForTesting(rootFolder, service: service)

		try await fileManagerVM.trashFileFromTool(atPath: folderPath)

		XCTAssertTrue(fs.trashedPathsSnapshot().contains(folderPath))
		XCTAssertTrue(fs.trashedPathsSnapshot().contains(filePath))
		XCTAssertNil(fileManagerVM.findFolderByFullPath(folderPath))
		XCTAssertNil(fileManagerVM.findFileByFullPath(filePath))
		let readableDescendantAfterTrash = await fileManagerVM.resolveReadableFileForUserInput(filePath)
		let cachedDescendantContentAfterTrash = await nestedFile.latestContent
		XCTAssertNil(readableDescendantAfterTrash)
		XCTAssertNil(cachedDescendantContentAfterTrash)
	}

	@MainActor
	func testTrashFileFromToolRejectsRelativeDisplayPathWithAbsoluteGuidance() async throws {
		let (fileManagerVM, rootURL, _) = try await makeWorkspaceRoot()
		defer { try? FileManager.default.removeItem(at: rootURL) }

		do {
			try await fileManagerVM.trashFileFromTool(atPath: "Sources/A.swift")
			XCTFail("Expected relative delete path to be rejected")
		} catch {
			let message = renderedMessage(for: error)
			XCTAssertTrue(message.contains("relative/display path"), message)
			XCTAssertTrue(message.contains("requires a true absolute filesystem path"), message)
			XCTAssertTrue(message.contains(rootURL.appendingPathComponent("Sources/A.swift").path), message)
			XCTAssertTrue(message.contains("exact and non-fuzzy"), message)
		}
	}

	@MainActor
	func testTrashFileFromToolRejectsRootQualifiedAliasWithAbsoluteGuidance() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("RepoPrompt", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL.appendingPathComponent("Sources", isDirectory: true), withIntermediateDirectories: true)
		try "struct A {}".write(to: rootURL.appendingPathComponent("Sources/A.swift"), atomically: true, encoding: .utf8)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let workspace = WorkspaceModel(name: "Test", repoPaths: [rootURL.path])
		let fileManagerVM = RepoFileManagerViewModel()
		try await fileManagerVM.loadFolder(at: rootURL, for: workspace, freshStart: true)

		do {
			try await fileManagerVM.trashFileFromTool(atPath: "RepoPrompt/Sources/A.swift")
			XCTFail("Expected root-qualified delete alias to be rejected")
		} catch {
			let message = renderedMessage(for: error)
			XCTAssertTrue(message.contains("root-qualified display alias"), message)
			XCTAssertTrue(message.contains(rootURL.appendingPathComponent("Sources/A.swift").path), message)
			XCTAssertTrue(message.contains("does not accept relative, root-qualified"), message)
		}
	}

	@MainActor
	func testTrashFileFromToolRejectsLeadingSlashRootAliasWithAbsoluteGuidance() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("RepoPrompt", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL.appendingPathComponent("Sources", isDirectory: true), withIntermediateDirectories: true)
		try "struct A {}".write(to: rootURL.appendingPathComponent("Sources/A.swift"), atomically: true, encoding: .utf8)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let workspace = WorkspaceModel(name: "Test", repoPaths: [rootURL.path])
		let fileManagerVM = RepoFileManagerViewModel()
		try await fileManagerVM.loadFolder(at: rootURL, for: workspace, freshStart: true)

		do {
			try await fileManagerVM.trashFileFromTool(atPath: "/RepoPrompt/Sources/A.swift")
			XCTFail("Expected leading-slash root alias to be rejected")
		} catch {
			let message = renderedMessage(for: error)
			XCTAssertTrue(message.contains("leading-slash root alias"), message)
			XCTAssertTrue(message.contains(rootURL.appendingPathComponent("Sources/A.swift").path), message)
			XCTAssertTrue(message.contains("requires a true absolute filesystem path"), message)
		}
	}

	@MainActor
	func testTrashFileFromToolRejectsExplicitGitDataAliasWithSystemRootGuidance() async throws {
		let (fileManagerVM, tempParent, gitDataURL, _) = try await makeWorkspaceWithGitData()
		defer { try? FileManager.default.removeItem(at: tempParent) }

		do {
			try await fileManagerVM.trashFileFromTool(atPath: "_git_data/MAP.txt")
			XCTFail("Expected _git_data delete alias to be rejected")
		} catch {
			let message = renderedMessage(for: error)
			XCTAssertTrue(message.contains("supplemental/system-root alias"), message)
			XCTAssertTrue(message.contains(gitDataURL.appendingPathComponent("MAP.txt").path), message)
			XCTAssertTrue(message.contains("true absolute filesystem path"), message)
		}
	}

	@MainActor
	func testTrashFileFromToolAbsoluteInsideRootMissingUsesUnresolvedTaxonomy() async throws {
		let (fileManagerVM, rootURL, _) = try await makeWorkspaceRoot()
		defer { try? FileManager.default.removeItem(at: rootURL) }
		let missingPath = rootURL.appendingPathComponent("Sources/Missing.swift").path

		do {
			try await fileManagerVM.trashFileFromTool(atPath: missingPath)
			XCTFail("Expected missing absolute delete path to be rejected")
		} catch {
			let message = renderedMessage(for: error)
			XCTAssertTrue(message.contains("inside loaded root"), message)
			XCTAssertTrue(message.contains("could not resolve an exact file or folder"), message)
			XCTAssertTrue(message.contains("No indexed file or folder exists"), message)
			XCTAssertFalse(message.contains("not inside any loaded folder"), message)
		}
	}

	@MainActor
	func testTrashFileFromToolAbsoluteOutsideWorkspaceListsLoadedRootFullPath() async throws {
		let (fileManagerVM, rootURL, _) = try await makeWorkspaceRoot()
		defer { try? FileManager.default.removeItem(at: rootURL) }
		let outsidePath = rootURL.deletingLastPathComponent()
			.appendingPathComponent("outside-\(UUID().uuidString).swift")
			.path

		do {
			try await fileManagerVM.trashFileFromTool(atPath: outsidePath)
			XCTFail("Expected outside-workspace absolute delete path to be rejected")
		} catch {
			let message = renderedMessage(for: error)
			XCTAssertTrue(message.contains("not inside any loaded folder"), message)
			XCTAssertTrue(message.contains(rootURL.path), message)
			XCTAssertTrue(message.contains("true absolute paths inside loaded roots"), message)
		}
	}

	@MainActor
	func testResolveWorkspaceFileForTaggedPathMatchesRelativePath() async throws {
		let (fileManagerVM, rootURL, _) = try await makeWorkspaceRoot()
		defer { try? FileManager.default.removeItem(at: rootURL) }

		let resolved = fileManagerVM.resolveWorkspaceFileForTaggedPath("Sources/A.swift")

		XCTAssertEqual(resolved?.standardizedRelativePath, "Sources/A.swift")
	}

	@MainActor
	func testResolveWorkspaceFileForTaggedPathMatchesUniqueRelativePathAcrossRoots() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootA = tempParent.appendingPathComponent("RootA", isDirectory: true)
		let rootB = tempParent.appendingPathComponent("RootB", isDirectory: true)
		try FileManager.default.createDirectory(at: rootA.appendingPathComponent("Sources", isDirectory: true), withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: rootB.appendingPathComponent("Sources", isDirectory: true), withIntermediateDirectories: true)
		let fileAURL = rootA.appendingPathComponent("Sources/A.swift")
		let fileBURL = rootB.appendingPathComponent("Sources/B.swift")
		try "struct A {}".write(to: fileAURL, atomically: true, encoding: .utf8)
		try "struct B {}".write(to: fileBURL, atomically: true, encoding: .utf8)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let workspace = WorkspaceModel(name: "Test", repoPaths: [rootA.path, rootB.path])
		let fileManagerVM = RepoFileManagerViewModel()
		try await fileManagerVM.loadFolder(at: rootA, for: workspace, freshStart: true)
		try await fileManagerVM.loadFolder(at: rootB, for: workspace, freshStart: false)

		XCTAssertEqual(
			fileManagerVM.resolveWorkspaceFileForTaggedPath("RootA/Sources/A.swift")?.standardizedFullPath,
			fileAURL.path
		)
		XCTAssertEqual(
			fileManagerVM.resolveWorkspaceFileForTaggedPath("RootB/Sources/B.swift")?.standardizedFullPath,
			fileBURL.path
		)
	}

	@MainActor
	func testResolveWorkspaceFileForTaggedPathPrefersExplicitRootAliasOverSameNameSubfolder() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("BombSquad", isDirectory: true)
		let rootTarget = rootURL.appendingPathComponent("_mcp_test/shared", isDirectory: true)
		let nestedTarget = rootURL.appendingPathComponent("BombSquad/_mcp_test/shared", isDirectory: true)
		try FileManager.default.createDirectory(at: rootTarget, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: nestedTarget, withIntermediateDirectories: true)
		let rootFile = rootTarget.appendingPathComponent("test_file.txt")
		try "root".write(to: rootFile, atomically: true, encoding: .utf8)
		try "nested".write(to: nestedTarget.appendingPathComponent("test_file.txt"), atomically: true, encoding: .utf8)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let workspace = WorkspaceModel(name: "Test", repoPaths: [rootURL.path])
		let fileManagerVM = RepoFileManagerViewModel()
		try await fileManagerVM.loadFolder(at: rootURL, for: workspace, freshStart: true)

		XCTAssertEqual(
			fileManagerVM.resolveWorkspaceFileForTaggedPath("BombSquad/_mcp_test/shared/test_file.txt")?.standardizedFullPath,
			rootFile.path
		)
	}

	@MainActor
	func testFindFilesPrefersExplicitRootAliasOverSameNameSubfolder() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("BombSquad", isDirectory: true)
		let rootTarget = rootURL.appendingPathComponent("_mcp_test/shared", isDirectory: true)
		let nestedTarget = rootURL.appendingPathComponent("BombSquad/_mcp_test/shared", isDirectory: true)
		try FileManager.default.createDirectory(at: rootTarget, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: nestedTarget, withIntermediateDirectories: true)
		let rootFile = rootTarget.appendingPathComponent("test_file.txt")
		try "root".write(to: rootFile, atomically: true, encoding: .utf8)
		try "nested".write(to: nestedTarget.appendingPathComponent("test_file.txt"), atomically: true, encoding: .utf8)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let workspace = WorkspaceModel(name: "Test", repoPaths: [rootURL.path])
		let fileManagerVM = RepoFileManagerViewModel()
		try await fileManagerVM.loadFolder(at: rootURL, for: workspace, freshStart: true)

		let hits = await fileManagerVM.findFiles(
			atPaths: ["BombSquad/_mcp_test/shared/test_file.txt"],
			profile: .mcpRead
		)
		XCTAssertEqual(
			hits["BombSquad/_mcp_test/shared/test_file.txt"]?.standardizedFullPath,
			rootFile.path
		)
	}

	@MainActor
	func testResolveFolderForUserInputConsumesLeadingAliasWhenSameNameSubfolderExists() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("BombSquad", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL.appendingPathComponent("BombSquad", isDirectory: true), withIntermediateDirectories: true)
		let rootFolder = rootURL.appendingPathComponent("_mcp_test", isDirectory: true)
		let nestedFolder = rootURL.appendingPathComponent("BombSquad/_mcp_test", isDirectory: true)
		try FileManager.default.createDirectory(at: rootFolder, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: nestedFolder, withIntermediateDirectories: true)
		try "root".write(to: rootFolder.appendingPathComponent("RootFile.swift"), atomically: true, encoding: .utf8)
		try "nested".write(to: nestedFolder.appendingPathComponent("NestedFile.swift"), atomically: true, encoding: .utf8)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let workspace = WorkspaceModel(name: "Test", repoPaths: [rootURL.path])
		let fileManagerVM = RepoFileManagerViewModel()
		try await fileManagerVM.loadFolder(at: rootURL, for: workspace, freshStart: true)

		let resolved = fileManagerVM.resolveFolderForUserInput("BombSquad/_mcp_test")
		XCTAssertEqual(resolved?.standardizedFullPath, rootFolder.path)
	}

	@MainActor
	func testWriteFileFromToolPrefersLiteralSameNameSubfolderWhenItMatchesDeeperStructure() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("RepoPrompt", isDirectory: true)
		let nestedParent = rootURL.appendingPathComponent("RepoPrompt/Views/AgentMode/ToolCards", isDirectory: true)
		try FileManager.default.createDirectory(at: nestedParent, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let workspace = WorkspaceModel(name: "Test", repoPaths: [rootURL.path])
		let fileManagerVM = RepoFileManagerViewModel()
		try await fileManagerVM.loadFolder(at: rootURL, for: workspace, freshStart: true)

		let userPath = "RepoPrompt/Views/AgentMode/ToolCards/ToolCallChipsFlow.swift"
		try await fileManagerVM.writeFileFromTool(
			userPath: userPath,
			content: "struct ToolCallChipsFlow {}",
			ifExists: "error",
			selectAfterCreate: false
		)

		let nestedTarget = rootURL.appendingPathComponent(userPath)
		let aliasTarget = rootURL.appendingPathComponent("Views/AgentMode/ToolCards/ToolCallChipsFlow.swift")
		XCTAssertTrue(FileManager.default.fileExists(atPath: nestedTarget.path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: aliasTarget.path))
	}

	@MainActor
	func testWriteFileFromToolPrefersLiteralSameNameSubfolderForDirectChildFile() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("RepoPrompt", isDirectory: true)
		try FileManager.default.createDirectory(
			at: rootURL.appendingPathComponent("RepoPrompt", isDirectory: true),
			withIntermediateDirectories: true
		)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let workspace = WorkspaceModel(name: "Test", repoPaths: [rootURL.path])
		let fileManagerVM = RepoFileManagerViewModel()
		try await fileManagerVM.loadFolder(at: rootURL, for: workspace, freshStart: true)

		let userPath = "RepoPrompt/DirectChild.swift"
		try await fileManagerVM.writeFileFromTool(
			userPath: userPath,
			content: "struct DirectChild {}",
			ifExists: "error",
			selectAfterCreate: false
		)

		let nestedTarget = rootURL.appendingPathComponent(userPath)
		let aliasTarget = rootURL.appendingPathComponent("DirectChild.swift")
		XCTAssertTrue(FileManager.default.fileExists(atPath: nestedTarget.path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: aliasTarget.path))
	}

	@MainActor
	func testWriteFileFromToolPrefersLiteralSameNameSubfolderWhenBothParentsExist() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("RepoPrompt", isDirectory: true)
		let aliasParent = rootURL.appendingPathComponent("Views/AgentMode/ToolCards", isDirectory: true)
		let nestedParent = rootURL.appendingPathComponent("RepoPrompt/Views/AgentMode/ToolCards", isDirectory: true)
		try FileManager.default.createDirectory(at: aliasParent, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: nestedParent, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let workspace = WorkspaceModel(name: "Test", repoPaths: [rootURL.path])
		let fileManagerVM = RepoFileManagerViewModel()
		try await fileManagerVM.loadFolder(at: rootURL, for: workspace, freshStart: true)

		let userPath = "RepoPrompt/Views/AgentMode/ToolCards/SpecificLiteral.swift"
		try await fileManagerVM.writeFileFromTool(
			userPath: userPath,
			content: "struct SpecificLiteral {}",
			ifExists: "error",
			selectAfterCreate: false
		)

		let nestedTarget = rootURL.appendingPathComponent(userPath)
		let aliasTarget = rootURL.appendingPathComponent("Views/AgentMode/ToolCards/SpecificLiteral.swift")
		XCTAssertTrue(FileManager.default.fileExists(atPath: nestedTarget.path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: aliasTarget.path))
	}

	@MainActor
	func testWriteFileFromToolPrefersLiteralSameNameSubfolderForAgentModelRegistryPath() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("RepoPrompt", isDirectory: true)
		let aliasParent = rootURL.appendingPathComponent("Models/Agent/ModelSelection", isDirectory: true)
		let nestedParent = rootURL.appendingPathComponent("RepoPrompt/Models/Agent/ModelSelection", isDirectory: true)
		try FileManager.default.createDirectory(at: aliasParent, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: nestedParent, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let workspace = WorkspaceModel(name: "Test", repoPaths: [rootURL.path])
		let fileManagerVM = RepoFileManagerViewModel()
		try await fileManagerVM.loadFolder(at: rootURL, for: workspace, freshStart: true)

		let userPath = "RepoPrompt/Models/Agent/ModelSelection/AgentACPModelRegistry.swift"
		try await fileManagerVM.writeFileFromTool(
			userPath: userPath,
			content: "struct AgentACPModelRegistry {}",
			ifExists: "error",
			selectAfterCreate: false
		)

		let nestedTarget = rootURL.appendingPathComponent(userPath)
		let aliasTarget = rootURL.appendingPathComponent("Models/Agent/ModelSelection/AgentACPModelRegistry.swift")
		XCTAssertTrue(FileManager.default.fileExists(atPath: nestedTarget.path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: aliasTarget.path))
	}

	@MainActor
	func testWriteFileFromToolKeepsAliasBehaviorWhenLiteralSubfolderIsNotStronger() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("RepoPrompt", isDirectory: true)
		let aliasParent = rootURL.appendingPathComponent("Views/AgentMode/ToolCards", isDirectory: true)
		try FileManager.default.createDirectory(at: aliasParent, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let workspace = WorkspaceModel(name: "Test", repoPaths: [rootURL.path])
		let fileManagerVM = RepoFileManagerViewModel()
		try await fileManagerVM.loadFolder(at: rootURL, for: workspace, freshStart: true)

		let userPath = "RepoPrompt/Views/AgentMode/ToolCards/RootRelative.swift"
		try await fileManagerVM.writeFileFromTool(
			userPath: userPath,
			content: "struct RootRelative {}",
			ifExists: "error",
			selectAfterCreate: false
		)

		let aliasTarget = rootURL.appendingPathComponent("Views/AgentMode/ToolCards/RootRelative.swift")
		let nestedTarget = rootURL.appendingPathComponent(userPath)
		XCTAssertTrue(FileManager.default.fileExists(atPath: aliasTarget.path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: nestedTarget.path))
	}

	@MainActor
	func testWriteFileFromToolMaterializesCreatedFileWithoutWatcherIngress() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }
		let fileManagerVM = RepoFileManagerViewModel()
		let (_, rootFolder) = try await registerUnwatchedRoot(named: "RepoPrompt", under: tempParent, in: fileManagerVM)

		try await fileManagerVM.writeFileFromTool(
			userPath: "Created.md",
			content: "created through tool",
			ifExists: "error",
			selectAfterCreate: false
		)

		let targetURL = URL(fileURLWithPath: rootFolder.fullPath).appendingPathComponent("Created.md")
		XCTAssertTrue(FileManager.default.fileExists(atPath: targetURL.path))
		guard case .workspace(let readableFile)? = await fileManagerVM.resolveReadableFileForUserInput("Created.md") else {
			return XCTFail("Expected created file to be readable from the catalog immediately")
		}
		XCTAssertEqual(readableFile.standardizedFullPath, (targetURL.path as NSString).standardizingPath)
		let editableCreatedFile = await fileManagerVM.resolveExistingFileForToolEdit(atPath: "Created.md")
		XCTAssertNotNil(editableCreatedFile)
	}

	@MainActor
	func testDiskMissingCatalogPresentFileIsPrunedForReadAndEditResolution() async throws {
		let (fileManagerVM, rootURL, _) = try await makeWorkspaceRoot(fileNames: ["Deleted.swift"])
		defer { try? FileManager.default.removeItem(at: rootURL) }
		let targetURL = rootURL.appendingPathComponent("Sources/Deleted.swift")
		let relativePath = "Sources/Deleted.swift"

		guard case .workspace(let staleFile)? = await fileManagerVM.resolveReadableFileForUserInput(relativePath) else {
			return XCTFail("Expected loaded catalog file to resolve before disk removal")
		}
		let contentBeforeRemoval = await staleFile.latestContent
		XCTAssertEqual(contentBeforeRemoval, "struct Deleted {}")

		try FileManager.default.removeItem(at: targetURL)

		let absoluteReadableAfterRemoval = await fileManagerVM.resolveReadableFileForUserInput(targetURL.path)
		let readableAfterRemoval = await fileManagerVM.resolveReadableFileForUserInput(relativePath)
		let existsAfterRemoval = await fileManagerVM.fileExistsStrictly(atPath: relativePath)
		let editableAfterRemoval = await fileManagerVM.resolveExistingFileForToolEdit(atPath: relativePath)
		let staleContentAfterRemoval = await staleFile.latestContent
		XCTAssertNil(absoluteReadableAfterRemoval)
		XCTAssertNil(readableAfterRemoval)
		XCTAssertFalse(existsAfterRemoval)
		XCTAssertNil(editableAfterRemoval)
		XCTAssertNil(fileManagerVM.findFileByFullPath(targetURL.path))
		XCTAssertNil(staleContentAfterRemoval)
	}

	@MainActor
	func testStrictWorkspaceReadReloadsExternalModificationWithoutDeliveredDelta() async throws {
		let (fileManagerVM, rootURL, _) = try await makeWorkspaceRoot(fileNames: ["A.swift"])
		defer { try? FileManager.default.removeItem(at: rootURL) }
		let targetURL = rootURL.appendingPathComponent("Sources/A.swift")
		let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
		let staleContent = "struct A { let staleReadToken = true }\n"
		try staleContent.write(to: targetURL, atomically: false, encoding: .utf8)
		try setDiskModificationDate(fixedDate, for: targetURL)
		let file = try XCTUnwrap(fileManagerVM.findFileByFullPath(targetURL.path))
		await file.setModificationDate(fixedDate, forceInvalidation: true)
		let warmedContent = await file.latestContent
		let warmedSnapshot = await file.cachedContentSnapshot()
		XCTAssertEqual(warmedContent, staleContent)
		XCTAssertTrue(warmedSnapshot.isFresh)

		let freshContent = "struct A { let freshReadToken = true }\n"
		try freshContent.write(to: targetURL, atomically: false, encoding: .utf8)
		try setDiskModificationDate(fixedDate, for: targetURL)

		let strictContent = try await fileManagerVM.readWorkspaceFileContentStrictly(file)

		let latestContent = await file.latestContent
		XCTAssertEqual(strictContent, freshContent)
		XCTAssertEqual(latestContent, freshContent)
	}

	@MainActor
	func testContentSearchReloadsExternalModificationWithoutDeliveredDelta() async throws {
		let (fileManagerVM, rootURL, _) = try await makeWorkspaceRoot(fileNames: ["A.swift"])
		defer { try? FileManager.default.removeItem(at: rootURL) }
		let targetURL = rootURL.appendingPathComponent("Sources/A.swift")
		let staleDate = Date(timeIntervalSince1970: 1_700_000_100)
		let freshDate = Date(timeIntervalSince1970: 1_700_000_200)
		let staleContent = "struct A { let staleSearchToken = true }\n"
		try staleContent.write(to: targetURL, atomically: false, encoding: .utf8)
		try setDiskModificationDate(staleDate, for: targetURL)
		let file = try XCTUnwrap(fileManagerVM.findFileByFullPath(targetURL.path))
		await file.setModificationDate(staleDate, forceInvalidation: true)
		let warmedContent = await file.latestContent
		XCTAssertEqual(warmedContent, staleContent)

		let freshContent = "struct A { let freshSearchToken = true }\n"
		try freshContent.write(to: targetURL, atomically: false, encoding: .utf8)
		try setDiskModificationDate(freshDate, for: targetURL)

		let freshResults = try await fileManagerVM.search(
			pattern: "freshSearchToken",
			mode: .content,
			isRegex: false,
			paths: ["Sources/A.swift"]
		)
		let staleResults = try await fileManagerVM.search(
			pattern: "staleSearchToken",
			mode: .content,
			isRegex: false,
			paths: ["Sources/A.swift"]
		)

		XCTAssertEqual(freshResults.matches?.count, 1)
		XCTAssertTrue((staleResults.matches ?? []).isEmpty)
	}

	@MainActor
	func testDeliveredFileModifiedWithUnchangedMTimeForcesContentReloadForSearch() async throws {
		let (fileManagerVM, rootURL, _) = try await makeWorkspaceRoot(fileNames: ["A.swift"])
		defer { try? FileManager.default.removeItem(at: rootURL) }
		let targetURL = rootURL.appendingPathComponent("Sources/A.swift")
		let rootFolder = try XCTUnwrap(fileManagerVM.rootFolders.first)
		let fixedDate = Date(timeIntervalSince1970: 1_700_000_300)
		let staleContent = "struct A { let staleDeliveredToken = true }\n"
		try staleContent.write(to: targetURL, atomically: false, encoding: .utf8)
		try setDiskModificationDate(fixedDate, for: targetURL)
		let file = try XCTUnwrap(fileManagerVM.findFileByFullPath(targetURL.path))
		await file.setModificationDate(fixedDate, forceInvalidation: true)
		let warmedContent = await file.latestContent
		XCTAssertEqual(warmedContent, staleContent)

		let freshContent = "struct A { let freshDeliveredToken = true }\n"
		try freshContent.write(to: targetURL, atomically: false, encoding: .utf8)
		try setDiskModificationDate(fixedDate, for: targetURL)
		await fileManagerVM.applyPreparedDeltasWithoutCoalescingForTesting(
			[.fileModified("Sources/A.swift", fixedDate)],
			forRootFolder: rootFolder
		)

		let results = try await fileManagerVM.search(
			pattern: "freshDeliveredToken",
			mode: .content,
			isRegex: false,
			paths: ["Sources/A.swift"]
		)

		let latestContent = await file.latestContent
		XCTAssertEqual(results.matches?.count, 1)
		XCTAssertEqual(latestContent, freshContent)
	}

	@MainActor
	func testApplyEditsPreviewReadsFreshDiskContentAfterExternalModification() async throws {
		let (fileManagerVM, rootURL, _) = try await makeWorkspaceRoot(fileNames: ["A.swift"])
		defer { try? FileManager.default.removeItem(at: rootURL) }
		let targetURL = rootURL.appendingPathComponent("Sources/A.swift")
		let fixedDate = Date(timeIntervalSince1970: 1_700_000_400)
		let staleContent = "struct A { let staleApplyToken = true }\n"
		try staleContent.write(to: targetURL, atomically: false, encoding: .utf8)
		try setDiskModificationDate(fixedDate, for: targetURL)
		let file = try XCTUnwrap(fileManagerVM.findFileByFullPath(targetURL.path))
		await file.setModificationDate(fixedDate, forceInvalidation: true)
		let warmedContent = await file.latestContent
		XCTAssertEqual(warmedContent, staleContent)

		let freshContent = "struct A { let freshApplyToken = true }\n"
		try freshContent.write(to: targetURL, atomically: false, encoding: .utf8)
		try setDiskModificationDate(fixedDate, for: targetURL)
		let service = ApplyEditsService(engine: .default, host: makeWorkspaceFileEditHost(fileManagerVM: fileManagerVM))
		let request = ApplyEditsRequest(
			path: "Sources/A.swift",
			mode: .single(search: "freshApplyToken", replace: "editedApplyToken", replaceAll: false),
			verbose: true
		)

		let preview = try await service.preview(request)

		XCTAssertTrue(preview.exists)
		XCTAssertEqual(preview.originalText, freshContent)
		XCTAssertTrue(preview.result.updatedText.contains("editedApplyToken"))
		XCTAssertFalse(preview.result.updatedText.contains("staleApplyToken"))
	}

	@MainActor
	func testStrictWorkspaceReadPrunesDiskMissingCatalogFileWithoutFallback() async throws {
		let (fileManagerVM, rootURL, _) = try await makeWorkspaceRoot(fileNames: ["Deleted.swift"])
		defer { try? FileManager.default.removeItem(at: rootURL) }
		let targetURL = rootURL.appendingPathComponent("Sources/Deleted.swift")
		let file = try XCTUnwrap(fileManagerVM.findFileByFullPath(targetURL.path))
		let staleContent = try String(contentsOf: targetURL, encoding: .utf8)
		let warmedContent = await file.latestContent
		XCTAssertEqual(warmedContent, staleContent)

		try FileManager.default.removeItem(at: targetURL)

		do {
			_ = try await fileManagerVM.readWorkspaceFileContentStrictly(file)
			XCTFail("Expected strict read to reject a disk-missing catalog file")
		} catch StrictWorkspaceFileContentError.fileMissing(let path) {
			XCTAssertEqual(path, file.standardizedFullPath)
		} catch {
			XCTFail("Expected fileMissing, got \(error)")
		}
		let latestAfterRemoval = await file.latestContent
		XCTAssertNil(fileManagerVM.findFileByFullPath(targetURL.path))
		XCTAssertNil(latestAfterRemoval)
	}

	@MainActor
	func testAggressiveFlushProcessesPublisherModificationBeforeCachedRead() async throws {
		let (fileManagerVM, rootURL, _) = try await makeWorkspaceRoot(fileNames: ["A.swift"])
		defer { try? FileManager.default.removeItem(at: rootURL) }
		let targetURL = rootURL.appendingPathComponent("Sources/A.swift")
		let rootFolder = try XCTUnwrap(fileManagerVM.rootFolders.first)
		let service = try XCTUnwrap(fileManagerVM.getFileSystemService(for: rootURL.path))
		let initialContent = "struct A { let staleFlushToken = true }\n"
		try initialContent.write(to: targetURL, atomically: false, encoding: .utf8)
		let initialDate = Date(timeIntervalSince1970: 1_700_000_500)
		try setDiskModificationDate(initialDate, for: targetURL)
		let file = try XCTUnwrap(fileManagerVM.findFileByFullPath(targetURL.path))
		await file.setModificationDate(initialDate, forceInvalidation: true)
		let warmedContent = await file.latestContent
		XCTAssertEqual(warmedContent, initialContent)
		await fileManagerVM.connectRegisteredFileSystemServicePublisherForTesting(forRootFolder: rootFolder)
		await fileManagerVM.setWindowFocusedForTesting(false)

		let freshContent = "struct A { let freshFlushToken = true }\n"
		try await service.editFile(atRelativePath: "Sources/A.swift", newContent: freshContent)
		await fileManagerVM.flushPendingDeltas(aggressive: true)

		let pendingDeltaCount = await fileManagerVM.pendingDeltaCountForTesting(forRootFolder: rootFolder)
		let latestContent = await file.latestContent
		XCTAssertEqual(pendingDeltaCount, 0)
		XCTAssertEqual(latestContent, freshContent)
	}

	@MainActor
	func testExactDiskPresentCatalogMissingFileIsReconciledForReadAndEdit() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }
		let fileManagerVM = RepoFileManagerViewModel()
		let (rootURL, _) = try await registerUnwatchedRoot(named: "RepoPrompt", under: tempParent, in: fileManagerVM)
		let docsURL = rootURL.appendingPathComponent("Docs", isDirectory: true)
		try FileManager.default.createDirectory(at: docsURL, withIntermediateDirectories: true)
		let readURL = docsURL.appendingPathComponent("Readable.md")
		let editURL = docsURL.appendingPathComponent("Editable.md")
		try "read me".write(to: readURL, atomically: true, encoding: .utf8)
		try "edit me".write(to: editURL, atomically: true, encoding: .utf8)

		XCTAssertNil(fileManagerVM.findFileByRelativePath("Docs/Readable.md"))
		guard case .workspace(let readableFile)? = await fileManagerVM.resolveReadableFileForUserInput("Docs/Readable.md") else {
			return XCTFail("Expected disk-present file to be reconciled for read_file resolution")
		}
		XCTAssertEqual(readableFile.standardizedFullPath, (readURL.path as NSString).standardizingPath)
		let readableContent = await readableFile.latestContent
		XCTAssertEqual(readableContent, "read me")

		let editableExists = await fileManagerVM.fileExistsStrictly(atPath: "Docs/Editable.md")
		XCTAssertTrue(editableExists)
		let editableFile = await fileManagerVM.resolveExistingFileForToolEdit(atPath: "Docs/Editable.md")
		XCTAssertEqual(editableFile?.standardizedFullPath, (editURL.path as NSString).standardizingPath)
	}

	@MainActor
	func testExactDiskReconciliationDoesNotMaterializeIgnoredCatalogMissingFile() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }
		let rootURL = tempParent.appendingPathComponent("RepoPrompt", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		try "*.secret\n".write(to: rootURL.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
		let service = try await FileSystemService(path: rootURL.path)
		let rootFolder = FolderViewModel(
			folder: Folder(name: "RepoPrompt", path: rootURL.path, modificationDate: Date()),
			rootPath: rootURL.path,
			isExpanded: true,
			sortMethod: .nameAscending
		)
		let fileManagerVM = RepoFileManagerViewModel()
		fileManagerVM.registerRootFolderForTesting(rootFolder, service: service)
		try "hidden".write(to: rootURL.appendingPathComponent("Hidden.secret"), atomically: true, encoding: .utf8)

		let resolved = await fileManagerVM.resolveReadableFileForUserInput("Hidden.secret")
		XCTAssertNil(resolved)
		let editableFile = await fileManagerVM.resolveExistingFileForToolEdit(atPath: "Hidden.secret")
		XCTAssertNil(editableFile)
		XCTAssertEqual(fileManagerVM.restorePerfLoadedTreeCounts().fileCount, 0)
	}

	@MainActor
	func testExactDiskReconciliationIgnoresIneligibleDuplicateBeforeAmbiguityDecision() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }
		let fileManagerVM = RepoFileManagerViewModel()
		let (rootAURL, _) = try await registerUnwatchedRoot(named: "RootA", under: tempParent, in: fileManagerVM)
		let rootBURL = tempParent.appendingPathComponent("RootB", isDirectory: true)
		try FileManager.default.createDirectory(at: rootBURL, withIntermediateDirectories: true)
		try "Shared.md\n".write(to: rootBURL.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
		let rootBService = try await FileSystemService(path: rootBURL.path)
		let rootBFolder = FolderViewModel(
			folder: Folder(name: "RootB", path: rootBURL.path, modificationDate: Date()),
			rootPath: rootBURL.path,
			isExpanded: true,
			sortMethod: .nameAscending
		)
		fileManagerVM.registerRootFolderForTesting(rootBFolder, service: rootBService)
		try "eligible".write(to: rootAURL.appendingPathComponent("Shared.md"), atomically: true, encoding: .utf8)
		try "ignored".write(to: rootBURL.appendingPathComponent("Shared.md"), atomically: true, encoding: .utf8)

		guard case .workspace(let resolvedFile)? = await fileManagerVM.resolveReadableFileForUserInput("Shared.md") else {
			return XCTFail("Expected the single catalog-eligible disk candidate to reconcile")
		}
		XCTAssertEqual(resolvedFile.standardizedFullPath, (rootAURL.appendingPathComponent("Shared.md").path as NSString).standardizingPath)
		XCTAssertEqual(fileManagerVM.restorePerfLoadedTreeCounts().fileCount, 1)
	}

	@MainActor
	func testWriteFileFromToolDoesNotMaterializeIgnoredCreatedFile() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }
		let rootURL = tempParent.appendingPathComponent("RepoPrompt", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		try "*.secret\n".write(to: rootURL.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
		let service = try await FileSystemService(path: rootURL.path)
		let rootFolder = FolderViewModel(
			folder: Folder(name: "RepoPrompt", path: rootURL.path, modificationDate: Date()),
			rootPath: rootURL.path,
			isExpanded: true,
			sortMethod: .nameAscending
		)
		let fileManagerVM = RepoFileManagerViewModel()
		fileManagerVM.registerRootFolderForTesting(rootFolder, service: service)

		try await fileManagerVM.writeFileFromTool(
			userPath: "Hidden.secret",
			content: "created but ignored",
			ifExists: "error",
			selectAfterCreate: false
		)

		XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("Hidden.secret").path))
		let resolved = await fileManagerVM.resolveReadableFileForUserInput("Hidden.secret")
		XCTAssertNil(resolved)
		XCTAssertEqual(fileManagerVM.restorePerfLoadedTreeCounts().fileCount, 0)
	}

	@MainActor
	func testDuplicateFileAddedAfterSynchronousToolCreateIsIdempotent() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }
		let fileManagerVM = RepoFileManagerViewModel()
		let (_, rootFolder) = try await registerUnwatchedRoot(named: "RepoPrompt", under: tempParent, in: fileManagerVM)

		try await fileManagerVM.writeFileFromTool(
			userPath: "Created.md",
			content: "created through tool",
			ifExists: "error",
			selectAfterCreate: false
		)
		let fileCountAfterCreate = fileManagerVM.restorePerfLoadedTreeCounts().fileCount

		await fileManagerVM.applyFileSystemDeltasForTesting([.fileAdded("Created.md")], forRootFolder: rootFolder)

		XCTAssertEqual(fileManagerVM.restorePerfLoadedTreeCounts().fileCount, fileCountAfterCreate)
		let rootFileChildren = rootFolder.children.compactMap { child -> FileViewModel? in
			if case .file(let file) = child { return file }
			return nil
		}
		XCTAssertEqual(rootFileChildren.filter { $0.name == "Created.md" }.count, 1)
	}

	@MainActor
	func testExactDiskReconciliationDoesNotChooseAmbiguousRelativeMultiRootPath() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }
		let fileManagerVM = RepoFileManagerViewModel()
		let (rootAURL, _) = try await registerUnwatchedRoot(named: "RootA", under: tempParent, in: fileManagerVM)
		let (rootBURL, _) = try await registerUnwatchedRoot(named: "RootB", under: tempParent, in: fileManagerVM)
		try "a".write(to: rootAURL.appendingPathComponent("Shared.md"), atomically: true, encoding: .utf8)
		try "b".write(to: rootBURL.appendingPathComponent("Shared.md"), atomically: true, encoding: .utf8)

		let ambiguousReadableFile = await fileManagerVM.resolveReadableFileForUserInput("Shared.md")
		XCTAssertNil(ambiguousReadableFile)
		let ambiguousExists = await fileManagerVM.fileExistsStrictly(atPath: "Shared.md")
		XCTAssertFalse(ambiguousExists)
		XCTAssertEqual(fileManagerVM.restorePerfLoadedTreeCounts().fileCount, 0)

		guard case .workspace(let rootAFile)? = await fileManagerVM.resolveReadableFileForUserInput("RootA/Shared.md") else {
			return XCTFail("Expected alias-qualified disk-present file to reconcile in the selected root")
		}
		XCTAssertEqual(rootAFile.standardizedFullPath, (rootAURL.appendingPathComponent("Shared.md").path as NSString).standardizingPath)
	}

	@MainActor
	func testResolveVisibleAliasPrefixedAbsolutePathResolutionConsumesLeadingAlias() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("RepoPrompt", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		let shadowURL = rootURL.appendingPathComponent("RepoPrompt/Views", isDirectory: true)
		try FileManager.default.createDirectory(at: shadowURL, withIntermediateDirectories: true)
		try "struct Shadow {}".write(
			to: shadowURL.appendingPathComponent("Shadow.swift"),
			atomically: true,
			encoding: .utf8
		)
		let workspace = WorkspaceModel(name: "Test", repoPaths: [rootURL.path])
		let fileManagerVM = RepoFileManagerViewModel()
		try await fileManagerVM.loadFolder(at: rootURL, for: workspace, freshStart: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }
		
		let resolution = fileManagerVM.resolveVisibleAliasPrefixedAbsolutePathResolution("RepoPrompt/Views", requireRemainder: true)
		if case .resolved(let absolutePath) = resolution {
			XCTAssertEqual(absolutePath, rootURL.appendingPathComponent("Views").path)
		} else {
			XCTFail("Expected leading alias to resolve root-relative path, got \(resolution)")
		}
		
		let folderResolution = await fileManagerVM.resolveFilesForFolderInput("RepoPrompt/RepoPrompt/Views")
		XCTAssertTrue(folderResolution.handled)
		XCTAssertEqual(folderResolution.displayPath, "RepoPrompt/Views")
		XCTAssertEqual(folderResolution.files.count, 1)
	}

	@MainActor
	func testResolveReadableFileForUserInputAllowsGlobalSkillFileOutsideWorkspace() async throws {
		let homeURL = try makeTemporaryHomeDirectory()
		let skillURL = homeURL
			.appendingPathComponent(".agents/skills/test-skill", isDirectory: true)
			.appendingPathComponent("SKILL.md")
		try FileManager.default.createDirectory(at: skillURL.deletingLastPathComponent(), withIntermediateDirectories: true)
		try "# Test Skill".write(to: skillURL, atomically: true, encoding: .utf8)
		defer { try? FileManager.default.removeItem(at: homeURL) }

		let fileManagerVM = RepoFileManagerViewModel(alwaysReadableHomeDirectoryURL: homeURL)
		let resolved = await fileManagerVM.resolveReadableFileForUserInput(skillURL.path)

		guard case .external(let file)? = resolved else {
			return XCTFail("Expected external readable file, got \(String(describing: resolved))")
		}
		XCTAssertEqual(file.absolutePath, skillURL.path)
		XCTAssertEqual(file.displayPath, "~/.agents/skills/test-skill/SKILL.md")
		XCTAssertTrue(fileManagerVM.isAlwaysReadableExternalPath(skillURL.path))
	}

	@MainActor
	func testResolveReadableFileForUserInputRejectsSymlinkEscapingAllowlist() async throws {
		let tempRoot = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let homeURL = tempRoot.appendingPathComponent("home", isDirectory: true)
		let outsideURL = tempRoot.appendingPathComponent("secret.txt")
		let symlinkURL = homeURL
			.appendingPathComponent(".agents/skills/test-skill", isDirectory: true)
			.appendingPathComponent("SKILL.md")
		try FileManager.default.createDirectory(at: symlinkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
		try "secret".write(to: outsideURL, atomically: true, encoding: .utf8)
		try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: outsideURL)
		defer { try? FileManager.default.removeItem(at: tempRoot) }

		let fileManagerVM = RepoFileManagerViewModel(alwaysReadableHomeDirectoryURL: homeURL)
		let resolved = await fileManagerVM.resolveReadableFileForUserInput(symlinkURL.path)

		XCTAssertNil(resolved)
	}

	@MainActor
	func testResolveReadableFileForUserInputKeepsRelativePathsWorkspaceBound() async throws {
		let homeURL = try makeTemporaryHomeDirectory()
		let skillURL = homeURL
			.appendingPathComponent(".agents/skills/test-skill", isDirectory: true)
			.appendingPathComponent("SKILL.md")
		try FileManager.default.createDirectory(at: skillURL.deletingLastPathComponent(), withIntermediateDirectories: true)
		try "# Test Skill".write(to: skillURL, atomically: true, encoding: .utf8)
		defer { try? FileManager.default.removeItem(at: homeURL) }

		let fileManagerVM = RepoFileManagerViewModel(alwaysReadableHomeDirectoryURL: homeURL)
		let resolved = await fileManagerVM.resolveReadableFileForUserInput(".agents/skills/test-skill/SKILL.md")

		XCTAssertNil(resolved)
	}

	@MainActor
	func testResolveAlwaysReadableExternalFolderDisplayPathReturnsFolderPath() async throws {
		let homeURL = try makeTemporaryHomeDirectory()
		let folderURL = homeURL.appendingPathComponent(".claude/skills/example", isDirectory: true)
		try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: homeURL) }

		let fileManagerVM = RepoFileManagerViewModel(alwaysReadableHomeDirectoryURL: homeURL)
		XCTAssertEqual(
			fileManagerVM.resolveAlwaysReadableExternalFolderDisplayPath(folderURL.path),
			"~/.claude/skills/example"
		)
	}

	@MainActor
	func testReadFileLookupFallsBackToLiteralRelativePathWhenAliasMisses() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("RepoPrompt", isDirectory: true)
		let literalFileURL = rootURL.appendingPathComponent("RepoPrompt/ViewModels/SelectedFilesPanelViewModel.swift")
		try FileManager.default.createDirectory(at: literalFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
		try "struct SelectedFilesPanelViewModel {}".write(
			to: literalFileURL,
			atomically: true,
			encoding: .utf8
		)
		defer { try? FileManager.default.removeItem(at: tempParent) }
		
		let workspace = WorkspaceModel(name: "Test", repoPaths: [rootURL.path])
		let fileManagerVM = RepoFileManagerViewModel()
		try await fileManagerVM.loadFolder(at: rootURL, for: workspace, freshStart: true)
		
		let file = await fileManagerVM.resolveFileForUserInput("RepoPrompt/ViewModels/SelectedFilesPanelViewModel.swift")
		XCTAssertEqual(file?.standardizedFullPath, literalFileURL.path)
	}
	
	@MainActor
	func testFolderLookupFallsBackToLiteralRelativePathWhenAliasMisses() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("RepoPrompt", isDirectory: true)
		let literalFolderURL = rootURL.appendingPathComponent("RepoPrompt/ViewModels", isDirectory: true)
		let literalFileURL = literalFolderURL.appendingPathComponent("SelectedFilesPanelViewModel.swift")
		try FileManager.default.createDirectory(at: literalFolderURL, withIntermediateDirectories: true)
		try "struct SelectedFilesPanelViewModel {}".write(
			to: literalFileURL,
			atomically: true,
			encoding: .utf8
		)
		defer { try? FileManager.default.removeItem(at: tempParent) }
		
		let workspace = WorkspaceModel(name: "Test", repoPaths: [rootURL.path])
		let fileManagerVM = RepoFileManagerViewModel()
		try await fileManagerVM.loadFolder(at: rootURL, for: workspace, freshStart: true)
		
		let resolution = await fileManagerVM.resolveFilesForFolderInput("RepoPrompt/ViewModels")
		XCTAssertTrue(resolution.handled)
		XCTAssertEqual(
			Set(resolution.files.map(\.standardizedFullPath)),
			Set([literalFileURL.path])
		)
	}
	
	@MainActor
	func testSearchRegexAutoCorrectionSurfacesWarningMessage() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("RepoPrompt", isDirectory: true)
		let fileURL = rootURL.appendingPathComponent("Sources/A.swift")
		try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
		try "func call() {}\n".write(to: fileURL, atomically: true, encoding: .utf8)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let workspace = WorkspaceModel(name: "Test", repoPaths: [rootURL.path])
		let fileManagerVM = RepoFileManagerViewModel()
		try await fileManagerVM.loadFolder(at: rootURL, for: workspace, freshStart: true)

		let results = try await fileManagerVM.search(
			pattern: "(",
			mode: .content,
			isRegex: true
		)

		XCTAssertEqual(results.matches?.count, 1)
		XCTAssertTrue(results.warningMessage?.contains("content-search pattern") == true)
		XCTAssertTrue(results.warningMessage?.contains("regex") == true)
	}

	@MainActor
	func testSearchScopeFallsBackToLiteralRelativeFolderWhenAliasMisses() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("RepoPrompt", isDirectory: true)
		let literalFolderURL = rootURL.appendingPathComponent("RepoPrompt/ViewModels", isDirectory: true)
		let literalFileURL = literalFolderURL.appendingPathComponent("SelectedFilesPanelViewModel.swift")
		try FileManager.default.createDirectory(at: literalFolderURL, withIntermediateDirectories: true)
		try "struct SelectedFilesPanelViewModel {}".write(
			to: literalFileURL,
			atomically: true,
			encoding: .utf8
		)
		defer { try? FileManager.default.removeItem(at: tempParent) }
		
		let workspace = WorkspaceModel(name: "Test", repoPaths: [rootURL.path])
		let fileManagerVM = RepoFileManagerViewModel()
		try await fileManagerVM.loadFolder(at: rootURL, for: workspace, freshStart: true)
		
		let results = try await fileManagerVM.search(
			pattern: "SelectedFilesPanelViewModel",
			mode: .content,
			isRegex: false,
			paths: ["RepoPrompt/ViewModels"]
		)
		
		XCTAssertEqual(
			Set(results.matches?.map(\.filePath) ?? []),
			Set([literalFileURL.path])
		)
	}
	
	@MainActor
	func testApplyEditsExistingFileFallsBackToLiteralRelativePathWhenAliasMisses() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("RepoPrompt", isDirectory: true)
		let literalFileURL = rootURL.appendingPathComponent("RepoPrompt/ViewModels/SelectedFilesPanelViewModel.swift")
		try FileManager.default.createDirectory(at: literalFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
		try "struct SelectedFilesPanelViewModel {}\n".write(
			to: literalFileURL,
			atomically: true,
			encoding: .utf8
		)
		defer { try? FileManager.default.removeItem(at: tempParent) }
		
		let workspace = WorkspaceModel(name: "Test", repoPaths: [rootURL.path])
		let fileManagerVM = RepoFileManagerViewModel()
		try await fileManagerVM.loadFolder(at: rootURL, for: workspace, freshStart: true)
		
		let service = ApplyEditsService(engine: .default, host: makeWorkspaceFileEditHost(fileManagerVM: fileManagerVM))
		let request = ApplyEditsRequest(
			path: "RepoPrompt/ViewModels/SelectedFilesPanelViewModel.swift",
			mode: .single(search: "SelectedFilesPanelViewModel", replace: "UpdatedSelectionPanelViewModel", replaceAll: false),
			verbose: false
		)
		
		let result = try await service.run(request)
		XCTAssertEqual(result.status, .success)
		XCTAssertEqual(result.fileCreated, false)
		XCTAssertTrue(try String(contentsOf: literalFileURL, encoding: .utf8).contains("UpdatedSelectionPanelViewModel"))
	}
	
	@MainActor
	func testApplyEditsExistingFileStillPrefersExplicitRootAliasOverSameNameSubfolder() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("BombSquad", isDirectory: true)
		let rootTarget = rootURL.appendingPathComponent("_mcp_test/shared", isDirectory: true)
		let literalShadow = rootURL.appendingPathComponent("BombSquad/_mcp_test/shared", isDirectory: true)
		let rootFileURL = rootTarget.appendingPathComponent("test_file.txt")
		let shadowFileURL = literalShadow.appendingPathComponent("test_file.txt")
		try FileManager.default.createDirectory(at: rootTarget, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: literalShadow, withIntermediateDirectories: true)
		try "root\n".write(to: rootFileURL, atomically: true, encoding: .utf8)
		try "shadow\n".write(to: shadowFileURL, atomically: true, encoding: .utf8)
		defer { try? FileManager.default.removeItem(at: tempParent) }
		
		let workspace = WorkspaceModel(name: "Test", repoPaths: [rootURL.path])
		let fileManagerVM = RepoFileManagerViewModel()
		try await fileManagerVM.loadFolder(at: rootURL, for: workspace, freshStart: true)
		
		let service = ApplyEditsService(engine: .default, host: makeWorkspaceFileEditHost(fileManagerVM: fileManagerVM))
		let request = ApplyEditsRequest(
			path: "BombSquad/_mcp_test/shared/test_file.txt",
			mode: .single(search: "root", replace: "edited-root", replaceAll: false),
			verbose: false
		)
		
		let result = try await service.run(request)
		XCTAssertEqual(result.status, .success)
		XCTAssertEqual(try String(contentsOf: rootFileURL, encoding: .utf8), "edited-root\n")
		XCTAssertEqual(try String(contentsOf: shadowFileURL, encoding: .utf8), "shadow\n")
	}
	
	@MainActor
	func testApplyEditsRewriteCreatePreservesExistingCreateSemanticsForAliasLookingPath() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("RepoPrompt", isDirectory: true)
		let literalFolderURL = rootURL.appendingPathComponent("RepoPrompt/ViewModels", isDirectory: true)
		let rootRelativeFileURL = rootURL.appendingPathComponent("ViewModels/NewFile.swift")
		let literalFileURL = literalFolderURL.appendingPathComponent("NewFile.swift")
		try FileManager.default.createDirectory(at: literalFolderURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }
		
		let workspace = WorkspaceModel(name: "Test", repoPaths: [rootURL.path])
		let fileManagerVM = RepoFileManagerViewModel()
		try await fileManagerVM.loadFolder(at: rootURL, for: workspace, freshStart: true)
		
		let service = ApplyEditsService(engine: .default, host: makeWorkspaceFileEditHost(fileManagerVM: fileManagerVM))
		let request = ApplyEditsRequest(
			path: "RepoPrompt/ViewModels/NewFile.swift",
			mode: .rewrite(newText: "struct NewFile {}\n", onMissing: .create),
			verbose: false
		)
		
		let result = try await service.run(request)
		XCTAssertEqual(result.fileCreated, true)
		XCTAssertEqual(try String(contentsOf: rootRelativeFileURL, encoding: .utf8), "struct NewFile {}\n")
		XCTAssertFalse(FileManager.default.fileExists(atPath: literalFileURL.path))
	}
	
	@MainActor
	func testApplyEditsRewriteCreateDoesNotTreatNonExactPathAsExistingFile() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("RepoPrompt", isDirectory: true)
		let literalFolderURL = rootURL.appendingPathComponent("RepoPrompt/ViewModels", isDirectory: true)
		let literalFileURL = literalFolderURL.appendingPathComponent("SelectedFilesPanelViewModel.swift")
		let rootRelativeCreatedURL = rootURL.appendingPathComponent("ViewModels/SelectedFilesPanelViewModel")
		try FileManager.default.createDirectory(at: literalFolderURL, withIntermediateDirectories: true)
		try "struct SelectedFilesPanelViewModel {}\n".write(
			to: literalFileURL,
			atomically: true,
			encoding: .utf8
		)
		defer { try? FileManager.default.removeItem(at: tempParent) }
		
		let workspace = WorkspaceModel(name: "Test", repoPaths: [rootURL.path])
		let fileManagerVM = RepoFileManagerViewModel()
		try await fileManagerVM.loadFolder(at: rootURL, for: workspace, freshStart: true)
		
		let service = ApplyEditsService(engine: .default, host: makeWorkspaceFileEditHost(fileManagerVM: fileManagerVM))
		let request = ApplyEditsRequest(
			path: "RepoPrompt/ViewModels/SelectedFilesPanelViewModel",
			mode: .rewrite(newText: "struct CreatedWithoutExtension {}\n", onMissing: .create),
			verbose: false
		)
		
		let result = try await service.run(request)
		XCTAssertEqual(result.fileCreated, true)
		XCTAssertEqual(try String(contentsOf: literalFileURL, encoding: .utf8), "struct SelectedFilesPanelViewModel {}\n")
		XCTAssertEqual(try String(contentsOf: rootRelativeCreatedURL, encoding: .utf8), "struct CreatedWithoutExtension {}\n")
	}
	
	@MainActor
	func testSearchScopeFallsBackToLiteralRelativeFileWhenAliasMisses() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("RepoPrompt", isDirectory: true)
		let literalFolderURL = rootURL.appendingPathComponent("RepoPrompt/ViewModels", isDirectory: true)
		let literalFileURL = literalFolderURL.appendingPathComponent("SelectedFilesPanelViewModel.swift")
		try FileManager.default.createDirectory(at: literalFolderURL, withIntermediateDirectories: true)
		try "struct SelectedFilesPanelViewModel {}".write(
			to: literalFileURL,
			atomically: true,
			encoding: .utf8
		)
		defer { try? FileManager.default.removeItem(at: tempParent) }
		
		let workspace = WorkspaceModel(name: "Test", repoPaths: [rootURL.path])
		let fileManagerVM = RepoFileManagerViewModel()
		try await fileManagerVM.loadFolder(at: rootURL, for: workspace, freshStart: true)
		
		let results = try await fileManagerVM.search(
			pattern: "SelectedFilesPanelViewModel",
			mode: .content,
			isRegex: false,
			paths: ["RepoPrompt/ViewModels/SelectedFilesPanelViewModel.swift"]
		)
		
		XCTAssertEqual(
			Set(results.matches?.map(\.filePath) ?? []),
			Set([literalFileURL.path])
		)
	}
	
	@MainActor
	func testLeadingSlashRootAliasFolderInputResolvesRootRelativeFolder() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("RepoPrompt", isDirectory: true)
		let rootViewsURL = rootURL.appendingPathComponent("Views", isDirectory: true)
		let shadowViewsURL = rootURL.appendingPathComponent("RepoPrompt/Views", isDirectory: true)
		try FileManager.default.createDirectory(at: rootViewsURL, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: shadowViewsURL, withIntermediateDirectories: true)
		try "root".write(
			to: rootViewsURL.appendingPathComponent("Root.swift"),
			atomically: true,
			encoding: .utf8
		)
		try "shadow".write(
			to: shadowViewsURL.appendingPathComponent("Shadow.swift"),
			atomically: true,
			encoding: .utf8
		)
		defer { try? FileManager.default.removeItem(at: tempParent) }
		
		let workspace = WorkspaceModel(name: "Test", repoPaths: [rootURL.path])
		let fileManagerVM = RepoFileManagerViewModel()
		try await fileManagerVM.loadFolder(at: rootURL, for: workspace, freshStart: true)
		
		let resolution = await fileManagerVM.resolveFilesForFolderInput("/RepoPrompt/Views")
		XCTAssertTrue(resolution.handled)
		XCTAssertEqual(
			Set(resolution.files.map(\.standardizedFullPath)),
			Set([rootViewsURL.appendingPathComponent("Root.swift").path])
		)
	}
	
	@MainActor
	func testSearchLeadingSlashRootAliasFolderPathResolvesRootRelativeFolder() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("RepoPrompt", isDirectory: true)
		let rootViewsURL = rootURL.appendingPathComponent("Views", isDirectory: true)
		let shadowViewsURL = rootURL.appendingPathComponent("RepoPrompt/Views", isDirectory: true)
		try FileManager.default.createDirectory(at: rootViewsURL, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: shadowViewsURL, withIntermediateDirectories: true)
		try "struct Root {}".write(
			to: rootViewsURL.appendingPathComponent("Root.swift"),
			atomically: true,
			encoding: .utf8
		)
		try "struct Shadow {}".write(
			to: shadowViewsURL.appendingPathComponent("Shadow.swift"),
			atomically: true,
			encoding: .utf8
		)
		defer { try? FileManager.default.removeItem(at: tempParent) }
		
		let workspace = WorkspaceModel(name: "Test", repoPaths: [rootURL.path])
		let fileManagerVM = RepoFileManagerViewModel()
		try await fileManagerVM.loadFolder(at: rootURL, for: workspace, freshStart: true)
		
		let results = try await fileManagerVM.search(
			pattern: "struct",
			mode: .content,
			isRegex: false,
			paths: ["/RepoPrompt/Views"]
		)
		
		XCTAssertEqual(
			Set(results.matches?.map(\.filePath) ?? []),
			Set([rootViewsURL.appendingPathComponent("Root.swift").path])
		)
	}
	
	@MainActor
	func testSearchLeadingSlashRootAliasWildcardPathResolvesRootRelativeFolder() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("RepoPrompt", isDirectory: true)
		let rootViewsURL = rootURL.appendingPathComponent("Views", isDirectory: true)
		let shadowViewsURL = rootURL.appendingPathComponent("RepoPrompt/Views", isDirectory: true)
		try FileManager.default.createDirectory(at: rootViewsURL, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: shadowViewsURL, withIntermediateDirectories: true)
		try "struct Root {}".write(
			to: rootViewsURL.appendingPathComponent("Root.swift"),
			atomically: true,
			encoding: .utf8
		)
		try "struct Shadow {}".write(
			to: shadowViewsURL.appendingPathComponent("Shadow.swift"),
			atomically: true,
			encoding: .utf8
		)
		defer { try? FileManager.default.removeItem(at: tempParent) }
		
		let workspace = WorkspaceModel(name: "Test", repoPaths: [rootURL.path])
		let fileManagerVM = RepoFileManagerViewModel()
		try await fileManagerVM.loadFolder(at: rootURL, for: workspace, freshStart: true)
		
		let results = try await fileManagerVM.search(
			pattern: "struct",
			mode: .content,
			isRegex: false,
			paths: ["/RepoPrompt/Views/*"]
		)
		
		XCTAssertEqual(
			Set(results.matches?.map(\.filePath) ?? []),
			Set([rootViewsURL.appendingPathComponent("Root.swift").path])
		)
	}
	
	@MainActor
	func testLeadingSlashRootAliasPrefersMatchingProtectedAliasName() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("tmp", isDirectory: true)
		let rootViewsURL = rootURL.appendingPathComponent("Views", isDirectory: true)
		try FileManager.default.createDirectory(at: rootViewsURL, withIntermediateDirectories: true)
		try "root".write(
			to: rootViewsURL.appendingPathComponent("Root.swift"),
			atomically: true,
			encoding: .utf8
		)
		defer { try? FileManager.default.removeItem(at: tempParent) }
		
		let workspace = WorkspaceModel(name: "Test", repoPaths: [rootURL.path])
		let fileManagerVM = RepoFileManagerViewModel()
		try await fileManagerVM.loadFolder(at: rootURL, for: workspace, freshStart: true)
		
		let resolution = await fileManagerVM.resolveFilesForFolderInput("/tmp/Views")
		XCTAssertTrue(resolution.handled)
		XCTAssertEqual(
			Set(resolution.files.map(\.standardizedFullPath)),
			Set([rootViewsURL.appendingPathComponent("Root.swift").path])
		)
	}
	
	@MainActor
	func testLiteralProtectedTopLevelAbsolutePathStillReportsOutsideWhenAliasDoesNotMatch() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("Workspace", isDirectory: true)
		let rootViewsURL = rootURL.appendingPathComponent("Views", isDirectory: true)
		try FileManager.default.createDirectory(at: rootViewsURL, withIntermediateDirectories: true)
		try "root".write(
			to: rootViewsURL.appendingPathComponent("Root.swift"),
			atomically: true,
			encoding: .utf8
		)
		defer { try? FileManager.default.removeItem(at: tempParent) }
		
		let workspace = WorkspaceModel(name: "Test", repoPaths: [rootURL.path])
		let fileManagerVM = RepoFileManagerViewModel()
		try await fileManagerVM.loadFolder(at: rootURL, for: workspace, freshStart: true)
		
		let resolution = await fileManagerVM.resolveFilesForFolderInput("/tmp/Views")
		XCTAssertFalse(resolution.handled)
		guard case .pathOutsideWorkspace? = resolution.issue else {
			return XCTFail("Expected pathOutsideWorkspace, got \(String(describing: resolution.issue))")
		}
	}
	
	@MainActor
	func testSearchAbsoluteFolderPathResolvesLiteralSameNameSubfolder() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("RepoPrompt", isDirectory: true)
		let nestedViewsURL = rootURL.appendingPathComponent("RepoPrompt/Views", isDirectory: true)
		let sourcesURL = rootURL.appendingPathComponent("Sources", isDirectory: true)
		try FileManager.default.createDirectory(at: nestedViewsURL, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: sourcesURL, withIntermediateDirectories: true)
		try "struct Scoped {}".write(
			to: nestedViewsURL.appendingPathComponent("Scoped.swift"),
			atomically: true,
			encoding: .utf8
		)
		try "struct Other {}".write(
			to: sourcesURL.appendingPathComponent("Other.swift"),
			atomically: true,
			encoding: .utf8
		)
		defer { try? FileManager.default.removeItem(at: tempParent) }
		
		let workspace = WorkspaceModel(name: "Test", repoPaths: [rootURL.path])
		let fileManagerVM = RepoFileManagerViewModel()
		try await fileManagerVM.loadFolder(at: rootURL, for: workspace, freshStart: true)
		
		XCTAssertNotNil(fileManagerVM.findFolderByFullPath(nestedViewsURL.path))
		let normalized = await fileManagerVM.normalizeFilterPaths([nestedViewsURL.path])
		XCTAssertEqual(normalized, [nestedViewsURL.path])
		
		let results = try await fileManagerVM.search(
			pattern: "struct",
			mode: .content,
			isRegex: false,
			paths: [nestedViewsURL.path]
		)
		
		XCTAssertEqual(
			Set(results.matches?.map(\.filePath) ?? []),
			Set([nestedViewsURL.appendingPathComponent("Scoped.swift").path])
		)
	}
	
	@MainActor
	func testSearchAbsolutePathInsideLoadedRootButMissingFolderReportsUnresolved() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("RepoPrompt", isDirectory: true)
		let nestedViewsURL = rootURL.appendingPathComponent("RepoPrompt/Views", isDirectory: true)
		try FileManager.default.createDirectory(at: nestedViewsURL, withIntermediateDirectories: true)
		try "struct Scoped {}".write(
			to: nestedViewsURL.appendingPathComponent("Scoped.swift"),
			atomically: true,
			encoding: .utf8
		)
		defer { try? FileManager.default.removeItem(at: tempParent) }
		
		let workspace = WorkspaceModel(name: "Test", repoPaths: [rootURL.path])
		let fileManagerVM = RepoFileManagerViewModel()
		try await fileManagerVM.loadFolder(at: rootURL, for: workspace, freshStart: true)
		
		let missingViewsPath = rootURL.appendingPathComponent("Views", isDirectory: true).path
		XCTAssertNil(fileManagerVM.findFolderByFullPath(missingViewsPath))
		XCTAssertNotNil(fileManagerVM.findFolderByFullPath(nestedViewsURL.path))
		
		let normalized = await fileManagerVM.normalizeFilterPaths([missingViewsPath])
		XCTAssertEqual(normalized, [missingViewsPath])
		
		do {
			_ = try await fileManagerVM.search(
				pattern: "struct",
				mode: .content,
				isRegex: false,
				paths: [missingViewsPath]
			)
			XCTFail("Expected unresolved path error")
		} catch {
			let message = renderedMessage(for: error)
			XCTAssertTrue(
				message.contains("Could not resolve '\(missingViewsPath)'"),
				"Unexpected error: \(message)"
			)
			XCTAssertFalse(
				message.contains("not inside any loaded folder"),
				"Unexpected error: \(message)"
			)
		}
	}

	@MainActor
	func testAbsoluteMissingFolderInsideLoadedRootWinsOverPseudoAliasClassification() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("RepoPrompt", isDirectory: true)
		let nestedViewsURL = rootURL.appendingPathComponent("RepoPrompt/Views", isDirectory: true)
		let absoluteLeadingComponent = rootURL.path.split(separator: "/").dropFirst().first.map(String.init) ?? "var"
		let aliasRootURL = tempParent.appendingPathComponent(absoluteLeadingComponent, isDirectory: true)
		try FileManager.default.createDirectory(at: nestedViewsURL, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: aliasRootURL, withIntermediateDirectories: true)
		try "struct Scoped {}".write(
			to: nestedViewsURL.appendingPathComponent("Scoped.swift"),
			atomically: true,
			encoding: .utf8
		)
		defer { try? FileManager.default.removeItem(at: tempParent) }
		
		let workspace = WorkspaceModel(name: "Test", repoPaths: [rootURL.path, aliasRootURL.path])
		let fileManagerVM = RepoFileManagerViewModel()
		try await fileManagerVM.loadFolder(at: rootURL, for: workspace, freshStart: true)
		try await fileManagerVM.loadFolder(at: aliasRootURL, for: workspace, freshStart: false)
		
		let missingViewsPath = rootURL.appendingPathComponent("Views", isDirectory: true).path
		let resolution = await fileManagerVM.resolveFilesForFolderInput(missingViewsPath)
		XCTAssertFalse(resolution.handled)
		guard let issue = resolution.issue else {
			return XCTFail("Expected unresolved issue")
		}
		let message = PathResolutionIssueRenderer.message(for: issue)
		XCTAssertTrue(
			message.contains("Could not resolve '\(missingViewsPath)'"),
			"Unexpected error: \(message)"
		)
		XCTAssertFalse(
			message.contains("looks like '/RootName/..."),
			"Unexpected error: \(message)"
		)
	}

	@MainActor
	func testBuildPromptEntriesSelectedDropsAutoCodemapAndCodemapsOnlyEligibleSelectedFiles() async throws {
		let (fileManagerVM, rootURL, _) = try await makeWorkspaceRoot(fileNames: ["A.swift", "B.swift", "C.swift"])
		defer { try? FileManager.default.removeItem(at: rootURL) }

		guard
			let fileA = fileManagerVM.findFileByRelativePath("Sources/A.swift"),
			let fileB = fileManagerVM.findFileByRelativePath("Sources/B.swift"),
			let fileC = fileManagerVM.findFileByRelativePath("Sources/C.swift")
		else {
			XCTFail("Expected files to be loaded")
			return
		}

		fileManagerVM.toggleFile(fileA)
		fileManagerVM.toggleFile(fileB)
		fileManagerVM.setFileAsCodemap(fileC)
		fileA.setCodeMap(makeMinimalFileAPI(filePath: fileA.fullPath))

		let entries = fileManagerVM.buildPromptEntries(codeMapUsage: .selected, allFileAPIs: [])
		XCTAssertEqual(entries.count, 2)

		let entryByPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.file.standardizedFullPath, $0) })
		XCTAssertNotNil(entryByPath[fileA.standardizedFullPath])
		XCTAssertNotNil(entryByPath[fileB.standardizedFullPath])
		XCTAssertNil(entryByPath[fileC.standardizedFullPath])

		XCTAssertEqual(entryByPath[fileA.standardizedFullPath]?.isCodemap, true)
		XCTAssertNil(entryByPath[fileA.standardizedFullPath]?.ranges)
		XCTAssertEqual(entryByPath[fileB.standardizedFullPath]?.isCodemap, false)
	}

	@MainActor
	func testBuildPromptEntriesCompleteAddsNonSelectedAPIsWithoutDuplicatingSelectedFiles() async throws {
		let (fileManagerVM, rootURL, _) = try await makeWorkspaceRoot(fileNames: ["A.swift", "B.swift"])
		defer { try? FileManager.default.removeItem(at: rootURL) }

		guard
			let fileA = fileManagerVM.findFileByRelativePath("Sources/A.swift"),
			let fileB = fileManagerVM.findFileByRelativePath("Sources/B.swift")
		else {
			XCTFail("Expected files to be loaded")
			return
		}

		fileManagerVM.toggleFile(fileA)

		fileB.setCodeMap(makeMinimalFileAPI(filePath: fileB.fullPath))

		let entries = fileManagerVM.buildPromptEntries(
			codeMapUsage: .complete,
			allFileAPIs: [
				makeMinimalFileAPI(filePath: fileA.fullPath),
				makeMinimalFileAPI(filePath: fileB.fullPath)
			]
		)

		let entriesForA = entries.filter { $0.file.standardizedFullPath == fileA.standardizedFullPath }
		let entriesForB = entries.filter { $0.file.standardizedFullPath == fileB.standardizedFullPath }

		XCTAssertEqual(entriesForA.count, 1)
		XCTAssertEqual(entriesForB.count, 1)
		XCTAssertEqual(entriesForB.first?.isCodemap, true)
		XCTAssertNil(entriesForB.first?.ranges)
	}

	@MainActor
	func testApplyStoredSelectionNormalizesSelectedAndAutoCodemapPaths() async throws {
		let (fileManagerVM, rootURL, _) = try await makeWorkspaceRoot(fileNames: ["A.swift", "B.swift"])
		defer { try? FileManager.default.removeItem(at: rootURL) }

		guard
			let fileA = fileManagerVM.findFileByRelativePath("Sources/A.swift"),
			let fileB = fileManagerVM.findFileByRelativePath("Sources/B.swift")
		else {
			XCTFail("Expected files to be loaded")
			return
		}

		let selectedA = fileA.standardizedFullPath
		let nonCanonicalB = rootURL.path + "/Sources//B.swift"

		await fileManagerVM.applyStoredSelection(
			StoredSelection(
				selectedPaths: [selectedA],
				autoCodemapPaths: [nonCanonicalB],
				slices: [:],
				codemapAutoEnabled: false
			)
		)

		let snapshot = fileManagerVM.snapshotSelection()
		XCTAssertEqual(snapshot.selectedPaths, [fileA.standardizedFullPath])
		XCTAssertEqual(snapshot.autoCodemapPaths, [fileB.standardizedFullPath])
	}

	@MainActor
	func testBuildPromptEntriesForStoredSelectionNormalizesStoredAndAPIPaths() async throws {
		let (fileManagerVM, rootURL, _) = try await makeWorkspaceRoot(fileNames: ["A.swift", "B.swift"])
		defer { try? FileManager.default.removeItem(at: rootURL) }

		guard
			let fileA = fileManagerVM.findFileByRelativePath("Sources/A.swift"),
			let fileB = fileManagerVM.findFileByRelativePath("Sources/B.swift")
		else {
			XCTFail("Expected files to be loaded")
			return
		}

		let nonCanonicalA = rootURL.path + "/Sources/./A.swift"
		let nonCanonicalB = rootURL.path + "/Sources/Feature/../B.swift"
		let expectedRanges = [LineRange(start: 1, end: 3)]

		let entries = fileManagerVM.buildPromptEntries(
			for: StoredSelection(
				selectedPaths: [nonCanonicalA],
				autoCodemapPaths: [],
				slices: [nonCanonicalA: expectedRanges],
				codemapAutoEnabled: false
			),
			codeMapUsage: .complete,
			allFileAPIs: [makeMinimalFileAPI(filePath: nonCanonicalB)]
		)

		let entryByPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.file.standardizedFullPath, $0) })
		XCTAssertEqual(entries.count, 2)
		XCTAssertEqual(entryByPath[fileA.standardizedFullPath]?.ranges, expectedRanges)
		XCTAssertEqual(entryByPath[fileA.standardizedFullPath]?.isCodemap, false)
		XCTAssertEqual(entryByPath[fileB.standardizedFullPath]?.isCodemap, true)
		XCTAssertNil(entryByPath[fileB.standardizedFullPath]?.ranges)
	}

	@MainActor
	func testBuildPromptEntriesForStoredSelectionPrefersCanonicalSliceKeyOverLegacyVariant() async throws {
		let (fileManagerVM, rootURL, _) = try await makeWorkspaceRoot(fileNames: ["A.swift"])
		defer { try? FileManager.default.removeItem(at: rootURL) }

		guard let fileA = fileManagerVM.findFileByRelativePath("Sources/A.swift") else {
			XCTFail("Expected file to be loaded")
			return
		}

		let canonicalPath = fileA.standardizedFullPath
		let legacyPath = rootURL.path + "/Sources/./A.swift"
		let canonicalRanges = [LineRange(start: 4, end: 6)]
		let legacyRanges = [LineRange(start: 1, end: 2)]

		let entries = fileManagerVM.buildPromptEntries(
			for: StoredSelection(
				selectedPaths: [legacyPath],
				autoCodemapPaths: [],
				slices: [
					legacyPath: legacyRanges,
					canonicalPath: canonicalRanges
				],
				codemapAutoEnabled: false
			),
			codeMapUsage: .auto,
			allFileAPIs: []
		)

		XCTAssertEqual(entries.count, 1)
		XCTAssertEqual(entries.first?.file.standardizedFullPath, canonicalPath)
		XCTAssertEqual(entries.first?.ranges, canonicalRanges)
	}

	func testTokenEvaluationIgnoresRestoredAutoCodemapStateWhenCodeMapUsageIsNone() async throws {
		let (fileManagerVM, rootURL, _) = try await makeWorkspaceRoot(fileNames: ["A.swift", "B.swift"])
		defer { try? FileManager.default.removeItem(at: rootURL) }

		guard
			let fileA = await MainActor.run(body: { fileManagerVM.findFileByRelativePath("Sources/A.swift") }),
			let fileB = await MainActor.run(body: { fileManagerVM.findFileByRelativePath("Sources/B.swift") })
		else {
			XCTFail("Expected files to be loaded")
			return
		}

		await MainActor.run {
			fileB.setCodeMap(makeMinimalFileAPI(filePath: fileB.fullPath))
		}

		await fileManagerVM.applyStoredSelection(
			StoredSelection(
				selectedPaths: [fileA.standardizedFullPath],
				autoCodemapPaths: [fileB.standardizedFullPath],
				slices: [:],
				codemapAutoEnabled: false
			)
		)

		let entries = await MainActor.run {
			fileManagerVM.buildPromptEntries(codeMapUsage: .none, allFileAPIs: [])
		}
		let snapshots = await MainActor.run {
			entries.map { entry in
				PromptFileEntrySnapshot(
					fileID: entry.file.id,
					relativePath: entry.file.relativePath,
					isCodemapRequested: entry.isCodemap,
					ranges: entry.ranges,
					cachedFullTokenCount: entry.file.cachedTokenCount,
					loadedContent: nil,
					codeMapContent: entry.isCodemap ? entry.file.fileAPI?.getFullAPIDescription(displayPath: entry.file.relativePath) : nil,
					availableCodeMapTokenCount: entry.file.fileAPI?.apiTokenCount ?? 0
				)
			}
		}

		let evaluation = await TokenCalculationService().evaluatePromptEntries(snapshots)

		XCTAssertEqual(evaluation.codeMapFileCount, 0)
		XCTAssertEqual(evaluation.codeMapTokenCount, 0)
		XCTAssertTrue(evaluation.codeMapContent.isEmpty)
	}

	@MainActor
	func testComputeSelectedIDsNormalizesStoredPaths() async throws {
		let (fileManagerVM, rootURL, _) = try await makeWorkspaceRoot(fileNames: ["A.swift"])
		defer { try? FileManager.default.removeItem(at: rootURL) }

		guard let fileA = fileManagerVM.findFileByRelativePath("Sources/A.swift") else {
			XCTFail("Expected file to be loaded")
			return
		}

		let stored = StoredSelection(
			selectedPaths: [rootURL.path + "/Sources/./Nested/../A.swift"],
			autoCodemapPaths: [],
			slices: [:],
			codemapAutoEnabled: false
		)

		XCTAssertEqual(fileManagerVM.computeSelectedIDs(from: stored), [fileA.id])
	}

	@MainActor
	func testHasAnySlicesForFileDetectsPersistedOnlyScopeEntry() async throws {
		let (fileManagerVM, rootURL, workspace) = try await makeWorkspaceRoot()
		defer { try? FileManager.default.removeItem(at: rootURL) }

		guard let file = fileManagerVM.findFileByRelativePath("Sources/A.swift") else {
			XCTFail("Expected file to be loaded")
			return
		}

		let legacyScope = PartitionScope(workspaceID: workspace.id)
		let relKey = (file.relativePath as NSString).standardizingPath
		let rootKey = (file.rootFolderPath as NSString).standardizingPath

		let before = await fileManagerVM._testHasAnySlicesForFile(file)
		XCTAssertFalse(before)

		try await fileManagerVM._testPersistSlicesForScope(
			rootPath: rootKey,
			scope: legacyScope,
			relativePath: relKey,
			ranges: [LineRange(start: 2, end: 4)]
		)

		let after = await fileManagerVM._testHasAnySlicesForFile(file)
		XCTAssertTrue(after, "Persisted slices in non-active scope should still be detected.")
	}

	@MainActor
	func testSliceRebasePrefilterCacheSkipsOnlyUntilPartitionRevisionChanges() async throws {
		let (fileManagerVM, rootURL, _) = try await makeWorkspaceRoot()
		defer { try? FileManager.default.removeItem(at: rootURL) }

		guard let file = fileManagerVM.findFileByRelativePath("Sources/A.swift") else {
			XCTFail("Expected file to be loaded")
			return
		}

		XCTAssertTrue(fileManagerVM._testShouldScheduleSliceRebase(file))

		fileManagerVM._testMarkKnownNoSlices(file)
		XCTAssertFalse(
			fileManagerVM._testShouldScheduleSliceRebase(file),
			"Known no-slices result should suppress scheduling until a save revision changes."
		)

		fileManagerVM._testBumpPartitionSliceSaveRevision()
		XCTAssertTrue(
			fileManagerVM._testShouldScheduleSliceRebase(file),
			"Any partition save revision bump should invalidate no-slices cache conservatively."
		)
	}

	@MainActor
	func testHydrateSlicesForActiveTabReplacesChangedPersistedRangesAndClearsAnchors() async throws {
		let (fileManagerVM, rootURL, workspace) = try await makeWorkspaceRoot()
		defer {
			cleanupPartitionStore(for: rootURL.path)
			try? FileManager.default.removeItem(at: rootURL)
		}

		guard let file = fileManagerVM.findFileByRelativePath("Sources/A.swift") else {
			XCTFail("Expected file to be loaded")
			return
		}

		let scope = PartitionScope(workspaceID: workspace.id, tabID: UUID())
		let rootKey = file.standardizedRootFolderPath
		let relKey = file.standardizedRelativePath
		let staleRange = LineRange(start: 1, end: 2)
		let desiredRanges = [staleRange, LineRange(start: 5, end: 6)]
		let staleAnchor = sliceAnchor(range: staleRange, tag: "stale")
		let store = PartitionStore()

		_ = try await store.apply(
			forRoot: rootKey,
			scope: scope,
			updates: [
				relKey: PartitionStore.SliceUpdate(
					ranges: [staleRange],
					fileModificationTime: 11,
					anchors: [staleAnchor]
				)
			],
			mode: .set
		)

		fileManagerVM.setCurrentWorkspaceID(workspace.id)
		fileManagerVM.setActiveTabID(scope.tabID)

		let selection = StoredSelection(
			selectedPaths: [file.standardizedFullPath],
			autoCodemapPaths: [],
			slices: [file.standardizedFullPath: desiredRanges],
			codemapAutoEnabled: false
		)

		await fileManagerVM.applyStoredSelection(selection)
		await fileManagerVM.hydrateSlicesForActiveTab(from: selection)

		XCTAssertEqual(fileManagerVM.selectionSlices(for: file), desiredRanges)
		XCTAssertEqual(fileManagerVM.snapshotSelection().slices[file.standardizedFullPath], desiredRanges)

		let persisted = await store.load(forRoot: rootKey, scope: scope).files[relKey]
		XCTAssertEqual(persisted?.ranges, desiredRanges)
		XCTAssertNil(persisted?.anchors)
	}

	@MainActor
	func testHydrateSlicesForActiveTabPreservesUnchangedPersistedAnchors() async throws {
		let (fileManagerVM, rootURL, workspace) = try await makeWorkspaceRoot()
		defer {
			cleanupPartitionStore(for: rootURL.path)
			try? FileManager.default.removeItem(at: rootURL)
		}

		guard let file = fileManagerVM.findFileByRelativePath("Sources/A.swift") else {
			XCTFail("Expected file to be loaded")
			return
		}

		let scope = PartitionScope(workspaceID: workspace.id, tabID: UUID())
		let rootKey = file.standardizedRootFolderPath
		let relKey = file.standardizedRelativePath
		let desiredRange = LineRange(start: 3, end: 4)
		let preservedAnchor = sliceAnchor(range: desiredRange, tag: "keep")
		let store = PartitionStore()

		_ = try await store.apply(
			forRoot: rootKey,
			scope: scope,
			updates: [
				relKey: PartitionStore.SliceUpdate(
					ranges: [desiredRange],
					fileModificationTime: 22,
					anchors: [preservedAnchor]
				)
			],
			mode: .set
		)

		fileManagerVM.setCurrentWorkspaceID(workspace.id)
		fileManagerVM.setActiveTabID(scope.tabID)

		let selection = StoredSelection(
			selectedPaths: [file.standardizedFullPath],
			autoCodemapPaths: [],
			slices: [file.standardizedFullPath: [desiredRange]],
			codemapAutoEnabled: false
		)

		await fileManagerVM.applyStoredSelection(selection)
		await fileManagerVM.hydrateSlicesForActiveTab(from: selection)

		XCTAssertEqual(fileManagerVM.selectionSlices(for: file), [desiredRange])

		let persisted = await store.load(forRoot: rootKey, scope: scope).files[relKey]
		XCTAssertEqual(persisted?.ranges, [desiredRange])
		XCTAssertEqual(persisted?.anchors, [preservedAnchor])
	}

	@MainActor
	func testHydrateSlicesForActiveTabRemovesPersistedEntriesMissingFromStoredSelection() async throws {
		let (fileManagerVM, rootURL, workspace) = try await makeWorkspaceRoot()
		defer {
			cleanupPartitionStore(for: rootURL.path)
			try? FileManager.default.removeItem(at: rootURL)
		}

		guard let file = fileManagerVM.findFileByRelativePath("Sources/A.swift") else {
			XCTFail("Expected file to be loaded")
			return
		}

		let scope = PartitionScope(workspaceID: workspace.id, tabID: UUID())
		let rootKey = file.standardizedRootFolderPath
		let relKey = file.standardizedRelativePath
		let staleRange = LineRange(start: 7, end: 8)
		let store = PartitionStore()

		_ = try await store.apply(
			forRoot: rootKey,
			scope: scope,
			updates: [
				relKey: PartitionStore.SliceUpdate(
					ranges: [staleRange],
					fileModificationTime: 33,
					anchors: [sliceAnchor(range: staleRange, tag: "drop")]
				)
			],
			mode: .set
		)

		fileManagerVM.setCurrentWorkspaceID(workspace.id)
		fileManagerVM.setActiveTabID(scope.tabID)

		let selection = StoredSelection(
			selectedPaths: [file.standardizedFullPath],
			autoCodemapPaths: [],
			slices: [:],
			codemapAutoEnabled: false
		)

		await fileManagerVM.applyStoredSelection(selection)
		await fileManagerVM.hydrateSlicesForActiveTab(from: selection)

		XCTAssertNil(fileManagerVM.selectionSlices(for: file))
		XCTAssertNil(fileManagerVM.snapshotSelection().slices[file.standardizedFullPath])

		let persisted = await store.load(forRoot: rootKey, scope: scope).files[relKey]
		XCTAssertNil(persisted)
	}
}


extension RepoFileManagerTests {
	@MainActor
	private func makeIndexedFileVM(
		name: String,
		fullPath: String,
		rootFolder: FolderViewModel,
		service: FileSystemService,
		parentFolder: FolderViewModel? = nil,
		hierarchyLevel: Int = 0
	) -> FileViewModel {
		FileViewModel(
			file: File(name: name, path: fullPath, modificationDate: Date()),
			rootPath: rootFolder.standardizedFullPath,
			hierarchyLevel: hierarchyLevel,
			rootIdentifier: rootFolder.id,
			rootFolderPath: rootFolder.standardizedFullPath,
			fileSystemService: service,
			parentFolder: parentFolder
		)
	}

	@MainActor
	private func makeDateSortFolder(
		name: String,
		rootPath: String,
		modificationDate: Date,
		hierarchyLevel: Int = 1,
		sortMethod: SortMethod = .dateNewest
	) -> FolderViewModel {
		FolderViewModel(
			folder: Folder(name: name, path: "\(rootPath)/\(name)", modificationDate: modificationDate),
			rootPath: rootPath,
			hierarchyLevel: hierarchyLevel,
			isExpanded: true,
			sortMethod: sortMethod
		)
	}

	@MainActor
	private func makeDateSortFile(
		name: String,
		rootFolder: FolderViewModel,
		service: FileSystemService,
		modificationDate: Date
	) -> FileViewModel {
		FileViewModel(
			file: File(name: name, path: "\(rootFolder.standardizedFullPath)/\(name)", modificationDate: modificationDate),
			rootPath: rootFolder.standardizedFullPath,
			hierarchyLevel: 1,
			rootIdentifier: rootFolder.id,
			rootFolderPath: rootFolder.standardizedFullPath,
			fileSystemService: service,
			parentFolder: rootFolder
		)
	}

	private func makeTestFileSystemService(path: String) async throws -> FileSystemService {
		try await FileSystemService(
			path: path,
			respectGitignore: false,
			skipSymlinks: true,
			isTestMode: true
		)
	}

	private func syntheticFolderName(index: Int, namePayloadLength: Int = 0) -> String {
		guard namePayloadLength > 0 else { return "Folder\(index)" }
		return "Folder\(index)-\(String(repeating: "f", count: namePayloadLength))"
	}

	private func syntheticFileName(index: Int, namePayloadLength: Int = 0) -> String {
		guard namePayloadLength > 0 else { return "File\(index).swift" }
		return "File\(index)-\(String(repeating: "x", count: namePayloadLength)).swift"
	}

	private func syntheticFileRelativePath(
		folderIndex: Int,
		fileIndex: Int = 0,
		namePayloadLength: Int = 0
	) -> String {
		"\(syntheticFolderName(index: folderIndex, namePayloadLength: namePayloadLength))/\(syntheticFileName(index: fileIndex, namePayloadLength: namePayloadLength))"
	}

	@MainActor
	private func makeSyntheticRoot(
		at rootURL: URL,
		service: FileSystemService,
		folderCount: Int,
		filesPerFolder: Int,
		isSystemRoot: Bool = false,
		namePayloadLength: Int = 0
	) -> FolderViewModel {
		let rootFolder = FolderViewModel(
			folder: Folder(name: rootURL.lastPathComponent, path: rootURL.path, modificationDate: Date()),
			rootPath: rootURL.path,
			isExpanded: true,
			isSystemRoot: isSystemRoot
		)

		for folderIndex in 0..<folderCount {
			let folderName = syntheticFolderName(index: folderIndex, namePayloadLength: namePayloadLength)
			let folderURL = rootURL.appendingPathComponent(folderName, isDirectory: true)
			let subfolder = FolderViewModel(
				folder: Folder(name: folderURL.lastPathComponent, path: folderURL.path, modificationDate: Date()),
				rootPath: rootURL.path,
				hierarchyLevel: 1,
				isExpanded: true,
				isSystemRoot: isSystemRoot
			)
			for fileIndex in 0..<filesPerFolder {
				let fileName = syntheticFileName(index: fileIndex, namePayloadLength: namePayloadLength)
				let fileURL = folderURL.appendingPathComponent(fileName)
				let fileVM = makeIndexedFileVM(
					name: fileURL.lastPathComponent,
					fullPath: fileURL.path,
					rootFolder: rootFolder,
					service: service,
					parentFolder: subfolder,
					hierarchyLevel: 1
				)
				subfolder.addFile(fileVM)
			}
			rootFolder.addSubfolder(subfolder)
		}

		return rootFolder
	}

	private func sliceAnchor(range: LineRange, tag: String) -> SliceAnchor {
		SliceAnchor(
			range: range,
			startSignature: ["\(tag)-start"],
			endSignature: ["\(tag)-end"]
		)
	}

	private func cleanupPartitionStore(for rootPath: String) {
		try? FileManager.default.removeItem(at: partitionDirectoryURL(for: rootPath))
	}

	private func partitionDirectoryURL(for rootPath: String) -> URL {
		let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
		let standardized = (rootPath as NSString).standardizingPath
		let leaf = (standardized as NSString).lastPathComponent
		let digest = SHA256.hash(data: Data(standardized.utf8))
		let hex = digest.map { String(format: "%02x", $0) }.joined()
		let repoKey = "\(leaf)-\(String(hex.prefix(12)))"
		return base.appendingPathComponent("RepoPrompt/Partitions/\(repoKey)", isDirectory: true)
	}

	@MainActor
	private func makeRootWithFile(isExpanded: Bool = true) async throws -> (RepoFileManagerViewModel, FolderViewModel, FileViewModel) {
		let fileManagerVM = RepoFileManagerViewModel()
		let rootPath = "/test/root"
		let rootFolder = Folder(name: "root", path: rootPath, modificationDate: Date())
		let rootFolderVM = FolderViewModel(folder: rootFolder, rootPath: rootPath, isExpanded: isExpanded)
		let tempDir = FileManager.default.temporaryDirectory
		let fileSystemService = try await FileSystemService(
			path: tempDir.path,
			respectGitignore: false,
			skipSymlinks: true
		)
		let file = File(name: "a.txt", path: "\(rootPath)/a.txt", modificationDate: Date())
		let fileVM = FileViewModel(
			file: file,
			rootPath: rootPath,
			hierarchyLevel: 0,
			rootIdentifier: rootFolderVM.id,
			rootFolderPath: rootPath,
			fileSystemService: fileSystemService
		)
		rootFolderVM.addFile(fileVM)
		fileManagerVM.addRootFolder(rootFolderVM)
		return (fileManagerVM, rootFolderVM, fileVM)
	}

	@MainActor
	func testGetAllFileViewModelsHandlesSelfCycle() async throws {
		let (fileManagerVM, rootFolderVM, fileVM) = try await makeRootWithFile()
		rootFolderVM.addSubfolder(rootFolderVM)
		let allFiles = fileManagerVM.getAllFileViewModels()
		XCTAssertEqual(allFiles.count, 1)
		XCTAssertEqual(allFiles.first?.id, fileVM.id)
	}

	@MainActor
	func testCollectAllFilesWithCodemapsUsesIndexedSnapshot() async throws {
		let (fileManagerVM, rootFolderVM, fileVM) = try await makeRootWithFile()
		rootFolderVM.addSubfolder(rootFolderVM)
		fileVM.setCodeMap(FileAPI(
			filePath: fileVM.fullPath,
			imports: [],
			classes: [],
			functions: [],
			enums: [],
			globalVars: [],
			macros: [],
			referencedTypes: []
		))
		fileManagerVM.registerRootFolderForTesting(rootFolderVM)

		let files = fileManagerVM.collectAllFilesWithCodemaps()
		XCTAssertEqual(files.count, 1)
		XCTAssertEqual(files.first?.id, fileVM.id)
	}

	@MainActor
	func testFindParentFolderAvoidsCycle() async throws {
		let rootPath = "/test/root"
		let rootFolder = Folder(name: "root", path: rootPath, modificationDate: Date())
		let childFolder = Folder(name: "child", path: "\(rootPath)/child", modificationDate: Date())
		let rootFolderVM = FolderViewModel(folder: rootFolder, rootPath: rootPath, isExpanded: true)
		let childFolderVM = FolderViewModel(folder: childFolder, rootPath: rootPath, hierarchyLevel: 1, isExpanded: true)
		let fileManagerVM = RepoFileManagerViewModel()
		rootFolderVM.addSubfolder(childFolderVM)
		childFolderVM.addSubfolder(rootFolderVM)
		fileManagerVM.addRootFolder(rootFolderVM)
		let parent = await fileManagerVM.findParentFolder(for: rootFolderVM)
		XCTAssertEqual(parent?.id, childFolderVM.id)
	}

	@MainActor
	func testFindFullPathHandlesSelfCycle() async throws {
		let (fileManagerVM, rootFolderVM, fileVM) = try await makeRootWithFile()
		rootFolderVM.addSubfolder(rootFolderVM)
		let fullPath = fileManagerVM.findFullPath(for: fileVM.relativePath)
		XCTAssertEqual(fullPath, fileVM.fullPath)
	}

	@MainActor
	func testGetFilesRecursivelyHandlesSelfCycle() async throws {
		let (fileManagerVM, rootFolderVM, fileVM) = try await makeRootWithFile()
		rootFolderVM.addSubfolder(rootFolderVM)
		let files = fileManagerVM.getFilesRecursively(under: rootFolderVM)
		XCTAssertEqual(files.count, 1)
		XCTAssertEqual(files.first?.id, fileVM.id)
	}

	@MainActor
	func testExpandCollapseAllHandlesSelfCycle() async throws {
		let (fileManagerVM, rootFolderVM, _) = try await makeRootWithFile(isExpanded: false)
		rootFolderVM.addSubfolder(rootFolderVM)
		fileManagerVM.expandAllChildren(of: rootFolderVM)
		XCTAssertTrue(rootFolderVM.isExpanded)
		fileManagerVM.collapseAllChildren(of: rootFolderVM)
		XCTAssertFalse(rootFolderVM.isExpanded)
	}

	@MainActor
	func testFileViewModelUsesStandardizedRootNameAndRelativeOverride() async throws {
		let service = try await makeTestFileSystemService(path: FileManager.default.temporaryDirectory.path)
		let file = File(name: "File.swift", path: "/Users/me/repo/File.swift", modificationDate: Date())
		let fileVM = FileViewModel(
			file: file,
			rootPath: "/Users/me/repo/./Sources/..",
			hierarchyLevel: 0,
			rootIdentifier: UUID(),
			rootFolderPath: "/Users/me/repo/./Sources/..",
			fileSystemService: service,
			relativePathOverride: "./Sources/Feature/../File.swift"
		)

		XCTAssertEqual(fileVM.standardizedRootFolderPath, "/Users/me/repo")
		XCTAssertEqual(fileVM.rootFolderName, "repo")
		XCTAssertEqual(fileVM.relativePath, "Sources/File.swift")
		XCTAssertEqual(fileVM.standardizedRelativePath, "Sources/File.swift")
		XCTAssertEqual(fileVM.uniqueRelativePath, "repo/Sources/File.swift")
	}

	@MainActor
	func testFolderViewModelNormalizesRelativePathOverride() {
		let folder = Folder(
			name: "Feature",
			path: "/Users/me/repo/Sources/Feature",
			modificationDate: Date()
		)
		let folderVM = FolderViewModel(
			folder: folder,
			rootPath: "/Users/me/repo/./Sources/..",
			relativePathOverride: "./Sources/Inner/../Feature"
		)

		XCTAssertEqual(folderVM.standardizedFullPath, "/Users/me/repo/Sources/Feature")
		XCTAssertEqual(folderVM.relativePath, "Sources/Feature")
	}

	@MainActor
	func testFolderDateNewestNoOpUpdateDoesNotMutateParentChildren() {
		let rootPath = "/test/root"
		let root = makeDateSortFolder(
			name: "root",
			rootPath: rootPath,
			modificationDate: Date(timeIntervalSince1970: 0),
			hierarchyLevel: 0,
			sortMethod: .dateNewest
		)
		let newest = makeDateSortFolder(name: "Newest", rootPath: rootPath, modificationDate: Date(timeIntervalSince1970: 300))
		let middle = makeDateSortFolder(name: "Middle", rootPath: rootPath, modificationDate: Date(timeIntervalSince1970: 200))
		let oldest = makeDateSortFolder(name: "Oldest", rootPath: rootPath, modificationDate: Date(timeIntervalSince1970: 100))
		root.addSubfolder(oldest)
		root.addSubfolder(newest)
		root.addSubfolder(middle)
		XCTAssertEqual(root.subfolders.map(\.name), ["Newest", "Middle", "Oldest"])
		let initialSubfolderIDs = root.subfolders.map(\.id)
		let initialChildIDs = root.children.map(\.id)

		var parentChangeCount = 0
		let cancellable = root.objectWillChange.sink {
			parentChangeCount += 1
		}
		defer { cancellable.cancel() }

		let middleNoOpDate = Date(timeIntervalSince1970: 150)
		middle.setModificationDate(middleNoOpDate)

		XCTAssertEqual(middle.modificationDate, middleNoOpDate)
		XCTAssertEqual(root.subfolders.map(\.id), initialSubfolderIDs)
		XCTAssertEqual(root.children.map(\.id), initialChildIDs)
		XCTAssertEqual(parentChangeCount, 0)

		let newestBoundaryNoOpDate = Date(timeIntervalSince1970: 250)
		newest.setModificationDate(newestBoundaryNoOpDate)

		XCTAssertEqual(newest.modificationDate, newestBoundaryNoOpDate)
		XCTAssertEqual(root.subfolders.map(\.id), initialSubfolderIDs)
		XCTAssertEqual(root.children.map(\.id), initialChildIDs)
		XCTAssertEqual(parentChangeCount, 0)
	}

	@MainActor
	func testFileDateOldestNoOpUpdateDoesNotMutateParentChildren() async throws {
		let service = try await makeTestFileSystemService(path: FileManager.default.temporaryDirectory.path)
		let rootPath = "/test/root"
		let root = makeDateSortFolder(
			name: "root",
			rootPath: rootPath,
			modificationDate: Date(timeIntervalSince1970: 0),
			hierarchyLevel: 0,
			sortMethod: .dateOldest
		)
		let oldest = makeDateSortFile(name: "Oldest.swift", rootFolder: root, service: service, modificationDate: Date(timeIntervalSince1970: 100))
		let middle = makeDateSortFile(name: "Middle.swift", rootFolder: root, service: service, modificationDate: Date(timeIntervalSince1970: 200))
		let newest = makeDateSortFile(name: "Newest.swift", rootFolder: root, service: service, modificationDate: Date(timeIntervalSince1970: 300))
		root.addFile(newest)
		root.addFile(oldest)
		root.addFile(middle)
		XCTAssertEqual(root.files.map(\.name), ["Oldest.swift", "Middle.swift", "Newest.swift"])
		let initialFileIDs = root.files.map(\.id)
		let initialChildIDs = root.children.map(\.id)

		var parentChangeCount = 0
		let cancellable = root.objectWillChange.sink {
			parentChangeCount += 1
		}
		defer { cancellable.cancel() }

		let middleNoOpDate = Date(timeIntervalSince1970: 250)
		await middle.setModificationDate(middleNoOpDate)

		XCTAssertEqual(middle.modificationDate, middleNoOpDate)
		XCTAssertEqual(root.files.map(\.id), initialFileIDs)
		XCTAssertEqual(root.children.map(\.id), initialChildIDs)
		XCTAssertEqual(parentChangeCount, 0)
	}

	@MainActor
	func testFolderDateNewestUpdateStillRepositionsWhenOrderChanges() {
		let rootPath = "/test/root"
		let root = makeDateSortFolder(
			name: "root",
			rootPath: rootPath,
			modificationDate: Date(timeIntervalSince1970: 0),
			hierarchyLevel: 0,
			sortMethod: .dateNewest
		)
		let newest = makeDateSortFolder(name: "Newest", rootPath: rootPath, modificationDate: Date(timeIntervalSince1970: 300))
		let middle = makeDateSortFolder(name: "Middle", rootPath: rootPath, modificationDate: Date(timeIntervalSince1970: 200))
		let oldest = makeDateSortFolder(name: "Oldest", rootPath: rootPath, modificationDate: Date(timeIntervalSince1970: 100))
		root.addSubfolder(newest)
		root.addSubfolder(middle)
		root.addSubfolder(oldest)

		oldest.setModificationDate(Date(timeIntervalSince1970: 400))

		XCTAssertEqual(root.subfolders.map(\.name), ["Oldest", "Newest", "Middle"])
		XCTAssertEqual(root.children.map(\.id), root.subfolders.map(\.id))
	}

	@MainActor
	func testFileDateOldestUpdateStillRepositionsWhenOrderChanges() async throws {
		let service = try await makeTestFileSystemService(path: FileManager.default.temporaryDirectory.path)
		let rootPath = "/test/root"
		let root = makeDateSortFolder(
			name: "root",
			rootPath: rootPath,
			modificationDate: Date(timeIntervalSince1970: 0),
			hierarchyLevel: 0,
			sortMethod: .dateOldest
		)
		let oldest = makeDateSortFile(name: "Oldest.swift", rootFolder: root, service: service, modificationDate: Date(timeIntervalSince1970: 100))
		let middle = makeDateSortFile(name: "Middle.swift", rootFolder: root, service: service, modificationDate: Date(timeIntervalSince1970: 200))
		let newest = makeDateSortFile(name: "Newest.swift", rootFolder: root, service: service, modificationDate: Date(timeIntervalSince1970: 300))
		root.addFile(oldest)
		root.addFile(middle)
		root.addFile(newest)

		await newest.setModificationDate(Date(timeIntervalSince1970: 50))

		XCTAssertEqual(root.files.map(\.name), ["Newest.swift", "Oldest.swift", "Middle.swift"])
		XCTAssertEqual(root.children.map(\.id), root.files.map(\.id))
	}

	@MainActor
	func testCoalesceDeltasRemovedFolderAbsorbsNormalizedDescendantsButNotSiblingPrefix() {
		let fileManagerVM = RepoFileManagerViewModel()
		let result = fileManagerVM.coalesceDeltasForTesting([
			.folderRemoved("App/./Feature"),
			.fileRemoved("App/Feature//File.swift"),
			.fileModified("App/Feature/Nested.swift", nil),
			.fileRemoved("App2/Feature.swift")
		])

		XCTAssertEqual(result.count, 2)
		XCTAssertTrue(result.contains { delta in
			if case .folderRemoved(let path) = delta { return path == "App/./Feature" }
			return false
		})
		XCTAssertTrue(result.contains { delta in
			if case .fileRemoved(let path) = delta { return path == "App2/Feature.swift" }
			return false
		})
	}

	@MainActor
	func testCoalesceDeltasKeepsChildAddsUnderAddedFolder() {
		let fileManagerVM = RepoFileManagerViewModel()
		let result = fileManagerVM.coalesceDeltasForTesting([
			.folderAdded("App"),
			.fileAdded("App/File.swift")
		])

		XCTAssertEqual(result.count, 2)
		XCTAssertTrue(result.contains { delta in
			if case .folderAdded(let path) = delta { return path == "App" }
			return false
		})
		XCTAssertTrue(result.contains { delta in
			if case .fileAdded(let path) = delta { return path == "App/File.swift" }
			return false
		})
	}

	@MainActor
	func testCoalesceDeltasFiltersMalformedAbsolutePathsBeforeMerging() {
		let fileManagerVM = RepoFileManagerViewModel()
		let result = fileManagerVM.coalesceDeltasForTesting(
			[
				.fileRemoved("tmp/RootB/B.swift"),
				.fileRemoved("/tmp/RootB/B.swift")
			],
			inRoot: "/tmp/RootA"
		)

		XCTAssertEqual(result.count, 1)
		guard case .fileRemoved(let path) = result.first else {
			return XCTFail("Expected surviving fileRemoved delta")
		}
		XCTAssertEqual(path, "tmp/RootB/B.swift")
	}

	@MainActor
	func testApplyFileSystemDeltasSkipsEscapingRelativePathThatTargetsSiblingRoot() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootAURL = tempParent.appendingPathComponent("RootA", isDirectory: true)
		let rootBURL = tempParent.appendingPathComponent("RootB", isDirectory: true)
		try FileManager.default.createDirectory(at: rootAURL, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: rootBURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let fileManagerVM = RepoFileManagerViewModel()
		let serviceA = try await makeTestFileSystemService(path: rootAURL.path)
		let serviceB = try await makeTestFileSystemService(path: rootBURL.path)

		let rootAFolder = FolderViewModel(
			folder: Folder(name: "RootA", path: rootAURL.path, modificationDate: Date()),
			rootPath: rootAURL.path,
			isExpanded: true
		)
		let rootBFolder = FolderViewModel(
			folder: Folder(name: "RootB", path: rootBURL.path, modificationDate: Date()),
			rootPath: rootBURL.path,
			isExpanded: true
		)
		let rootBFile = FileViewModel(
			file: File(name: "B.swift", path: rootBURL.appendingPathComponent("B.swift").path, modificationDate: Date()),
			rootPath: rootBURL.path,
			hierarchyLevel: 0,
			rootIdentifier: rootBFolder.id,
			rootFolderPath: rootBURL.path,
			fileSystemService: serviceB
		)
		rootBFolder.addFile(rootBFile)

		fileManagerVM.registerRootFolderForTesting(rootAFolder, service: serviceA)
		fileManagerVM.registerRootFolderForTesting(rootBFolder, service: serviceB)

		await fileManagerVM.applyFileSystemDeltasForTesting(
			[.fileRemoved("../RootB/B.swift")],
			forRootFolder: rootAFolder
		)

		XCTAssertNotNil(fileManagerVM.findFileByFullPath(rootBFile.standardizedFullPath))
	}

	@MainActor
	func testApplyFileSystemDeltasSkipsAbsoluteDeltaInput() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootAURL = tempParent.appendingPathComponent("RootA", isDirectory: true)
		let rootBURL = tempParent.appendingPathComponent("RootB", isDirectory: true)
		try FileManager.default.createDirectory(at: rootAURL, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: rootBURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let fileManagerVM = RepoFileManagerViewModel()
		let serviceA = try await makeTestFileSystemService(path: rootAURL.path)
		let serviceB = try await makeTestFileSystemService(path: rootBURL.path)

		let rootAFolder = FolderViewModel(
			folder: Folder(name: "RootA", path: rootAURL.path, modificationDate: Date()),
			rootPath: rootAURL.path,
			isExpanded: true
		)
		let rootBFolder = FolderViewModel(
			folder: Folder(name: "RootB", path: rootBURL.path, modificationDate: Date()),
			rootPath: rootBURL.path,
			isExpanded: true
		)
		let rootBFile = FileViewModel(
			file: File(name: "B.swift", path: rootBURL.appendingPathComponent("B.swift").path, modificationDate: Date()),
			rootPath: rootBURL.path,
			hierarchyLevel: 0,
			rootIdentifier: rootBFolder.id,
			rootFolderPath: rootBURL.path,
			fileSystemService: serviceB
		)
		rootBFolder.addFile(rootBFile)

		fileManagerVM.registerRootFolderForTesting(rootAFolder, service: serviceA)
		fileManagerVM.registerRootFolderForTesting(rootBFolder, service: serviceB)

		await fileManagerVM.applyFileSystemDeltasForTesting(
			[.fileRemoved(rootBFile.standardizedFullPath)],
			forRootFolder: rootAFolder
		)

		XCTAssertNotNil(fileManagerVM.findFileByFullPath(rootBFile.standardizedFullPath))
	}

	@MainActor
	func testFolderModifiedReplayUsesCarriedDateAndSkipsWhenNoDateAvailable() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("RootA", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let initialDate = Date(timeIntervalSince1970: 100)
		let carriedDate = Date(timeIntervalSince1970: 200)
		let fileManagerVM = RepoFileManagerViewModel()
		let service = try await makeTestFileSystemService(path: rootURL.path)
		let rootFolder = FolderViewModel(
			folder: Folder(name: "RootA", path: rootURL.path, modificationDate: Date()),
			rootPath: rootURL.path,
			isExpanded: true
		)
		let docsURL = rootURL.appendingPathComponent("docs", isDirectory: true)
		let docsFolder = FolderViewModel(
			folder: Folder(name: "docs", path: docsURL.path, modificationDate: initialDate),
			rootPath: rootURL.path,
			hierarchyLevel: 1,
			isExpanded: true
		)
		rootFolder.addSubfolder(docsFolder)
		fileManagerVM.registerRootFolderForTesting(rootFolder, service: service)

		await fileManagerVM.applyFileSystemDeltasForTesting(
			[.folderModified("docs", nil)],
			forRootFolder: rootFolder
		)
		XCTAssertEqual(docsFolder.modificationDate, initialDate)

		await fileManagerVM.applyFileSystemDeltasForTesting(
			[.folderModified("docs", carriedDate)],
			forRootFolder: rootFolder
		)
		XCTAssertEqual(docsFolder.modificationDate, carriedDate)
	}

	@MainActor
	func testRegisterRootFolderForTestingRebuildKeepsSiblingPrefixRootEntriesIndexed() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootAURL = tempParent.appendingPathComponent("repo", isDirectory: true)
		let rootBURL = tempParent.appendingPathComponent("repo-beta", isDirectory: true)
		try FileManager.default.createDirectory(at: rootAURL, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: rootBURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let fileManagerVM = RepoFileManagerViewModel()
		let serviceA = try await makeTestFileSystemService(path: rootAURL.path)
		let serviceB = try await makeTestFileSystemService(path: rootBURL.path)
		let rootAFolder = FolderViewModel(
			folder: Folder(name: "repo", path: rootAURL.path, modificationDate: Date()),
			rootPath: rootAURL.path,
			isExpanded: true
		)
		let rootBFolder = FolderViewModel(
			folder: Folder(name: "repo-beta", path: rootBURL.path, modificationDate: Date()),
			rootPath: rootBURL.path,
			isExpanded: true
		)
		let rootAFile = makeIndexedFileVM(
			name: "A.swift",
			fullPath: rootAURL.appendingPathComponent("A.swift").path,
			rootFolder: rootAFolder,
			service: serviceA
		)
		let rootBFile = makeIndexedFileVM(
			name: "B.swift",
			fullPath: rootBURL.appendingPathComponent("B.swift").path,
			rootFolder: rootBFolder,
			service: serviceB
		)
		rootAFolder.addFile(rootAFile)
		rootBFolder.addFile(rootBFile)

		fileManagerVM.registerRootFolderForTesting(rootAFolder, service: serviceA)
		fileManagerVM.registerRootFolderForTesting(rootBFolder, service: serviceB)
		fileManagerVM.registerRootFolderForTesting(rootAFolder, service: serviceA)

		XCTAssertNotNil(fileManagerVM.findFileByFullPath(rootAFile.standardizedFullPath))
		XCTAssertNotNil(fileManagerVM.findFileByFullPath(rootBFile.standardizedFullPath))
		XCTAssertNotNil(fileManagerVM.findFolderByFullPath(rootBFolder.standardizedFullPath))
	}

	@MainActor
	func testRegisterRootFolderForTestingRebuildDropsRemovedDescendantFolderAndFileEntries() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootAURL = tempParent.appendingPathComponent("RootA", isDirectory: true)
		let rootBURL = tempParent.appendingPathComponent("RootB", isDirectory: true)
		try FileManager.default.createDirectory(at: rootAURL, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: rootBURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let fileManagerVM = RepoFileManagerViewModel()
		let serviceA = try await makeTestFileSystemService(path: rootAURL.path)
		let serviceB = try await makeTestFileSystemService(path: rootBURL.path)
		let rootAFolder = FolderViewModel(
			folder: Folder(name: "RootA", path: rootAURL.path, modificationDate: Date()),
			rootPath: rootAURL.path,
			isExpanded: true
		)
		let rootBFolder = FolderViewModel(
			folder: Folder(name: "RootB", path: rootBURL.path, modificationDate: Date()),
			rootPath: rootBURL.path,
			isExpanded: true
		)
		let nestedFolder = FolderViewModel(
			folder: Folder(name: "Sources", path: rootAURL.appendingPathComponent("Sources", isDirectory: true).path, modificationDate: Date()),
			rootPath: rootAURL.path,
			hierarchyLevel: 1,
			isExpanded: true
		)
		let nestedFile = makeIndexedFileVM(
			name: "A.swift",
			fullPath: rootAURL.appendingPathComponent("Sources/A.swift").path,
			rootFolder: rootAFolder,
			service: serviceA,
			parentFolder: nestedFolder,
			hierarchyLevel: 1
		)
		let rootBFile = makeIndexedFileVM(
			name: "B.swift",
			fullPath: rootBURL.appendingPathComponent("B.swift").path,
			rootFolder: rootBFolder,
			service: serviceB
		)
		nestedFolder.addFile(nestedFile)
		rootAFolder.addSubfolder(nestedFolder)
		rootBFolder.addFile(rootBFile)

		fileManagerVM.registerRootFolderForTesting(rootAFolder, service: serviceA)
		fileManagerVM.registerRootFolderForTesting(rootBFolder, service: serviceB)
		XCTAssertNotNil(fileManagerVM.findFolderByFullPath(nestedFolder.standardizedFullPath))
		XCTAssertNotNil(fileManagerVM.findFileByFullPath(nestedFile.standardizedFullPath))

		rootAFolder.removeSubfolder(nestedFolder)
		fileManagerVM.registerRootFolderForTesting(rootAFolder, service: serviceA)

		XCTAssertNil(fileManagerVM.findFolderByFullPath(nestedFolder.standardizedFullPath))
		XCTAssertNil(fileManagerVM.findFileByFullPath(nestedFile.standardizedFullPath))
		XCTAssertNotNil(fileManagerVM.findFileByFullPath(rootBFile.standardizedFullPath))
	}

	@MainActor
	func testUnloadRootFolderRemovesDetachedStaleDescendantsFromIndex() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("repo", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let fileManagerVM = RepoFileManagerViewModel()
		let service = try await makeTestFileSystemService(path: rootURL.path)
		let rootFolder = FolderViewModel(
			folder: Folder(name: "repo", path: rootURL.path, modificationDate: Date()),
			rootPath: rootURL.path,
			isExpanded: true
		)
		let nestedFolder = FolderViewModel(
			folder: Folder(name: "Sources", path: rootURL.appendingPathComponent("Sources", isDirectory: true).path, modificationDate: Date()),
			rootPath: rootURL.path,
			hierarchyLevel: 1,
			isExpanded: true
		)
		let nestedFile = makeIndexedFileVM(
			name: "A.swift",
			fullPath: rootURL.appendingPathComponent("Sources/A.swift").path,
			rootFolder: rootFolder,
			service: service,
			parentFolder: nestedFolder,
			hierarchyLevel: 1
		)
		nestedFolder.addFile(nestedFile)
		rootFolder.addSubfolder(nestedFolder)

		fileManagerVM.registerRootFolderForTesting(rootFolder, service: service)
		XCTAssertNotNil(fileManagerVM.findFolderByFullPath(nestedFolder.standardizedFullPath))
		XCTAssertNotNil(fileManagerVM.findFileByFullPath(nestedFile.standardizedFullPath))

		rootFolder.removeSubfolder(nestedFolder)
		await fileManagerVM.unloadRootFolder(rootFolder)

		XCTAssertNil(fileManagerVM.findFolderByFullPath(rootFolder.standardizedFullPath))
		XCTAssertNil(fileManagerVM.findFolderByFullPath(nestedFolder.standardizedFullPath))
		XCTAssertNil(fileManagerVM.findFileByFullPath(nestedFile.standardizedFullPath))
	}

	@MainActor
	func testRootReferenceCleanupMetricsStayRootScopedAcrossRoots() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootAURL = tempParent.appendingPathComponent("repo", isDirectory: true)
		let rootBURL = tempParent.appendingPathComponent("repo-beta", isDirectory: true)
		try FileManager.default.createDirectory(at: rootAURL, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: rootBURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let fileManagerVM = RepoFileManagerViewModel()
		let serviceA = try await makeTestFileSystemService(path: rootAURL.path)
		let serviceB = try await makeTestFileSystemService(path: rootBURL.path)
		let rootAFolder = FolderViewModel(
			folder: Folder(name: "repo", path: rootAURL.path, modificationDate: Date()),
			rootPath: rootAURL.path,
			isExpanded: true
		)
		let rootBFolder = FolderViewModel(
			folder: Folder(name: "repo-beta", path: rootBURL.path, modificationDate: Date()),
			rootPath: rootBURL.path,
			isExpanded: true
		)
		let nestedFolder = FolderViewModel(
			folder: Folder(name: "Sources", path: rootAURL.appendingPathComponent("Sources", isDirectory: true).path, modificationDate: Date()),
			rootPath: rootAURL.path,
			hierarchyLevel: 1,
			isExpanded: true
		)
		let nestedFile = makeIndexedFileVM(
			name: "A.swift",
			fullPath: rootAURL.appendingPathComponent("Sources/A.swift").path,
			rootFolder: rootAFolder,
			service: serviceA,
			parentFolder: nestedFolder,
			hierarchyLevel: 1
		)
		let rootBFile = makeIndexedFileVM(
			name: "B.swift",
			fullPath: rootBURL.appendingPathComponent("B.swift").path,
			rootFolder: rootBFolder,
			service: serviceB
		)
		nestedFolder.addFile(nestedFile)
		rootAFolder.addSubfolder(nestedFolder)
		rootBFolder.addFile(rootBFile)

		fileManagerVM.registerRootFolderForTesting(rootAFolder, service: serviceA)
		fileManagerVM.registerRootFolderForTesting(rootBFolder, service: serviceB)

		let metrics = fileManagerVM.rootReferenceCleanupMetricsForTesting(rootAFolder)
		XCTAssertEqual(metrics.matchedFolderKeys, 2)
		XCTAssertEqual(metrics.matchedFileKeys, 1)
		XCTAssertEqual(metrics.cleanupCandidateFolderKeys, 2)
		XCTAssertEqual(metrics.cleanupCandidateFileKeys, 1)
		XCTAssertEqual(metrics.totalFolderKeys, 3)
		XCTAssertEqual(metrics.totalFileKeys, 2)
		XCTAssertFalse(metrics.usedFallbackGlobalScan)
		XCTAssertGreaterThan(metrics.totalFolderKeys, metrics.cleanupCandidateFolderKeys)
		XCTAssertGreaterThan(metrics.totalFileKeys, metrics.cleanupCandidateFileKeys)
	}

	@MainActor
	func testRootReferenceCleanupCandidatesAreRootScoped() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootAURL = tempParent.appendingPathComponent("RootA", isDirectory: true)
		let rootBURL = tempParent.appendingPathComponent("RootB", isDirectory: true)
		try FileManager.default.createDirectory(at: rootAURL, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: rootBURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let fileManagerVM = RepoFileManagerViewModel()
		let serviceA = try await makeTestFileSystemService(path: rootAURL.path)
		let serviceB = try await makeTestFileSystemService(path: rootBURL.path)
		let rootAFolder = FolderViewModel(
			folder: Folder(name: "RootA", path: rootAURL.path, modificationDate: Date()),
			rootPath: rootAURL.path,
			isExpanded: true
		)
		let rootBFolder = FolderViewModel(
			folder: Folder(name: "RootB", path: rootBURL.path, modificationDate: Date()),
			rootPath: rootBURL.path,
			isExpanded: true
		)
		let rootAFile = makeIndexedFileVM(
			name: "A.swift",
			fullPath: rootAURL.appendingPathComponent("A.swift").path,
			rootFolder: rootAFolder,
			service: serviceA
		)
		let rootBFile = makeIndexedFileVM(
			name: "B.swift",
			fullPath: rootBURL.appendingPathComponent("B.swift").path,
			rootFolder: rootBFolder,
			service: serviceB
		)
		rootAFolder.addFile(rootAFile)
		rootBFolder.addFile(rootBFile)

		fileManagerVM.registerRootFolderForTesting(rootAFolder, service: serviceA)
		fileManagerVM.registerRootFolderForTesting(rootBFolder, service: serviceB)

		let metrics = fileManagerVM.rootReferenceCleanupMetricsForTesting(rootAFolder)
		XCTAssertEqual(metrics.cleanupCandidateFolderKeys, metrics.matchedFolderKeys)
		XCTAssertEqual(metrics.cleanupCandidateFileKeys, metrics.matchedFileKeys)
		XCTAssertFalse(metrics.usedFallbackGlobalScan)
	}

	@MainActor
	func testRebuildAfterRemovingLastFileAvoidsOwnershipFallbackAndPreservesSiblingRoot() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootAURL = tempParent.appendingPathComponent("RootA", isDirectory: true)
		let rootBURL = tempParent.appendingPathComponent("RootB", isDirectory: true)
		try FileManager.default.createDirectory(at: rootAURL, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: rootBURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let fileManagerVM = RepoFileManagerViewModel()
		let serviceA = try await makeTestFileSystemService(path: rootAURL.path)
		let serviceB = try await makeTestFileSystemService(path: rootBURL.path)
		let rootAFolder = FolderViewModel(
			folder: Folder(name: "RootA", path: rootAURL.path, modificationDate: Date()),
			rootPath: rootAURL.path,
			isExpanded: true
		)
		let rootBFolder = FolderViewModel(
			folder: Folder(name: "RootB", path: rootBURL.path, modificationDate: Date()),
			rootPath: rootBURL.path,
			isExpanded: true
		)
		let rootASubfolderName = syntheticFolderName(index: 0, namePayloadLength: 48)
		let rootASubfolder = FolderViewModel(
			folder: Folder(
				name: rootASubfolderName,
				path: rootAURL.appendingPathComponent(rootASubfolderName, isDirectory: true).path,
				modificationDate: Date()
			),
			rootPath: rootAURL.path,
			hierarchyLevel: 1,
			isExpanded: true
		)
		let rootAFile = makeIndexedFileVM(
			name: "A.swift",
			fullPath: rootAURL.appendingPathComponent("A.swift").path,
			rootFolder: rootAFolder,
			service: serviceA
		)
		let rootBFile = makeIndexedFileVM(
			name: "B.swift",
			fullPath: rootBURL.appendingPathComponent("B.swift").path,
			rootFolder: rootBFolder,
			service: serviceB
		)
		rootAFolder.addSubfolder(rootASubfolder)
		rootAFolder.addFile(rootAFile)
		rootBFolder.addFile(rootBFile)

		fileManagerVM.registerRootFolderForTesting(rootAFolder, service: serviceA)
		fileManagerVM.registerRootFolderForTesting(rootBFolder, service: serviceB)

		await fileManagerVM.applyFileSystemDeltasForTesting([.fileRemoved("A.swift")], forRootFolder: rootAFolder)
		XCTAssertNil(fileManagerVM.findFileByFullPath(rootAFile.standardizedFullPath))

		fileManagerVM.registerRootFolderForTesting(rootAFolder, service: serviceA)

		let sample = try XCTUnwrap(fileManagerVM.latestIndexRebuildPerfSampleForTesting())
		XCTAssertEqual(sample.rootKey, rootAFolder.standardizedFullPath)
		XCTAssertEqual(sample.cleanupCandidateFileKeys, 0)
		XCTAssertFalse(sample.usedOwnershipFallback)
		XCTAssertNil(fileManagerVM.findFileByFullPath(rootAFile.standardizedFullPath))
		XCTAssertNotNil(fileManagerVM.findFolderByFullPath(rootASubfolder.standardizedFullPath))
		XCTAssertNotNil(fileManagerVM.findFileByFullPath(rootBFile.standardizedFullPath))
	}

	func testDeltaReplayPreparationBuildsChunkSummariesAndRenameTransfers() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("WorkspaceRoot", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let actor = DeltaReplayPreparationActor()
		let batch = await actor.prepare(
			rootKey: rootURL.path,
			deltas: [
				.folderRemoved("src/Legacy"),
				.folderAdded("src/Renamed"),
				.folderRemoved("src/Legacy/Subtree"),
				.fileAdded("/tmp/outside.swift"),
				.fileModified("src/Renamed/File.swift", Date(timeIntervalSince1970: 123)),
				.folderModified("docs", nil)
			],
			chunkSize: 2
		)

		XCTAssertEqual(batch.queuedDeltaCount, 6)
		XCTAssertEqual(batch.coalescedDeltaCount, 4)
		XCTAssertEqual(batch.discardedDeltaCount, 2)
		XCTAssertEqual(batch.chunks.count, 2)
		XCTAssertFalse(batch.preparedDeltas.contains { $0.relativePath == "src/Legacy/Subtree" })

		let firstChunk = try XCTUnwrap(batch.chunks.first)
		XCTAssertEqual(firstChunk.deltaCount, 2)
		XCTAssertEqual(firstChunk.summary.folderRemovedCount, 1)
		XCTAssertEqual(firstChunk.summary.folderAddedCount, 1)
		XCTAssertEqual(firstChunk.summary.modifiedCount, 0)
		let renameTransfer = try XCTUnwrap(firstChunk.renameTransfers.first)
		XCTAssertEqual(
			renameTransfer.oldAbsolutePath,
			(rootURL.appendingPathComponent("src/Legacy", isDirectory: true).path as NSString).standardizingPath
		)
		XCTAssertEqual(
			renameTransfer.newAbsolutePath,
			(rootURL.appendingPathComponent("src/Renamed", isDirectory: true).path as NSString).standardizingPath
		)

		let secondChunk = try XCTUnwrap(batch.chunks.last)
		XCTAssertEqual(secondChunk.deltaCount, 2)
		XCTAssertEqual(secondChunk.summary.fileModifiedCount, 1)
		XCTAssertEqual(secondChunk.summary.folderModifiedCount, 1)
		XCTAssertTrue(secondChunk.renameTransfers.isEmpty)
	}

	@MainActor
	func testImmediateLiveApplyConsumesAllPreparedChunksWhenChunkingIsForced() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("WorkspaceRoot", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let fileManagerVM = RepoFileManagerViewModel()
		let service = try await makeTestFileSystemService(path: rootURL.path)
		let rootFolder = FolderViewModel(
			folder: Folder(name: "WorkspaceRoot", path: rootURL.path, modificationDate: Date()),
			rootPath: rootURL.path,
			isExpanded: true
		)
		fileManagerVM.registerRootFolderForTesting(rootFolder, service: service)
		fileManagerVM.setDeltaReplayTuningForTesting(chunkSize: 1, interChunkDelayNanoseconds: 0)
		fileManagerVM.setWindowFocused(true)

		let folderA = syntheticFolderName(index: 0, namePayloadLength: 80)
		let folderB = syntheticFolderName(index: 1, namePayloadLength: 80)
		await fileManagerVM.receiveLiveFileSystemDeltasForTesting(
			[.folderAdded(folderA), .folderAdded(folderB)],
			forRootFolder: rootFolder
		)

		let pendingDeltaCountAfterImmediateApply = await fileManagerVM.pendingDeltaCountForTesting(forRootFolder: rootFolder)
		XCTAssertEqual(pendingDeltaCountAfterImmediateApply, 0)
		XCTAssertNotNil(fileManagerVM.findFolderByFullPath(rootURL.appendingPathComponent(folderA, isDirectory: true).path))
		XCTAssertNotNil(fileManagerVM.findFolderByFullPath(rootURL.appendingPathComponent(folderB, isDirectory: true).path))
	}

	@MainActor
	func testAggressiveFlushAwaitsRealPublisherIngressBeforeDraining() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("WorkspaceRoot", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let fileManagerVM = RepoFileManagerViewModel()
		let service = try await makeTestFileSystemService(path: rootURL.path)
		let rootFolder = FolderViewModel(
			folder: Folder(name: "WorkspaceRoot", path: rootURL.path, modificationDate: Date()),
			rootPath: rootURL.path,
			isExpanded: true
		)
		fileManagerVM.registerRootFolderForTesting(rootFolder, service: service)
		await fileManagerVM.connectRegisteredFileSystemServicePublisherForTesting(forRootFolder: rootFolder)
		await fileManagerVM.setWindowFocusedForTesting(false)

		try await service.createFile(atRelativePath: "Generated.swift", content: "struct Generated {}\n")
		await fileManagerVM.flushPendingDeltas(aggressive: true)

		let generatedPath = rootURL.appendingPathComponent("Generated.swift").path
		XCTAssertNotNil(fileManagerVM.findFileByFullPath(generatedPath))
		let pendingDeltaCount = await fileManagerVM.pendingDeltaCountForTesting(forRootFolder: rootFolder)
		XCTAssertEqual(pendingDeltaCount, 0)
	}

	@MainActor
	func testImmediateIngressReplaysLateArrivalsQueuedBehindPreparedImmediatePass() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("WorkspaceRoot", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let payloadLength = 72
		let fileManagerVM = RepoFileManagerViewModel()
		let service = try await makeTestFileSystemService(path: rootURL.path)
		let rootFolder = makeSyntheticRoot(
			at: rootURL,
			service: service,
			folderCount: 1,
			filesPerFolder: 0,
			namePayloadLength: payloadLength
		)
		fileManagerVM.registerRootFolderForTesting(rootFolder, service: service)
		fileManagerVM.setDeltaReplayTuningForTesting(chunkSize: 1, interChunkDelayNanoseconds: 0)
		fileManagerVM.setWindowFocused(true)

		let firstBurstFolder = "ImmediatePassA-\(String(repeating: "a", count: payloadLength))"
		let secondBurstFolder = "ImmediatePassB-\(String(repeating: "b", count: payloadLength))"
		let secondBurstFile = syntheticFileName(index: 808, namePayloadLength: payloadLength)
		let firstBurst: [FileSystemDelta] = [
			.folderAdded(firstBurstFolder),
			.folderModified(syntheticFolderName(index: 0, namePayloadLength: payloadLength), nil)
		]
		let secondBurst: [FileSystemDelta] = [
			.folderAdded(secondBurstFolder),
			.fileAdded("\(secondBurstFolder)/\(secondBurstFile)")
		]

		var scheduledSecondBurst = false
		var injectedSecondBurst = false
		var appliedEventCount = 0
		let injectedExpectation = expectation(description: "Injected second burst behind immediate apply")
		let appliedCancellable = fileManagerVM.fileSystemDeltasAppliedPublisher.sink { event in
			guard event.rootKey == rootFolder.standardizedFullPath else { return }
			appliedEventCount += 1
			guard !scheduledSecondBurst else { return }
			scheduledSecondBurst = true
			Task { @MainActor in
				await fileManagerVM.receiveLiveFileSystemDeltasForTesting(secondBurst, forRootFolder: rootFolder)
				injectedSecondBurst = true
				injectedExpectation.fulfill()
			}
		}
		defer { appliedCancellable.cancel() }

		await fileManagerVM.receiveLiveFileSystemDeltasForTesting(firstBurst, forRootFolder: rootFolder)
		await fulfillment(of: [injectedExpectation], timeout: 2.0)

		let pendingDeltaCountAfterReplay = await fileManagerVM.pendingDeltaCountForTesting(forRootFolder: rootFolder)
		XCTAssertTrue(injectedSecondBurst)
		XCTAssertEqual(appliedEventCount, 2)
		XCTAssertEqual(pendingDeltaCountAfterReplay, 0)
		let secondBurstFolderURL = rootURL.appendingPathComponent(secondBurstFolder, isDirectory: true)
		XCTAssertNotNil(fileManagerVM.findFolderByFullPath(rootURL.appendingPathComponent(firstBurstFolder, isDirectory: true).path))
		XCTAssertNotNil(fileManagerVM.findFolderByFullPath(secondBurstFolderURL.path))
		XCTAssertNotNil(fileManagerVM.findFileByFullPath(secondBurstFolderURL.appendingPathComponent(secondBurstFile).path))
	}

	@MainActor
	func testStaleWatcherIngressIsDroppedAfterRootReload() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("WorkspaceRoot", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let fileManagerVM = RepoFileManagerViewModel()
		let firstService = try await makeTestFileSystemService(path: rootURL.path)
		let firstRoot = makeSyntheticRoot(
			at: rootURL,
			service: firstService,
			folderCount: 1,
			filesPerFolder: 0,
			namePayloadLength: 72
		)
		fileManagerVM.registerRootFolderForTesting(firstRoot, service: firstService)
		let staleGeneration = await fileManagerVM.ensureReplayIngressRegistrationForTesting(forRootFolder: firstRoot)

		await fileManagerVM.unloadRootFolder(firstRoot)

		let reloadedService = try await makeTestFileSystemService(path: rootURL.path)
		let reloadedRoot = makeSyntheticRoot(
			at: rootURL,
			service: reloadedService,
			folderCount: 1,
			filesPerFolder: 0,
			namePayloadLength: 72
		)
		fileManagerVM.registerRootFolderForTesting(reloadedRoot, service: reloadedService)
		let currentGeneration = await fileManagerVM.ensureReplayIngressRegistrationForTesting(forRootFolder: reloadedRoot)
		XCTAssertNotEqual(staleGeneration, currentGeneration)

		let staleFolderURL = rootURL.appendingPathComponent("StaleWatcherFolder", isDirectory: true)
		await fileManagerVM.receiveWatcherFileSystemDeltasForTesting(
			[.folderAdded("StaleWatcherFolder")],
			forRootFolder: reloadedRoot,
			capturedGeneration: staleGeneration
		)
		let pendingAfterStaleIngress = await fileManagerVM.pendingDeltaCountForTesting(forRootFolder: reloadedRoot)
		XCTAssertEqual(pendingAfterStaleIngress, 0)
		XCTAssertNil(fileManagerVM.findFolderByFullPath(staleFolderURL.path))

		let freshFolderURL = rootURL.appendingPathComponent("FreshWatcherFolder", isDirectory: true)
		await fileManagerVM.receiveWatcherFileSystemDeltasForTesting(
			[.folderAdded("FreshWatcherFolder")],
			forRootFolder: reloadedRoot,
			capturedGeneration: currentGeneration
		)
		XCTAssertNotNil(fileManagerVM.findFolderByFullPath(freshFolderURL.path))
	}

	@MainActor
	func testFocusRegainReplayRunsIndependentlyAcrossTwoWindows() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let firstRootURL = tempParent.appendingPathComponent("WindowOneRoot", isDirectory: true)
		let secondRootURL = tempParent.appendingPathComponent("WindowTwoRoot", isDirectory: true)
		try FileManager.default.createDirectory(at: firstRootURL, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: secondRootURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let payloadLength = 72
		let queuedFolderName = "QueuedFolder-\(String(repeating: "q", count: payloadLength))"
		let queuedFileName = syntheticFileName(index: 99, namePayloadLength: payloadLength)
		let makeBurst = {
			(0..<11).map { FileSystemDelta.folderModified(self.syntheticFolderName(index: $0, namePayloadLength: payloadLength), nil) } + [
				.folderAdded(queuedFolderName),
				.fileAdded("\(queuedFolderName)/\(queuedFileName)")
			]
		}

		let firstVM = RepoFileManagerViewModel()
		let secondVM = RepoFileManagerViewModel()
		let firstService = try await makeTestFileSystemService(path: firstRootURL.path)
		let secondService = try await makeTestFileSystemService(path: secondRootURL.path)
		let firstRoot = makeSyntheticRoot(
			at: firstRootURL,
			service: firstService,
			folderCount: 12,
			filesPerFolder: 0,
			namePayloadLength: payloadLength
		)
		let secondRoot = makeSyntheticRoot(
			at: secondRootURL,
			service: secondService,
			folderCount: 12,
			filesPerFolder: 0,
			namePayloadLength: payloadLength
		)
		firstVM.registerRootFolderForTesting(firstRoot, service: firstService)
		secondVM.registerRootFolderForTesting(secondRoot, service: secondService)
		firstVM.setDeltaReplayTuningForTesting(chunkSize: 5, interChunkDelayNanoseconds: 0)
		secondVM.setDeltaReplayTuningForTesting(chunkSize: 5, interChunkDelayNanoseconds: 0)
		firstVM.setWindowFocused(false)
		secondVM.setWindowFocused(false)

		let firstBurst = makeBurst()
		let secondBurst = makeBurst()
		await firstVM.receiveLiveFileSystemDeltasForTesting(firstBurst, forRootFolder: firstRoot)
		await secondVM.receiveLiveFileSystemDeltasForTesting(secondBurst, forRootFolder: secondRoot)

		let firstPendingDeltaCountBeforeReplay = await firstVM.pendingDeltaCountForTesting(forRootFolder: firstRoot)
		let secondPendingDeltaCountBeforeReplay = await secondVM.pendingDeltaCountForTesting(forRootFolder: secondRoot)
		XCTAssertEqual(firstPendingDeltaCountBeforeReplay, firstBurst.count)
		XCTAssertEqual(secondPendingDeltaCountBeforeReplay, secondBurst.count)
		XCTAssertNil(firstVM.findFolderByFullPath(firstRootURL.appendingPathComponent(queuedFolderName, isDirectory: true).path))
		XCTAssertNil(secondVM.findFolderByFullPath(secondRootURL.appendingPathComponent(queuedFolderName, isDirectory: true).path))

		firstVM.setWindowFocused(true)
		secondVM.setWindowFocused(true)
		await firstVM.waitForDeltaReplayCompletionForTesting()
		await secondVM.waitForDeltaReplayCompletionForTesting()

		let firstQueuedFolderPath = firstRootURL.appendingPathComponent(queuedFolderName, isDirectory: true)
		let secondQueuedFolderPath = secondRootURL.appendingPathComponent(queuedFolderName, isDirectory: true)
		let firstPendingDeltaCountAfterReplay = await firstVM.pendingDeltaCountForTesting(forRootFolder: firstRoot)
		let secondPendingDeltaCountAfterReplay = await secondVM.pendingDeltaCountForTesting(forRootFolder: secondRoot)
		XCTAssertEqual(firstPendingDeltaCountAfterReplay, 0)
		XCTAssertEqual(secondPendingDeltaCountAfterReplay, 0)
		XCTAssertNotNil(firstVM.findFolderByFullPath(firstQueuedFolderPath.path))
		XCTAssertNotNil(secondVM.findFolderByFullPath(secondQueuedFolderPath.path))
		XCTAssertNotNil(firstVM.findFileByFullPath(firstQueuedFolderPath.appendingPathComponent(queuedFileName).path))
		XCTAssertNotNil(secondVM.findFileByFullPath(secondQueuedFolderPath.appendingPathComponent(queuedFileName).path))

		let firstSample = try XCTUnwrap(firstVM.latestDeltaReplayPerfSampleForTesting())
		let secondSample = try XCTUnwrap(secondVM.latestDeltaReplayPerfSampleForTesting())
		for sample in [firstSample, secondSample] {
			XCTAssertEqual(sample.pendingRootCountAtStart, 1)
			XCTAssertEqual(sample.pendingDeltaCountAtStart, 13)
			XCTAssertEqual(sample.whileLoopPassCount, 2)
			XCTAssertEqual(sample.totalRootPassCount, 1)
			XCTAssertEqual(sample.totalChunkCount, 3)
			XCTAssertEqual(sample.totalCoalescedDeltaCount, 13)
			XCTAssertEqual(sample.totalDiscardedDeltaCount, 0)
			XCTAssertEqual(sample.replayedRoots.count, 3)
			XCTAssertEqual(sample.replayedRoots.map(\.chunkDeltaCount).reduce(0, +), 13)
			XCTAssertTrue(sample.replayedRoots.allSatisfy { $0.chunkCountInPass == 3 })
			XCTAssertGreaterThanOrEqual(sample.totalPreparationDurationMS, 0)
			XCTAssertGreaterThanOrEqual(sample.totalCoalesceDurationMS, 0)
		}
	}

	@MainActor
	func testHiddenMultiWindowLiveBurstDefersWithoutReplayUntilFocusRegain() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let payloadLength = 88
		let bursts = (0..<3).map { windowIndex in
			(0..<9).map { FileSystemDelta.folderModified(self.syntheticFolderName(index: $0, namePayloadLength: payloadLength), nil) } + [
				.folderAdded("Window\(windowIndex)-Queued-" + String(repeating: "q", count: payloadLength)),
				.fileAdded("Window\(windowIndex)-Queued-" + String(repeating: "q", count: payloadLength) + "/" + self.syntheticFileName(index: windowIndex, namePayloadLength: payloadLength))
			]
		}

		var viewModels: [RepoFileManagerViewModel] = []
		var roots: [FolderViewModel] = []
		var rootChangedCounts: [Int] = []
		for windowIndex in 0..<3 {
			let rootURL = tempParent.appendingPathComponent("Window\(windowIndex)", isDirectory: true)
			try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
			let vm = RepoFileManagerViewModel()
			let service = try await makeTestFileSystemService(path: rootURL.path)
			let root = makeSyntheticRoot(
				at: rootURL,
				service: service,
				folderCount: 10,
				filesPerFolder: 0,
				namePayloadLength: payloadLength
			)
			vm.registerRootFolderForTesting(root, service: service)
			vm.setDeltaReplayTuningForTesting(chunkSize: 4, interChunkDelayNanoseconds: 0)
			vm.setWindowFocused(false)
			rootChangedCounts.append(0)
			let countIndex = rootChangedCounts.count - 1
			vm.onRootFoldersChanged = {
				rootChangedCounts[countIndex] += 1
			}
			viewModels.append(vm)
			roots.append(root)
		}

		for (index, vm) in viewModels.enumerated() {
			await vm.receiveLiveFileSystemDeltasForTesting(bursts[index], forRootFolder: roots[index])
		}

		for (index, vm) in viewModels.enumerated() {
			XCTAssertNil(vm.latestDeltaReplayPerfSampleForTesting())
			let pendingDeltaCountBeforeFocusRegain = await vm.pendingDeltaCountForTesting(forRootFolder: roots[index])
			XCTAssertEqual(pendingDeltaCountBeforeFocusRegain, bursts[index].count)
			let diagnostics = await vm.deferredReplayBufferDiagnosticsForTesting()
			XCTAssertGreaterThanOrEqual(diagnostics.deferredIngressCount, 1)
			XCTAssertEqual(diagnostics.immediateIngressCount, 0)
		}
		XCTAssertEqual(rootChangedCounts, [0, 0, 0])

		for vm in viewModels {
			vm.setWindowFocused(true)
		}
		for vm in viewModels {
			await vm.waitForDeltaReplayCompletionForTesting()
		}

		for (index, vm) in viewModels.enumerated() {
			let replaySample = try XCTUnwrap(vm.latestDeltaReplayPerfSampleForTesting())
			let pendingDeltaCountAfterFocusRegain = await vm.pendingDeltaCountForTesting(forRootFolder: roots[index])
			XCTAssertEqual(pendingDeltaCountAfterFocusRegain, 0)
			XCTAssertEqual(replaySample.rootPasses.count, 1)
			XCTAssertEqual(replaySample.totalOnRootFoldersChangedInvocationCount, 1)
			XCTAssertEqual(replaySample.totalDeltaAppliedPublisherInvocationCount, 1)
			XCTAssertEqual(rootChangedCounts[index], 1)
		}
	}

	@MainActor
	func testReplayPublishesAndInvalidatesOncePerRootPassNotPerChunk() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("WorkspaceRoot", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let payloadLength = 84
		let fileManagerVM = RepoFileManagerViewModel()
		let service = try await makeTestFileSystemService(path: rootURL.path)
		let rootFolder = makeSyntheticRoot(
			at: rootURL,
			service: service,
			folderCount: 1,
			filesPerFolder: 0,
			namePayloadLength: payloadLength
		)
		fileManagerVM.registerRootFolderForTesting(rootFolder, service: service)
		fileManagerVM.setDeltaReplayTuningForTesting(chunkSize: 1, interChunkDelayNanoseconds: 0)

		var onRootFoldersChangedCount = 0
		var fileSystemChangedCount = 0
		var appliedEvents: [RepoFileManagerViewModel.FileSystemDeltasAppliedEvent] = []
		let fileSystemChangedCancellable = fileManagerVM.fileSystemChangedPublisher.sink {
			fileSystemChangedCount += 1
		}
		let appliedCancellable = fileManagerVM.fileSystemDeltasAppliedPublisher.sink { event in
			appliedEvents.append(event)
		}
		defer {
			fileSystemChangedCancellable.cancel()
			appliedCancellable.cancel()
		}
		fileManagerVM.onRootFoldersChanged = {
			onRootFoldersChangedCount += 1
		}

		await fileManagerVM.enqueuePendingDeltasForTesting(
			[
				.folderAdded("Queued-A"),
				.folderAdded("Queued-B"),
				.folderAdded("Queued-C")
			],
			forRootFolder: rootFolder
		)
		await fileManagerVM.flushPendingDeltas()

		let sample = try XCTUnwrap(fileManagerVM.latestDeltaReplayPerfSampleForTesting())
		let rootPass = try XCTUnwrap(sample.rootPasses.last)
		XCTAssertEqual(sample.totalChunkCount, 3)
		XCTAssertEqual(sample.rootPasses.count, 1)
		XCTAssertEqual(rootPass.chunkCount, 3)
		XCTAssertEqual(rootPass.digestCount, 3)
		XCTAssertEqual(onRootFoldersChangedCount, 1)
		XCTAssertEqual(fileSystemChangedCount, 1)
		XCTAssertEqual(appliedEvents.count, 1)
		XCTAssertEqual(appliedEvents.first?.deltas.count, 3)
		XCTAssertEqual(sample.totalOnRootFoldersChangedInvocationCount, 1)
		XCTAssertEqual(sample.totalSnapshotInvalidationCount, 1)
		XCTAssertEqual(sample.totalDeltaAppliedPublisherInvocationCount, 1)
		XCTAssertEqual(sample.totalReplayCodeScanBatchInvocationCount, 0)
		XCTAssertEqual(sample.totalReplaySliceRebaseBatchInvocationCount, 0)
	}

	@MainActor
	func testReplayPerfSampleSeparatesPrepareApplyAndRebuildForMixedTopologyBurst() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("WorkspaceRoot", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let payloadLength = 96
		let fileManagerVM = RepoFileManagerViewModel()
		let service = try await makeTestFileSystemService(path: rootURL.path)
		let rootFolder = makeSyntheticRoot(
			at: rootURL,
			service: service,
			folderCount: 6,
			filesPerFolder: 0,
			namePayloadLength: payloadLength
		)
		fileManagerVM.registerRootFolderForTesting(rootFolder, service: service)
		fileManagerVM.setDeltaReplayTuningForTesting(chunkSize: 2, interChunkDelayNanoseconds: 0)

		let queuedFolderName = "QueuedFolder-\(String(repeating: "n", count: payloadLength))"
		let replacementFolderName = "ReplacementFolder-\(String(repeating: "r", count: payloadLength))"
		let queuedFileName = syntheticFileName(index: 77, namePayloadLength: payloadLength)
		let removedFolderName = syntheticFolderName(index: 2, namePayloadLength: payloadLength)
		fileManagerVM.setWindowFocused(false)
		await fileManagerVM.receiveLiveFileSystemDeltasForTesting(
			[
				.folderModified(syntheticFolderName(index: 0, namePayloadLength: payloadLength), nil),
				.folderModified(syntheticFolderName(index: 1, namePayloadLength: payloadLength), nil),
				.folderAdded(queuedFolderName),
				.fileAdded("\(queuedFolderName)/\(queuedFileName)"),
				.folderRemoved(removedFolderName),
				.folderAdded(replacementFolderName)
			],
			forRootFolder: rootFolder
		)

		await fileManagerVM.flushPendingDeltas(aggressive: true)

		let sample = try XCTUnwrap(fileManagerVM.latestDeltaReplayPerfSampleForTesting())
		XCTAssertEqual(sample.pendingRootCountAtStart, 1)
		XCTAssertEqual(sample.pendingDeltaCountAtStart, 6)
		XCTAssertEqual(sample.totalChunkCount, 3)
		XCTAssertEqual(sample.totalCoalescedDeltaCount, 6)
		XCTAssertEqual(sample.totalDiscardedDeltaCount, 0)
		XCTAssertEqual(sample.totalRebuildDurationMS, 0)
		XCTAssertGreaterThanOrEqual(sample.totalPreparationDurationMS, 0)
		XCTAssertGreaterThanOrEqual(sample.totalCoalesceDurationMS, 0)
		XCTAssertEqual(sample.replayedRoots.count, 3)

		let firstChunk = sample.replayedRoots[0]
		XCTAssertEqual(firstChunk.chunkDeltaCount, 2)
		XCTAssertEqual(firstChunk.modifiedCount, 2)
		XCTAssertNil(firstChunk.rebuildDurationMS)

		let secondChunk = sample.replayedRoots[1]
		XCTAssertEqual(secondChunk.folderAddedCount, 1)
		XCTAssertEqual(secondChunk.fileAddedCount, 1)
		XCTAssertNil(secondChunk.rebuildDurationMS)

		let thirdChunk = sample.replayedRoots[2]
		XCTAssertEqual(thirdChunk.folderRemovedCount, 1)
		XCTAssertEqual(thirdChunk.folderAddedCount, 1)
		XCTAssertTrue(thirdChunk.usedIncrementalIndexCleanup)
		XCTAssertFalse(thirdChunk.incrementalIndexCleanupFallbackToRebuild)
		XCTAssertEqual(thirdChunk.incrementalRemovedFolderCount, 1)
		XCTAssertEqual(thirdChunk.incrementalRemovedFileCount, 0)
		XCTAssertNil(thirdChunk.rebuildDurationMS)

		XCTAssertNotNil(fileManagerVM.findFolderByFullPath(rootURL.appendingPathComponent(queuedFolderName, isDirectory: true).path))
		XCTAssertNotNil(fileManagerVM.findFileByFullPath(rootURL.appendingPathComponent(queuedFolderName, isDirectory: true).appendingPathComponent(queuedFileName).path))
		XCTAssertNil(fileManagerVM.findFolderByFullPath(rootURL.appendingPathComponent(removedFolderName, isDirectory: true).path))
		XCTAssertNotNil(fileManagerVM.findFolderByFullPath(rootURL.appendingPathComponent(replacementFolderName, isDirectory: true).path))
	}

	@MainActor
	func testFolderRemovalReplayUsesIncrementalIndexCleanupWithoutRebuildAndPrunesCodemapState() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("WorkspaceRoot", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let payloadLength = 96
		let fileManagerVM = RepoFileManagerViewModel()
		let service = try await makeTestFileSystemService(path: rootURL.path)
		let rootFolder = makeSyntheticRoot(
			at: rootURL,
			service: service,
			folderCount: 4,
			filesPerFolder: 2,
			namePayloadLength: payloadLength
		)
		fileManagerVM.registerRootFolderForTesting(rootFolder, service: service)
		fileManagerVM.setDeltaReplayTuningForTesting(chunkSize: 4, interChunkDelayNanoseconds: 0)

		let removedFolderName = syntheticFolderName(index: 2, namePayloadLength: payloadLength)
		let selectedFilePath = syntheticFileRelativePath(folderIndex: 2, fileIndex: 0, namePayloadLength: payloadLength)
		let codemapFilePath = syntheticFileRelativePath(folderIndex: 2, fileIndex: 1, namePayloadLength: payloadLength)
		let selectedFile = try XCTUnwrap(fileManagerVM.findFileByRelativePath(selectedFilePath))
		let codemapFile = try XCTUnwrap(fileManagerVM.findFileByRelativePath(codemapFilePath))
		let selectedRanges = [LineRange(start: 1, end: 3)]

		await fileManagerVM.applyStoredSelection(
			StoredSelection(
				selectedPaths: [selectedFile.standardizedFullPath],
				autoCodemapPaths: [codemapFile.standardizedFullPath],
				slices: [:],
				codemapAutoEnabled: false
			)
		)
		fileManagerVM.seedSelectionSlicesForTesting(selectedRanges, for: selectedFile)
		XCTAssertEqual(try XCTUnwrap(fileManagerVM.selectionSlices(for: selectedFile)), selectedRanges)
		XCTAssertTrue(fileManagerVM.snapshotSelection().autoCodemapPaths.contains(codemapFile.standardizedFullPath))

		await fileManagerVM.enqueuePendingDeltasForTesting(
			[.folderRemoved(removedFolderName)],
			forRootFolder: rootFolder
		)
		await fileManagerVM.flushPendingDeltas()

		let sample = try XCTUnwrap(fileManagerVM.latestDeltaReplayPerfSampleForTesting())
		let chunk = try XCTUnwrap(sample.replayedRoots.last)
		XCTAssertTrue(chunk.usedIncrementalIndexCleanup)
		XCTAssertFalse(chunk.incrementalIndexCleanupFallbackToRebuild)
		XCTAssertNil(chunk.rebuildDurationMS)
		XCTAssertEqual(chunk.incrementalRemovedFolderCount, 1)
		XCTAssertEqual(chunk.incrementalRemovedFileCount, 2)
		XCTAssertEqual(chunk.incrementalDescendantScanInvocationCount, 1)
		XCTAssertEqual(sample.totalIncrementalDescendantScanInvocationCount, 1)
		XCTAssertEqual(sample.totalIncrementalDescendantScannedFolderCandidateCount, chunk.incrementalDescendantScannedFolderCandidateCount)
		XCTAssertEqual(sample.totalIncrementalDescendantScannedFileCandidateCount, chunk.incrementalDescendantScannedFileCandidateCount)
		XCTAssertNil(fileManagerVM.findFolderByFullPath(rootURL.appendingPathComponent(removedFolderName, isDirectory: true).path))
		XCTAssertNil(fileManagerVM.findFileByFullPath(selectedFile.standardizedFullPath))
		XCTAssertNil(fileManagerVM.findFileByFullPath(codemapFile.standardizedFullPath))
		XCTAssertNil(fileManagerVM.selectionSlices(for: selectedFile))
		let snapshot = fileManagerVM.snapshotSelection()
		XCTAssertFalse(snapshot.selectedPaths.contains(selectedFile.standardizedFullPath))
		XCTAssertFalse(snapshot.autoCodemapPaths.contains(codemapFile.standardizedFullPath))
	}

	@MainActor
	func testFolderRemovalReplayFallsBackToRebuildWhenRemovedSubtreeDoesNotMatchIndexedDescendants() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("WorkspaceRoot", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let payloadLength = 80
		let staleFolderName = "StaleFolder-\(String(repeating: "s", count: payloadLength))"
		let staleFileName = syntheticFileName(index: 404, namePayloadLength: payloadLength)
		let fileManagerVM = RepoFileManagerViewModel()
		let service = try await makeTestFileSystemService(path: rootURL.path)
		let rootFolder = makeSyntheticRoot(
			at: rootURL,
			service: service,
			folderCount: 2,
			filesPerFolder: 0,
			namePayloadLength: payloadLength
		)
		fileManagerVM.registerRootFolderForTesting(rootFolder, service: service)
		fileManagerVM.setDeltaReplayTuningForTesting(chunkSize: 1, interChunkDelayNanoseconds: 0)
		let staleFolderURL = rootURL.appendingPathComponent(staleFolderName, isDirectory: true)
		let staleFolder = FolderViewModel(
			folder: Folder(name: staleFolderName, path: staleFolderURL.path, modificationDate: Date()),
			rootPath: rootURL.path,
			hierarchyLevel: 1,
			isExpanded: true
		)
		let staleFile = makeIndexedFileVM(
			name: staleFileName,
			fullPath: staleFolderURL.appendingPathComponent(staleFileName).path,
			rootFolder: rootFolder,
			service: service,
			parentFolder: staleFolder,
			hierarchyLevel: 1
		)
		staleFolder.addFile(staleFile)
		rootFolder.addSubfolder(staleFolder)
		XCTAssertTrue(fileManagerVM.getFilesRecursively(under: rootFolder).contains { $0.standardizedFullPath == staleFile.standardizedFullPath })

		await fileManagerVM.receiveLiveFileSystemDeltasForTesting(
			[.folderRemoved(staleFolderName)],
			forRootFolder: rootFolder
		)

		let sample = try XCTUnwrap(fileManagerVM.latestImmediateReplayPerfSampleForTesting())
		let chunk = try XCTUnwrap(sample.replayedChunks.last)
		XCTAssertTrue(chunk.usedIncrementalIndexCleanup)
		XCTAssertTrue(chunk.incrementalIndexCleanupFallbackToRebuild)
		XCTAssertEqual(chunk.incrementalDescendantScanInvocationCount, 1)
		XCTAssertEqual(sample.replayedChunks.map(\.incrementalDescendantScanInvocationCount).reduce(0, +), 1)
		XCTAssertNotNil(chunk.rebuildDurationMS)
		XCTAssertEqual(try XCTUnwrap(fileManagerVM.latestIndexRebuildPerfSampleForTesting()).rootKey, rootFolder.standardizedFullPath)
		XCTAssertFalse(fileManagerVM.getFilesRecursively(under: rootFolder).contains { $0.standardizedFullPath == staleFile.standardizedFullPath })
	}

	@MainActor
	func testFallbackRebuildPrunesIndexedSelectedAndCodemapDescendantsOutsideRemovedTreeSnapshot() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("WorkspaceRoot", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let payloadLength = 72
		let fileManagerVM = RepoFileManagerViewModel()
		let service = try await makeTestFileSystemService(path: rootURL.path)
		let rootFolder = makeSyntheticRoot(
			at: rootURL,
			service: service,
			folderCount: 2,
			filesPerFolder: 1,
			namePayloadLength: payloadLength
		)
		fileManagerVM.registerRootFolderForTesting(rootFolder, service: service)
		fileManagerVM.setDeltaReplayTuningForTesting(chunkSize: 1, interChunkDelayNanoseconds: 0)
		let removedFolderName = syntheticFolderName(index: 0, namePayloadLength: payloadLength)
		let realTreeFile = try XCTUnwrap(fileManagerVM.findFileByRelativePath(
			syntheticFileRelativePath(folderIndex: 0, fileIndex: 0, namePayloadLength: payloadLength)
		))
		let staleFileName = syntheticFileName(index: 515, namePayloadLength: payloadLength)
		let staleFile = makeIndexedFileVM(
			name: staleFileName,
			fullPath: rootURL.appendingPathComponent("\(removedFolderName)/\(staleFileName)").path,
			rootFolder: rootFolder,
			service: service
		)
		fileManagerVM.injectIndexedFileForTesting(staleFile)
		XCTAssertNotNil(fileManagerVM.findFileByFullPath(staleFile.standardizedFullPath))

		await fileManagerVM.applyStoredSelection(
			StoredSelection(
				selectedPaths: [realTreeFile.standardizedFullPath],
				autoCodemapPaths: [staleFile.standardizedFullPath],
				slices: [:],
				codemapAutoEnabled: false
			)
		)
		XCTAssertTrue(fileManagerVM.snapshotSelection().autoCodemapPaths.contains(staleFile.standardizedFullPath))

		await fileManagerVM.receiveLiveFileSystemDeltasForTesting(
			[.folderRemoved(removedFolderName)],
			forRootFolder: rootFolder
		)

		let sample = try XCTUnwrap(fileManagerVM.latestImmediateReplayPerfSampleForTesting())
		let chunk = try XCTUnwrap(sample.replayedChunks.last)
		XCTAssertTrue(chunk.incrementalIndexCleanupFallbackToRebuild)
		XCTAssertEqual(chunk.incrementalDescendantScanInvocationCount, 1)
		XCTAssertEqual(sample.replayedChunks.map(\.incrementalDescendantScanInvocationCount).reduce(0, +), 1)
		XCTAssertNotNil(chunk.rebuildDurationMS)
		XCTAssertNil(fileManagerVM.findFileByFullPath(staleFile.standardizedFullPath))
		let snapshot = fileManagerVM.snapshotSelection()
		XCTAssertFalse(snapshot.selectedPaths.contains(realTreeFile.standardizedFullPath))
		XCTAssertFalse(snapshot.autoCodemapPaths.contains(staleFile.standardizedFullPath))
	}

	@MainActor
	func testFolderRemovalReplayManySiblingFoldersRunsOneBatchedDescendantScanPerChunk() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("WorkspaceRoot", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let payloadLength = 48
		let folderCount = 50
		let removedFolderCount = 40
		let fileManagerVM = RepoFileManagerViewModel()
		let service = try await makeTestFileSystemService(path: rootURL.path)
		let rootFolder = makeSyntheticRoot(
			at: rootURL,
			service: service,
			folderCount: folderCount,
			filesPerFolder: 1,
			namePayloadLength: payloadLength
		)
		fileManagerVM.registerRootFolderForTesting(rootFolder, service: service)
		fileManagerVM.setDeltaReplayTuningForTesting(chunkSize: removedFolderCount, interChunkDelayNanoseconds: 0)
		let removedNames = (0..<removedFolderCount).map { syntheticFolderName(index: $0, namePayloadLength: payloadLength) }
		await fileManagerVM.receiveLiveFileSystemDeltasForTesting(
			removedNames.map(FileSystemDelta.folderRemoved),
			forRootFolder: rootFolder
		)

		let sample = try XCTUnwrap(fileManagerVM.latestImmediateReplayPerfSampleForTesting())
		let chunk = try XCTUnwrap(sample.replayedChunks.last)
		XCTAssertEqual(sample.chunkCount, 1)
		XCTAssertEqual(sample.replayedChunks.map(\.incrementalDescendantScanInvocationCount).reduce(0, +), 1)
		XCTAssertTrue(chunk.usedIncrementalIndexCleanup)
		XCTAssertFalse(chunk.incrementalIndexCleanupFallbackToRebuild)
		XCTAssertFalse(chunk.incrementalCleanupUsedFallbackGlobalScan)
		XCTAssertEqual(chunk.incrementalDescendantScanInvocationCount, 1)
		XCTAssertEqual(chunk.incrementalDescendantScannedFolderCandidateCount, folderCount + 1)
		XCTAssertEqual(chunk.incrementalDescendantScannedFileCandidateCount, folderCount)
		XCTAssertEqual(chunk.incrementalRemovedFolderCount, removedFolderCount)
		XCTAssertEqual(chunk.incrementalRemovedFileCount, removedFolderCount)
		for removedName in removedNames {
			XCTAssertNil(fileManagerVM.findFolderByFullPath(rootURL.appendingPathComponent(removedName, isDirectory: true).path))
		}
		let preservedFolderName = syntheticFolderName(index: removedFolderCount, namePayloadLength: payloadLength)
		let preservedFilePath = syntheticFileRelativePath(folderIndex: removedFolderCount, fileIndex: 0, namePayloadLength: payloadLength)
		XCTAssertNotNil(fileManagerVM.findFolderByFullPath(rootURL.appendingPathComponent(preservedFolderName, isDirectory: true).path))
		XCTAssertNotNil(fileManagerVM.findFileByRelativePath(preservedFilePath))
	}

	@MainActor
	func testFolderRemovalReplayBatchesValidationPerChunkWhenChunkingIsForced() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("WorkspaceRoot", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let payloadLength = 40
		let fileManagerVM = RepoFileManagerViewModel()
		let service = try await makeTestFileSystemService(path: rootURL.path)
		let rootFolder = makeSyntheticRoot(
			at: rootURL,
			service: service,
			folderCount: 6,
			filesPerFolder: 1,
			namePayloadLength: payloadLength
		)
		fileManagerVM.registerRootFolderForTesting(rootFolder, service: service)
		fileManagerVM.setDeltaReplayTuningForTesting(chunkSize: 2, interChunkDelayNanoseconds: 0)
		let removedNames = (0..<5).map { syntheticFolderName(index: $0, namePayloadLength: payloadLength) }
		await fileManagerVM.receiveLiveFileSystemDeltasForTesting(
			removedNames.map(FileSystemDelta.folderRemoved),
			forRootFolder: rootFolder
		)

		let sample = try XCTUnwrap(fileManagerVM.latestImmediateReplayPerfSampleForTesting())
		XCTAssertEqual(sample.chunkCount, 3)
		XCTAssertEqual(sample.replayedChunks.count, 3)
		XCTAssertEqual(sample.replayedChunks.map(\.incrementalDescendantScanInvocationCount).reduce(0, +), 3)
		XCTAssertEqual(sample.replayedChunks.map(\.incrementalDescendantScanInvocationCount), [1, 1, 1])
		XCTAssertTrue(sample.replayedChunks.allSatisfy { !$0.incrementalIndexCleanupFallbackToRebuild })
		XCTAssertEqual(sample.replayedChunks.map(\.folderRemovedCount), [2, 2, 1])
		XCTAssertNotNil(fileManagerVM.findFolderByFullPath(rootURL.appendingPathComponent(syntheticFolderName(index: 5, namePayloadLength: payloadLength), isDirectory: true).path))
	}

	@MainActor
	func testFolderRemovalReplayPreservesSiblingPrefixPathsDuringBatchedCleanup() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("WorkspaceRoot", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let fileManagerVM = RepoFileManagerViewModel()
		let service = try await makeTestFileSystemService(path: rootURL.path)
		let rootFolder = FolderViewModel(
			folder: Folder(name: rootURL.lastPathComponent, path: rootURL.path, modificationDate: Date()),
			rootPath: rootURL.path,
			isExpanded: true
		)
		let fooFolder = FolderViewModel(
			folder: Folder(name: "Foo", path: rootURL.appendingPathComponent("Foo", isDirectory: true).path, modificationDate: Date()),
			rootPath: rootURL.path,
			hierarchyLevel: 1,
			isExpanded: true
		)
		let fooBarFolder = FolderViewModel(
			folder: Folder(name: "FooBar", path: rootURL.appendingPathComponent("FooBar", isDirectory: true).path, modificationDate: Date()),
			rootPath: rootURL.path,
			hierarchyLevel: 1,
			isExpanded: true
		)
		let fooFile = makeIndexedFileVM(
			name: "Remove.swift",
			fullPath: rootURL.appendingPathComponent("Foo/Remove.swift").path,
			rootFolder: rootFolder,
			service: service,
			parentFolder: fooFolder,
			hierarchyLevel: 1
		)
		let fooBarFile = makeIndexedFileVM(
			name: "Keep.swift",
			fullPath: rootURL.appendingPathComponent("FooBar/Keep.swift").path,
			rootFolder: rootFolder,
			service: service,
			parentFolder: fooBarFolder,
			hierarchyLevel: 1
		)
		fooFolder.addFile(fooFile)
		fooBarFolder.addFile(fooBarFile)
		rootFolder.addSubfolder(fooFolder)
		rootFolder.addSubfolder(fooBarFolder)
		fileManagerVM.registerRootFolderForTesting(rootFolder, service: service)
		fileManagerVM.setDeltaReplayTuningForTesting(chunkSize: 4, interChunkDelayNanoseconds: 0)
		await fileManagerVM.receiveLiveFileSystemDeltasForTesting([.folderRemoved("Foo")], forRootFolder: rootFolder)

		let sample = try XCTUnwrap(fileManagerVM.latestImmediateReplayPerfSampleForTesting())
		let chunk = try XCTUnwrap(sample.replayedChunks.last)
		XCTAssertEqual(chunk.incrementalDescendantScanInvocationCount, 1)
		XCTAssertFalse(chunk.incrementalIndexCleanupFallbackToRebuild)
		XCTAssertNil(fileManagerVM.findFolderByFullPath(fooFolder.standardizedFullPath))
		XCTAssertNil(fileManagerVM.findFileByFullPath(fooFile.standardizedFullPath))
		XCTAssertNotNil(fileManagerVM.findFolderByFullPath(fooBarFolder.standardizedFullPath))
		XCTAssertNotNil(fileManagerVM.findFileByFullPath(fooBarFile.standardizedFullPath))
	}

	@MainActor
	func testFolderRemovalThenFileAdditionAtSamePathSurvivesBatchedCleanup() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("WorkspaceRoot", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let fileManagerVM = RepoFileManagerViewModel()
		let service = try await makeTestFileSystemService(path: rootURL.path)
		let rootFolder = makeSyntheticRoot(
			at: rootURL,
			service: service,
			folderCount: 0,
			filesPerFolder: 0
		)
		let nodeFolder = FolderViewModel(
			folder: Folder(name: "Node", path: rootURL.appendingPathComponent("Node", isDirectory: true).path, modificationDate: Date()),
			rootPath: rootURL.path,
			hierarchyLevel: 1,
			isExpanded: true
		)
		let oldFile = makeIndexedFileVM(
			name: "Old.swift",
			fullPath: rootURL.appendingPathComponent("Node/Old.swift").path,
			rootFolder: rootFolder,
			service: service,
			parentFolder: nodeFolder,
			hierarchyLevel: 2
		)
		nodeFolder.addFile(oldFile)
		rootFolder.addSubfolder(nodeFolder)
		fileManagerVM.registerRootFolderForTesting(rootFolder, service: service)
		fileManagerVM.setDeltaReplayTuningForTesting(chunkSize: 4, interChunkDelayNanoseconds: 0)
		let selectedRanges = [LineRange(start: 1, end: 2)]
		await fileManagerVM.applyStoredSelection(
			StoredSelection(
				selectedPaths: [oldFile.standardizedFullPath],
				autoCodemapPaths: [oldFile.standardizedFullPath],
				slices: [:],
				codemapAutoEnabled: false
			)
		)
		fileManagerVM.seedSelectionSlicesForTesting(selectedRanges, for: oldFile)

		await fileManagerVM.receiveLiveFileSystemDeltasForTesting(
			[.folderRemoved("Node"), .fileAdded("Node")],
			forRootFolder: rootFolder
		)

		let sample = try XCTUnwrap(fileManagerVM.latestImmediateReplayPerfSampleForTesting())
		let chunk = try XCTUnwrap(sample.replayedChunks.last)
		XCTAssertEqual(sample.chunkCount, 1)
		XCTAssertEqual(chunk.incrementalDescendantScanInvocationCount, 1)
		XCTAssertFalse(chunk.incrementalIndexCleanupFallbackToRebuild)
		let nodePath = rootURL.appendingPathComponent("Node").path
		XCTAssertNil(fileManagerVM.findFolderByFullPath(nodePath))
		XCTAssertNotNil(fileManagerVM.findFileByFullPath(nodePath))
		XCTAssertNil(fileManagerVM.findFileByFullPath(oldFile.standardizedFullPath))
		XCTAssertNil(fileManagerVM.selectionSlices(for: oldFile))
		let snapshot = fileManagerVM.snapshotSelection()
		XCTAssertFalse(snapshot.selectedPaths.contains(oldFile.standardizedFullPath))
		XCTAssertFalse(snapshot.autoCodemapPaths.contains(oldFile.standardizedFullPath))
	}

	@MainActor
	func testFolderRemovalThenNestedFileAdditionCreatesFreshParentAfterBatchedCleanup() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("WorkspaceRoot", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let fileManagerVM = RepoFileManagerViewModel()
		let service = try await makeTestFileSystemService(path: rootURL.path)
		let rootFolder = makeSyntheticRoot(
			at: rootURL,
			service: service,
			folderCount: 0,
			filesPerFolder: 0
		)
		let nodeFolder = FolderViewModel(
			folder: Folder(name: "Node", path: rootURL.appendingPathComponent("Node", isDirectory: true).path, modificationDate: Date()),
			rootPath: rootURL.path,
			hierarchyLevel: 1,
			isExpanded: true
		)
		let oldFile = makeIndexedFileVM(
			name: "Old.swift",
			fullPath: rootURL.appendingPathComponent("Node/Old.swift").path,
			rootFolder: rootFolder,
			service: service,
			parentFolder: nodeFolder,
			hierarchyLevel: 2
		)
		nodeFolder.addFile(oldFile)
		rootFolder.addSubfolder(nodeFolder)
		fileManagerVM.registerRootFolderForTesting(rootFolder, service: service)
		fileManagerVM.setDeltaReplayTuningForTesting(chunkSize: 4, interChunkDelayNanoseconds: 0)

		await fileManagerVM.applyPreparedDeltasWithoutCoalescingForTesting(
			[.folderRemoved("Node"), .folderAdded("Node"), .fileAdded("Node/New.swift")],
			forRootFolder: rootFolder
		)

		let sample = try XCTUnwrap(fileManagerVM.latestImmediateReplayPerfSampleForTesting())
		let chunk = try XCTUnwrap(sample.replayedChunks.last)
		XCTAssertEqual(sample.chunkCount, 1)
		XCTAssertEqual(chunk.incrementalDescendantScanInvocationCount, 1)
		XCTAssertFalse(chunk.incrementalIndexCleanupFallbackToRebuild)
		let freshNodeFolder = try XCTUnwrap(fileManagerVM.findFolderByFullPath(rootURL.appendingPathComponent("Node", isDirectory: true).path))
		XCTAssertNotEqual(freshNodeFolder.id, nodeFolder.id)
		XCTAssertNil(fileManagerVM.findFileByFullPath(oldFile.standardizedFullPath))
		XCTAssertNotNil(fileManagerVM.findFileByFullPath(rootURL.appendingPathComponent("Node/New.swift").path))
	}

	@MainActor
	func testFolderRemovalWithStaleFileAtRemovedFolderPathFallsBackToRebuild() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("WorkspaceRoot", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let fileManagerVM = RepoFileManagerViewModel()
		let service = try await makeTestFileSystemService(path: rootURL.path)
		let rootFolder = makeSyntheticRoot(
			at: rootURL,
			service: service,
			folderCount: 0,
			filesPerFolder: 0
		)
		let nodePath = rootURL.appendingPathComponent("Node", isDirectory: true).path
		let nodeFolder = FolderViewModel(
			folder: Folder(name: "Node", path: nodePath, modificationDate: Date()),
			rootPath: rootURL.path,
			hierarchyLevel: 1,
			isExpanded: true
		)
		rootFolder.addSubfolder(nodeFolder)
		fileManagerVM.registerRootFolderForTesting(rootFolder, service: service)
		fileManagerVM.setDeltaReplayTuningForTesting(chunkSize: 4, interChunkDelayNanoseconds: 0)
		let staleFile = makeIndexedFileVM(
			name: "Node",
			fullPath: nodePath,
			rootFolder: rootFolder,
			service: service,
			parentFolder: rootFolder,
			hierarchyLevel: 1
		)
		fileManagerVM.injectIndexedFileForTesting(staleFile)
		XCTAssertNotNil(fileManagerVM.findFileByFullPath(staleFile.standardizedFullPath))

		await fileManagerVM.receiveLiveFileSystemDeltasForTesting(
			[.folderRemoved("Node")],
			forRootFolder: rootFolder
		)

		let sample = try XCTUnwrap(fileManagerVM.latestImmediateReplayPerfSampleForTesting())
		let chunk = try XCTUnwrap(sample.replayedChunks.last)
		XCTAssertEqual(sample.chunkCount, 1)
		XCTAssertEqual(chunk.incrementalDescendantScanInvocationCount, 1)
		XCTAssertTrue(chunk.incrementalIndexCleanupFallbackToRebuild)
		XCTAssertNotNil(chunk.rebuildDurationMS)
		XCTAssertNil(fileManagerVM.findFolderByFullPath(nodePath))
		XCTAssertNil(fileManagerVM.findFileByFullPath(staleFile.standardizedFullPath))
	}

	@MainActor
	func testReplayChunkBatchesCodeScanAndSliceRebaseSideEffectsOncePerChunk() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("WorkspaceRoot", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let payloadLength = 72
		let fileManagerVM = RepoFileManagerViewModel()
		let service = try await makeTestFileSystemService(path: rootURL.path)
		let rootFolder = makeSyntheticRoot(
			at: rootURL,
			service: service,
			folderCount: 2,
			filesPerFolder: 2,
			namePayloadLength: payloadLength
		)
		fileManagerVM.registerRootFolderForTesting(rootFolder, service: service)
		fileManagerVM.setDeltaReplayTuningForTesting(chunkSize: 8, interChunkDelayNanoseconds: 0)

		let modifiedOne = syntheticFileRelativePath(folderIndex: 0, fileIndex: 0, namePayloadLength: payloadLength)
		let modifiedTwo = syntheticFileRelativePath(folderIndex: 0, fileIndex: 1, namePayloadLength: payloadLength)
		let newFileRelativePath = "\(syntheticFolderName(index: 0, namePayloadLength: payloadLength))/\(syntheticFileName(index: 99, namePayloadLength: payloadLength))"
		await fileManagerVM.enqueuePendingDeltasForTesting(
			[
				.fileModified(modifiedOne, nil),
				.fileModified(modifiedTwo, nil),
				.fileAdded(newFileRelativePath)
			],
			forRootFolder: rootFolder
		)
		await fileManagerVM.flushPendingDeltas()

		let sample = try XCTUnwrap(fileManagerVM.latestDeltaReplayPerfSampleForTesting())
		let chunk = try XCTUnwrap(sample.replayedRoots.last)
		XCTAssertEqual(sample.totalChunkCount, 1)
		XCTAssertEqual(chunk.codeScanBatchInvocationCount, 1)
		XCTAssertEqual(chunk.codeScanBatchFileCount, 3)
		XCTAssertEqual(chunk.sliceRebaseBatchInvocationCount, 1)
		XCTAssertEqual(chunk.sliceRebaseCandidateCount, 2)
		XCTAssertEqual(sample.totalCodeScanBatchFileCount, 3)
		XCTAssertEqual(sample.totalSliceRebaseCandidateCount, 2)
		XCTAssertNotNil(fileManagerVM.findFileByRelativePath(newFileRelativePath))
	}

	@MainActor
	func testReplayProcessesDeltasThatArriveWhileReplayIsAlreadyDraining() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("WorkspaceRoot", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let payloadLength = 64
		let fileManagerVM = RepoFileManagerViewModel()
		let service = try await makeTestFileSystemService(path: rootURL.path)
		let rootFolder = makeSyntheticRoot(
			at: rootURL,
			service: service,
			folderCount: 1,
			filesPerFolder: 0,
			namePayloadLength: payloadLength
		)
		fileManagerVM.registerRootFolderForTesting(rootFolder, service: service)
		fileManagerVM.setDeltaReplayTuningForTesting(chunkSize: 1, interChunkDelayNanoseconds: 50_000_000)
		fileManagerVM.setWindowFocused(false)

		let firstBurstFolder = "FirstBurst-\(String(repeating: "a", count: payloadLength))"
		let secondBurstFolder = "SecondBurst-\(String(repeating: "b", count: payloadLength))"
		let secondBurstFile = syntheticFileName(index: 909, namePayloadLength: payloadLength)
		let firstBurst: [FileSystemDelta] = [
			.folderAdded(firstBurstFolder),
			.folderModified(syntheticFolderName(index: 0, namePayloadLength: payloadLength), nil)
		]
		let secondBurst: [FileSystemDelta] = [
			.folderAdded(secondBurstFolder),
			.fileAdded("\(secondBurstFolder)/\(secondBurstFile)")
		]

		var cancellable: AnyCancellable?
		var scheduledSecondBurst = false
		var injectedSecondBurst = false
		let injectedExpectation = expectation(description: "Injected second replay burst")
		cancellable = fileManagerVM.fileSystemDeltasAppliedPublisher.sink { event in
			guard event.rootKey == rootFolder.standardizedFullPath else { return }
			guard !scheduledSecondBurst else { return }
			scheduledSecondBurst = true
			Task { @MainActor in
				await fileManagerVM.receiveLiveFileSystemDeltasForTesting(secondBurst, forRootFolder: rootFolder)
				injectedSecondBurst = true
				injectedExpectation.fulfill()
			}
		}
		defer { cancellable?.cancel() }

		await fileManagerVM.receiveLiveFileSystemDeltasForTesting(firstBurst, forRootFolder: rootFolder)
		let pendingDeltaCountBeforeReplay = await fileManagerVM.pendingDeltaCountForTesting(forRootFolder: rootFolder)
		XCTAssertEqual(pendingDeltaCountBeforeReplay, firstBurst.count)

		fileManagerVM.setWindowFocused(true)
		await fulfillment(of: [injectedExpectation], timeout: 2.0)
		await fileManagerVM.waitForDeltaReplayCompletionForTesting()

		let sample = try XCTUnwrap(fileManagerVM.latestDeltaReplayPerfSampleForTesting())
		let pendingDeltaCountAfterReplay = await fileManagerVM.pendingDeltaCountForTesting(forRootFolder: rootFolder)
		XCTAssertTrue(injectedSecondBurst)
		XCTAssertEqual(pendingDeltaCountAfterReplay, 0)
		XCTAssertGreaterThanOrEqual(sample.whileLoopPassCount, 2)
		XCTAssertGreaterThanOrEqual(sample.totalRootPassCount, 2)
		XCTAssertEqual(sample.totalChunkCount, 4)
		XCTAssertEqual(sample.rootPasses.count, 2)
		XCTAssertEqual(sample.totalOnRootFoldersChangedInvocationCount, 2)
		XCTAssertEqual(sample.totalDeltaAppliedPublisherInvocationCount, 2)
		XCTAssertEqual(sample.totalSnapshotInvalidationCount, 2)
		XCTAssertNotNil(fileManagerVM.findFolderByFullPath(rootURL.appendingPathComponent(firstBurstFolder, isDirectory: true).path))
		let secondBurstFolderURL = rootURL.appendingPathComponent(secondBurstFolder, isDirectory: true)
		XCTAssertNotNil(fileManagerVM.findFolderByFullPath(secondBurstFolderURL.path))
		XCTAssertNotNil(fileManagerVM.findFileByFullPath(secondBurstFolderURL.appendingPathComponent(secondBurstFile).path))
	}

	@MainActor
	func testLateArrivalsDuringReplayBecomeNextPreparedPassAndStillFanOutOncePerPass() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("WorkspaceRoot", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let payloadLength = 68
		let fileManagerVM = RepoFileManagerViewModel()
		let service = try await makeTestFileSystemService(path: rootURL.path)
		let rootFolder = makeSyntheticRoot(
			at: rootURL,
			service: service,
			folderCount: 1,
			filesPerFolder: 0,
			namePayloadLength: payloadLength
		)
		fileManagerVM.registerRootFolderForTesting(rootFolder, service: service)
		fileManagerVM.setDeltaReplayTuningForTesting(chunkSize: 1, interChunkDelayNanoseconds: 50_000_000)
		fileManagerVM.setWindowFocused(false)

		let firstBurstFolder = "LatePassA-" + String(repeating: "a", count: payloadLength)
		let secondBurstFolder = "LatePassB-" + String(repeating: "b", count: payloadLength)
		let secondBurstFile = syntheticFileName(index: 707, namePayloadLength: payloadLength)
		let firstBurst: [FileSystemDelta] = [
			.folderAdded(firstBurstFolder),
			.folderModified(syntheticFolderName(index: 0, namePayloadLength: payloadLength), nil)
		]
		let secondBurst: [FileSystemDelta] = [
			.folderAdded(secondBurstFolder),
			.fileAdded("\(secondBurstFolder)/\(secondBurstFile)")
		]

		var onRootFoldersChangedCount = 0
		var fileSystemChangedCount = 0
		var appliedEventCount = 0
		var injectedSecondBurst = false
		fileManagerVM.onRootFoldersChanged = {
			onRootFoldersChangedCount += 1
		}
		let fileSystemChangedCancellable = fileManagerVM.fileSystemChangedPublisher.sink {
			fileSystemChangedCount += 1
		}
		let appliedCancellable = fileManagerVM.fileSystemDeltasAppliedPublisher.sink { _ in
			appliedEventCount += 1
		}
		defer {
			fileSystemChangedCancellable.cancel()
			appliedCancellable.cancel()
		}

		await fileManagerVM.receiveLiveFileSystemDeltasForTesting(firstBurst, forRootFolder: rootFolder)
		Task { @MainActor in
			try? await Task.sleep(nanoseconds: 20_000_000)
			await fileManagerVM.receiveLiveFileSystemDeltasForTesting(secondBurst, forRootFolder: rootFolder)
			injectedSecondBurst = true
		}
		fileManagerVM.setWindowFocused(true)
		try? await Task.sleep(nanoseconds: 200_000_000)
		await fileManagerVM.waitForDeltaReplayCompletionForTesting()

		let sample = try XCTUnwrap(fileManagerVM.latestDeltaReplayPerfSampleForTesting())
		XCTAssertTrue(injectedSecondBurst)
		XCTAssertEqual(sample.rootPasses.count, 2)
		XCTAssertEqual(sample.totalOnRootFoldersChangedInvocationCount, 2)
		XCTAssertEqual(sample.totalDeltaAppliedPublisherInvocationCount, 2)
		XCTAssertEqual(sample.totalSnapshotInvalidationCount, 2)
		XCTAssertEqual(onRootFoldersChangedCount, 2)
		XCTAssertEqual(fileSystemChangedCount, 2)
		XCTAssertEqual(appliedEventCount, 2)
	}

	@MainActor
	func testDeltaReplayPerfSampleReportsExpectedChunkCountsForLargeLongPathBurst() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("WorkspaceRoot", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let fileManagerVM = RepoFileManagerViewModel()
		let service = try await makeTestFileSystemService(path: rootURL.path)
		let rootFolder = makeSyntheticRoot(
			at: rootURL,
			service: service,
			folderCount: 250,
			filesPerFolder: 0,
			namePayloadLength: 96
		)
		fileManagerVM.registerRootFolderForTesting(rootFolder, service: service)

		let deltas = (0..<250).map { index in
			FileSystemDelta.folderModified(syntheticFolderName(index: index, namePayloadLength: 96), nil)
		}
		await fileManagerVM.enqueuePendingDeltasForTesting(deltas, forRootFolder: rootFolder)

		await fileManagerVM.flushPendingDeltas()

		let sample = try XCTUnwrap(fileManagerVM.latestDeltaReplayPerfSampleForTesting())
		XCTAssertFalse(sample.aggressive)
		XCTAssertEqual(sample.pendingRootCountAtStart, 1)
		XCTAssertEqual(sample.pendingDeltaCountAtStart, 250)
		XCTAssertEqual(sample.totalRootPassCount, 1)
		XCTAssertEqual(sample.totalChunkCount, 3)
		XCTAssertEqual(sample.replayedRoots.count, 3)
		XCTAssertEqual(Set(sample.replayedRoots.map(\.passIndex)), Set([1]))
		XCTAssertEqual(sample.replayedRoots.map(\.chunkIndexInPass), [0, 1, 2])
		XCTAssertTrue(sample.replayedRoots.allSatisfy { $0.rootKey == rootFolder.standardizedFullPath })
		XCTAssertTrue(sample.replayedRoots.allSatisfy { $0.chunkCountInPass == 3 })
		XCTAssertEqual(sample.totalCoalescedDeltaCount, 250)
		XCTAssertEqual(sample.totalDiscardedDeltaCount, 0)
		XCTAssertEqual(Set(sample.replayedRoots.map(\.batchQueuedDeltaCount)), Set([250]))
		XCTAssertEqual(Set(sample.replayedRoots.map(\.batchCoalescedDeltaCount)), Set([250]))
		XCTAssertEqual(Set(sample.replayedRoots.map(\.batchDiscardedDeltaCount)), Set([0]))
		XCTAssertEqual(sample.replayedRoots.map(\.chunkDeltaCount).reduce(0, +), 250)
		XCTAssertEqual(sample.replayedRoots.map(\.modifiedCount).reduce(0, +), 250)
		XCTAssertGreaterThanOrEqual(sample.totalPreparationDurationMS, 0)
		XCTAssertGreaterThanOrEqual(sample.totalCoalesceDurationMS, 0)
	}

	@MainActor
	func testLargeLongPathFolderOnlyRootRebuildStaysOwnershipBacked() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootAURL = tempParent.appendingPathComponent("RootA", isDirectory: true)
		let rootBURL = tempParent.appendingPathComponent("RootB", isDirectory: true)
		try FileManager.default.createDirectory(at: rootAURL, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: rootBURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let fileManagerVM = RepoFileManagerViewModel()
		let serviceA = try await makeTestFileSystemService(path: rootAURL.path)
		let serviceB = try await makeTestFileSystemService(path: rootBURL.path)
		let rootAFolder = makeSyntheticRoot(
			at: rootAURL,
			service: serviceA,
			folderCount: 180,
			filesPerFolder: 0,
			namePayloadLength: 96
		)
		let rootBFolder = makeSyntheticRoot(
			at: rootBURL,
			service: serviceB,
			folderCount: 24,
			filesPerFolder: 4,
			namePayloadLength: 48
		)

		fileManagerVM.registerRootFolderForTesting(rootAFolder, service: serviceA)
		fileManagerVM.registerRootFolderForTesting(rootBFolder, service: serviceB)
		fileManagerVM.registerRootFolderForTesting(rootAFolder, service: serviceA)

		let metrics = fileManagerVM.rootReferenceCleanupMetricsForTesting(rootAFolder)
		XCTAssertEqual(metrics.matchedFolderKeys, 181)
		XCTAssertEqual(metrics.cleanupCandidateFolderKeys, 181)
		XCTAssertEqual(metrics.matchedFileKeys, 0)
		XCTAssertEqual(metrics.cleanupCandidateFileKeys, 0)
		XCTAssertFalse(metrics.usedFallbackGlobalScan)
		XCTAssertGreaterThan(metrics.totalFolderKeys, metrics.cleanupCandidateFolderKeys)

		let sample = try XCTUnwrap(fileManagerVM.latestIndexRebuildPerfSampleForTesting())
		XCTAssertEqual(sample.rootKey, rootAFolder.standardizedFullPath)
		XCTAssertEqual(sample.cleanupCandidateFolderKeys, 181)
		XCTAssertEqual(sample.cleanupCandidateFileKeys, 0)
		XCTAssertFalse(sample.usedOwnershipFallback)
	}

	@MainActor
	func testRootRebuildPerfMatrixCharacterization() async throws {
		struct ScenarioReport: Codable {
			struct RebuildReport: Codable {
				let averageTotalDurationMS: Double
				let averageCleanupCandidateSelectionDurationMS: Double
				let averageCleanupFolderRemovalDurationMS: Double
				let averageCleanupFileRemovalDurationMS: Double
				let averageReindexTraversalDurationMS: Double
				let averageCleanupCandidateFolderKeys: Double
				let averageCleanupCandidateFileKeys: Double
				let usedOwnershipFallback: Bool
			}
			struct ReplayReport: Codable {
				let totalDurationMS: Double
				let pendingRootCountAtStart: Int
				let pendingDeltaCountAtStart: Int
				let whileLoopPassCount: Int
				let totalRootPassCount: Int
				let totalChunkCount: Int
				let totalCoalescedDeltaCount: Int
				let totalDiscardedDeltaCount: Int
				let totalCoalesceDurationMS: Double
				let totalPreparationDurationMS: Double
				let totalApplyAwaitDurationMS: Double
				let totalYieldDurationMS: Double
				let totalInterChunkSleepDurationMS: Double
				let totalDeltaLoopDurationMS: Double
				let totalFlushPendingInsertsDurationMS: Double
				let totalUpdateFolderStatesDurationMS: Double
				let totalOnRootFoldersChangedDurationMS: Double
				let totalRebuildDurationMS: Double
				let totalInvalidateSnapshotDurationMS: Double
				let replayedRootCount: Int
				let targetPassCount: Int?
				let targetChunkCount: Int?
				let targetBatchQueuedDeltaCount: Int?
				let targetBatchCoalescedDeltaCount: Int?
				let targetBatchDiscardedDeltaCount: Int?
				let targetChunkDeltaCount: Int?
				let targetApplyAwaitDurationMS: Double?
				let targetYieldDurationMS: Double?
				let targetInterChunkSleepDurationMS: Double?
				let targetDeltaLoopDurationMS: Double?
				let targetPendingInsertRootCountBeforeFlush: Int?
				let targetPendingInsertEntryCountBeforeFlush: Int?
				let targetPendingInsertEntryCountForReplayedRootBeforeFlush: Int?
				let targetPendingInsertEntryCountRemainingAfterFlush: Int?
				let targetFlushPendingInsertsDurationMS: Double?
				let targetUpdateFolderStatesDurationMS: Double?
				let targetOnRootFoldersChangedDurationMS: Double?
				let targetRebuildDurationMS: Double?
				let targetRebuildCleanupCandidateSelectionDurationMS: Double?
				let targetRebuildCleanupFolderRemovalDurationMS: Double?
				let targetRebuildCleanupFileRemovalDurationMS: Double?
				let targetRebuildTraversalDurationMS: Double?
				let targetInvalidateSnapshotDurationMS: Double?
				let targetTotalApplyDurationMS: Double?
			}
			let scenario: String
			let rebuild: RebuildReport
			let replay: ReplayReport
		}

		func scenarioReport(
			name: String,
			includeSiblings: Bool,
			includeGitData: Bool
		) async throws -> ScenarioReport {
			let tempParent = FileManager.default.temporaryDirectory
				.appendingPathComponent(UUID().uuidString, isDirectory: true)
			try FileManager.default.createDirectory(at: tempParent, withIntermediateDirectories: true)
			defer { try? FileManager.default.removeItem(at: tempParent) }

			let fileManagerVM = RepoFileManagerViewModel()
			let targetURL = tempParent.appendingPathComponent("TargetRoot", isDirectory: true)
			try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
			let targetService = try await makeTestFileSystemService(path: targetURL.path)
			let targetRoot = makeSyntheticRoot(
				at: targetURL,
				service: targetService,
				folderCount: 20,
				filesPerFolder: 30
			)
			fileManagerVM.registerRootFolderForTesting(targetRoot, service: targetService)

			if includeSiblings {
				for siblingIndex in 0..<6 {
					let siblingURL = tempParent.appendingPathComponent("Sibling\(siblingIndex)", isDirectory: true)
					try FileManager.default.createDirectory(at: siblingURL, withIntermediateDirectories: true)
					let siblingService = try await makeTestFileSystemService(path: siblingURL.path)
					let siblingRoot = makeSyntheticRoot(
						at: siblingURL,
						service: siblingService,
						folderCount: 20,
						filesPerFolder: 60
					)
					fileManagerVM.registerRootFolderForTesting(siblingRoot, service: siblingService)
				}
			}

			if includeGitData {
				let gitDataURL = tempParent.appendingPathComponent("_git_data", isDirectory: true)
				try FileManager.default.createDirectory(at: gitDataURL, withIntermediateDirectories: true)
				let gitDataService = try await makeTestFileSystemService(path: gitDataURL.path)
				let gitDataRoot = makeSyntheticRoot(
					at: gitDataURL,
					service: gitDataService,
					folderCount: 12,
					filesPerFolder: 120,
					isSystemRoot: true
				)
				fileManagerVM.registerRootFolderForTesting(gitDataRoot, service: gitDataService)
			}

			var rebuildSamples: [RepoFileManagerViewModel.IndexRebuildPerfSample] = []
			for _ in 0..<3 {
				fileManagerVM.registerRootFolderForTesting(targetRoot, service: targetService)
				rebuildSamples.append(try XCTUnwrap(fileManagerVM.latestIndexRebuildPerfSampleForTesting()))
			}

			await fileManagerVM.enqueuePendingDeltasForTesting([.folderAdded("ReplayFolder")], forRootFolder: targetRoot)
			await fileManagerVM.flushPendingDeltas()
			let replaySample = try XCTUnwrap(fileManagerVM.latestDeltaReplayPerfSampleForTesting())
			let replayedTargetSamples = replaySample.replayedRoots.filter { $0.rootKey == targetRoot.standardizedFullPath }
			let replayedTarget = replayedTargetSamples.last

			func average(_ values: [Double]) -> Double {
				guard !values.isEmpty else { return 0 }
				return values.reduce(0, +) / Double(values.count)
			}

			return ScenarioReport(
				scenario: name,
				rebuild: .init(
					averageTotalDurationMS: average(rebuildSamples.map(\.totalDurationMS)),
					averageCleanupCandidateSelectionDurationMS: average(rebuildSamples.map(\.cleanupCandidateSelectionDurationMS)),
					averageCleanupFolderRemovalDurationMS: average(rebuildSamples.map(\.cleanupFolderRemovalDurationMS)),
					averageCleanupFileRemovalDurationMS: average(rebuildSamples.map(\.cleanupFileRemovalDurationMS)),
					averageReindexTraversalDurationMS: average(rebuildSamples.map(\.reindexTraversalDurationMS)),
					averageCleanupCandidateFolderKeys: average(rebuildSamples.map { Double($0.cleanupCandidateFolderKeys) }),
					averageCleanupCandidateFileKeys: average(rebuildSamples.map { Double($0.cleanupCandidateFileKeys) }),
					usedOwnershipFallback: rebuildSamples.contains { $0.usedOwnershipFallback }
				),
				replay: .init(
					totalDurationMS: replaySample.totalDurationMS,
					pendingRootCountAtStart: replaySample.pendingRootCountAtStart,
					pendingDeltaCountAtStart: replaySample.pendingDeltaCountAtStart,
					whileLoopPassCount: replaySample.whileLoopPassCount,
					totalRootPassCount: replaySample.totalRootPassCount,
					totalChunkCount: replaySample.totalChunkCount,
					totalCoalescedDeltaCount: replaySample.totalCoalescedDeltaCount,
					totalDiscardedDeltaCount: replaySample.totalDiscardedDeltaCount,
					totalCoalesceDurationMS: replaySample.totalCoalesceDurationMS,
					totalPreparationDurationMS: replaySample.totalPreparationDurationMS,
					totalApplyAwaitDurationMS: replaySample.totalApplyAwaitDurationMS,
					totalYieldDurationMS: replaySample.totalYieldDurationMS,
					totalInterChunkSleepDurationMS: replaySample.totalInterChunkSleepDurationMS,
					totalDeltaLoopDurationMS: replaySample.totalDeltaLoopDurationMS,
					totalFlushPendingInsertsDurationMS: replaySample.totalFlushPendingInsertsDurationMS,
					totalUpdateFolderStatesDurationMS: replaySample.totalUpdateFolderStatesDurationMS,
					totalOnRootFoldersChangedDurationMS: replaySample.totalOnRootFoldersChangedDurationMS,
					totalRebuildDurationMS: replaySample.totalRebuildDurationMS,
					totalInvalidateSnapshotDurationMS: replaySample.totalInvalidateSnapshotDurationMS,
					replayedRootCount: replaySample.replayedRoots.count,
					targetPassCount: replayedTargetSamples.isEmpty ? nil : Set(replayedTargetSamples.map(\.passIndex)).count,
					targetChunkCount: replayedTargetSamples.isEmpty ? nil : replayedTargetSamples.count,
					targetBatchQueuedDeltaCount: replayedTarget?.batchQueuedDeltaCount,
					targetBatchCoalescedDeltaCount: replayedTarget?.batchCoalescedDeltaCount,
					targetBatchDiscardedDeltaCount: replayedTarget?.batchDiscardedDeltaCount,
					targetChunkDeltaCount: replayedTarget?.chunkDeltaCount,
					targetApplyAwaitDurationMS: replayedTargetSamples.isEmpty ? nil : replayedTargetSamples.reduce(0) { $0 + $1.applyAwaitDurationMS },
					targetYieldDurationMS: replayedTargetSamples.isEmpty ? nil : replayedTargetSamples.reduce(0) { $0 + $1.yieldDurationMSAfterChunk },
					targetInterChunkSleepDurationMS: replayedTargetSamples.isEmpty ? nil : replayedTargetSamples.reduce(0) { $0 + $1.interChunkSleepDurationMSAfterChunk },
					targetDeltaLoopDurationMS: replayedTarget?.deltaLoopDurationMS,
					targetPendingInsertRootCountBeforeFlush: replayedTarget?.pendingInsertRootCountBeforeFlush,
					targetPendingInsertEntryCountBeforeFlush: replayedTarget?.pendingInsertEntryCountBeforeFlush,
					targetPendingInsertEntryCountForReplayedRootBeforeFlush: replayedTarget?.pendingInsertEntryCountForReplayedRootBeforeFlush,
					targetPendingInsertEntryCountRemainingAfterFlush: replayedTarget?.pendingInsertEntryCountRemainingAfterFlush,
					targetFlushPendingInsertsDurationMS: replayedTarget?.flushPendingInsertsDurationMS,
					targetUpdateFolderStatesDurationMS: replayedTarget?.updateFolderStatesDurationMS,
					targetOnRootFoldersChangedDurationMS: replayedTarget?.onRootFoldersChangedDurationMS,
					targetRebuildDurationMS: replayedTarget?.rebuildDurationMS,
					targetRebuildCleanupCandidateSelectionDurationMS: replayedTarget?.rebuildCleanupCandidateSelectionDurationMS,
					targetRebuildCleanupFolderRemovalDurationMS: replayedTarget?.rebuildCleanupFolderRemovalDurationMS,
					targetRebuildCleanupFileRemovalDurationMS: replayedTarget?.rebuildCleanupFileRemovalDurationMS,
					targetRebuildTraversalDurationMS: replayedTarget?.rebuildTraversalDurationMS,
					targetInvalidateSnapshotDurationMS: replayedTarget?.invalidateSnapshotDurationMS,
					targetTotalApplyDurationMS: replayedTarget?.totalApplyDurationMS
				)
			)
		}

		let reports = try await [
			scenarioReport(name: "baseline", includeSiblings: false, includeGitData: false),
			scenarioReport(name: "siblings_only", includeSiblings: true, includeGitData: false),
			scenarioReport(name: "git_data_only", includeSiblings: false, includeGitData: true),
			scenarioReport(name: "siblings_plus_git_data", includeSiblings: true, includeGitData: true)
		]

		let reportURL = FileManager.default.temporaryDirectory.appendingPathComponent("repo-file-manager-perf-matrix.json")
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		try encoder.encode(reports).write(to: reportURL)

		XCTAssertEqual(reports.count, 4)
		XCTAssertTrue(reports.allSatisfy { !$0.rebuild.usedOwnershipFallback })
		XCTAssertTrue(reports.allSatisfy { $0.replay.pendingRootCountAtStart == 1 })
	}

	@MainActor
	func testIndexRebuildPerfSampleReportsScopedCleanupAndTraversalCounts() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("WorkspaceRoot", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let fileManagerVM = RepoFileManagerViewModel()
		let service = try await makeTestFileSystemService(path: rootURL.path)
		let rootFolder = FolderViewModel(
			folder: Folder(name: "WorkspaceRoot", path: rootURL.path, modificationDate: Date()),
			rootPath: rootURL.path,
			isExpanded: true
		)
		let nestedFolder = FolderViewModel(
			folder: Folder(name: "Sources", path: rootURL.appendingPathComponent("Sources", isDirectory: true).path, modificationDate: Date()),
			rootPath: rootURL.path,
			hierarchyLevel: 1,
			isExpanded: true
		)
		let nestedFile = makeIndexedFileVM(
			name: "A.swift",
			fullPath: rootURL.appendingPathComponent("Sources/A.swift").path,
			rootFolder: rootFolder,
			service: service,
			parentFolder: nestedFolder,
			hierarchyLevel: 1
		)
		nestedFolder.addFile(nestedFile)
		rootFolder.addSubfolder(nestedFolder)

		fileManagerVM.registerRootFolderForTesting(rootFolder, service: service)
		fileManagerVM.registerRootFolderForTesting(rootFolder, service: service)

		let sample = try XCTUnwrap(fileManagerVM.latestIndexRebuildPerfSampleForTesting())
		XCTAssertEqual(sample.rootKey, rootFolder.standardizedFullPath)
		XCTAssertEqual(sample.cleanupCandidateFolderKeys, 2)
		XCTAssertEqual(sample.cleanupCandidateFileKeys, 1)
		XCTAssertEqual(sample.reindexVisitedFolderCount, 2)
		XCTAssertEqual(sample.reindexVisitedFileCount, 1)
		XCTAssertFalse(sample.usedOwnershipFallback)
		XCTAssertGreaterThanOrEqual(sample.totalDurationMS, 0)
	}

	@MainActor
	func testDeltaReplayPerfSampleCapturesQueuedReplay() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("WorkspaceRoot", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let fileManagerVM = RepoFileManagerViewModel()
		let service = try await makeTestFileSystemService(path: rootURL.path)
		let rootFolder = FolderViewModel(
			folder: Folder(name: "WorkspaceRoot", path: rootURL.path, modificationDate: Date()),
			rootPath: rootURL.path,
			isExpanded: true
		)
		let nestedFolder = FolderViewModel(
			folder: Folder(name: "Sources", path: rootURL.appendingPathComponent("Sources", isDirectory: true).path, modificationDate: Date()),
			rootPath: rootURL.path,
			hierarchyLevel: 1,
			isExpanded: true
		)
		rootFolder.addSubfolder(nestedFolder)

		fileManagerVM.registerRootFolderForTesting(rootFolder, service: service)
		await fileManagerVM.enqueuePendingDeltasForTesting([.folderModified("Sources", nil)], forRootFolder: rootFolder)

		await fileManagerVM.flushPendingDeltas()

		let sample = try XCTUnwrap(fileManagerVM.latestDeltaReplayPerfSampleForTesting())
		XCTAssertFalse(sample.aggressive)
		XCTAssertEqual(sample.pendingRootCountAtStart, 1)
		XCTAssertEqual(sample.pendingDeltaCountAtStart, 1)
		XCTAssertEqual(sample.whileLoopPassCount, 2)
		XCTAssertEqual(sample.totalRootPassCount, 1)
		XCTAssertEqual(sample.totalChunkCount, 1)
		XCTAssertEqual(sample.totalCoalescedDeltaCount, 1)
		XCTAssertEqual(sample.totalDiscardedDeltaCount, 0)
		XCTAssertEqual(sample.replayedRoots.count, 1)
		XCTAssertEqual(sample.replayedRoots.first?.batchQueuedDeltaCount, 1)
		XCTAssertEqual(sample.replayedRoots.first?.batchCoalescedDeltaCount, 1)
		XCTAssertEqual(sample.replayedRoots.first?.chunkDeltaCount, 1)
		XCTAssertEqual(sample.replayedRoots.first?.pendingInsertRootCountBeforeFlush, 0)
		XCTAssertEqual(sample.replayedRoots.first?.pendingInsertEntryCountBeforeFlush, 0)
		XCTAssertEqual(sample.replayedRoots.first?.pendingInsertEntryCountRemainingAfterFlush, 0)
		XCTAssertEqual(sample.totalInterChunkSleepDurationMS, 0)
		XCTAssertEqual(sample.replayedRoots.first?.interChunkSleepDurationMSAfterChunk, 0)
		XCTAssertEqual(sample.replayedRoots.first?.rootKey, rootFolder.standardizedFullPath)
		XCTAssertEqual(sample.replayedRoots.first?.modifiedCount, 1)
		XCTAssertNil(sample.replayedRoots.first?.rebuildDurationMS)
		XCTAssertGreaterThanOrEqual(sample.totalPreparationDurationMS, 0)
		XCTAssertGreaterThanOrEqual(sample.totalCoalesceDurationMS, 0)
		XCTAssertGreaterThanOrEqual(sample.totalDurationMS, 0)
	}

	@MainActor
	func testRootReferenceCleanupMetricsIncludeSupplementalGitDataEntries() async throws {
		let tempParent = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = tempParent.appendingPathComponent("WorkspaceRoot", isDirectory: true)
		let gitDataURL = tempParent.appendingPathComponent("_git_data", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: gitDataURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tempParent) }

		let fileManagerVM = RepoFileManagerViewModel()
		let workspaceService = try await makeTestFileSystemService(path: rootURL.path)
		let gitDataService = try await makeTestFileSystemService(path: gitDataURL.path)
		let workspaceRoot = FolderViewModel(
			folder: Folder(name: "WorkspaceRoot", path: rootURL.path, modificationDate: Date()),
			rootPath: rootURL.path,
			isExpanded: true
		)
		let gitDataRoot = FolderViewModel(
			folder: Folder(name: "_git_data", path: gitDataURL.path, modificationDate: Date()),
			rootPath: gitDataURL.path,
			isExpanded: true,
			isSystemRoot: true
		)
		let workspaceFile = makeIndexedFileVM(
			name: "A.swift",
			fullPath: rootURL.appendingPathComponent("Sources/A.swift").path,
			rootFolder: workspaceRoot,
			service: workspaceService
		)
		let gitDataFile = makeIndexedFileVM(
			name: "MAP.txt",
			fullPath: gitDataURL.appendingPathComponent("MAP.txt").path,
			rootFolder: gitDataRoot,
			service: gitDataService
		)
		workspaceRoot.addFile(workspaceFile)
		gitDataRoot.addFile(gitDataFile)

		fileManagerVM.registerRootFolderForTesting(workspaceRoot, service: workspaceService)
		fileManagerVM.registerRootFolderForTesting(gitDataRoot, service: gitDataService)

		let metrics = fileManagerVM.rootReferenceCleanupMetricsForTesting(workspaceRoot)
		XCTAssertEqual(metrics.matchedFileKeys, 1)
		XCTAssertEqual(metrics.cleanupCandidateFileKeys, 1)
		XCTAssertEqual(metrics.totalFileKeys, 2)
		XCTAssertFalse(metrics.usedFallbackGlobalScan)
		XCTAssertGreaterThan(metrics.totalFileKeys, metrics.cleanupCandidateFileKeys)
	}
}
