import XCTest
@testable import RepoPrompt

final class GitServiceRenameParsingTests: XCTestCase {
	func testNormalizeRenamedPathPreservesPrefixForBraceRename() {
		let service = GitService()
		let raw = "build/static/js/{514.07631633.chunk.js => 514.506331af.chunk.js}"

		let normalized = service.normalizeRenamedPath(raw)

		XCTAssertEqual(normalized, "build/static/js/514.506331af.chunk.js")
	}

	func testNormalizeRenamedPathHandlesDirectorySegmentRename() {
		let service = GitService()

		let normalized = service.normalizeRenamedPath("src/{old => new}/file.ts")

		XCTAssertEqual(normalized, "src/new/file.ts")
	}

	func testNormalizeRenamedPathHandlesWholePathRename() {
		let service = GitService()

		let normalized = service.normalizeRenamedPath("old/path.ts => new/path.ts")

		XCTAssertEqual(normalized, "new/path.ts")
	}

	func testNormalizeRenamedPathFallsBackToWholePathRenameWhenBracesAreLiteral() {
		let service = GitService()

		let normalized = service.normalizeRenamedPath("docs/{draft}/old.md => docs/{draft}/new.md")

		XCTAssertEqual(normalized, "docs/{draft}/new.md")
	}

	func testNormalizeRenamedPathLeavesPlainPathsUntouched() {
		let service = GitService()

		let normalized = service.normalizeRenamedPath("src/docs/changelog/Version20.js")

		XCTAssertEqual(normalized, "src/docs/changelog/Version20.js")
	}

	func testParseNumstatOutputNormalizesBraceRenameDestination() {
		let service = GitService()
		let output = "1\t1\tbuild/static/js/{514.07631633.chunk.js => 514.506331af.chunk.js}"

		let map = service.parseNumstatOutput(output)

		XCTAssertEqual(map["build/static/js/514.506331af.chunk.js"]?.0, 1)
		XCTAssertEqual(map["build/static/js/514.506331af.chunk.js"]?.1, 1)
		XCTAssertFalse(map.keys.contains { $0.hasSuffix("}") })
	}

	func testNumstatAndNameStatusParsersAgreeOnRenameDestinationPath() {
		let service = GitService()
		let numstat = "1\t1\tbuild/static/js/{514.07631633.chunk.js => 514.506331af.chunk.js}"
		let nameStatus = "R100\tbuild/static/js/514.07631633.chunk.js\tbuild/static/js/514.506331af.chunk.js"

		let statsMap = service.parseNumstatOutput(numstat)
		let statusMap = service.parseNameStatusOutput(nameStatus)

		XCTAssertEqual(Set(statsMap.keys), Set(statusMap.keys))
		XCTAssertEqual(statusMap["build/static/js/514.506331af.chunk.js"], "R")
	}
}
