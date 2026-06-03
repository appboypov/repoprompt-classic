import XCTest
import MCP
@testable import RepoPrompt

/// Comprehensive tests for all apply_edits repair mechanisms in DelegateEditSandbox
final class DelegateEditSandboxRepairTests: XCTestCase {

	// MARK: - Test Fixtures

	private let testFilePath = "test.swift"
	private let originalContent = """
	func greet() {
	\tprint("Hello")
	}

	func farewell() {
	\tprint("Goodbye")
	}
	"""

	// MARK: - Helper Methods

	private func makeSandbox() -> DelegateEditSandbox {
		return DelegateEditSandbox(allowedPath: testFilePath, original: originalContent)
	}

	private func makeStringValue(_ s: String) -> MCP.Value {
		return .string(s)
	}

	private func makeObjectValue(_ dict: [String: MCP.Value]) -> MCP.Value {
		return .object(dict)
	}

	private func makeBoolValue(_ b: Bool) -> MCP.Value {
		return .bool(b)
	}

	private func makeArrayValue(_ items: [MCP.Value]) -> MCP.Value {
		return .array(items)
	}

	private func assertSuccess(_ result: CallTool.Result, file: StaticString = #file, line: UInt = #line) {
		XCTAssertFalse(result.isError ?? false, "Expected success but got error", file: file, line: line)
	}

	private func assertError(_ result: CallTool.Result, file: StaticString = #file, line: UInt = #line) {
		XCTAssertTrue(result.isError ?? false, "Expected error but got success", file: file, line: line)
	}

	// MARK: - Valid Calls (Baseline)

	func testValidSingleSearchReplace() async throws {
		let sandbox = makeSandbox()
		let args: [String: MCP.Value] = [
			"search": makeStringValue("Hello"),
			"replace": makeStringValue("Hi"),
			"path": makeStringValue(testFilePath)
		]

		let result = await sandbox.callApplyEdits(args: args)
		assertSuccess(result)

		let content = await sandbox.currentContent()
		XCTAssertTrue(content.contains("Hi"))
		XCTAssertFalse(content.contains("Hello"))
	}

	func testValidBatchEdits() async throws {
		let sandbox = makeSandbox()
		let args: [String: MCP.Value] = [
			"edits": makeArrayValue([
				makeObjectValue([
					"search": makeStringValue("Hello"),
					"replace": makeStringValue("Hi")
				]),
				makeObjectValue([
					"search": makeStringValue("Goodbye"),
					"replace": makeStringValue("Bye")
				])
			]),
			"path": makeStringValue(testFilePath)
		]

		let result = await sandbox.callApplyEdits(args: args)
		assertSuccess(result)

		let content = await sandbox.currentContent()
		XCTAssertTrue(content.contains("Hi"))
		XCTAssertTrue(content.contains("Bye"))
		XCTAssertFalse(content.contains("Hello"))
		XCTAssertFalse(content.contains("Goodbye"))
	}

	func testValidRewrite() async throws {
		let sandbox = makeSandbox()
		let newContent = "// New content\nfunc test() {}"
		let args: [String: MCP.Value] = [
			"rewrite": makeStringValue(newContent),
			"path": makeStringValue(testFilePath)
		]

		let result = await sandbox.callApplyEdits(args: args)
		assertSuccess(result)

		let content = await sandbox.currentContent()
		XCTAssertEqual(content, newContent)
	}

	// MARK: - Output Contract

	func testApplyEditsEmitsPathCorrectionNote() async {
		let sandbox = makeSandbox()
		let args: [String: MCP.Value] = [
			"rewrite": makeStringValue("// New content\n"),
			"path": makeStringValue("wrong.swift")
		]

		let result = await sandbox.callApplyEdits(args: args)
		assertSuccess(result)

		let note = CallToolResultJSON.string("note", in: result)
		XCTAssertEqual(note, "Path corrected to '\(testFilePath)'.")
	}

	func testApplyEditsErrorFormatting() async {
		let sandbox = makeSandbox()
		let args: [String: MCP.Value] = [
			"rewrite": makeStringValue("content")
		]

		let result = await sandbox.callApplyEdits(args: args)
		assertError(result)
		let text = CallToolResultJSON.textBody(result)
		XCTAssertNotNil(text)
		XCTAssertTrue(text?.contains("\(DelegateEditToolNames.editFile):") == true)
	}

	// MARK: - Malformed Single Search/Replace (replacement key is code)

	func testMalformedSingleSearchReplace_CodeAsKey() async throws {
		let sandbox = makeSandbox()
		// Simulate the bug: replacement text becomes the key name
		let args: [String: MCP.Value] = [
			"search": makeStringValue("Hello"),
			"\tprint(\"Hi\")": makeStringValue("\tprint(\"Hi\")"),  // Malformed: code as key
			"path": makeStringValue(testFilePath)
		]

		let result = await sandbox.callApplyEdits(args: args)
		// Should succeed after repair
		assertSuccess(result)

		let content = await sandbox.currentContent()
		XCTAssertTrue(content.contains("Hi"))
	}

	func testMalformedSingleSearchReplace_MultilineCodeAsKey() async throws {
		let sandbox = makeSandbox()
		let replacementCode = """
		\tprint("Hi")
		\tprint("World")
		"""
		// Malformed: multiline code as key
		let args: [String: MCP.Value] = [
			"search": makeStringValue("Hello"),
			replacementCode: makeStringValue(replacementCode),
			"path": makeStringValue(testFilePath)
		]

		let result = await sandbox.callApplyEdits(args: args)
		assertSuccess(result)

		let content = await sandbox.currentContent()
		XCTAssertTrue(content.contains("Hi"))
		XCTAssertTrue(content.contains("World"))
	}

	// MARK: - Malformed Batch Edits

	func testMalformedBatchEdits_OneEditWithCodeAsKey() async throws {
		let sandbox = makeSandbox()
		let args: [String: MCP.Value] = [
			"edits": makeArrayValue([
				makeObjectValue([
					"search": makeStringValue("Hello"),
					"\tprint(\"Hi\")": makeStringValue("\tprint(\"Hi\")")  // Malformed
				])
			]),
			"path": makeStringValue(testFilePath)
		]

		let result = await sandbox.callApplyEdits(args: args)
		assertSuccess(result)

		let content = await sandbox.currentContent()
		XCTAssertTrue(content.contains("Hi"))
	}

	func testMalformedBatchEdits_MultipleEditsWithCodeAsKey() async throws {
		let sandbox = makeSandbox()
		let args: [String: MCP.Value] = [
			"edits": makeArrayValue([
				makeObjectValue([
					"search": makeStringValue("Hello"),
					"\tprint(\"Hi\")": makeStringValue("\tprint(\"Hi\")")  // Malformed
				]),
				makeObjectValue([
					"search": makeStringValue("Goodbye"),
					"func bye()": makeStringValue("func bye()")  // Malformed
				])
			]),
			"path": makeStringValue(testFilePath)
		]

		let result = await sandbox.callApplyEdits(args: args)
		assertSuccess(result)

		let content = await sandbox.currentContent()
		XCTAssertTrue(content.contains("Hi"))
		XCTAssertTrue(content.contains("bye"))
	}

	func testMalformedBatchEdits_MixedValidAndMalformed() async throws {
		let sandbox = makeSandbox()
		let args: [String: MCP.Value] = [
			"edits": makeArrayValue([
				makeObjectValue([
					"search": makeStringValue("Hello"),
					"replace": makeStringValue("Hi")  // Valid
				]),
				makeObjectValue([
					"search": makeStringValue("Goodbye"),
					"func bye()": makeStringValue("func bye()")  // Malformed
				])
			]),
			"path": makeStringValue(testFilePath)
		]

		let result = await sandbox.callApplyEdits(args: args)
		assertSuccess(result)

		let content = await sandbox.currentContent()
		XCTAssertTrue(content.contains("Hi"))
		XCTAssertTrue(content.contains("bye"))
	}

	// MARK: - Alternative replacement key names (with, content)

	func testValidAlternativeKey_With() async throws {
		let sandbox = makeSandbox()
		let args: [String: MCP.Value] = [
			"search": makeStringValue("Hello"),
			"with": makeStringValue("Hi"),  // Alternative key
			"path": makeStringValue(testFilePath)
		]

		let result = await sandbox.callApplyEdits(args: args)
		assertSuccess(result)

		let content = await sandbox.currentContent()
		XCTAssertTrue(content.contains("Hi"))
	}

	func testValidAlternativeKey_Content() async throws {
		let sandbox = makeSandbox()
		let args: [String: MCP.Value] = [
			"search": makeStringValue("Hello"),
			"content": makeStringValue("Hi"),  // Alternative key
			"path": makeStringValue(testFilePath)
		]

		let result = await sandbox.callApplyEdits(args: args)
		assertSuccess(result)

		let content = await sandbox.currentContent()
		XCTAssertTrue(content.contains("Hi"))
	}

	// MARK: - Edge Cases

	func testMalformedWithAllFlag() async throws {
		let sandbox = makeSandbox()
		// Test that the repair works even when 'all' flag is present
		let args: [String: MCP.Value] = [
			"search": makeStringValue("print"),
			"\tprintln": makeStringValue("\tprintln"),  // Malformed
			"all": makeBoolValue(true),
			"path": makeStringValue(testFilePath)
		]

		let result = await sandbox.callApplyEdits(args: args)
		assertSuccess(result)

		let content = await sandbox.currentContent()
		XCTAssertTrue(content.contains("println"))
		XCTAssertFalse(content.contains("print("))  // All instances replaced
	}

	func testMalformedWithVerboseFlag() async throws {
		let sandbox = makeSandbox()
		let args: [String: MCP.Value] = [
			"search": makeStringValue("Hello"),
			"\tprint(\"Hi\")": makeStringValue("\tprint(\"Hi\")"),  // Malformed
			"verbose": makeBoolValue(true),
			"path": makeStringValue(testFilePath)
		]

		let result = await sandbox.callApplyEdits(args: args)
		assertSuccess(result)

		// Verbose should include a diff
		let body = CallToolResultJSON.object(result)
		XCTAssertNotNil(body?["diff"])
	}

	func testMalformedKeyWithColonsAndSlashes() async throws {
		let sandbox = makeSandbox()
		// Test detection of code-like characters: :, /, \, etc.
		let args: [String: MCP.Value] = [
			"search": makeStringValue("Hello"),
			"some/path/to:file": makeStringValue("Hi"),  // Has code-like chars
			"path": makeStringValue(testFilePath)
		]

		let result = await sandbox.callApplyEdits(args: args)
		assertSuccess(result)

		let content = await sandbox.currentContent()
		XCTAssertTrue(content.contains("Hi"))
	}

	func testMalformedKeyWithQuotes() async throws {
		let sandbox = makeSandbox()
		let args: [String: MCP.Value] = [
			"search": makeStringValue("Hello"),
			"\"quoted string\"": makeStringValue("Hi"),  // Has quotes
			"path": makeStringValue(testFilePath)
		]

		let result = await sandbox.callApplyEdits(args: args)
		assertSuccess(result)

		let content = await sandbox.currentContent()
		XCTAssertTrue(content.contains("Hi"))
	}

	// MARK: - Cases That Should NOT Be Repaired

	func testNoRepairWhenMultipleOrphanKeys() async throws {
		let sandbox = makeSandbox()
		// When there are multiple unknown keys, we shouldn't guess
		let args: [String: MCP.Value] = [
			"search": makeStringValue("Hello"),
			"unknown1": makeStringValue("value1"),
			"unknown2": makeStringValue("value2"),
			"path": makeStringValue(testFilePath)
		]

		let result = await sandbox.callApplyEdits(args: args)
		// Should fail - no valid replacement found
		assertError(result)
	}

	func testNoRepairWhenOrphanKeyLooksNormal() async throws {
		let sandbox = makeSandbox()
		// If the orphan key looks like a normal identifier (no special chars),
		// we shouldn't repair it
		let args: [String: MCP.Value] = [
			"search": makeStringValue("Hello"),
			"normalkey": makeStringValue("Hi"),  // No special chars
			"path": makeStringValue(testFilePath)
		]

		let result = await sandbox.callApplyEdits(args: args)
		// Should fail - repair shouldn't trigger for normal-looking keys
		assertError(result)
	}

	// MARK: - Real-World Failure Cases from Chat

	func testRealWorldFailureCase1() async throws {
		// From the chat: search followed by code snippet as key
		let sandbox = makeSandbox()
		let malformedKey = """
		\t@ViewBuilder
		\tprivate func modelPickerPopover() -> some View {
		\t\tVStack(alignment: .leading, spacing: 8) {
		\t\t\tText("Select Model")
		\t\t}
		\t}
		"""
		let args: [String: MCP.Value] = [
			"search": makeStringValue("func greet()"),
			malformedKey: makeStringValue(malformedKey),
			"path": makeStringValue(testFilePath)
		]

		let result = await sandbox.callApplyEdits(args: args)
		assertSuccess(result)

		let content = await sandbox.currentContent()
		XCTAssertTrue(content.contains("modelPickerPopover"))
	}

	func testRealWorldFailureCase2_InBatchEdits() async throws {
		// Similar to real failure but in batch edits
		let sandbox = makeSandbox()
		let malformedKey = """
		\tprivate func truncateHeadIfNeeded(_ text: String) -> String {
		\t\tlet maxModelNameLength = self.maxModelNameLength
		\t}
		"""
		let args: [String: MCP.Value] = [
			"edits": makeArrayValue([
				makeObjectValue([
					"search": makeStringValue("func greet()"),
					malformedKey: makeStringValue(malformedKey)
				])
			]),
			"path": makeStringValue(testFilePath)
		]

		let result = await sandbox.callApplyEdits(args: args)
		assertSuccess(result)

		let content = await sandbox.currentContent()
		XCTAssertTrue(content.contains("truncateHeadIfNeeded"))
	}

	// MARK: - Empty and Missing Cases

	func testEmptyReplacementShouldWork() async throws {
		let sandbox = makeSandbox()
		let args: [String: MCP.Value] = [
			"search": makeStringValue("Hello"),
			"replace": makeStringValue(""),  // Empty replacement (delete)
			"path": makeStringValue(testFilePath)
		]

		let result = await sandbox.callApplyEdits(args: args)
		assertSuccess(result)

		let content = await sandbox.currentContent()
		XCTAssertFalse(content.contains("Hello"))
	}

	func testMissingSearchShouldFail() async throws {
		let sandbox = makeSandbox()
		let args: [String: MCP.Value] = [
			"replace": makeStringValue("Hi"),
			"path": makeStringValue(testFilePath)
		]

		let result = await sandbox.callApplyEdits(args: args)
		assertError(result)
	}

	// MARK: - Performance Test

	func testRepairPerformanceWithLargeBatch() async throws {
		let sandbox = makeSandbox()

		// Create 100 malformed edits
		var edits: [MCP.Value] = []
		for i in 0..<100 {
			edits.append(makeObjectValue([
				"search": makeStringValue("print"),
				"\tlog_\(i)()": makeStringValue("\tlog_\(i)()")  // Malformed
			]))
		}

		let args: [String: MCP.Value] = [
			"edits": makeArrayValue(edits),
			"path": makeStringValue(testFilePath)
		]

		let start = Date()
		let result = await sandbox.callApplyEdits(args: args)
		let elapsed = Date().timeIntervalSince(start)

		// Should complete in reasonable time (< 5 seconds for 100 edits)
		XCTAssertLessThan(elapsed, 5.0)

		// Note: This might fail due to ambiguity, but should still complete quickly
		// We're mainly testing that the repair logic doesn't cause performance issues
	}
}
