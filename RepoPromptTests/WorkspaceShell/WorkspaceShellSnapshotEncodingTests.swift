import XCTest
@testable import RepoPrompt

final class WorkspaceShellSnapshotEncodingTests: XCTestCase {
	func testSnapshotEncodesSnakeCaseKeys() throws {
		let visible = UUID()
		let snapshot = WorkspaceShellSnapshot(
			visibleWorkspaceID: visible,
			isWorkspaceSidebarCollapsed: true,
			workspaces: [MCPWorkspaceSummary(id: visible, name: "A", allRepoPaths: [], showingWindowIDs: [1], isVisible: true)]
		)

		let data = try JSONEncoder().encode(snapshot)
		let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
		XCTAssertEqual(object["visible_workspace_id"] as? String, visible.uuidString)
		XCTAssertEqual(object["is_workspace_sidebar_collapsed"] as? Bool, true)
		XCTAssertEqual((object["workspaces"] as? [[String: Any]])?.count, 1)
		XCTAssertNil(object["visibleWorkspaceID"])

		let empty = try JSONSerialization.jsonObject(with: JSONEncoder().encode(WorkspaceShellSnapshot.empty)) as? [String: Any]
		XCTAssertTrue(empty?["visible_workspace_id"] is NSNull || empty?["visible_workspace_id"] == nil)
		XCTAssertEqual((empty?["workspaces"] as? [Any])?.count, 0)
	}

	func testWorkspaceSummaryEncodesVisibilityAvailabilityAndAgents() throws {
		let summary = MCPWorkspaceSummary(
			id: UUID(),
			name: "B",
			allRepoPaths: ["/tmp/one", "/tmp/two", "/tmp/three", "/tmp/four"],
			showingWindowIDs: [],
			isHidden: false,
			isVisible: false,
			isAvailable: false,
			hasRunningAgents: true
		)

		let data = try JSONEncoder().encode(summary)
		let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
		XCTAssertEqual(object["is_visible"] as? Bool, false)
		XCTAssertEqual(object["is_available"] as? Bool, false)
		XCTAssertEqual(object["has_running_agents"] as? Bool, true)
		XCTAssertEqual(object["root_count"] as? Int, 4)
		XCTAssertEqual((object["repo_paths"] as? [String])?.count, 3)

		let decoded = try JSONDecoder().decode(MCPWorkspaceSummary.self, from: data)
		XCTAssertEqual(decoded, summary)
	}

	func testResponseEncodesShellField() throws {
		let response = ManageWorkspacesResponse(
			action: "state",
			workspaces: nil,
			status: "ok",
			windowID: 7,
			shell: .empty
		)

		let data = try JSONEncoder().encode(response)
		let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
		XCTAssertNotNil(object["shell"] as? [String: Any])
		XCTAssertEqual(object["window_id"] as? Int, 7)
		XCTAssertNil(object["closed_window_id"] as? Int)
	}
}
