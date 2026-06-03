import Foundation
import MCP
import XCTest
@testable import RepoPrompt

final class ToolOutputFormatterCodeStructureTests: XCTestCase {
	func testFormatCodeStructureMentionsMaxResultsForCountOnlyOmission() throws {
		let text = try formattedText(
			from: ToolResultDTOs.SelectedCodeStructureDTO(
				fileCount: 2,
				content: "File: Root/A.swift\nImports:\n---\n---\n",
				omittedCount: 3,
				omittedTotal: 3
			)
		)

		XCTAssertTrue(text.contains("increase `max_results` to inspect more files"))
		XCTAssertFalse(text.contains("~6k-token response cap"))
	}

	func testFormatCodeStructureMentionsTokenBudgetCap() throws {
		let text = try formattedText(
			from: ToolResultDTOs.SelectedCodeStructureDTO(
				fileCount: 1,
				content: "File: Root/A.swift\nImports:\n---\n---\n",
				omittedTotal: 2,
				tokenBudgetOmittedCount: 2,
				tokenBudgetHit: true
			)
		)

		XCTAssertTrue(text.contains("response capped near 6k tokens"))
		XCTAssertFalse(text.contains("increase `max_results` to inspect more files"))
	}

	func testFormatCodeStructureSeparatesMaxResultsAndTokenBudgetReasons() throws {
		let text = try formattedText(
			from: ToolResultDTOs.SelectedCodeStructureDTO(
				fileCount: 2,
				content: "File: Root/A.swift\nImports:\n---\n---\n",
				omittedCount: 3,
				omittedTotal: 5,
				tokenBudgetOmittedCount: 2,
				tokenBudgetHit: true
			)
		)

		XCTAssertTrue(text.contains("3 beyond `max_results`, 2 beyond the ~6k-token response cap"))
		XCTAssertTrue(text.contains("Increase `max_results` to consider more files, or narrow `paths`"))
	}

	private func formattedText(from dto: ToolResultDTOs.SelectedCodeStructureDTO) throws -> String {
		let data = try JSONEncoder().encode(dto)
		let json = try XCTUnwrap(String(data: data, encoding: .utf8))
		let value = try XCTUnwrap(Value.fromJSONString(json))
		let blocks = ToolOutputFormatter.formatCodeStructure(value: value)

		guard let first = blocks.first, case .text(let text, _, _) = first else {
			throw NSError(domain: "ToolOutputFormatterCodeStructureTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected a text content block"])
		}

		return text
	}
}
