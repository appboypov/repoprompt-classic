import XCTest
@testable import RepoPrompt

final class SliceRebaseEngineTests: XCTestCase {
	func testNoOpWhenContentIsUnchanged() {
		let text = """
		a
		b
		c
		d
		"""

		let result = SliceRebaseEngine.rebase(
			oldText: text,
			newText: text,
			oldRanges: [LineRange(start: 2, end: 3)],
			anchors: nil
		)

		XCTAssertEqual(result.rebased, [LineRange(start: 2, end: 3)])
		XCTAssertTrue(result.dropped.isEmpty)
		XCTAssertFalse(result.didChange)
	}

	func testFastPathShiftsTailRangesAfterSingleInsertion() {
		let oldText = """
		a
		b
		c
		d
		"""
		let newText = """
		intro
		a
		b
		c
		d
		"""

		let result = SliceRebaseEngine.rebase(
			oldText: oldText,
			newText: newText,
			oldRanges: [LineRange(start: 2, end: 3)],
			anchors: nil
		)

		XCTAssertEqual(result.rebased, [LineRange(start: 3, end: 4)])
		XCTAssertTrue(result.dropped.isEmpty)
		XCTAssertTrue(result.didChange)
	}

	func testFastPathShiftsTailRangesAfterDeletion() {
		let oldText = """
		a
		b
		c
		d
		e
		"""
		let newText = """
		a
		d
		e
		"""

		let result = SliceRebaseEngine.rebase(
			oldText: oldText,
			newText: newText,
			oldRanges: [LineRange(start: 4, end: 5)],
			anchors: nil
		)

		XCTAssertEqual(result.rebased, [LineRange(start: 2, end: 3)])
		XCTAssertTrue(result.dropped.isEmpty)
		XCTAssertTrue(result.didChange)
	}

	func testAnchorFallbackRebasesOverlapRangeWithInsertedLine() {
		let oldText = """
		header
		func start
		body
		tail
		"""
		let newText = """
		header
		func start
		inserted
		body
		tail
		"""
		let oldRanges = [LineRange(start: 2, end: 3)]
		let anchors = SliceRebaseEngine.buildAnchors(content: oldText, ranges: oldRanges)

		let result = SliceRebaseEngine.rebase(
			oldText: nil,
			newText: newText,
			oldRanges: oldRanges,
			anchors: anchors
		)

		XCTAssertEqual(result.rebased, [LineRange(start: 2, end: 4)])
		XCTAssertTrue(result.dropped.isEmpty)
		XCTAssertTrue(result.didChange)
	}

	func testGeneratedAnchorsFromOldTextRebaseOverlapRange() {
		let oldText = """
		header
		func start
		body
		tail
		"""
		let newText = """
		header
		func start
		inserted
		body
		tail
		"""

		let result = SliceRebaseEngine.rebase(
			oldText: oldText,
			newText: newText,
			oldRanges: [LineRange(start: 2, end: 3)],
			anchors: nil
		)

		XCTAssertEqual(result.rebased, [LineRange(start: 2, end: 4)])
		XCTAssertTrue(result.dropped.isEmpty)
		XCTAssertTrue(result.didChange)
	}

	func testAnchorFallbackUsesStartBoundaryWhenEndBoundaryIsMissing() {
		let oldText = """
		alpha
		needle start
		needle end
		omega
		"""
		let newText = """
		intro
		alpha
		needle start
		needle end
		omega
		"""
		let oldRange = LineRange(start: 2, end: 3)
		let anchors = SliceRebaseEngine
			.buildAnchors(content: oldText, ranges: [oldRange])
			.map { anchor in
				var mutable = anchor
				mutable.endSignature = []
				return mutable
			}

		let result = SliceRebaseEngine.rebase(
			oldText: nil,
			newText: newText,
			oldRanges: [oldRange],
			anchors: anchors
		)

		XCTAssertEqual(result.rebased, [LineRange(start: 3, end: 4)])
		XCTAssertTrue(result.dropped.isEmpty)
		XCTAssertTrue(result.didChange)
	}

	func testAnchorFallbackUsesEndBoundaryWhenStartBoundaryIsMissing() {
		let oldText = """
		alpha
		needle start
		needle end
		omega
		"""
		let newText = """
		intro
		alpha
		needle start
		needle end
		omega
		"""
		let oldRange = LineRange(start: 2, end: 3)
		let anchors = SliceRebaseEngine
			.buildAnchors(content: oldText, ranges: [oldRange])
			.map { anchor in
				var mutable = anchor
				mutable.startSignature = []
				return mutable
			}

		let result = SliceRebaseEngine.rebase(
			oldText: nil,
			newText: newText,
			oldRanges: [oldRange],
			anchors: anchors
		)

		XCTAssertEqual(result.rebased, [LineRange(start: 3, end: 4)])
		XCTAssertTrue(result.dropped.isEmpty)
		XCTAssertTrue(result.didChange)
	}

	func testMixedOutcomesRebaseKnownRangeAndDropUnknownRange() {
		let oldText = """
		header
		func start
		body
		tail
		"""
		let newText = """
		header
		func start
		inserted
		body
		tail
		"""
		let anchoredRange = LineRange(start: 2, end: 3)
		let unknownRange = LineRange(start: 8, end: 9)
		let anchors = SliceRebaseEngine.buildAnchors(content: oldText, ranges: [anchoredRange])

		let result = SliceRebaseEngine.rebase(
			oldText: nil,
			newText: newText,
			oldRanges: [anchoredRange, unknownRange],
			anchors: anchors
		)

		XCTAssertEqual(result.rebased, [LineRange(start: 2, end: 4)])
		XCTAssertEqual(result.dropped, [unknownRange])
		XCTAssertTrue(result.didChange)
	}

	func testBuildAnchorsClampsOutOfBoundsRanges() {
		let content = """
		one
		two
		three
		"""
		let anchors = SliceRebaseEngine.buildAnchors(
			content: content,
			ranges: [
				LineRange(start: 1, end: 1),
				LineRange(start: 99, end: 120)
			]
		)

		XCTAssertEqual(anchors.map(\.range), [LineRange(start: 1, end: 1), LineRange(start: 3, end: 3)])
		XCTAssertEqual(anchors.count, 2)
	}

	func testRangeDropsWhenNewTextIsEmpty() {
		let result = SliceRebaseEngine.rebase(
			oldText: "a\nb\nc\n",
			newText: "",
			oldRanges: [LineRange(start: 2, end: 3)],
			anchors: nil
		)

		XCTAssertTrue(result.rebased.isEmpty)
		XCTAssertEqual(result.dropped, [LineRange(start: 2, end: 3)])
		XCTAssertTrue(result.didChange)
	}

	// MARK: - P0 regression: oldText == newText must not block anchor-based remapping

	/// Models the exact failure mode where the content cache is refreshed before the
	/// debounced rebase runs, causing `oldText` to be the same as `newText`.
	/// Without the fix, the fast path produces delta=0 and early-returns, so the
	/// reported line numbers never move even though anchors could correctly shift them.
	func testAnchorsCorrectRangesWhenOldTextEqualsNewText() {
		let oldTextReal = """
		header
		func start() {
		body
		}
		footer
		"""
		let newText = """
		header
		import Foundation
		import UIKit
		func start() {
		body
		}
		footer
		"""
		let oldRanges = [LineRange(start: 2, end: 4)]
		let anchors = SliceRebaseEngine.buildAnchors(content: oldTextReal, ranges: oldRanges)

		// Simulate the bug: oldText is accidentally the *new* content
		let result = SliceRebaseEngine.rebase(
			oldText: newText,   // <-- stale cache overwrote old snapshot
			newText: newText,
			oldRanges: oldRanges,
			anchors: anchors
		)

		// Anchors should shift the range from 2–4 → 4–6
		XCTAssertEqual(result.rebased, [LineRange(start: 4, end: 6)])
		XCTAssertTrue(result.dropped.isEmpty)
		XCTAssertTrue(result.didChange)
	}

	/// When oldText == newText and there are NO anchors, ranges should be preserved
	/// (genuinely unchanged file) rather than dropped.
	func testNoChangeWhenOldTextEqualsNewTextWithoutAnchors() {
		let text = """
		a
		b
		c
		d
		"""

		let result = SliceRebaseEngine.rebase(
			oldText: text,
			newText: text,
			oldRanges: [LineRange(start: 2, end: 3)],
			anchors: nil
		)

		XCTAssertEqual(result.rebased, [LineRange(start: 2, end: 3)])
		XCTAssertTrue(result.dropped.isEmpty)
		XCTAssertFalse(result.didChange)
	}

	func testRangeDropsWhenNoOldTextOrAnchors() {
		let result = SliceRebaseEngine.rebase(
			oldText: nil,
			newText: "x\ny\nz\n",
			oldRanges: [LineRange(start: 10, end: 12)],
			anchors: nil
		)

		XCTAssertTrue(result.rebased.isEmpty)
		XCTAssertEqual(result.dropped, [LineRange(start: 10, end: 12)])
		XCTAssertTrue(result.didChange)
	}
}
