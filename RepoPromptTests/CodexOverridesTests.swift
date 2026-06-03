import XCTest
@testable import RepoPrompt

final class CodexOverridesTests: XCTestCase {
	private static let forcedDisabledBoolConfigKeys = [
		"features.apps",
		"features.js_repl",
		"features.js_repl_tools_only",
		"features.memories",
		"features.goals",
		"features.computer_use",
		"features.plugins",
		"features.tool_search",
		"features.tool_call_mcp_elicitation",
		"features.tool_suggest",
		"memories.generate_memories",
		"memories.use_memories"
	]

	func testAppServerConfigMapDisablesSearchUsingTopLevelMode() {
		let policy = CodexOverrides.ToolPolicy(
			toolOutputTokenLimit: 50000,
			shellToolEnabled: nil,
			webSearchRequestEnabled: false,
			viewImageToolEnabled: nil,
			includeApplyPatchTool: nil,
			parallelToolCallsEnabled: nil
		)

		let map = CodexOverrides.appServerConfigMap(toolPolicy: policy)

		XCTAssertEqual(map["web_search"] as? String, "disabled")
		XCTAssertNil(map["tools.web_search"])
		XCTAssertNil(map["tools.web_search_request"])
		XCTAssertEqual(map["features.web_search_request"] as? Bool, false)
		XCTAssertEqual(map["model_reasoning_summary"] as? String, "auto")
	}

	func testAppServerConfigMapDisablesUnifiedExecWhenShellIsOff() {
		let policy = CodexOverrides.ToolPolicy(
			toolOutputTokenLimit: 50000,
			shellToolEnabled: false,
			webSearchRequestEnabled: nil,
			viewImageToolEnabled: nil,
			includeApplyPatchTool: nil,
			parallelToolCallsEnabled: nil
		)

		let map = CodexOverrides.appServerConfigMap(toolPolicy: policy)

		XCTAssertEqual(map["features.shell_tool"] as? Bool, false)
		XCTAssertEqual(map["features.unified_exec"] as? Bool, false)
	}

	func testAppServerConfigMapDisablesExperimentalAppsAndJSReplFeatures() {
		let policy = CodexOverrides.ToolPolicy(
			toolOutputTokenLimit: 50000,
			shellToolEnabled: true,
			webSearchRequestEnabled: nil,
			viewImageToolEnabled: false,
			includeApplyPatchTool: false,
			parallelToolCallsEnabled: false,
			multiAgentEnabled: false,
			experimentalSteeringEnabled: true
		)

		let map = CodexOverrides.appServerConfigMap(toolPolicy: policy)

		XCTAssertEqual(map["features.apps"] as? Bool, false)
		XCTAssertEqual(map["features.js_repl"] as? Bool, false)
		XCTAssertEqual(map["features.js_repl_tools_only"] as? Bool, false)
	}

	func testAppServerConfigMapEnablesScopedComputerUseFeaturePolicy() {
		let policy = CodexOverrides.ToolPolicy(
			toolOutputTokenLimit: 50000,
			shellToolEnabled: true,
			webSearchRequestEnabled: nil,
			viewImageToolEnabled: false,
			includeApplyPatchTool: false,
			parallelToolCallsEnabled: false,
			multiAgentEnabled: false,
			experimentalSteeringEnabled: true
		)

		let map = CodexOverrides.appServerConfigMap(
			toolPolicy: policy,
			featurePolicy: .enabledForComputerUse
		)

		XCTAssertEqual(map["features.goals"] as? Bool, false)
		XCTAssertEqual(map["features.computer_use"] as? Bool, true)
		XCTAssertEqual(map["features.plugins"] as? Bool, true)
		XCTAssertEqual(map["features.tool_search"] as? Bool, true)
		XCTAssertEqual(map["features.tool_search_always_defer_mcp_tools"] as? Bool, true)
		XCTAssertEqual(map["features.tool_suggest"] as? Bool, true)
		XCTAssertEqual(map["features.tool_call_mcp_elicitation"] as? Bool, true)
		XCTAssertEqual(map["features.apps"] as? Bool, false)
		XCTAssertEqual(map["features.memories"] as? Bool, false)
		XCTAssertEqual(map["memories.generate_memories"] as? Bool, false)
		XCTAssertEqual(map["memories.use_memories"] as? Bool, false)
	}

	func testDefaultAppServerConfigOverridesPassesScopedComputerUseFeaturePolicy() {
		let map = CodexNativeSessionController.defaultAppServerConfigOverrides(
			forceExperimentalSteering: false,
			computerUseEnabled: true
		)

		XCTAssertEqual(map["features.goals"] as? Bool, false)
		XCTAssertEqual(map["features.computer_use"] as? Bool, true)
		XCTAssertEqual(map["features.plugins"] as? Bool, true)
		XCTAssertEqual(map["features.tool_search"] as? Bool, true)
		XCTAssertEqual(map["features.tool_search_always_defer_mcp_tools"] as? Bool, true)
		XCTAssertEqual(map["features.tool_suggest"] as? Bool, true)
		XCTAssertEqual(map["features.tool_call_mcp_elicitation"] as? Bool, true)
	}

	func testDefaultAppServerConfigOverridesPassesGoalOptInFeaturePolicy() {
		let map = CodexNativeSessionController.defaultAppServerConfigOverrides(
			forceExperimentalSteering: false,
			goalSupportEnabled: true,
			computerUseEnabled: false
		)

		XCTAssertEqual(map["features.goals"] as? Bool, true)
		XCTAssertEqual(map["features.computer_use"] as? Bool, false)
	}

	func testCLIConfigArgsEnableScopedComputerUseFeaturePolicy() {
		let policy = CodexOverrides.ToolPolicy(
			toolOutputTokenLimit: 50000,
			shellToolEnabled: nil,
			webSearchRequestEnabled: nil,
			viewImageToolEnabled: nil,
			includeApplyPatchTool: nil,
			parallelToolCallsEnabled: nil,
			modelReasoningSummary: nil
		)

		let args = CodexOverrides.cliConfigArgs(
			toolPolicy: policy,
			featurePolicy: .enabledForComputerUse
		)

		assertConfigArgs(args, contain: "features.goals=false")
		assertConfigArgs(args, contain: "features.computer_use=true")
		assertConfigArgs(args, contain: "features.plugins=true")
		assertConfigArgs(args, contain: "features.tool_search=true")
		assertConfigArgs(args, contain: "features.tool_search_always_defer_mcp_tools=true")
		assertConfigArgs(args, contain: "features.tool_suggest=true")
		assertConfigArgs(args, contain: "features.tool_call_mcp_elicitation=true")
		assertConfigArgs(args, contain: "features.apps=false")
	}

	func testAppServerConfigMapDoesNotEnableGoalsByDefault() {
		let policy = CodexOverrides.ToolPolicy(
			toolOutputTokenLimit: 50000,
			shellToolEnabled: true,
			webSearchRequestEnabled: nil,
			viewImageToolEnabled: false,
			includeApplyPatchTool: false,
			parallelToolCallsEnabled: false,
			multiAgentEnabled: false,
			experimentalSteeringEnabled: true
		)

		let map = CodexOverrides.appServerConfigMap(toolPolicy: policy)

		XCTAssertEqual(map["features.goals"] as? Bool, false)
		XCTAssertEqual(map["features.computer_use"] as? Bool, false)
	}

	func testAppServerConfigMapEnablesGoalsWhenOptedIn() {
		let policy = CodexOverrides.ToolPolicy(
			toolOutputTokenLimit: 50000,
			shellToolEnabled: true,
			webSearchRequestEnabled: nil,
			viewImageToolEnabled: false,
			includeApplyPatchTool: false,
			parallelToolCallsEnabled: false,
			multiAgentEnabled: false,
			experimentalSteeringEnabled: true
		)

		let map = CodexOverrides.appServerConfigMap(toolPolicy: policy, featurePolicy: .enabledForGoals)

		XCTAssertEqual(map["features.goals"] as? Bool, true)
		XCTAssertEqual(map["features.computer_use"] as? Bool, false)
	}

	func testAppServerConfigMapEnablesGoalsAndComputerUseWhenBothOptedIn() {
		let policy = CodexOverrides.ToolPolicy(
			toolOutputTokenLimit: 50000,
			shellToolEnabled: true,
			webSearchRequestEnabled: nil,
			viewImageToolEnabled: false,
			includeApplyPatchTool: false,
			parallelToolCallsEnabled: false,
			multiAgentEnabled: false,
			experimentalSteeringEnabled: true
		)

		let map = CodexOverrides.appServerConfigMap(
			toolPolicy: policy,
			featurePolicy: .resolved(goalsEnabled: true, computerUseEnabled: true)
		)

		XCTAssertEqual(map["features.goals"] as? Bool, true)
		XCTAssertEqual(map["features.computer_use"] as? Bool, true)
		XCTAssertEqual(map["features.plugins"] as? Bool, true)
		XCTAssertEqual(map["features.tool_search"] as? Bool, true)
	}

	func testAppServerConfigMapAlwaysAppliesForcedCodexDisables() {
		let policy = CodexOverrides.ToolPolicy(
			toolOutputTokenLimit: 50000,
			shellToolEnabled: true,
			webSearchRequestEnabled: nil,
			viewImageToolEnabled: false,
			includeApplyPatchTool: false,
			parallelToolCallsEnabled: false,
			multiAgentEnabled: false,
			experimentalSteeringEnabled: true
		)

		let map = CodexOverrides.appServerConfigMap(toolPolicy: policy)

		assertForcedAppServerConfig(in: map)
	}

	func testCLIConfigArgsEnableGoalsOnlyWhenOptedIn() {
		let policy = CodexOverrides.ToolPolicy(
			toolOutputTokenLimit: 50000,
			shellToolEnabled: nil,
			webSearchRequestEnabled: nil,
			viewImageToolEnabled: nil,
			includeApplyPatchTool: nil,
			parallelToolCallsEnabled: nil,
			modelReasoningSummary: nil
		)

		let defaultArgs = CodexOverrides.cliConfigArgs(toolPolicy: policy)
		let optedInArgs = CodexOverrides.cliConfigArgs(toolPolicy: policy, featurePolicy: .enabledForGoals)

		assertConfigArgs(defaultArgs, contain: "features.goals=false")
		assertConfigArgs(defaultArgs, contain: "features.computer_use=false")
		assertConfigArgs(optedInArgs, contain: "features.goals=true")
		assertConfigArgs(optedInArgs, contain: "features.computer_use=false")
	}

	func testCLIConfigArgsIncludeSearchModeAndUnifiedExecDisable() {
		let policy = CodexOverrides.ToolPolicy(
			toolOutputTokenLimit: 50000,
			shellToolEnabled: false,
			webSearchRequestEnabled: false,
			viewImageToolEnabled: nil,
			includeApplyPatchTool: nil,
			parallelToolCallsEnabled: nil
		)

		let args = CodexOverrides.cliConfigArgs(toolPolicy: policy)
		let joined = args.joined(separator: " ")

		XCTAssertTrue(joined.contains("features.shell_tool=false"))
		XCTAssertTrue(joined.contains("features.unified_exec=false"))
		XCTAssertTrue(joined.contains("web_search=disabled"))
		XCTAssertFalse(joined.contains("tools.web_search="))
		XCTAssertFalse(joined.contains("tools.web_search_request="))
		XCTAssertTrue(joined.contains("model_reasoning_summary=auto"))
		XCTAssertTrue(joined.contains("features.apps=false"))
		XCTAssertTrue(joined.contains("features.goals=false"))
		XCTAssertTrue(joined.contains("features.computer_use=false"))
		XCTAssertTrue(joined.contains("features.js_repl=false"))
		XCTAssertTrue(joined.contains("features.js_repl_tools_only=false"))
	}

	func testOverrideSerializersEmitCanonicalApplyPatchDisableOnly() {
		let policy = CodexOverrides.ToolPolicy(
			toolOutputTokenLimit: 50000,
			shellToolEnabled: nil,
			webSearchRequestEnabled: nil,
			viewImageToolEnabled: nil,
			includeApplyPatchTool: false,
			parallelToolCallsEnabled: nil
		)

		let map = CodexOverrides.appServerConfigMap(toolPolicy: policy)
		XCTAssertEqual(map["features.apply_patch_freeform"] as? Bool, false)
		XCTAssertNil(map["include_apply_patch_tool"])

		let args = CodexOverrides.cliConfigArgs(toolPolicy: policy)
		let joined = args.joined(separator: " ")
		XCTAssertTrue(joined.contains("features.apply_patch_freeform=false"))
		XCTAssertFalse(joined.contains("include_apply_patch_tool=false"))
	}

	func testOverrideSerializersDoNotEmitToolsNamespaceKeys() {
		let policy = CodexOverrides.ToolPolicy(
			toolOutputTokenLimit: 50000,
			shellToolEnabled: true,
			webSearchRequestEnabled: true,
			viewImageToolEnabled: true,
			includeApplyPatchTool: false,
			parallelToolCallsEnabled: false,
			multiAgentEnabled: false,
			experimentalSteeringEnabled: true
		)

		let map = CodexOverrides.appServerConfigMap(toolPolicy: policy)
		XCTAssertTrue(map.keys.filter { $0.hasPrefix("tools.") }.isEmpty)

		let args = CodexOverrides.cliConfigArgs(toolPolicy: policy)
		XCTAssertFalse(args.contains { $0.hasPrefix("tools.") })
	}

	func testAppServerConfigMapOmitsSteerFlagByDefault() {
		let policy = CodexOverrides.ToolPolicy(
			toolOutputTokenLimit: 50000,
			shellToolEnabled: nil,
			webSearchRequestEnabled: nil,
			viewImageToolEnabled: nil,
			includeApplyPatchTool: nil,
			parallelToolCallsEnabled: nil
		)

		let map = CodexOverrides.appServerConfigMap(toolPolicy: policy)

		XCTAssertNil(map["features.steer"])
		XCTAssertEqual(map["model_reasoning_summary"] as? String, "auto")
		XCTAssertEqual(map["features.apps"] as? Bool, false)
		XCTAssertEqual(map["features.js_repl"] as? Bool, false)
		XCTAssertEqual(map["features.js_repl_tools_only"] as? Bool, false)
	}

	func testAppServerConfigMapIncludesSteerFlagWhenRequested() {
		let policy = CodexOverrides.ToolPolicy(
			toolOutputTokenLimit: 50000,
			shellToolEnabled: nil,
			webSearchRequestEnabled: nil,
			viewImageToolEnabled: nil,
			includeApplyPatchTool: nil,
			parallelToolCallsEnabled: nil,
			experimentalSteeringEnabled: true
		)

		let map = CodexOverrides.appServerConfigMap(toolPolicy: policy)

		XCTAssertEqual(map["features.steer"] as? Bool, true)
	}

	func testAppServerConfigMapIncludesMultiAgentFlagWhenRequested() {
		let policy = CodexOverrides.ToolPolicy(
			toolOutputTokenLimit: 50000,
			shellToolEnabled: nil,
			webSearchRequestEnabled: nil,
			viewImageToolEnabled: nil,
			includeApplyPatchTool: nil,
			parallelToolCallsEnabled: nil,
			multiAgentEnabled: false
		)

		let map = CodexOverrides.appServerConfigMap(toolPolicy: policy)

		XCTAssertEqual(map["features.multi_agent"] as? Bool, false)
	}

	func testCLIConfigArgsIncludesSteerFlagWhenRequested() {
		let policy = CodexOverrides.ToolPolicy(
			toolOutputTokenLimit: 50000,
			shellToolEnabled: nil,
			webSearchRequestEnabled: nil,
			viewImageToolEnabled: nil,
			includeApplyPatchTool: nil,
			parallelToolCallsEnabled: nil,
			experimentalSteeringEnabled: true
		)

		let args = CodexOverrides.cliConfigArgs(toolPolicy: policy)
		let joined = args.joined(separator: " ")

		XCTAssertTrue(joined.contains("features.steer=true"))
	}

	func testCLIConfigArgsIncludesMultiAgentFlagWhenRequested() {
		let policy = CodexOverrides.ToolPolicy(
			toolOutputTokenLimit: 50000,
			shellToolEnabled: nil,
			webSearchRequestEnabled: nil,
			viewImageToolEnabled: nil,
			includeApplyPatchTool: nil,
			parallelToolCallsEnabled: nil,
			multiAgentEnabled: false,
			modelReasoningSummary: nil
		)

		let args = CodexOverrides.cliConfigArgs(toolPolicy: policy)
		let joined = args.joined(separator: " ")

		XCTAssertTrue(joined.contains("features.multi_agent=false"))
	}

	func testCLIConfigArgsIncludeExperimentalAppsAndJSReplDisablesByDefault() {
		let policy = CodexOverrides.ToolPolicy(
			toolOutputTokenLimit: 50000,
			shellToolEnabled: nil,
			webSearchRequestEnabled: nil,
			viewImageToolEnabled: nil,
			includeApplyPatchTool: nil,
			parallelToolCallsEnabled: nil,
			modelReasoningSummary: nil
		)

		let args = CodexOverrides.cliConfigArgs(toolPolicy: policy)
		let joined = args.joined(separator: " ")

		XCTAssertTrue(joined.contains("features.apps=false"))
		XCTAssertTrue(joined.contains("features.goals=false"))
		XCTAssertTrue(joined.contains("features.computer_use=false"))
		XCTAssertTrue(joined.contains("features.js_repl=false"))
		XCTAssertTrue(joined.contains("features.js_repl_tools_only=false"))
	}

	func testCLIConfigArgsAlwaysApplyForcedCodexDisables() {
		let policy = CodexOverrides.ToolPolicy(
			toolOutputTokenLimit: 50000,
			shellToolEnabled: false,
			webSearchRequestEnabled: false,
			viewImageToolEnabled: false,
			includeApplyPatchTool: false,
			parallelToolCallsEnabled: false,
			multiAgentEnabled: false,
			modelReasoningSummary: nil
		)

		let args = CodexOverrides.cliConfigArgs(toolPolicy: policy)

		assertForcedCLIConfigArgs(args)
	}

	func testCodexIntegrationConfigurationDiscoverOverridesEnableShellAndKeepForcedDisables() {
		let args = CodexIntegrationConfiguration.configOverrides(for: .discoverRun)

		assertForcedCLIConfigArgs(args)
		assertConfigArgs(args, contain: "features.shell_tool=true")
		assertConfigArgs(args, doNotContain: "features.unified_exec=false")
	}

	func testCodexIntegrationConfigurationAgentRunOverridesDoNotForceShellDisabled() {
		let args = CodexIntegrationConfiguration.configOverrides(for: .agentRun)

		assertForcedCLIConfigArgs(args)
		assertConfigArgs(args, doNotContain: "features.shell_tool=false")
		assertConfigArgs(args, doNotContain: "features.unified_exec=false")
	}

	func testCodexIntegrationConfigurationDelegateEditOverridesKeepShellDisabled() {
		let args = CodexIntegrationConfiguration.configOverrides(for: .delegateEdit)

		assertForcedCLIConfigArgs(args)
		assertConfigArgs(args, contain: "features.shell_tool=false")
		assertConfigArgs(args, contain: "features.unified_exec=false")
	}

	func testCodexExecArgumentsEnableShellAndKeepForcedDisableOverrides() {
		let repoPromptName = MCPIntegrationHelper.repoPromptMCPServerName
		let serverEntries = [
			MCPIntegrationHelper.CodexServerEntry(
				rawName: repoPromptName,
				normalizedName: repoPromptName,
				cliPathComponent: MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: repoPromptName)
			)
		]

		let command = CodexExecAgentProvider.buildCodexExecArguments(
			selectedModelString: "gpt-5-high",
			serverEntries: serverEntries,
			brokenServers: []
		)
		let args = command.args

		XCTAssertTrue(args.contains("exec"))
		assertForcedCLIConfigArgs(args)
		assertConfigArgs(args, contain: "features.shell_tool=true")
		assertConfigArgs(args, doNotContain: "features.unified_exec=false")
		assertConfigArgs(args, contain: "mcp_servers.\(repoPromptName).enabled=true")
		XCTAssertEqual(Array(args.suffix(3)), ["--json", "--skip-git-repo-check", "--full-auto"])
	}

	private func assertForcedAppServerConfig(
		in map: [String: Any],
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		for key in Self.forcedDisabledBoolConfigKeys {
			XCTAssertEqual(map[key] as? Bool, false, "Expected forced disabled bool override for \(key)", file: file, line: line)
		}
	}

	private func assertForcedCLIConfigArgs(
		_ args: [String],
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		for key in Self.forcedDisabledBoolConfigKeys {
			assertConfigArgs(args, contain: "\(key)=false", file: file, line: line)
		}
	}

	private func assertConfigArgs(
		_ args: [String],
		contain expectedConfig: String,
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		for index in args.indices.dropLast() where args[index] == "-c" && args[index + 1] == expectedConfig {
			return
		}
		XCTFail("Expected -c \(expectedConfig) in args: \(args)", file: file, line: line)
	}

	private func assertConfigArgs(
		_ args: [String],
		doNotContain unexpectedConfig: String,
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		for index in args.indices.dropLast() where args[index] == "-c" && args[index + 1] == unexpectedConfig {
			XCTFail("Did not expect -c \(unexpectedConfig) in args: \(args)", file: file, line: line)
			return
		}
	}
}
