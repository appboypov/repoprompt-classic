import XCTest
@testable import RepoPrompt

final class IndentCorrectionUtilityTests: XCTestCase {
	
	// MARK: - Debug helpers (optional)
	
	private func debugPrintBlock(_ block: [String]) {
		print("----- Block Start -----")
		for (i, line) in block.enumerated() {
			let indent = String.getIndentationLevel(from: line)
			let content = String.removeIndentationTag(line)
			print("[\(i)] indent=\(indent): \"\(content)\"")
		}
		print("----- Block End -------\n")
	}
	
	private func levels(_ lines: [String]) -> [Int] {
		return lines.map { String.getIndentationLevel(from: $0) }
	}
	
	/// Average absolute difference between indentation of same-index lines.
	private func alignmentScore(_ a: [String], _ b: [String]) -> Double {
		let count = min(a.count, b.count)
		guard count > 0 else { return .infinity }
		var sum = 0
		for i in 0..<count {
			sum += abs(String.getIndentationLevel(from: a[i]) - String.getIndentationLevel(from: b[i]))
		}
		return Double(sum) / Double(count)
	}
	
	private func lineHasLeakedLeadingTab(_ line: String) -> Bool {
		let withoutTag = String.removeIndentationTag(line)
		return withoutTag.hasPrefix("\t") || withoutTag.hasPrefix("\u{0009}")
	}
	
	// MARK: - 1) Already aligned => no change
	
	func testAlreadyAlignedSnippet() {
		let oldBlock = [
			"<s4>func foo() {",
			"<s8>print(\"Hello\")",
			"<s4>}"
		]
		let searchBlock: [String] = []
		let newSnippet = [
			"<s4>func bar() {",
			"<s8>print(\"World\")",
			"<s4>}"
		]
		
		let result = IndentCorrectionUtility.reIndentUsingSearchBlock(
			oldBlock: oldBlock,
			searchBlock: searchBlock,
			newSnippet: newSnippet
		)
		
		XCTAssertEqual(result, newSnippet, "Snippet was already aligned but got changed.")
	}
	
	// MARK: - 2) Tabs → Spaces conversion (match file style)
	
	func testTabsConvertedToSpacesAndAligned() {
		let oldBlock = [
			"<s4>if (condition) {",
			"<s8>doSomething()",
			"<s4>}"
		]
		let searchBlock = [
			"<s4>while (somethingElse) {",
			"<s8>anotherThing()",
			"<s4>}"
		]
		let newSnippet = [
			"<t1>func doTabbyStuff() {",
			"<t2>print(\"Tab Indented!\")",
			"<t1>}"
		]
		
		let result = IndentCorrectionUtility.reIndentUsingSearchBlock(
			oldBlock: oldBlock,
			searchBlock: searchBlock,
			newSnippet: newSnippet
		)
		
		// Verify s-style was adopted and looks sane.
		for line in result {
			let (type, count) = String.getIndentationEncoding(from: line)
			XCTAssertEqual(type, "s", "Expected snippet lines to be converted to space-based indentation.")
			XCTAssertTrue(count >= 4, "Expected at least one level of indentation in the converted snippet.")
		}
	}
	
	// MARK: - 3) Multi-level structure preserved
	
	func testMultiLevelSnippetPreservesIndentStructure() {
		let oldBlock = [
			"<s4>class Foo {",
			"<s8>func something() {",
			"<s12>print(\"Hello\")",
			"<s8>}",
			"<s4>}"
		]
		let searchBlock = [
			"<s4>struct Bar {",
			"<s8>let x = 10",
			"<s4>}"
		]
		let newSnippet = [
			"<s2>class Baz {",
			"<s4>func nestedThing() {",
			"<s6>print(\"Nested!\")",
			"<s4>}",
			"<s2>}"
		]
		
		let result = IndentCorrectionUtility.reIndentUsingSearchBlock(
			oldBlock: oldBlock,
			searchBlock: searchBlock,
			newSnippet: newSnippet
		)
		
		let distinctIndentSet = Set(result.map { String.getIndentationLevel(from: $0) })
		XCTAssertTrue(distinctIndentSet.count > 1, "Expected multi-level indentation to be preserved, but it collapsed.")
	}
	
	// MARK: - 4) Extreme inputs never produce invalid indentation
	
	func testExtremeShiftIsClampedOrFallback() {
		let oldBlock = [
			"<s4>public void oldFunc() {",
			"<s8>// body",
			"<s4>}"
		]
		let searchBlock = [
			"<s4>extension SomeExtension {",
			"<s8>func doIt() {}",
			"<s4>}"
		]
		let newSnippet = [
			"<s100>giantFunction() {",
			"<s104>print(\"Over-indented!\")",
			"<s100>}"
		]
		
		let result = IndentCorrectionUtility.reIndentUsingSearchBlock(
			oldBlock: oldBlock,
			searchBlock: searchBlock,
			newSnippet: newSnippet
		)
		
		for line in result {
			let indent = String.getIndentationLevel(from: line)
			XCTAssertTrue(indent >= 0 && indent <= 999, "Indentation out of valid range after shift/clamp.")
		}
	}
	
	// MARK: - 5) Single-level near single-level => stable
	
	func testSingleLevelSnippetNearSingleLevelOldBlock() {
		let oldBlock = [
			"<s4>let a = 1",
			"<s4>let b = 2",
			"<s4>print(a + b)"
		]
		let searchBlock: [String] = []
		let newSnippet = [
			"<s4>let x = 10",
			"<s4>let y = 11",
			"<s4>print(x + y)"
		]
		
		let result = IndentCorrectionUtility.reIndentUsingSearchBlock(
			oldBlock: oldBlock,
			searchBlock: searchBlock,
			newSnippet: newSnippet
		)
		
		XCTAssertEqual(result, newSnippet, "Snippet was already single-level aligned and should remain unchanged.")
	}
	
	// MARK: - 6) Leaked \t after tag is promoted into indent (no literal tabs left)
	
	func testLeakedTabPromotionIsAppliedAndNoLiteralTabsRemain() {
		let oldBlock = [
			"<s4>func f() {",
			"<s8>print(1)",
			"<s4>}"
		]
		let searchBlock = oldBlock // style anchor
		let newSnippet = [
			"<s4>\tlet x = 1",
			"<s8>\tprint(x)",
			"<s4>\t}"
		]
		
		// Sanity: leaked tabs are present in input content
		XCTAssertTrue(lineHasLeakedLeadingTab(newSnippet[0]))
		XCTAssertTrue(lineHasLeakedLeadingTab(newSnippet[1]))
		
		let result = IndentCorrectionUtility.reIndentUsingSearchBlock(
			oldBlock: oldBlock,
			searchBlock: searchBlock,
			newSnippet: newSnippet
		)
		
		// The leaked tabs should be absorbed into the indent level and no longer present in content.
		for (i, line) in result.enumerated() {
			XCTAssertFalse(lineHasLeakedLeadingTab(line), "Line \(i) still has a literal leading tab in content.")
		}
		
		// And the first line should have gained at least one indent unit relative to the input.
		let oldIndent = String.getIndentationLevel(from: newSnippet[0]) // counts only the <sN> tag
		let newIndent = String.getIndentationLevel(from: result[0])
		XCTAssertEqual(newIndent, oldIndent + 4, "Expected leaked tab to increase indentation by one unit (4 spaces).")
	}
	
	// MARK: - 7) Idempotency: running again doesn't change the result
	
	func testIdempotentWhenRunTwice() {
		let oldBlock = [
			"<s4>if ready {",
			"<s8>go()",
			"<s4>}"
		]
		let searchBlock = [
			"<s0>if ready {",
			"<s4>go()",
			"<s0>}"
		]
		let newSnippet = [
			"<s0>if ready {",
			"<s4>go()",
			"<s0>}"
		]
		
		let once = IndentCorrectionUtility.reIndentUsingSearchBlock(
			oldBlock: oldBlock, searchBlock: searchBlock, newSnippet: newSnippet
		)
		let twice = IndentCorrectionUtility.reIndentUsingSearchBlock(
			oldBlock: oldBlock, searchBlock: searchBlock, newSnippet: once
		)
		
		XCTAssertEqual(once, twice, "Re-running the indent correction should be idempotent.")
	}
	
	// MARK: - 8) Spaces → Tabs conversion (match file style)
	
	func testSpacesSnippetConvertedToTabsWhenOldBlockIsTabs() {
		let oldBlock = [
			"<t1>switch v {",
			"<t2>case 1: break",
			"<t1>}"
		]
		let searchBlock = [
			"<t1>while ok {",
			"<t2>noop()",
			"<t1>}"
		]
		let newSnippet = [
			"<s4>func g() {",
			"<s8>print(\"hi\")",
			"<s4>}"
		]
		
		let result = IndentCorrectionUtility.reIndentUsingSearchBlock(
			oldBlock: oldBlock, searchBlock: searchBlock, newSnippet: newSnippet
		)
		
		for line in result {
			let (type, _) = String.getIndentationEncoding(from: line)
			XCTAssertEqual(type, "t", "Expected snippet lines to be converted to tab-based indentation.")
		}
	}
	
	// MARK: - 9) Uniform delta derived from searchBlock aligns snippet to oldBlock
	
	func testUniformDeltaFromSearchBlockAlignsSnippetToOldBlock() {
		// oldBlock is exactly one indent unit deeper than searchBlock
		let oldBlock = [
			"<s4>if ok {",
			"<s8>doWork()",
			"<s4>}"
		]
		let searchBlock = [
			"<s0>if ok {",
			"<s4>doWork()",
			"<s0>}"
		]
		// newSnippet matches the under-indented search style; the transform should shift it by +4.
		let newSnippet = [
			"<s0>if ok {",
			"<s4>doWork()",
			"<s0>}"
		]
		
		let before = alignmentScore(newSnippet, oldBlock)
		let result = IndentCorrectionUtility.reIndentUsingSearchBlock(
			oldBlock: oldBlock, searchBlock: searchBlock, newSnippet: newSnippet
		)
		let after = alignmentScore(result, oldBlock)
		
		XCTAssertTrue(after < before, "Uniform delta should improve alignment.")
		XCTAssertEqual(levels(result), levels(oldBlock), "Snippet should align exactly to oldBlock levels.")
	}
	
	// MARK: - 10) Discrete fallback kicks in when uniform delta exceeds cap
	
	func testDiscreteFallbackCapsShiftsUsingHardCap() {
		// Make old vs search differ by a huge constant delta; uniform will be too large.
		let oldBlock = [
			"<s4>a {",
			"<s8>b()",
			"<s4>}"
		]
		let searchBlock = [
			"<s104>a {",
			"<s108>b()",
			"<s104>}"
		]
		let newSnippet = [
			"<s0>a {",
			"<s4>b()",
			"<s0>}"
		]
		
		let result = IndentCorrectionUtility.reIndentUsingSearchBlock(
			oldBlock: oldBlock, searchBlock: searchBlock, newSnippet: newSnippet
		)
		
		// Ensure per-line shift did not exceed the hard cap.
		let cap = IndentationConfig.hardMaxAllowedShift  // e.g., 24 if maxAllowedShift = 12
		for (orig, now) in zip(newSnippet, result) {
			let d = String.getIndentationLevel(from: now) - String.getIndentationLevel(from: orig)
			XCTAssertLessThanOrEqual(abs(d), cap, "Per-line shift exceeded hard cap.")
		}
	}
	
	// MARK: - 11) Negative uniform delta cannot produce negative indentation
	
	func testNoNegativeIndentWithLargeNegativeUniformDelta() {
		// Here, search is over-indented relative to old; uniform delta will be negative.
		let oldBlock = [
			"<s0>func h() {",
			"<s4>doit()",
			"<s0>}"
		]
		let searchBlock = [
			"<s12>func h() {",
			"<s16>doit()",
			"<s12>}"
		]
		let newSnippet = [
			"<s0>func h() {",
			"<s0>return",
			"<s0>}"
		]
		
		let result = IndentCorrectionUtility.reIndentUsingSearchBlock(
			oldBlock: oldBlock, searchBlock: searchBlock, newSnippet: newSnippet
		)
		
		for (i, line) in result.enumerated() {
			let indent = String.getIndentationLevel(from: line)
			XCTAssertGreaterThanOrEqual(indent, 0, "Line \(i) ended up with negative indentation.")
		}
	}
	
	// MARK: - 12) Do not invent transforms when search is empty
	
	func testNoInventedTransformWhenSearchBlockEmpty() {
		let oldBlock = [
			"<s4>if cond {",
			"<s8>work()",
			"<s4>}"
		]
		let searchBlock: [String] = [] // no evidence
		// Over-indented snippet; since search is empty, we should not attempt to "correct" it.
		let newSnippet = [
			"<s8>if cond {",
			"<s12>work()",
			"<s8>}"
		]
		
		let result = IndentCorrectionUtility.reIndentUsingSearchBlock(
			oldBlock: oldBlock, searchBlock: searchBlock, newSnippet: newSnippet
		)
		
		XCTAssertEqual(result, newSnippet, "With empty searchBlock, we should not invent a transform.")
	}
}
