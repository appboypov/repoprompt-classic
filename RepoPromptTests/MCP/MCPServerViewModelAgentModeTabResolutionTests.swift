import XCTest
@testable import RepoPrompt

@MainActor
final class MCPServerViewModelAgentModeTabResolutionTests: XCTestCase {
	func testResolveExplicitTabIDForAgentModeReturnsNilWhenNotProvided() throws {
		let result = try MCPServerViewModel.resolveExplicitTabIDForAgentMode(
			rawTabID: nil,
			availableTabIDs: []
		)

		XCTAssertNil(result)
	}

	func testResolveExplicitTabIDForAgentModeThrowsForInvalidUUID() {
		XCTAssertThrowsError(
			try MCPServerViewModel.resolveExplicitTabIDForAgentMode(
				rawTabID: "not-a-uuid",
				availableTabIDs: []
			)
		) { error in
			let message = String(describing: error)
			XCTAssertTrue(message.contains("Invalid _tabID"))
		}
	}

	func testResolveExplicitTabIDForAgentModeThrowsWhenTabDoesNotExist() {
		let tabID = UUID(uuidString: "00000000-0000-0000-0000-0000000000F1")!
		XCTAssertThrowsError(
			try MCPServerViewModel.resolveExplicitTabIDForAgentMode(
				rawTabID: tabID.uuidString,
				availableTabIDs: []
			)
		) { error in
			let message = String(describing: error)
			XCTAssertTrue(message.contains("Tab not found"))
		}
	}

	func testResolveExplicitTabIDForAgentModeReturnsTabIDWhenAvailable() throws {
		let tabID = UUID(uuidString: "00000000-0000-0000-0000-0000000000F2")!

		let result = try MCPServerViewModel.resolveExplicitTabIDForAgentMode(
			rawTabID: tabID.uuidString,
			availableTabIDs: [tabID]
		)

		XCTAssertEqual(result, tabID)
	}

	func testLiveConnectionIDReturnsNilWhenRunHasNoMapping() {
		let runID = UUID()
		let result = MCPServerViewModel.test_liveConnectionID(
			forRunID: runID,
			connectionIDByRunID: [:],
			connectionIDToRunID: [:]
		)

		XCTAssertNil(result)
	}

	func testLiveConnectionIDReturnsNilWhenOnlyHistoricalReverseMappingExists() {
		let runID = UUID()
		let staleConnectionID = UUID()

		let result = MCPServerViewModel.test_liveConnectionID(
			forRunID: runID,
			connectionIDByRunID: [runID: staleConnectionID],
			connectionIDToRunID: [:]
		)

		XCTAssertNil(result)
	}

	func testLiveConnectionIDReturnsConnectionWhenBidirectionalMappingIsConsistent() {
		let runID = UUID()
		let connectionID = UUID()

		let result = MCPServerViewModel.test_liveConnectionID(
			forRunID: runID,
			connectionIDByRunID: [runID: connectionID],
			connectionIDToRunID: [connectionID: runID]
		)

		XCTAssertEqual(result, connectionID)
	}

	func testManagerRunIDFallbackRegistersActiveToolLivenessWhenVMLocalMappingIsMissing() async {
		let windowState = WindowState()
		addTeardownBlock {
			await windowState.tearDown()
		}
		let mcpServer = windowState.mcpServer
		let connectionID = UUID()
		let runID = UUID()
		addTeardownBlock {
			await ServerNetworkManager.shared.cleanupRunRoutingState(for: runID)
			await ServerNetworkManager.shared.debugRemoveConnection(connectionID)
		}

		await ServerNetworkManager.shared.cleanupRunRoutingState(for: runID)
		await ServerNetworkManager.shared.debugSeedConnectionRunRouting(
			connectionID: connectionID,
			runID: runID,
			windowID: windowState.windowID
		)

		XCTAssertNil(mcpServer.connectionID(forRunID: runID), "Precondition: VM-local mapping should be empty")

		let metadata = MCPServerViewModel.RequestMetadata(
			connectionID: connectionID,
			clientName: "codex-test",
			windowID: windowState.windowID
		)
		let begun = await mcpServer.test_beginResolvedToolExecution(
			metadata: metadata,
			execContext: .live
		)

		XCTAssertEqual(begun?.runID, runID)
		XCTAssertTrue(mcpServer.hasActiveToolExecutions(runID: runID))

		if let executionID = begun?.executionID {
			mcpServer.test_endToolExecution(executionID: executionID)
		}
		XCTAssertFalse(mcpServer.hasActiveToolExecutions(runID: runID))

	}

	func testDifferentWindowManagerRunIDFallbackIsRejectedForActiveToolLiveness() async {
		let windowState = WindowState()
		addTeardownBlock {
			await windowState.tearDown()
		}
		let mcpServer = windowState.mcpServer
		let connectionID = UUID()
		let runID = UUID()
		let otherWindowID = windowState.windowID + 10_000
		addTeardownBlock {
			await ServerNetworkManager.shared.cleanupRunRoutingState(for: runID)
			await ServerNetworkManager.shared.debugRemoveConnection(connectionID)
		}

		await ServerNetworkManager.shared.cleanupRunRoutingState(for: runID)
		await ServerNetworkManager.shared.debugSeedConnectionRunRouting(
			connectionID: connectionID,
			runID: runID,
			windowID: otherWindowID
		)

		let metadata = MCPServerViewModel.RequestMetadata(
			connectionID: connectionID,
			clientName: "codex-test",
			windowID: windowState.windowID
		)
		let begun = await mcpServer.test_beginResolvedToolExecution(
			metadata: metadata,
			execContext: .live
		)

		XCTAssertNil(begun)
		XCTAssertFalse(mcpServer.hasActiveToolExecutions(runID: runID))

	}

	func testVirtualRunIDPathRegistersActiveToolLivenessAndSeedsLocalMapping() async {
		let windowState = WindowState()
		addTeardownBlock {
			await windowState.tearDown()
		}
		let mcpServer = windowState.mcpServer
		let connectionID = UUID()
		let runID = UUID()
		let metadata = MCPServerViewModel.RequestMetadata(
			connectionID: connectionID,
			clientName: "codex-test",
			windowID: windowState.windowID
		)

		let begun = await mcpServer.test_beginResolvedToolExecution(
			metadata: metadata,
			execContext: .virtual(makeTabScopedContext(windowID: windowState.windowID, runID: runID))
		)

		XCTAssertEqual(begun?.runID, runID)
		XCTAssertEqual(mcpServer.connectionID(forRunID: runID), connectionID)
		XCTAssertTrue(mcpServer.hasActiveToolExecutions(runID: runID))

		if let executionID = begun?.executionID {
			mcpServer.test_endToolExecution(executionID: executionID)
		}
		XCTAssertFalse(mcpServer.hasActiveToolExecutions(runID: runID))
	}

	func testAgentExternalControlToolsDoNotRegisterAsRunOwnedActiveTools() async {
		let windowState = WindowState()
		addTeardownBlock {
			await windowState.tearDown()
		}
		let mcpServer = windowState.mcpServer
		let connectionID = UUID()
		let runID = UUID()
		let metadata = MCPServerViewModel.RequestMetadata(
			connectionID: connectionID,
			clientName: "rp-cli-debug",
			windowID: windowState.windowID
		)

		for toolName in ["agent_run", "agent_explore"] {
			let begun = await mcpServer.test_beginResolvedToolExecution(
				metadata: metadata,
				execContext: .virtual(makeTabScopedContext(windowID: windowState.windowID, runID: runID)),
				toolName: toolName
			)

			XCTAssertNil(begun, "\(toolName) should be treated as external control-plane work")
			XCTAssertEqual(mcpServer.connectionID(forRunID: runID), connectionID)
			XCTAssertFalse(mcpServer.hasActiveToolExecutions(runID: runID))
		}
	}

	func testCancelActiveToolsForConnectionOnlyCancelsMatchingExecutions() async {
		let windowState = WindowState()
		addTeardownBlock {
			await windowState.tearDown()
		}
		let mcpServer = windowState.mcpServer
		let connectionA = UUID()
		let connectionB = UUID()
		let runA = UUID()
		let runB = UUID()
		var cancelled: [String] = []

		let metadataA = MCPServerViewModel.RequestMetadata(
			connectionID: connectionA,
			clientName: "client-a",
			windowID: windowState.windowID
		)
		let metadataB = MCPServerViewModel.RequestMetadata(
			connectionID: connectionB,
			clientName: "client-b",
			windowID: windowState.windowID
		)

		let begunA = await mcpServer.test_beginResolvedToolExecution(
			metadata: metadataA,
			execContext: .virtual(makeTabScopedContext(windowID: windowState.windowID, runID: runA)),
			toolName: "context_builder",
			cancel: { cancelled.append("a") }
		)
		let begunB = await mcpServer.test_beginResolvedToolExecution(
			metadata: metadataB,
			execContext: .virtual(makeTabScopedContext(windowID: windowState.windowID, runID: runB)),
			toolName: "context_builder",
			cancel: { cancelled.append("b") }
		)

		XCTAssertNotNil(begunA)
		XCTAssertNotNil(begunB)
		let cancelledCount = mcpServer.cancelActiveToolsForConnection(connectionID: connectionA, reason: "test")

		XCTAssertEqual(cancelledCount, 1)
		XCTAssertEqual(cancelled, ["a"])
		XCTAssertFalse(mcpServer.hasActiveToolExecutions(runID: runA))
		XCTAssertTrue(mcpServer.hasActiveToolExecutions(runID: runB))

		if let executionID = begunB?.executionID {
			mcpServer.test_endToolExecution(executionID: executionID)
		}
	}

	func testLegacyActiveSlotCancellationRespectsConnectionOwnership() async {
		let windowState = WindowState()
		addTeardownBlock {
			await windowState.tearDown()
		}
		let mcpServer = windowState.mcpServer
		let ownerConnection = UUID()
		let otherConnection = UUID()
		var cancelCount = 0

		mcpServer.test_setActiveToolSlot(
			toolName: "context_builder",
			connectionID: ownerConnection,
			cancel: { cancelCount += 1 }
		)

		XCTAssertEqual(mcpServer.cancelActiveToolsForConnection(connectionID: otherConnection, reason: "test"), 0)
		XCTAssertEqual(cancelCount, 0)
		XCTAssertEqual(mcpServer.activeToolName, "context_builder")
		XCTAssertEqual(mcpServer.test_activeToolConnectionID(), ownerConnection)

		XCTAssertEqual(mcpServer.cancelActiveToolsForConnection(connectionID: ownerConnection, reason: "test"), 1)
		XCTAssertEqual(cancelCount, 1)
		XCTAssertNil(mcpServer.activeToolName)
		XCTAssertNil(mcpServer.test_activeToolConnectionID())
	}

	func testStaleDisconnectCleanupDoesNotCancelNewerSameNameToolFromDifferentConnection() async {
		let windowState = WindowState()
		addTeardownBlock {
			await windowState.tearDown()
		}
		let mcpServer = windowState.mcpServer
		let staleConnection = UUID()
		let newerConnection = UUID()
		var newerCancelCount = 0

		await ServerNetworkManager.shared.debugMarkActiveToolOwner(
			windowID: windowState.windowID,
			connectionID: staleConnection,
			toolName: "context_builder"
		)
		mcpServer.test_setActiveToolSlot(
			toolName: "context_builder",
			connectionID: newerConnection,
			cancel: { newerCancelCount += 1 }
		)

		let cancelledCount = await ServerNetworkManager.shared.debugCancelActiveToolsOwnedByConnection(
			staleConnection,
			assignedWindowID: windowState.windowID,
			reason: "stale-disconnect-test"
		)

		XCTAssertEqual(cancelledCount, 0)
		XCTAssertEqual(newerCancelCount, 0)
		XCTAssertEqual(mcpServer.activeToolName, "context_builder")
		XCTAssertEqual(mcpServer.test_activeToolConnectionID(), newerConnection)

		XCTAssertEqual(mcpServer.cancelActiveToolsForConnection(connectionID: newerConnection, reason: "cleanup"), 1)
	}

	private func makeTabScopedContext(
		windowID: Int,
		runID: UUID
	) -> MCPServerViewModel.TabScopedContext {
		MCPServerViewModel.TabScopedContext(
			tabID: UUID(),
			windowID: windowID,
			workspaceID: nil,
			promptText: "",
			selection: StoredSelection(),
			selectedMetaPromptIDs: [],
			tabName: "Test Tab",
			runID: runID,
			explicitlyBound: false
		)
	}
}
