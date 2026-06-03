import XCTest
import MCP
@testable import RepoPrompt

/// Regression tests for canonical binding argument handling in the MCPConnectionManager
/// dispatch pipeline. `context_id` remains a hidden per-call routing handle for normal
/// tool calls, while `working_dirs` is only extracted and rehydrated for explicit
/// `bind_context` calls.
final class MCPDispatchArgsRehydrationTests: XCTestCase {

	// MARK: - Hidden routing extraction

	func testNormalizerExtractsValidContextIDForNonBindContextTool() {
		let contextID = UUID()
		let args: [String: MCP.Value] = [
			"path": MCPTestValue.s("test.swift"),
			"context_id": MCPTestValue.s(contextID.uuidString)
		]

		let normalized = DelegateEditArgsNormalizer.normalize(
			params: args,
			originalToolName: "read_file",
			canonicalToolName: "read_file"
		)

		XCTAssertEqual(normalized.contextID, contextID)
		XCTAssertNil(normalized.payload["context_id"])
	}

	func testNormalizerLeavesInvalidContextIDInPayloadForNonBindContextTool() {
		let args: [String: MCP.Value] = [
			"path": MCPTestValue.s("test.swift"),
			"context_id": MCPTestValue.s("not-a-uuid")
		]

		let normalized = DelegateEditArgsNormalizer.normalize(
			params: args,
			originalToolName: "read_file",
			canonicalToolName: "read_file"
		)

		XCTAssertNil(normalized.contextID)
		XCTAssertEqual(normalized.payload["context_id"]?.stringValue, "not-a-uuid")
	}

	func testNormalizerDoesNotExtractWorkingDirsForNonBindContextTool() {
		let args: [String: MCP.Value] = [
			"path": MCPTestValue.s("test.swift"),
			"working_dirs": MCPTestValue.a([
				MCPTestValue.s("/tmp/project"),
				MCPTestValue.s("/tmp/project/Sources")
			])
		]

		let normalized = DelegateEditArgsNormalizer.normalize(
			params: args,
			originalToolName: "read_file",
			canonicalToolName: "read_file"
		)

		XCTAssertTrue(normalized.workingDirs.isEmpty)
		let dirs = normalized.payload["working_dirs"]?.arrayValue?.compactMap { $0.stringValue }
		XCTAssertEqual(dirs, ["/tmp/project", "/tmp/project/Sources"])
	}

	// MARK: - Dispatch arg rehydration

	func testBindContextDispatchArgumentsRehydrateContextIDAndWorkingDirs() {
		let contextID = UUID()
		let args: [String: MCP.Value] = [
			"op": MCPTestValue.s("bind"),
			"context_id": MCPTestValue.s(contextID.uuidString),
			"working_dirs": MCPTestValue.a([
				MCPTestValue.s("/tmp/project"),
				MCPTestValue.s("/tmp/project/Sources")
			])
		]

		let normalized = DelegateEditArgsNormalizer.normalize(
			params: args,
			originalToolName: "bind_context",
			canonicalToolName: "bind_context"
		)

		var dispatchArguments = normalized.payload
		if let extractedContextID = normalized.contextID {
			dispatchArguments["context_id"] = .string(extractedContextID.uuidString)
		}
		if !normalized.workingDirs.isEmpty {
			dispatchArguments["working_dirs"] = .array(normalized.workingDirs.map { .string($0) })
		}

		XCTAssertEqual(dispatchArguments["context_id"]?.stringValue, contextID.uuidString)
		let dirs = dispatchArguments["working_dirs"]?.arrayValue?.compactMap { $0.stringValue }
		XCTAssertEqual(dirs, ["/tmp/project", "/tmp/project/Sources"])
	}

	func testNonBindContextDispatchArgumentsDoNotRehydrateExtractedContextID() {
		let contextID = UUID()
		let args: [String: MCP.Value] = [
			"path": MCPTestValue.s("test.swift"),
			"context_id": MCPTestValue.s(contextID.uuidString)
		]

		let normalized = DelegateEditArgsNormalizer.normalize(
			params: args,
			originalToolName: "read_file",
			canonicalToolName: "read_file"
		)

		let dispatchArguments = normalized.payload
		XCTAssertNil(dispatchArguments["context_id"])
		XCTAssertEqual(normalized.contextID, contextID)
	}

	func testNonBindContextDispatchArgumentsDoNotSynthesizeWorkingDirs() {
		let args: [String: MCP.Value] = [
			"path": MCPTestValue.s("test.swift"),
			"working_dirs": MCPTestValue.a([
				MCPTestValue.s("/tmp/project")
			])
		]

		let normalized = DelegateEditArgsNormalizer.normalize(
			params: args,
			originalToolName: "read_file",
			canonicalToolName: "read_file"
		)

		let dispatchArguments = normalized.payload
		XCTAssertEqual(dispatchArguments["working_dirs"]?.arrayValue?.compactMap { $0.stringValue }, ["/tmp/project"])
		XCTAssertTrue(normalized.workingDirs.isEmpty)
	}

	func testDispatchArgumentsDoNotRehydrateHiddenRoutingKeysForNonBindContextTool() {
		let contextID = UUID()
		let tabID = UUID()
		let args: [String: MCP.Value] = [
			"path": MCPTestValue.s("test.swift"),
			"context_id": MCPTestValue.s(contextID.uuidString),
			"_tabID": MCPTestValue.s(tabID.uuidString),
			"_windowID": MCPTestValue.i(2),
			"_rawJSON": MCPTestValue.b(true)
		]

		let normalized = DelegateEditArgsNormalizer.normalize(
			params: args,
			originalToolName: "read_file",
			canonicalToolName: "read_file"
		)

		let dispatchArguments = normalized.payload
		XCTAssertNil(dispatchArguments["context_id"])
		XCTAssertNil(dispatchArguments["_tabID"])
		XCTAssertNil(dispatchArguments["_windowID"])
		XCTAssertNil(dispatchArguments["_rawJSON"])
		XCTAssertEqual(normalized.contextID, contextID)
	}

	func testDispatchArgumentsPreserveInvalidContextIDLiteralInPayload() {
		let args: [String: MCP.Value] = [
			"path": MCPTestValue.s("test.swift"),
			"context_id": MCPTestValue.s("not-a-uuid")
		]

		let normalized = DelegateEditArgsNormalizer.normalize(
			params: args,
			originalToolName: "read_file",
			canonicalToolName: "read_file"
		)

		let dispatchArguments = normalized.payload
		XCTAssertEqual(dispatchArguments["context_id"]?.stringValue, "not-a-uuid")
	}
}
