import XCTest
@testable import RepoPrompt

final class CommandExecutionOutputSanitizerTests: XCTestCase {
	func testSanitizeStripsANSIControlSequencesFromInteractivePromptOutput() {
		let esc = "\u{001B}"
		let raw = "\(esc)[2J\(esc)[3J\(esc)[H\(esc)[?25l\(esc)[2K\(esc)[1G\(esc)[36m?\(esc)[39m Something is already running on port 3000.\nWould you like to run the app on another port instead?\(esc)[22m \(esc)[90m›\(esc)[39m \(esc)[90m(Y/n)\(esc)[39m"

		let sanitized = CommandExecutionOutputSanitizer.sanitize(raw)

		XCTAssertFalse(sanitized.contains("\u{001B}"))
		XCTAssertTrue(sanitized.contains("Something is already running on port 3000."))
		XCTAssertTrue(sanitized.contains("Would you like to run the app on another port instead?"))
		XCTAssertTrue(sanitized.contains("(Y/n)"))
	}

	func testSanitizeAppliesCarriageReturnOverwriteSemantics() {
		let raw = "starting\u{000D}loading\u{000D}done\nnext\u{000D}overwritten"

		let sanitized = CommandExecutionOutputSanitizer.sanitize(raw)

		XCTAssertEqual(sanitized, "done\noverwritten")
	}

	func testSanitizeAppliesBackspaceEdits() {
		let raw = "abc\u{0008}\u{0008}Z"

		let sanitized = CommandExecutionOutputSanitizer.sanitize(raw)

		XCTAssertEqual(sanitized, "aZ")
	}

	func testSanitizeLeavesCleanTextUnchanged() {
		let raw = "line one\nline two\tok"

		let sanitized = CommandExecutionOutputSanitizer.sanitize(raw)

		XCTAssertEqual(sanitized, raw)
	}
}
