import XCTest
@testable import RepoPrompt

final class CodeMapApplicationGuardTests: XCTestCase {
	private func makeTestFileSystemService(path: String) async throws -> FileSystemService {
		try await FileSystemService(
			path: path,
			respectGitignore: false,
			skipSymlinks: true,
			isTestMode: true
		)
	}

	@MainActor
	private func makeFileViewModel(
		fullPath: String,
		rootPath: String,
		service: FileSystemService
	) -> FileViewModel {
		FileViewModel(
			file: File(name: (fullPath as NSString).lastPathComponent, path: fullPath, modificationDate: Date()),
			rootPath: rootPath,
			hierarchyLevel: 0,
			rootIdentifier: UUID(),
			rootFolderPath: rootPath,
			fileSystemService: service
		)
	}

	private func makeAPI(path: String, typeName: String) -> FileAPI {
		FileAPI(
			filePath: path,
			imports: [],
			classes: [ClassInfo(name: typeName, methods: [], properties: [])],
			functions: [],
			enums: [],
			globalVars: [],
			macros: [],
			referencedTypes: []
		)
	}

	private func makeRequest(
		fileID: UUID,
		rootPath: String,
		relativePath: String,
		content: String = "final class CurrentType {}\n"
	) -> CodeScanActor.ScanRequest {
		CodeScanActor.ScanRequest(
			fileID: fileID,
			modificationDate: Date(),
			content: content,
			fileExtension: "swift",
			relativePath: relativePath,
			fullPath: "\(rootPath)/\(relativePath)",
			rootFolderPath: rootPath
		)
	}

	private func makeResult(_ request: CodeScanActor.ScanRequest, fileAPI: FileAPI?) -> CodeScanActor.ScanResult {
		CodeScanActor.ScanResult(request: request, fileAPI: fileAPI)
	}

	@MainActor
	func testFileViewModelRejectsPathMismatchedCodeMapAndClearsExistingState() async throws {
		let rootURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("FileViewModelCodeMapGuardTests-\(UUID().uuidString)", isDirectory: true)
		let rootPath = rootURL.path
		let filePath = rootURL.appendingPathComponent("A.swift").path
		let service = try await makeTestFileSystemService(path: rootPath)
		let fileVM = makeFileViewModel(fullPath: filePath, rootPath: rootPath, service: service)

		fileVM.setCodeMap(makeAPI(path: filePath, typeName: "CurrentType"))
		XCTAssertNotNil(fileVM.fileAPI)
		XCTAssertNotNil(fileVM.codemapLineCount)

		fileVM.setCodeMap(makeAPI(path: "\(rootPath)-old/A.swift", typeName: "OldType"))
		XCTAssertNil(fileVM.fileAPI)
		XCTAssertNil(fileVM.codemapLineCount)
	}

	@MainActor
	func testCachedFileAPIsReturnsOnlyAttachedCurrentHierarchyAPIs() async throws {
		let rootURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("RepoFileManagerCachedAPIFilterTests-\(UUID().uuidString)", isDirectory: true)
		let rootPath = rootURL.path
		let relativePath = "A.swift"
		let filePath = rootURL.appendingPathComponent(relativePath).path
		let ghostPath = rootURL.appendingPathComponent("Ghost.swift").path
		let service = try await makeTestFileSystemService(path: rootPath)
		let fileVM = makeFileViewModel(fullPath: filePath, rootPath: rootPath, service: service)
		let manager = RepoFileManagerViewModel(alwaysReadableHomeDirectoryURL: rootURL)
		manager.injectIndexedFileForTesting(fileVM)

		let currentAPI = makeAPI(path: filePath, typeName: "CurrentType")
		let currentRequest = makeRequest(fileID: fileVM.id, rootPath: rootPath, relativePath: relativePath)
		manager.applyBatchCodeMapResultsForTesting([makeResult(currentRequest, fileAPI: currentAPI)])

		manager.seedCachedCodeMapAPIForTesting(
			fullPath: ghostPath,
			api: makeAPI(path: ghostPath, typeName: "GhostType")
		)

		let cachedAPIs = manager.cachedFileAPIs()
		XCTAssertEqual(cachedAPIs.count, 1)
		XCTAssertEqual(cachedAPIs.first?.definedTypeNames ?? [], Set(["CurrentType"]))

		let staleSamePathAPI = makeAPI(path: filePath, typeName: "StaleSamePathType")
		let validatedAPIs = manager.validatedCurrentFileAPIs(from: [staleSamePathAPI])
		XCTAssertEqual(validatedAPIs.count, 1)
		XCTAssertEqual(validatedAPIs.first?.definedTypeNames ?? [], Set(["CurrentType"]))
	}

	@MainActor
	func testApplyBatchCodeMapResultsClearsExistingCodeMapForCurrentFilePathMismatch() async throws {
		let rootURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("RepoFileManagerCodeMapInvalidCurrentTests-\(UUID().uuidString)", isDirectory: true)
		let rootPath = rootURL.path
		let relativePath = "A.swift"
		let filePath = rootURL.appendingPathComponent(relativePath).path
		let service = try await makeTestFileSystemService(path: rootPath)
		let fileVM = makeFileViewModel(fullPath: filePath, rootPath: rootPath, service: service)
		let manager = RepoFileManagerViewModel(alwaysReadableHomeDirectoryURL: rootURL)
		manager.injectIndexedFileForTesting(fileVM)

		let currentRequest = makeRequest(fileID: fileVM.id, rootPath: rootPath, relativePath: relativePath)
		manager.applyBatchCodeMapResultsForTesting([
			makeResult(currentRequest, fileAPI: makeAPI(path: filePath, typeName: "CurrentType"))
		])
		XCTAssertNotNil(fileVM.fileAPI)
		XCTAssertNotNil(manager.cachedCodeMapAPIForTesting(fullPath: filePath))

		manager.applyBatchCodeMapResultsForTesting([
			makeResult(currentRequest, fileAPI: makeAPI(path: "\(rootPath)-old/\(relativePath)", typeName: "OldType"))
		])

		XCTAssertNil(fileVM.fileAPI)
		XCTAssertNil(manager.cachedCodeMapAPIForTesting(fullPath: filePath))
	}

	@MainActor
	func testApplyBatchCodeMapResultsRejectsMismatchedFileIDAndUsesLatestValidDedupeEntry() async throws {
		let rootURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("RepoFileManagerCodeMapGuardTests-\(UUID().uuidString)", isDirectory: true)
		let rootPath = rootURL.path
		let relativePath = "A.swift"
		let filePath = rootURL.appendingPathComponent(relativePath).path
		let service = try await makeTestFileSystemService(path: rootPath)
		let fileVM = makeFileViewModel(fullPath: filePath, rootPath: rootPath, service: service)
		let manager = RepoFileManagerViewModel(alwaysReadableHomeDirectoryURL: rootURL)
		manager.injectIndexedFileForTesting(fileVM)

		let validAPI = makeAPI(path: filePath, typeName: "CurrentType")
		let currentRequest = makeRequest(fileID: fileVM.id, rootPath: rootPath, relativePath: relativePath)
		let staleRequest = makeRequest(fileID: UUID(), rootPath: rootPath, relativePath: relativePath)

		manager.applyBatchCodeMapResultsForTesting([makeResult(staleRequest, fileAPI: validAPI)])
		XCTAssertNil(fileVM.fileAPI)
		XCTAssertNil(manager.cachedCodeMapAPIForTesting(fullPath: filePath))

		manager.applyBatchCodeMapResultsForTesting([
			makeResult(currentRequest, fileAPI: validAPI),
			makeResult(staleRequest, fileAPI: validAPI)
		])

		XCTAssertNotNil(fileVM.fileAPI)
		XCTAssertNotNil(manager.cachedCodeMapAPIForTesting(fullPath: filePath))
	}
}
