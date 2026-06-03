import XCTest
@testable import RepoPrompt

final class MCPRoutingHardeningTests: XCTestCase {
	@MainActor
	func testResolveComposeTabRoutingSnapshotUsesLiveStateForActiveTab() {
		let activeTab = ComposeTabState(name: "Active", promptText: "stored-active")
		let workspace = WorkspaceModel(
			name: "Workspace",
			repoPaths: [],
			composeTabs: [activeTab],
			activeComposeTabID: activeTab.id
		)

		let resolved = WorkspaceManagerViewModel.test_resolveComposeTabRoutingSnapshot(
			for: activeTab.id,
			workspaces: [workspace],
			activeWorkspaceID: workspace.id,
			activeComposeTabID: activeTab.id,
			liveSnapshotProvider: { base in
				var live = base
				live.promptText = "live-active"
				return live
			}
		)

		XCTAssertEqual(resolved?.workspaceID, workspace.id)
		XCTAssertEqual(resolved?.snapshot.promptText, "live-active")
		XCTAssertTrue(resolved?.usesLiveUIState == true)
	}

	@MainActor
	func testResolveComposeTabRoutingSnapshotUsesStoredStateForInactiveWorkspaceTab() {
		let activeTab = ComposeTabState(name: "Active", promptText: "active-stored")
		let inactiveTab = ComposeTabState(name: "Inactive", promptText: "inactive-stored")
		let activeWorkspace = WorkspaceModel(
			name: "Active Workspace",
			repoPaths: [],
			composeTabs: [activeTab],
			activeComposeTabID: activeTab.id
		)
		let inactiveWorkspace = WorkspaceModel(
			name: "Inactive Workspace",
			repoPaths: [],
			composeTabs: [inactiveTab],
			activeComposeTabID: inactiveTab.id
		)

		let resolved = WorkspaceManagerViewModel.test_resolveComposeTabRoutingSnapshot(
			for: inactiveTab.id,
			workspaces: [activeWorkspace, inactiveWorkspace],
			activeWorkspaceID: activeWorkspace.id,
			activeComposeTabID: activeTab.id,
			liveSnapshotProvider: { base in
				var live = base
				live.promptText = "should-not-be-used"
				return live
			}
		)

		XCTAssertEqual(resolved?.workspaceID, inactiveWorkspace.id)
		XCTAssertEqual(resolved?.snapshot.promptText, "inactive-stored")
		XCTAssertFalse(resolved?.usesLiveUIState == true)
	}

	@MainActor
	func testPopPendingContextForBindingDoesNotFallbackWhenRunHintMisses() {
		let queuedRunID = UUID()
		let expectedRunID = UUID()
		var store = MCPServerViewModel.PendingContextStore()
		let queuedContext = MCPServerViewModel.TabScopedContext(
			tabID: UUID(),
			windowID: 7,
			workspaceID: UUID(),
			promptText: "queued",
			selection: .init(),
			selectedMetaPromptIDs: [],
			tabName: "Queued",
			runID: queuedRunID,
			explicitlyBound: false
		)
		_ = store.enqueue(queuedContext, clientName: "codex-mcp-client", windowID: 7)

		let result = MCPServerViewModel.test_popPendingContextForBinding(
			from: &store,
			clientName: "codex-mcp-client",
			windowID: 7,
			runHint: expectedRunID
		)

		XCTAssertNil(result.context)
		XCTAssertEqual(result.remaining, 1)
		XCTAssertFalse(result.usedRunHint)
	}

	@MainActor
	func testPopPendingContextForBindingUsesFIFOWhenRunHintAbsent() {
		var store = MCPServerViewModel.PendingContextStore()
		let firstContext = MCPServerViewModel.TabScopedContext(
			tabID: UUID(),
			windowID: 3,
			workspaceID: UUID(),
			promptText: "first",
			selection: .init(),
			selectedMetaPromptIDs: [],
			tabName: "First",
			runID: UUID(),
			explicitlyBound: false
		)
		let secondContext = MCPServerViewModel.TabScopedContext(
			tabID: UUID(),
			windowID: 3,
			workspaceID: UUID(),
			promptText: "second",
			selection: .init(),
			selectedMetaPromptIDs: [],
			tabName: "Second",
			runID: UUID(),
			explicitlyBound: false
		)
		_ = store.enqueue(firstContext, clientName: "codex-mcp-client", windowID: 3)
		_ = store.enqueue(secondContext, clientName: "codex-mcp-client", windowID: 3)

		let result = MCPServerViewModel.test_popPendingContextForBinding(
			from: &store,
			clientName: "codex-mcp-client",
			windowID: 3,
			runHint: nil
		)

		XCTAssertEqual(result.context?.tabID, firstContext.tabID)
		XCTAssertEqual(result.remaining, 1)
		XCTAssertFalse(result.usedRunHint)
	}

	func testCalculateComponentBreakdownIncludesDuplicatePromptAndMetadata() {
		let breakdown = TokenCalculationService.calculateComponentBreakdown(
			promptText: "bound prompt text",
			selectedInstructionsText: "meta one\n\nmeta two",
			includeDiffFormatting: true,
			xmlFormattingPrompt: "<xml_formatting_instructions>format</xml_formatting_instructions>",
			fileTreeText: "tree",
			gitDiffText: "diff",
			metadataText: "<mcp>tab metadata</mcp>",
			duplicateUserInstructionsAtTop: true
		)

		let promptTokens = TokenCalculationService.estimateTokens(for: "bound prompt text")
		XCTAssertEqual(breakdown.prompt, promptTokens)
		XCTAssertEqual(breakdown.duplicatePrompt, promptTokens)
		XCTAssertEqual(breakdown.instructions, TokenCalculationService.estimateTokens(for: "meta one\n\nmeta two"))
		XCTAssertEqual(breakdown.formatting, TokenCalculationService.estimateTokens(for: "<xml_formatting_instructions>format</xml_formatting_instructions>"))
		XCTAssertEqual(breakdown.fileTree, TokenCalculationService.estimateTokens(for: "tree"))
		XCTAssertEqual(breakdown.gitDiff, TokenCalculationService.estimateTokens(for: "diff"))
		XCTAssertEqual(breakdown.metadata, TokenCalculationService.estimateTokens(for: "<mcp>tab metadata</mcp>"))
	}

	func testMakeTokenStatsUsesSharedBreakdownComponents() {
		let breakdown = TokenComponentBreakdown(
			prompt: 25,
			duplicatePrompt: 25,
			instructions: 30,
			formatting: 5,
			fileTree: 40,
			gitDiff: 10,
			metadata: 15
		)
		let stats = MCPServerViewModel.makeTokenStats(
			filesTokens: 120,
			filesContentTokens: 100,
			codemapsTokens: 20,
			breakdown: breakdown
		)

		XCTAssertEqual(stats.files, 120)
		XCTAssertEqual(stats.filesContent, 100)
		XCTAssertEqual(stats.codemaps, 20)
		XCTAssertEqual(stats.prompt, 50)
		XCTAssertEqual(stats.meta, 30)
		XCTAssertEqual(stats.fileTree, 40)
		XCTAssertEqual(stats.git, 10)
		XCTAssertEqual(stats.other, 20)
		XCTAssertEqual(stats.total, 120 + 50 + 30 + 40 + 10 + 20)
	}

	@MainActor
	func testResolveFileToolLookupRootScopeWidensOnlyForDiscoverRunWithVirtualRunID() {
		let discoverVirtual = MCPServerViewModel.ExecContext.virtual(
			MCPServerViewModel.TabScopedContext(
				tabID: UUID(),
				windowID: 1,
				workspaceID: UUID(),
				promptText: "discover",
				selection: .init(),
				selectedMetaPromptIDs: [],
				tabName: "Discover",
				runID: UUID(),
				explicitlyBound: false
			)
		)
		let widened = MCPServerViewModel.test_resolveFileToolLookupRootScope(
			purpose: .discoverRun,
			execContext: discoverVirtual
		)
		XCTAssertEqual(widened, .visibleWorkspacePlusGitData)
	}

	@MainActor
	func testResolveFileToolLookupRootScopeStaysVisibleWorkspaceOtherwise() {
		let runlessVirtual = MCPServerViewModel.ExecContext.virtual(
			MCPServerViewModel.TabScopedContext(
				tabID: UUID(),
				windowID: 1,
				workspaceID: UUID(),
				promptText: "discover",
				selection: .init(),
				selectedMetaPromptIDs: [],
				tabName: "Discover",
				runID: nil,
				explicitlyBound: false
			)
		)
		XCTAssertEqual(
			MCPServerViewModel.test_resolveFileToolLookupRootScope(
				purpose: .discoverRun,
				execContext: runlessVirtual
			),
			.visibleWorkspace
		)
		XCTAssertEqual(
			MCPServerViewModel.test_resolveFileToolLookupRootScope(
				purpose: .agentModeRun,
				execContext: .live
			),
			.visibleWorkspace
		)
	}

	@MainActor
	func testShouldReuseLastContextForHeadlessAutoBindOnlyForRunlessImplicitContext() {
		let runlessLast = MCPServerViewModel.TabScopedContext(
			tabID: UUID(),
			windowID: 1,
			workspaceID: UUID(),
			promptText: "runless",
			selection: .init(),
			selectedMetaPromptIDs: [],
			tabName: "Runless",
			runID: nil,
			explicitlyBound: false
		)
		let runBoundLast = MCPServerViewModel.TabScopedContext(
			tabID: UUID(),
			windowID: 1,
			workspaceID: UUID(),
			promptText: "run-bound",
			selection: .init(),
			selectedMetaPromptIDs: [],
			tabName: "RunBound",
			runID: UUID(),
			explicitlyBound: false
		)

		XCTAssertTrue(
			MCPServerViewModel.test_shouldReuseLastContextForHeadlessAutoBind(
				runHint: nil,
				lastContext: runlessLast
			)
		)
		XCTAssertFalse(
			MCPServerViewModel.test_shouldReuseLastContextForHeadlessAutoBind(
				runHint: UUID(),
				lastContext: runlessLast
			)
		)
		XCTAssertFalse(
			MCPServerViewModel.test_shouldReuseLastContextForHeadlessAutoBind(
				runHint: nil,
				lastContext: runBoundLast
			)
		)
	}
}
