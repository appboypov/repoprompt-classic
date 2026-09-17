import XCTest
@testable import RepoPrompt

@MainActor
final class WindowCloseCoordinatorTests: XCTestCase {
	func testDecideAllowsTermination() {
		let decision = WindowCloseCoordinator.decide(
			snapshot: makeSnapshot(isTerminating: true),
			authorization: nil
		)

		XCTAssertEqual(decision, .allow)
	}

	func testDecideAllowsAuthorizedClose() {
		let decision = WindowCloseCoordinator.decide(
			snapshot: makeSnapshot(
				isLastAppWindow: true,
				isLastMCPEnabledWindow: true,
				mcp: .init(
					toolsEnabled: true,
					liveConnectionCount: 1,
					activeExecutionCount: 0,
					hasIdleLiveConnections: true,
					activeToolName: nil
				)
			),
			authorization: WindowCloseAuthorization(
				source: .workspaceDelete,
				bypassConfirmation: true,
				bypassBackgroundPreservation: true
			)
		)

		XCTAssertEqual(decision, .allow)
	}

	func testDecideConfirmsActiveWork() {
		let decision = WindowCloseCoordinator.decide(
			snapshot: makeSnapshot(
				activeItems: [
					WindowCloseActivityItem(
						id: "agent-mode",
						count: 2,
						singularLabel: "active agent session",
						pluralLabel: "active agent sessions"
					)
				]
			),
			authorization: nil
		)

		guard case .confirm(let confirmation) = decision else {
			return XCTFail("Expected close confirmation for active work")
		}
		XCTAssertTrue(confirmation.message.contains("2 active agent sessions"))
		XCTAssertEqual(confirmation.confirmButtonTitle, "Close and End Sessions")
	}

	func testDecideConfirmsActiveMCPToolExecution() {
		let decision = WindowCloseCoordinator.decide(
			snapshot: makeSnapshot(
				mcp: .init(
					toolsEnabled: true,
					liveConnectionCount: 1,
					activeExecutionCount: 1,
					hasIdleLiveConnections: false,
					activeToolName: "apply_edits"
				)
			),
			authorization: nil
		)

		guard case .confirm(let confirmation) = decision else {
			return XCTFail("Expected close confirmation for active MCP execution")
		}
		XCTAssertTrue(confirmation.message.contains("active MCP tool execution"))
	}

	func testDecidePromptsLastAppWindowForIdleLiveMCPWithHideOption() {
		let decision = WindowCloseCoordinator.decide(
			snapshot: makeSnapshot(
				isLastAppWindow: true,
				isLastMCPEnabledWindow: true,
				mcp: .init(
					toolsEnabled: true,
					liveConnectionCount: 1,
					activeExecutionCount: 0,
					hasIdleLiveConnections: true,
					activeToolName: nil
				)
			),
			authorization: nil
		)

		guard case .confirm(let confirmation) = decision else {
			return XCTFail("Expected continuity prompt for the last app window")
		}
		XCTAssertEqual(confirmation.title, "Keep MCP running?")
		XCTAssertEqual(confirmation.confirmButtonTitle, "Close and Stop MCP")
		XCTAssertEqual(confirmation.secondaryButtonTitle, "Hide and Keep Running")
		XCTAssertEqual(confirmation.secondaryAction, .backgroundWindow)
	}

	func testDecideConfirmsIdleLiveMCPWhenAnotherWindowRemains() {
		let decision = WindowCloseCoordinator.decide(
			snapshot: makeSnapshot(
				isLastAppWindow: false,
				isLastMCPEnabledWindow: true,
				mcp: .init(
					toolsEnabled: true,
					liveConnectionCount: 2,
					activeExecutionCount: 0,
					hasIdleLiveConnections: true,
					activeToolName: nil
				)
			),
			authorization: nil
		)

		guard case .confirm(let confirmation) = decision else {
			return XCTFail("Expected continuity confirmation")
		}
		XCTAssertTrue(confirmation.message.contains("disconnect 2 MCP clients"))
		XCTAssertEqual(confirmation.confirmButtonTitle, "Close and Disconnect")
		XCTAssertNil(confirmation.secondaryButtonTitle)
		XCTAssertNil(confirmation.secondaryAction)
	}

	func testDecidePromptsLastAppWindowWhenToolsAreEnabledEvenWithoutLiveConnections() {
		let decision = WindowCloseCoordinator.decide(
			snapshot: makeSnapshot(
				isLastAppWindow: true,
				isLastMCPEnabledWindow: true,
				mcp: .init(
					toolsEnabled: true,
					liveConnectionCount: 0,
					activeExecutionCount: 0,
					hasIdleLiveConnections: false,
					activeToolName: nil
				)
			),
			authorization: nil
		)

		guard case .confirm(let confirmation) = decision else {
			return XCTFail("Expected prompt for last MCP-enabled window")
		}
		XCTAssertEqual(confirmation.title, "Keep MCP running?")
		XCTAssertEqual(confirmation.secondaryButtonTitle, "Hide and Keep Running")
		XCTAssertEqual(confirmation.secondaryAction, .backgroundWindow)
		XCTAssertTrue(confirmation.message.contains("hide it to keep MCP running from the menu bar"))
	}

	func testDecideAllowsCloseWithoutPromptWhenNotLastAppWindowAndNoLiveConnections() {
		let decision = WindowCloseCoordinator.decide(
			snapshot: makeSnapshot(
				isLastAppWindow: false,
				isLastMCPEnabledWindow: true,
				mcp: .init(
					toolsEnabled: true,
					liveConnectionCount: 0,
					activeExecutionCount: 0,
					hasIdleLiveConnections: false,
					activeToolName: nil
				)
			),
			authorization: nil
		)

		XCTAssertEqual(decision, .allow)
	}

	func testAggregateCountsInactiveRuntimeSessionsAndAnyEnabledMCP() {
		let agentItem = { (count: Int) in
			WorkspaceSwitchSessionItem(id: "agent-mode", count: count, singularLabel: "agent run", pluralLabel: "agent runs")
		}
		let snapshot = WindowCloseImpactSnapshot.aggregate(
			sessionSnapshots: [
				WorkspaceSwitchSessionSnapshot(items: []),
				WorkspaceSwitchSessionSnapshot(items: [agentItem(2)]),
				WorkspaceSwitchSessionSnapshot(items: [agentItem(1), WorkspaceSwitchSessionItem(id: "chat", count: 1, singularLabel: "chat", pluralLabel: "chats")])
			],
			mcpStates: [
				.inactive,
				.init(toolsEnabled: true, liveConnectionCount: 2, activeExecutionCount: 1, hasIdleLiveConnections: false, activeToolName: nil),
				.init(toolsEnabled: true, liveConnectionCount: 1, activeExecutionCount: 2, hasIdleLiveConnections: true, activeToolName: "read_file")
			],
			isTerminating: false
		)

		XCTAssertTrue(snapshot.isLastAppWindow)
		XCTAssertTrue(snapshot.isLastMCPEnabledWindow)
		XCTAssertEqual(snapshot.activeItems.map(\.id), ["agent-mode", "chat"])
		XCTAssertEqual(snapshot.activeItems.map(\.count), [3, 1])
		XCTAssertEqual(snapshot.mcp.liveConnectionCount, 2)
		XCTAssertEqual(snapshot.mcp.activeExecutionCount, 3)
		XCTAssertTrue(snapshot.mcp.hasIdleLiveConnections)
		XCTAssertEqual(snapshot.mcp.activeToolName, "read_file")
		guard case .confirm = WindowCloseCoordinator.decide(snapshot: snapshot, authorization: nil) else {
			return XCTFail("aggregate with active work must confirm")
		}
	}

	private func makeSnapshot(
		isTerminating: Bool = false,
		isLastAppWindow: Bool = false,
		isLastMCPEnabledWindow: Bool = false,
		activeItems: [WindowCloseActivityItem] = [],
		mcp: WindowMCPCloseSafetyState = .inactive
	) -> WindowCloseImpactSnapshot {
		WindowCloseImpactSnapshot(
			isTerminating: isTerminating,
			isLastAppWindow: isLastAppWindow,
			isLastMCPEnabledWindow: isLastMCPEnabledWindow,
			activeItems: activeItems,
			mcp: mcp
		)
	}
}
