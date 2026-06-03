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

		let context = FileTreeSelectionContext(
			rootFolders: [root],
			selectedFileIDs: [file.id],
			option: .files,
			filePathDisplay: .relative,
			onlyIncludeRootsWithSelectedFiles: false,
			includeLegend: true,
			isMCPContext: false,
			showCodeMapMarkers: false
		)
		let live = CodeMapExtractor.generateFileTree(using: context)
		let snapshot = CodeMapExtractor.makeFileTreeSnapshot(using: context)
		let rendered = CodeMapExtractor.generateFileTree(using: snapshot)

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

		let context = FileTreeSelectionContext(
			rootFolders: [repoPromptRoot, codexRoot],
			selectedFileIDs: [],
			option: .files,
			filePathDisplay: .relative,
			onlyIncludeRootsWithSelectedFiles: false,
			includeLegend: false,
			isMCPContext: false
		)
		let live = CodeMapExtractor.generateFileTree(using: context)
		let snapshot = CodeMapExtractor.makeFileTreeSnapshot(using: context)
		let rendered = CodeMapExtractor.generateFileTree(using: snapshot)

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

		let context = FileTreeSelectionContext(
			rootFolders: [root],
			selectedFileIDs: [],
			option: .files,
			filePathDisplay: .relative,
			onlyIncludeRootsWithSelectedFiles: false,
			includeLegend: false,
			isMCPContext: false
		)
		let live = CodeMapExtractor.generateFileTree(using: context)
		let snapshot = CodeMapExtractor.makeFileTreeSnapshot(using: context)
		let rendered = CodeMapExtractor.generateFileTree(using: snapshot)

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
			rootFolders: [repoPromptRoot, codexRoot],
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
			rootFolders: [parentRoot, codexRoot],
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

		let context = FileTreeSelectionContext(
			rootFolders: [root],
			selectedFileIDs: [fileA.id],
			option: .auto,
			filePathDisplay: .relative,
			onlyIncludeRootsWithSelectedFiles: false,
			includeLegend: true,
			isMCPContext: false
		)

		let live = CodeMapExtractor.generateFileTree(using: context)
		let snapshot = CodeMapExtractor.makeFileTreeSnapshot(using: context)
		let rendered = CodeMapExtractor.generateFileTree(using: snapshot)

		XCTAssertEqual(rendered, live)
	}
}
