import XCTest
import MCP
@testable import RepoPrompt

final class BindContextToolTests: XCTestCase {
	func testParseBindContextRequestAcceptsWindowIDSelector() throws {
		let request = try WindowRoutingService.parseBindContextRequest([
			"op": MCPTestValue.s("bind"),
			"window_id": MCPTestValue.i(3)
		])

		XCTAssertEqual(request.op, .bind)
		XCTAssertEqual(request.matchKind, .windowID)
		XCTAssertEqual(request.windowID, 3)
		XCTAssertNil(request.contextID)
		XCTAssertTrue(request.workingDirs.isEmpty)
	}

	func testParseBindContextRequestAcceptsContextIDWithWindowDisambiguator() throws {
		let contextID = UUID()
		let request = try WindowRoutingService.parseBindContextRequest([
			"op": MCPTestValue.s("bind"),
			"context_id": MCPTestValue.s(contextID.uuidString),
			"window_id": MCPTestValue.i(2)
		])

		XCTAssertEqual(request.matchKind, .contextID)
		XCTAssertEqual(request.contextID, contextID)
		XCTAssertEqual(request.windowID, 2)
	}

	func testParseBindContextRequestNormalizesWorkingDirsArray() throws {
		let request = try WindowRoutingService.parseBindContextRequest([
			"op": MCPTestValue.s("bind"),
			"working_dirs": MCPTestValue.a([
				MCPTestValue.s(" /tmp/project/./Sources "),
				MCPTestValue.s("/tmp/project/Sources")
			]),
			"create_if_missing": MCPTestValue.b(true)
		])

		XCTAssertEqual(request.matchKind, .workingDirs)
		XCTAssertEqual(request.workingDirs, ["/tmp/project/Sources"])
		XCTAssertTrue(request.createIfMissing)
	}

	func testParseBindContextRequestNormalizesCommaSeparatedWorkingDirs() throws {
		let request = try WindowRoutingService.parseBindContextRequest([
			"op": MCPTestValue.s("bind"),
			"working_dirs": MCPTestValue.s(" /tmp/project , /tmp/project/Sources ")
		])

		XCTAssertEqual(request.matchKind, .workingDirs)
		XCTAssertEqual(request.workingDirs, ["/tmp/project", "/tmp/project/Sources"])
	}

	func testParseBindContextRequestRejectsContextIDAndWorkingDirsTogether() {
		let contextID = UUID()

		XCTAssertThrowsError(try WindowRoutingService.parseBindContextRequest([
			"op": MCPTestValue.s("bind"),
			"context_id": MCPTestValue.s(contextID.uuidString),
			"working_dirs": MCPTestValue.a([MCPTestValue.s("/tmp/project")])
		])) { error in
			XCTAssertTrue(error.localizedDescription.contains("exactly one primary selector"))
		}
	}

	func testParseBindContextRequestRejectsCreateIfMissingWithoutWorkingDirs() {
		XCTAssertThrowsError(try WindowRoutingService.parseBindContextRequest([
			"op": MCPTestValue.s("bind"),
			"window_id": MCPTestValue.i(4),
			"create_if_missing": MCPTestValue.b(true)
		])) { error in
			XCTAssertTrue(error.localizedDescription.contains("create_if_missing"))
		}
	}

	func testParseBindContextRequestRejectsTabNameWithoutWorkingDirsCreation() {
		XCTAssertThrowsError(try WindowRoutingService.parseBindContextRequest([
			"op": MCPTestValue.s("bind"),
			"window_id": MCPTestValue.i(4),
			"tab_name": MCPTestValue.s("Background")
		])) { error in
			XCTAssertTrue(error.localizedDescription.contains("tab_name"))
		}
	}

	func testParseBindContextRequestRejectsMissingSelectorForBind() {
		XCTAssertThrowsError(try WindowRoutingService.parseBindContextRequest([
			"op": MCPTestValue.s("bind")
		])) { error in
			XCTAssertTrue(error.localizedDescription.contains("requires exactly one primary selector"))
		}
	}

	func testPreferredOpenWindowIDPrefersSelectedWindow() {
		XCTAssertEqual(
			WindowRoutingService.test_preferredOpenWindowID(
				showingWindowIDs: [2, 6, 9],
				selectedWindowID: 6,
				focusedWindowID: 9
			),
			6
		)
	}

	func testPreferredOpenWindowIDFallsBackToFocusedThenLowest() {
		XCTAssertEqual(
			WindowRoutingService.test_preferredOpenWindowID(
				showingWindowIDs: [4, 8],
				selectedWindowID: nil,
				focusedWindowID: 8
			),
			8
		)
		XCTAssertEqual(
			WindowRoutingService.test_preferredOpenWindowID(
				showingWindowIDs: [4, 8],
				selectedWindowID: nil,
				focusedWindowID: 3
			),
			4
		)
	}

	func testBindContextBindingSummaryEncodesSnakeCaseKeys() throws {
		let summary = MCPBindContextBindingSummary(
			bindingKind: "context",
			windowID: 1,
			contextID: UUID(),
			workspaceID: UUID(),
			workspaceName: "RepoPrompt",
			tabName: "Main",
			repoPaths: ["/tmp/repo"],
			explicit: true,
			runScoped: false
		)

		let data = try JSONEncoder().encode(summary)
		let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
		XCTAssertEqual(object?["binding_kind"] as? String, "context")
		XCTAssertNotNil(object?["context_id"])
		XCTAssertNil(object?["contextID"])
		XCTAssertEqual(object?["run_scoped"] as? Bool, false)
	}

	func testBindContextResponseEncodesCreatedWorkspaceInSnakeCase() throws {
		let response = BindContextResponse(
			binding: MCPBindContextBindingSummary(
				bindingKind: "window",
				windowID: 2,
				contextID: nil,
				workspaceID: UUID(),
				workspaceName: "FeedingLittlesApp",
				tabName: nil,
				repoPaths: ["/tmp/project"],
				explicit: false,
				runScoped: false
			),
			createdTab: false,
			createdWorkspace: true,
			normalizedWorkingDirs: ["/tmp/project"]
		)

		let data = try JSONEncoder().encode(response)
		let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
		XCTAssertEqual(object?["created_workspace"] as? Bool, true)
		XCTAssertNil(object?["createdWorkspace"])
	}
}
