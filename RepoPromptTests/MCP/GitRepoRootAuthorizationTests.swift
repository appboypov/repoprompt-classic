import XCTest
@testable import RepoPrompt

@MainActor
final class GitRepoRootAuthorizationTests: XCTestCase {
	func testPathWithinGitToolRootsAcceptsExactRoot() {
		let allowed = ["/tmp/Workspace/Repo"]
		XCTAssertTrue(
			GitRepoRootAuthorization.isPathWithinAuthorizedRoots(
				"/tmp/Workspace/Repo",
				roots: allowed
			)
		)
	}

	func testPathWithinGitToolRootsAcceptsNestedPath() {
		let allowed = ["/tmp/Workspace/Repo"]
		XCTAssertTrue(
			GitRepoRootAuthorization.isPathWithinAuthorizedRoots(
				"/tmp/Workspace/Repo/Sources/Feature.swift",
				roots: allowed
			)
		)
	}

	func testPathWithinGitToolRootsRejectsPrefixTrapSibling() {
		let allowed = ["/tmp/Workspace/Repo"]
		XCTAssertFalse(
			GitRepoRootAuthorization.isPathWithinAuthorizedRoots(
				"/tmp/Workspace/Repo2",
				roots: allowed
			)
		)
	}

	func testPathWithinGitToolRootsRejectsOutsidePath() {
		let allowed = ["/tmp/Workspace/Repo"]
		XCTAssertFalse(
			GitRepoRootAuthorization.isPathWithinAuthorizedRoots(
				"/tmp/Other/SecretRepo",
				roots: allowed
			)
		)
	}

	func testPathWithinGitToolRootsExpandsTilde() {
		let home = NSHomeDirectory()
		XCTAssertTrue(
			GitRepoRootAuthorization.isPathWithinAuthorizedRoots(
				"~/Documents",
				roots: [home]
			)
		)
	}

	func testPathWithinGitToolRootsRejectsRelativePath() {
		XCTAssertFalse(
			GitRepoRootAuthorization.isPathWithinAuthorizedRoots(
				".",
				roots: ["/tmp/Workspace/Repo"]
			)
		)
	}
}
