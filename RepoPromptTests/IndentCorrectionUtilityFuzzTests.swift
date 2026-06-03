//
//  IndentCorrectionUtilityFuzzTests.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-08-14.
//


import XCTest
@testable import RepoPrompt

final class IndentCorrectionUtilityFuzzTests: XCTestCase {

	// MARK: - Deterministic RNG

	private struct LCG: RandomNumberGenerator {
		var state: UInt64
		mutating func next() -> UInt64 {
			// Deterministic LCG (glibc-style parameters)
			state = 6364136223846793005 &* state &+ 1
			return state
		}
	}

	@inline(__always)
	private func randi(_ rng: inout LCG, _ upperExclusive: Int) -> Int {
		precondition(upperExclusive > 0)
		return Int(rng.next() % UInt64(upperExclusive))
	}

	@inline(__always)
	private func randi(_ rng: inout LCG, _ range: ClosedRange<Int>) -> Int {
		let width = range.upperBound - range.lowerBound + 1
		return range.lowerBound + randi(&rng, width)
	}

	@inline(__always)
	private func chance(_ rng: inout LCG, _ numerator: Int, _ denominator: Int) -> Bool {
		return randi(&rng, denominator) < numerator
	}

	// MARK: - Helpers

	/// Construct an encoded line with optional leaked whitespace *after* the tag.
	private func makeLine(type: String, count: Int, content: String, leakSpaces: Int = 0, leakTabs: Int = 0) -> String {
		let tag = "<\(type)\(max(0, count))>"
		let leaks = String(repeating: "\t", count: max(0, leakTabs)) + String(repeating: " ", count: max(0, leakSpaces))
		return tag + leaks + content
	}

	/// Ensure there is no literal whitespace at content start (post-tag).
	private func assertNoLeadingWhitespaceInContent(_ lines: [String], file: StaticString = #file, line: UInt = #line) {
		for l in lines {
			let content = String.removeIndentationTag(l)
			guard !content.isEmpty else { continue }
			XCTAssertFalse(content.hasPrefix(" ") || content.hasPrefix("\t"),
			               "Leading whitespace leaked into content: \(content)", file: file, line: line)
		}
	}

	/// Sum absolute indentation differences between two blocks (line-for-line).
	private func sumAbsDiffs(vs reference: [String], lines: [String]) -> Int {
		return zip(reference, lines).reduce(0) { acc, pair in
			let (r, x) = pair
			return acc + abs(String.getIndentationLevel(from: r) - String.getIndentationLevel(from: x))
		}
	}

	/// Distinct indentation levels in a block.
	private func distinctIndentCount(_ lines: [String]) -> Int {
		return Set(lines.map { String.getIndentationLevel(from: $0) }).count
	}

	/// Random content generator (keeps lines distinct).
	private func makeContent(caseId: Int, line: Int) -> String {
		return "L\(caseId)-\(line)"
	}

	// MARK: - Generators

	private struct GeneratedBlock {
		let lines: [String]
		var levels: [Int]   // logical levels (units for tabs; spaces count for spaces)
		let type: String    // "s" or "t"
		let unit: Int       // for spaces: 2 or 4; for tabs: 1
	}

	/// Generate a random **space-based** oldBlock with 2- or 4-space units and a smooth-ish shape.
	private func genSpaceOldBlock(caseId: Int, rng: inout LCG) -> GeneratedBlock {
		let n = randi(&rng, 12...40)
		let unit = chance(&rng, 1, 3) ? 2 : 4  // Prefer 4 but include 2-space styles
		let maxLevel = randi(&rng, 3...8)      // logical levels (not spaces)
		var levels: [Int] = []
		levels.reserveCapacity(n)

		var level = randi(&rng, 0...2)
		for _ in 0..<n {
			// Random walk with clamping
			let step = randi(&rng, [-1, 0, 1])
			level = min(max(level + step, 0), maxLevel)
			levels.append(level * unit) // convert to spaces
		}

		let lines = (0..<n).map { i in
			makeLine(type: "s", count: levels[i], content: makeContent(caseId: caseId, line: i))
		}

		return GeneratedBlock(lines: lines, levels: levels, type: "s", unit: unit)
	}

	/// Generate a random **tab-based** oldBlock with 1-tab unit and a smooth-ish shape.
	private func genTabOldBlock(caseId: Int, rng: inout LCG) -> GeneratedBlock {
		let n = randi(&rng, 12...40)
		let unit = 1
		let maxLevel = randi(&rng, 3...8)
		var levels: [Int] = []
		levels.reserveCapacity(n)

		var level = randi(&rng, 0...2)
		for _ in 0..<n {
			let step = randi(&rng, [-1, 0, 1])
			level = min(max(level + step, 0), maxLevel)
			levels.append(level) // tabs count directly
		}

		let lines = (0..<n).map { i in
			makeLine(type: "t", count: levels[i], content: makeContent(caseId: caseId, line: i))
		}

		return GeneratedBlock(lines: lines, levels: levels, type: "t", unit: unit)
	}

	/// Create a search block that encodes a uniform old-search delta (in *effective* units),
	/// with optional small noise/outliers (kept non-negative).
	private func makeSearchBlock(from old: GeneratedBlock, rng: inout LCG,
	                             uniformDeltaUnits: Int,
	                             noiseProbability: Int = 0, noiseMagnitudeUnits: Int = 0) -> [String] {

		let isSpaces = (old.type == "s")
		let unit = old.unit

		return old.levels.enumerated().map { (i, oldIndent) in
			var searchIndent = oldIndent - (uniformDeltaUnits * unit) // old - search = uniformDeltaUnits * unit
			// Add optional noise
			if noiseProbability > 0, chance(&rng, noiseProbability, 100) {
				let noiseUnits = randi(&rng, -noiseMagnitudeUnits...noiseMagnitudeUnits)
				searchIndent -= noiseUnits * unit
			}
			searchIndent = max(0, searchIndent)

			let content = makeContent(caseId: 10000 + i, line: i) // differ content
			if isSpaces {
				return makeLine(type: "s", count: searchIndent, content: content,
				                leakSpaces: chance(&rng, 1, 4) ? randi(&rng, 0...2) : 0,
				                leakTabs: 0)
			} else {
				// tabs
				return makeLine(type: "t", count: searchIndent, content: content,
				                leakSpaces: chance(&rng, 1, 4) ? randi(&rng, 0...3) : 0,
				                leakTabs: chance(&rng, 1, 6) ? 1 : 0)
			}
		}
	}

	/// Create a snippet that mostly follows the search block's indentation (pre-correction),
	/// but mixes indent types and introduces leaked leading whitespace.
	private func makeSnippet(from search: [String], fileType: String, fileUnit: Int, rng: inout LCG) -> [String] {
		return search.enumerated().map { (i, line) in
			let (stype, scount) = String.getIndentationEncoding(from: line)
			let indent = scount
			let content = "S\(i)"

			// Mix styles ~30% of the time; keep valid conversions (e.g., spaces -> tabs only if divisible by 4).
			if stype == "s" {
				// sometimes convert to tabs if divisible by 4
				if chance(&rng, 3, 10), indent % 4 == 0 {
					let tabs = indent / 4
					return makeLine(type: "t", count: tabs, content: content,
					                leakSpaces: randi(&rng, 0...2), leakTabs: chance(&rng, 1, 5) ? 1 : 0)
				} else {
					return makeLine(type: "s", count: indent, content: content,
					                leakSpaces: randi(&rng, 0...2), leakTabs: 0)
				}
			} else {
				// stype == "t"
				if chance(&rng, 3, 10) {
					let spaces = indent * 4
					return makeLine(type: "s", count: spaces, content: content,
					                leakSpaces: randi(&rng, 0...2), leakTabs: 0)
				} else {
					return makeLine(type: "t", count: indent, content: content,
					                leakSpaces: randi(&rng, 0...3), leakTabs: chance(&rng, 1, 6) ? 1 : 0)
				}
			}
		}
	}

	// MARK: - Fuzz: Space files

	func testFuzz_SpaceFiles_Alignment_Unification_Invariants() {
		var rng = LCG(state: 0xDEADBEEF)
		let cases = 120

		for caseId in 0..<cases {
			let old = genSpaceOldBlock(caseId: caseId, rng: &rng)
			// Choose a uniform delta in units (e.g., -3...+3 units)
			let deltaUnits = randi(&rng, -3...3)
			let search = makeSearchBlock(from: old, rng: &rng, uniformDeltaUnits: deltaUnits,
			                             noiseProbability: 10, noiseMagnitudeUnits: 1)
			let snippet = makeSnippet(from: search, fileType: old.type, fileUnit: old.unit, rng: &rng)

			let before = sumAbsDiffs(vs: old.lines, lines: snippet)
			let result = IndentCorrectionUtility.reIndentUsingSearchBlock(
				oldBlock: old.lines, searchBlock: search, newSnippet: snippet
			)
			let after = sumAbsDiffs(vs: old.lines, lines: result)

			// Invariants
			for line in result {
				let indent = String.getIndentationLevel(from: line)
				XCTAssertTrue((0...999).contains(indent), "Indent out of bounds")
				let (t, _) = String.getIndentationEncoding(from: line)
				XCTAssertEqual(t, "s", "Result must unify to space-based style.")
			}
			// No leaked leading whitespace in content for space files
			assertNoLeadingWhitespaceInContent(result)

			// Non-regression on alignment (often strictly improves)
			XCTAssertLessThanOrEqual(after, before, "Alignment should not get worse for space files.")

			// No flattening if original snippet had multiple indent levels
			let origDistinct = distinctIndentCount(snippet)
			let newDistinct = distinctIndentCount(result)
			if origDistinct > 1 {
				XCTAssertGreaterThan(newDistinct, 1, "Must not flatten multi-level structures.")
			}

			// Idempotence
			let again = IndentCorrectionUtility.reIndentUsingSearchBlock(
				oldBlock: old.lines, searchBlock: search, newSnippet: result
			)
			XCTAssertEqual(again, result, "Correction should be idempotent.")
		}
	}

	// MARK: - Fuzz: Tab files

	func testFuzz_TabFiles_Unification_Invariants() {
		var rng = LCG(state: 0xBADC0FFEE0DDF00D)
		let cases = 100

		for caseId in 0..<cases {
			let old = genTabOldBlock(caseId: 5000 + caseId, rng: &rng)
			let deltaUnits = randi(&rng, -2...3) // in tab units
			let search = makeSearchBlock(from: old, rng: &rng, uniformDeltaUnits: deltaUnits,
			                             noiseProbability: 12, noiseMagnitudeUnits: 1)
			let snippet = makeSnippet(from: search, fileType: old.type, fileUnit: old.unit, rng: &rng)

			let before = sumAbsDiffs(vs: old.lines, lines: snippet)
			let result = IndentCorrectionUtility.reIndentUsingSearchBlock(
				oldBlock: old.lines, searchBlock: search, newSnippet: snippet
			)
			let after = sumAbsDiffs(vs: old.lines, lines: result)

			// Invariants
			for line in result {
				let indent = String.getIndentationLevel(from: line)
				XCTAssertTrue((0...999).contains(indent), "Indent out of bounds")
				let (t, _) = String.getIndentationEncoding(from: line)
				XCTAssertEqual(t, "t", "Result must unify to tab-based style.")
			}
			// For tabs, small leftover spaces in content may remain; only enforce bounds and style.

			// Non-regression
			XCTAssertLessThanOrEqual(after, before, "Alignment should not get worse for tab files.")

			// Avoid flattening when original had multiple levels
			let origDistinct = distinctIndentCount(snippet)
			let newDistinct = distinctIndentCount(result)
			if origDistinct > 1 {
				XCTAssertGreaterThan(newDistinct, 1, "Must not flatten multi-level structures.")
			}

			// Idempotence
			let again = IndentCorrectionUtility.reIndentUsingSearchBlock(
				oldBlock: old.lines, searchBlock: search, newSnippet: result
			)
			XCTAssertEqual(again, result, "Correction should be idempotent.")
		}
	}

	// MARK: - Fuzz: Outlier robustness (MAD filtering)

	func testFuzz_OutliersRobustness_MADFiltering() {
		var rng = LCG(state: 0xFEEDFACECAFEBABE)
		let cases = 80

		for caseId in 0..<cases {
			let old = genSpaceOldBlock(caseId: 9000 + caseId, rng: &rng)
			// Strong uniform delta that should be discovered
			let deltaUnits = randi(&rng, 1...3) // positive shift (old - search = +)
			// Inject a few extreme outliers
			let search = makeSearchBlock(from: old, rng: &rng, uniformDeltaUnits: deltaUnits,
			                             noiseProbability: 15, noiseMagnitudeUnits: 5)
			let snippet = makeSnippet(from: search, fileType: old.type, fileUnit: old.unit, rng: &rng)

			let before = sumAbsDiffs(vs: old.lines, lines: snippet)
			let result = IndentCorrectionUtility.reIndentUsingSearchBlock(
				oldBlock: old.lines, searchBlock: search, newSnippet: snippet
			)
			let after = sumAbsDiffs(vs: old.lines, lines: result)

			// With a strong coherent signal, alignment should improve despite outliers.
			XCTAssertLessThan(after, before, "Alignment should improve with outliers present.")
		}
	}

	// MARK: - Fuzz: Discrete fallback (uniform delta exceeding cap)

	func testFuzz_DiscreteFallback_NoFlattening() {
		var rng = LCG(state: 0xABCDEF0123456789)
		let cases = 60

		for caseId in 0..<cases {
			// Create a space file whose minIndent is small => tight effective cap (12)
			var old = genSpaceOldBlock(caseId: 12000 + caseId, rng: &rng)
			// Force presence of some low-indented lines
			if !old.lines.isEmpty {
				old.levels[0] = 0
			}
			let oldLinesForced = old.levels.enumerated().map { (i, lvl) in
				makeLine(type: "s", count: lvl, content: makeContent(caseId: 12000 + caseId, line: i))
			}
			let oldBlock = GeneratedBlock(lines: oldLinesForced, levels: old.levels, type: "s", unit: old.unit)

			// Make a *large* uniform delta (beyond 12) to force discrete fallback
			let deltaUnits = randi(&rng, 5...8) // units * unit (2/4) => often >12 spaces
			let search = makeSearchBlock(from: oldBlock, rng: &rng, uniformDeltaUnits: deltaUnits,
			                             noiseProbability: 5, noiseMagnitudeUnits: 0)
			let snippet = makeSnippet(from: search, fileType: oldBlock.type, fileUnit: oldBlock.unit, rng: &rng)

			let result = IndentCorrectionUtility.reIndentUsingSearchBlock(
				oldBlock: oldBlock.lines, searchBlock: search, newSnippet: snippet
			)

			// Check candidate delta uniformity and allowed set where possible.
			// Compute observed per-line deltas (new - old snippet)
			let ds = zip(snippet, result).map { String.getIndentationLevel(from: $1) - String.getIndentationLevel(from: $0) }
			let unique = Set(ds)
			// In discrete fallback, algorithm searches among [-12,-8,-4,0,4,8,12,16], but it may pick 16 when multi-level.
			// We at least enforce "bounded" and "not wildly large", and uniform where feasible.
			XCTAssertTrue(unique.allSatisfy { abs($0) <= 16 }, "Discrete fallback deltas must be bounded.")
			// Avoid flattening
			if distinctIndentCount(snippet) > 1 {
				XCTAssertGreaterThan(distinctIndentCount(result), 1, "Discrete fallback must not flatten.")
			}
			// Invariants
			for line in result {
				let indent = String.getIndentationLevel(from: line)
				XCTAssertTrue((0...999).contains(indent), "Indent out of range in discrete fallback.")
			}
		}
	}

	// MARK: - Fuzz: Large inputs (stride in pair gathering)

	func testFuzz_LargeInputs_StrideBounded() {
		var rng = LCG(state: 0xCAFED00D1337BEEF)

		// Create a large old block (400 lines), ensure gatherComparableLinePairs stride kicks in.
		let n = 400
		let unit = 4
		var levels: [Int] = []
		levels.reserveCapacity(n)
		var level = 0
		let maxLevel = 12
		for _ in 0..<n {
			level = min(max(level + randi(&rng, [-1, 0, 1]), 0), maxLevel)
			levels.append(level * unit)
		}
		let oldBlock = (0..<n).map { i in makeLine(type: "s", count: levels[i], content: "BIG-\(i)") }

		// Make a clean search (uniform -1 unit) with occasional noise
		let deltaUnits = 1
		let search = (0..<n).map { i -> String in
			var sIndent = levels[i] - deltaUnits * unit
			if chance(&rng, 1, 15) { sIndent -= unit } // small noise
			sIndent = max(0, sIndent)
			return makeLine(type: "s", count: sIndent, content: "BIGS-\(i)")
		}

		// Snippet mirrors search but with random style mix and leaks
		let snippet = makeSnippet(from: search, fileType: "s", fileUnit: unit, rng: &rng)

		let before = sumAbsDiffs(vs: oldBlock, lines: snippet)
		let result = IndentCorrectionUtility.reIndentUsingSearchBlock(
			oldBlock: oldBlock, searchBlock: search, newSnippet: snippet
		)
		let after = sumAbsDiffs(vs: oldBlock, lines: result)

		// Should improve notably in most large cases; at minimum, not regress.
		XCTAssertLessThanOrEqual(after, before, "Alignment should not worsen on large inputs.")
		for line in result {
			let indent = String.getIndentationLevel(from: line)
			XCTAssertTrue((0...999).contains(indent), "Indent out of range on large inputs.")
		}
	}

	// MARK: - Utility

	private func randi(_ rng: inout LCG, _ array: [Int]) -> Int {
		return array[randi(&rng, array.count)]
	}
}
