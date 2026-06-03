import XCTest
@testable import RepoPrompt

final class AgentModeModelLabelTruncationTests: XCTestCase {
	func testTruncateModelNameLeavesShortNamesUntouched() {
		XCTAssertEqual(String.truncateModelName("GPT-5"), "GPT-5")
	}

	func testTruncateModelNamePrefersSuffixAfterSlash() {
		let raw = "openai/gpt-5-codex"
		XCTAssertEqual(String.truncateModelName(raw, maxLength: 12), "gpt-5-codex")
	}

	func testTruncateModelNameFallsBackToHeadTruncation() {
		let raw = "12345678901234567890"
		XCTAssertEqual(String.truncateModelName(raw, maxLength: 8), "…34567890")
	}
}
