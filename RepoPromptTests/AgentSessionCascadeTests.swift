import Foundation
import XCTest
@testable import RepoPrompt

@MainActor
final class AgentSessionCascadeTests: XCTestCase {
	func testStashingParentSessionAlsoStashesLiveChildren() async {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }

		let parentTabID = UUID()
		let childTabID = UUID()
		let windowState = makeWindowState(
			root: tempRoot,
			composeTabs: [
				ComposeTabState(id: parentTabID, name: "Parent", lastModified: Date(timeIntervalSince1970: 100)),
				ComposeTabState(id: childTabID, name: "Child", lastModified: Date(timeIntervalSince1970: 200))
			],
			activeComposeTabID: parentTabID
		)
		defer { Task { await windowState.tearDown() } }

		let agentModeVM = windowState.agentModeViewModel
		let promptManager = windowState.promptManager
		guard let parentSessionID = agentModeVM.test_mcpSpawnParentSessionID(sourceTabID: parentTabID) else {
			return XCTFail("Expected parent session ID")
		}
		agentModeVM.test_applySpawnParentSessionID(parentSessionID, tabID: childTabID)

		await promptManager.stashTab(parentTabID)

		let stashedTabIDs = Set(promptManager.currentStashedTabs.map(\.tab.id))
		XCTAssertTrue(stashedTabIDs.contains(parentTabID), "stashed tab IDs: \(stashedTabIDs)")
		XCTAssertTrue(stashedTabIDs.contains(childTabID), "stashed tab IDs: \(stashedTabIDs)")
		XCTAssertFalse(promptManager.currentComposeTabs.contains(where: { $0.id == parentTabID }))
		XCTAssertFalse(promptManager.currentComposeTabs.contains(where: { $0.id == childTabID }))
	}

	func testDeletingLiveParentSessionAlsoDeletesArchivedChildren() async {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }

		let parentTabID = UUID()
		let childTabID = UUID()
		let archivedChildTabID = UUID()
		let archivedChildStashID = UUID()
		let archivedChildSessionID = UUID()
		let windowState = makeWindowState(
			root: tempRoot,
			composeTabs: [
				ComposeTabState(id: parentTabID, name: "Parent", lastModified: Date(timeIntervalSince1970: 100)),
				ComposeTabState(id: childTabID, name: "Child", lastModified: Date(timeIntervalSince1970: 200))
			],
			stashedTabs: [
				StashedTab(
					id: archivedChildStashID,
					tab: ComposeTabState(
						id: archivedChildTabID,
						name: "Archived Child",
						lastModified: Date(timeIntervalSince1970: 300),
						activeAgentSessionID: archivedChildSessionID
					)
				)
			],
			activeComposeTabID: parentTabID
		)
		defer { Task { await windowState.tearDown() } }

		let agentModeVM = windowState.agentModeViewModel
		let promptManager = windowState.promptManager
		guard let parentSessionID = agentModeVM.test_mcpSpawnParentSessionID(sourceTabID: parentTabID) else {
			return XCTFail("Expected parent session ID")
		}
		agentModeVM.test_applySpawnParentSessionID(parentSessionID, tabID: childTabID)
		agentModeVM.test_seedSessionIndexEntry(
			sessionID: archivedChildSessionID,
			tabID: archivedChildTabID,
			parentSessionID: parentSessionID
		)

		await promptManager.closeComposeTab(parentTabID)

		XCTAssertFalse(promptManager.currentComposeTabs.contains(where: { $0.id == parentTabID }))
		XCTAssertFalse(promptManager.currentComposeTabs.contains(where: { $0.id == childTabID }))
		XCTAssertFalse(promptManager.currentStashedTabs.contains(where: { $0.id == archivedChildStashID }))
	}

	func testDeletingArchivedParentSessionAlsoDeletesLiveChildren() async {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }

		let survivorTabID = UUID()
		let childTabID = UUID()
		let parentTabID = UUID()
		let parentStashID = UUID()
		let parentSessionID = UUID()
		let windowState = makeWindowState(
			root: tempRoot,
			composeTabs: [
				ComposeTabState(id: survivorTabID, name: "Survivor", lastModified: Date(timeIntervalSince1970: 50)),
				ComposeTabState(id: childTabID, name: "Child", lastModified: Date(timeIntervalSince1970: 200))
			],
			stashedTabs: [
				StashedTab(
					id: parentStashID,
					tab: ComposeTabState(
						id: parentTabID,
						name: "Archived Parent",
						lastModified: Date(timeIntervalSince1970: 100),
						activeAgentSessionID: parentSessionID
					)
				)
			],
			activeComposeTabID: survivorTabID
		)
		defer { Task { await windowState.tearDown() } }

		let agentModeVM = windowState.agentModeViewModel
		let promptManager = windowState.promptManager
		agentModeVM.test_applySpawnParentSessionID(parentSessionID, tabID: childTabID)

		await promptManager.deleteStashedTab(parentStashID)

		XCTAssertTrue(
			promptManager.currentComposeTabs.contains(where: { $0.id == survivorTabID }),
			"compose tab IDs: \(promptManager.currentComposeTabs.map(\.id))"
		)
		XCTAssertFalse(promptManager.currentComposeTabs.contains(where: { $0.id == childTabID }))
		XCTAssertFalse(promptManager.currentStashedTabs.contains(where: { $0.id == parentStashID }))
	}

	private func makeWindowState(
		root: URL,
		composeTabs: [ComposeTabState],
		stashedTabs: [StashedTab] = [],
		activeComposeTabID: UUID? = nil
	) -> WindowState {
		let windowState = WindowState()
		var workspace = WorkspaceModel(
			name: "Agent Session Cascade Tests",
			repoPaths: [],
			customStoragePath: root,
			composeTabs: composeTabs,
			activeComposeTabID: activeComposeTabID ?? composeTabs.first?.id
		)
		workspace.stashedTabs = stashedTabs
		windowState.workspaceManager.workspaces = [workspace]
		windowState.workspaceManager.activeWorkspace = workspace
		windowState.promptManager.loadComposeTabsFromWorkspace(workspace)
		windowState.promptManager.loadStashedTabsFromWorkspace(workspace)
		return windowState
	}

	private func makeTempDirectory() -> URL {
		let base = FileManager.default.temporaryDirectory
		let dir = base.appendingPathComponent("RepoPrompt-AgentSessionCascadeTests-\(UUID().uuidString)", isDirectory: true)
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir
	}
}
