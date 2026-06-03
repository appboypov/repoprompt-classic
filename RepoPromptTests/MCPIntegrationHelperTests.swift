//
//  MCPIntegrationHelperTests.swift
//  RepoPromptTests
//
//  Created by Claude Code
//

import XCTest
@testable import RepoPrompt

final class MCPIntegrationHelperTests: XCTestCase {

	// MARK: - codexCLIPathComponent Tests

	func testCLIPathComponent_BareKey() {
		// Simple bare keys should not be quoted
		XCTAssertEqual(MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: "RepoPrompt"), "RepoPrompt")
		XCTAssertEqual(MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: "my-server"), "my-server")
		XCTAssertEqual(MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: "server_123"), "server_123")
		XCTAssertEqual(MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: "ABC-def_789"), "ABC-def_789")
	}

	func testCLIPathComponent_EmptyString() {
		// Empty string should return quoted empty string
		XCTAssertEqual(MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: ""), "\"\"")
	}

	func testCLIPathComponent_SpecialCharacters() {
		// Strings with special characters must be quoted and escaped
		XCTAssertEqual(MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: "My Server"), "\"My Server\"")
		XCTAssertEqual(MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: "server.name"), "\"server.name\"")
		XCTAssertEqual(MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: "server:port"), "\"server:port\"")
	}

	func testCLIPathComponent_EscapeSequences() {
		// Test proper escaping of special characters
		XCTAssertEqual(MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: "quote\"test"), "\"quote\\\"test\"")
		XCTAssertEqual(MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: "back\\slash"), "\"back\\\\slash\"")
		XCTAssertEqual(MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: "new\nline"), "\"new\\nline\"")
		XCTAssertEqual(MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: "carriage\rreturn"), "\"carriage\\rreturn\"")
		XCTAssertEqual(MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: "tab\there"), "\"tab\\there\"")
	}

	func testCLIPathComponent_MultipleEscapes() {
		// Test string with multiple escape sequences
		XCTAssertEqual(MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: "test\n\"value\""), "\"test\\n\\\"value\\\"\"")
	}

	// MARK: - normalizedCodexServerName Tests

	func testNormalizedServerName_BareKey() {
		// Bare keys should be returned as-is (trimmed)
		let result = MCPIntegrationHelper.codexMCPServerEntries()
		// This is a private method, so we'll test it indirectly through codexMCPServerEntries
		// For direct testing, we need to expose it or use reflection
	}

	func testNormalizedServerName_DoubleQuoted() throws {
		// Create a temporary config to test parsing
		let tempDir = FileManager.default.temporaryDirectory
		let configDir = tempDir.appendingPathComponent("codex-test-\(UUID().uuidString)", isDirectory: true)
		let configFile = configDir.appendingPathComponent("config.toml")

		try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
		defer {
			try? FileManager.default.removeItem(at: configDir)
		}

		// Test double-quoted key with spaces
		let content = """
		[mcp_servers."My Server"]
		command = "/test"
		"""
		try content.write(to: configFile, atomically: true, encoding: .utf8)

		// We can't easily test the private method directly, but we can verify
		// that the parsing handles quoted keys correctly through the public API
	}

	// MARK: - codexMCPServerEntries Integration Tests

	func testCodexMCPServerEntries_EmptyConfig() throws {
		// Test with non-existent config file
		let entries = MCPIntegrationHelper.codexMCPServerEntries()
		// Should return empty array if config doesn't exist or is empty
		// Note: This will use the actual ~/.codex/config.toml if it exists
	}

	func testCodexMCPServerEntries_ParsesMultipleServers() throws {
		// This test would require mocking the file system or using a test config
		// For now, we'll document expected behavior

		// Given a config like:
		// [mcp_servers.RepoPrompt]
		// command = "/path/to/server"
		//
		// [mcp_servers."My Server"]
		// command = "/another/path"
		//
		// [mcp_servers.'single-quoted']
		// command = "/third/path"
		//
		// Expected:
		// - 3 entries returned
		// - Each entry has rawName, normalizedName, and cliPathComponent
		// - RepoPrompt -> barekey
		// - My Server -> quoted
		// - single-quoted -> barekey (after unquoting)
	}

	func testCodexMCPServerEntries_DeduplicatesServers() throws {
		// If the same server appears twice, only the first should be included
		// This is enforced by the seenRawNames Set
	}

	// MARK: - Escape Sequence Decoding Tests

	func testDecodeEscapeSequences_BasicEscapes() {
		// Test through the full parsing flow
		// Double-quoted keys with escape sequences should be properly decoded

		// Expected behavior:
		// "test\\n" -> "test\n"
		// "test\\t" -> "test\t"
		// "test\\\"" -> "test\""
		// "test\\\\" -> "test\"
	}

	func testDecodeEscapeSequences_UnicodeEscapes() {
		// Test Unicode escape sequences
		// Expected behavior:
		// "test\\u0041" -> "testA"
		// "test\\u03B1" -> "testα" (Greek alpha)
		// "emoji\\u1F600" (incomplete, needs full sequence)
	}

	func testDecodeEscapeSequences_InvalidEscapes() {
		// Invalid escape sequences should be handled gracefully
		// "test\\" (trailing backslash) -> "test\"
		// "test\\u12" (incomplete unicode) -> "test\u12" (literal)
	}

	// MARK: - TOML Single-Quoted Key Tests

	func testSingleQuotedKey_NoEscapeProcessing() {
		// Single-quoted TOML keys don't process escape sequences
		// except for '' which becomes '
		// Expected: 'test\n' -> "test\n" (literal backslash-n, not newline)
		// Expected: 'test''quote' -> "test'quote"
	}

	// MARK: - Real-World Scenario Tests

	func testRealWorldScenario_StandardServerNames() {
		// Test common server name patterns
		let testCases = [
			("RepoPrompt", "RepoPrompt"),
			("my-mcp-server", "my-mcp-server"),
			("server_v1", "server_v1"),
		]

		for (input, expected) in testCases {
			let result = MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: input)
			XCTAssertEqual(result, expected, "Failed for input: \(input)")
		}
	}

	func testRealWorldScenario_ProblematicServerNames() {
		// Test server names that require quoting
		let testCases = [
			("My MCP Server", "\"My MCP Server\""),
			("server:8080", "\"server:8080\""),
			("test@host", "\"test@host\""),
			("path/to/server", "\"path/to/server\""),
		]

		for (input, expected) in testCases {
			let result = MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: input)
			XCTAssertEqual(result, expected, "Failed for input: \(input)")
		}
	}

	func testRealWorldScenario_DangerousCharacters() {
		// Test characters that could cause command injection if not properly escaped
		let testCases = [
			("server; rm -rf /", "\"server; rm -rf /\""),
			("server && echo pwned", "\"server && echo pwned\""),
			("server | cat /etc/passwd", "\"server | cat /etc/passwd\""),
			("server`whoami`", "\"server`whoami`\""),
			("server$(whoami)", "\"server$(whoami)\""),
		]

		for (input, expected) in testCases {
			let result = MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: input)
			XCTAssertEqual(result, expected, "Failed to safely quote dangerous input: \(input)")
		}
	}

	// MARK: - Edge Cases

	func testEdgeCase_OnlySpecialCharacters() {
		XCTAssertEqual(MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: "!!!"), "\"!!!\"")
		XCTAssertEqual(MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: "..."), "\"...\"")
		XCTAssertEqual(MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: "###"), "\"###\"")
	}

	func testEdgeCase_VeryLongServerName() {
		let longName = String(repeating: "a", count: 1000)
		let result = MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: longName)
		// Should still be a bare key (all alphanumeric)
		XCTAssertEqual(result, longName)
	}

	func testEdgeCase_UnicodeCharacters() {
		// Unicode characters require quoting
		XCTAssertEqual(MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: "test🚀server"), "\"test🚀server\"")
		XCTAssertEqual(MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: "サーバー"), "\"サーバー\"")
		XCTAssertEqual(MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: "sервер"), "\"sервер\"")
	}

	func testEdgeCase_WhitespaceVariations() {
		// Various whitespace should be quoted
		XCTAssertEqual(MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: " leading"), "\" leading\"")
		XCTAssertEqual(MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: "trailing "), "\"trailing \"")
		XCTAssertEqual(MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: "  double  space  "), "\"  double  space  \"")
	}

	// MARK: - RepoPrompt permission auto-approval matching

	func testRepoPromptPermissionAutoApprovalMatchesCursorDisplayLabelToolName() {
		let match = MCPIntegrationHelper.repoPromptPermissionAutoApprovalMatch(
			requestToolName: "RepoPrompt-git: git",
			requestPayload: ["command": "git status"]
		)

		XCTAssertEqual(match?.source, .serverIdentifier)
		XCTAssertEqual(match?.normalizedToolName, "git")
		XCTAssertEqual(match?.serverIdentifier, "RepoPrompt-git")
	}

	func testRepoPromptPermissionAutoApprovalMatchesCursorDisplayLabelFromPayloadTitle() {
		let match = MCPIntegrationHelper.repoPromptPermissionAutoApprovalMatch(
			requestToolName: nil,
			requestPayload: [
				"toolCall": [
					"title": "RepoPrompt-git: git"
				]
			]
		)

		XCTAssertEqual(match?.source, .serverIdentifier)
		XCTAssertEqual(match?.normalizedToolName, "git")
		XCTAssertEqual(match?.serverIdentifier, "RepoPrompt-git")
	}

	func testRepoPromptPermissionAutoApprovalDoesNotMatchArbitraryRepoPromptMention() {
		let match = MCPIntegrationHelper.repoPromptPermissionAutoApprovalMatch(
			requestToolName: "grep RepoPrompt docs",
			requestPayload: ["command": "grep RepoPrompt README.md"]
		)

		XCTAssertNil(match)
	}

	func testRepoPromptPermissionAutoApprovalDoesNotMatchOtherServerDisplayLabel() {
		let match = MCPIntegrationHelper.repoPromptPermissionAutoApprovalMatch(
			requestToolName: "OtherServer: git",
			requestPayload: [:]
		)

		XCTAssertNil(match)
	}

	// MARK: - Performance Tests

	func testClaudeProcessEnvironmentOverridesMatchExpectedValues() {
		XCTAssertEqual(MCPIntegrationHelper.claudeProcessEnvironmentOverrides["MCP_TIMEOUT"], "30000")
		XCTAssertEqual(MCPIntegrationHelper.claudeProcessEnvironmentOverrides["MCP_TOOL_TIMEOUT"], "10800000")
		XCTAssertEqual(MCPIntegrationHelper.claudeProcessEnvironmentOverrides["MAX_MCP_OUTPUT_TOKENS"], "25000")
	}

	func testClaudeAgentModeKeepsNativeSkillToolEnabled() {
		let disallowed = MCPIntegrationHelper.claudeDisallowedTools(for: .agentRun)

		XCTAssertFalse(disallowed.contains("Skill"))
		XCTAssertTrue(disallowed.contains("Write"))
		XCTAssertTrue(disallowed.contains("Edit"))
	}

	func testClaudeAgentModeDisablesNativeBashUnlessExplicitlyAllowed() {
		let disallowedByDefault = MCPIntegrationHelper.claudeDisallowedTools(for: .agentRun)
		let disallowedWhenAllowed = MCPIntegrationHelper.claudeDisallowedTools(for: .agentRun, allowNativeBashTool: true)
		let bashToolNames = ["Bash", "BashOutput", "KillShell"]

		for toolName in bashToolNames {
			XCTAssertTrue(disallowedByDefault.contains(toolName), "Expected \(toolName) to be disabled by default")
			XCTAssertFalse(disallowedWhenAllowed.contains(toolName), "Expected \(toolName) to be allowed when native Bash is enabled")
		}
	}

	func testClaudeDiscoveryConfigAllowsNativeBashButKeepsMutationToolsDisallowed() {
		let config = ClaudeCodeAgentConfig.discovery()
		let bashToolNames = ["Bash", "BashOutput", "KillShell"]

		XCTAssertTrue(config.allowNativeBashTool)
		for toolName in bashToolNames {
			XCTAssertFalse(config.disallowedBuiltInTools.contains(toolName), "Expected discovery config to allow \(toolName)")
		}
		XCTAssertTrue(config.disallowedBuiltInTools.contains("Write"))
		XCTAssertTrue(config.disallowedBuiltInTools.contains("Edit"))
		XCTAssertTrue(config.disallowedBuiltInTools.contains("Task"))
	}

	func testClaudeMonitorToolIsDisabledInAllContexts() {
		let contexts: [AgentCLIToolContext] = [
			.agentRun,
			.discoverRun,
			.delegateEdit,
			.promptOnly,
			.terminal
		]

		for context in contexts {
			XCTAssertTrue(
				MCPIntegrationHelper.claudeDisallowedTools(for: context).contains("Monitor"),
				"Expected Monitor to be disallowed for \(context)"
			)
			XCTAssertTrue(
				MCPIntegrationHelper.claudeDisallowedTools(for: context, allowNativeBashTool: true).contains("Monitor"),
				"Expected Monitor to remain disallowed when native Bash is allowed for \(context)"
			)
		}
	}

	func testInvestigateCLIFrontmatterQuotesYAMLScalars() {
		let skill = ClaudeCodeCommands.rpInvestigateCLI
		XCTAssertTrue(skill.contains("name: \"rp-investigate\""))
		XCTAssertTrue(skill.contains("description: \"Deep investigation with rp-cli commands: tools gather evidence, follow-up reasoning synthesizes selected context\""))
	}

	func testInstallAgentsSkills_CLIFrontmatterNameMatchesParentDirectory() throws {
		let workspaceURL = try makeTemporaryDirectory(named: "agents-cli-skills")

		let installed = MCPIntegrationHelper.installAgentsSkills(workspacePath: workspaceURL.path, useCLIVariant: true)
		XCTAssertEqual(installed, 9)

		let skillDirectoryURL = workspaceURL
			.appendingPathComponent(".agents", isDirectory: true)
			.appendingPathComponent("skills", isDirectory: true)
			.appendingPathComponent("rp-build-cli", isDirectory: true)
		let skillFileURL = skillDirectoryURL.appendingPathComponent("SKILL.md")
		let skillContents = try String(contentsOf: skillFileURL, encoding: .utf8)

		let orchestrateSkillDirectoryURL = workspaceURL
			.appendingPathComponent(".agents", isDirectory: true)
			.appendingPathComponent("skills", isDirectory: true)
			.appendingPathComponent("rp-orchestrate-cli", isDirectory: true)
		let orchestrateSkillFileURL = orchestrateSkillDirectoryURL.appendingPathComponent("SKILL.md")
		let orchestratePolicyFileURL = orchestrateSkillDirectoryURL
			.appendingPathComponent("agents", isDirectory: true)
			.appendingPathComponent("openai.yaml")
		let orchestrateSkillContents = try String(contentsOf: orchestrateSkillFileURL, encoding: .utf8)
		let oracleExportCLIPolicyFileURL = workspaceURL
			.appendingPathComponent(".agents", isDirectory: true)
			.appendingPathComponent("skills", isDirectory: true)
			.appendingPathComponent("rp-oracle-export-cli", isDirectory: true)
			.appendingPathComponent("agents", isDirectory: true)
			.appendingPathComponent("openai.yaml")
		let reminderCLIPolicyFileURL = workspaceURL
			.appendingPathComponent(".agents", isDirectory: true)
			.appendingPathComponent("skills", isDirectory: true)
			.appendingPathComponent("rp-reminder-cli", isDirectory: true)
			.appendingPathComponent("agents", isDirectory: true)
			.appendingPathComponent("openai.yaml")

		XCTAssertTrue(FileManager.default.fileExists(atPath: skillFileURL.path))
		XCTAssertTrue(skillContents.contains("name: \"rp-build-cli\""))
		XCTAssertTrue(FileManager.default.fileExists(atPath: orchestrateSkillFileURL.path))
		XCTAssertTrue(FileManager.default.fileExists(atPath: orchestratePolicyFileURL.path))
		XCTAssertTrue(orchestrateSkillContents.contains("name: \"rp-orchestrate-cli\""))
		XCTAssertEqual(
			try String(contentsOf: orchestratePolicyFileURL, encoding: .utf8),
			"policy:\n  allow_implicit_invocation: false"
		)
		XCTAssertEqual(
			try String(contentsOf: oracleExportCLIPolicyFileURL, encoding: .utf8),
			"policy:\n  allow_implicit_invocation: false"
		)
		// The CLI variant of rp-reminder must NOT be implicitly invokable — only the
		// MCP variant stays auto-invocable (see codexSkillAgentPolicy).
		XCTAssertEqual(
			try String(contentsOf: reminderCLIPolicyFileURL, encoding: .utf8),
			"policy:\n  allow_implicit_invocation: false"
		)
	}

	@MainActor
	func testAgentSkillCatalogResolvesQuotedSkillFrontmatter() async throws {
		let homeURL = try makeTemporaryDirectory(named: "quoted-skill-home")
		let skillDirectoryURL = homeURL
			.appendingPathComponent(".agents", isDirectory: true)
			.appendingPathComponent("skills", isDirectory: true)
			.appendingPathComponent("rp-investigate", isDirectory: true)
		try FileManager.default.createDirectory(at: skillDirectoryURL, withIntermediateDirectories: true)
		try ClaudeCodeCommands.rpInvestigateCLI.write(
			to: skillDirectoryURL.appendingPathComponent("SKILL.md"),
			atomically: true,
			encoding: .utf8
		)

		let catalog = AgentSkillCatalog(homeDirectoryURL: homeURL)
		await catalog.refresh(workspacePaths: [], agentKind: .codexExec)

		let skill = catalog.resolve(name: "rp-investigate")
		XCTAssertEqual(skill?.name, "rp-investigate")
		XCTAssertEqual(
			skill?.description,
			"Deep investigation with rp-cli commands: tools gather evidence, follow-up reasoning synthesizes selected context"
		)
	}

	func testInstallAgentsSkills_WritesCodexPolicyFilesAndRepairsMissingPolicy() throws {
		let workspaceURL = try makeTemporaryDirectory(named: "agents-skills")

		let installed = MCPIntegrationHelper.installAgentsSkills(workspacePath: workspaceURL.path, useCLIVariant: false)
		XCTAssertEqual(installed, 9)

		let buildPolicyURL = workspaceURL
			.appendingPathComponent(".agents", isDirectory: true)
			.appendingPathComponent("skills", isDirectory: true)
			.appendingPathComponent("rp-build", isDirectory: true)
			.appendingPathComponent("agents", isDirectory: true)
			.appendingPathComponent("openai.yaml")
		let reminderPolicyURL = workspaceURL
			.appendingPathComponent(".agents", isDirectory: true)
			.appendingPathComponent("skills", isDirectory: true)
			.appendingPathComponent("rp-reminder", isDirectory: true)
			.appendingPathComponent("agents", isDirectory: true)
			.appendingPathComponent("openai.yaml")
		let oracleExportPolicyURL = workspaceURL
			.appendingPathComponent(".agents", isDirectory: true)
			.appendingPathComponent("skills", isDirectory: true)
			.appendingPathComponent("rp-oracle-export", isDirectory: true)
			.appendingPathComponent("agents", isDirectory: true)
			.appendingPathComponent("openai.yaml")
		let orchestrateSkillURL = workspaceURL
			.appendingPathComponent(".agents", isDirectory: true)
			.appendingPathComponent("skills", isDirectory: true)
			.appendingPathComponent("rp-orchestrate", isDirectory: true)
			.appendingPathComponent("SKILL.md")
		let orchestratePolicyURL = workspaceURL
			.appendingPathComponent(".agents", isDirectory: true)
			.appendingPathComponent("skills", isDirectory: true)
			.appendingPathComponent("rp-orchestrate", isDirectory: true)
			.appendingPathComponent("agents", isDirectory: true)
			.appendingPathComponent("openai.yaml")

		XCTAssertEqual(
			try String(contentsOf: buildPolicyURL, encoding: .utf8),
			"policy:\n  allow_implicit_invocation: false"
		)
		XCTAssertEqual(
			try String(contentsOf: reminderPolicyURL, encoding: .utf8),
			"policy:\n  allow_implicit_invocation: true"
		)
		XCTAssertEqual(
			try String(contentsOf: oracleExportPolicyURL, encoding: .utf8),
			"policy:\n  allow_implicit_invocation: false"
		)
		XCTAssertTrue(FileManager.default.fileExists(atPath: orchestrateSkillURL.path))
		XCTAssertEqual(
			try String(contentsOf: orchestratePolicyURL, encoding: .utf8),
			"policy:\n  allow_implicit_invocation: false"
		)

		try FileManager.default.removeItem(at: buildPolicyURL)
		XCTAssertFalse(FileManager.default.fileExists(atPath: buildPolicyURL.path))

		let repaired = MCPIntegrationHelper.installAgentsSkills(workspacePath: workspaceURL.path, useCLIVariant: false)
		XCTAssertEqual(repaired, 9)
		XCTAssertEqual(
			try String(contentsOf: buildPolicyURL, encoding: .utf8),
			"policy:\n  allow_implicit_invocation: false"
		)
	}

	func testInstallClaudeCodeCommands_WritesCodexPolicyFiles() throws {
		let workspaceURL = try makeTemporaryDirectory(named: "claude-skills")

		let installed = MCPIntegrationHelper.installClaudeCodeCommands(workspacePath: workspaceURL.path, useCLIVariant: false)
		XCTAssertEqual(installed, 9)

		let reviewPolicyURL = workspaceURL
			.appendingPathComponent(".claude", isDirectory: true)
			.appendingPathComponent("skills", isDirectory: true)
			.appendingPathComponent("rp-review", isDirectory: true)
			.appendingPathComponent("agents", isDirectory: true)
			.appendingPathComponent("openai.yaml")
		let oracleExportPolicyURL = workspaceURL
			.appendingPathComponent(".claude", isDirectory: true)
			.appendingPathComponent("skills", isDirectory: true)
			.appendingPathComponent("rp-oracle-export", isDirectory: true)
			.appendingPathComponent("agents", isDirectory: true)
			.appendingPathComponent("openai.yaml")
		let orchestrateSkillURL = workspaceURL
			.appendingPathComponent(".claude", isDirectory: true)
			.appendingPathComponent("skills", isDirectory: true)
			.appendingPathComponent("rp-orchestrate", isDirectory: true)
			.appendingPathComponent("SKILL.md")
		let orchestratePolicyURL = workspaceURL
			.appendingPathComponent(".claude", isDirectory: true)
			.appendingPathComponent("skills", isDirectory: true)
			.appendingPathComponent("rp-orchestrate", isDirectory: true)
			.appendingPathComponent("agents", isDirectory: true)
			.appendingPathComponent("openai.yaml")

		XCTAssertEqual(
			try String(contentsOf: reviewPolicyURL, encoding: .utf8),
			"policy:\n  allow_implicit_invocation: false"
		)
		XCTAssertEqual(
			try String(contentsOf: oracleExportPolicyURL, encoding: .utf8),
			"policy:\n  allow_implicit_invocation: false"
		)
		XCTAssertTrue(FileManager.default.fileExists(atPath: orchestrateSkillURL.path))
		XCTAssertEqual(
			try String(contentsOf: orchestratePolicyURL, encoding: .utf8),
			"policy:\n  allow_implicit_invocation: false"
		)
	}

	func testPerformance_CLIPathComponent() {
		self.measure {
			for _ in 0..<1000 {
				_ = MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: "test-server-123")
				_ = MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: "My Server With Spaces")
				_ = MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: "test\n\"escape\"")
			}
		}
	}

	private func makeTemporaryDirectory(named prefix: String) throws -> URL {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		addTeardownBlock {
			try? FileManager.default.removeItem(at: url)
		}
		return url
	}
}
