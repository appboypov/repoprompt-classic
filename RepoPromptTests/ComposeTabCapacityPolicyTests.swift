import Foundation
import XCTest
import MCP
@testable import RepoPrompt

@MainActor
final class ComposeTabCapacityPolicyTests: XCTestCase {
	func testDefaultBackgroundCreationRespectsSoftLimitOfFifty() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let tabs = makeComposeTabs(count: 50)
		let windowState = await makeWindowState(root: tempRoot, composeTabs: tabs, activeComposeTabID: tabs[0].id)
		defer { Task { await windowState.tearDown() } }
		let promptManager = windowState.promptManager

		XCTAssertEqual(promptManager.composeTabLimit, 50)
		let createdTab = await promptManager.createBackgroundComposeTab(strategy: .blank, name: "Default Background")

		XCTAssertNotNil(createdTab)
		XCTAssertEqual(promptManager.composeTabCount, 50)
		XCTAssertEqual(promptManager.currentStashedTabs.count, 1)
		XCTAssertEqual(promptManager.currentStashedTabs.first?.tab.id, tabs[1].id)
	}

	func testMCPBackgroundAgentPolicyCanExceedUISoftLimitWithoutStashing() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let tabs = makeComposeTabs(count: 50)
		let windowState = await makeWindowState(root: tempRoot, composeTabs: tabs, activeComposeTabID: tabs[0].id)
		defer { Task { await windowState.tearDown() } }
		let promptManager = windowState.promptManager

		let createdTab = await promptManager.createBackgroundComposeTab(
			strategy: .blank,
			name: "MCP Background",
			capacityPolicy: .mcpBackgroundAgent
		)

		XCTAssertNotNil(createdTab)
		XCTAssertEqual(promptManager.composeTabLimit, 50)
		XCTAssertEqual(promptManager.composeTabCount, 51)
		XCTAssertTrue(promptManager.currentStashedTabs.isEmpty)
		XCTAssertTrue(promptManager.currentComposeTabs.contains(where: { $0.id == createdTab?.id }))
	}

	func testAutomaticStashingDoesNotSelectRunningProtectedAgentSession() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let tabs = makeComposeTabs(count: 50)
		let activeTabID = tabs[0].id
		let protectedTabID = tabs[1].id
		let expectedStashedTabID = tabs[2].id
		let windowState = await makeWindowState(root: tempRoot, composeTabs: tabs, activeComposeTabID: activeTabID)
		defer { Task { await windowState.tearDown() } }
		let agentModeVM = windowState.agentModeViewModel
		let promptManager = windowState.promptManager
		agentModeVM.ensureSession(for: protectedTabID)
		agentModeVM.setAgentRunActive(protectedTabID, isActive: true)

		let createdTab = await promptManager.createBackgroundComposeTab(strategy: .blank, name: "Default Background")

		XCTAssertNotNil(createdTab)
		XCTAssertEqual(promptManager.composeTabCount, 50)
		XCTAssertTrue(promptManager.currentComposeTabs.contains(where: { $0.id == protectedTabID }))
		XCTAssertNotNil(agentModeVM.sessions[protectedTabID])
		XCTAssertFalse(promptManager.currentStashedTabs.contains(where: { $0.tab.id == protectedTabID }))
		XCTAssertEqual(promptManager.currentStashedTabs.first?.tab.id, expectedStashedTabID)
	}

	func testSidebarPolicyBatchArchiveSkipsActiveAndIneligibleTabs() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let tabs = makeComposeTabs(count: 4)
		let activeTabID = tabs[0].id
		let protectedTabID = tabs[1].id
		let windowState = await makeWindowState(root: tempRoot, composeTabs: tabs, activeComposeTabID: activeTabID)
		defer { Task { await windowState.tearDown() } }
		let promptManager = windowState.promptManager
		promptManager.composeTabAutoStashEligibilityProvider = { tabID in
			tabID != protectedTabID
		}

		let archivedTabIDs = await promptManager.autoArchiveComposeTabsForSidebarPolicy(
			withIDs: Set(tabs.map(\.id))
		)

		XCTAssertEqual(archivedTabIDs, [tabs[2].id, tabs[3].id])
		XCTAssertEqual(Set(promptManager.currentComposeTabs.map(\.id)), [activeTabID, protectedTabID])
		XCTAssertEqual(Set(promptManager.currentStashedTabs.map { $0.tab.id }), [tabs[2].id, tabs[3].id])
	}

	func testSidebarPolicyBatchArchiveSkipsRootWhenCascadeChildIsIneligible() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let tabs = makeComposeTabs(count: 3)
		let parentTabID = tabs[1].id
		let childTabID = tabs[2].id
		let windowState = await makeWindowState(root: tempRoot, composeTabs: tabs, activeComposeTabID: tabs[0].id)
		defer { Task { await windowState.tearDown() } }
		let promptManager = windowState.promptManager
		promptManager.composeTabCascadeResolver = { _, _ in
			PromptViewModel.AgentSessionCascadePlan(composeTabIDs: [childTabID])
		}
		promptManager.composeTabAutoStashEligibilityProvider = { tabID in
			tabID != childTabID
		}

		let archivedTabIDs = await promptManager.autoArchiveComposeTabsForSidebarPolicy(withIDs: [parentTabID])

		XCTAssertTrue(archivedTabIDs.isEmpty)
		XCTAssertEqual(Set(promptManager.currentComposeTabs.map(\.id)), Set(tabs.map(\.id)))
		XCTAssertTrue(promptManager.currentStashedTabs.isEmpty)
	}

	func testSidebarPolicyBatchArchiveAppliesValidatedAffectedIDsWithoutFinalCascadeExpansion() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let tabs = makeComposeTabs(count: 3)
		let parentTabID = tabs[1].id
		let childTabID = tabs[2].id
		let windowState = await makeWindowState(root: tempRoot, composeTabs: tabs, activeComposeTabID: tabs[0].id)
		defer { Task { await windowState.tearDown() } }
		let promptManager = windowState.promptManager
		let cascadeProbe = SidebarCascadeMutationProbe(childTabID: childTabID)
		promptManager.composeTabCascadeResolver = { _, _ in
			await cascadeProbe.nextPlan()
		}

		let archivedTabIDs = await promptManager.autoArchiveComposeTabsForSidebarPolicy(withIDs: [parentTabID])

		let cascadeCallCount = await cascadeProbe.callCount
		XCTAssertEqual(archivedTabIDs, [parentTabID])
		XCTAssertEqual(cascadeCallCount, 2)
		XCTAssertEqual(Set(promptManager.currentComposeTabs.map(\.id)), [tabs[0].id, childTabID])
		XCTAssertEqual(Set(promptManager.currentStashedTabs.map { $0.tab.id }), [parentTabID])
	}

	func testBackgroundAgentHardCapFailsClearlyWithoutRemovingProtectedTabs() async throws {
		let restoreHardCap = preserveBackgroundAgentHardCap()
		defer { restoreHardCap() }
		UserDefaults.standard.set(50, forKey: backgroundAgentHardCapKey)

		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let tabs = makeComposeTabs(count: 50)
		let activeTabID = tabs[0].id
		let protectedTabIDs = Set(tabs.dropFirst().map(\.id))
		let windowState = await makeWindowState(root: tempRoot, composeTabs: tabs, activeComposeTabID: activeTabID)
		defer { Task { await windowState.tearDown() } }
		let agentModeVM = windowState.agentModeViewModel
		let promptManager = windowState.promptManager
		for tabID in protectedTabIDs {
			agentModeVM.ensureSession(for: tabID)
			agentModeVM.setAgentRunActive(tabID, isActive: true)
		}

		do {
			_ = try await agentModeVM.mcpResolveOrCreateSessionTarget(
				tabID: nil,
				sessionID: nil,
				createIfNeeded: true,
				sessionName: "At Capacity"
			)
			XCTFail("Expected background agent hard-cap exhaustion")
		} catch let error as MCPError {
			guard case .invalidParams(let message) = error else {
				return XCTFail("Unexpected MCPError: \(error)")
			}
			XCTAssertTrue((message ?? "").contains("Background agent session capacity is full"))
		} catch {
			XCTFail("Unexpected error: \(error)")
		}

		XCTAssertEqual(promptManager.composeTabCount, 50)
		XCTAssertTrue(promptManager.currentStashedTabs.isEmpty)
		let remainingTabIDs = Set(promptManager.currentComposeTabs.map(\.id))
		XCTAssertTrue(protectedTabIDs.isSubset(of: remainingTabIDs))
		for tabID in protectedTabIDs {
			XCTAssertNotNil(agentModeVM.sessions[tabID], "Expected protected session to remain for tab \(tabID)")
		}
	}

	private let backgroundAgentHardCapKey = "agentMode.maxBackgroundAgentComposeTabs"

	private func makeComposeTabs(count: Int) -> [ComposeTabState] {
		(0..<count).map { index in
			ComposeTabState(
				id: UUID(),
				name: "Tab \(index + 1)",
				lastModified: Date(timeIntervalSince1970: TimeInterval(index))
			)
		}
	}

	private func makeWindowState(
		root: URL,
		composeTabs: [ComposeTabState],
		activeComposeTabID: UUID? = nil
	) async -> WindowState {
		let windowState = WindowState()
		await windowState.workspaceManager.awaitInitialized()
		let workspace = WorkspaceModel(
			name: "Compose Tab Capacity Tests",
			repoPaths: [],
			customStoragePath: root,
			composeTabs: composeTabs,
			activeComposeTabID: activeComposeTabID ?? composeTabs.first?.id
		)
		windowState.workspaceManager.workspaces = [workspace]
		windowState.workspaceManager.activeWorkspace = workspace
		windowState.promptManager.loadComposeTabsFromWorkspace(workspace)
		windowState.promptManager.loadStashedTabsFromWorkspace(workspace)
		return windowState
	}

	private func makeTempDirectory() -> URL {
		let base = FileManager.default.temporaryDirectory
		let dir = base.appendingPathComponent("RepoPrompt-ComposeTabCapacityPolicyTests-\(UUID().uuidString)", isDirectory: true)
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir
	}

	private func preserveBackgroundAgentHardCap() -> () -> Void {
		let defaults = UserDefaults.standard
		let key = backgroundAgentHardCapKey
		let previousValue = defaults.object(forKey: key)
		return {
			if let previousValue {
				defaults.set(previousValue, forKey: key)
			} else {
				defaults.removeObject(forKey: key)
			}
		}
	}
}

private actor SidebarCascadeMutationProbe {
	private let childTabID: UUID
	private var calls = 0

	init(childTabID: UUID) {
		self.childTabID = childTabID
	}

	var callCount: Int { calls }

	func nextPlan() -> PromptViewModel.AgentSessionCascadePlan {
		calls += 1
		guard calls >= 3 else { return .init() }
		return PromptViewModel.AgentSessionCascadePlan(composeTabIDs: [childTabID])
	}
}
