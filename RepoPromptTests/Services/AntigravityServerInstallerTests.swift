import XCTest
@testable import RepoPrompt

final class AntigravityServerInstallerTests: XCTestCase {
	func testArchivePicksTheReleaseOfEachArchitecture() {
		let arm = AntigravityServerInstaller.archive(for: .arm64)
		let intel = AntigravityServerInstaller.archive(for: .x86_64)

		XCTAssertTrue(arm.url.lastPathComponent.hasSuffix("-darwin-arm64.zip"))
		XCTAssertTrue(intel.url.lastPathComponent.hasSuffix("-darwin-x86_64.zip"))
		XCTAssertTrue(arm.url.lastPathComponent.contains(AntigravityServerInstaller.version))
		XCTAssertNotEqual(arm.sha256, intel.sha256)
	}

	func testVerifyChecksumAcceptsMatchingHashInAnyCase() throws {
		let fileURL = try makeFile(contents: "hello")

		XCTAssertNoThrow(try AntigravityServerInstaller.verifyChecksum(
			of: fileURL,
			expectedSHA256: "2CF24DBA5FB0A30E26E83B2AC5B9E29E1B161E5C1FA7425E73043362938B9824"
		))
	}

	func testVerifyChecksumRejectsMismatchedDownload() throws {
		let fileURL = try makeFile(contents: "tampered")
		let expected = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"

		XCTAssertThrowsError(try AntigravityServerInstaller.verifyChecksum(of: fileURL, expectedSHA256: expected)) { error in
			guard case AntigravityServerInstaller.InstallError.checksumMismatch(let reportedExpected, let actual) = error else {
				return XCTFail("Expected checksumMismatch, got \(error)")
			}
			XCTAssertEqual(reportedExpected, expected)
			XCTAssertNotEqual(actual, expected)
		}
	}

	private func makeFile(contents: String) throws -> URL {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("AntigravityServerInstallerTests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
		let fileURL = directory.appendingPathComponent("archive.zip")
		try Data(contents.utf8).write(to: fileURL)
		return fileURL
	}
}
