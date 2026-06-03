import XCTest
@testable import RepoPrompt

final class ToolCallCardStateResolverTests: XCTestCase {
	func testToolCallWithoutResultStaysRunning() {
		let item = AgentChatItem.toolCall(
			name: "agent_run",
			argsJSON: "{\"op\":\"wait\"}"
		)

		XCTAssertEqual(ToolCallCardStateResolver.status(for: item), .running)
	}

	func testToolCallWithCompletedResultPayloadUsesSemanticRunStatus() {
		var item = AgentChatItem.toolCall(
			name: "agent_run",
			argsJSON: "{\"op\":\"wait\"}"
		)
		item.toolResultJSON = "{\"status\":\"completed\"}"
		item.text = item.toolResultJSON ?? item.text

		XCTAssertEqual(ToolCallCardStateResolver.status(for: item), .success)
	}
}
