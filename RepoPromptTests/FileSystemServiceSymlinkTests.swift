import XCTest
@testable import RepoPrompt

final class FileSystemServiceSymlinkTests: XCTestCase {
	private func makeTempRepo() throws -> URL {
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("repoprompt-fs-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		return root
	}
	
	private func createFile(at url: URL, contents: String = "test") {
		FileManager.default.createFile(atPath: url.path, contents: Data(contents.utf8))
	}
	
	private func allDeltaPaths(_ deltas: [FileSystemDelta]) -> [String] {
		return deltas.compactMap { delta in
			switch delta {
			case .fileAdded(let path):
				return path
			case .fileRemoved(let path):
				return path
			case .folderAdded(let path):
				return path
			case .folderRemoved(let path):
				return path
			case .fileModified(let path, _):
				return path
			case .folderModified(let path, _):
				return path
			}
		}
	}
	
	func testSymlinkToAncestorDoesNotRecurseForever() async throws {
		let root = try makeTempRepo()
		defer { try? FileManager.default.removeItem(at: root) }
		
		let a = root.appendingPathComponent("a")
		try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
		let loop = a.appendingPathComponent("loop")
		try FileManager.default.createSymbolicLink(atPath: loop.path, withDestinationPath: root.path)
		
		let service = try await FileSystemService(
			path: root.path,
			respectGitignore: false,
			skipSymlinks: false
		)
		
		let deltas = try await service.scanOneLevelAndDiff(relativeFolderPath: "")
		let paths = allDeltaPaths(deltas)
		
		XCTAssertTrue(paths.contains("a"))
		XCTAssertTrue(paths.contains("a/loop"))
		XCTAssertFalse(paths.contains { $0.hasPrefix("a/loop/") })
	}
	
	func testSymlinkToSiblingIsTraversedWhenAllowed() async throws {
		let root = try makeTempRepo()
		defer { try? FileManager.default.removeItem(at: root) }
		
		let src = root.appendingPathComponent("src")
		try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
		createFile(at: src.appendingPathComponent("file.txt"))
		
		let link = root.appendingPathComponent("link")
		try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: src.path)
		
		let service = try await FileSystemService(
			path: root.path,
			respectGitignore: false,
			skipSymlinks: false
		)
		
		let deltas = try await service.scanOneLevelAndDiff(relativeFolderPath: "")
		let paths = allDeltaPaths(deltas)
		
		XCTAssertTrue(paths.contains("link"))
		XCTAssertTrue(paths.contains("link/file.txt"))
	}
	
	func testSymlinkOutsideRootTraversesWhenAllowed() async throws {
		let root = try makeTempRepo()
		defer { try? FileManager.default.removeItem(at: root) }
		
		let external = FileManager.default.temporaryDirectory
			.appendingPathComponent("repoprompt-ext-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: external) }
		
		createFile(at: external.appendingPathComponent("outside.txt"))
		let link = root.appendingPathComponent("ext")
		try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: external.path)
		
		let service = try await FileSystemService(
			path: root.path,
			respectGitignore: false,
			skipSymlinks: false
		)
		
		let deltas = try await service.scanOneLevelAndDiff(relativeFolderPath: "")
		let paths = allDeltaPaths(deltas)
		
		XCTAssertTrue(paths.contains("ext"))
		XCTAssertTrue(paths.contains("ext/outside.txt"))
	}
}
