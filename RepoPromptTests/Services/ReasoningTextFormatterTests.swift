import XCTest
@_spi(TestSupport) @testable import RepoPrompt

final class ReasoningTextFormatterTests: XCTestCase {
	func testNormalizeSeparatesAdjacentBoldSummaryHeaders() {
		let raw = "**Analyzing skill invocation architecture****Planning**"

		XCTAssertEqual(
			ReasoningTextFormatter.normalize(raw),
			"**Analyzing skill invocation architecture**\n\n**Planning**"
		)
	}

	func testNormalizeLeavesLiteralAsteriskRunsUntouched() {
		let raw = "Use **** as a literal marker inside the reasoning body."

		XCTAssertEqual(ReasoningTextFormatter.normalize(raw), raw)
	}

	func testEagerReasoningSummaryFlushIsLimitedToCodexAndBuiltInOpenAIResponsesModels() {
		XCTAssertTrue(AIQueriesService.shouldEagerlyFlushReasoningSummaries(for: .codexCliGpt5Medium))
		XCTAssertTrue(AIQueriesService.shouldEagerlyFlushReasoningSummaries(for: .gpt5))
		XCTAssertFalse(AIQueriesService.shouldEagerlyFlushReasoningSummaries(for: .openaiCustom(name: "gpt-5")))
		XCTAssertFalse(AIQueriesService.shouldEagerlyFlushReasoningSummaries(for: .gpt41))
	}
}
