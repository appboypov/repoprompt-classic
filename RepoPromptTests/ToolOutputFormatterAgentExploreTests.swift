import MCP
import XCTest
@testable import RepoPrompt

final class ToolOutputFormatterAgentExploreTests: XCTestCase {
	func testAgentExploreWaitingForInputDoesNotSuggestUnsupportedRespondOrSteer() throws {
		let text = try renderedText(
			toolName: "agent_explore",
			args: ["op": .string("wait")],
			json: #"{"status":"waiting_for_input","session_id":"075cda44-1111-2222-3333-555555555555","interaction_id":"interaction-1","interaction":{"id":"interaction-1","kind":"question","prompt":"Which area should I inspect?"},"assistant_text":"I found two likely areas."}"#
		)

		XCTAssertTrue(text.contains("**Agent explore · Wait**"))
		XCTAssertTrue(text.contains("### Waiting for input"))
		XCTAssertTrue(text.contains("agent_explore does not support respond"))
		XCTAssertFalse(text.contains("Use `agent_run`"))
		XCTAssertFalse(text.contains("op=respond"))
		XCTAssertFalse(text.contains("not `steer`"))
	}

	func testAgentRunWaitingForInputKeepsRespondGuidance() throws {
		let text = try renderedText(
			toolName: "agent_run",
			args: ["op": .string("wait")],
			json: #"{"status":"waiting_for_input","session_id":"075cda44-1111-2222-3333-444444444444","interaction_id":"interaction-1","interaction":{"id":"interaction-1","kind":"instruction","prompt":"Provide more detail."}}"#
		)

		XCTAssertTrue(text.contains("**Agent run · Wait**"))
		XCTAssertTrue(text.contains("Use `agent_run` with `op=respond`"))
		XCTAssertTrue(text.contains("not `steer`"))
	}

	func testAgentExploreBatchStartEnvelopeUsesExploreHeading() throws {
		let text = try renderedText(
			toolName: "agent_explore",
			args: ["op": .string("start")],
			json: #"{"start":{"mode":"many","result":"detached","started_count":2,"running_session_ids":["11111111-1111-1111-1111-111111111111","22222222-2222-2222-2222-222222222222"],"terminal_session_ids":[],"interesting_session_ids":[]},"session_ids":["11111111-1111-1111-1111-111111111111","22222222-2222-2222-2222-222222222222"],"snapshots":[{"session_id":"11111111-1111-1111-1111-111111111111","status":"running"},{"session_id":"22222222-2222-2222-2222-222222222222","status":"running"}]}"#
		)

		XCTAssertTrue(text.contains("**Agent explore · Start (multiple)**"))
		XCTAssertTrue(text.contains("- Sessions started: 2"))
		XCTAssertTrue(text.contains("- Result: **Detached**"))
		XCTAssertTrue(text.contains("- Running: 2"))
		XCTAssertTrue(text.contains("`11111111-1111-1111-1111-111111111111`"))
		XCTAssertTrue(text.contains("`22222222-2222-2222-2222-222222222222`"))
		XCTAssertFalse(text.contains("`11111111…`"))
		XCTAssertFalse(text.contains("op=respond"))
	}

	func testAgentExploreMultiPollUsesExploreHeading() throws {
		let text = try renderedText(
			toolName: "agent_explore",
			args: ["op": .string("poll")],
			json: #"{"poll":{"mode":"many","polled_count":2,"running_session_ids":["11111111-1111-1111-1111-111111111111"],"terminal_session_ids":["22222222-2222-2222-2222-222222222222"]},"snapshots":[{"session_id":"11111111-1111-1111-1111-111111111111","status":"running"},{"session_id":"22222222-2222-2222-2222-222222222222","status":"completed"}]}"#
		)

		XCTAssertTrue(text.contains("**Agent explore · Poll (multiple)**"))
		XCTAssertTrue(text.contains("- Sessions polled: 2"))
		XCTAssertTrue(text.contains("`11111111-1111-1111-1111-111111111111`"))
		XCTAssertTrue(text.contains("`22222222-2222-2222-2222-222222222222`"))
		XCTAssertFalse(text.contains("`11111111…`"))
	}

	func testAgentRunMultiPollUsesFullSessionIDs() throws {
		let text = try renderedText(
			toolName: "agent_run",
			args: ["op": .string("poll")],
			json: #"{"poll":{"mode":"many","polled_count":2,"running_session_ids":["33333333-3333-3333-3333-333333333333"],"terminal_session_ids":["44444444-4444-4444-4444-444444444444"]},"snapshots":[{"session_id":"33333333-3333-3333-3333-333333333333","status":"running"},{"session_id":"44444444-4444-4444-4444-444444444444","status":"completed"}]}"#
		)

		XCTAssertTrue(text.contains("**Agent run · Poll (multiple)**"))
		XCTAssertTrue(text.contains("`33333333-3333-3333-3333-333333333333`"))
		XCTAssertTrue(text.contains("`44444444-4444-4444-4444-444444444444`"))
		XCTAssertFalse(text.contains("`33333333…`"))
	}

	func testOracleExportBlockReferencesMessageHandoff() throws {
		let text = try renderedText(
			toolName: "ask_oracle",
			args: ["export_response": .bool(true)],
			json: #"{"response":"Plan ready.","oracle_export_path":"prompt-exports/oracle-plan.md","oracle_export_instruction":"Read the Oracle export at prompt-exports/oracle-plan.md with `read_file` and use it as planning context for this task."}"#
		)

		XCTAssertTrue(text.contains("### Oracle export"))
		XCTAssertTrue(text.contains("prompt-exports/oracle-plan.md"))
		XCTAssertTrue(text.contains("include the path inside the `message`"))
		XCTAssertTrue(text.contains("```text"))
		XCTAssertFalse(text.contains("Pass it to delegated agents as"))
		XCTAssertFalse(text.contains("`agent_run` `oracle_export_path`"))
	}

	/// The formatter does not know which delegation tool the caller sees, so it must
	/// NOT name `agent_run` or `agent_explore` directly. Instead, it points back at the
	/// system prompt, which branches on `taskLabelKind` to name the correct tool.
	func testOracleExportBlockDoesNotNameSpecificDelegationTool() throws {
		let text = try renderedText(
			toolName: "ask_oracle",
			args: ["export_response": .bool(true)],
			json: #"{"response":"Plan ready.","oracle_export_path":"prompt-exports/oracle-plan.md","oracle_export_instruction":"Read the Oracle export at prompt-exports/oracle-plan.md with `read_file` and use it as planning context for this task."}"#
		)

		XCTAssertFalse(
			text.contains("agent_run"),
			"oracleExportBlock must not name `agent_run` directly — caller capabilities vary per role."
		)
		XCTAssertFalse(
			text.contains("agent_explore"),
			"oracleExportBlock must not name `agent_explore` directly — caller capabilities vary per role."
		)
		XCTAssertTrue(
			text.contains("your system prompt"),
			"oracleExportBlock should defer tool naming to the system prompt."
		)
	}

	/// The formatter output must not tell the LLM to `paste` anything — LLMs emit text,
	/// they do not paste.
	func testOracleExportBlockDoesNotSayPaste() throws {
		let text = try renderedText(
			toolName: "ask_oracle",
			args: ["export_response": .bool(true)],
			json: #"{"response":"Plan ready.","oracle_export_path":"prompt-exports/oracle-plan.md","oracle_export_instruction":"Read the Oracle export at prompt-exports/oracle-plan.md with `read_file` and use it as planning context for this task."}"#
		)

		let lowered = text.lowercased()
		for verb in [" paste ", "paste it", "paste the", "paste them", " pasted ", " pasting "] {
			XCTAssertFalse(
				lowered.contains(verb),
				"oracleExportBlock must not use the paste verb ('\(verb)')"
			)
		}
	}

	private func renderedText(
		toolName: String,
		args: [String: Value],
		json: String
	) throws -> String {
		let value = try XCTUnwrap(Value.fromJSONString(json))
		let blocks = ToolOutputFormatter.buildContentBlocks(
			toolName: toolName,
			args: args,
			result: value,
			emitResources: false
		)
		let texts = blocks.compactMap { block -> String? in
			guard case .text(let text, _, _) = block else { return nil }
			return text
		}
		guard !texts.isEmpty else {
			throw NSError(
				domain: "ToolOutputFormatterAgentExploreTests",
				code: 1,
				userInfo: [NSLocalizedDescriptionKey: "Expected a text content block"]
			)
		}
		return texts.joined(separator: "\n")
	}
}
