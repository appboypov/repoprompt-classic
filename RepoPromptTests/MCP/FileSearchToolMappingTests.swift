import XCTest
@testable import RepoPrompt

final class FileSearchToolMappingTests: XCTestCase {
	func testVariableLengthLookbehindCompileErrorFormattingIsActionable() {
		let pattern = #"(?<!\/\/.*)GetComponent"#
		let failure = RepoPromptPCRE2Adapter.searchPatternError(
			from: PCRE2Error.compile(
				pattern: pattern,
				offset: 0,
				code: 125,
				message: "lookbehind assertion is not fixed length"
			),
			pattern: pattern
		)
		guard let searchError = failure as? SearchPatternError else {
			return XCTFail("Expected SearchPatternError, got \(type(of: failure))")
		}

		let parts = MCPServerViewModel.friendlySearchErrorParts(
			for: pattern,
			isRegex: true,
			error: searchError
		)

		XCTAssertTrue(parts.issue.contains("Variable-length lookbehinds are not supported"), parts.issue)
		XCTAssertTrue(parts.issue.contains("fixed or bounded length"), parts.issue)
		XCTAssertFalse(parts.issue.contains("PCRE2"), parts.issue)
		XCTAssertFalse(parts.issue.contains("byte offset 0"), parts.issue)
		XCTAssertFalse(parts.issue.contains("(125)"), parts.issue)
		XCTAssertTrue(parts.suggestion?.contains("fixed-width lookbehind") == true, parts.suggestion ?? "nil")
		XCTAssertTrue(parts.suggestion?.contains("line-level lookahead") == true, parts.suggestion ?? "nil")
		XCTAssertTrue(parts.suggestion?.contains(#"(?m)^(?!.*\/\/).*GetComponent"#) == true, parts.suggestion ?? "nil")
	}

	func testGenericCompileErrorFormattingHidesEngineDetails() {
		let failure = RepoPromptPCRE2Adapter.searchPatternError(
			from: PCRE2Error.compile(
				pattern: "[",
				offset: 1,
				code: 106,
				message: "missing terminating ] for character class"
			),
			pattern: "["
		)
		guard let searchError = failure as? SearchPatternError else {
			return XCTFail("Expected SearchPatternError, got \(type(of: failure))")
		}

		let parts = MCPServerViewModel.friendlySearchErrorParts(
			for: "[",
			isRegex: true,
			error: searchError
		)

		XCTAssertTrue(parts.issue.contains("A character class is missing its closing `]`."), parts.issue)
		XCTAssertFalse(parts.issue.contains("PCRE2"), parts.issue)
		XCTAssertFalse(parts.issue.contains("byte offset"), parts.issue)
		XCTAssertFalse(parts.issue.contains("(106)"), parts.issue)
	}

	func testSanitizeSearchScopeInputsPreservesRawSearchIntent() {
		let sanitized = MCPServerViewModel.sanitizeSearchScopeInputs([
			" /RepoPrompt/Views ",
			"/RepoPrompt/Views/*",
			"RepoPrompt/ViewModels",
			"RepoPrompt/ViewModels",
			"   "
		])
		XCTAssertEqual(
			sanitized,
			[
				"/RepoPrompt/Views",
				"/RepoPrompt/Views/*",
				"RepoPrompt/ViewModels"
			]
		)
	}
	
	func testPathFilterSuggestionDoesNotAppearForValidScopedMiss() {
		let suggestion = MCPServerViewModel.pathFilterSuggestion(
			hadPathFilter: true,
			scopedFileCount: 3
		)
		XCTAssertNil(suggestion)
	}

	func testPathFilterSuggestionAppearsForZeroCandidateScope() {
		let suggestion = MCPServerViewModel.pathFilterSuggestion(
			hadPathFilter: true,
			scopedFileCount: 0
		)
		XCTAssertEqual(
			suggestion,
			"The specified path filter resolved to no files in the current workspace. Use get_file_tree to inspect the project structure and confirm the path."
		)
	}
}
