//
//  OpenCodeIntegrationConfigurationTests.swift
//  RepoPromptTests
//

import XCTest
@testable import RepoPrompt

final class OpenCodeIntegrationConfigurationTests: XCTestCase {

	func testMCPConfigIncludesCommandArgsAndEnvironment() throws {
		let configuration = RepoPromptMCPServerConfiguration(
			command: "/usr/local/bin/repoprompt-mcp",
			args: ["serve", "--stdio"],
			env: [
				.init(name: "RP_TEST", value: "1"),
				.init(name: "MAX_MCP_OUTPUT_TOKENS", value: "25000")
			]
		)

		let dict = OpenCodeIntegrationConfiguration.mcpConfigDict(for: configuration)

		XCTAssertEqual(dict["type"] as? String, "local")
		XCTAssertEqual(dict["command"] as? [String], ["/usr/local/bin/repoprompt-mcp", "serve", "--stdio"])
		XCTAssertEqual(dict["environment"] as? [String: String], [
			"RP_TEST": "1",
			"MAX_MCP_OUTPUT_TOKENS": "25000"
		])
		XCTAssertEqual(dict["timeout"] as? Int, 14_400_000)
	}

	func testManagedACPAgentAllowsAgentModeToolsAndDeniesOverlappingTools() throws {
		let dict = OpenCodeIntegrationConfiguration.managedACPAgentConfigDict
		let permissions = try XCTUnwrap(dict["permission"] as? [String: String])

		XCTAssertEqual(dict["name"] as? String, OpenCodeAgentConfig.managedSessionModeID)
		XCTAssertEqual(dict["mode"] as? String, "primary")
		for allowedTool in ["bash", "webfetch", "websearch", "codesearch"] {
			XCTAssertEqual(permissions[allowedTool], "allow", "Expected OpenCode Agent Mode tool \(allowedTool) to be allowed")
		}
		for deniedTool in ["read", "list", "glob", "grep", "edit", "write", "patch", "todowrite", "task", "skill", "question", "plan_enter", "plan_exit"] {
			XCTAssertEqual(permissions[deniedTool], "deny", "Expected OpenCode built-in tool \(deniedTool) to be denied")
		}
		XCTAssertNil(dict["options"], "Agent options are forwarded to model providers by OpenCode and must not contain RepoPrompt metadata")
	}

	func testManagedFullAccessAgentSuppressesPromptsWithoutChangingManagedDenies() throws {
		let dict = OpenCodeIntegrationConfiguration.managedFullAccessACPAgentConfigDict
		let permissions = try XCTUnwrap(dict["permission"] as? [String: String])

		XCTAssertEqual(dict["name"] as? String, OpenCodeAgentConfig.managedFullAccessSessionModeID)
		XCTAssertEqual(dict["mode"] as? String, "primary")
		XCTAssertEqual(permissions["*"], "allow")
		for deniedTool in ["read", "list", "glob", "grep", "edit", "write", "patch", "todowrite", "task", "skill", "question", "plan_enter", "plan_exit"] {
			XCTAssertEqual(permissions[deniedTool], "deny", "Expected OpenCode full-access mode to preserve managed deny for \(deniedTool)")
		}
		for defaultAllowedTool in ["bash", "webfetch", "websearch", "codesearch"] {
			XCTAssertNil(permissions[defaultAllowedTool], "Expected OpenCode full-access mode to rely on wildcard allow without changing exposed tools for \(defaultAllowedTool)")
		}
		XCTAssertNil(dict["tools"], "Full-access mode must not disable or alter injected tools")
		XCTAssertNil(dict["options"], "Agent options are forwarded to model providers by OpenCode and must not contain RepoPrompt metadata")
	}

	func testManagedHeadlessAgentDeniesNativeToolsWithoutWildcard() throws {
		let dict = OpenCodeIntegrationConfiguration.managedHeadlessAgentConfigDict
		let permissions = try XCTUnwrap(dict["permission"] as? [String: String])

		XCTAssertEqual(dict["name"] as? String, OpenCodeAgentConfig.managedHeadlessSessionModeID)
		XCTAssertEqual(dict["mode"] as? String, "primary")
		XCTAssertNil(permissions["*"], "Headless mode must not wildcard-deny injected RepoPrompt MCP tools")
		XCTAssertNil(dict["tools"], "Headless mode must not disable injected RepoPrompt MCP tools")
		for deniedTool in ["bash", "read", "list", "glob", "grep", "edit", "write", "patch", "webfetch", "websearch", "codesearch", "todowrite", "task", "skill", "question", "plan_enter", "plan_exit"] {
			XCTAssertEqual(permissions[deniedTool], "deny", "Expected OpenCode headless mode to deny native tool \(deniedTool)")
		}
		XCTAssertNil(dict["options"], "Agent options are forwarded to model providers by OpenCode and must not contain RepoPrompt metadata")
	}

	func testManagedNoToolsAgentDeniesAllTools() throws {
		let dict = OpenCodeIntegrationConfiguration.managedNoToolsAgentConfigDict
		let permissions = try XCTUnwrap(dict["permission"] as? [String: String])
		let tools = try XCTUnwrap(dict["tools"] as? [String: Bool])

		XCTAssertEqual(dict["name"] as? String, OpenCodeAgentConfig.managedNoToolsSessionModeID)
		XCTAssertEqual(dict["mode"] as? String, "primary")
		XCTAssertEqual(permissions["*"], "deny")
		for deniedTool in ["bash", "read", "list", "glob", "grep", "edit", "write", "patch", "webfetch", "websearch", "codesearch", "todowrite", "task", "skill", "question", "plan_enter", "plan_exit"] {
			XCTAssertEqual(permissions[deniedTool], "deny", "Expected OpenCode no-tools mode to deny \(deniedTool)")
		}
		XCTAssertEqual(tools["*"], false)
		XCTAssertNil(dict["options"], "Agent options are forwarded to model providers by OpenCode and must not contain RepoPrompt metadata")
	}

	func testManagedAgentConfigContainsInteractiveHeadlessAndNoToolsModes() throws {
		let dicts = OpenCodeIntegrationConfiguration.managedAgentConfigDicts

		XCTAssertNotNil(dicts[OpenCodeAgentConfig.managedSessionModeID])
		XCTAssertNotNil(dicts[OpenCodeAgentConfig.managedFullAccessSessionModeID])
		XCTAssertNotNil(dicts[OpenCodeAgentConfig.managedHeadlessSessionModeID])
		XCTAssertNotNil(dicts[OpenCodeAgentConfig.managedNoToolsSessionModeID])
	}

	func testEphemeralACPConfigIncludesManagedAgentsAndActiveMCP() throws {
		let json = try OpenCodeIntegrationConfiguration.ephemeralACPConfigJSON(includeRepoPromptMCPServer: true)
		let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])

		XCTAssertEqual(root["$schema"] as? String, "https://opencode.ai/config.json")

		let agents = try XCTUnwrap(root["agent"] as? [String: Any])
		XCTAssertNotNil(agents[OpenCodeAgentConfig.managedSessionModeID])
		XCTAssertNotNil(agents[OpenCodeAgentConfig.managedFullAccessSessionModeID])
		XCTAssertNotNil(agents[OpenCodeAgentConfig.managedHeadlessSessionModeID])
		XCTAssertNotNil(agents[OpenCodeAgentConfig.managedNoToolsSessionModeID])

		let servers = try XCTUnwrap(root["mcp"] as? [String: Any])
		let repoPromptServer = try XCTUnwrap(servers[MCPIntegrationHelper.repoPromptMCPServerName] as? [String: Any])
		let command = try XCTUnwrap(repoPromptServer["command"] as? [String])

		XCTAssertEqual(repoPromptServer["type"] as? String, "local")
		XCTAssertFalse(command.isEmpty)
		XCTAssertFalse(repoPromptServer["enabled"] as? Bool == false)
		XCTAssertEqual(repoPromptServer["timeout"] as? Int, 14_400_000)
		XCTAssertFalse(json.contains("repoPromptManaged"), "Provider-facing OpenCode config must not include internal RepoPrompt metadata")
		XCTAssertFalse(json.contains("repoPromptManagedVersion"), "Provider-facing OpenCode config must not include internal RepoPrompt metadata")
	}

	func testEphemeralACPConfigDisablesRepoPromptMCPWhenExcluded() throws {
		let root = OpenCodeIntegrationConfiguration.ephemeralACPConfigDict(includeRepoPromptMCPServer: false)
		let agents = try XCTUnwrap(root["agent"] as? [String: Any])
		let servers = try XCTUnwrap(root["mcp"] as? [String: Any])
		let repoPromptServer = try XCTUnwrap(servers[MCPIntegrationHelper.repoPromptMCPServerName] as? [String: Any])

		XCTAssertNotNil(agents[OpenCodeAgentConfig.managedSessionModeID])
		XCTAssertNotNil(agents[OpenCodeAgentConfig.managedFullAccessSessionModeID])
		XCTAssertNotNil(agents[OpenCodeAgentConfig.managedHeadlessSessionModeID])
		XCTAssertNotNil(agents[OpenCodeAgentConfig.managedNoToolsSessionModeID])
		XCTAssertEqual(repoPromptServer["type"] as? String, "local")
		XCTAssertEqual(repoPromptServer["command"] as? [String], ["/usr/bin/false"])
		XCTAssertEqual(repoPromptServer["environment"] as? [String: String], [:])
		XCTAssertEqual(repoPromptServer["enabled"] as? Bool, false)
		XCTAssertEqual(repoPromptServer["timeout"] as? Int, 14_400_000)
	}

	func testEphemeralConfigSerializesFullAccessWildcardBeforeSpecificDenies() throws {
		let json = try OpenCodeIntegrationConfiguration.ephemeralACPConfigJSON(includeRepoPromptMCPServer: true)
		let modeRange = try XCTUnwrap(json.range(of: "\"\(OpenCodeAgentConfig.managedFullAccessSessionModeID)\""))
		let tail = json[modeRange.upperBound...]
		let permissionRange = try XCTUnwrap(tail.range(of: "\"permission\" : {"))
		let permissionTail = tail[permissionRange.upperBound...]
		let wildcardRange = try XCTUnwrap(permissionTail.range(of: "\"*\" : \"allow\""))
		let readRange = try XCTUnwrap(permissionTail.range(of: "\"read\" : \"deny\""))

		XCTAssertLessThan(wildcardRange.lowerBound, readRange.lowerBound, "OpenCode uses last matching permission rule wins; wildcard allow must serialize before specific denies.")
	}

	func testLegacyCleanupRemovesOnlyRepoPromptManagedAgents() throws {
		let root: [String: Any] = [
			"agent": [
				OpenCodeAgentConfig.managedSessionModeID: [
					"options": ["repoPromptManaged": true]
				],
				OpenCodeAgentConfig.managedHeadlessSessionModeID: [
					"options": ["repoPromptManaged": true]
				],
				OpenCodeAgentConfig.managedFullAccessSessionModeID: [
					"options": ["repoPromptManaged": true]
				],
				OpenCodeAgentConfig.managedNoToolsSessionModeID: [
					"options": ["repoPromptManaged": false]
				],
				"custom": [
					"options": ["repoPromptManaged": true]
				]
			]
		]

		let cleaned = OpenCodeIntegrationConfiguration.cleanLegacyACPConfigRoot(
			root,
			preserveExplicitMCPInstall: false
		)
		let agents = try XCTUnwrap(cleaned.root["agent"] as? [String: Any])

		XCTAssertTrue(cleaned.changed)
		XCTAssertNil(agents[OpenCodeAgentConfig.managedSessionModeID])
		XCTAssertNil(agents[OpenCodeAgentConfig.managedHeadlessSessionModeID])
		XCTAssertNil(agents[OpenCodeAgentConfig.managedFullAccessSessionModeID])
		XCTAssertNotNil(agents[OpenCodeAgentConfig.managedNoToolsSessionModeID])
		XCTAssertNotNil(agents["custom"])
	}

	func testLegacyCleanupRemovesNonExplicitLegacyMCP() throws {
		let root: [String: Any] = [
			"mcp": [
				"repoprompt": [
					"type": "local",
					"command": ["/Users/example/RepoPrompt/build/repoprompt_cli_debug"],
					"timeout": 14_400_000
				],
				"Other": [
					"type": "local",
					"command": ["/usr/bin/other"]
				]
			]
		]

		let cleaned = OpenCodeIntegrationConfiguration.cleanLegacyACPConfigRoot(
			root,
			preserveExplicitMCPInstall: false
		)
		let servers = try XCTUnwrap(cleaned.root["mcp"] as? [String: Any])

		XCTAssertTrue(cleaned.changed)
		XCTAssertNil(servers["repoprompt"])
		XCTAssertNotNil(servers["Other"])
	}

	func testLegacyCleanupPreservesExplicitMCPInstall() throws {
		let root: [String: Any] = [
			"mcp": [
				MCPIntegrationHelper.repoPromptMCPServerName: [
					"type": "local",
					"command": ["/Users/example/RepoPrompt/build/repoprompt_cli"],
					"timeout": 14_400_000
				]
			]
		]

		let cleaned = OpenCodeIntegrationConfiguration.cleanLegacyACPConfigRoot(
			root,
			preserveExplicitMCPInstall: true
		)
		let servers = try XCTUnwrap(cleaned.root["mcp"] as? [String: Any])

		XCTAssertFalse(cleaned.changed)
		XCTAssertNotNil(servers[MCPIntegrationHelper.repoPromptMCPServerName])
	}

	func testLegacyCleanupPreservesCustomSameNamedMCPWhenNotLegacyLooking() throws {
		let root: [String: Any] = [
			"mcp": [
				MCPIntegrationHelper.repoPromptMCPServerName: [
					"type": "local",
					"command": ["/usr/local/bin/custom-repoprompt-wrapper"]
				]
			]
		]

		let cleaned = OpenCodeIntegrationConfiguration.cleanLegacyACPConfigRoot(
			root,
			preserveExplicitMCPInstall: false
		)
		let servers = try XCTUnwrap(cleaned.root["mcp"] as? [String: Any])

		XCTAssertFalse(cleaned.changed)
		XCTAssertNotNil(servers[MCPIntegrationHelper.repoPromptMCPServerName])
	}
}
