import XCTest
@testable import RepoPrompt

final class StandardizedPathTests: XCTestCase {
	func testAbsoluteStandardizesRelativeInputWithoutMakingItAbsolute() {
		let result = StandardizedPath.absolute("src/../File.swift")
		XCTAssertEqual(result, "src/../File.swift")
		XCTAssertFalse(result.hasPrefix("/"))
	}

	func testAbsoluteExpandsTildeToAbsolutePath() {
		let result = StandardizedPath.absolute("~/Repo/File.swift")
		XCTAssertTrue(result.hasPrefix("/"))
		XCTAssertTrue(result.hasSuffix("/Repo/File.swift"))
	}

	func testRelativeCollapsesToEmptyWhenSegmentsCancelOut() {
		XCTAssertEqual(StandardizedPath.relative("a/.."), "")
		XCTAssertEqual(StandardizedPath.relative("a/b/../.."), "")
	}

	func testRelativePreservesLeadingParentTraversalAfterNormalization() {
		XCTAssertEqual(StandardizedPath.relative("a/../../b"), "../b")
		XCTAssertEqual(StandardizedPath.relative(".././a//b/.."), "../a")
	}

	func testRelativeTreatsOnlyExactDotSegmentsAsSpecial() {
		XCTAssertEqual(StandardizedPath.relative(".../file.swift"), ".../file.swift")
	}

	func testContainsNULDetectsEmbeddedNullScalar() {
		XCTAssertTrue(StandardizedPath.containsNUL("abc\u{0}def"))
		XCTAssertFalse(StandardizedPath.containsNUL("abcdef"))
	}

	func testDiagnosticEscapedRendersNULAndCommonControlsSafely() {
		let input = "a\u{0}b\nc\td\re\u{7F}"
		XCTAssertEqual(StandardizedPath.diagnosticEscaped(input), "a\\0b\\nc\\td\\re\\u{7F}")
	}
}
