import XCTest
import MCP
@testable import RepoPrompt

/// Integration tests that verify the complete repair pipeline:
/// 1. MCPConnectionManager sanitization (tool-name unwrapping)
/// 2. DelegateEditSandbox repair (malformed replacement keys)
final class MCPRepairIntegrationTests: XCTestCase {

	// MARK: - Test Fixtures

	private let testFilePath = "integration_test.swift"
	private let originalContent = """
	class TestClass {
		func someMethod() {
			print("hello")
		}
	}
	"""

	// MARK: - Helper Methods

	private func makeSandbox() -> DelegateEditSandbox {
		return DelegateEditSandbox(allowedPath: testFilePath, original: originalContent)
	}

	private func normalize(
		_ raw: [String: MCP.Value]?,
		originalToolName: String = "apply_edits",
		canonicalToolName: String = "apply_edits"
	) -> [String: MCP.Value]? {
		guard let raw else { return nil }
		return DelegateEditArgsNormalizer.normalize(
			params: raw,
			originalToolName: originalToolName,
			canonicalToolName: canonicalToolName
		).payload
	}

	// MARK: - Integration Tests

	func testToolNameWrapperWithValidEdits() async throws {
		let sandbox = makeSandbox()

		// Wrapped in tool-name key (MCPConnectionManager should unwrap this)
		let rawArgs: [String: MCP.Value] = [
			"apply_edits": MCPTestValue.o([
				"edits": MCPTestValue.a([
					MCPTestValue.o([
						"search": MCPTestValue.s("hello"),
						"replace": MCPTestValue.s("world")
					])
				]),
				"path": MCPTestValue.s(testFilePath)
			])
		]

		let toolName = "apply_" + "edits"
		let sanitized = normalize(rawArgs, originalToolName: toolName, canonicalToolName: "apply_edits")
		XCTAssertNotNil(sanitized)
		XCTAssertNil(sanitized?[toolName])
		XCTAssertNotNil(sanitized?["edits"])

		let result = await sandbox.callApplyEdits(args: sanitized!)
		XCTAssertFalse(result.isError ?? false)

		let content = await sandbox.currentContent()
		XCTAssertTrue(content.contains("world"))
		XCTAssertFalse(content.contains("hello"))
	}

	func testToolNameWrapperWithMalformedEdits() async throws {
		let sandbox = makeSandbox()

		// BOTH issues: wrapped in tool-name + malformed replacement key
		let rawArgs: [String: MCP.Value] = [
			"apply_edits": MCPTestValue.o([
				"edits": MCPTestValue.a([
					MCPTestValue.o([
						"search": MCPTestValue.s("hello"),
						"\tnewMethod()": MCPTestValue.s("\tnewMethod()")
					])
				]),
				"path": MCPTestValue.s(testFilePath)
			])
		]

		let sanitized = normalize(rawArgs)
		XCTAssertNotNil(sanitized)
		XCTAssertNil(sanitized?["apply_edits"])

		let result = await sandbox.callApplyEdits(args: sanitized!)
		XCTAssertFalse(result.isError ?? false, "Should succeed after both repairs")

		let content = await sandbox.currentContent()
		XCTAssertTrue(content.contains("newMethod"))
		XCTAssertFalse(content.contains("hello"))
	}

	func testToolNameWrapperWithPathSibling() async throws {
		let sandbox = makeSandbox()

		// Wrapped with path as sibling (should merge)
		let rawArgs: [String: MCP.Value] = [
			"path": MCPTestValue.s(testFilePath),
			"apply_edits": MCPTestValue.o([
				"edits": MCPTestValue.a([
					MCPTestValue.o([
						"search": MCPTestValue.s("hello"),
						"replace": MCPTestValue.s("world")
					])
				])
			])
		]

		let sanitized = normalize(rawArgs)
		XCTAssertNotNil(sanitized)
		XCTAssertNotNil(sanitized?["path"])
		XCTAssertNotNil(sanitized?["edits"])
		XCTAssertNil(sanitized?["apply_edits"])

		let result = await sandbox.callApplyEdits(args: sanitized!)
		XCTAssertFalse(result.isError ?? false)

		let content = await sandbox.currentContent()
		XCTAssertTrue(content.contains("world"))
	}

	func testNestedToolNameWrapper() async throws {
		let sandbox = makeSandbox()

		let rawArgs: [String: MCP.Value] = [
			"apply_edits": MCPTestValue.o([
				"apply_edits": MCPTestValue.o([
					"edits": MCPTestValue.a([
						MCPTestValue.o([
							"search": MCPTestValue.s("hello"),
							"replace": MCPTestValue.s("world")
						])
					]),
					"path": MCPTestValue.s(testFilePath)
				])
			])
		]

		let sanitized = normalize(rawArgs)
		XCTAssertNotNil(sanitized)
		XCTAssertNil(sanitized?["apply_edits"])
		XCTAssertNotNil(sanitized?["edits"])

		let result = await sandbox.callApplyEdits(args: sanitized!)
		XCTAssertFalse(result.isError ?? false)

		let content = await sandbox.currentContent()
		XCTAssertTrue(content.contains("world"))
	}

	func testToolNameWrapperInArgsKey() async throws {
		let sandbox = makeSandbox()

		let rawArgs: [String: MCP.Value] = [
			"args": MCPTestValue.o([
				"apply_edits": MCPTestValue.o([
					"edits": MCPTestValue.a([
						MCPTestValue.o([
							"search": MCPTestValue.s("hello"),
							"replace": MCPTestValue.s("world")
						])
					]),
					"path": MCPTestValue.s(testFilePath)
				])
			])
		]

		let sanitized = normalize(rawArgs)
		XCTAssertNotNil(sanitized)
		XCTAssertNil(sanitized?["args"])
		XCTAssertNil(sanitized?["apply_edits"])
		XCTAssertNotNil(sanitized?["edits"])

		let result = await sandbox.callApplyEdits(args: sanitized!)
		XCTAssertFalse(result.isError ?? false)

		let content = await sandbox.currentContent()
		XCTAssertTrue(content.contains("world"))
	}

	func testRealWorldScenario_ToolWrapperAndMalformedKey() async throws {
		let sandbox = makeSandbox()

		let malformedReplacement = """
		func newMethod() {
			print("new")
		}
		"""

		let rawArgs: [String: MCP.Value] = [
			"path": MCPTestValue.s(testFilePath),
			"apply_edits": MCPTestValue.o([
				"edits": MCPTestValue.a([
					MCPTestValue.o([
						"search": MCPTestValue.s("func someMethod()"),
						malformedReplacement: MCPTestValue.s(malformedReplacement)
					])
				])
			])
		]

		let sanitized = normalize(rawArgs)
		XCTAssertNotNil(sanitized)

		let result = await sandbox.callApplyEdits(args: sanitized!)
		XCTAssertFalse(result.isError ?? false, "Should succeed after both repairs")

		let content = await sandbox.currentContent()
		XCTAssertTrue(content.contains("newMethod"))
		XCTAssertFalse(content.contains("someMethod"))
	}

	func testSingleSearchReplaceWithBothIssues() async throws {
		let sandbox = makeSandbox()

		let rawArgs: [String: MCP.Value] = [
			"apply_edits": MCPTestValue.o([
				"search": MCPTestValue.s("hello"),
				"\tprint(\"world\")": MCPTestValue.s("\tprint(\"world\")"),
				"path": MCPTestValue.s(testFilePath)
			])
		]

		let sanitized = normalize(rawArgs)
		XCTAssertNotNil(sanitized)

		let result = await sandbox.callApplyEdits(args: sanitized!)
		XCTAssertFalse(result.isError ?? false)

		let content = await sandbox.currentContent()
		XCTAssertTrue(content.contains("world"))
	}

	func testRewriteModeWithToolWrapper() async throws {
		let sandbox = makeSandbox()

		let newContent = "// Completely new content"
		let rawArgs: [String: MCP.Value] = [
			"apply_edits": MCPTestValue.o([
				"rewrite": MCPTestValue.s(newContent),
				"path": MCPTestValue.s(testFilePath)
			])
		]

		let sanitized = normalize(rawArgs)
		XCTAssertNotNil(sanitized)

		let result = await sandbox.callApplyEdits(args: sanitized!)
		XCTAssertFalse(result.isError ?? false)

		let content = await sandbox.currentContent()
		XCTAssertEqual(content, newContent)
	}

	// MARK: - Negative Cases (Should Still Fail After Repairs)

	func testInvalidSiblingShouldPreventUnwrap() async throws {
		let sandbox = makeSandbox()

		let rawArgs: [String: MCP.Value] = [
			"invalid_key": MCPTestValue.s("blocks unwrap"),
			"apply_edits": MCPTestValue.o([
				"edits": MCPTestValue.a([
					MCPTestValue.o([
						"search": MCPTestValue.s("hello"),
						"\tprint(\"world\")": MCPTestValue.s("\tprint(\"world\")")
					])
				])
			])
		]

		let sanitized = normalize(rawArgs)
		XCTAssertNotNil(sanitized?["apply_edits"], "Should not unwrap with invalid sibling")

		let result = await sandbox.callApplyEdits(args: sanitized!)
		XCTAssertTrue(result.isError ?? false, "Should fail - invalid structure after blocked unwrap")
	}

	func testMultipleOrphanKeysShouldNotRepair() async throws {
		let sandbox = makeSandbox()

		let rawArgs: [String: MCP.Value] = [
			"search": MCPTestValue.s("old"),
			"orphan1": MCPTestValue.s("value1"),
			"orphan2": MCPTestValue.s("value2"),
			"path": MCPTestValue.s(testFilePath)
		]

		let result = await sandbox.callApplyEdits(args: rawArgs)
		XCTAssertTrue(result.isError ?? false, "Should fail - can't guess which orphan is the replacement")
	}
}
