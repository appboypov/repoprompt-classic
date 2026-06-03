import XCTest
@testable import RepoPrompt

final class MarkdownFileLinkInteractionTests: XCTestCase {
	func testParsesRelativePathWithLineFragment() {
		let target = MarkdownFileLinkTarget.parse(rawDestination: "Services/AI/SystemPromptService.swift#L42")

		XCTAssertEqual(target?.normalizedPath, "Services/AI/SystemPromptService.swift")
		XCTAssertEqual(target?.lineNumber, 42)
	}

	func testParsesFileURLAndDecodesPath() {
		let target = MarkdownFileLinkTarget.parse(rawDestination: "file:///tmp/My%20File.swift#L8")

		XCTAssertEqual(target?.normalizedPath, "/tmp/My File.swift")
		XCTAssertEqual(target?.lineNumber, 8)
	}

	func testParsesColonSuffixedFileReference() {
		let target = MarkdownFileLinkTarget.parse(rawDestination: "SystemPromptService.swift:27:3")

		XCTAssertEqual(target?.normalizedPath, "SystemPromptService.swift")
		XCTAssertEqual(target?.lineNumber, 27)
	}

	func testRejectsExternalLinks() {
		XCTAssertNil(MarkdownFileLinkTarget.parse(rawDestination: "https://example.com/file.swift#L10"))
		XCTAssertNil(MarkdownFileLinkTarget.parse(rawDestination: "mailto:test@example.com"))
	}
}
