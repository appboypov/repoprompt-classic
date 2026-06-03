import XCTest
import MCP
@testable import RepoPrompt

/// Tests for the tool-name wrapper normalization logic in DelegateEditArgsNormalizer
final class MCPSanitizationTests: XCTestCase {
	private func normalize(
		_ args: [String: MCP.Value],
		originalToolName: String = "apply_edits",
		canonicalToolName: String = "apply_edits"
	) -> NormalizedArgs {
		DelegateEditArgsNormalizer.normalize(
			params: args,
			originalToolName: originalToolName,
			canonicalToolName: canonicalToolName
		)
	}

	func testNormalizeUnwrapTopLevelWrapper() {
		let inner: [String: MCP.Value] = [
			"edits": MCPTestValue.a([]),
			"path": MCPTestValue.s("test.swift")
		]
		let args: [String: MCP.Value] = [
			"apply_edits": MCPTestValue.o(inner)
		]

		let normalized = normalize(args)
		XCTAssertNil(normalized.payload["apply_edits"])
		XCTAssertNotNil(normalized.payload["edits"])
		XCTAssertEqual(normalized.payload["path"]?.stringValue, "test.swift")
		XCTAssertTrue(normalized.warnings.contains { $0.contains("Unwrapped tool-name wrapper") })
	}

	func testNormalizeUnwrapWithValidSiblings() {
		let inner: [String: MCP.Value] = [
			"edits": MCPTestValue.a([])
		]
		let args: [String: MCP.Value] = [
			"apply_edits": MCPTestValue.o(inner),
			"path": MCPTestValue.s("file.swift"),
			"verbose": MCPTestValue.b(true)
		]

		let normalized = normalize(args)
		XCTAssertNil(normalized.payload["apply_edits"])
		XCTAssertNotNil(normalized.payload["edits"])
		XCTAssertEqual(normalized.payload["path"]?.stringValue, "file.swift")
		XCTAssertEqual(normalized.payload["verbose"]?.boolValue, true)
	}

	func testNormalizeNoUnwrapWithInvalidSibling() {
		let inner: [String: MCP.Value] = [
			"edits": MCPTestValue.a([])
		]
		let args: [String: MCP.Value] = [
			"apply_edits": MCPTestValue.o(inner),
			"invalid_key": MCPTestValue.s("blocks unwrap")
		]

		let normalized = normalize(args)
		XCTAssertNotNil(normalized.payload["apply_edits"])
		XCTAssertNotNil(normalized.payload["invalid_key"])
		XCTAssertTrue(normalized.warnings.isEmpty)
	}

	func testNormalizeUnwrapWithValidToolSpecificSibling() {
		let inner: [String: MCP.Value] = [
			"edits": MCPTestValue.a([])
		]
		let args: [String: MCP.Value] = [
			"apply_edits": MCPTestValue.o(inner),
			"replace_all": MCPTestValue.b(true)
		]

		let normalized = normalize(args)
		XCTAssertNil(normalized.payload["apply_edits"])
		XCTAssertNotNil(normalized.payload["edits"])
		XCTAssertEqual(normalized.payload["replace_all"]?.boolValue, true)
		XCTAssertTrue(normalized.warnings.contains { $0.contains("Unwrapped tool-name wrapper") })
	}

	func testNormalizeJSONStringWrapper() {
		let args: [String: MCP.Value] = [
			"apply_edits": MCPTestValue.s("{\"edits\":[],\"path\":\"file.swift\"}")
		]

		let normalized = normalize(args)
		XCTAssertNil(normalized.payload["apply_edits"])
		XCTAssertNotNil(normalized.payload["edits"])
		XCTAssertEqual(normalized.payload["path"]?.stringValue, "file.swift")
	}

	func testNormalizeMultipleLevels() {
		let inner: [String: MCP.Value] = [
			"edits": MCPTestValue.a([])
		]
		let middle: [String: MCP.Value] = [
			"apply_edits": MCPTestValue.o(inner)
		]
		let args: [String: MCP.Value] = [
			"apply_edits": MCPTestValue.o(middle)
		]

		let normalized = normalize(args)
		XCTAssertNil(normalized.payload["apply_edits"])
		XCTAssertNotNil(normalized.payload["edits"])
	}

	func testNormalizeInnerWinsOnDuplicateKeys() {
		let inner: [String: MCP.Value] = [
			"path": MCPTestValue.s("inner.swift"),
			"edits": MCPTestValue.a([])
		]
		let args: [String: MCP.Value] = [
			"apply_edits": MCPTestValue.o(inner),
			"path": MCPTestValue.s("outer.swift")
		]

		let normalized = normalize(args)
		XCTAssertEqual(normalized.payload["path"]?.stringValue, "inner.swift")
	}

	func testNormalizeNoWrapper() {
		let args: [String: MCP.Value] = [
			"edits": MCPTestValue.a([]),
			"path": MCPTestValue.s("test.swift")
		]

		let normalized = normalize(args)
		XCTAssertEqual(normalized.payload.count, args.count)
		XCTAssertEqual(normalized.payload["path"]?.stringValue, "test.swift")
	}

	func testNormalizeUnwrapAliasName() {
		let inner: [String: MCP.Value] = [
			"edits": MCPTestValue.a([])
		]
		let args: [String: MCP.Value] = [
			"some_alias": MCPTestValue.o(inner)
		]

		let normalized = normalize(args, originalToolName: "some_alias", canonicalToolName: "apply_edits")
		XCTAssertNil(normalized.payload["some_alias"])
		XCTAssertNotNil(normalized.payload["edits"])
	}

	func testNormalizeArgsWrapperAndSupportedRoutingExtraction() {
		let tabID = UUID()
		let args: [String: MCP.Value] = [
			"args": MCPTestValue.o([
				"apply_edits": MCPTestValue.o([
					"edits": MCPTestValue.a([]),
					"path": MCPTestValue.s("test.swift")
				]),
				"_tabID": MCPTestValue.s(tabID.uuidString),
				"_windowID": MCPTestValue.i(2),
				"_rawJSON": MCPTestValue.b(true)
			])
		]

		let normalized = normalize(args)
		XCTAssertNil(normalized.payload["args"])
		XCTAssertNil(normalized.payload["apply_edits"])
		XCTAssertEqual(normalized.payload["path"]?.stringValue, "test.swift")
		XCTAssertEqual(normalized.tabID, tabID)
		XCTAssertEqual(normalized.windowID, 2)
		XCTAssertEqual(normalized.rawJSON, true)
	}

	func testNormalizeParsesJSONStringSubfields() {
		let args: [String: MCP.Value] = [
			"path": MCPTestValue.s("file.swift"),
			"replace": MCPTestValue.s("{\"search\":\"a\",\"replace\":\"b\"}")
		]

		let normalized = normalize(args)
		XCTAssertNotNil(normalized.payload["replace"]?.objectValue)
	}

	func testNormalizeExtractsSupportedRoutingFieldsFromTopLevel() {
		let tabID = UUID()
		let args: [String: MCP.Value] = [
			"edits": MCPTestValue.a([]),
			"path": MCPTestValue.s("test.swift"),
			"_tabID": MCPTestValue.s(tabID.uuidString),
			"_windowID": MCPTestValue.i(3),
			"_rawJSON": MCPTestValue.b(true)
		]

		let normalized = normalize(args)
		XCTAssertNil(normalized.payload["_tabID"])
		XCTAssertNil(normalized.payload["_windowID"])
		XCTAssertNil(normalized.payload["_rawJSON"])
		XCTAssertEqual(normalized.payload["path"]?.stringValue, "test.swift")
		XCTAssertEqual(normalized.tabID, tabID)
		XCTAssertEqual(normalized.windowID, 3)
		XCTAssertEqual(normalized.rawJSON, true)
	}

	func testNormalizeExtractsHiddenContextIDFromTopLevelForNonBindContextTools() {
		let contextID = UUID()
		let args: [String: MCP.Value] = [
			"edits": MCPTestValue.a([]),
			"path": MCPTestValue.s("test.swift"),
			"context_id": MCPTestValue.s(contextID.uuidString),
			"working_dirs": MCPTestValue.a([
				MCPTestValue.s("/tmp/project"),
				MCPTestValue.s(" /tmp/project/Sources ")
			])
		]

		let normalized = normalize(args)
		XCTAssertNil(normalized.payload["context_id"])
		XCTAssertEqual(normalized.contextID, contextID)
		XCTAssertEqual(normalized.payload["working_dirs"]?.arrayValue?.compactMap(\.stringValue), ["/tmp/project", " /tmp/project/Sources "])
		XCTAssertTrue(normalized.workingDirs.isEmpty)
	}

	func testNormalizeExtractsBindContextWorkingDirsFromTopLevel() {
		let contextID = UUID()
		let args: [String: MCP.Value] = [
			"op": MCPTestValue.s("bind"),
			"context_id": MCPTestValue.s(contextID.uuidString),
			"working_dirs": MCPTestValue.s("/tmp/project,/tmp/project/Tests")
		]

		let normalized = DelegateEditArgsNormalizer.normalize(
			params: args,
			originalToolName: "bind_context",
			canonicalToolName: "bind_context"
		)

		XCTAssertNil(normalized.payload["context_id"])
		XCTAssertNil(normalized.payload["working_dirs"])
		XCTAssertEqual(normalized.contextID, contextID)
		XCTAssertEqual(normalized.workingDirs, ["/tmp/project", "/tmp/project/Tests"])
	}

	func testNormalizeExtractsBindContextWorkingDirsFromNestedArgs() {
		let contextID = UUID()
		let args: [String: MCP.Value] = [
			"args": MCPTestValue.o([
				"bind_context": MCPTestValue.o([
					"op": MCPTestValue.s("bind")
				]),
				"context_id": MCPTestValue.s(contextID.uuidString),
				"working_dirs": MCPTestValue.s("/tmp/project,/tmp/project/Tests")
			])
		]

		let normalized = DelegateEditArgsNormalizer.normalize(
			params: args,
			originalToolName: "bind_context",
			canonicalToolName: "bind_context"
		)
		XCTAssertNil(normalized.payload["context_id"])
		XCTAssertNil(normalized.payload["working_dirs"])
		XCTAssertEqual(normalized.contextID, contextID)
		XCTAssertEqual(normalized.workingDirs, ["/tmp/project", "/tmp/project/Tests"])
	}
}
