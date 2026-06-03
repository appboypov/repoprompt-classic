import XCTest
@testable import RepoPrompt

final class AgentAssistantLineDerivationTests: XCTestCase {
	func testPreviewSummaryMatchesComponentsNewlineSemantics() {
		let inputs = [
			"",
			"single line",
			"first\nsecond\nthird",
			"first\n",
			"first\n\nthird",
			"first\r\nsecond",
			"first\rsecond\nthird",
			"first\u{2028}second\u{2029}third",
			"emoji 👩‍💻\ncombining e\u{301}\nlast"
		]
		let limits = [0, 1, 2, 10]

		for input in inputs {
			for limit in limits {
				let components = input.components(separatedBy: .newlines)
				let summary = AgentAssistantLineDerivation.previewSummary(
					for: input,
					previewLineCount: limit
				)

				XCTAssertEqual(summary.lineCount, components.count, "line count for \(String(reflecting: input)) limit \(limit)")
				XCTAssertEqual(summary.previewText, components.prefix(limit).joined(separator: "\n"), "preview for \(String(reflecting: input)) limit \(limit)")
				XCTAssertEqual(summary.displayedLineCount, min(components.count, limit), "displayed count for \(String(reflecting: input)) limit \(limit)")
				XCTAssertEqual(summary.remainingLineCount, max(0, components.count - limit), "remaining count for \(String(reflecting: input)) limit \(limit)")
				XCTAssertEqual(summary.needsCollapse, components.count > limit, "collapse decision for \(String(reflecting: input)) limit \(limit)")
			}
		}
	}

	func testBoundedLineCountStopsAfterLimit() {
		let twelveLines = (1...12).map { "line \($0)" }.joined(separator: "\n")
		let bounded = AgentAssistantLineDerivation.lineCount(upTo: 10, in: twelveLines)
		XCTAssertEqual(bounded.count, 11)
		XCTAssertFalse(bounded.isExact)
	}

	func testBoundedLineCountReportsExactWhenWithinLimit() {
		let threeLines = "one\ntwo\nthree"
		let bounded = AgentAssistantLineDerivation.lineCount(upTo: 10, in: threeLines)
		XCTAssertEqual(bounded.count, 3)
		XCTAssertTrue(bounded.isExact)
	}
}
