import XCTest
@testable import RepoPrompt

final class GitDiffCompareSpecTests: XCTestCase {
	func testParseMergeBaseAliases() {
		XCTAssertEqual(
			GitDiffCompareSpec.parse("mergebase:origin/main"),
			.uncommittedMergeBase(base: "origin/main")
		)
		XCTAssertEqual(
			GitDiffCompareSpec.parse("uncommitted-mergebase:origin/main"),
			.uncommittedMergeBase(base: "origin/main")
		)
		XCTAssertEqual(
			GitDiffCompareSpec.parse("staged-mergebase:origin/main"),
			.stagedMergeBase(base: "origin/main")
		)
	}

	func testMergeBaseDisplayStringsAndKeys() {
		XCTAssertEqual(
			GitDiffCompareSpec.uncommittedMergeBase(base: "origin/main").displayString,
			"mergebase:origin/main"
		)
		XCTAssertEqual(
			GitDiffCompareSpec.uncommittedMergeBase(base: "origin/main").rawKey,
			"uncommitted-mergebase:origin/main"
		)
		XCTAssertEqual(
			GitDiffCompareSpec.stagedMergeBase(base: "origin/main").displayString,
			"staged-mergebase:origin/main"
		)
		XCTAssertEqual(
			GitDiffCompareSpec.stagedMergeBase(base: "origin/main").rawKey,
			"staged-mergebase:origin/main"
		)
	}

	func testCompareSpecCodableRoundTripsMergeBaseCases() throws {
		let values: [GitDiffCompareSpec] = [
			.uncommittedMergeBase(base: "origin/main"),
			.stagedMergeBase(base: "origin/main")
		]

		for value in values {
			let data = try JSONEncoder().encode(value)
			let decoded = try JSONDecoder().decode(GitDiffCompareSpec.self, from: data)
			XCTAssertEqual(decoded, value)
		}
	}

	func testGitDiffTargetCodableRoundTripsMergeBaseCase() throws {
		let value = GitDiffTarget.uncommittedMergeBase(base: "origin/main")
		let data = try JSONEncoder().encode(value)
		let decoded = try JSONDecoder().decode(GitDiffTarget.self, from: data)

		XCTAssertEqual(decoded, value)
		XCTAssertEqual(value.kind, .uncommittedMergeBase)
		XCTAssertEqual(value.keyString, "uncommitted-mergebase:origin/main")
	}
}
