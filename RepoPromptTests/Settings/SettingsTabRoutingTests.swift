import XCTest
@testable import RepoPrompt

final class SettingsTabRoutingTests: XCTestCase {
	func testAgentWorkflowsTabMetadata() {
		XCTAssertEqual(SettingsTab.agentWorkflows.title, "Agent Workflows")
		XCTAssertEqual(SettingsTab.agentWorkflows.section, .agentMode)
	}

	func testAgentWorkflowsSearchTagsDoNotRenameCopyChatWorkflowPresets() {
		XCTAssertEqual(SettingsTab.workflowPresets.title, "Workflow Presets")
		XCTAssertEqual(SettingsTab.workflowPresets.section, .copyChat)
		XCTAssertTrue(SettingsTab.agentWorkflows.searchTags.contains("agent mode workflows"))
		XCTAssertTrue(SettingsTab.agentWorkflows.searchTags.contains("cleanup guidance"))
		XCTAssertTrue(SettingsTab.agentWorkflows.searchTags.contains("Workflows folder"))
	}
}
