import XCTest
@testable import RepoPrompt

final class EscapedIndentationFixTests: XCTestCase {

	func testPromoteEscapedTabsInEncodedLine_spaces() {
		let input  = "<s0>\\t\\tlet x = 1"
		let output = String.promoteEscapedTabsInEncodedLine(input, spacesTabStop: 4)
		XCTAssertEqual(output, "<s8>let x = 1")
	}

	func testPromoteEscapedTabsInEncodedLine_tabs() {
		let input  = "<t1>\\tprint(\"hi\")"
		let output = String.promoteEscapedTabsInEncodedLine(input)
		XCTAssertEqual(output, "<t2>print(\"hi\")")
	}

	func testPromoteEscapedUnicode() {
		let input  = "<s4>\\u0009foo"
		let output = String.promoteEscapedTabsInEncodedLine(input, spacesTabStop: 4)
		XCTAssertEqual(output, "<s8>foo")
	}

	func testVectorizedPromotionAndScan() {
		let lines = [
			"<s0>ok",
			"<s4>\\tbad",
			"<t1>\\u0009alsoBad",
			"<s2>fine"
		]
		let bad = String.findLinesWithLeadingEscapedTabs(lines)
		XCTAssertEqual(bad, [1, 2])

		let promoted = String.promoteEscapedTabsInEncodedLines(lines)
		XCTAssertEqual(promoted[1], "<s8>bad")
		XCTAssertEqual(promoted[2], "<t2>alsoBad")

		// After promotion, there should be no flagged lines.
		let badAfter = String.findLinesWithLeadingEscapedTabs(promoted)
		XCTAssertTrue(badAfter.isEmpty)
	}
	
	func testIdempotence() {
		let input = "<s4>\\t\\tfunction() {"
		let once = String.promoteEscapedTabsInEncodedLine(input)
		let twice = String.promoteEscapedTabsInEncodedLine(once)
		XCTAssertEqual(once, twice)
		XCTAssertEqual(once, "<s12>function() {")
	}
	
	func testMixedEscapes() {
		let input = "<s0>\\t\\u0009\\tlet x = 1"
		let output = String.promoteEscapedTabsInEncodedLine(input)
		XCTAssertEqual(output, "<s12>let x = 1")
	}
	
	func testNonMatchingLines() {
		// Lines without encoded indentation tags should pass through unchanged
		let lines = [
			"regular line",
			"another line"
		]
		let result = String.promoteEscapedTabsInEncodedLines(lines)
		XCTAssertEqual(result, lines)
	}
	
	func testEmptyContent() {
		let input = "<s4>\\t\\t"
		let output = String.promoteEscapedTabsInEncodedLine(input)
		XCTAssertEqual(output, "<s12>")
	}
	
	func testPartialEscapes() {
		// Only leading escapes should be promoted, not those in the middle
		let input = "<s4>print(\"\\t\\tindented\")"
		let output = String.promoteEscapedTabsInEncodedLine(input)
		XCTAssertEqual(output, "<s4>print(\"\\t\\tindented\")")
	}
	
	func testCustomTabStop() {
		let input = "<s0>\\t\\tcode"
		let output2 = String.promoteEscapedTabsInEncodedLine(input, spacesTabStop: 2)
		let output4 = String.promoteEscapedTabsInEncodedLine(input, spacesTabStop: 4)
		let output8 = String.promoteEscapedTabsInEncodedLine(input, spacesTabStop: 8)
		
		XCTAssertEqual(output2, "<s4>code")
		XCTAssertEqual(output4, "<s8>code")
		XCTAssertEqual(output8, "<s16>code")
	}

	func testLatexCommandNotPromotedWhenDisabled() {
		let input = "<s0>\\textbf{Hello}"
		let output = String.promoteEscapedTabsInEncodedLine(input, enabled: false)
		XCTAssertEqual(output, input)
	}

	func testShouldPromoteLeadingEscapedTabs_texPathDisabled() {
		XCTAssertFalse(String.shouldPromoteLeadingEscapedTabs(path: "/tmp/paper.tex"))
		XCTAssertFalse(String.shouldPromoteLeadingEscapedTabs(path: "/tmp/macros.sty"))
		XCTAssertTrue(String.shouldPromoteLeadingEscapedTabs(path: "/tmp/File.swift"))
	}

	func testShouldPromoteLeadingEscapedTabs_detectsLatexMarkersInNonTexFile() {
		let repl = "\\begin{align}\n\\textbf{X}\n\\end{align}"
		XCTAssertFalse(String.shouldPromoteLeadingEscapedTabs(path: "/tmp/readme.md", replaceRaw: repl))
	}
}
