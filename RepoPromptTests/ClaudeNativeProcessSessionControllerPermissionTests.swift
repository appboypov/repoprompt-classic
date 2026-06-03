import XCTest
@testable import RepoPrompt

final class ClaudeNativeProcessSessionControllerPermissionTests: XCTestCase {
	func testApprovalResponseSendFailureFailsActiveTurnAndFinishesEvents() async {
		let controller = ClaudeNativeProcessSessionController(
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil,
			config: ClaudeCodeAgentConfig.agentMode()
		)
		let events = await controller.events
		let collector = Task { await collectEventsUntilFinished(from: events) }
		let turnID = await controller.test_beginTurnTracking()
		await controller.test_storePendingPermissionRequest(
			id: "perm-1",
			request: [
				"tool_name": "Bash",
				"tool_use_id": "toolu_approval_failure",
				"input": ["command": "echo hi"]
			]
		)

		await controller.respondToPermissionRequest(id: "perm-1", decision: .accept)

		let received = await collector.value
		XCTAssertTrue(
			received.containsError(containing: "Failed to submit Claude approval decision"),
			"Expected approval send failure error, got: \(received.debugSummary)"
		)
		XCTAssertTrue(
			received.containsTurnCompleted(turnID: turnID, status: .failed),
			"Expected active turn to fail, got: \(received.debugSummary)"
		)
	}

	func testRepoPromptAutoApprovalSendFailureFailsActiveTurnAndFinishesEvents() async {
		let controller = ClaudeNativeProcessSessionController(
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil,
			config: ClaudeCodeAgentConfig.agentMode()
		)
		let events = await controller.events
		let collector = Task { await collectEventsUntilFinished(from: events) }
		let turnID = await controller.test_beginTurnTracking()

		await controller.test_handleControlRequest(
			requestID: "auto-1",
			subtype: "can_use_tool",
			request: [
				"tool_name": "mcp__RepoPrompt__get_file_tree",
				"tool_use_id": "toolu_auto_failure",
				"input": [:]
			]
		)

		let received = await collector.value
		XCTAssertTrue(
			received.containsError(containing: "Failed auto-approving RepoPrompt Claude permission request"),
			"Expected auto-approval send failure error, got: \(received.debugSummary)"
		)
		XCTAssertTrue(
			received.containsTurnCompleted(turnID: turnID, status: .failed),
			"Expected active turn to fail, got: \(received.debugSummary)"
		)
	}

	func testShutdownFinishesEventsStream() async {
		let controller = ClaudeNativeProcessSessionController(
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil,
			config: ClaudeCodeAgentConfig.agentMode()
		)
		let events = await controller.events
		let finished = expectation(description: "events stream finished")
		let eventsTask = Task {
			for await _ in events {}
			finished.fulfill()
		}

		await controller.shutdown()
		await fulfillment(of: [finished], timeout: 1.0)
		eventsTask.cancel()
	}

	func testAgentModeConfigProvidesMCPEnvironmentOverrides() {
		let config = ClaudeCodeAgentConfig.agentMode()

		XCTAssertEqual(config.processEnvironmentOverrides["MCP_TIMEOUT"], "30000")
		XCTAssertEqual(config.processEnvironmentOverrides["MCP_TOOL_TIMEOUT"], "10800000")
		XCTAssertEqual(config.processEnvironmentOverrides["MAX_MCP_OUTPUT_TOKENS"], "25000")
	}

	func testNonAgentConfigsDoNotProvideMCPEnvironmentOverrides() {
		XCTAssertTrue(ClaudeCodeAgentConfig.discovery().processEnvironmentOverrides.isEmpty)
		XCTAssertTrue(ClaudeCodeAgentConfig.delegateEdit().processEnvironmentOverrides.isEmpty)
	}

	func testAgentModeConfigUsesModelSpecificEffortFallback() {
		let restoreDefaults = preserveUserDefaults(keys: [
			"claudeCodeEffortLevel",
			"claudeCodeEffortLevelsByModelSlug"
		])
		defer { restoreDefaults() }
		let defaults = UserDefaults.standard
		ClaudeAgentToolPreferences.setEffortLevel(.low, defaults: defaults)
		defaults.removeObject(forKey: "claudeCodeEffortLevelsByModelSlug")
		ClaudeAgentToolPreferences.setEffortLevel(.xhigh, forModelRaw: AgentModel.claudeOpus.rawValue, agentKind: .claudeCode, defaults: defaults)
		ClaudeAgentToolPreferences.setEffortLevel(.high, forModelRaw: AgentModel.claudeSonnet.rawValue, agentKind: .claudeCode, defaults: defaults)
		ClaudeAgentToolPreferences.setEffortLevel(.low, defaults: defaults)

		XCTAssertEqual(ClaudeCodeAgentConfig.agentMode(modelString: AgentModel.claudeOpus.rawValue).effortLevel, .xhigh)
		XCTAssertEqual(ClaudeCodeAgentConfig.agentMode(modelString: AgentModel.claudeSonnet.rawValue).effortLevel, .high)
		XCTAssertEqual(ClaudeCodeAgentConfig.agentMode().effortLevel, .low)
		XCTAssertEqual(
			ClaudeCodeAgentConfig.agentMode(modelString: AgentModel.claudeSonnet.rawValue, effortLevel: .medium).effortLevel,
			.medium
		)
	}

	func testEffectiveLaunchEnvironmentAppliesAgentModeAndResolverOverrides() async {
		let controller = ClaudeNativeProcessSessionController(
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil,
			config: ClaudeCodeAgentConfig.agentMode(
				toolSearchEnabled: false,
				effortLevel: .high
			)
		)

		let environment = await controller.test_effectiveLaunchEnvironment(
			base: [
				"PATH": "/usr/bin",
				"HOME": "/tmp/repoprompt-tests",
				"NODE_OPTIONS": "--inspect"
			],
			resolverOverrides: [
				"API_TIMEOUT_MS": "3000000",
				"ANTHROPIC_BASE_URL": "https://api.z.ai/api/anthropic",
				"ENABLE_CLAUDEAI_MCP_SERVERS": "resolver-wins",
				"NODE_OPTIONS": "--inspect-brk"
			]
		)

		XCTAssertEqual(environment["MCP_TIMEOUT"], "30000")
		XCTAssertEqual(environment["MCP_TOOL_TIMEOUT"], "10800000")
		XCTAssertEqual(environment["MAX_MCP_OUTPUT_TOKENS"], "25000")
		XCTAssertEqual(environment["API_TIMEOUT_MS"], "3000000")
		XCTAssertEqual(environment["ANTHROPIC_BASE_URL"], "https://api.z.ai/api/anthropic")
		XCTAssertEqual(environment["CLAUDE_CODE_ENTRYPOINT"], "sdk-ts")
		XCTAssertEqual(environment["ENABLE_TOOL_SEARCH"], "false")
		XCTAssertNil(environment["CLAUDE_CODE_EFFORT_LEVEL"])
		XCTAssertEqual(environment["ENABLE_CLAUDEAI_MCP_SERVERS"], "resolver-wins")
		XCTAssertNil(environment["NODE_OPTIONS"])
	}

	func testEffectiveLaunchEnvironmentRemovesResolverAuthKeys() async {
		let controller = ClaudeNativeProcessSessionController(
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil,
			config: ClaudeCodeAgentConfig.agentMode()
		)

		let environment = await controller.test_effectiveLaunchEnvironment(
			base: [
				"PATH": "/usr/bin",
				"ANTHROPIC_AUTH_TOKEN": "inherited-token",
				"ANTHROPIC_API_KEY": "inherited-key"
			],
			resolverOverrides: ["ANTHROPIC_API_KEY": "resolver-key"],
			resolverRemovedKeys: ["ANTHROPIC_AUTH_TOKEN"]
		)

		XCTAssertEqual(environment["ANTHROPIC_API_KEY"], "resolver-key")
		XCTAssertNil(environment["ANTHROPIC_AUTH_TOKEN"])
	}

	func testEffectiveLaunchEnvironmentDoesNotSetNativeEffortEnvironment() async {
		let controller = ClaudeNativeProcessSessionController(
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil,
			config: ClaudeCodeAgentConfig.agentMode(effortLevel: .xhigh)
		)

		let environment = await controller.test_effectiveLaunchEnvironment(
			base: ["PATH": "/usr/bin"]
		)

		XCTAssertNil(environment["CLAUDE_CODE_EFFORT_LEVEL"])
	}

	func testEncodedClaudeConfigStripsModelAndBuildsXHighFlagSettings() async throws {
		let config = ClaudeCodeAgentConfig.agentMode(
			modelString: "opus:xhigh",
			effortLevel: .medium
		)
		XCTAssertEqual(config.modelString, AgentModel.claudeOpus.rawValue)
		XCTAssertEqual(config.effortLevel, .xhigh)

		let controller = ClaudeNativeProcessSessionController(
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil,
			config: config
		)

		let args = await controller.test_buildArguments(existingSessionID: nil, model: nil)
		XCTAssertFalse(args.contains("--model"))
		XCTAssertFalse(args.contains("opus:xhigh"))

		let maybeRequest = await controller.test_buildApplyFlagSettingsRequest(
			model: config.modelString,
			effortLevel: config.effortLevel
		)
		let request = try XCTUnwrap(maybeRequest)
		XCTAssertEqual(request["subtype"] as? String, "apply_flag_settings")
		let settings = try XCTUnwrap(request["settings"] as? [String: Any])
		XCTAssertEqual(settings["model"] as? String, AgentModel.claudeOpus.rawValue)
		XCTAssertEqual(settings["effortLevel"] as? String, ClaudeCodeEffortLevel.xhigh.envValue)

		let environment = await controller.test_effectiveLaunchEnvironment(
			base: ["PATH": "/usr/bin"]
		)
		XCTAssertNil(environment["CLAUDE_CODE_EFFORT_LEVEL"])
	}

	func testEncodedClaudeModelOverrideBuildsFlagSettingsInsteadOfArguments() async throws {
		let controller = ClaudeNativeProcessSessionController(
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil,
			config: ClaudeCodeAgentConfig.agentMode()
		)

		let specifier = ClaudeModelSpecifier(raw: "opus[1m]:max")
		let args = await controller.test_buildArguments(existingSessionID: nil, model: "opus[1m]:max")
		XCTAssertFalse(args.contains("--model"))
		XCTAssertFalse(args.contains("opus[1m]:max"))

		let maybeRequest = await controller.test_buildApplyFlagSettingsRequest(
			model: specifier.runtimeModelParam,
			effortLevel: specifier.explicitEffortLevel
		)
		let request = try XCTUnwrap(maybeRequest)
		XCTAssertEqual(request["subtype"] as? String, "apply_flag_settings")
		let settings = try XCTUnwrap(request["settings"] as? [String: Any])
		XCTAssertEqual(settings["model"] as? String, AgentModel.claudeOpus1m.rawValue)
		XCTAssertEqual(settings["effortLevel"] as? String, ClaudeCodeEffortLevel.max.envValue)
	}

	func testResolveApplyFlagSettingsUsesSuppliedEffortForLiveUpdates() async throws {
		let controller = ClaudeNativeProcessSessionController(
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil,
			config: ClaudeCodeAgentConfig.agentMode(effortLevel: .low),
			environmentResolver: FixedClaudeLaunchEnvironmentResolver(effectiveModel: AgentModel.claudeOpus.rawValue)
		)

		let maybeRequest = try await controller.test_resolveApplyFlagSettingsRequest(
			model: AgentModel.claudeOpus.rawValue,
			effortLevel: .high
		)
		let request = try XCTUnwrap(maybeRequest)
		let settings = try XCTUnwrap(request["settings"] as? [String: Any])
		XCTAssertEqual(settings["model"] as? String, AgentModel.claudeOpus.rawValue)
		XCTAssertEqual(settings["effortLevel"] as? String, ClaudeCodeEffortLevel.high.envValue)
	}

	func testResolveApplyFlagSettingsLetsEncodedModelEffortOverrideSuppliedPreference() async throws {
		let controller = ClaudeNativeProcessSessionController(
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil,
			config: ClaudeCodeAgentConfig.agentMode(effortLevel: .low),
			environmentResolver: FixedClaudeLaunchEnvironmentResolver(effectiveModel: AgentModel.claudeOpus.rawValue)
		)

		let maybeRequest = try await controller.test_resolveApplyFlagSettingsRequest(
			model: ClaudeModelSpecifier.encodedRaw(baseModelRaw: AgentModel.claudeOpus.rawValue, effort: .max),
			effortLevel: .high
		)
		let request = try XCTUnwrap(maybeRequest)
		let settings = try XCTUnwrap(request["settings"] as? [String: Any])
		XCTAssertEqual(settings["model"] as? String, AgentModel.claudeOpus.rawValue)
		XCTAssertEqual(settings["effortLevel"] as? String, ClaudeCodeEffortLevel.max.envValue)
	}

	func testKimiAgentModeConfigSuppressesEffortLevel() {
		let config = ClaudeCodeAgentConfig.agentMode(
			modelString: "kimi-code:high",
			runtimeVariant: .kimi,
			effortLevel: .max
		)

		XCTAssertEqual(config.modelString, AgentModel.kimiCode.rawValue)
		XCTAssertNil(config.effortLevel)
		XCTAssertTrue(config.effortEnvironmentOverrides.isEmpty)
	}

	func testKimiNativeFlagSettingsSuppressModelAndEffort() async throws {
		let controller = ClaudeNativeProcessSessionController(
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil,
			config: ClaudeCodeAgentConfig.agentMode(
				modelString: AgentModel.kimiCode.rawValue,
				runtimeVariant: .kimi,
				effortLevel: .high
			),
			environmentResolver: FixedClaudeLaunchEnvironmentResolver(
				effectiveModel: nil,
				backend: .compatible(.kimi),
				suppressesEffortSettings: true
			)
		)

		let request = try await controller.test_resolveApplyFlagSettingsRequest(
			model: AgentModel.kimiCode.rawValue,
			effortLevel: .max
		)
		XCTAssertNil(request)
	}

	func testDefaultClaudeModelIsOmittedFromFlagSettingsButEffortIsPreserved() async throws {
		let controller = ClaudeNativeProcessSessionController(
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil,
			config: ClaudeCodeAgentConfig.agentMode()
		)

		let maybeRequest = await controller.test_buildApplyFlagSettingsRequest(
			model: AgentModel.defaultModel.rawValue,
			effortLevel: .xhigh
		)
		let request = try XCTUnwrap(maybeRequest)
		let settings = try XCTUnwrap(request["settings"] as? [String: Any])
		XCTAssertNil(settings["model"])
		XCTAssertEqual(settings["effortLevel"] as? String, ClaudeCodeEffortLevel.xhigh.envValue)
	}

	func testEmptyNativeFlagSettingsRequestIsOmitted() async {
		let controller = ClaudeNativeProcessSessionController(
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil,
			config: ClaudeCodeAgentConfig.agentMode()
		)

		let empty = await controller.test_buildApplyFlagSettingsRequest()
		let defaultModelOnly = await controller.test_buildApplyFlagSettingsRequest(model: "  default  ", effortLevel: nil)
		XCTAssertNil(empty)
		XCTAssertNil(defaultModelOnly)
	}

	func testHeadlessClaudeDiscoveryConfigStripsModelAndCarriesEffortEnvironment() throws {
		let config = ClaudeCodeAgentConfig.discovery(modelString: "opus[1m]:max")
		XCTAssertEqual(config.modelString, AgentModel.claudeOpus1m.rawValue)
		XCTAssertEqual(config.effortLevel, .max)
		XCTAssertEqual(config.effortEnvironmentOverrides["CLAUDE_CODE_EFFORT_LEVEL"], ClaudeCodeEffortLevel.max.envValue)

		let provider = ClaudeCodeAgentProvider(
			runner: CLIProcessRunner(config: CLIProcessConfiguration(command: "echo")),
			config: config
		)
		let context = HeadlessAgentContext(
			runID: UUID(),
			configURL: nil,
			environment: [:],
			launchEnvironment: ClaudeCodeLaunchEnvironment(
				effectiveModel: config.modelString,
				environmentOverrides: [:],
				backend: .defaultClaude
			)
		)
		let args = provider.buildArguments(context: context)
		let modelIndex = try XCTUnwrap(args.firstIndex(of: "--model"))
		XCTAssertEqual(args[args.index(after: modelIndex)], AgentModel.claudeOpus1m.rawValue)
		XCTAssertFalse(args.contains("opus[1m]:max"))
	}

	func testAllowPermissionResponsePayloadIncludesUpdatedInputAndToolUseID() {
		let pendingRequest: [String: Any] = [
			"tool_use_id": "toolu_123",
			"input": [
				"command": "echo hi",
				"description": "demo"
			]
		]

		let payload = ClaudeNativeProcessSessionController.allowPermissionResponsePayload(
			pendingRequest: pendingRequest,
			includeUpdatedPermissions: false
		)

		XCTAssertEqual(payload["behavior"] as? String, "allow")
		let updatedInput = payload["updatedInput"] as? [String: Any]
		XCTAssertEqual(updatedInput?["command"] as? String, "echo hi")
		XCTAssertEqual(updatedInput?["description"] as? String, "demo")
		XCTAssertEqual(payload["toolUseID"] as? String, "toolu_123")
		XCTAssertNil(payload["updatedPermissions"])
	}

	func testAllowPermissionResponsePayloadIncludesPermissionSuggestionsWhenRequested() {
		let suggestions: [[String: Any]] = [
			[
				"type": "setMode",
				"mode": "acceptEdits",
				"destination": "session"
			]
		]
		let pendingRequest: [String: Any] = [
			"tool_use_id": "toolu_456",
			"input": ["path": "README.md"],
			"permission_suggestions": suggestions
		]

		let payload = ClaudeNativeProcessSessionController.allowPermissionResponsePayload(
			pendingRequest: pendingRequest,
			includeUpdatedPermissions: true
		)

		XCTAssertEqual(payload["behavior"] as? String, "allow")
		let updatedPermissions = payload["updatedPermissions"] as? [[String: Any]]
		XCTAssertEqual(updatedPermissions?.count, 1)
		XCTAssertEqual(updatedPermissions?.first?["type"] as? String, "setMode")
	}

	func testShouldAutoApproveRepoPromptPermissionRequestForRepoPromptToolName() {
		let shouldAutoApprove = ClaudeNativeProcessSessionController.shouldAutoApproveRepoPromptPermissionRequest(
			toolName: "mcp__RepoPrompt__get_file_tree",
			input: [:]
		)

		XCTAssertTrue(shouldAutoApprove)
	}

	func testShouldAutoApproveRepoPromptPermissionRequestForRepoPromptServerName() {
		let shouldAutoApprove = ClaudeNativeProcessSessionController.shouldAutoApproveRepoPromptPermissionRequest(
			toolName: "mcp_call",
			input: ["server_name": "RepoPrompt"]
		)

		XCTAssertTrue(shouldAutoApprove)
	}

	func testShouldAutoApproveRepoPromptPermissionRequestForNestedToolName() {
		let shouldAutoApprove = ClaudeNativeProcessSessionController.shouldAutoApproveRepoPromptPermissionRequest(
			toolName: "mcp_call",
			input: [
				"tool": [
					"name": "mcp__RepoPrompt__read_file"
				]
			]
		)

		XCTAssertTrue(shouldAutoApprove)
	}

	func testShouldAutoApproveRepoPromptPermissionRequestForPermissionSuggestionRule() {
		let shouldAutoApprove = ClaudeNativeProcessSessionController.shouldAutoApproveRepoPromptPermissionRequest(
			toolName: "mcp_call",
			input: [
				"permission_suggestions": [
					[
						"rules": [
							["toolName": "mcp__RepoPrompt__file_search"]
						]
					]
				]
			]
		)

		XCTAssertTrue(shouldAutoApprove)
	}

	func testRecoverablePlaintextAssistantFragmentReturnsNarrativeText() {
		let line = "The investigation was exploring why tool events appeared while assistant text never rendered."
		let recovered = ClaudeNativeProcessSessionController.recoverablePlaintextAssistantFragment(
			from: Data(line.utf8)
		)
		XCTAssertEqual(recovered, line)
	}

	func testRecoverablePlaintextAssistantFragmentRejectsCodeLikeFragments() {
		let line = ".runningStatusText = nil\n\tviewModel?.setAgentRunActive(session.tabID, isActive: false)"
		let recovered = ClaudeNativeProcessSessionController.recoverablePlaintextAssistantFragment(
			from: Data(line.utf8)
		)
		XCTAssertNil(recovered)
	}

	func testDetermineTurnStatusTreatsExecutionErrorsAsFailed() async {
		let controller = ClaudeNativeProcessSessionController(
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil,
			config: ClaudeCodeAgentConfig.agentMode()
		)
		let status = await controller.test_determineTurnStatus(
			payload: [
				"type": "result",
				"subtype": "error_during_execution",
				"is_error": false,
				"errors": ["SyntaxError: JSON Parse error"]
			]
		)
		XCTAssertEqual(status, .failed)
	}

	func testDetermineTurnStatusTreatsAbortedExecutionErrorsAsCancelled() async {
		let controller = ClaudeNativeProcessSessionController(
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil,
			config: ClaudeCodeAgentConfig.agentMode()
		)
		let status = await controller.test_determineTurnStatus(
			payload: [
				"type": "result",
				"subtype": "error_during_execution",
				"is_error": false,
				"errors": ["Error: Request was aborted."]
			]
		)
		XCTAssertEqual(status, .cancelled)
	}

	func testDetermineTurnStatusTreatsInterruptedTurnErrorsAsCancelled() async {
		let controller = ClaudeNativeProcessSessionController(
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil,
			config: ClaudeCodeAgentConfig.agentMode()
		)
		// Simulate that an interrupt was sent for the current turn.
		await controller.test_setTurnWasInterrupted(true)
		let status = await controller.test_determineTurnStatus(
			payload: [
				"type": "result",
				"subtype": "error_during_execution",
				"is_error": false,
				"errors": ["SyntaxError: JSON Parse error"]
			]
		)
		// When we know the turn was interrupted, even error_during_execution
		// should be classified as .cancelled (the errors are abort side effects).
		XCTAssertEqual(status, .cancelled)
	}

	func testShouldSuppressUserFacingStreamResultForKnownClaudeAbortArtifact() {
		let result = AIStreamResult(
			type: "error",
			text: """
			SyntaxError: JSON Parse error: Unrecognized token '/'
			at <parse> (:0)
			at parse (unknown)
			at <anonymous> (/$bunfs/root/src/entrypoints/cli.js:98:1134)
			"""
		)

		XCTAssertTrue(ClaudeNativeProcessSessionController.shouldSuppressUserFacingStreamResult(result))
	}

	func testShouldSuppressUserFacingStreamResultForClaudeInternalStopReasonDiagnostic() {
		let result = AIStreamResult(
			type: "error",
			text: "[ede_diagnostic] result_type=user last_content_type=n/a stop_reason=tool_use"
		)

		XCTAssertTrue(ClaudeNativeProcessSessionController.shouldSuppressUserFacingStreamResult(result))
	}

	func testShouldSuppressUserFacingStreamResultForGenericClaudeDiagnosticError() {
		let result = AIStreamResult(
			type: "error",
			text: "Internal diagnostic: provider emitted non-user-facing trace output"
		)

		XCTAssertTrue(ClaudeNativeProcessSessionController.shouldSuppressUserFacingStreamResult(result))
	}

	func testShouldNotSuppressUserFacingStreamResultForLegitimateDiagnosticError() {
		let result = AIStreamResult(
			type: "error",
			text: "Error: diagnostic upload failed for the selected workspace"
		)

		XCTAssertFalse(ClaudeNativeProcessSessionController.shouldSuppressUserFacingStreamResult(result))
	}

	func testShouldNotSuppressUserFacingStreamResultForLegitimateClaudeError() {
		let result = AIStreamResult(
			type: "error",
			text: "Error: failed to parse config: JSON Parse error at line 4"
		)

		XCTAssertFalse(ClaudeNativeProcessSessionController.shouldSuppressUserFacingStreamResult(result))
	}

	// MARK: - Background Task Notification Suppression

	func testShouldSuppressTaskNotificationSystemMessage() {
		let result = AIStreamResult(
			type: "system",
			text: "Task update — blj2xgod6 — failed — Background command \"Run transcript services tests via daemon\" failed with exit code 1"
		)

		XCTAssertTrue(ClaudeNativeProcessSessionController.shouldSuppressUserFacingStreamResult(result))
	}

	func testShouldSuppressTaskStartedSystemMessage() {
		let result = AIStreamResult(
			type: "system",
			text: "Task started — abc123 — Running unit tests"
		)

		XCTAssertTrue(ClaudeNativeProcessSessionController.shouldSuppressUserFacingStreamResult(result))
	}

	func testShouldNotSuppressLegitimateSystemMessage() {
		let result = AIStreamResult(
			type: "system",
			text: "Context compacted — trigger: auto — at ~180000 tokens"
		)

		XCTAssertFalse(ClaudeNativeProcessSessionController.shouldSuppressUserFacingStreamResult(result))
	}

	// MARK: - Initialize Contract Tests

	func testFreshStartInitializeRequestOmitsPromptFields() async {
		let controller = ClaudeNativeProcessSessionController(
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil,
			config: ClaudeCodeAgentConfig.agentMode()
		)
		let request = await controller.test_buildInitializeRequest()
		XCTAssertEqual(request["subtype"] as? String, "initialize")
		XCTAssertNil(request["systemPrompt"])
		XCTAssertNil(request["appendSystemPrompt"])
	}

	func testInitializeRequestDoesNotCarryPermissionMode() async {
		let controller = ClaudeNativeProcessSessionController(
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil,
			config: ClaudeCodeAgentConfig.agentMode(permissionMode: "auto")
		)
		let request = await controller.test_buildInitializeRequest()
		XCTAssertEqual(request["subtype"] as? String, "initialize")
		XCTAssertNil(request["permissionMode"])
		XCTAssertNil(request["permission_mode"])
		XCTAssertNil(request["permissionPromptTool"])
	}

	func testInitialPermissionModeUsesSetPermissionModeControlRequest() async throws {
		let controller = ClaudeNativeProcessSessionController(
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil,
			config: ClaudeCodeAgentConfig.agentMode(permissionMode: "auto")
		)

		let maybeRequest = await controller.test_buildSetPermissionModeRequest()
		let request = try XCTUnwrap(maybeRequest)
		XCTAssertEqual(request["subtype"] as? String, "set_permission_mode")
		XCTAssertEqual(request["mode"] as? String, "auto")
	}

	func testInitialPermissionModeRequestTrimsAndOmitsEmptyModes() async throws {
		let controller = ClaudeNativeProcessSessionController(
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil,
			config: ClaudeCodeAgentConfig.agentMode(permissionMode: "acceptEdits")
		)

		let maybeTrimmed = await controller.test_buildSetPermissionModeRequest(permissionMode: "  acceptEdits  ")
		let trimmed = try XCTUnwrap(maybeTrimmed)
		XCTAssertEqual(trimmed["subtype"] as? String, "set_permission_mode")
		XCTAssertEqual(trimmed["mode"] as? String, "acceptEdits")

		let empty = await controller.test_buildSetPermissionModeRequest(permissionMode: "   ")
		XCTAssertNil(empty)
	}

	func testInitializeRequestIncludesExplicitEmptySystemPromptOverride() async {
		let controller = ClaudeNativeProcessSessionController(
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil,
			config: ClaudeCodeAgentConfig.agentMode()
		)
		let request = await controller.test_buildInitializeRequest(systemPromptOverride: "")
		XCTAssertEqual(request["subtype"] as? String, "initialize")
		XCTAssertEqual(request["systemPrompt"] as? String, "")
		XCTAssertNil(request["appendSystemPrompt"])
	}

	func testInitializeRequestIncludesRepoPromptSystemPromptOverrideWhenProvided() async {
		let controller = ClaudeNativeProcessSessionController(
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil,
			config: ClaudeCodeAgentConfig.agentMode()
		)
		let request = await controller.test_buildInitializeRequest(systemPromptOverride: "RepoPrompt native instructions")
		XCTAssertEqual(request["subtype"] as? String, "initialize")
		XCTAssertEqual(request["systemPrompt"] as? String, "RepoPrompt native instructions")
		XCTAssertNil(request["appendSystemPrompt"])
	}

	func testInitializeRequestDoesNotVaryForResumeOrInstructions() async {
		let controller = ClaudeNativeProcessSessionController(
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil,
			config: ClaudeCodeAgentConfig.agentMode()
		)
		let request = await controller.test_buildInitializeRequest()
		XCTAssertEqual(request["subtype"] as? String, "initialize")
		XCTAssertNil(request["systemPrompt"])
		XCTAssertNil(request["appendSystemPrompt"])
	}

	func testEmptyInstructionsOmitsBothPromptFields() async {
		let controller = ClaudeNativeProcessSessionController(
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil,
			config: ClaudeCodeAgentConfig.agentMode()
		)
		let freshRequest = await controller.test_buildInitializeRequest()
		XCTAssertEqual(freshRequest["subtype"] as? String, "initialize")
		XCTAssertNil(freshRequest["systemPrompt"])
		XCTAssertNil(freshRequest["appendSystemPrompt"])

		let resumedRequest = await controller.test_buildInitializeRequest()
		XCTAssertEqual(resumedRequest["subtype"] as? String, "initialize")
		XCTAssertNil(resumedRequest["systemPrompt"])
		XCTAssertNil(resumedRequest["appendSystemPrompt"])
	}

	func testClaudeCodePromptDeliveryDecoratesUserMessageWithXMLInstructions() {
		let decorated = ClaudeCodePromptDelivery.decoratedUserMessage(
			"User task",
			instructions: "RepoPrompt instructions"
		)

		XCTAssertTrue(decorated.contains("<claude_code_instructions>"))
		XCTAssertTrue(decorated.contains("RepoPrompt instructions"))
		XCTAssertTrue(decorated.contains("</claude_code_instructions>"))
		XCTAssertTrue(decorated.hasSuffix("User task"))
	}

	func testCLIArgsNoLongerContainPromptFlags() async {
		let controller = ClaudeNativeProcessSessionController(
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil,
			config: ClaudeCodeAgentConfig.agentMode()
		)

		// Fresh start
		let freshArgs = await controller.test_buildArguments(
			existingSessionID: nil,
			model: nil
		)
		XCTAssertFalse(freshArgs.contains("--system-prompt"), "CLI args should not contain --system-prompt")
		XCTAssertFalse(freshArgs.contains("--append-system-prompt"), "CLI args should not contain --append-system-prompt")

		// Resume
		let resumeArgs = await controller.test_buildArguments(
			existingSessionID: "session-abc",
			model: nil
		)
		XCTAssertFalse(resumeArgs.contains("--system-prompt"), "CLI args should not contain --system-prompt on resume")
		XCTAssertFalse(resumeArgs.contains("--append-system-prompt"), "CLI args should not contain --append-system-prompt on resume")
		XCTAssertTrue(resumeArgs.contains("--resume"), "CLI args should still contain --resume")
		XCTAssertTrue(resumeArgs.contains("session-abc"), "CLI args should contain the session ID for resume")
	}

	func testCLIArgsKeepPermissionPromptToolAndDeferManualPermissionModeToControlProtocol() async throws {
		let controller = ClaudeNativeProcessSessionController(
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil,
			config: ClaudeCodeAgentConfig.agentMode(permissionMode: "acceptEdits")
		)

		let args = await controller.test_buildArguments(existingSessionID: nil, model: nil)
		let promptToolIndex = try XCTUnwrap(args.firstIndex(of: "--permission-prompt-tool"))
		XCTAssertEqual(args[args.index(after: promptToolIndex)], "stdio")
		XCTAssertFalse(args.contains("--permission-mode"))
	}

	func testCLIArgsKeepPermissionPromptToolAndDeferClaudeAutoModeToControlProtocol() async throws {
		let controller = ClaudeNativeProcessSessionController(
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil,
			config: ClaudeCodeAgentConfig.agentMode(permissionMode: "auto")
		)

		let args = await controller.test_buildArguments(existingSessionID: nil, model: nil)
		let promptToolIndex = try XCTUnwrap(args.firstIndex(of: "--permission-prompt-tool"))
		XCTAssertEqual(args[args.index(after: promptToolIndex)], "stdio")
		XCTAssertFalse(args.contains("--permission-mode"))
	}

	func testCLIArgsKeepBypassAvailabilityFlagWhenBypassModeIsAppliedByControlProtocol() async {
		let controller = ClaudeNativeProcessSessionController(
			runID: UUID(),
			tabID: UUID(),
			windowID: 1,
			workspacePath: nil,
			config: ClaudeCodeAgentConfig.agentMode(permissionMode: "bypassPermissions")
		)

		let args = await controller.test_buildArguments(existingSessionID: nil, model: nil)
		XCTAssertFalse(args.contains("--permission-mode"))
		XCTAssertTrue(args.contains("--allow-dangerously-skip-permissions"))
	}

	func testParseInitializeResponseSnapshotCapturesAllFields() {
		let response: [String: Any] = [
			"commands": [
				["name": "/help", "description": "Show help", "argumentHint": ""],
				["name": "/commit", "description": "Create a commit", "argumentHint": "message"]
			],
			"agents": [
				["name": "code-review", "description": "Reviews code changes", "model": "claude-sonnet-4-5-20250514"],
				["name": "pair", "description": "Pair programming"]
			],
			"output_style": "concise",
			"available_output_styles": ["concise", "verbose", "minimal"],
			"account": [
				"email": "user@example.com",
				"organization": "Acme",
				"subscriptionType": "pro",
				"tokenSource": "anthropic",
				"apiKeySource": "env",
				"apiProvider": "firstParty"
			],
			"pid": 12345,
			"models": [["id": "claude-opus-4-6", "name": "Opus"]],
			"fast_mode_state": ["enabled": true]
		]

		let snapshot = ClaudeNativeProcessSessionController.parseInitializeResponseSnapshot(from: response)

		XCTAssertEqual(snapshot.commands.count, 2)
		XCTAssertEqual(snapshot.commands[0].name, "/help")
		XCTAssertEqual(snapshot.commands[1].name, "/commit")
		XCTAssertEqual(snapshot.commands[1].argumentHint, "message")

		XCTAssertEqual(snapshot.agents.count, 2)
		XCTAssertEqual(snapshot.agents[0].name, "code-review")
		XCTAssertEqual(snapshot.agents[0].model, "claude-sonnet-4-5-20250514")
		XCTAssertEqual(snapshot.agents[1].name, "pair")
		XCTAssertNil(snapshot.agents[1].model)

		XCTAssertEqual(snapshot.outputStyle, "concise")
		XCTAssertEqual(snapshot.availableOutputStyles, ["concise", "verbose", "minimal"])

		XCTAssertEqual(snapshot.account?.email, "user@example.com")
		XCTAssertEqual(snapshot.account?.organization, "Acme")
		XCTAssertEqual(snapshot.account?.subscriptionType, "pro")
		XCTAssertEqual(snapshot.account?.tokenSource, "anthropic")
		XCTAssertEqual(snapshot.account?.apiKeySource, "env")
		XCTAssertEqual(snapshot.account?.apiProvider, "firstParty")

		XCTAssertEqual(snapshot.pid, 12345)
		XCTAssertNotNil(snapshot.modelsJSON)
		XCTAssertNotNil(snapshot.fastModeStateJSON)
	}

	func testParseInitializeResponseSnapshotToleratsMissingFields() {
		let snapshot = ClaudeNativeProcessSessionController.parseInitializeResponseSnapshot(from: [:])

		XCTAssertTrue(snapshot.commands.isEmpty)
		XCTAssertTrue(snapshot.agents.isEmpty)
		XCTAssertNil(snapshot.outputStyle)
		XCTAssertTrue(snapshot.availableOutputStyles.isEmpty)
		XCTAssertNil(snapshot.account)
		XCTAssertNil(snapshot.pid)
		XCTAssertNil(snapshot.modelsJSON)
		XCTAssertNil(snapshot.fastModeStateJSON)
	}

	func testParseInitializeResponseSnapshotSkipsMalformedEntries() {
		let response: [String: Any] = [
			"commands": [
				["name": "/help", "description": "Show help", "argumentHint": ""],
				["description": "Missing name"],  // no name, should be skipped
				["name": "", "description": "Empty name"]  // empty name, should be skipped
			],
			"agents": [
				["name": "valid", "description": "Valid agent"],
				["description": "Missing name agent"]  // should be skipped
			]
		]

		let snapshot = ClaudeNativeProcessSessionController.parseInitializeResponseSnapshot(from: response)
		XCTAssertEqual(snapshot.commands.count, 1)
		XCTAssertEqual(snapshot.commands[0].name, "/help")
		XCTAssertEqual(snapshot.agents.count, 1)
		XCTAssertEqual(snapshot.agents[0].name, "valid")
	}
}

private struct FixedClaudeLaunchEnvironmentResolver: ClaudeCodeLaunchEnvironmentResolving {
	let effectiveModel: String?
	var environmentOverrides: [String: String] = [:]
	var backend: ClaudeCodeLaunchEnvironment.Backend = .defaultClaude
	var suppressesEffortSettings = false

	func resolve(
		variant _: ClaudeCodeRuntimeVariant,
		requestedModel _: String?
	) async throws -> ClaudeCodeLaunchEnvironment {
		ClaudeCodeLaunchEnvironment(
			effectiveModel: effectiveModel,
			environmentOverrides: environmentOverrides,
			backend: backend,
			suppressesEffortSettings: suppressesEffortSettings
		)
	}

}

private func preserveUserDefaults(keys: [String]) -> () -> Void {
	let defaults = UserDefaults.standard
	let previousValues = keys.reduce(into: [String: Any]()) { result, key in
		if let value = defaults.object(forKey: key) {
			result[key] = value
		}
	}
	return {
		for key in keys {
			if let previousValue = previousValues[key] {
				defaults.set(previousValue, forKey: key)
			} else {
				defaults.removeObject(forKey: key)
			}
		}
	}
}

private func collectEventsUntilFinished(
	from events: AsyncStream<ClaudeNativeProcessSessionController.Event>
) async -> [ClaudeNativeProcessSessionController.Event] {
	var received: [ClaudeNativeProcessSessionController.Event] = []
	for await event in events {
		received.append(event)
	}
	return received
}

private extension Array where Element == ClaudeNativeProcessSessionController.Event {
	func containsError(containing text: String) -> Bool {
		contains { event in
			if case .error(let message) = event {
				return message.contains(text)
			}
			return false
		}
	}

	func containsTurnCompleted(
		turnID: UUID,
		status expectedStatus: ClaudeNativeProcessSessionController.TurnStatus
	) -> Bool {
		contains { event in
			if case .turnCompleted(let candidateTurnID, let status) = event,
				candidateTurnID == turnID {
				return status.matches(expectedStatus)
			}
			return false
		}
	}

	var debugSummary: String {
		map { event in
			switch event {
			case .stream(let result):
				return "stream(\(result.type))"
			case .runtimeInit:
				return "runtimeInit"
			case .approvalRequest(let request):
				return "approvalRequest(\(request.requestID.displayValue))"
			case .approvalCancelled(let requestID):
				return "approvalCancelled(\(requestID))"
			case .turnCompleted(let turnID, let status):
				return "turnCompleted(\(turnID.uuidString), \(status))"
			case .error(let message):
				return "error(\(message))"
			}
		}
		.joined(separator: ", ")
	}
}

private extension ClaudeNativeProcessSessionController.TurnStatus {
	func matches(_ other: ClaudeNativeProcessSessionController.TurnStatus) -> Bool {
		switch (self, other) {
		case (.completed, .completed), (.cancelled, .cancelled), (.failed, .failed):
			return true
		default:
			return false
		}
	}
}
