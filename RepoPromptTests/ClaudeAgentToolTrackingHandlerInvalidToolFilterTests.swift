import XCTest
@testable import RepoPrompt

@MainActor
final class ClaudeAgentToolTrackingHandlerInvalidToolFilterTests: XCTestCase {
	private func makeHandler() -> ClaudeAgentToolTrackingHandler {
		ClaudeAgentToolTrackingHandler(hooks: .noOp)
	}

	private func makeSession() -> AgentModeViewModel.TabSession {
		AgentModeViewModel.TabSession(tabID: UUID())
	}

	private func noSuchToolResultJSON(for toolName: String) -> String {
		"<tool_use_error>Error: No such tool available: \(toolName)</tool_use_error>"
	}

	func testInvalidToolErrorResultRemovesPlaceholderAndIsConsumed() {
		let handler = makeHandler()
		let session = makeSession()

		let invalidToolName = "mcp__RepoPrompt"
		let invocationID = UUID()

		// Arrange: provider emitted the tool_call first — the viewmodel would have
		// appended it to session.items before the tool_result arrived.
		let call = AgentToolStreamEvent.ToolCall(
			toolName: invalidToolName,
			invocationID: invocationID,
			argsJSON: nil
		)
		let callConsumed = handler.handleProviderToolEvent(
			.toolCall(call),
			session: session
		)
		// Non-RepoPrompt tools fall through, so the Claude handler doesn't consume
		// the tool_call; the viewmodel would have appended it. Simulate that here
		// so we can verify the filter retracts it on the subsequent error.
		XCTAssertFalse(callConsumed)
		session.appendItem(
			AgentChatItem.toolCall(
				name: invalidToolName,
				invocationID: invocationID,
				argsJSON: nil,
				sequenceIndex: session.nextSequenceIndex
			)
		)
		XCTAssertEqual(session.items.count, 1)

		// Act: error tool_result arrives.
		let result = AgentToolStreamEvent.ToolResult(
			toolName: invalidToolName,
			invocationID: invocationID,
			argsJSON: nil,
			resultJSON: noSuchToolResultJSON(for: invalidToolName),
			isError: true
		)
		let resultConsumed = handler.handleProviderToolEvent(
			.toolResult(result),
			session: session
		)

		// Assert: result consumed (not emitted) and placeholder removed.
		XCTAssertTrue(resultConsumed)
		XCTAssertTrue(session.items.isEmpty)
	}

	func testInvalidToolErrorWithNilIsErrorStillRetractsPlaceholder() {
		// When the Claude translator classifies the name as a RepoPrompt tool it
		// emits `toolIsError = nil` because the tracker owns status. The filter
		// must still match in that case.
		let handler = makeHandler()
		let session = makeSession()

		let invalidToolName = "mcp__RepoPrompt__not_a_real_tool"
		let invocationID = UUID()

		session.appendItem(
			AgentChatItem.toolCall(
				name: invalidToolName,
				invocationID: invocationID,
				argsJSON: nil,
				sequenceIndex: session.nextSequenceIndex
			)
		)

		let result = AgentToolStreamEvent.ToolResult(
			toolName: invalidToolName,
			invocationID: invocationID,
			argsJSON: nil,
			resultJSON: noSuchToolResultJSON(for: invalidToolName),
			isError: nil
		)
		let consumed = handler.handleProviderToolEvent(
			.toolResult(result),
			session: session
		)

		XCTAssertTrue(consumed)
		XCTAssertTrue(session.items.isEmpty)
	}

	func testNormalToolErrorIsNotIntercepted() {
		// A "real" tool_use_error unrelated to the No-Such-Tool path must pass
		// through so downstream handling preserves its row.
		let handler = makeHandler()
		let session = makeSession()

		let toolName = "SomeThirdPartyTool"
		let invocationID = UUID()

		let result = AgentToolStreamEvent.ToolResult(
			toolName: toolName,
			invocationID: invocationID,
			argsJSON: nil,
			resultJSON: "<tool_use_error>Error: command failed</tool_use_error>",
			isError: true
		)
		let consumed = handler.handleProviderToolEvent(
			.toolResult(result),
			session: session
		)

		// Non-RepoPrompt tool with a non-matching error wrapper falls through
		// (not consumed by the Claude handler), letting the generic viewmodel
		// path render it normally.
		XCTAssertFalse(consumed)
	}
}
