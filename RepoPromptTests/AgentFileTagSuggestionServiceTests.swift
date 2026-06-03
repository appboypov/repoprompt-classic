import XCTest
@testable import RepoPrompt

@MainActor
final class AgentFileTagSuggestionServiceTests: XCTestCase {

	// MARK: - Empty query is the cheap/lazy path

	/// Bare `@` must not build the full candidate cache or allocate a
	/// `PathSearchIndex` — that O(N) work is unnecessary for empty queries
	/// and can be very expensive in large multi-root workspaces.
	/// See docs/investigations/agent-mode-file-mention-large-repo-crash-2026-04-21.md.
	func testEmptyQueryDoesNotBuildFullCandidateIndex() async {
		let manager = RepoFileManagerViewModel()
		let service = AgentFileTagSuggestionService(fileManager: manager, maxResults: 5)

		let results = await service.suggestions(for: "")

		XCTAssertTrue(results.isEmpty)
		XCTAssertEqual(service.cachedCandidateCountForTesting, 0, "Empty query must not populate cachedCandidates")
		XCTAssertFalse(service.pathSearchIndexIsBuiltForTesting, "Empty query must not construct the PathSearchIndex")
	}

	// MARK: - Duplicate token paths must not crash

	/// Seeds the candidate cache with duplicate `tokenRelativePath` values
	/// (same-basename roots producing identical `uniqueRelativePath`).
	/// Previously built `Dictionary(uniqueKeysWithValues:)` and SIGTRAPd
	/// with `_MergeError`; the fix must dedupe duplicate keys safely.
	func testEmptyQueryWithDuplicateTokenPathsDoesNotCrash() async {
		let manager = RepoFileManagerViewModel()
		let service = AgentFileTagSuggestionService(fileManager: manager, maxResults: 5)
		service.seedCandidateCacheForTesting(
			tokenPaths: [
				"mono/README.md",
				"mono/README.md",
				"mono/Sources/App.swift",
				"mono/Sources/App.swift",
			],
			hasMultipleRoots: true
		)

		let results = await service.suggestions(for: "")

		// No crash, no exception. With no selected files we fall back to the
		// cached candidate head (bounded by maxResults).
		XCTAssertFalse(results.isEmpty)
		XCTAssertLessThanOrEqual(results.count, 5)
	}

	// MARK: - Selected suggestions for multi-root duplicates

	/// Two roots with the same last-path component ("mono") and the same
	/// relative file produce identical `uniqueRelativePath`. The previous
	/// implementation trapped inside `Dictionary(uniqueKeysWithValues:)`.
	/// The fix must surface both files (they are distinct by stable file
	/// identity / `standardizedFullPath`) and must not SIGTRAP on the
	/// duplicate token-path keys.
	func testSelectedSuggestionsWithSameBasenameRootsDoesNotCrash() async throws {
		let fixture = try await makeDuplicateBasenameFixture()
		defer { fixture.cleanup() }

		fixture.manager.selectFileForTesting(fixture.fileA)
		fixture.manager.selectFileForTesting(fixture.fileB)

		let service = AgentFileTagSuggestionService(fileManager: fixture.manager, maxResults: 5)

		// Must not trap on duplicate `uniqueRelativePath` keys.
		let results = await service.suggestions(for: "")

		XCTAssertEqual(fixture.fileA.uniqueRelativePath, fixture.fileB.uniqueRelativePath)
		XCTAssertNotEqual(fixture.fileA.standardizedFullPath, fixture.fileB.standardizedFullPath)
		// Both files are kept because identity dedupe uses
		// standardizedFullPath, not the colliding tokenRelativePath.
		XCTAssertEqual(results.count, 2)
		XCTAssertEqual(
			Set(results.map(\.relativePath)),
			[fixture.fileA.uniqueRelativePath]
		)
	}

	// MARK: - Selected suggestions still surface files on empty query

	func testEmptyQueryReturnsSelectedFilesWithoutIndexing() async throws {
		let fixture = try await makeSingleFileFixture(name: "Alpha.swift")
		defer { fixture.cleanup() }

		fixture.manager.selectFileForTesting(fixture.file)

		let service = AgentFileTagSuggestionService(fileManager: fixture.manager, maxResults: 5)
		let results = await service.suggestions(for: "")

		XCTAssertEqual(results.count, 1)
		XCTAssertEqual(results.first?.displayName, "Alpha.swift")
		XCTAssertEqual(
			service.cachedCandidateCountForTesting, 0,
			"Empty query must NOT trigger the full candidate cache build, even when selected files exist"
		)
		XCTAssertFalse(service.pathSearchIndexIsBuiltForTesting)
	}

	// MARK: - Fixtures

	private struct SingleFileFixture {
		let manager: RepoFileManagerViewModel
		let rootURL: URL
		let file: FileViewModel
		let cleanup: () -> Void
	}

	private struct DuplicateBasenameFixture {
		let manager: RepoFileManagerViewModel
		let parent: URL
		let fileA: FileViewModel
		let fileB: FileViewModel
		let cleanup: () -> Void
	}

	private func makeTestFileSystemService(path: String) async throws -> FileSystemService {
		try await FileSystemService(
			path: path,
			respectGitignore: false,
			skipSymlinks: true,
			isTestMode: true
		)
	}

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

	private func makeSingleFileFixture(name: String) async throws -> SingleFileFixture {
		let rootURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("AgentFileTagSingle-\(UUID().uuidString)", isDirectory: true)
		let rootPath = rootURL.path
		let fullPath = rootURL.appendingPathComponent(name).path
		let service = try await makeTestFileSystemService(path: rootPath)
		let file = makeFileViewModel(fullPath: fullPath, rootPath: rootPath, service: service)
		let manager = RepoFileManagerViewModel(alwaysReadableHomeDirectoryURL: rootURL)
		manager.injectIndexedFileForTesting(file)
		return SingleFileFixture(
			manager: manager,
			rootURL: rootURL,
			file: file,
			cleanup: { try? FileManager.default.removeItem(at: rootURL) }
		)
	}

	private func makeDuplicateBasenameFixture() async throws -> DuplicateBasenameFixture {
		// Two roots whose *last path component* is identical ("mono") but
		// whose absolute paths differ, each containing the same relative
		// file. This reproduces the real crash repro: identical
		// `uniqueRelativePath` from different roots.
		let parent = FileManager.default.temporaryDirectory
			.appendingPathComponent("AgentFileTagDup-\(UUID().uuidString)", isDirectory: true)
		let rootA = parent.appendingPathComponent("client-a/mono", isDirectory: true)
		let rootB = parent.appendingPathComponent("client-b/mono", isDirectory: true)
		let relative = "README.md"
		let serviceA = try await makeTestFileSystemService(path: rootA.path)
		let serviceB = try await makeTestFileSystemService(path: rootB.path)
		let fileA = makeFileViewModel(
			fullPath: rootA.appendingPathComponent(relative).path,
			rootPath: rootA.path,
			service: serviceA
		)
		let fileB = makeFileViewModel(
			fullPath: rootB.appendingPathComponent(relative).path,
			rootPath: rootB.path,
			service: serviceB
		)
		let manager = RepoFileManagerViewModel(alwaysReadableHomeDirectoryURL: parent)
		manager.injectIndexedFileForTesting(fileA)
		manager.injectIndexedFileForTesting(fileB)
		return DuplicateBasenameFixture(
			manager: manager,
			parent: parent,
			fileA: fileA,
			fileB: fileB,
			cleanup: { try? FileManager.default.removeItem(at: parent) }
		)
	}
}
