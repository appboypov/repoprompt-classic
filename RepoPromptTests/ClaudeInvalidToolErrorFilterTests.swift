import XCTest
@testable import RepoPrompt

final class ClaudeInvalidToolErrorFilterTests: XCTestCase {
	func testDetectsNoSuchToolAvailableWithExplicitIsError() {
		let text = "<tool_use_error>Error: No such tool available: mcp__RepoPrompt</tool_use_error>"
		XCTAssertTrue(
			ClaudeInvalidToolErrorFilter.isNoSuchToolAvailableError(
				resultText: text,
				isError: true
			)
		)
	}

	func testDetectsNoSuchToolAvailableWhenIsErrorIsNil() {
		// Translator sets `toolIsError` to nil for RepoPrompt-classified names to defer
		// status to the tracker. The filter should still match so the placeholder row
		// gets dropped.
		let text = "<tool_use_error>Error: No such tool available: mcp__RepoPrompt__not_a_real_tool</tool_use_error>"
		XCTAssertTrue(
			ClaudeInvalidToolErrorFilter.isNoSuchToolAvailableError(
				resultText: text,
				isError: nil
			)
		)
	}

	func testCaseInsensitiveMatch() {
		let text = "<TOOL_USE_ERROR>Error: NO SUCH TOOL AVAILABLE: something</TOOL_USE_ERROR>"
		XCTAssertTrue(
			ClaudeInvalidToolErrorFilter.isNoSuchToolAvailableError(
				resultText: text,
				isError: true
			)
		)
	}

	func testIgnoresWhenIsErrorIsExplicitlyFalse() {
		// Defense-in-depth: if upstream flipped the flag, don't suppress.
		let text = "<tool_use_error>Error: No such tool available: foo</tool_use_error>"
		XCTAssertFalse(
			ClaudeInvalidToolErrorFilter.isNoSuchToolAvailableError(
				resultText: text,
				isError: false
			)
		)
	}

	func testIgnoresUnrelatedErrorPayloads() {
		let text = "<tool_use_error>Error: Command failed: bad flag</tool_use_error>"
		XCTAssertFalse(
			ClaudeInvalidToolErrorFilter.isNoSuchToolAvailableError(
				resultText: text,
				isError: true
			)
		)
	}

	func testIgnoresPlainTextWithoutWrapperTag() {
		let text = "No such tool available: foo"
		XCTAssertFalse(
			ClaudeInvalidToolErrorFilter.isNoSuchToolAvailableError(
				resultText: text,
				isError: true
			)
		)
	}

	func testIgnoresEmptyOrNilInput() {
		XCTAssertFalse(
			ClaudeInvalidToolErrorFilter.isNoSuchToolAvailableError(
				resultText: nil,
				isError: true
			)
		)
		XCTAssertFalse(
			ClaudeInvalidToolErrorFilter.isNoSuchToolAvailableError(
				resultText: "",
				isError: true
			)
		)
		XCTAssertFalse(
			ClaudeInvalidToolErrorFilter.isNoSuchToolAvailableError(
				resultText: "   \n  ",
				isError: true
			)
		)
	}
}
