import XCTest
@testable import RepoPrompt

@MainActor
final class CodeMapExtractorTests: XCTestCase {
	private func makeTestFileSystemService(path: String) async throws -> FileSystemService {
		try await FileSystemService(
			path: path,
			respectGitignore: false,
			skipSymlinks: true
		)
	}

	private func makeAPI(
		filePath: String,
		definedTypeName: String? = nil,
		referencedTypes: [String] = []
	) -> FileAPI {
		FileAPI(
			filePath: filePath,
			imports: [],
			classes: definedTypeName.map { [ClassInfo(name: $0, methods: [], properties: [])] } ?? [],
			functions: [],
			enums: [],
			globalVars: [],
			macros: [],
			referencedTypes: referencedTypes
		)
	}

	func testGetAutoReferencedAPIsDedupesByStandardizedPath() {
		let selectedAPI = makeAPI(
			filePath: "/Users/test/project/Selected.swift",
			referencedTypes: ["SharedType", "SharedTypeAlias"]
		)
		let referencedA = makeAPI(
			filePath: "/Users/test/project/src/./Feature/../Shared.swift",
			definedTypeName: "SharedType"
		)
		let referencedB = makeAPI(
			filePath: "/Users/test/project/src/Shared.swift",
			definedTypeName: "SharedTypeAlias"
		)

		let included = CodeMapExtractor.getAutoReferencedAPIs(
			selectedAPIs: [selectedAPI],
			unselectedAPIs: [referencedA, referencedB]
		)

		XCTAssertEqual(included.count, 1)
		XCTAssertEqual(
			included.first.map { StandardizedPath.absolute($0.filePath) },
			StandardizedPath.absolute(referencedA.filePath)
		)
	}

	func testGetCodeMapFilePathsAutoNormalizesReferencedPathsForRelativeDisplay() async throws {
		let rootPath = "/Users/test/project"
		let service = try await makeTestFileSystemService(path: FileManager.default.temporaryDirectory.path)

		let selectedFile = File(name: "Selected.swift", path: "\(rootPath)/Selected.swift", modificationDate: Date())
		let selectedFileVM = FileViewModel(
			file: selectedFile,
			rootPath: rootPath,
			hierarchyLevel: 0,
			rootIdentifier: UUID(),
			rootFolderPath: rootPath,
			fileSystemService: service
		)
		selectedFileVM.setCodeMap(makeAPI(
			filePath: selectedFileVM.standardizedFullPath,
			referencedTypes: ["UtilType"]
		))

		let rootFolder = FolderViewModel(
			folder: Folder(name: "project", path: rootPath, modificationDate: Date()),
			rootPath: rootPath,
			isExpanded: true
		)

		let referencedAPI = makeAPI(
			filePath: "\(rootPath)/src/./Feature/../Util.swift",
			definedTypeName: "UtilType"
		)

		let result = CodeMapExtractor.getCodeMapFilePaths(
			codeMapUsage: .auto,
			selectedFiles: [selectedFileVM],
			allFileAPIs: [selectedFileVM.fileAPI!, referencedAPI],
			filePathDisplay: .relative,
			rootFolders: [rootFolder]
		)

		XCTAssertEqual(result, ["src/Util.swift"])
	}

	func testGetCodeMapFilePathsRelativePrefixesLeafNameForMultipleRoots() {
		let rootA = FolderViewModel(
			folder: Folder(name: "Frontend", path: "/Users/test/workspaces/Frontend", modificationDate: Date()),
			rootPath: "/Users/test/workspaces/Frontend",
			isExpanded: true
		)
		let rootB = FolderViewModel(
			folder: Folder(name: "Backend", path: "/Users/test/workspaces/Backend", modificationDate: Date()),
			rootPath: "/Users/test/workspaces/Backend",
			isExpanded: true
		)

		let result = CodeMapExtractor.getCodeMapFilePaths(
			codeMapUsage: .complete,
			selectedFiles: [],
			allFileAPIs: [makeAPI(filePath: "/Users/test/workspaces/Backend/src/./Feature/../Util.swift")],
			filePathDisplay: .relative,
			rootFolders: [rootA, rootB]
		)

		XCTAssertEqual(result, ["Backend/src/Util.swift"])
	}

	func testGetCodeMapFilePathsSelectedOnlyReportsAcceptedSelectedAPIs() async throws {
		let rootPath = "/Users/test/project"
		let service = try await makeTestFileSystemService(path: FileManager.default.temporaryDirectory.path)
		let acceptedFile = FileViewModel(
			file: File(name: "Good.swift", path: "\(rootPath)/Good.swift", modificationDate: Date()),
			rootPath: rootPath,
			hierarchyLevel: 0,
			rootIdentifier: UUID(),
			rootFolderPath: rootPath,
			fileSystemService: service
		)
		acceptedFile.setCodeMap(makeAPI(filePath: acceptedFile.standardizedFullPath, definedTypeName: "GoodType"))
		let missingAPIFile = FileViewModel(
			file: File(name: "Missing.swift", path: "\(rootPath)/Missing.swift", modificationDate: Date()),
			rootPath: rootPath,
			hierarchyLevel: 0,
			rootIdentifier: UUID(),
			rootFolderPath: rootPath,
			fileSystemService: service
		)
		let mismatchedFile = FileViewModel(
			file: File(name: "Mismatch.swift", path: "\(rootPath)/Mismatch.swift", modificationDate: Date()),
			rootPath: rootPath,
			hierarchyLevel: 0,
			rootIdentifier: UUID(),
			rootFolderPath: rootPath,
			fileSystemService: service
		)
		mismatchedFile.setCodeMap(makeAPI(filePath: "\(rootPath)-old/Mismatch.swift", definedTypeName: "OldType"))
		let rootFolder = FolderViewModel(
			folder: Folder(name: "project", path: rootPath, modificationDate: Date()),
			rootPath: rootPath,
			isExpanded: true
		)

		let paths = CodeMapExtractor.getCodeMapFilePaths(
			codeMapUsage: .selected,
			selectedFiles: [acceptedFile, missingAPIFile, mismatchedFile],
			allFileAPIs: [],
			filePathDisplay: .relative,
			rootFolders: [rootFolder]
		)

		XCTAssertEqual(paths, ["Good.swift"])
	}

	func testBuildLocalDefinitionBlockFiltersAPIsOutsideCurrentRoots() {
		let rootPath = "/Users/test/project"
		let rootFolder = FolderViewModel(
			folder: Folder(name: "project", path: rootPath, modificationDate: Date()),
			rootPath: rootPath,
			isExpanded: true
		)

		let result = CodeMapExtractor.buildLocalDefinitionBlockIfNeeded(
			codeMapUsage: .complete,
			selectedFiles: [],
			allFileAPIs: [
				makeAPI(filePath: "\(rootPath)/Current.swift", definedTypeName: "CurrentType"),
				makeAPI(filePath: "/Users/test/old-root/Old.swift", definedTypeName: "OldType")
			],
			filePathDisplay: .relative,
			rootFolders: [rootFolder]
		)

		XCTAssertEqual(result.fileCount, 1)
		XCTAssertTrue(result.text.contains("CurrentType"))
		XCTAssertFalse(result.text.contains("OldType"))
	}

	func testSubsetFileTreeCanSuppressCodeMapMarkersWhileKeepingSelectionMarkers() {
		let rootPath = "/Users/test/project"
		let root = FolderViewModel(
			folder: Folder(name: "project", path: rootPath, modificationDate: Date()),
			rootPath: rootPath,
			isExpanded: true
		)
		let subsetPaths: Set<String> = ["\(rootPath)/A.swift"]

		let treeFromFolders = CodeMapExtractor.generateFileTreeForSubsetFiles(
			rootFolders: [root],
			subsetFullPaths: subsetPaths,
			filePathDisplay: .relative,
			includeLegend: true,
			codeMapAvailableFullPaths: subsetPaths,
			showCodeMapMarkers: false
		)
		let treeFromRoots = CodeMapExtractor.generateFileTreeForSubsetPaths(
			roots: [CodeMapExtractor.RootInfo(standardizedRootFullPath: root.standardizedFullPath, displayName: root.name)],
			subsetFullPaths: subsetPaths,
			filePathDisplay: .relative,
			selectedMarkAll: true,
			codeMapAvailableFullPaths: subsetPaths,
			includeLegend: true,
			showCodeMapMarkers: false
		)

		for tree in [treeFromFolders, treeFromRoots] {
			XCTAssertTrue(tree.contains("A.swift *"))
			XCTAssertFalse(tree.contains("A.swift * +"))
			XCTAssertFalse(tree.contains("(+ denotes code-map available)"))
			XCTAssertTrue(tree.contains("(* denotes selected files)"))
		}
	}

	func testFileTreeCanSuppressCodeMapMarkersWhileKeepingSelectionMarkers() async throws {
		let rootPath = "/Users/test/project"
		let service = try await makeTestFileSystemService(path: FileManager.default.temporaryDirectory.path)
		let root = FolderViewModel(
			folder: Folder(name: "project", path: rootPath, modificationDate: Date()),
			rootPath: rootPath,
			isExpanded: true
		)
		let file = FileViewModel(
			file: File(name: "A.swift", path: "\(rootPath)/A.swift", modificationDate: Date()),
			rootPath: rootPath,
			hierarchyLevel: 0,
			rootIdentifier: UUID(),
			rootFolderPath: rootPath,
			fileSystemService: service
		)
		file.setCodeMap(makeAPI(filePath: file.standardizedFullPath, definedTypeName: "A"))
		root.addFile(file)

		let live = CodeMapExtractor.generateFileTreeForRoots(
			rootFolders: snapshotRoots([root]),
			option: .files,
			filePathDisplay: .relative,
			selectedFileIDs: [file.standardizedFullPath],
			onlyIncludeRootsWithSelectedFiles: false,
			includeLegend: true,
			showCodeMapMarkers: false
		)
		let rendered = treeFromIndexes(FileTreeSelectionContext(
			rootFolders: [root],
			selectedFilePaths: [file.standardizedFullPath],
			option: .files,
			filePathDisplay: .relative,
			onlyIncludeRootsWithSelectedFiles: false,
			includeLegend: true,
			showCodeMapMarkers: false
		))

		XCTAssertEqual(rendered, live)
		XCTAssertTrue(live.contains("A.swift *"))
		XCTAssertFalse(live.contains("A.swift * +"))
		XCTAssertFalse(live.contains("(+ denotes code-map available)"))
		XCTAssertTrue(live.contains("(* denotes selected files)"))
	}

	func testFileTreeRelativeMultiRootUsesRenderedRootIdentityWhenRootPathIsStale() {
		let repoPromptRoot = FolderViewModel(
			folder: Folder(name: "RepoPrompt", path: "/Users/example/Documents/XCode/RepoPrompt", modificationDate: Date()),
			rootPath: "/Users/example/Documents/XCode/RepoPrompt",
			isExpanded: true
		)
		let codexRoot = FolderViewModel(
			folder: Folder(name: "codex", path: "/Users/example/Documents/Git/codex", modificationDate: Date()),
			rootPath: "/Users/example/Documents/XCode",
			isExpanded: true
		)
		let codexRs = FolderViewModel(
			folder: Folder(name: "codex-rs", path: "/Users/example/Documents/Git/codex/codex-rs", modificationDate: Date()),
			rootPath: "/Users/example/Documents/XCode",
			isExpanded: true
		)
		codexRoot.addSubfolder(codexRs)

		let live = CodeMapExtractor.generateFileTreeForRoots(
			rootFolders: snapshotRoots([repoPromptRoot, codexRoot], showEmptyFolders: true),
			option: .files,
			filePathDisplay: .relative,
			selectedFileIDs: [],
			onlyIncludeRootsWithSelectedFiles: false,
			includeLegend: false
		)
		let rendered = treeFromIndexes(FileTreeSelectionContext(
			rootFolders: [repoPromptRoot, codexRoot],
			selectedFilePaths: [],
			option: .files,
			filePathDisplay: .relative,
			onlyIncludeRootsWithSelectedFiles: false,
			includeLegend: false
		), showEmptyFolders: true)

		XCTAssertEqual(rendered, live)
		XCTAssertTrue(live.contains("\ncodex\n└── codex-rs"), live)
		XCTAssertFalse(live.contains("XCode/codex"), live)
	}

	func testFileTreeSnapshotRendererUsesAcceptedCodeMapEligibilityForMarkers() async throws {
		let rootPath = "/Users/test/project"
		let service = try await makeTestFileSystemService(path: FileManager.default.temporaryDirectory.path)
		let root = FolderViewModel(
			folder: Folder(name: "project", path: rootPath, modificationDate: Date()),
			rootPath: rootPath,
			isExpanded: true
		)
		let file = FileViewModel(
			file: File(name: "A.swift", path: "\(rootPath)/A.swift", modificationDate: Date()),
			rootPath: rootPath,
			hierarchyLevel: 0,
			rootIdentifier: UUID(),
			rootFolderPath: rootPath,
			fileSystemService: service
		)
		file.setCodeMap(makeAPI(filePath: "\(rootPath)-old/A.swift", definedTypeName: "A"))
		root.addFile(file)

		let live = CodeMapExtractor.generateFileTreeForRoots(
			rootFolders: snapshotRoots([root]),
			option: .files,
			filePathDisplay: .relative,
			selectedFileIDs: [],
			onlyIncludeRootsWithSelectedFiles: false,
			includeLegend: false
		)
		let rendered = treeFromIndexes(FileTreeSelectionContext(
			rootFolders: [root],
			selectedFilePaths: [],
			option: .files,
			filePathDisplay: .relative,
			onlyIncludeRootsWithSelectedFiles: false,
			includeLegend: false
		))

		XCTAssertEqual(rendered, live)
		XCTAssertFalse(live.contains("A.swift +"), live)
	}

	func testFileTreeStartingAtPathUsesContainingRootAliasWhenRootPathIsStale() {
		let repoPromptRoot = FolderViewModel(
			folder: Folder(name: "RepoPrompt", path: "/Users/example/Documents/XCode/RepoPrompt", modificationDate: Date()),
			rootPath: "/Users/example/Documents/XCode/RepoPrompt",
			isExpanded: true
		)
		let codexRoot = FolderViewModel(
			folder: Folder(name: "codex", path: "/Users/example/Documents/Git/codex", modificationDate: Date()),
			rootPath: "/Users/example/Documents/Git/codex",
			isExpanded: true
		)
		let codexRs = FolderViewModel(
			folder: Folder(name: "codex-rs", path: "/Users/example/Documents/Git/codex/codex-rs", modificationDate: Date()),
			rootPath: "/Users/example/Documents/XCode",
			isExpanded: true
		)
		codexRoot.addSubfolder(codexRs)

		let tree = CodeMapExtractor.generateFileTreeStartingAtPath(
			startFolderFullPath: codexRs.fullPath,
			rootFolders: snapshotRoots([repoPromptRoot, codexRoot], showEmptyFolders: true),
			mode: "full",
			maxDepth: nil,
			includeHidden: true,
			filePathDisplay: .relative,
			selectedFileIDs: [],
			includeLegend: false,
			isMCPContext: false
		)

		XCTAssertEqual(tree.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init), "codex/codex-rs")
		XCTAssertFalse(tree.contains("XCode/codex-rs"), tree)
	}

	func testFileTreeStartingAtPathPrefersMostSpecificContainingRoot() {
		let parentRoot = FolderViewModel(
			folder: Folder(name: "Git", path: "/Users/example/Documents/Git", modificationDate: Date()),
			rootPath: "/Users/example/Documents/Git",
			isExpanded: true
		)
		let codexUnderParent = FolderViewModel(
			folder: Folder(name: "codex", path: "/Users/example/Documents/Git/codex", modificationDate: Date()),
			rootPath: "/Users/example/Documents/Git",
			isExpanded: true
		)
		let codexRoot = FolderViewModel(
			folder: Folder(name: "codex", path: "/Users/example/Documents/Git/codex", modificationDate: Date()),
			rootPath: "/Users/example/Documents/Git/codex",
			isExpanded: true
		)
		parentRoot.addSubfolder(codexUnderParent)

		let tree = CodeMapExtractor.generateFileTreeStartingAtPath(
			startFolderFullPath: codexRoot.fullPath,
			rootFolders: snapshotRoots([parentRoot, codexRoot], showEmptyFolders: true),
			mode: "full",
			maxDepth: nil,
			includeHidden: true,
			filePathDisplay: .relative,
			selectedFileIDs: [],
			includeLegend: false,
			isMCPContext: false
		)

		XCTAssertEqual(tree.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init), "codex")
		XCTAssertFalse(tree.contains("Git/codex"), tree)
	}

	func testFileTreeSnapshotRendererMatchesLiveRendererForAutoMode() async throws {
		let rootPath = "/Users/test/project"
		let service = try await makeTestFileSystemService(path: FileManager.default.temporaryDirectory.path)
		let root = FolderViewModel(
			folder: Folder(name: "project", path: rootPath, modificationDate: Date()),
			rootPath: rootPath,
			isExpanded: true
		)
		let sources = FolderViewModel(
			folder: Folder(name: "Sources", path: "\(rootPath)/Sources", modificationDate: Date()),
			rootPath: rootPath,
			isExpanded: true
		)
		let gitData = FolderViewModel(
			folder: Folder(name: "_git_data", path: "\(rootPath)/_git_data", modificationDate: Date()),
			rootPath: rootPath,
			isExpanded: true
		)
		let fileA = FileViewModel(
			file: File(name: "A.swift", path: "\(rootPath)/Sources/A.swift", modificationDate: Date()),
			rootPath: rootPath,
			hierarchyLevel: 0,
			rootIdentifier: UUID(),
			rootFolderPath: rootPath,
			fileSystemService: service
		)
		let fileB = FileViewModel(
			file: File(name: "B.tmp", path: "\(rootPath)/Sources/B.tmp", modificationDate: Date()),
			rootPath: rootPath,
			hierarchyLevel: 0,
			rootIdentifier: UUID(),
			rootFolderPath: rootPath,
			fileSystemService: service
		)
		let gitArtifact = FileViewModel(
			file: File(name: "artifact.patch", path: "\(rootPath)/_git_data/artifact.patch", modificationDate: Date()),
			rootPath: rootPath,
			hierarchyLevel: 0,
			rootIdentifier: UUID(),
			rootFolderPath: rootPath,
			fileSystemService: service
		)
		fileA.setCodeMap(makeAPI(filePath: fileA.standardizedFullPath, definedTypeName: "A"))
		root.addSubfolder(sources)
		root.addSubfolder(gitData)
		sources.addFile(fileA)
		sources.addFile(fileB)
		gitData.addFile(gitArtifact)

		let live = CodeMapExtractor.generateFileTreeForRoots(
			rootFolders: snapshotRoots([root]),
			option: .auto,
			filePathDisplay: .relative,
			selectedFileIDs: [fileA.standardizedFullPath],
			onlyIncludeRootsWithSelectedFiles: false,
			includeLegend: true
		)
		let rendered = treeFromIndexes(FileTreeSelectionContext(
			rootFolders: [root],
			selectedFilePaths: [fileA.standardizedFullPath],
			option: .auto,
			filePathDisplay: .relative,
			onlyIncludeRootsWithSelectedFiles: false,
			includeLegend: true
		))

		XCTAssertEqual(rendered, live)
	}

	func testPromptFileTreeListsTheFilesOfFoldersThatAreNotOpened() async throws {
		let (fileManagerVM, parentURL, _) = try await makeUnopenedProjectRoot()
		defer { try? FileManager.default.removeItem(at: parentURL) }
		let expected = """
		project
		├── src
		│   ├── sub
		│   │   └── B.swift
		│   └── A.swift
		└── README.md

		"""

		XCTAssertEqual(promptFileTree(fileManagerVM, option: .files, selected: []), expected)
		XCTAssertEqual(promptFileTree(fileManagerVM, option: .auto, selected: []), expected)
	}

	func testPromptFileTreeMarksASelectedFileWithACodemapInAFolderThatIsNotOpened() async throws {
		let (fileManagerVM, parentURL, rootPath) = try await makeUnopenedProjectRoot()
		defer { try? FileManager.default.removeItem(at: parentURL) }
		let bPath = StandardizedPath.join(standardizedRoot: rootPath, standardizedRelativePath: "src/sub/B.swift")
		let request = CodeScanActor.ScanRequest(
			fileID: RepoFileManagerViewModel.fileID(forStandardizedPath: bPath),
			modificationDate: Date(),
			content: "",
			fileExtension: "swift",
			relativePath: "src/sub/B.swift",
			fullPath: bPath,
			rootFolderPath: rootPath
		)
		fileManagerVM.applyBatchCodeMapResultsForTesting([
			CodeScanActor.ScanResult(request: request, fileAPI: makeAPI(filePath: bPath, definedTypeName: "B"))
		])

		XCTAssertEqual(promptFileTree(fileManagerVM, option: .selected, selected: [bPath]), """
		project
		└── src
		    └── sub
		        └── B.swift * +

		""")
		XCTAssertEqual(promptFileTree(fileManagerVM, option: .auto, selected: [bPath]), """
		project
		├── src
		│   ├── sub
		│   │   └── B.swift * +
		│   └── A.swift
		└── README.md

		""")
	}

	/// A loaded root folder `project` holding `README.md`, `src/A.swift` and `src/sub/B.swift`, with no folder opened.
	/// Returns the file manager, the temporary folder to remove and the root's standardized path.
	private func makeUnopenedProjectRoot() async throws -> (RepoFileManagerViewModel, URL, String) {
		let parentURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let rootURL = parentURL.appendingPathComponent("project", isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL.appendingPathComponent("src/sub", isDirectory: true), withIntermediateDirectories: true)
		for path in ["README.md", "src/A.swift", "src/sub/B.swift"] {
			try "content".write(to: rootURL.appendingPathComponent(path), atomically: true, encoding: .utf8)
		}
		let fileManagerVM = RepoFileManagerViewModel()
		fileManagerVM.beginDeferringInitialRootLoadScans()
		try await fileManagerVM.loadFolder(at: rootURL, for: WorkspaceModel(name: "Test", repoPaths: [rootURL.path]), freshStart: true)
		await fileManagerVM.waitUntilReadingIsComplete()
		let rootPath = try XCTUnwrap(fileManagerVM.visibleRootFolders.first?.standardizedFullPath)
		return (fileManagerVM, parentURL, rootPath)
	}

	/// The prompt's file tree of every root folder of a file manager, without legend.
	private func promptFileTree(_ fileManagerVM: RepoFileManagerViewModel, option: FileTreeOption, selected: Set<String>) -> String {
		CodeMapExtractor.generateFileTree(using: fileManagerVM.fileTreeSnapshot(using: FileTreeSelectionContext(
			rootFolders: fileManagerVM.visibleRootFolders,
			selectedFilePaths: selected,
			option: option,
			filePathDisplay: .relative,
			onlyIncludeRootsWithSelectedFiles: !selected.isEmpty,
			includeLegend: false
		)))
	}

	/// The tree of a context, rendered from indexes that hold exactly the folders and files of its root view models.
	private func treeFromIndexes(_ context: FileTreeSelectionContext, showEmptyFolders: Bool = false) -> String {
		CodeMapExtractor.generateFileTree(using: snapshotFromIndexes(context, showEmptyFolders: showEmptyFolders))
	}

	/// The snapshot folders of root view models, built from indexes that hold exactly their folders and files.
	private func snapshotRoots(_ roots: [FolderViewModel], showEmptyFolders: Bool = false) -> [FileTreeFolderSnapshot] {
		snapshotFromIndexes(FileTreeSelectionContext(
			rootFolders: roots,
			selectedFilePaths: [],
			option: .files,
			filePathDisplay: .relative,
			onlyIncludeRootsWithSelectedFiles: false,
			includeLegend: false
		), showEmptyFolders: showEmptyFolders).roots
	}

	/// The snapshot of a context, built from indexes that hold exactly the folders and files of its root view models.
	private func snapshotFromIndexes(_ context: FileTreeSelectionContext, showEmptyFolders: Bool) -> FileTreeSelectionSnapshot {
		var indexes: [String: RootFolderIndex] = [:]
		var filesByPath: [String: FileViewModel] = [:]
		for root in context.rootFolders {
			let rootPath = root.standardizedFullPath
			let index = RootFolderIndex(rootPath: rootPath)
			var pending = [root]
			while let folder = pending.popLast() {
				for subfolder in folder.subfolders {
					index.addFolder(RelativePath.from(absolutePath: subfolder.standardizedFullPath, rootPath: rootPath), isRead: true)
					pending.append(subfolder)
				}
				for file in folder.files {
					index.addFile(RelativePath.from(absolutePath: file.standardizedFullPath, rootPath: rootPath))
					filesByPath[file.standardizedFullPath] = file
				}
			}
			index.finishReading()
			indexes[rootPath] = index
		}
		return CodeMapExtractor.makeFileTreeSnapshot(
			using: context,
			indexes: indexes,
			showEmptyFolders: showEmptyFolders,
			codemapPaths: [:],
			treeItemCodeMaps: filesByPath.mapValues { $0.hasAcceptedCodeMap }
		)
	}
}
