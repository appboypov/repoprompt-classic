//
//  CodeMapLineNumberTests.swift
//  RepoPromptTests
//
//  Validates line number computation against read_file line-splitting rules.
//

import XCTest
@testable import RepoPrompt

final class CodeMapLineNumberTests: XCTestCase {
	func testLineBoundariesMatchReadFileSplits() {
		let content = "first\r\nsecond\nthird\rfourth"
		let pairs = String.splitContentPreservingAllLineEndings(content)
		var expectedStarts: [Int] = []
		var offset = 0
		for pair in pairs {
			expectedStarts.append(offset)
			offset += pair.line.utf16.count + pair.ending.utf16.count
		}
		let boundaries = CodeMapGenerator.computeLineBoundaries(content: content)
		XCTAssertEqual(boundaries, expectedStarts)
		for (idx, start) in expectedStarts.enumerated() {
			let lineNumber = CodeMapGenerator.lineNumber(for: start, using: boundaries)
			XCTAssertEqual(lineNumber, idx + 1)
		}
	}
	
	func testLineNumberWithinLinesMatchesExpected() {
		let content = "one\n\ntwo\r\nthree"
		let pairs = String.splitContentPreservingAllLineEndings(content)
		var offsets: [Int] = []
		var offset = 0
		for pair in pairs {
			let midOffset = pair.line.utf16.isEmpty ? offset : (offset + min(1, pair.line.utf16.count - 1))
			offsets.append(midOffset)
			offset += pair.line.utf16.count + pair.ending.utf16.count
		}
		let boundaries = CodeMapGenerator.computeLineBoundaries(content: content)
		for (idx, loc) in offsets.enumerated() {
			let lineNumber = CodeMapGenerator.lineNumber(for: loc, using: boundaries)
			XCTAssertEqual(lineNumber, idx + 1)
		}
	}
}
