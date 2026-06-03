//
//  MCPPromptRegistryTests.swift
//  RepoPromptTests
//

import XCTest
import MCP
@testable import RepoPrompt

final class MCPPromptRegistryTests: XCTestCase {
	func testListPromptsIncludesOrchestrate() {
		let promptNames = MCPPromptRegistry.listPrompts().map(\.name)

		XCTAssertTrue(promptNames.contains("rp-orchestrate"))
		XCTAssertEqual(promptNames.last, "rp-orchestrate", "Append new prompts to preserve existing order")
	}

	func testGetOrchestratePromptWithoutArgumentsDoesNotThrow() throws {
		let result = try MCPPromptRegistry.getPrompt(named: "rp-orchestrate", arguments: nil)
		let text = try promptText(from: result)

		XCTAssertTrue(text.contains("MCP Orchestrator"))
		XCTAssertFalse(text.hasPrefix("---"), "MCP prompt text should not expose managed-skill YAML frontmatter")
	}

	func testGetOrchestratePromptContainsAgentRunGuidance() throws {
		let result = try MCPPromptRegistry.getPrompt(named: "rp-orchestrate", arguments: nil)
		let text = try promptText(from: result)

		XCTAssertTrue(text.contains("agent_run"))
		XCTAssertTrue(text.localizedCaseInsensitiveContains("decompose"))
		XCTAssertTrue(text.localizedCaseInsensitiveContains("delegate"))
	}

	private func promptText(from result: GetPrompt.Result) throws -> String {
		let message = try XCTUnwrap(result.messages.first)
		return try XCTUnwrap(
			firstTextString(in: message),
			"Expected a user text prompt message"
		)
	}

	private func firstTextString(in value: Any, depth: Int = 0) -> String? {
		guard depth < 8 else { return nil }

		if let string = value as? String {
			return string
		}

		let mirror = Mirror(reflecting: value)
		if mirror.displayStyle == .optional {
			guard let wrapped = mirror.children.first?.value else { return nil }
			return firstTextString(in: wrapped, depth: depth + 1)
		}

		for child in mirror.children where child.label == "text" {
			if let string = child.value as? String {
				return string
			}
		}

		for child in mirror.children {
			if let string = firstTextString(in: child.value, depth: depth + 1) {
				return string
			}
		}
		return nil
	}
}
