//
//  DiffViewModelSearchCursorTests.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-06-23.
//


import XCTest
@testable import RepoPrompt

/**
 Verifies that repeated invocations of
 `DiffGenerationUtility.generateDiffWithSearchBlock`
— when driven by an incrementing `searchStartLine` the same way
`DiffProcessingHelper` does internally — correctly match *subsequent*
occurrences of a search-block and never re-match the same region.

This provides direct safety-net coverage for the cursor logic that
`DiffViewModel` relies on when it processes multiple, identical
`<search>` blocks in a single file.
*/
final class DiffViewModelSearchCursorTests: XCTestCase {
	
	/// Simple helper to unwrap the first chunk (tests only ever
	/// generate one) or fail early with a useful message.
	private func firstStartLine(in chunks: [DiffChunk],
								file: StaticString = #file,
								line: UInt = #line) -> Int {
		guard let chunk = chunks.first else {
			XCTFail("No diff chunks produced", file: file, line: line)
			return -1
		}
		return chunk.startLine
	}
	
	/// The core scenario: the same three-line pattern (`foo/bar/baz`)
	/// appears twice in the file.  
	/// We patch the first occurrence, then ask the diff generator to
	/// *continue searching* after that point and patch the second.
	func testSearchCursorAdvancesBetweenIdenticalBlocks() async throws {
		
		// ── 1)  Synthetic “file” with two identical blocks ────────────
		//
		//  0  alpha
		//  1  beta
		//  2  foo()
		//  3  bar()
		//  4  baz()
		//  5  foo()
		//  6  bar()
		//  7  baz()
		//  8  omega
		let original: [String] = [
			"alpha", "beta",
			"foo()", "bar()", "baz()",
			"foo()", "bar()", "baz()",
			"omega"
		]
		
		let searchBlock = ["foo()", "bar()", "baz()"]
		let patch1      = ["FOO()", "BAR()", "BAZ()"]
		let patch2      = ["FOO2()", "BAR2()", "BAZ2()"]
		
		// ── 2)  First replacement – expect match at line 2 ───────────
		let diff1 = try await DiffGenerationUtility.generateDiffWithSearchBlock(
			fileContent     : original,
			searchBlock     : searchBlock,
			newContent      : patch1,
			diffPrecision   : .normal,
			lineIndexMap    : nil,
			searchStartLine : 0
		)
		let firstStart = firstStartLine(in: diff1)
		XCTAssertEqual(firstStart, 2,
					   "First block should begin at line 2")
		
		// ── 3)  Second replacement – start *after* first block ───────
		let nextSearchStart = firstStart + searchBlock.count   // 2 + 3 = 5
		let diff2 = try await DiffGenerationUtility.generateDiffWithSearchBlock(
			fileContent     : original,
			searchBlock     : searchBlock,
			newContent      : patch2,
			diffPrecision   : .normal,
			lineIndexMap    : nil,
			searchStartLine : nextSearchStart
		)
		let secondStart = firstStartLine(in: diff2)
		XCTAssertEqual(secondStart, 5,
					   "Second block should begin at line 5 (immediately after the first)")
		
		// Sanity: the two chunks must target *different* regions
		XCTAssertNotEqual(firstStart, secondStart,
						  "Search cursor did not advance; regions overlap.")
	}
}
