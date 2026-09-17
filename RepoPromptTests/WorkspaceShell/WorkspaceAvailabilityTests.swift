import XCTest
@testable import RepoPrompt

final class WorkspaceAvailabilityTests: XCTestCase {
	func testMissingRootMakesWorkspaceUnavailable() throws {
		let existing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: existing) }
		let missing = existing.appendingPathComponent("gone").path

		XCTAssertTrue(WorkspaceAvailability.isAvailable(repoPaths: [existing.path]))
		XCTAssertTrue(WorkspaceAvailability.isAvailable(repoPaths: []))
		XCTAssertFalse(WorkspaceAvailability.isAvailable(repoPaths: [existing.path, missing]))
	}

	func testFileRootIsNotAvailable() throws {
		let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
		try Data().write(to: file)
		defer { try? FileManager.default.removeItem(at: file) }

		XCTAssertFalse(WorkspaceAvailability.isAvailable(repoPaths: [file.path]))
	}
}
