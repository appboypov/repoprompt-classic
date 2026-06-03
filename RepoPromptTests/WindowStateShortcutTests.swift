import XCTest
@testable import RepoPrompt

@MainActor
final class WindowStateShortcutTests: XCTestCase {
	func testCloseActiveComposeTabFromShortcutStashesActiveAgentTab() async {
		let windowState = WindowState()

		let workspaceReady = await waitForCondition(timeoutSeconds: 5.0) {
			windowState.workspaceManager.isInitialized && windowState.workspaceManager.activeWorkspace != nil
		}
		XCTAssertTrue(workspaceReady, "Expected WindowState workspace initialization to complete")

		if windowState.promptManager.activeComposeTabID == nil {
			_ = await windowState.promptManager.ensureActiveComposeTab(nil)
		}
		guard let initialTabID = windowState.promptManager.activeComposeTabID else {
			return XCTFail("Expected an initial active compose tab")
		}

		let initialComposeCount = windowState.promptManager.composeTabCount
		let initialStashedCount = windowState.promptManager.currentStashedTabs.count

		await windowState.promptManager.createBlankComposeTab(createAgentSession: true)
		guard let activeTabID = windowState.promptManager.activeComposeTabID,
			activeTabID != initialTabID else {
			return XCTFail("Expected a second active compose tab")
		}
		guard let activeAgentSessionID = windowState.promptManager.currentComposeTabs
			.first(where: { $0.id == activeTabID })?
			.activeAgentSessionID else {
			return XCTFail("Expected the active tab to be backed by an agent session")
		}

		XCTAssertEqual(windowState.promptManager.composeTabCount, initialComposeCount + 1)
		XCTAssertEqual(windowState.promptManager.currentStashedTabs.count, initialStashedCount)

		windowState.closeActiveComposeTabFromShortcut()

		let didStash = await waitForCondition(timeoutSeconds: 2.0) {
			windowState.promptManager.composeTabCount == initialComposeCount
				&& windowState.promptManager.currentStashedTabs.count == initialStashedCount + 1
				&& !windowState.promptManager.currentComposeTabs.contains(where: { $0.id == activeTabID })
		}
		XCTAssertTrue(didStash, "Expected Cmd+W shortcut behavior to stash the active tab")
		XCTAssertFalse(windowState.promptManager.currentComposeTabs.contains(where: { $0.id == activeTabID }))

		guard let stashedTab = windowState.promptManager.currentStashedTabs.first(where: { $0.tab.id == activeTabID }) else {
			return XCTFail("Expected the closed tab to appear in stashed tabs")
		}
		XCTAssertEqual(stashedTab.tab.activeAgentSessionID, activeAgentSessionID)
	}

	private func waitForCondition(
		timeoutSeconds: TimeInterval,
		pollIntervalNanoseconds: UInt64 = 10_000_000,
		condition: @escaping @MainActor () -> Bool
	) async -> Bool {
		let deadline = Date().addingTimeInterval(timeoutSeconds)
		while Date() < deadline {
			if condition() {
				return true
			}
			try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
		}
		return condition()
	}
}
