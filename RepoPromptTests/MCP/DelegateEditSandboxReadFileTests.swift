import XCTest
import MCP
@testable import RepoPrompt

final class DelegateEditSandboxReadFileTests: XCTestCase {
	private let testFilePath = "test.swift"
	private let defaultContent = "line1\nline2\nline3\n"

	private func makeSandbox(content: String? = nil) -> DelegateEditSandbox {
		DelegateEditSandbox(allowedPath: testFilePath, original: content ?? defaultContent)
	}

	func testReadFileStartLineZeroFails() async {
		let sandbox = makeSandbox()
		let args: [String: MCP.Value] = [
			"start_line": .int(0)
		]

		let result = await sandbox.callReadFile(args: args)
		XCTAssertTrue(result.isError ?? false)
		let text = CallToolResultJSON.textBody(result)
		XCTAssertTrue(text?.contains("start_line must be positive") == true)
	}

	func testReadFileNegativeStartLineWithLimitFails() async {
		let sandbox = makeSandbox()
		let args: [String: MCP.Value] = [
			"start_line": .int(-2),
			"limit": .int(1)
		]

		let result = await sandbox.callReadFile(args: args)
		XCTAssertTrue(result.isError ?? false)
		let text = CallToolResultJSON.textBody(result)
		XCTAssertTrue(text?.contains("limit parameter is not allowed") == true)
	}

	func testReadFileNegativeStartLineReturnsLastNLines() async {
		let sandbox = makeSandbox()
		let args: [String: MCP.Value] = [
			"start_line": .int(-2)
		]

		let result = await sandbox.callReadFile(args: args)
		XCTAssertFalse(result.isError ?? false)
		let dto = CallToolResultJSON.decode(ToolResultDTOs.ReadFileReply.self, from: result)
		XCTAssertNotNil(dto)
		XCTAssertEqual(dto?.totalLines, 3)
		XCTAssertEqual(dto?.firstLine, 2)
		XCTAssertEqual(dto?.lastLine, 3)
		XCTAssertEqual(dto?.content, "line2\nline3\n")
	}

	func testReadFileStartLineBeyondEOFReturnsEmptyWithMessage() async {
		let sandbox = makeSandbox()
		let args: [String: MCP.Value] = [
			"start_line": .int(10)
		]

		let result = await sandbox.callReadFile(args: args)
		XCTAssertFalse(result.isError ?? false)
		let dto = CallToolResultJSON.decode(ToolResultDTOs.ReadFileReply.self, from: result)
		XCTAssertNotNil(dto)
		XCTAssertEqual(dto?.content, "")
		XCTAssertEqual(dto?.totalLines, 3)
		XCTAssertEqual(dto?.firstLine, 10)
		XCTAssertEqual(dto?.lastLine, 3)
		XCTAssertTrue(dto?.message?.contains("Requested start_line exceeds file length") == true)
	}

	func testReadFileRepeatedReadsReturnIdenticalResults() async {
		let sandbox = makeSandbox(content: "alpha\r\nbeta\ngamma")
		let args: [String: MCP.Value] = [
			"start_line": .int(1),
			"limit": .int(2)
		]

		let first = await sandbox.callReadFile(args: args)
		let second = await sandbox.callReadFile(args: args)

		XCTAssertFalse(first.isError ?? false)
		XCTAssertFalse(second.isError ?? false)
		let firstDTO = CallToolResultJSON.decode(ToolResultDTOs.ReadFileReply.self, from: first)
		let secondDTO = CallToolResultJSON.decode(ToolResultDTOs.ReadFileReply.self, from: second)
		XCTAssertEqual(firstDTO?.content, "alpha\r\nbeta\n")
		XCTAssertEqual(firstDTO?.content, secondDTO?.content)
		XCTAssertEqual(firstDTO?.firstLine, secondDTO?.firstLine)
		XCTAssertEqual(firstDTO?.lastLine, secondDTO?.lastLine)
		XCTAssertEqual(firstDTO?.totalLines, secondDTO?.totalLines)
	}

	func testReadFileCacheInvalidatesAfterEdit() async {
		let sandbox = makeSandbox()
		let initial = await sandbox.callReadFile(args: ["start_line": .int(2), "limit": .int(1)])
		let initialDTO = CallToolResultJSON.decode(ToolResultDTOs.ReadFileReply.self, from: initial)
		XCTAssertEqual(initialDTO?.content, "line2\n")

		let edit = await sandbox.callApplyEdits(args: [
			"path": .string(testFilePath),
			"search": .string("line2"),
			"replace": .string("updated")
		])
		XCTAssertFalse(edit.isError ?? false)

		let updated = await sandbox.callReadFile(args: ["start_line": .int(2), "limit": .int(1)])
		let updatedDTO = CallToolResultJSON.decode(ToolResultDTOs.ReadFileReply.self, from: updated)
		XCTAssertEqual(updatedDTO?.content, "updated\n")
		XCTAssertFalse(updatedDTO?.content.contains("line2") == true)
	}
}
