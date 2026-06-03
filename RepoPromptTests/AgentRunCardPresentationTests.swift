import Foundation
import XCTest
@testable import RepoPrompt

final class AgentRunCardPresentationTests: XCTestCase {
	func testPresentationUsesSemanticStatusAndWorkflowInSubtitle() throws {
		let sessionID = UUID()
		let args = try makeArgs(
			op: "start",
			sessionID: sessionID,
			sessionName: "Child Session",
			agent: "codexExec",
			model: "gpt-5.4",
			reasoningEffort: "high",
			workflowName: "Review"
		)
		let presentation = AgentRunCardPresentation(
			resultObject: [
				"status": "running",
				"assistant_text": "Working through the task"
			],
			args: args
		)

		XCTAssertEqual(presentation?.sessionID, sessionID)
		XCTAssertEqual(presentation?.visualStatus, .running)
		XCTAssertEqual(presentation?.subtitle, "Still Running • Review • Child Session • codexExec • gpt-5.4 • reasoning high")
		XCTAssertEqual(presentation?.detailText, "Working through the task")
	}

	func testPresentationPrefersInteractionPromptWhileWaitingForInput() throws {
		let args = try makeArgs(op: "wait", sessionID: UUID())
		let presentation = AgentRunCardPresentation(
			resultObject: [
				"status": "waiting_for_input",
				"session": ["name": "Child Session"],
				"agent": [
					"name": "Codex",
					"id": "codexExec",
					"model": "gpt-5.4",
					"reasoning_effort": "medium"
				],
				"interaction": [
					"kind": "approval",
					"prompt": "Approve the command?"
				],
				"_meta": [
					"delivery": "queued_follow_up"
				]
			],
			args: args
		)

		XCTAssertEqual(presentation?.visualStatus, .warning)
		XCTAssertEqual(presentation?.subtitle, "Needs Input • Child Session • Codex • gpt-5.4 • reasoning medium • approval needed")
		XCTAssertEqual(presentation?.detailText, "Approve the command?")
	}

	func testPresentationUsesDeliveryExplanationWhenRunningWithoutPromptOrNote() throws {
		let presentation = AgentRunCardPresentation(
			resultObject: [
				"status": "running",
				"_meta": [
					"delivery": "queued_claude_interrupt"
				]
			]
		)

		XCTAssertEqual(presentation?.visualStatus, .running)
		XCTAssertEqual(presentation?.detailText, "Queued for Claude and requested an interrupt at the next decision point.")
	}

	func testPresentationUsesExploreOpOverrideForWaitStatus() throws {
		let presentation = AgentRunCardPresentation(
			resultObject: [
				"status": "running",
				"session": ["name": "Explore Child"],
				"agent": ["name": "Explore"]
			],
			args: nil,
			opOverride: "wait"
		)

		XCTAssertEqual(presentation?.visualStatus, .neutral)
		XCTAssertEqual(presentation?.subtitle, "Still Running • Explore Child • Explore")
	}

	func testPresentationFallsBackToSessionIDWithoutSessionName() throws {
		let sessionID = UUID()
		let args = try makeArgs(op: "wait", sessionID: sessionID)
		let presentation = AgentRunCardPresentation(
			resultObject: [
				"status": "completed",
				"assistant_text": "hello world"
			],
			args: args
		)

		XCTAssertEqual(presentation?.subtitle, "Run Complete • \(sessionID.uuidString)")
		XCTAssertNil(presentation?.detailText)
	}

	private func makeArgs(
		op: String,
		sessionID: UUID? = nil,
		sessionName: String? = nil,
		agent: String? = nil,
		model: String? = nil,
		reasoningEffort: String? = nil,
		workflowName: String? = nil
	) throws -> ToolArgsDTOs.AgentRunArgs {
		var object: [String: Any] = ["op": op]
		if let sessionID {
			object["session_id"] = sessionID.uuidString
		}
		if let sessionName {
			object["session_name"] = sessionName
		}
		if let agent {
			object["agent"] = agent
		}
		if let model {
			object["model"] = model
		}
		if let reasoningEffort {
			object["reasoning_effort"] = reasoningEffort
		}
		if let workflowName {
			object["workflow_name"] = workflowName
		}
		let data = try JSONSerialization.data(withJSONObject: object)
		return try JSONDecoder().decode(ToolArgsDTOs.AgentRunArgs.self, from: data)
	}
}
