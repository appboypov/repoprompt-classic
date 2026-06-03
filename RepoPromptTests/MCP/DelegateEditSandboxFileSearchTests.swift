import XCTest
import MCP
@testable import RepoPrompt

final class DelegateEditSandboxFileSearchTests: XCTestCase {
	private let testFilePath = "test.swift"
	private let defaultContent = "Hello world\nConcatenate cat\ncat\n"

	private func makeSandbox(content: String? = nil) -> DelegateEditSandbox {
		DelegateEditSandbox(allowedPath: testFilePath, original: content ?? defaultContent)
	}

	func testFileSearchLiteralCaseInsensitiveDefault() async {
		let sandbox = makeSandbox()
		let args: [String: MCP.Value] = [
			"pattern": .string("hello")
		]

		let result = await sandbox.callFileSearch(args: args)
		XCTAssertFalse(result.isError ?? false)
		let dto = CallToolResultJSON.decode(ToolResultDTOs.SearchResultDTO.self, from: result)
		XCTAssertNotNil(dto)
		XCTAssertEqual(dto?.totalMatches, 1)
		XCTAssertEqual(dto?.contentMatches, 1)
	}

	func testFileSearchWholeWordUsesWordBoundaries() async {
		let sandbox = makeSandbox()
		let args: [String: MCP.Value] = [
			"pattern": .string("cat"),
			"whole_word": .bool(true)
		]

		let result = await sandbox.callFileSearch(args: args)
		XCTAssertFalse(result.isError ?? false)
		let dto = CallToolResultJSON.decode(ToolResultDTOs.SearchResultDTO.self, from: result)
		XCTAssertNotNil(dto)
		XCTAssertEqual(dto?.totalMatches, 2)
	}

	func testFileSearchWholeWordLineNumbersAreOneBased() async {
		let sandbox = makeSandbox()
		let args: [String: MCP.Value] = [
			"pattern": .string("cat"),
			"whole_word": .bool(true)
		]

		let result = await sandbox.callFileSearch(args: args)
		XCTAssertFalse(result.isError ?? false)
		let dto = CallToolResultJSON.decode(ToolResultDTOs.SearchResultDTO.self, from: result)
		let lineNumbers = dto?.contentMatchGroups.first?.lines.map(\.lineNumber)
		XCTAssertEqual(lineNumbers, [2, 3])
	}

	func testFileSearchRegexEscapedParenthesesMatchLiteralParentheses() async {
		let sandbox = makeSandbox(content: "call(foo)\ncallfoo\n")
		let args: [String: MCP.Value] = [
			"pattern": .string(#"call\(foo\)"#),
			"regex": .bool(true)
		]

		let result = await sandbox.callFileSearch(args: args)
		XCTAssertFalse(result.isError ?? false)
		let dto = CallToolResultJSON.decode(ToolResultDTOs.SearchResultDTO.self, from: result)
		XCTAssertEqual(dto?.totalMatches, 1)
		XCTAssertEqual(dto?.contentMatchGroups.first?.lines.first?.lineNumber, 1)
		XCTAssertEqual(dto?.contentMatchGroups.first?.lines.first?.lineText, "call(foo)")
	}

	func testFileSearchRegexRepairsUnbalancedLiteralParenthesis() async {
		let sandbox = makeSandbox(content: "frame(minWidth: 42)\nframeMax\n")
		let args: [String: MCP.Value] = [
			"pattern": .string("frame(minWidth:"),
			"regex": .bool(true)
		]

		let result = await sandbox.callFileSearch(args: args)
		XCTAssertFalse(result.isError ?? false)
		let dto = CallToolResultJSON.decode(ToolResultDTOs.SearchResultDTO.self, from: result)
		XCTAssertEqual(dto?.totalMatches, 1)
		XCTAssertEqual(dto?.contentMatchGroups.first?.lines.first?.lineNumber, 1)
		XCTAssertEqual(dto?.contentMatchGroups.first?.lines.first?.lineText, "frame(minWidth: 42)")
	}

	func testFileSearchRegexInvalidReturnsErrorMessageInDTO() async {
		let sandbox = makeSandbox()
		let args: [String: MCP.Value] = [
			"pattern": .string("["),
			"regex": .bool(true)
		]

		let result = await sandbox.callFileSearch(args: args)
		XCTAssertFalse(result.isError ?? false)
		let dto = CallToolResultJSON.decode(ToolResultDTOs.SearchResultDTO.self, from: result)
		XCTAssertNotNil(dto)
		XCTAssertTrue(dto?.errorMessage?.lowercased().contains("invalid regex pattern") == true)
	}

	func testFileSearchRegexVariableLengthLookbehindReturnsActionableDTO() async {
		let sandbox = makeSandbox(content: "GetComponent\n// anything GetComponent\n")
		let args: [String: MCP.Value] = [
			"pattern": .string(#"(?<!\/\/.*)GetComponent"#),
			"regex": .bool(true)
		]

		let result = await sandbox.callFileSearch(args: args)
		XCTAssertFalse(result.isError ?? false)
		let dto = CallToolResultJSON.decode(ToolResultDTOs.SearchResultDTO.self, from: result)
		XCTAssertNotNil(dto)
		let error = dto?.errorMessage ?? ""
		XCTAssertTrue(error.contains("Variable-length lookbehinds are not supported"), error)
		XCTAssertFalse(error.contains("PCRE2"), error)
		XCTAssertFalse(error.contains("byte offset 0"), error)
		XCTAssertFalse(error.contains("(125)"), error)
		XCTAssertTrue(dto?.suggestion?.contains("fixed-width lookbehind") == true, dto?.suggestion ?? "nil")
		XCTAssertTrue(dto?.suggestion?.contains(#"(?m)^(?!.*\/\/).*GetComponent"#) == true, dto?.suggestion ?? "nil")
	}

	func testFileSearchRegexGenericCompileErrorHidesEngineDetails() async {
		let sandbox = makeSandbox()
		let result = await sandbox.callFileSearch(args: [
			"pattern": .string("["),
			"regex": .bool(true)
		])
		XCTAssertFalse(result.isError ?? false)
		let dto = CallToolResultJSON.decode(ToolResultDTOs.SearchResultDTO.self, from: result)
		let error = dto?.errorMessage ?? ""
		XCTAssertTrue(error.contains("A character class is missing its closing `]`."), error)
		XCTAssertFalse(error.contains("PCRE2"), error)
		XCTAssertFalse(error.contains("byte offset"), error)
	}

	func testFileSearchCountOnlyOmitsContentMatchGroups() async {
		let sandbox = makeSandbox()
		let args: [String: MCP.Value] = [
			"pattern": .string("cat"),
			"count_only": .bool(true)
		]

		let result = await sandbox.callFileSearch(args: args)
		XCTAssertFalse(result.isError ?? false)
		let dto = CallToolResultJSON.decode(ToolResultDTOs.SearchResultDTO.self, from: result)
		XCTAssertNotNil(dto)
		XCTAssertEqual(dto?.contentMatchGroups.count, 0)
	}

	func testFileSearchContextLinesIncluded() async {
		let sandbox = makeSandbox()
		let args: [String: MCP.Value] = [
			"pattern": .string("cat"),
			"context_lines": .int(1)
		]

		let result = await sandbox.callFileSearch(args: args)
		XCTAssertFalse(result.isError ?? false)
		let dto = CallToolResultJSON.decode(ToolResultDTOs.SearchResultDTO.self, from: result)
		XCTAssertNotNil(dto)
		let lines = dto?.contentMatchGroups.first?.lines ?? []
		let hasContext = lines.contains { line in
			(line.contextBefore?.isEmpty == false) || (line.contextAfter?.isEmpty == false)
		}
		XCTAssertTrue(hasContext)
	}

	func testFileSearchRepeatedRegexSearchesReturnIdenticalResults() async {
		let sandbox = makeSandbox(content: "cat\nconcatenate\ncategory\nCAT\n")
		let args: [String: MCP.Value] = [
			"pattern": .string("cat"),
			"regex": .bool(true),
			"whole_word": .bool(true),
			"case_insensitive": .bool(true)
		]

		let first = await sandbox.callFileSearch(args: args)
		let second = await sandbox.callFileSearch(args: args)

		XCTAssertFalse(first.isError ?? false)
		XCTAssertFalse(second.isError ?? false)
		let firstDTO = CallToolResultJSON.decode(ToolResultDTOs.SearchResultDTO.self, from: first)
		let secondDTO = CallToolResultJSON.decode(ToolResultDTOs.SearchResultDTO.self, from: second)
		XCTAssertEqual(firstDTO?.totalMatches, 2)
		XCTAssertEqual(firstDTO?.totalMatches, secondDTO?.totalMatches)
		XCTAssertEqual(firstDTO?.contentMatches, secondDTO?.contentMatches)
		XCTAssertEqual(
			firstDTO?.contentMatchGroups.first?.lines.map(\.lineNumber),
			secondDTO?.contentMatchGroups.first?.lines.map(\.lineNumber)
		)
		XCTAssertEqual(
			firstDTO?.contentMatchGroups.first?.lines.map(\.lineText),
			secondDTO?.contentMatchGroups.first?.lines.map(\.lineText)
		)
	}

	func testFileSearchCacheInvalidatesAfterEdit() async {
		let sandbox = makeSandbox(content: "cat\ncat\ndog\n")
		let args: [String: MCP.Value] = [
			"pattern": .string("cat"),
			"whole_word": .bool(true)
		]
		let before = await sandbox.callFileSearch(args: args)
		let beforeDTO = CallToolResultJSON.decode(ToolResultDTOs.SearchResultDTO.self, from: before)
		XCTAssertEqual(beforeDTO?.totalMatches, 2)

		let edit = await sandbox.callApplyEdits(args: [
			"path": .string(testFilePath),
			"search": .string("cat"),
			"replace": .string("bird"),
			"all": .bool(true)
		])
		XCTAssertFalse(edit.isError ?? false)

		let afterCat = await sandbox.callFileSearch(args: args)
		let afterCatDTO = CallToolResultJSON.decode(ToolResultDTOs.SearchResultDTO.self, from: afterCat)
		XCTAssertEqual(afterCatDTO?.totalMatches, 0)

		let afterBird = await sandbox.callFileSearch(args: [
			"pattern": .string("bird"),
			"whole_word": .bool(true)
		])
		let afterBirdDTO = CallToolResultJSON.decode(ToolResultDTOs.SearchResultDTO.self, from: afterBird)
		XCTAssertEqual(afterBirdDTO?.totalMatches, 2)
		XCTAssertEqual(afterBirdDTO?.contentMatchGroups.first?.lines.map(\.lineNumber), [1, 2])
	}
}
