import XCTest
@testable import RepoPrompt

final class WindowRoutingServiceManageWorkspacesTests: XCTestCase {
	@MainActor
	func testValidateAddFolderWorkspaceRejectsSystemWorkspace() {
		let workspace = WorkspaceModel(
			name: "No Workspace",
			repoPaths: [],
			isSystemWorkspace: true
		)

		do {
			try WindowRoutingService.validateAddFolderWorkspace(workspace)
			XCTFail("Expected system workspace validation to throw")
		} catch {
			XCTAssertTrue(
				error.localizedDescription.contains("Cannot add folders to system workspace"),
				"Unexpected error: \(error.localizedDescription)"
			)
		}
	}

	@MainActor
	func testValidateAddFolderWorkspaceAllowsRegularWorkspace() {
		let workspace = WorkspaceModel(
			name: "RepoPrompt",
			repoPaths: ["/tmp/repoprompt"],
			isSystemWorkspace: false
		)

		XCTAssertNoThrow(try WindowRoutingService.validateAddFolderWorkspace(workspace))
	}

	func testWorkspaceDeleteCloseAuthorizationBypassesPromptAndBackgroundPreservation() {
		let authorization = WindowRoutingService.workspaceDeleteCloseAuthorization()

		XCTAssertEqual(authorization.source, .workspaceDelete)
		XCTAssertTrue(authorization.bypassConfirmation)
		XCTAssertTrue(authorization.bypassBackgroundPreservation)
	}

	func testComposeTabSummaryEncodesContextIDWithSnakeCaseKey() throws {
		let summary = MCPComposeTabSummary(
			id: UUID(),
			contextID: UUID(),
			name: "Main",
			workspaceID: UUID(),
			workspaceName: "RepoPrompt",
			windowID: 2,
			isActive: true,
			isBoundForClient: false,
			totalFileCount: 3,
			sampleFileNames: ["A.swift"]
		)

		let data = try JSONEncoder().encode(summary)
		let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
		XCTAssertEqual(object?["context_id"] as? String, summary.contextID.uuidString)
		XCTAssertNil(object?["contextID"])
	}

	func testWorkspaceSummaryEncodesHiddenWithSnakeCaseKey() throws {
		let summary = MCPWorkspaceSummary(
			id: UUID(),
			name: "Hidden Project",
			allRepoPaths: ["/tmp/hidden"],
			showingWindowIDs: [],
			isHidden: true
		)

		let data = try JSONEncoder().encode(summary)
		let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
		XCTAssertEqual(object?["is_hidden"] as? Bool, true)
		XCTAssertNil(object?["isHidden"])
	}

	func testNameBasedWorkspaceResolutionExcludesHiddenByDefault() throws {
		let hidden = WorkspaceModel(
			name: "Archive",
			repoPaths: ["/tmp/archive"],
			isHiddenInMenus: true
		)

		XCTAssertThrowsError(try WindowRoutingService.test_resolveWorkspaceReference(
			"Archive",
			workspaces: [hidden],
			includeHiddenForName: false
		)) { error in
			XCTAssertTrue(error.localizedDescription.contains("hidden"), "Unexpected error: \(error.localizedDescription)")
			XCTAssertTrue(error.localizedDescription.contains("include_hidden=true"), "Unexpected error: \(error.localizedDescription)")
		}
	}

	func testNameBasedWorkspaceResolutionIncludesHiddenWhenRequested() throws {
		let hidden = WorkspaceModel(
			name: "Archive",
			repoPaths: ["/tmp/archive"],
			isHiddenInMenus: true
		)

		let resolved = try WindowRoutingService.test_resolveWorkspaceReference(
			"Archive",
			workspaces: [hidden],
			includeHiddenForName: true
		)
		XCTAssertEqual(resolved.id, hidden.id)
	}

	func testUUIDWorkspaceResolutionAllowsHiddenWithoutIncludeHidden() throws {
		let hidden = WorkspaceModel(
			name: "Archive",
			repoPaths: ["/tmp/archive"],
			isHiddenInMenus: true
		)

		let resolved = try WindowRoutingService.test_resolveWorkspaceReference(
			hidden.id.uuidString,
			workspaces: [hidden],
			includeHiddenForName: false
		)
		XCTAssertEqual(resolved.id, hidden.id)
	}

	func testVisibleWorkspaceWinsNameResolutionWhenHiddenDuplicateExistsByDefault() throws {
		let visible = WorkspaceModel(
			name: "Archive",
			repoPaths: ["/tmp/archive-visible"]
		)
		let hidden = WorkspaceModel(
			name: "Archive",
			repoPaths: ["/tmp/archive-hidden"],
			isHiddenInMenus: true
		)

		let resolved = try WindowRoutingService.test_resolveWorkspaceReference(
			"Archive",
			workspaces: [hidden, visible],
			includeHiddenForName: false
		)
		XCTAssertEqual(resolved.id, visible.id)
	}

	func testNameResolutionRequiresUUIDWhenVisibleWorkspacesShareName() throws {
		let first = WorkspaceModel(
			name: "Archive",
			repoPaths: ["/tmp/archive-a"]
		)
		let second = WorkspaceModel(
			name: "Archive",
			repoPaths: ["/tmp/archive-b"]
		)

		XCTAssertThrowsError(try WindowRoutingService.test_resolveWorkspaceReference(
			"Archive",
			workspaces: [first, second],
			includeHiddenForName: false
		)) { error in
			XCTAssertTrue(error.localizedDescription.contains("multiple workspaces"), "Unexpected error: \(error.localizedDescription)")
			XCTAssertTrue(error.localizedDescription.contains("UUID"), "Unexpected error: \(error.localizedDescription)")
		}
	}

	func testIncludeHiddenNameResolutionRequiresUUIDWhenVisibleAndHiddenShareName() throws {
		let visible = WorkspaceModel(
			name: "Archive",
			repoPaths: ["/tmp/archive-visible"]
		)
		let hidden = WorkspaceModel(
			name: "Archive",
			repoPaths: ["/tmp/archive-hidden"],
			isHiddenInMenus: true
		)

		XCTAssertThrowsError(try WindowRoutingService.test_resolveWorkspaceReference(
			"Archive",
			workspaces: [hidden, visible],
			includeHiddenForName: true
		)) { error in
			XCTAssertTrue(error.localizedDescription.contains("multiple workspaces"), "Unexpected error: \(error.localizedDescription)")
			XCTAssertTrue(error.localizedDescription.contains("UUID"), "Unexpected error: \(error.localizedDescription)")
		}
	}

	func testHideNameResolutionIsIdempotentForAlreadyHiddenWorkspace() throws {
		let hidden = WorkspaceModel(
			name: "Archive",
			repoPaths: ["/tmp/archive"],
			isHiddenInMenus: true
		)

		let resolved = try WindowRoutingService.test_resolveWorkspaceHiddenMutationReference(
			"Archive",
			workspaces: [hidden],
			hidden: true
		)
		XCTAssertEqual(resolved.id, hidden.id)
	}
}
