import XCTest
import MCP
@testable import RepoPrompt

@MainActor
final class AppSettingsMCPServiceTests: XCTestCase {
	private var temporaryDirectories: [URL] = []
	private var userDefaultsSuites: [String] = []

	override func tearDownWithError() throws {
		for directory in temporaryDirectories {
			try? FileManager.default.removeItem(at: directory)
		}
		for suite in userDefaultsSuites {
			UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
		}
		temporaryDirectories = []
		userDefaultsSuites = []
		try super.tearDownWithError()
	}

	func testListUsesSnakeCaseCatalogCanIncludeValuesAndExcludesSensitiveSurfaces() async throws {
		let harness = try await makeHarness()
		harness.store.setShowTooltips(false)

		let listObject = try await call(harness.tool, ["op": .string("list")])
		let settings = try settingsCatalog(from: listObject)
		let keys = Set(settings.compactMap { $0["key"]?.stringValue })
		let groups = Set(settings.compactMap { $0["group"]?.stringValue })

		XCTAssertEqual(listObject["status"]?.stringValue, "ok")
		XCTAssertEqual(listObject["supports_set"]?.boolValue, true)
		XCTAssertEqual(groups, ["ui", "prompt_packaging", "models", "context_builder", "mcp", "code_maps", "file_system", "agent_mode"])
		XCTAssertTrue(keys.contains("ui.appearance_mode"))
		XCTAssertTrue(keys.contains("ui.font_scale"))
		XCTAssertTrue(keys.contains("models.temperature_enabled"))
		XCTAssertTrue(keys.contains("models.planning_model"))
		XCTAssertTrue(keys.contains("context_builder.agent"))
		XCTAssertTrue(keys.contains("context_builder.model"))
		XCTAssertTrue(keys.contains("code_maps.globally_disabled"))
		XCTAssertTrue(keys.contains("file_system.global_ignore_defaults"))
		XCTAssertTrue(keys.contains("agent_mode.show_built_in_workflow_cleanup_guidance"))
		#if DEBUG
		XCTAssertTrue(keys.contains("agent_mode.claude_raw_event_logging_enabled"))
		XCTAssertTrue(keys.contains("agent_mode.claude_raw_event_log_file_path"))
		XCTAssertTrue(keys.contains("agent_mode.perf_diagnostics_enabled"))
		XCTAssertTrue(keys.contains("agent_mode.perf_diagnostics_os_log_enabled"))
		#endif

		// Old or re-grouped names must not leak through.
		XCTAssertFalse(keys.contains("ui.appearanceMode"))
		XCTAssertFalse(keys.contains("promptPackaging.setModelTemperature"))
		XCTAssertFalse(keys.contains("modelSelection.planningModel"))
		XCTAssertFalse(keys.contains("codeMaps.globallyDisabled"))
		XCTAssertFalse(keys.contains("prompt_packaging.model_temperature"))
		XCTAssertFalse(keys.contains("prompt_packaging.should_set_model_temperature"))
		XCTAssertFalse(keys.contains("prompt_packaging.custom_planning_prompt"))
		XCTAssertFalse(keys.contains("prompt_packaging.file_edit_format"))
		XCTAssertFalse(keys.contains("prompt_packaging.allow_diff_models_to_rewrite"))
		XCTAssertFalse(keys.contains("prompt_packaging.complex_edit_strategy"))
		XCTAssertFalse(keys.contains("editing.file_edit_format"))
		XCTAssertFalse(keys.contains("editing.allow_diff_models_to_rewrite"))
		XCTAssertFalse(keys.contains("editing.complex_edit_strategy"))
		XCTAssertFalse(keys.contains("model_selection.planning_model"))
		XCTAssertFalse(keys.contains("model_selection.preferred_compose_model"))
		XCTAssertFalse(keys.contains("model_selection.sync_chat_model_with_oracle"))
		XCTAssertFalse(keys.contains("fileSystem.respectGitignore"))
		XCTAssertFalse(keys.contains("ignore.globalIgnoreDefaults"))
		XCTAssertFalse(keys.contains("file_system.globalIgnoreDefaults"))

		// Dead / internal UI + MCP toggles should no longer be exposed.
		XCTAssertFalse(keys.contains("ui.use_transparency"))
		XCTAssertFalse(keys.contains("ui.collapse_latest_file_changes"))
		XCTAssertFalse(keys.contains("ui.experimental_attributed_text_editor"))
		XCTAssertFalse(keys.contains("mcp.temporarily_disable_presets"))
		XCTAssertFalse(keys.contains("mcp.auto_start"))
		XCTAssertFalse(keys.contains("mcp.server_start"))

		let forbiddenFragments = [
			"credential", "api_key", "apiKey", "permission", "disabled_tools", "disabledTools",
			"tool_acl", "workspace_approval", "workspaceApproval", "pro_edit",
			"model_override", "modelOverrides", "diff_overrides", "stream_overrides"
		]
		for key in keys {
			for fragment in forbiddenFragments {
				XCTAssertFalse(
					key.localizedCaseInsensitiveContains(fragment),
					"Catalog key '\(key)' should not expose forbidden fragment '\(fragment)'"
				)
			}
		}

		let mcpList = try await call(harness.tool, [
			"op": .string("list"),
			"group": .string("mcp")
		])
		let mcpSettings = try settingsCatalog(from: mcpList)
		let mcpKeys = Set(mcpSettings.compactMap { $0["key"]?.stringValue })
		XCTAssertEqual(mcpKeys, ["mcp.show_model_presets"])
		XCTAssertFalse(mcpKeys.contains("mcp.auto_start"))
		XCTAssertFalse(mcpKeys.contains("mcp.server_start"))

		let listWithValues = try await call(harness.tool, [
			"op": .string("list"),
			"group": .string("ui")
		])
		let uiSettings = try settingsCatalog(from: listWithValues)
		XCTAssertEqual(Set(uiSettings.compactMap { $0["group"]?.stringValue }), ["ui"])
		let showTooltips = try XCTUnwrap(uiSettings.first { $0["key"]?.stringValue == "ui.show_tooltips" })
		XCTAssertEqual(showTooltips["value"]?.boolValue, false)
		let fontScale = try XCTUnwrap(uiSettings.first { $0["key"]?.stringValue == "ui.font_scale" })
		XCTAssertEqual(fontScale["type"]?.stringValue, "number")
		XCTAssertEqual(fontScale["options_available"]?.boolValue, true)
		// Non-candidate settings must not advertise options_available.
		XCTAssertNotEqual(showTooltips["options_available"]?.boolValue, true)

		let settingsByKey = Dictionary(uniqueKeysWithValues: settings.compactMap { setting -> (String, [String: Value])? in
			guard let key = setting["key"]?.stringValue else { return nil }
			return (key, setting)
		})
		let planningModel = try XCTUnwrap(settingsByKey["models.planning_model"])
		XCTAssertEqual(planningModel["options_available"]?.boolValue, true)
		XCTAssertEqual(planningModel["label"]?.stringValue, "Oracle Model")
		let composeModel = try XCTUnwrap(settingsByKey["models.preferred_compose_model"])
		XCTAssertEqual(composeModel["options_available"]?.boolValue, true)
		XCTAssertEqual(composeModel["label"]?.stringValue, "Built-in Chat Model")
		let syncChatModel = try XCTUnwrap(settingsByKey["models.sync_chat_model_with_oracle"])
		XCTAssertEqual(syncChatModel["label"]?.stringValue, "Sync Built-in Chat with Oracle")
		let customPlanningPrompt = try XCTUnwrap(settingsByKey["models.custom_planning_prompt"])
		XCTAssertEqual(customPlanningPrompt["label"]?.stringValue, "Custom Oracle System Prompt")
		let contextBuilderAgent = try XCTUnwrap(settingsByKey["context_builder.agent"])
		XCTAssertNil(contextBuilderAgent["label"])
		let contextBuilderModel = try XCTUnwrap(settingsByKey["context_builder.model"])
		XCTAssertNil(contextBuilderModel["label"])
		// Representative non-candidate settings should not carry the flag.
		let appearance = try XCTUnwrap(settingsByKey["ui.appearance_mode"])
		XCTAssertNotEqual(appearance["options_available"]?.boolValue, true)
		let temperature = try XCTUnwrap(settingsByKey["models.temperature"])
		XCTAssertNotEqual(temperature["options_available"]?.boolValue, true)
		XCTAssertNil(showTooltips["label"])
	}

	func testListDetailedDefaultsTrueAndFalseOmitsRichCatalogFields() async throws {
		let harness = try await makeHarness()

		let defaultList = try await call(harness.tool, [
			"op": .string("list"),
			"group": .string("models")
		])
		XCTAssertEqual(defaultList["detailed"]?.boolValue, true)
		let defaultSettings = try settingsCatalog(from: defaultList)
		let defaultPlanningModel = try XCTUnwrap(defaultSettings.first { $0["key"]?.stringValue == "models.planning_model" })
		XCTAssertEqual(defaultPlanningModel["label"]?.stringValue, "Oracle Model")
		XCTAssertNotNil(defaultPlanningModel["description"])
		XCTAssertEqual(defaultPlanningModel["options_available"]?.boolValue, true)
		XCTAssertTrue(defaultPlanningModel["value"]?.isNull == true)

		let compactModels = try await call(harness.tool, [
			"op": .string("list"),
			"group": .string("models"),
			"detailed": .bool(false)
		])
		XCTAssertEqual(compactModels["detailed"]?.boolValue, false)
		let compactSettings = try settingsCatalog(from: compactModels)
		let compactPlanningModel = try XCTUnwrap(compactSettings.first { $0["key"]?.stringValue == "models.planning_model" })
		XCTAssertEqual(compactPlanningModel["type"]?.stringValue, "string|null")
		XCTAssertEqual(compactPlanningModel["options_available"]?.boolValue, true)
		XCTAssertTrue(compactPlanningModel["value"]?.isNull == true)
		XCTAssertNil(compactPlanningModel["description"])
		XCTAssertNil(compactPlanningModel["label"])
		XCTAssertNil(compactPlanningModel["value_format"])
		XCTAssertNil(compactPlanningModel["allowed_values"])
		XCTAssertNil(compactPlanningModel["allowed_items"])

		let compactUI = try await call(harness.tool, [
			"op": .string("list"),
			"group": .string("ui"),
			"detailed": .bool(false)
		])
		let uiSettings = try settingsCatalog(from: compactUI)
		let compactAppearance = try XCTUnwrap(uiSettings.first { $0["key"]?.stringValue == "ui.appearance_mode" })
		XCTAssertNil(compactAppearance["description"])
		XCTAssertNil(compactAppearance["allowed_values"])
	}

	func testOptionsDetailedDefaultsTrueAndFalseOmitsDescriptionsAndModelMetadata() async throws {
		let harness = try await makeHarness()

		let defaultEnvelope = try await call(harness.tool, [
			"op": .string("options"),
			"key": .string("models.planning_model"),
			"limit": .int(20)
		])
		XCTAssertEqual(defaultEnvelope["detailed"]?.boolValue, true)
		let defaultOptions = try XCTUnwrap(defaultEnvelope["options"]?.arrayValue).compactMap(\.objectValue)
		XCTAssertFalse(defaultOptions.isEmpty)

		let explicitDetailedEnvelope = try await call(harness.tool, [
			"op": .string("options"),
			"key": .string("models.planning_model"),
			"limit": .int(20),
			"detailed": .bool(true)
		])
		XCTAssertEqual(explicitDetailedEnvelope["detailed"]?.boolValue, true)
		let explicitDetailedOptions = try XCTUnwrap(explicitDetailedEnvelope["options"]?.arrayValue).compactMap(\.objectValue)
		XCTAssertEqual(
			defaultOptions.map { Set($0.keys) },
			explicitDetailedOptions.map { Set($0.keys) },
			"Omitting detailed should be equivalent to detailed=true."
		)

		let compactEnvelope = try await call(harness.tool, [
			"op": .string("options"),
			"key": .string("models.planning_model"),
			"limit": .int(20),
			"detailed": .bool(false)
		])
		XCTAssertEqual(compactEnvelope["detailed"]?.boolValue, false)
		let compactOptions = try XCTUnwrap(compactEnvelope["options"]?.arrayValue).compactMap(\.objectValue)
		XCTAssertFalse(compactOptions.isEmpty)
		for candidate in compactOptions {
			XCTAssertNil(candidate["description"])
			XCTAssertNil(candidate["reasoning_effort"])
			XCTAssertNil(candidate["context_window_tokens"])
			XCTAssertNil(candidate["tags"])
			XCTAssertNotNil(candidate["label"])
			XCTAssertNotNil(candidate["provider"])
		}
	}

	func testOptionsReturnsModelCandidatesAndSupportsAgentFilter() async throws {
		let harness = try await makeHarness()

		let envelope = try await call(harness.tool, [
			"op": .string("options"),
			"key": .string("models.planning_model")
		])

		XCTAssertEqual(envelope["op"]?.stringValue, "options")
		XCTAssertEqual(envelope["status"]?.stringValue, "ok")
		XCTAssertEqual(envelope["key"]?.stringValue, "models.planning_model")
		XCTAssertEqual(envelope["type"]?.stringValue, "string|null")
		XCTAssertEqual(envelope["source"]?.stringValue, "ai_model_catalog")
		XCTAssertEqual(envelope["nullable"]?.boolValue, true)
		XCTAssertEqual(envelope["exhaustive"]?.boolValue, false)
		XCTAssertTrue(envelope["clear_value"]?.isNull == true)
		let generatedAt = try XCTUnwrap(envelope["generated_at"]?.stringValue)
		XCTAssertFalse(generatedAt.isEmpty)

		let options = try XCTUnwrap(envelope["options"]?.arrayValue)
		XCTAssertFalse(options.isEmpty)
		let taskLabels: Set<String> = ["explore", "engineer", "pair", "design"]
		for option in options {
			let object = try XCTUnwrap(option.objectValue)
			let value = try XCTUnwrap(object["value"]?.stringValue)
			XCTAssertFalse(value.isEmpty)
			XCTAssertFalse(taskLabels.contains(value.lowercased()), "Option value '\(value)' should not be a task label")
			XCTAssertNotNil(AIModel.fromModelName(value), "Option value '\(value)' should be a parseable AIModel raw value")
			let label = try XCTUnwrap(object["label"]?.stringValue)
			XCTAssertFalse(label.isEmpty)
			let provider = try XCTUnwrap(object["provider"]?.stringValue)
			XCTAssertFalse(provider.isEmpty)
			XCTAssertEqual(object["available"]?.boolValue, true)
		}

		let filtered = try await call(harness.tool, [
			"op": .string("options"),
			"key": .string("models.planning_model"),
			"agent": .string(DiscoverAgentKind.codexExec.rawValue)
		])
		let filteredOptions = try XCTUnwrap(filtered["options"]?.arrayValue)
		XCTAssertFalse(filteredOptions.isEmpty)
		for option in filteredOptions {
			let object = try XCTUnwrap(option.objectValue)
			let value = try XCTUnwrap(object["value"]?.stringValue)
			XCTAssertEqual(AIModel.fromModelName(value)?.providerType, .codex)
			XCTAssertEqual(object["provider"]?.stringValue, "codex")
		}
		let filters = try XCTUnwrap(filtered["filters"]?.objectValue)
		XCTAssertEqual(filters["agent"]?.stringValue, DiscoverAgentKind.codexExec.rawValue)

		// Notes should document the fail-open set semantics and task-label exclusion.
		let notes = try XCTUnwrap(envelope["notes"]?.arrayValue).compactMap(\.stringValue)
		XCTAssertTrue(notes.contains(where: { $0.lowercased().contains("custom") }))
		XCTAssertTrue(notes.contains(where: { $0.lowercased().contains("task label") }))
	}

	func testOptionsAppliesLimitAndReportsTruncation() async throws {
		let harness = try await makeHarness()

		let envelope = try await call(harness.tool, [
			"op": .string("options"),
			"key": .string("models.planning_model"),
			"limit": .int(2)
		])

		let count = try XCTUnwrap(envelope["count"]?.intValue)
		let totalCount = try XCTUnwrap(envelope["total_count"]?.intValue)
		let truncated = try XCTUnwrap(envelope["truncated"]?.boolValue)
		let options = try XCTUnwrap(envelope["options"]?.arrayValue)

		XCTAssertLessThanOrEqual(count, 2)
		XCTAssertEqual(count, options.count)
		XCTAssertGreaterThanOrEqual(totalCount, count)
		XCTAssertEqual(envelope["limit"]?.intValue, 2)
		XCTAssertEqual(truncated, totalCount > count)
	}

	func testOptionsRejectsUnsupportedKeysAndBadParameters() async throws {
		let harness = try await makeHarness()

		await assertInvalidParams("Removed editing key should fail") {
			try await harness.tool([
				"op": .string("options"),
				"key": .string("editing.file_edit_format")
			])
		}

		await assertInvalidParams("Missing key should fail") {
			try await harness.tool(["op": .string("options")])
		}

		await assertInvalidParams("Unknown key should fail") {
			try await harness.tool([
				"op": .string("options"),
				"key": .string("models.not_a_real_setting")
			])
		}

		await assertInvalidParams("Key without provider should fail") {
			try await harness.tool([
				"op": .string("options"),
				"key": .string("ui.show_tooltips")
			])
		}

		await assertInvalidParams("Invalid agent should fail") {
			try await harness.tool([
				"op": .string("options"),
				"key": .string("models.planning_model"),
				"agent": .string("not-a-real-agent")
			])
		}

		await assertInvalidParams("limit=0 should fail") {
			try await harness.tool([
				"op": .string("options"),
				"key": .string("models.planning_model"),
				"limit": .int(0)
			])
		}

		await assertInvalidParams("limit=201 should fail") {
			try await harness.tool([
				"op": .string("options"),
				"key": .string("models.planning_model"),
				"limit": .int(201)
			])
		}

		await assertInvalidParams("group should not be accepted on options") {
			try await harness.tool([
				"op": .string("options"),
				"key": .string("models.planning_model"),
				"group": .string("models")
			])
		}

		await assertInvalidParams("keys should not be accepted on options") {
			try await harness.tool([
				"op": .string("options"),
				"key": .string("models.planning_model"),
				"keys": .array([.string("models.planning_model")])
			])
		}

		await assertInvalidParams("value should not be accepted on options") {
			try await harness.tool([
				"op": .string("options"),
				"key": .string("models.planning_model"),
				"value": .string("anything")
			])
		}
	}

	func testGetSupportsKeyKeysAndGroupAndFailsClosedForOldOrSensitiveKeys() async throws {
		let harness = try await makeHarness()
		harness.store.setShowTooltips(false)
		harness.store.setMCPShowModelPresets(true)

		let byKey = try values(from: try await call(harness.tool, [
			"op": .string("get"),
			"key": .string("ui.show_tooltips")
		]))
		XCTAssertEqual(byKey["ui.show_tooltips"]?.boolValue, false)
		XCTAssertEqual(byKey.count, 1)

		let byKeys = try values(from: try await call(harness.tool, [
			"op": .string("get"),
			"keys": .array([.string("ui.show_tooltips"), .string("mcp.show_model_presets")])
		]))
		XCTAssertEqual(byKeys["ui.show_tooltips"]?.boolValue, false)
		XCTAssertEqual(byKeys["mcp.show_model_presets"]?.boolValue, true)
		XCTAssertEqual(byKeys.count, 2)

		let byGroup = try values(from: try await call(harness.tool, [
			"op": .string("get"),
			"group": .string("models")
		]))
		XCTAssertEqual(Set(byGroup.keys), [
			"models.preferred_compose_model",
			"models.planning_model",
			"models.sync_chat_model_with_oracle",
			"models.temperature",
			"models.temperature_enabled",
			"models.custom_planning_prompt"
		])

		let fileSystemGroup = try values(from: try await call(harness.tool, [
			"op": .string("get"),
			"group": .string("file_system")
		]))
		XCTAssertEqual(Set(fileSystemGroup.keys), [
			"file_system.respect_gitignore",
			"file_system.respect_repo_ignore",
			"file_system.respect_cursorignore",
			"file_system.global_ignore_defaults",
			"file_system.enable_hierarchical_ignores",
			"file_system.skip_symlinks",
			"file_system.show_empty_folders"
		])
		XCTAssertEqual(fileSystemGroup["file_system.respect_gitignore"]?.boolValue, true)
		XCTAssertEqual(fileSystemGroup["file_system.show_empty_folders"]?.boolValue, false)

		let agentModeGroup = try values(from: try await call(harness.tool, [
			"op": .string("get"),
			"group": .string("agent_mode")
		]))
		var expectedAgentModeKeys: Set<String> = ["agent_mode.show_built_in_workflow_cleanup_guidance"]
		#if DEBUG
		expectedAgentModeKeys.formUnion([
			"agent_mode.claude_raw_event_logging_enabled",
			"agent_mode.claude_raw_event_log_file_path",
			"agent_mode.perf_diagnostics_enabled",
			"agent_mode.perf_diagnostics_os_log_enabled"
		])
		#endif
		XCTAssertEqual(Set(agentModeGroup.keys), expectedAgentModeKeys)
		XCTAssertEqual(agentModeGroup["agent_mode.show_built_in_workflow_cleanup_guidance"]?.boolValue, true)
		#if DEBUG
		XCTAssertEqual(agentModeGroup["agent_mode.claude_raw_event_logging_enabled"]?.boolValue, false)
		XCTAssertEqual(agentModeGroup["agent_mode.claude_raw_event_log_file_path"]?.stringValue, "")
		XCTAssertEqual(agentModeGroup["agent_mode.perf_diagnostics_enabled"]?.boolValue, false)
		XCTAssertEqual(agentModeGroup["agent_mode.perf_diagnostics_os_log_enabled"]?.boolValue, false)
		#endif

		for key in [
			// Old camelCase keys
			"ui.appearanceMode",
			"promptPackaging.setModelTemperature",
			"modelSelection.planningModel",
			"codeMaps.globallyDisabled",
			// Previously exposed keys that are now renamed or removed
			"prompt_packaging.model_temperature",
			"prompt_packaging.should_set_model_temperature",
			"prompt_packaging.custom_planning_prompt",
			"prompt_packaging.file_edit_format",
			"prompt_packaging.complex_edit_strategy",
			"editing.file_edit_format",
			"editing.allow_diff_models_to_rewrite",
			"editing.complex_edit_strategy",
			"model_selection.planning_model",
			"fileSystem.respectGitignore",
			"ignore.globalIgnoreDefaults",
			"file_system.globalIgnoreDefaults",
			"ui.use_transparency",
			"ui.collapse_latest_file_changes",
			"ui.experimental_attributed_text_editor",
			"mcp.temporarily_disable_presets",
			"mcp.auto_start",
			"mcp.server_start",
			// Excluded surfaces
			"credentials.openai_api_key",
			"api.api_key",
			"mcp.disabled_tools",
			"workspace_approvals.policy",
			"permissions.agent_mode",
			"agent_mode.pro_edit_agent_mode",
			"model_overrides.diff_overrides"
		] {
			await assertInvalidParams("Expected key '\(key)' to fail closed") {
				try await harness.tool(["op": .string("get"), "key": .string(key)])
			}
		}

		for group in [
			"modelSelection",
			"model_selection",
			"editing"
		] {
			await assertInvalidParams("Expected old group '\(group)' to fail closed") {
				try await harness.tool(["op": .string("get"), "group": .string(group)])
			}
		}
	}

	#if DEBUG
	func testDebugAgentModeDiagnosticSettingsWriteUserDefaultsBackedKeys() async throws {
		let harness = try await makeHarness()

		let rawLoggingResult = try await call(harness.tool, [
			"op": .string("set"),
			"key": .string("agent_mode.claude_raw_event_logging_enabled"),
			"value": .bool(true)
		])
		XCTAssertEqual(rawLoggingResult["old_value"]?.boolValue, false)
		XCTAssertEqual(rawLoggingResult["new_value"]?.boolValue, true)
		XCTAssertEqual(rawLoggingResult["changed"]?.boolValue, true)
		XCTAssertEqual(harness.store.claudeRawEventLoggingEnabled(), true)

		let pathResult = try await call(harness.tool, [
			"op": .string("set"),
			"key": .string("agent_mode.claude_raw_event_log_file_path"),
			"value": .string("  /tmp/repoprompt-claude-raw-events  ")
		])
		XCTAssertEqual(pathResult["new_value"]?.stringValue, "  /tmp/repoprompt-claude-raw-events  ")
		XCTAssertEqual(harness.store.claudeRawEventLogFilePath(), "  /tmp/repoprompt-claude-raw-events  ")

		let perfResult = try await call(harness.tool, [
			"op": .string("set"),
			"key": .string("agent_mode.perf_diagnostics_enabled"),
			"value": .string("true")
		])
		XCTAssertEqual(perfResult["new_value"]?.boolValue, true)
		XCTAssertEqual(harness.store.agentModePerfDiagnosticsEnabled(), true)

		let osLogResult = try await call(harness.tool, [
			"op": .string("set"),
			"key": .string("agent_mode.perf_diagnostics_os_log_enabled"),
			"value": .bool(true)
		])
		XCTAssertEqual(osLogResult["new_value"]?.boolValue, true)
		XCTAssertEqual(harness.store.agentModePerfDiagnosticsOSLogEnabled(), true)

		let readBack = try values(from: try await call(harness.tool, [
			"op": .string("get"),
			"keys": .array([
				.string("agent_mode.claude_raw_event_logging_enabled"),
				.string("agent_mode.claude_raw_event_log_file_path"),
				.string("agent_mode.perf_diagnostics_enabled"),
				.string("agent_mode.perf_diagnostics_os_log_enabled")
			])
		]))
		XCTAssertEqual(readBack["agent_mode.claude_raw_event_logging_enabled"]?.boolValue, true)
		XCTAssertEqual(readBack["agent_mode.claude_raw_event_log_file_path"]?.stringValue, "  /tmp/repoprompt-claude-raw-events  ")
		XCTAssertEqual(readBack["agent_mode.perf_diagnostics_enabled"]?.boolValue, true)
		XCTAssertEqual(readBack["agent_mode.perf_diagnostics_os_log_enabled"]?.boolValue, true)

		let clearPathResult = try await call(harness.tool, [
			"op": .string("set"),
			"key": .string("agent_mode.claude_raw_event_log_file_path"),
			"value": .string("   ")
		])
		XCTAssertEqual(clearPathResult["new_value"]?.stringValue, "")
		XCTAssertEqual(harness.store.claudeRawEventLogFilePath(), "")
	}
	#endif

	func testSetRepresentativeValuesAndPersistsThroughJSONStore() async throws {
		CodexGoalSupport.setEnabledForTesting(nil)
		defer { CodexGoalSupport.setEnabledForTesting(nil) }
		let harness = try await makeHarness()

		let booleanResult = try await call(harness.tool, [
			"op": .string("set"),
			"key": .string("ui.show_tooltips"),
			"value": .bool(false)
		])
		XCTAssertEqual(booleanResult["old_value"]?.boolValue, true)
		XCTAssertEqual(booleanResult["new_value"]?.boolValue, false)
		XCTAssertEqual(booleanResult["changed"]?.boolValue, true)
		XCTAssertEqual(booleanResult["applied"]?.boolValue, true)

		let enumResult = try await call(harness.tool, [
			"op": .string("set"),
			"key": .string("prompt_packaging.file_path_display_option"),
			"value": .string("Relative")
		])
		XCTAssertEqual(enumResult["new_value"]?.stringValue, "Relative")

		let numberResult = try await call(harness.tool, [
			"op": .string("set"),
			"key": .string("models.temperature"),
			"value": .double(1.25)
		])
		XCTAssertEqual(numberResult["new_value"]?.doubleValue, 1.25)

		let optionalStringResult = try await call(harness.tool, [
			"op": .string("set"),
			"key": .string("models.planning_model"),
			"value": .string("  provider:model-id  ")
		])
		XCTAssertEqual(optionalStringResult["new_value"]?.stringValue, "provider:model-id")

		let optionalNullResult = try await call(harness.tool, [
			"op": .string("set"),
			"key": .string("models.planning_model"),
			"value": .null
		])
		XCTAssertTrue(optionalNullResult["new_value"]?.isNull == true)

		let codeMapsResult = try await call(harness.tool, [
			"op": .string("set"),
			"key": .string("code_maps.globally_disabled"),
			"value": .bool(true)
		])
		XCTAssertEqual(codeMapsResult["new_value"]?.boolValue, true)

		let rawIgnoreDefaults = "  # keep whitespace\n**/custom-cache/\n"
		let ignoreDefaultsResult = try await call(harness.tool, [
			"op": .string("set"),
			"key": .string("file_system.global_ignore_defaults"),
			"value": .string(rawIgnoreDefaults)
		])
		XCTAssertEqual(ignoreDefaultsResult["new_value"]?.stringValue, rawIgnoreDefaults)

		let skipSymlinksResult = try await call(harness.tool, [
			"op": .string("set"),
			"key": .string("file_system.skip_symlinks"),
			"value": .bool(false)
		])
		XCTAssertEqual(skipSymlinksResult["new_value"]?.boolValue, false)

		let cleanupGuidanceResult = try await call(harness.tool, [
			"op": .string("set"),
			"key": .string("agent_mode.show_built_in_workflow_cleanup_guidance"),
			"value": .bool(false)
		])
		XCTAssertEqual(cleanupGuidanceResult["old_value"]?.boolValue, true)
		XCTAssertEqual(cleanupGuidanceResult["new_value"]?.boolValue, false)

		let codexGoalSupportResult = try await call(harness.tool, [
			"op": .string("set"),
			"key": .string("agent_mode.codex_goal_support_enabled"),
			"value": .bool(true)
		])
		XCTAssertEqual(codexGoalSupportResult["old_value"]?.boolValue, false)
		XCTAssertEqual(codexGoalSupportResult["new_value"]?.boolValue, true)

		let document = try harness.fileStore.load()
		XCTAssertEqual(document.scalarPreferences?.ui?.showTooltips, false)
		XCTAssertEqual(document.scalarPreferences?.promptPackaging?.filePathDisplayOption, "Relative")
		XCTAssertEqual(document.scalarPreferences?.promptPackaging?.modelTemperature, 1.25)
		XCTAssertNil(document.scalarPreferences?.modelSelection?.planningModel)
		XCTAssertEqual(document.scalarPreferences?.fileSystem?.globalIgnoreDefaults, rawIgnoreDefaults)
		XCTAssertEqual(document.scalarPreferences?.fileSystem?.skipSymlinks, false)
		XCTAssertEqual(document.scalarPreferences?.agentMode?.showBuiltInWorkflowCleanupGuidance, false)
		XCTAssertEqual(document.scalarPreferences?.agentMode?.codexGoalSupportEnabled, true)
		XCTAssertEqual(document.globalDefaults.codeMapsGloballyDisabled, true)

		let readBack = try values(from: try await call(harness.tool, [
			"op": .string("get"),
			"key": .string("agent_mode.codex_goal_support_enabled")
		]))
		XCTAssertEqual(readBack["agent_mode.codex_goal_support_enabled"]?.boolValue, true)
	}

	func testFontScaleSettingUsesManagerAndExactPresetValues() async throws {
		let originalFontScale = FontScaleManager.shared.preset.rawValue
		defer {
			FontScaleManager.shared.applyPersistedRawValueFromAppSettings(
				originalFontScale,
				broadcastExternalChange: false
			)
		}
		let harness = try await makeHarness()

		let setResult = try await call(harness.tool, [
			"op": .string("set"),
			"key": .string("ui.font_scale"),
			"value": .int(18)
		])
		XCTAssertEqual(setResult["new_value"]?.doubleValue, 18)
		XCTAssertEqual(FontScaleManager.shared.preset.rawValue, 18)
		XCTAssertEqual(try harness.fileStore.load().scalarPreferences?.ui?.fontScaleBodySize, 18)

		let readBack = try values(from: try await call(harness.tool, [
			"op": .string("get"),
			"key": .string("ui.font_scale")
		]))
		XCTAssertEqual(readBack["ui.font_scale"]?.doubleValue, 18)

		let optionsEnvelope = try await call(harness.tool, [
			"op": .string("options"),
			"key": .string("ui.font_scale")
		])
		let options = try XCTUnwrap(optionsEnvelope["options"]?.arrayValue).compactMap(\.objectValue)
		XCTAssertEqual(options.compactMap { $0["value"]?.doubleValue }, FontScalePreset.allCases.map(\.rawValue))
		XCTAssertEqual(options.compactMap { $0["label"]?.stringValue }, ["Normal", "Large", "Extra Large"])

		await assertInvalidParams("ui.font_scale rejects non-preset numeric values") {
			try await harness.tool([
				"op": .string("set"),
				"key": .string("ui.font_scale"),
				"value": .int(15)
			])
		}
	}

	func testFontScaleGetReadsInjectedStoreNotProcessLocalManager() async throws {
		let originalFontScale = FontScaleManager.shared.preset.rawValue
		defer {
			FontScaleManager.shared.applyPersistedRawValueFromAppSettings(
				originalFontScale,
				broadcastExternalChange: false
			)
		}
		let harness = try await makeHarness()

		FontScaleManager.shared.applyPersistedRawValueFromAppSettings(
			FontScalePreset.normal.rawValue,
			broadcastExternalChange: false
		)
		harness.store.setFontScaleBodySize(FontScalePreset.extraLarge.rawValue)

		let readBack = try values(from: try await call(harness.tool, [
			"op": .string("get"),
			"key": .string("ui.font_scale")
		]))

		XCTAssertEqual(readBack["ui.font_scale"]?.doubleValue, FontScalePreset.extraLarge.rawValue)
		XCTAssertEqual(FontScaleManager.shared.preset.rawValue, FontScalePreset.normal.rawValue)
	}

	func testFontScaleNoOpSetStillReconcilesLiveManager() async throws {
		let originalFontScale = FontScaleManager.shared.preset.rawValue
		defer {
			FontScaleManager.shared.applyPersistedRawValueFromAppSettings(
				originalFontScale,
				broadcastExternalChange: false
			)
		}
		let harness = try await makeHarness()

		harness.store.setFontScaleBodySize(FontScalePreset.extraLarge.rawValue)
		FontScaleManager.shared.applyPersistedRawValueFromAppSettings(
			FontScalePreset.normal.rawValue,
			broadcastExternalChange: false
		)

		let setResult = try await call(harness.tool, [
			"op": .string("set"),
			"key": .string("ui.font_scale"),
			"value": .int(Int(FontScalePreset.extraLarge.rawValue))
		])

		XCTAssertEqual(setResult["changed"]?.boolValue, false)
		XCTAssertEqual(setResult["applied"]?.boolValue, false)
		XCTAssertEqual(setResult["new_value"]?.doubleValue, FontScalePreset.extraLarge.rawValue)
		XCTAssertEqual(FontScaleManager.shared.preset.rawValue, FontScalePreset.extraLarge.rawValue)
	}

	func testSetNormalizesBooleanAndNumericPrimitiveStrings() async throws {
		let harness = try await makeHarness()

		let falseStringResult = try await call(harness.tool, [
			"op": .string("set"),
			"key": .string("ui.show_tooltips"),
			"value": .string(" FALSE ")
		])
		XCTAssertEqual(falseStringResult["new_value"]?.boolValue, false)

		let trueStringResult = try await call(harness.tool, [
			"op": .string("set"),
			"key": .string("code_maps.globally_disabled"),
			"value": .string("TrUe")
		])
		XCTAssertEqual(trueStringResult["new_value"]?.boolValue, true)

		let numericStringResult = try await call(harness.tool, [
			"op": .string("set"),
			"key": .string("models.temperature"),
			"value": .string(" 0.35 ")
		])
		XCTAssertEqual(numericStringResult["new_value"]?.doubleValue, 0.35)

		let integerResult = try await call(harness.tool, [
			"op": .string("set"),
			"key": .string("models.temperature"),
			"value": .int(1)
		])
		XCTAssertEqual(integerResult["new_value"]?.doubleValue, 1.0)

		let document = try harness.fileStore.load()
		XCTAssertEqual(document.scalarPreferences?.ui?.showTooltips, false)
		XCTAssertEqual(document.scalarPreferences?.promptPackaging?.modelTemperature, 1.0)
	}

	func testSetRejectsRepresentativeValidationFailures() async throws {
		let harness = try await makeHarness()

		await assertInvalidParams("Removed editing settings reject writes") {
			try await harness.tool([
				"op": .string("set"),
				"key": .string("editing.file_edit_format"),
				"value": .string("Whole")
			])
		}

		await assertInvalidParams("Boolean settings reject ambiguous strings") {
			try await harness.tool([
				"op": .string("set"),
				"key": .string("ui.show_tooltips"),
				"value": .string("yes")
			])
		}

		await assertInvalidParams("Boolean settings reject numeric-looking strings") {
			try await harness.tool([
				"op": .string("set"),
				"key": .string("ui.show_tooltips"),
				"value": .string("1")
			])
		}

		await assertInvalidParams("Boolean settings reject numeric booleans") {
			try await harness.tool([
				"op": .string("set"),
				"key": .string("ui.show_tooltips"),
				"value": .int(1)
			])
		}

		await assertInvalidParams("Enum settings reject unknown strings") {
			try await harness.tool([
				"op": .string("set"),
				"key": .string("prompt_packaging.file_path_display_option"),
				"value": .string("Absolute")
			])
		}

		await assertInvalidParams("models.temperature rejects malformed numeric strings") {
			try await harness.tool([
				"op": .string("set"),
				"key": .string("models.temperature"),
				"value": .string("not-a-number")
			])
		}

		await assertInvalidParams("models.temperature rejects non-finite numeric strings") {
			try await harness.tool([
				"op": .string("set"),
				"key": .string("models.temperature"),
				"value": .string("nan")
			])
		}

		await assertInvalidParams("models.temperature rejects boolean values") {
			try await harness.tool([
				"op": .string("set"),
				"key": .string("models.temperature"),
				"value": .bool(true)
			])
		}

		await assertInvalidParams("models.temperature must be in range") {
			try await harness.tool([
				"op": .string("set"),
				"key": .string("models.temperature"),
				"value": .double(2.5)
			])
		}

		await assertInvalidParams("Nullable model settings remain string-or-null only") {
			try await harness.tool([
				"op": .string("set"),
				"key": .string("models.planning_model"),
				"value": .bool(false)
			])
		}

		await assertInvalidParams("prompt_sections_order must be JSON") {
			try await harness.tool([
				"op": .string("set"),
				"key": .string("prompt_packaging.prompt_sections_order"),
				"value": .string("{not-json")
			])
		}

		let incompleteOrder = try promptSectionsOrderJSON(Array(PromptSection.allCases.dropLast()))
		await assertInvalidParams("prompt_sections_order must include every section exactly once") {
			try await harness.tool([
				"op": .string("set"),
				"key": .string("prompt_packaging.prompt_sections_order"),
				"value": .string(incompleteOrder)
			])
		}

		await assertInvalidParams("global ignore defaults rejects non-string values") {
			try await harness.tool([
				"op": .string("set"),
				"key": .string("file_system.global_ignore_defaults"),
				"value": .bool(true)
			])
		}

		await assertInvalidParams("global ignore defaults rejects oversized strings") {
			try await harness.tool([
				"op": .string("set"),
				"key": .string("file_system.global_ignore_defaults"),
				"value": .string(String(repeating: "x", count: 20_001))
			])
		}
	}

	// MARK: - afterWrite notification + mirroring

	func testSetPlanningModelPostsRecommendationsDidApplyNotification() async throws {
		let harness = try await makeHarness()
		harness.store.setSyncChatModelWithOracle(false)

		let count = try await countRecommendationsDidApply(notificationCenter: harness.notificationCenter) {
			let result = try await self.call(harness.tool, [
				"op": .string("set"),
				"key": .string("models.planning_model"),
				"value": .string("provider:planning-id")
			])
			XCTAssertEqual(result["changed"]?.boolValue, true)
			XCTAssertEqual(result["new_value"]?.stringValue, "provider:planning-id")
		}

		XCTAssertEqual(count, 1, "Expected exactly one .recommendationsDidApply for a successful write")
	}

	func testSetPreferredComposeModelPostsRecommendationsDidApplyNotification() async throws {
		let harness = try await makeHarness()
		harness.store.setSyncChatModelWithOracle(false)

		let count = try await countRecommendationsDidApply(notificationCenter: harness.notificationCenter) {
			let result = try await self.call(harness.tool, [
				"op": .string("set"),
				"key": .string("models.preferred_compose_model"),
				"value": .string("provider:compose-id")
			])
			XCTAssertEqual(result["changed"]?.boolValue, true)
			XCTAssertEqual(result["new_value"]?.stringValue, "provider:compose-id")
		}

		XCTAssertEqual(count, 1, "Expected exactly one .recommendationsDidApply for a successful write")
	}

	func testSetPlanningModelMirrorsToPreferredComposeWhenSyncEnabled() async throws {
		let harness = try await makeHarness()
		harness.store.setPreferredComposeModelRaw("provider:compose-initial")
		harness.store.setPlanningModelRaw(nil)
		harness.store.setSyncChatModelWithOracle(true)

		let count = try await countRecommendationsDidApply(notificationCenter: harness.notificationCenter) {
			_ = try await self.call(harness.tool, [
				"op": .string("set"),
				"key": .string("models.planning_model"),
				"value": .string("provider:planning-new")
			])
		}

		XCTAssertEqual(harness.store.planningModelRaw(), "provider:planning-new")
		XCTAssertEqual(
			harness.store.preferredComposeModelRaw(),
			"provider:planning-new",
			"compose sibling should mirror the planning value when sync is enabled"
		)
		XCTAssertEqual(count, 1, "Mirror write must not fire a second .recommendationsDidApply")
	}

	func testSetPreferredComposeModelMirrorsToPlanningWhenSyncEnabled() async throws {
		let harness = try await makeHarness()
		harness.store.setPlanningModelRaw("provider:planning-initial")
		harness.store.setPreferredComposeModelRaw(nil)
		harness.store.setSyncChatModelWithOracle(true)

		let count = try await countRecommendationsDidApply(notificationCenter: harness.notificationCenter) {
			_ = try await self.call(harness.tool, [
				"op": .string("set"),
				"key": .string("models.preferred_compose_model"),
				"value": .string("provider:compose-new")
			])
		}

		XCTAssertEqual(harness.store.preferredComposeModelRaw(), "provider:compose-new")
		XCTAssertEqual(
			harness.store.planningModelRaw(),
			"provider:compose-new",
			"planning sibling should mirror the compose value when sync is enabled"
		)
		XCTAssertEqual(count, 1, "Mirror write must not fire a second .recommendationsDidApply")
	}

	func testSetSyncChatModelWithOracleSnapsPreferredComposeToPlanning() async throws {
		let harness = try await makeHarness()
		harness.store.setPreferredComposeModelRaw("provider:compose-initial")
		harness.store.setPlanningModelRaw("provider:planning-authoritative")
		harness.store.setSyncChatModelWithOracle(false)

		let count = try await countRecommendationsDidApply(notificationCenter: harness.notificationCenter) {
			let result = try await self.call(harness.tool, [
				"op": .string("set"),
				"key": .string("models.sync_chat_model_with_oracle"),
				"value": .bool(true)
			])
			XCTAssertEqual(result["changed"]?.boolValue, true)
		}

		XCTAssertTrue(harness.store.syncChatModelWithOracle())
		XCTAssertEqual(harness.store.planningModelRaw(), "provider:planning-authoritative")
		XCTAssertEqual(harness.store.preferredComposeModelRaw(), "provider:planning-authoritative")
		XCTAssertEqual(count, 1, "Sync toggle snap should post one recommendations notification")
		let diagnostics = harness.store.recentSettingsWriteDiagnostics()
		XCTAssertTrue(diagnostics.contains { $0.key == "syncChatModelWithOracle" && $0.reason == "app_settings.models.sync_chat_model_with_oracle" })
		XCTAssertTrue(diagnostics.contains { $0.key == "preferredComposeModelRaw" && $0.reason == "app_settings.models.sync_chat_model_with_oracle.snap_to_planning" })
	}

	func testSetSyncChatModelWithOracleDisablingDoesNotSnapModels() async throws {
		let harness = try await makeHarness()
		harness.store.setPreferredComposeModelRaw("provider:compose-initial")
		harness.store.setPlanningModelRaw("provider:planning-initial")
		harness.store.setSyncChatModelWithOracle(true)

		_ = try await self.call(harness.tool, [
			"op": .string("set"),
			"key": .string("models.sync_chat_model_with_oracle"),
			"value": .bool(false)
		])

		XCTAssertFalse(harness.store.syncChatModelWithOracle())
		XCTAssertEqual(harness.store.preferredComposeModelRaw(), "provider:compose-initial")
		XCTAssertEqual(harness.store.planningModelRaw(), "provider:planning-initial")
	}

	func testSetPlanningModelDoesNotMirrorWhenSyncDisabled() async throws {
		let harness = try await makeHarness()
		harness.store.setPreferredComposeModelRaw("provider:compose-initial")
		harness.store.setPlanningModelRaw(nil)
		harness.store.setSyncChatModelWithOracle(false)

		let count = try await countRecommendationsDidApply(notificationCenter: harness.notificationCenter) {
			_ = try await self.call(harness.tool, [
				"op": .string("set"),
				"key": .string("models.planning_model"),
				"value": .string("provider:planning-new")
			])
		}

		XCTAssertEqual(harness.store.planningModelRaw(), "provider:planning-new")
		XCTAssertEqual(
			harness.store.preferredComposeModelRaw(),
			"provider:compose-initial",
			"compose sibling must be untouched when sync is disabled"
		)
		XCTAssertEqual(count, 1, "Notification should still fire exactly once for the primary write")
	}

	func testSetPlanningModelMirrorsClearWhenSyncEnabled() async throws {
		let harness = try await makeHarness()
		harness.store.setPlanningModelRaw("provider:both")
		harness.store.setPreferredComposeModelRaw("provider:both")
		harness.store.setSyncChatModelWithOracle(true)

		let count = try await countRecommendationsDidApply(notificationCenter: harness.notificationCenter) {
			_ = try await self.call(harness.tool, [
				"op": .string("set"),
				"key": .string("models.planning_model"),
				"value": .null
			])
		}

		XCTAssertNil(harness.store.planningModelRaw())
		XCTAssertNil(
			harness.store.preferredComposeModelRaw(),
			"clearing one model with sync enabled should mirror the clear to the sibling"
		)
		XCTAssertEqual(count, 1, "Mirror clear must not fire a second .recommendationsDidApply")
	}

	func testSetPlanningModelWithUnchangedValueDoesNotRepostNotification() async throws {
		let harness = try await makeHarness()
		harness.store.setPlanningModelRaw("provider:unchanged")
		harness.store.setSyncChatModelWithOracle(false)

		let count = try await countRecommendationsDidApply(notificationCenter: harness.notificationCenter) {
			let result = try await self.call(harness.tool, [
				"op": .string("set"),
				"key": .string("models.planning_model"),
				"value": .string("provider:unchanged")
			])
			XCTAssertEqual(result["changed"]?.boolValue, false)
			XCTAssertEqual(result["applied"]?.boolValue, false)
			XCTAssertEqual(result["new_value"]?.stringValue, "provider:unchanged")
		}

		XCTAssertEqual(count, 0, "No-op writes must not fire .recommendationsDidApply")
	}

	func testSetFileSystemSettingPostsFileSystemPreferencesNotification() async throws {
		let harness = try await makeHarness()

		let capture = try await captureFileSystemPreferencesDidChange(notificationCenter: harness.notificationCenter) {
			let result = try await self.call(harness.tool, [
				"op": .string("set"),
				"key": .string("file_system.respect_gitignore"),
				"value": .bool(false)
			])
			XCTAssertEqual(result["changed"]?.boolValue, true)
			XCTAssertEqual(result["new_value"]?.boolValue, false)
		}

		XCTAssertEqual(capture.count, 1)
		XCTAssertEqual(capture.lastKey, "file_system.respect_gitignore")
	}

	func testSetPlanningModelWhenSiblingAlreadyMatchesDoesNotFireSecondNotification() async throws {
		let harness = try await makeHarness()
		harness.store.setPlanningModelRaw("provider:shared-old")
		harness.store.setPreferredComposeModelRaw("provider:shared-new")
		harness.store.setSyncChatModelWithOracle(true)

		let count = try await countRecommendationsDidApply(notificationCenter: harness.notificationCenter) {
			_ = try await self.call(harness.tool, [
				"op": .string("set"),
				"key": .string("models.planning_model"),
				"value": .string("provider:shared-new")
			])
		}

		XCTAssertEqual(harness.store.planningModelRaw(), "provider:shared-new")
		XCTAssertEqual(harness.store.preferredComposeModelRaw(), "provider:shared-new")
		XCTAssertEqual(count, 1, "Sibling already matches — no extra notification should fire")
	}

	func testContextBuilderAgentSetSwitchesAgentAndKeepsRememberedModel() async throws {
		let harness = try await makeHarness()
		let rememberedCodexModel = "codex-remembered-model"
		harness.store.setGlobalDiscoverAgentSelection(
			agentRaw: DiscoverAgentKind.codexExec.rawValue,
			modelRaw: rememberedCodexModel,
			markUserDefined: true
		)
		harness.store.setGlobalDiscoverAgentSelection(
			agentRaw: DiscoverAgentKind.claudeCode.rawValue,
			modelRaw: AgentModel.claudeOpus.rawValue,
			markUserDefined: true
		)

		let result = try await call(harness.tool, [
			"op": .string("set"),
			"key": .string("context_builder.agent"),
			"value": .string(DiscoverAgentKind.codexExec.rawValue)
		])

		XCTAssertEqual(result["new_value"]?.stringValue, DiscoverAgentKind.codexExec.rawValue)
		let selection = harness.store.globalDiscoverAgentSelection()
		XCTAssertEqual(selection.agentRaw, DiscoverAgentKind.codexExec.rawValue)
		XCTAssertEqual(selection.modelRaw, rememberedCodexModel)
		let document = try harness.fileStore.load()
		XCTAssertEqual(
			document.globalDefaults.discoverModelsByAgent?[DiscoverAgentKind.codexExec.rawValue],
			rememberedCodexModel
		)
	}

	func testContextBuilderAgentFallsBackToDefaultModelWhenNoneRemembered() async throws {
		let harness = try await makeHarness()
		harness.store.setGlobalDiscoverAgentSelection(
			agentRaw: DiscoverAgentKind.claudeCode.rawValue,
			modelRaw: AgentModel.claudeOpus.rawValue,
			markUserDefined: true
		)
		// Ensure no remembered model for the target agent.
		XCTAssertNil(
			harness.store.globalDiscoverRememberedModelRaw(for: DiscoverAgentKind.codexExec.rawValue),
			"precondition: codexExec should not have a remembered model"
		)
		let expectedDefault = AgentModelCatalog.defaultModelRaw(for: .codexExec)

		let result = try await call(harness.tool, [
			"op": .string("set"),
			"key": .string("context_builder.agent"),
			"value": .string(DiscoverAgentKind.codexExec.rawValue)
		])

		XCTAssertEqual(result["new_value"]?.stringValue, DiscoverAgentKind.codexExec.rawValue)
		let selection = harness.store.globalDiscoverAgentSelection()
		XCTAssertEqual(selection.agentRaw, DiscoverAgentKind.codexExec.rawValue)
		XCTAssertEqual(
			selection.modelRaw,
			expectedDefault,
			"falling back to AgentModelCatalog.defaultModelRaw(for:) when no remembered model exists"
		)
	}

	func testContextBuilderModelSetUpdatesCurrentAgentSlot() async throws {
		let harness = try await makeHarness()
		harness.store.setGlobalDiscoverAgentSelection(
			agentRaw: DiscoverAgentKind.codexExec.rawValue,
			modelRaw: "codex-initial",
			markUserDefined: true
		)

		let result = try await call(harness.tool, [
			"op": .string("set"),
			"key": .string("context_builder.model"),
			"value": .string("  codex-new-model  ")
		])

		XCTAssertEqual(result["new_value"]?.stringValue, "codex-new-model")
		let selection = harness.store.globalDiscoverAgentSelection()
		XCTAssertEqual(selection.agentRaw, DiscoverAgentKind.codexExec.rawValue)
		XCTAssertEqual(selection.modelRaw, "codex-new-model")
		let document = try harness.fileStore.load()
		XCTAssertEqual(
			document.globalDefaults.discoverModelsByAgent?[DiscoverAgentKind.codexExec.rawValue],
			"codex-new-model"
		)
	}

	func testContextBuilderModelNullClearsForCurrentAgent() async throws {
		let harness = try await makeHarness()
		harness.store.setGlobalDiscoverAgentSelection(
			agentRaw: DiscoverAgentKind.codexExec.rawValue,
			modelRaw: "codex-to-clear",
			markUserDefined: true
		)

		let nullResult = try await call(harness.tool, [
			"op": .string("set"),
			"key": .string("context_builder.model"),
			"value": .null
		])

		XCTAssertTrue(nullResult["new_value"]?.isNull == true)
		XCTAssertNil(harness.store.globalDiscoverRememberedModelRaw(for: DiscoverAgentKind.codexExec.rawValue))
		var document = try harness.fileStore.load()
		XCTAssertNil(document.globalDefaults.discoverModelsByAgent?[DiscoverAgentKind.codexExec.rawValue])

		harness.store.setGlobalDiscoverAgentSelection(
			agentRaw: DiscoverAgentKind.codexExec.rawValue,
			modelRaw: "codex-to-clear-again",
			markUserDefined: true
		)
		let emptyStringResult = try await call(harness.tool, [
			"op": .string("set"),
			"key": .string("context_builder.model"),
			"value": .string("   ")
		])
		XCTAssertTrue(emptyStringResult["new_value"]?.isNull == true)
		document = try harness.fileStore.load()
		XCTAssertNil(document.globalDefaults.discoverModelsByAgent?[DiscoverAgentKind.codexExec.rawValue])
	}

	func testContextBuilderSettingsPostRecommendationsDidApply() async throws {
		let harness = try await makeHarness()
		harness.store.setGlobalDiscoverAgentSelection(
			agentRaw: DiscoverAgentKind.claudeCode.rawValue,
			modelRaw: AgentModel.claudeOpus.rawValue,
			markUserDefined: true
		)

		let count = try await countRecommendationsDidApply(notificationCenter: harness.notificationCenter) {
			_ = try await self.call(harness.tool, [
				"op": .string("set"),
				"key": .string("context_builder.agent"),
				"value": .string(DiscoverAgentKind.codexExec.rawValue)
			])
			_ = try await self.call(harness.tool, [
				"op": .string("set"),
				"key": .string("context_builder.model"),
				"value": .string("codex-notification-model")
			])
		}

		XCTAssertEqual(count, 2, "Each successful Context Builder setting write should post once")
	}

	func testContextBuilderModelCandidatesDefaultToCurrentAgent() async throws {
		let harness = try await makeHarness()
		harness.store.setGlobalDiscoverAgentSelection(
			agentRaw: DiscoverAgentKind.gemini.rawValue,
			modelRaw: AgentModel.geminiPro3p1Preview.rawValue,
			markUserDefined: true
		)

		let envelope = try await call(harness.tool, [
			"op": .string("options"),
			"key": .string("context_builder.model")
		])

		let options = try XCTUnwrap(envelope["options"]?.arrayValue)
		XCTAssertFalse(options.isEmpty)
		for option in options {
			let object = try XCTUnwrap(option.objectValue)
			XCTAssertEqual(object["agent"]?.stringValue, DiscoverAgentKind.gemini.rawValue)
		}
		let filters = try XCTUnwrap(envelope["filters"]?.objectValue)
		XCTAssertEqual(filters["agent"]?.stringValue, DiscoverAgentKind.gemini.rawValue)
	}

	func testContextBuilderModelCandidatesHonorExplicitAgentFilter() async throws {
		let harness = try await makeHarness()
		harness.store.setGlobalDiscoverAgentSelection(
			agentRaw: DiscoverAgentKind.gemini.rawValue,
			modelRaw: AgentModel.geminiPro3p1Preview.rawValue,
			markUserDefined: true
		)

		let envelope = try await call(harness.tool, [
			"op": .string("options"),
			"key": .string("context_builder.model"),
			"agent": .string(DiscoverAgentKind.codexExec.rawValue)
		])

		let options = try XCTUnwrap(envelope["options"]?.arrayValue)
		XCTAssertFalse(options.isEmpty)
		for option in options {
			let object = try XCTUnwrap(option.objectValue)
			XCTAssertEqual(object["agent"]?.stringValue, DiscoverAgentKind.codexExec.rawValue)
		}
		let filters = try XCTUnwrap(envelope["filters"]?.objectValue)
		XCTAssertEqual(filters["agent"]?.stringValue, DiscoverAgentKind.codexExec.rawValue)
	}

	func testContextBuilderAgentRejectsUnknownEnumValue() async throws {
		let harness = try await makeHarness()

		await assertInvalidParams("Unknown Context Builder discovery agent should fail") {
			try await harness.tool([
				"op": .string("set"),
				"key": .string("context_builder.agent"),
				"value": .string("not-a-real-agent")
			])
		}
	}

	// MARK: - Plan-named coverage

	func testCatalogEmitsLabelsOnlyForConfiguredSettings() async throws {
		let harness = try await makeHarness()

		let listObject = try await call(harness.tool, ["op": .string("list")])
		let settings = try settingsCatalog(from: listObject)
		let settingsByKey = Dictionary(uniqueKeysWithValues: settings.compactMap { setting -> (String, [String: Value])? in
			guard let key = setting["key"]?.stringValue else { return nil }
			return (key, setting)
		})

		let expectedLabels: [String: String] = [
			"ui.font_scale": "Font Scale",
			"models.planning_model": "Oracle Model",
			"models.preferred_compose_model": "Built-in Chat Model",
			"models.sync_chat_model_with_oracle": "Sync Built-in Chat with Oracle",
			"models.custom_planning_prompt": "Custom Oracle System Prompt"
		]
		for (key, label) in expectedLabels {
			let setting = try XCTUnwrap(settingsByKey[key])
			XCTAssertEqual(setting["label"]?.stringValue, label)
		}

		// Unlabeled keys must not synthesize labels from the key name.
		for key in ["ui.show_tooltips", "mcp.show_model_presets", "context_builder.agent", "context_builder.model"] {
			let setting = try XCTUnwrap(settingsByKey[key])
			XCTAssertNil(setting["label"], "'\(key)' should not expose a label")
		}
	}

	func testContextBuilderSettingsAppearInCatalogWithMinimalDescriptions() async throws {
		let harness = try await makeHarness()

		let listObject = try await call(harness.tool, ["op": .string("list")])
		let groups = try XCTUnwrap(listObject["groups"]?.arrayValue).compactMap(\.stringValue)
		XCTAssertTrue(groups.contains("context_builder"))

		let settings = try settingsCatalog(from: listObject)
		let settingsByKey = Dictionary(uniqueKeysWithValues: settings.compactMap { setting -> (String, [String: Value])? in
			guard let key = setting["key"]?.stringValue else { return nil }
			return (key, setting)
		})

		let agentSetting = try XCTUnwrap(settingsByKey["context_builder.agent"])
		XCTAssertEqual(agentSetting["group"]?.stringValue, "context_builder")
		XCTAssertEqual(agentSetting["type"]?.stringValue, "string")
		XCTAssertEqual(agentSetting["description"]?.stringValue, "CLI agent used by the Context Builder MCP tool.")
		let allowed = try XCTUnwrap(agentSetting["allowed_values"]?.arrayValue).compactMap(\.stringValue)
		XCTAssertEqual(Set(allowed), Set(DiscoverAgentKind.allCases.map(\.rawValue)))

		let modelSetting = try XCTUnwrap(settingsByKey["context_builder.model"])
		XCTAssertEqual(modelSetting["group"]?.stringValue, "context_builder")
		XCTAssertEqual(modelSetting["type"]?.stringValue, "string|null")
		XCTAssertEqual(modelSetting["description"]?.stringValue, "Model raw identifier used by the Context Builder MCP tool.")
		XCTAssertEqual(modelSetting["options_available"]?.boolValue, true)
	}

	func testContextBuilderAgentWriteUsesRememberedOrDefaultModel() async throws {
		let harness = try await makeHarness()

		// Seed a remembered model for codexExec, then switch away so the agent slot is claudeCode.
		let rememberedCodexModel = "codex-remembered-model"
		harness.store.setGlobalDiscoverAgentSelection(
			agentRaw: DiscoverAgentKind.codexExec.rawValue,
			modelRaw: rememberedCodexModel,
			markUserDefined: true
		)
		harness.store.setGlobalDiscoverAgentSelection(
			agentRaw: DiscoverAgentKind.claudeCode.rawValue,
			modelRaw: AgentModel.claudeOpus.rawValue,
			markUserDefined: true
		)

		let notificationCount = try await countRecommendationsDidApply(notificationCenter: harness.notificationCenter) {
			_ = try await self.call(harness.tool, [
				"op": .string("set"),
				"key": .string("context_builder.agent"),
				"value": .string(DiscoverAgentKind.codexExec.rawValue)
			])
		}

		let selection = harness.store.globalDiscoverAgentSelection()
		XCTAssertEqual(selection.agentRaw, DiscoverAgentKind.codexExec.rawValue)
		XCTAssertEqual(selection.modelRaw, rememberedCodexModel, "remembered model should be preserved")
		XCTAssertEqual(notificationCount, 1, "context_builder.agent write must post .recommendationsDidApply exactly once")

		// Now switch to gemini where nothing is remembered — default model for backend is used.
		XCTAssertNil(
			harness.store.globalDiscoverRememberedModelRaw(for: DiscoverAgentKind.gemini.rawValue),
			"precondition: gemini should not have a remembered model"
		)
		_ = try await call(harness.tool, [
			"op": .string("set"),
			"key": .string("context_builder.agent"),
			"value": .string(DiscoverAgentKind.gemini.rawValue)
		])
		let afterSwitch = harness.store.globalDiscoverAgentSelection()
		XCTAssertEqual(afterSwitch.agentRaw, DiscoverAgentKind.gemini.rawValue)
		XCTAssertEqual(
			afterSwitch.modelRaw,
			AgentModelCatalog.defaultModelRaw(for: .gemini),
			"falling back to AgentModelCatalog.defaultModelRaw(for:) when no remembered model exists"
		)
	}

	func testContextBuilderModelWriteCanSetAndClearRememberedModel() async throws {
		let harness = try await makeHarness()
		harness.store.setGlobalDiscoverAgentSelection(
			agentRaw: DiscoverAgentKind.codexExec.rawValue,
			modelRaw: "codex-initial",
			markUserDefined: true
		)

		let setResult = try await call(harness.tool, [
			"op": .string("set"),
			"key": .string("context_builder.model"),
			"value": .string("  codex-trimmed-model  ")
		])
		XCTAssertEqual(setResult["new_value"]?.stringValue, "codex-trimmed-model")
		XCTAssertEqual(
			harness.store.globalDiscoverRememberedModelRaw(for: DiscoverAgentKind.codexExec.rawValue),
			"codex-trimmed-model"
		)

		let clearResult = try await call(harness.tool, [
			"op": .string("set"),
			"key": .string("context_builder.model"),
			"value": .null
		])
		XCTAssertTrue(clearResult["new_value"]?.isNull == true)

		// Round-trip: reading must return null, not a synthesized default.
		let getResult = try await call(harness.tool, [
			"op": .string("get"),
			"key": .string("context_builder.model")
		])
		let values = try XCTUnwrap(getResult["values"]?.objectValue)
		XCTAssertTrue(
			values["context_builder.model"]?.isNull == true,
			"context_builder.model must round-trip null after a clear"
		)
	}

	func testContextBuilderModelOptionsDefaultToCurrentBackend() async throws {
		let harness = try await makeHarness()
		harness.store.setGlobalDiscoverAgentSelection(
			agentRaw: DiscoverAgentKind.gemini.rawValue,
			modelRaw: AgentModel.geminiPro3p1Preview.rawValue,
			markUserDefined: true
		)

		// Without agent=, default candidates come from the current context-builder backend.
		let defaultEnvelope = try await call(harness.tool, [
			"op": .string("options"),
			"key": .string("context_builder.model")
		])
		let defaultOptions = try XCTUnwrap(defaultEnvelope["options"]?.arrayValue)
		XCTAssertFalse(defaultOptions.isEmpty)
		for option in defaultOptions {
			let object = try XCTUnwrap(option.objectValue)
			XCTAssertEqual(object["agent"]?.stringValue, DiscoverAgentKind.gemini.rawValue)
		}
		let defaultFilters = try XCTUnwrap(defaultEnvelope["filters"]?.objectValue)
		XCTAssertEqual(defaultFilters["agent"]?.stringValue, DiscoverAgentKind.gemini.rawValue)

		let defaultNotes = try XCTUnwrap(defaultEnvelope["notes"]?.arrayValue).compactMap(\.stringValue)
		XCTAssertEqual(defaultNotes.count, 2, "Context Builder candidates should not introduce additional notes")

		// Explicit agent= overrides the default.
		let explicitEnvelope = try await call(harness.tool, [
			"op": .string("options"),
			"key": .string("context_builder.model"),
			"agent": .string(DiscoverAgentKind.codexExec.rawValue)
		])
		let explicitOptions = try XCTUnwrap(explicitEnvelope["options"]?.arrayValue)
		XCTAssertFalse(explicitOptions.isEmpty)
		for option in explicitOptions {
			let object = try XCTUnwrap(option.objectValue)
			XCTAssertEqual(object["agent"]?.stringValue, DiscoverAgentKind.codexExec.rawValue)
		}
	}

	func testToolSchemaDescriptionsStayMinimalAndAvoidDiscoveryAgentPhrase() async throws {
		let harness = try await makeHarness()

		let propertyDescriptions = try schemaPropertyDescriptions(for: harness.tool)
		XCTAssertEqual(propertyDescriptions["agent"], "Filter options by CLI backend.")
		XCTAssertEqual(propertyDescriptions["limit"], "Maximum options returned (1–200).")
		XCTAssertEqual(propertyDescriptions["detailed"], "Include descriptions and model metadata.")

		for (name, description) in propertyDescriptions {
			let lowered = description.lowercased()
			XCTAssertFalse(
				lowered.contains("discovery-agent"),
				"Schema description for '\(name)' must not contain 'discovery-agent': \(description)"
			)
			XCTAssertFalse(
				lowered.contains("discovery agent"),
				"Schema description for '\(name)' must not contain 'discovery agent': \(description)"
			)
			XCTAssertFalse(
				description.contains("DiscoverAgentKind"),
				"Schema description for '\(name)' must not leak the type name 'DiscoverAgentKind': \(description)"
			)
		}
	}

	// MARK: - Helpers

	private struct Harness {
		// Retain the service so its `[weak self]` tool closures stay live for the test.
		let service: AppSettingsMCPService
		let tool: RepoPrompt.Tool
		let store: GlobalSettingsStore
		let fileStore: GlobalSettingsFileStore
		let notificationCenter: NotificationCenter
	}

	private func makeHarness() async throws -> Harness {
		let defaults = makeUserDefaults()
		let fileStore = GlobalSettingsFileStore(fileURL: try makeTemporarySettingsFileURL())
		let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
		let notificationCenter = NotificationCenter()
		let service = AppSettingsMCPService(store: store, notificationCenter: notificationCenter)
		let tools = await service.tools
		let tool = try XCTUnwrap(tools.first { $0.name == AppSettingsMCPService.toolName })
		return Harness(
			service: service,
			tool: tool,
			store: store,
			fileStore: fileStore,
			notificationCenter: notificationCenter
		)
	}

	/// Counts `.recommendationsDidApply` postings on the harness's dedicated
	/// NotificationCenter for the duration of `operation`. Listeners run
	/// synchronously because `NotificationCenter.post` is synchronous; the
	/// counter is wrapped in a reference box so the `@Sendable` observer
	/// closure can mutate it.
	private final class RecommendationsNotificationCounter: @unchecked Sendable {
		var count = 0
	}

	private final class FileSystemPreferencesNotificationCapture: @unchecked Sendable {
		var count = 0
		var lastKey: String?
	}

	private func countRecommendationsDidApply(
		notificationCenter: NotificationCenter,
		operation: () async throws -> Void
	) async throws -> Int {
		let counter = RecommendationsNotificationCounter()
		let token = notificationCenter.addObserver(
			forName: .recommendationsDidApply,
			object: nil,
			queue: nil
		) { _ in
			counter.count += 1
		}
		defer { notificationCenter.removeObserver(token) }
		try await operation()
		return counter.count
	}

	private func captureFileSystemPreferencesDidChange(
		notificationCenter: NotificationCenter,
		operation: () async throws -> Void
	) async throws -> FileSystemPreferencesNotificationCapture {
		let capture = FileSystemPreferencesNotificationCapture()
		let token = notificationCenter.addObserver(
			forName: .appSettingsFileSystemPreferencesDidChange,
			object: nil,
			queue: nil
		) { notification in
			capture.count += 1
			capture.lastKey = notification.userInfo?["key"] as? String
		}
		defer { notificationCenter.removeObserver(token) }
		try await operation()
		return capture
	}

	private func call(_ tool: RepoPrompt.Tool, _ args: [String: Value]) async throws -> [String: Value] {
		let value = try await tool(args)
		return try XCTUnwrap(value.objectValue)
	}

	private func values(from object: [String: Value]) throws -> [String: Value] {
		return try XCTUnwrap(object["values"]?.objectValue)
	}

	private func settingsCatalog(from object: [String: Value]) throws -> [[String: Value]] {
		let settings = try XCTUnwrap(object["settings"]?.arrayValue)
		return try settings.map { try XCTUnwrap($0.objectValue) }
	}

	private func assertInvalidParams(
		_ message: String,
		file: StaticString = #filePath,
		line: UInt = #line,
		operation: () async throws -> Value
	) async {
		do {
			_ = try await operation()
			XCTFail(message, file: file, line: line)
		} catch MCPError.invalidParams {
			// Expected.
		} catch {
			XCTFail("\(message); expected invalidParams, got \(error)", file: file, line: line)
		}
	}

	private func promptSectionsOrderJSON(_ sections: [PromptSection]) throws -> String {
		let data = try JSONEncoder().encode(sections)
		return try XCTUnwrap(String(data: data, encoding: .utf8))
	}

	/// Encodes `tool.inputSchema` to JSON and returns the `description` associated with
	/// each top-level property. Going through Codable avoids brittle pattern matching on
	/// `JSONSchema` cases as the MCP dependency evolves.
	private func schemaPropertyDescriptions(for tool: RepoPrompt.Tool) throws -> [String: String] {
		let data = try JSONEncoder().encode(tool.inputSchema)
		let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
		let properties = root["properties"] as? [String: Any] ?? [:]
		var descriptions: [String: String] = [:]
		for (name, payload) in properties {
			if let object = payload as? [String: Any],
				let description = object["description"] as? String {
				descriptions[name] = description
			}
		}
		return descriptions
	}

	private func makeTemporarySettingsFileURL() throws -> URL {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("RepoPrompt-AppSettingsMCPServiceTests-\(UUID().uuidString)", isDirectory: true)
		temporaryDirectories.append(directory)
		return directory
			.appendingPathComponent("Settings", isDirectory: true)
			.appendingPathComponent("globalSettings.json")
	}

	private func makeUserDefaults() -> UserDefaults {
		let suite = "RepoPrompt.AppSettingsMCPServiceTests.\(UUID().uuidString)"
		userDefaultsSuites.append(suite)
		let defaults = UserDefaults(suiteName: suite)!
		defaults.removePersistentDomain(forName: suite)
		return defaults
	}
}
