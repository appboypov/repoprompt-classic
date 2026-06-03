import XCTest
@testable import RepoPrompt

@MainActor
final class CodeStructureBudgetingTests: XCTestCase {
	func testApplyCodeStructureOutputBudgetUsesCountCapOnly() {
		let selection = MCPServerViewModel.applyCodeStructureOutputBudget(
			[
				.init(key: "a", estimatedTokens: 100),
				.init(key: "b", estimatedTokens: 100),
				.init(key: "c", estimatedTokens: 100),
				.init(key: "d", estimatedTokens: 100)
			],
			maxResults: 2,
			tokenBudget: 1_000,
			separatorTokens: 5
		)

		XCTAssertEqual(selection.includedKeys, ["a", "b"])
		XCTAssertEqual(selection.omittedByMaxResults, 2)
		XCTAssertEqual(selection.omittedByTokenBudget, 0)
		XCTAssertEqual(selection.omittedTotal, 2)
	}

	func testApplyCodeStructureOutputBudgetUsesTokenCapOnly() {
		let selection = MCPServerViewModel.applyCodeStructureOutputBudget(
			[
				.init(key: "a", estimatedTokens: 200),
				.init(key: "b", estimatedTokens: 200),
				.init(key: "c", estimatedTokens: 200)
			],
			maxResults: 10,
			tokenBudget: 609,
			separatorTokens: 5
		)

		XCTAssertEqual(selection.includedKeys, ["a", "b"])
		XCTAssertEqual(selection.omittedByMaxResults, 0)
		XCTAssertEqual(selection.omittedByTokenBudget, 1)
		XCTAssertEqual(selection.omittedTotal, 1)
	}

	func testApplyCodeStructureOutputBudgetTracksBothOmissionTypes() {
		let selection = MCPServerViewModel.applyCodeStructureOutputBudget(
			[
				.init(key: "a", estimatedTokens: 240),
				.init(key: "b", estimatedTokens: 240),
				.init(key: "c", estimatedTokens: 240),
				.init(key: "d", estimatedTokens: 240)
			],
			maxResults: 3,
			tokenBudget: 490,
			separatorTokens: 5
		)

		XCTAssertEqual(selection.includedKeys, ["a", "b"])
		XCTAssertEqual(selection.omittedByMaxResults, 1)
		XCTAssertEqual(selection.omittedByTokenBudget, 1)
		XCTAssertEqual(selection.omittedTotal, 2)
	}

	func testApplyCodeStructureOutputBudgetHandlesZeroMaxResults() {
		let selection = MCPServerViewModel.applyCodeStructureOutputBudget(
			[
				.init(key: "a", estimatedTokens: 100),
				.init(key: "b", estimatedTokens: 100)
			],
			maxResults: 0,
			tokenBudget: 1_000,
			separatorTokens: 5
		)

		XCTAssertTrue(selection.includedKeys.isEmpty)
		XCTAssertEqual(selection.omittedByMaxResults, 2)
		XCTAssertEqual(selection.omittedByTokenBudget, 0)
	}

	func testApplyCodeStructureOutputBudgetIncludesSingleOversizedFile() {
		let selection = MCPServerViewModel.applyCodeStructureOutputBudget(
			[
				.init(key: "a", estimatedTokens: 700),
				.init(key: "b", estimatedTokens: 100)
			],
			maxResults: 2,
			tokenBudget: 600,
			separatorTokens: 5
		)

		XCTAssertEqual(selection.includedKeys, ["a"])
		XCTAssertEqual(selection.omittedByMaxResults, 0)
		XCTAssertEqual(selection.omittedByTokenBudget, 1)
		XCTAssertEqual(selection.omittedTotal, 1)
	}
}
