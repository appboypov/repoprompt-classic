import XCTest
@testable import RepoPrompt

@MainActor
final class MCPServerViewModelAgentSessionParentingTests: XCTestCase {
	private func makeVirtualContext(tabID: UUID = UUID()) -> MCPServerViewModel.ExecContext {
		.virtual(
			MCPServerViewModel.TabScopedContext(
				tabID: tabID,
				windowID: 1,
				workspaceID: nil,
				promptText: "",
				selection: StoredSelection(),
				selectedMetaPromptIDs: [],
				tabName: "Agent",
				runID: UUID(),
				explicitlyBound: false
			)
		)
	}

	func testAgentModeVirtualContextUsesSourceTabAsParent() {
		let sourceTabID = UUID()
		let result = MCPServerViewModel.spawnParentSourceTabIDForAgentSessionCreation(
			purpose: .agentModeRun,
			execContext: makeVirtualContext(tabID: sourceTabID)
		)

		XCTAssertEqual(result, sourceTabID)
	}

	func testAgentModeLiveContextDoesNotUseParent() {
		let result = MCPServerViewModel.spawnParentSourceTabIDForAgentSessionCreation(
			purpose: .agentModeRun,
			execContext: .live
		)

		XCTAssertNil(result)
	}

	func testAgentModeVirtualContextUsesSourceTabForSpawnSource() {
		let sourceTabID = UUID()
		let result = MCPServerViewModel.spawnSourceTabIDForAgentSessionCreation(
			purpose: .agentModeRun,
			execContext: makeVirtualContext(tabID: sourceTabID)
		)

		XCTAssertEqual(result, sourceTabID)
	}

	func testUnknownVirtualContextDoesNotUseSpawnSource() {
		let result = MCPServerViewModel.spawnSourceTabIDForAgentSessionCreation(
			purpose: .unknown,
			execContext: makeVirtualContext()
		)

		XCTAssertNil(result)
	}

	func testDiscoverVirtualContextDoesNotUseParent() {
		let result = MCPServerViewModel.spawnParentSourceTabIDForAgentSessionCreation(
			purpose: .discoverRun,
			execContext: makeVirtualContext()
		)

		XCTAssertNil(result)
	}

	func testDelegateEditVirtualContextDoesNotUseParent() {
		let result = MCPServerViewModel.spawnParentSourceTabIDForAgentSessionCreation(
			purpose: .delegateEditRun,
			execContext: makeVirtualContext()
		)

		XCTAssertNil(result)
	}
}
