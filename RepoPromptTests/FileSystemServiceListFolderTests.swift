import XCTest
@testable import RepoPrompt

final class FileSystemServiceListFolderTests: XCTestCase {
	private var rootURL: URL!

	override func setUpWithError() throws {
		rootURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("FileSystemServiceListFolder-\(UUID().uuidString)", isDirectory: true)
		let fileManager = FileManager.default
		try fileManager.createDirectory(at: rootURL.appendingPathComponent("src/a"), withIntermediateDirectories: true)
		try fileManager.createDirectory(at: rootURL.appendingPathComponent("build"), withIntermediateDirectories: true)
		try "build/\n".write(to: rootURL.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
		try "secret.txt\n".write(to: rootURL.appendingPathComponent("src/.gitignore"), atomically: true, encoding: .utf8)
		for relativePath in ["src/x.swift", "src/.repoprompt.tmp.1", "src/a/open.txt", "src/a/secret.txt", "build/out.o"] {
			XCTAssertTrue(fileManager.createFile(atPath: rootURL.appendingPathComponent(relativePath).path, contents: Data()))
		}
	}

	override func tearDownWithError() throws {
		try? FileManager.default.removeItem(at: rootURL)
	}

	private func makeService() async throws -> FileSystemService {
		try await FileSystemService(
			path: rootURL.path,
			respectGitignore: true,
			respectRepoIgnore: false,
			respectCursorignore: false,
			skipSymlinks: true,
			isTestMode: true
		)
	}

	func testListFolderListsDirectEntriesTheIgnoreRulesAllow() async throws {
		let service = try await makeService()

		let chunk = try await service.listFolder(atRelativePath: "src")

		XCTAssertEqual(chunk.folders.map(\.relativePath), ["src/a"])
		XCTAssertEqual(chunk.files.map(\.relativePath).sorted(), ["src/.gitignore", "src/x.swift"])
		XCTAssertTrue(chunk.readFolders.contains("src"))
	}

	func testListFolderOfRootOmitsIgnoredFolders() async throws {
		let service = try await makeService()

		let chunk = try await service.listFolder(atRelativePath: "")

		XCTAssertEqual(chunk.folders.map(\.relativePath), ["src"])
		XCTAssertEqual(chunk.files.map(\.relativePath), [".gitignore"])
		XCTAssertTrue(chunk.readFolders.contains(""))
	}

	func testListFolderAppliesIgnoreFilesOfParentFolders() async throws {
		let service = try await makeService()

		let chunk = try await service.listFolder(atRelativePath: "src/a")

		XCTAssertEqual(chunk.folders.map(\.relativePath), [])
		XCTAssertEqual(chunk.files.map(\.relativePath), ["src/a/open.txt"])
		XCTAssertTrue(chunk.readFolders.contains("src/a"))
	}
}
