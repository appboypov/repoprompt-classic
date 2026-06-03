import XCTest
@testable import RepoPrompt

@MainActor
final class GlobalSettingsMigrationTests: XCTestCase {
	private var temporaryDirectories: [URL] = []
	private var userDefaultsSuites: [String] = []

	override func tearDownWithError() throws {
		CodexGoalSupport.setEnabledForTesting(nil)
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

	func testLoadOrMigrateCreatesJSONFromLegacyUserDefaultsBlobs() throws {
		let defaults = makeUserDefaults()
		let workspaceID = UUID()
		var globalDefaults = GlobalDefaults(discoverAgentRaw: "gemini", discoverModelsByAgent: ["gemini": "gemini-pro"])
		globalDefaults.discoveryTokenBudget = 120_000
		GlobalSettingsLegacyBridge.writeLegacyMirrors(
			copySettings: [workspaceID: CopyGlobalSettings(workspaceID: workspaceID)],
			chatSettings: [workspaceID: ChatGlobalSettings(workspaceID: workspaceID)],
			globalDefaults: globalDefaults,
			defaults: defaults
		)
		let fileStore = GlobalSettingsFileStore(fileURL: try makeTemporarySettingsFileURL())

		let document = fileStore.loadOrMigrate(defaults: defaults)

		XCTAssertEqual(document.copySettings[workspaceID]?.workspaceID, workspaceID)
		XCTAssertEqual(document.chatSettings[workspaceID]?.workspaceID, workspaceID)
		XCTAssertEqual(document.globalDefaults.discoverAgentRaw, "gemini")
		XCTAssertEqual(document.globalDefaults.discoveryTokenBudget, 120_000)
		let loadedFromDisk = try fileStore.load()
		XCTAssertEqual(loadedFromDisk.copySettings[workspaceID]?.workspaceID, workspaceID)
		XCTAssertEqual(loadedFromDisk.globalDefaults.discoverAgentRaw, "gemini")
	}

	func testGlobalSettingsStorePrefersExistingJSONOverLegacyBlobs() throws {
		let defaults = makeUserDefaults()
		let jsonWorkspaceID = UUID()
		let legacyWorkspaceID = UUID()
		GlobalSettingsLegacyBridge.writeLegacyMirrors(
			copySettings: [legacyWorkspaceID: CopyGlobalSettings(workspaceID: legacyWorkspaceID)],
			chatSettings: [legacyWorkspaceID: ChatGlobalSettings(workspaceID: legacyWorkspaceID)],
			globalDefaults: GlobalDefaults(
				discoverAgentRaw: DiscoverAgentKind.claudeCode.rawValue,
				discoverModelsByAgent: [DiscoverAgentKind.claudeCode.rawValue: AgentModel.claudeOpus.rawValue]
			),
			defaults: defaults
		)
		let fileStore = GlobalSettingsFileStore(fileURL: try makeTemporarySettingsFileURL())
		let jsonScalarPreferences = GlobalScalarPreferences(
			agentMode: GlobalScalarPreferences.AgentModeSettings(
				proEditAgentMode: true,
				proEditAgentKind: DiscoverAgentKind.claudeCode.rawValue,
				proEditAgentModel: AgentModel.claudeSonnet.rawValue,
				proEditAgentModeMigrated: true,
				agentAutoExpandToolCards: true,
				maxBackgroundAgentComposeTabs: 640
			)
		)
		try fileStore.save(GlobalSettingsDocument(
			copySettings: [jsonWorkspaceID: CopyGlobalSettings(workspaceID: jsonWorkspaceID)],
			chatSettings: [jsonWorkspaceID: ChatGlobalSettings(workspaceID: jsonWorkspaceID)],
			globalDefaults: GlobalDefaults(
				discoverAgentRaw: DiscoverAgentKind.gemini.rawValue,
				discoverModelsByAgent: [DiscoverAgentKind.gemini.rawValue: AgentModel.geminiPro3p1Preview.rawValue]
			),
			scalarPreferences: jsonScalarPreferences
		))

		let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)

		XCTAssertNotNil(store.copySettings[jsonWorkspaceID])
		XCTAssertNil(store.copySettings[legacyWorkspaceID])
		XCTAssertEqual(store.globalDiscoverAgentSelection().agentRaw, DiscoverAgentKind.gemini.rawValue)
		XCTAssertEqual(store.proEditAgentKindRaw(), DiscoverAgentKind.claudeCode.rawValue)
		XCTAssertEqual(store.proEditAgentModelRaw(), AgentModel.claudeSonnet.rawValue)
		XCTAssertTrue(store.proEditAgentModeMigrated())
		XCTAssertEqual(store.maxBackgroundAgentComposeTabs(), 640)
	}

	func testGlobalSettingsStoreDualWritesJSONAndLegacyMirrorsOnSave() throws {
		let defaults = makeUserDefaults()
		let workspaceID = UUID()
		let fileStore = GlobalSettingsFileStore(fileURL: try makeTemporarySettingsFileURL())
		let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)

		_ = store.copySettings(for: workspaceID)
		store.setCodeMapsGloballyDisabled(true)

		let document = try fileStore.load()
		XCTAssertEqual(document.copySettings[workspaceID]?.workspaceID, workspaceID)
		XCTAssertEqual(document.globalDefaults.codeMapsGloballyDisabled, true)

		let legacyCopySettings = GlobalSettingsLegacyBridge.copySettings(from: defaults)
		let legacyDefaults = GlobalSettingsLegacyBridge.globalDefaults(from: defaults)
		XCTAssertEqual(legacyCopySettings[workspaceID]?.workspaceID, workspaceID)
		XCTAssertEqual(legacyDefaults.codeMapsGloballyDisabled, true)
	}

	func testSchemaV1JSONMigratesScalarPreferencesFromLegacyUserDefaults() throws {
		let defaults = makeUserDefaults()
		defaults.set("Dark", forKey: GlobalSettingsLegacyBridge.appearanceModeKey)
		defaults.set(false, forKey: GlobalSettingsLegacyBridge.useTransparencyKey)
		defaults.set(true, forKey: GlobalSettingsLegacyBridge.collapseLatestFileChangesKey)
		defaults.set(false, forKey: GlobalSettingsLegacyBridge.showTooltipsKey)
		defaults.set(true, forKey: GlobalSettingsLegacyBridge.experimentalAttributedTextEditorKey)
		defaults.set(false, forKey: GlobalSettingsLegacyBridge.enableKeyboardShortcutsKey)
		defaults.set("[\"userInstructions\"]", forKey: GlobalSettingsLegacyBridge.promptSectionsOrderKey)
		defaults.set(true, forKey: GlobalSettingsLegacyBridge.duplicateUserInstructionsAtTopKey)
		defaults.set("Relative", forKey: GlobalSettingsLegacyBridge.filePathDisplayOptionKey)
		defaults.set("tokenAscending", forKey: GlobalSettingsLegacyBridge.selectedFilesSortMethodKey)
		defaults.set("Whole", forKey: GlobalSettingsLegacyBridge.fileEditFormatKey)
		defaults.set(false, forKey: SettingKeys.allowDiffModelsToRewrite)
		defaults.set(true, forKey: GlobalSettingsLegacyBridge.includeDatetimeInUserInstructionsKey)
		defaults.set("custom plan", forKey: GlobalSettingsLegacyBridge.customPlanningPromptKey)
		defaults.set(0.7, forKey: GlobalSettingsLegacyBridge.modelTemperatureKey)
		defaults.set(false, forKey: GlobalSettingsLegacyBridge.setModelTemperatureKey)
		defaults.set("Parallel split", forKey: GlobalSettingsLegacyBridge.complexEditStrategyKey)
		defaults.set("gpt-5.4", forKey: GlobalSettingsLegacyBridge.preferredComposeModelKey)
		defaults.set("gpt-5.4", forKey: GlobalSettingsLegacyBridge.planningModelKey)
		defaults.set(true, forKey: GlobalSettingsLegacyBridge.mcpAutoStartKey)
		defaults.set(true, forKey: SettingKeys.mcpShowModelPresets)
		defaults.set(false, forKey: GlobalSettingsLegacyBridge.mcpTemporarilyDisablePresetsKey)
		let legacyIgnoreDefaults = "# custom legacy ignores\n**/dist/\n"
		defaults.set(false, forKey: GlobalSettingsLegacyBridge.respectGitignoreKey)
		defaults.set(false, forKey: GlobalSettingsLegacyBridge.respectRepoIgnoreKey)
		defaults.set(false, forKey: GlobalSettingsLegacyBridge.respectCursorignoreKey)
		defaults.set(legacyIgnoreDefaults, forKey: GlobalSettingsLegacyBridge.globalIgnoreDefaultsKey)
		defaults.set(IgnoreSettingsDefaults.currentGlobalIgnoreDefaultsVersion, forKey: GlobalSettingsLegacyBridge.globalIgnoreDefaultsVersionKey)
		defaults.set(true, forKey: GlobalSettingsLegacyBridge.enableHierarchicalIgnoresKey)
		defaults.set(false, forKey: GlobalSettingsLegacyBridge.skipSymlinksKey)
		defaults.set(true, forKey: GlobalSettingsLegacyBridge.showEmptyFoldersKey)
		defaults.set(true, forKey: GlobalSettingsLegacyBridge.proEditAgentModeKey)
		defaults.set(DiscoverAgentKind.claudeCode.rawValue, forKey: GlobalSettingsLegacyBridge.proEditAgentKindKey)
		defaults.set(AgentModel.claudeSonnet.rawValue, forKey: GlobalSettingsLegacyBridge.proEditAgentModelKey)
		// Stale deprecated Auto-Expand defaults should not migrate back into scalar preferences.
		defaults.set(true, forKey: GlobalSettingsLegacyBridge.agentAutoExpandToolCardsKey)
		defaults.set(750, forKey: GlobalSettingsLegacyBridge.maxBackgroundAgentComposeTabsKey)
		defaults.set(false, forKey: GlobalSettingsLegacyBridge.showBuiltInWorkflowCleanupGuidanceKey)
		defaults.set(true, forKey: GlobalSettingsLegacyBridge.restrictMCPAgentDiscoveryToRoleLabelsKey)
		defaults.set(["custom-diff": true], forKey: GlobalSettingsLegacyBridge.modelDiffOverridesKey)
		defaults.set(["custom-stream": false], forKey: GlobalSettingsLegacyBridge.modelStreamOverridesKey)
		defaults.set(["custom-temp": 0.25], forKey: GlobalSettingsLegacyBridge.modelTemperatureOverridesKey)
		defaults.set(["custom-responses": true], forKey: GlobalSettingsLegacyBridge.modelResponsesOverridesKey)
		let fileURL = try makeTemporarySettingsFileURL()
		try writeSchemaV1Document(to: fileURL)
		let fileStore = GlobalSettingsFileStore(fileURL: fileURL)

		let document = fileStore.loadOrMigrate(defaults: defaults)

		XCTAssertEqual(document.schemaVersion, GlobalSettingsDocument.currentSchemaVersion)
		XCTAssertEqual(document.scalarPreferences?.ui?.appearanceMode, "Dark")
		XCTAssertEqual(document.scalarPreferences?.ui?.useTransparency, false)
		XCTAssertEqual(document.scalarPreferences?.ui?.collapseLatestFileChanges, true)
		XCTAssertEqual(document.scalarPreferences?.ui?.showTooltips, false)
		XCTAssertEqual(document.scalarPreferences?.ui?.experimentalAttributedTextEditor, true)
		XCTAssertEqual(document.scalarPreferences?.ui?.enableKeyboardShortcuts, false)
		XCTAssertEqual(document.scalarPreferences?.promptPackaging?.promptSectionsOrder, "[\"userInstructions\"]")
		XCTAssertEqual(document.scalarPreferences?.promptPackaging?.duplicateUserInstructionsAtTop, true)
		XCTAssertEqual(document.scalarPreferences?.promptPackaging?.filePathDisplayOption, "Relative")
		XCTAssertEqual(document.scalarPreferences?.promptPackaging?.selectedFilesSortMethod, "tokenAscending")
		XCTAssertEqual(document.scalarPreferences?.promptPackaging?.fileEditFormat, "Whole")
		XCTAssertEqual(document.scalarPreferences?.promptPackaging?.allowDiffModelsToRewrite, false)
		XCTAssertEqual(document.scalarPreferences?.promptPackaging?.includeDatetimeInUserInstructions, true)
		XCTAssertEqual(document.scalarPreferences?.promptPackaging?.customPlanningPrompt, "custom plan")
		XCTAssertEqual(document.scalarPreferences?.promptPackaging?.modelTemperature, 0.7)
		XCTAssertEqual(document.scalarPreferences?.promptPackaging?.setModelTemperature, false)
		XCTAssertEqual(document.scalarPreferences?.promptPackaging?.complexEditStrategy, "Parallel split")
		XCTAssertEqual(document.scalarPreferences?.modelSelection?.preferredComposeModel, "gpt-5.4")
		XCTAssertEqual(document.scalarPreferences?.modelSelection?.planningModel, "gpt-5.4")
		XCTAssertNil(document.scalarPreferences?.modelSelection?.syncChatModelWithOracle)
		XCTAssertEqual(document.scalarPreferences?.mcp?.autoStart, true)
		XCTAssertEqual(document.scalarPreferences?.mcp?.showModelPresets, true)
		XCTAssertEqual(document.scalarPreferences?.mcp?.temporarilyDisablePresets, false)
		XCTAssertEqual(document.scalarPreferences?.fileSystem?.respectGitignore, true)
		XCTAssertEqual(document.scalarPreferences?.fileSystem?.respectRepoIgnore, false)
		XCTAssertEqual(document.scalarPreferences?.fileSystem?.respectCursorignore, false)
		XCTAssertEqual(document.scalarPreferences?.fileSystem?.globalIgnoreDefaults, legacyIgnoreDefaults)
		XCTAssertEqual(document.scalarPreferences?.fileSystem?.enableHierarchicalIgnores, true)
		XCTAssertEqual(document.scalarPreferences?.fileSystem?.skipSymlinks, false)
		XCTAssertEqual(document.scalarPreferences?.fileSystem?.showEmptyFolders, true)
		XCTAssertEqual(document.scalarPreferences?.agentMode?.proEditAgentMode, true)
		XCTAssertEqual(document.scalarPreferences?.agentMode?.proEditAgentKind, DiscoverAgentKind.claudeCode.rawValue)
		XCTAssertEqual(document.scalarPreferences?.agentMode?.proEditAgentModel, AgentModel.claudeSonnet.rawValue)
		XCTAssertNil(document.scalarPreferences?.agentMode?.agentAutoExpandToolCards)
		XCTAssertEqual(document.scalarPreferences?.agentMode?.maxBackgroundAgentComposeTabs, 750)
		XCTAssertEqual(document.scalarPreferences?.agentMode?.showBuiltInWorkflowCleanupGuidance, false)
		XCTAssertEqual(document.scalarPreferences?.agentMode?.restrictMCPAgentDiscoveryToRoleLabels, true)
		XCTAssertEqual(document.scalarPreferences?.modelOverrides?.diffOverrides, ["custom-diff": true])
		XCTAssertEqual(document.scalarPreferences?.modelOverrides?.streamOverrides, ["custom-stream": false])
		XCTAssertEqual(document.scalarPreferences?.modelOverrides?.temperatureOverrides, ["custom-temp": 0.25])
		XCTAssertEqual(document.scalarPreferences?.modelOverrides?.responsesOverrides, ["custom-responses": true])
		XCTAssertNotNil(defaults.string(forKey: GlobalSettingsLegacyBridge.scalarShadowHashKey))

		let diskDocument = try fileStore.load()
		XCTAssertEqual(diskDocument.schemaVersion, GlobalSettingsDocument.currentSchemaVersion)
		XCTAssertEqual(diskDocument.scalarPreferences?.fileSystem?.respectGitignore, true)
		XCTAssertEqual(defaults.object(forKey: GlobalSettingsLegacyBridge.respectGitignoreKey) as? Bool, true)
		XCTAssertEqual(diskDocument.scalarPreferences?.agentMode?.maxBackgroundAgentComposeTabs, 750)
		XCTAssertEqual(diskDocument.scalarPreferences?.agentMode?.showBuiltInWorkflowCleanupGuidance, false)
		XCTAssertEqual(diskDocument.scalarPreferences?.agentMode?.restrictMCPAgentDiscoveryToRoleLabels, true)
		XCTAssertEqual(diskDocument.scalarPreferences?.modelOverrides?.diffOverrides, ["custom-diff": true])
	}

	func testSchemaV2MigrationForcesRespectGitignoreOnAndUpdatesLegacyMirror() throws {
		let defaults = makeUserDefaults()
		let legacyPreferences = GlobalScalarPreferences(
			fileSystem: GlobalScalarPreferences.FileSystemSettings(
				respectGitignore: false,
				respectRepoIgnore: false
			)
		)
		GlobalSettingsLegacyBridge.writeLegacyMirrors(
			copySettings: [:],
			chatSettings: [:],
			globalDefaults: GlobalDefaults(discoverAgentRaw: nil, discoverModelsByAgent: nil),
			scalarPreferences: legacyPreferences,
			defaults: defaults
		)
		let fileURL = try makeTemporarySettingsFileURL()
		try writeSchemaV2DocumentWithRespectGitignoreDisabled(to: fileURL)
		let fileStore = GlobalSettingsFileStore(fileURL: fileURL)

		let document = fileStore.loadOrMigrate(defaults: defaults)

		XCTAssertEqual(document.schemaVersion, GlobalSettingsDocument.currentSchemaVersion)
		XCTAssertEqual(document.scalarPreferences?.fileSystem?.respectGitignore, true)
		XCTAssertEqual(document.scalarPreferences?.fileSystem?.respectRepoIgnore, false)
		XCTAssertEqual(defaults.object(forKey: GlobalSettingsLegacyBridge.respectGitignoreKey) as? Bool, true)
		XCTAssertFalse(GlobalSettingsLegacyBridge.shouldReimportScalarPreferences(defaults: defaults))
		let diskDocument = try fileStore.load()
		XCTAssertEqual(diskDocument.scalarPreferences?.fileSystem?.respectGitignore, true)
		XCTAssertEqual(diskDocument.scalarPreferences?.fileSystem?.respectRepoIgnore, false)
	}

	func testLegacyOnlyMigrationForcesRespectGitignoreOnAndUpdatesLegacyMirror() throws {
		let defaults = makeUserDefaults()
		defaults.set(false, forKey: GlobalSettingsLegacyBridge.respectGitignoreKey)
		let fileStore = GlobalSettingsFileStore(fileURL: try makeTemporarySettingsFileURL())

		let document = fileStore.loadOrMigrate(defaults: defaults)

		XCTAssertEqual(document.schemaVersion, GlobalSettingsDocument.currentSchemaVersion)
		XCTAssertEqual(document.scalarPreferences?.fileSystem?.respectGitignore, true)
		XCTAssertEqual(defaults.object(forKey: GlobalSettingsLegacyBridge.respectGitignoreKey) as? Bool, true)
		XCTAssertFalse(GlobalSettingsLegacyBridge.shouldReimportScalarPreferences(defaults: defaults))
		let diskDocument = try fileStore.load()
		XCTAssertEqual(diskDocument.scalarPreferences?.fileSystem?.respectGitignore, true)
	}

	func testRespectGitignoreCanBeDisabledAfterSchemaV3Migration() throws {
		let defaults = makeUserDefaults()
		defaults.set(false, forKey: GlobalSettingsLegacyBridge.respectGitignoreKey)
		let fileURL = try makeTemporarySettingsFileURL()
		try writeSchemaV2DocumentWithRespectGitignoreDisabled(to: fileURL)
		let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
		let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
		XCTAssertTrue(store.respectGitignore())

		store.setRespectGitignore(false)
		let reloadedStore = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)

		XCTAssertFalse(reloadedStore.respectGitignore())
		XCTAssertEqual(defaults.object(forKey: GlobalSettingsLegacyBridge.respectGitignoreKey) as? Bool, false)
		let diskDocument = try fileStore.load()
		XCTAssertEqual(diskDocument.schemaVersion, GlobalSettingsDocument.currentSchemaVersion)
		XCTAssertEqual(diskDocument.scalarPreferences?.fileSystem?.respectGitignore, false)
	}

	func testLegacyGlobalIgnoreDefaultsUpgradeBeforeJSONMigration() throws {
		let defaults = makeUserDefaults()
		let staleDefaults = "# older defaults\n**/node_modules/\n"
		defaults.set(staleDefaults, forKey: GlobalSettingsLegacyBridge.globalIgnoreDefaultsKey)
		defaults.set(1, forKey: GlobalSettingsLegacyBridge.globalIgnoreDefaultsVersionKey)
		let fileStore = GlobalSettingsFileStore(fileURL: try makeTemporarySettingsFileURL())

		let document = fileStore.loadOrMigrate(defaults: defaults)

		let migratedDefaults = try XCTUnwrap(document.scalarPreferences?.fileSystem?.globalIgnoreDefaults)
		XCTAssertNotEqual(migratedDefaults, staleDefaults)
		XCTAssertTrue(migratedDefaults.contains("**/.pnpm-store/"))
		XCTAssertEqual(defaults.integer(forKey: GlobalSettingsLegacyBridge.globalIgnoreDefaultsVersionKey), IgnoreSettingsDefaults.currentGlobalIgnoreDefaultsVersion)
		let diskDocument = try fileStore.load()
		XCTAssertEqual(diskDocument.scalarPreferences?.fileSystem?.globalIgnoreDefaults, migratedDefaults)
	}

	func testScalarAccessorsReadJSONAndDualWriteLegacyMirrors() throws {
		let defaults = makeUserDefaults()
		let fileStore = GlobalSettingsFileStore(fileURL: try makeTemporarySettingsFileURL())
		let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)

		store.setAppearanceModeRaw("Light")
		store.setUseTransparency(false)
		store.setCollapseLatestFileChanges(true)
		store.setShowTooltips(false)
		store.setExperimentalAttributedTextEditor(true)
		store.setEnableKeyboardShortcuts(false)
		store.setPromptSectionsOrderRaw("[\"fileMap\"]")
		store.setDuplicateUserInstructionsAtTop(true)
		store.setFilePathDisplayOptionRaw("Relative")
		store.setSelectedFilesSortMethodRaw("dateNewest")
		store.setFileEditFormatRaw("None")
		store.setAllowDiffModelsToRewrite(false)
		store.setIncludeDatetimeInUserInstructions(true)
		store.setCustomPlanningPrompt("plan harder")
		store.setModelTemperature(0.4)
		store.setShouldSetModelTemperature(false)
		store.setComplexEditStrategyRaw("Single query")
		store.setPreferredComposeModelRaw("claude-sonnet-4")
		store.setPlanningModelRaw("gpt-5.4")
		store.setSyncChatModelWithOracle(false)
		store.setMCPAutoStart(true)
		store.setMCPShowModelPresets(true)
		store.setMCPTemporarilyDisablePresets(true)
		let ignoreDefaults = "  # keep raw ignore whitespace\n**/custom/\n"
		store.setRespectGitignore(false)
		store.setRespectRepoIgnore(false)
		store.setRespectCursorignore(false)
		store.setGlobalIgnoreDefaults(ignoreDefaults)
		store.setEnableHierarchicalIgnores(false)
		store.setSkipSymlinks(false)
		store.setShowEmptyFolders(true)
		store.updateProEditSettings { snapshot in
			snapshot.agentMode = true
			snapshot.agentKindRaw = DiscoverAgentKind.codexExec.rawValue
			snapshot.agentModelRaw = AgentModel.codexMedium.rawValue
			snapshot.agentModeMigrated = true
		}
		store.setMaxBackgroundAgentComposeTabs(800)
		store.setShowBuiltInWorkflowCleanupGuidance(false)
		store.setCodexGoalSupportEnabled(true)
		store.setRestrictMCPAgentDiscoveryToRoleLabels(true)
		store.setModelDiffOverrides(["diff-model": false])
		store.setModelStreamOverrides(["stream-model": true])
		store.setModelTemperatureOverrides(["temperature-model": 0.6])
		store.setModelResponsesOverrides(["responses-model": true])

		let document = try fileStore.load()
		XCTAssertEqual(document.scalarPreferences?.ui?.appearanceMode, "Light")
		XCTAssertEqual(document.scalarPreferences?.ui?.useTransparency, false)
		XCTAssertEqual(document.scalarPreferences?.ui?.collapseLatestFileChanges, true)
		XCTAssertEqual(document.scalarPreferences?.ui?.showTooltips, false)
		XCTAssertEqual(document.scalarPreferences?.ui?.experimentalAttributedTextEditor, true)
		XCTAssertEqual(document.scalarPreferences?.ui?.enableKeyboardShortcuts, false)
		XCTAssertEqual(document.scalarPreferences?.promptPackaging?.promptSectionsOrder, "[\"fileMap\"]")
		XCTAssertEqual(document.scalarPreferences?.promptPackaging?.duplicateUserInstructionsAtTop, true)
		XCTAssertEqual(document.scalarPreferences?.promptPackaging?.filePathDisplayOption, "Relative")
		XCTAssertEqual(document.scalarPreferences?.promptPackaging?.selectedFilesSortMethod, "dateNewest")
		XCTAssertEqual(document.scalarPreferences?.promptPackaging?.fileEditFormat, "None")
		XCTAssertEqual(document.scalarPreferences?.promptPackaging?.allowDiffModelsToRewrite, false)
		XCTAssertEqual(document.scalarPreferences?.promptPackaging?.includeDatetimeInUserInstructions, true)
		XCTAssertEqual(document.scalarPreferences?.promptPackaging?.customPlanningPrompt, "plan harder")
		XCTAssertEqual(document.scalarPreferences?.promptPackaging?.modelTemperature, 0.4)
		XCTAssertEqual(document.scalarPreferences?.promptPackaging?.setModelTemperature, false)
		XCTAssertEqual(document.scalarPreferences?.promptPackaging?.complexEditStrategy, "Single query")
		XCTAssertEqual(document.scalarPreferences?.modelSelection?.preferredComposeModel, "claude-sonnet-4")
		XCTAssertEqual(document.scalarPreferences?.modelSelection?.planningModel, "gpt-5.4")
		XCTAssertEqual(document.scalarPreferences?.modelSelection?.syncChatModelWithOracle, false)
		XCTAssertEqual(document.scalarPreferences?.mcp?.autoStart, true)
		XCTAssertEqual(document.scalarPreferences?.mcp?.showModelPresets, true)
		XCTAssertEqual(document.scalarPreferences?.mcp?.temporarilyDisablePresets, true)
		XCTAssertEqual(document.scalarPreferences?.fileSystem?.respectGitignore, false)
		XCTAssertEqual(document.scalarPreferences?.fileSystem?.respectRepoIgnore, false)
		XCTAssertEqual(document.scalarPreferences?.fileSystem?.respectCursorignore, false)
		XCTAssertEqual(document.scalarPreferences?.fileSystem?.globalIgnoreDefaults, ignoreDefaults)
		XCTAssertEqual(document.scalarPreferences?.fileSystem?.enableHierarchicalIgnores, false)
		XCTAssertEqual(document.scalarPreferences?.fileSystem?.skipSymlinks, false)
		XCTAssertEqual(document.scalarPreferences?.fileSystem?.showEmptyFolders, true)
		XCTAssertEqual(document.scalarPreferences?.agentMode?.proEditAgentMode, true)
		XCTAssertEqual(document.scalarPreferences?.agentMode?.proEditAgentKind, DiscoverAgentKind.codexExec.rawValue)
		XCTAssertEqual(document.scalarPreferences?.agentMode?.proEditAgentModel, AgentModel.codexMedium.rawValue)
		XCTAssertEqual(document.scalarPreferences?.agentMode?.proEditAgentModeMigrated, true)
		XCTAssertEqual(document.scalarPreferences?.agentMode?.maxBackgroundAgentComposeTabs, 800)
		XCTAssertEqual(document.scalarPreferences?.agentMode?.showBuiltInWorkflowCleanupGuidance, false)
		XCTAssertEqual(document.scalarPreferences?.agentMode?.codexGoalSupportEnabled, true)
		XCTAssertEqual(document.scalarPreferences?.agentMode?.restrictMCPAgentDiscoveryToRoleLabels, true)
		XCTAssertEqual(document.scalarPreferences?.modelOverrides?.diffOverrides, ["diff-model": false])
		XCTAssertEqual(document.scalarPreferences?.modelOverrides?.streamOverrides, ["stream-model": true])
		XCTAssertEqual(document.scalarPreferences?.modelOverrides?.temperatureOverrides, ["temperature-model": 0.6])
		XCTAssertEqual(document.scalarPreferences?.modelOverrides?.responsesOverrides, ["responses-model": true])

		XCTAssertEqual(defaults.string(forKey: GlobalSettingsLegacyBridge.appearanceModeKey), "Light")
		XCTAssertEqual(defaults.bool(forKey: GlobalSettingsLegacyBridge.useTransparencyKey), false)
		XCTAssertEqual(defaults.bool(forKey: GlobalSettingsLegacyBridge.collapseLatestFileChangesKey), true)
		XCTAssertEqual(defaults.bool(forKey: GlobalSettingsLegacyBridge.showTooltipsKey), false)
		XCTAssertEqual(defaults.bool(forKey: GlobalSettingsLegacyBridge.experimentalAttributedTextEditorKey), true)
		XCTAssertEqual(defaults.bool(forKey: GlobalSettingsLegacyBridge.enableKeyboardShortcutsKey), false)
		XCTAssertEqual(defaults.string(forKey: GlobalSettingsLegacyBridge.promptSectionsOrderKey), "[\"fileMap\"]")
		XCTAssertEqual(defaults.bool(forKey: GlobalSettingsLegacyBridge.duplicateUserInstructionsAtTopKey), true)
		XCTAssertEqual(defaults.string(forKey: GlobalSettingsLegacyBridge.filePathDisplayOptionKey), "Relative")
		XCTAssertEqual(defaults.string(forKey: GlobalSettingsLegacyBridge.selectedFilesSortMethodKey), "dateNewest")
		XCTAssertEqual(defaults.string(forKey: GlobalSettingsLegacyBridge.fileEditFormatKey), "None")
		XCTAssertEqual(defaults.bool(forKey: SettingKeys.allowDiffModelsToRewrite), false)
		XCTAssertEqual(defaults.bool(forKey: GlobalSettingsLegacyBridge.includeDatetimeInUserInstructionsKey), true)
		XCTAssertEqual(defaults.string(forKey: GlobalSettingsLegacyBridge.customPlanningPromptKey), "plan harder")
		XCTAssertEqual(defaults.double(forKey: GlobalSettingsLegacyBridge.modelTemperatureKey), 0.4)
		XCTAssertEqual(defaults.bool(forKey: GlobalSettingsLegacyBridge.setModelTemperatureKey), false)
		XCTAssertEqual(defaults.string(forKey: GlobalSettingsLegacyBridge.complexEditStrategyKey), "Single query")
		XCTAssertEqual(defaults.string(forKey: GlobalSettingsLegacyBridge.preferredComposeModelKey), "claude-sonnet-4")
		XCTAssertEqual(defaults.string(forKey: GlobalSettingsLegacyBridge.planningModelKey), "gpt-5.4")
		XCTAssertEqual(defaults.bool(forKey: AgentModelSyncPreferences.syncChatModelWithOracleKey), false)
		XCTAssertEqual(defaults.bool(forKey: GlobalSettingsLegacyBridge.mcpAutoStartKey), true)
		XCTAssertEqual(defaults.bool(forKey: SettingKeys.mcpShowModelPresets), true)
		XCTAssertEqual(defaults.bool(forKey: GlobalSettingsLegacyBridge.mcpTemporarilyDisablePresetsKey), true)
		XCTAssertEqual(defaults.bool(forKey: GlobalSettingsLegacyBridge.respectGitignoreKey), false)
		XCTAssertEqual(defaults.bool(forKey: GlobalSettingsLegacyBridge.respectRepoIgnoreKey), false)
		XCTAssertEqual(defaults.bool(forKey: GlobalSettingsLegacyBridge.respectCursorignoreKey), false)
		XCTAssertEqual(defaults.string(forKey: GlobalSettingsLegacyBridge.globalIgnoreDefaultsKey), ignoreDefaults)
		XCTAssertEqual(defaults.integer(forKey: GlobalSettingsLegacyBridge.globalIgnoreDefaultsVersionKey), IgnoreSettingsDefaults.currentGlobalIgnoreDefaultsVersion)
		XCTAssertEqual(defaults.bool(forKey: GlobalSettingsLegacyBridge.enableHierarchicalIgnoresKey), false)
		XCTAssertEqual(defaults.bool(forKey: GlobalSettingsLegacyBridge.skipSymlinksKey), false)
		XCTAssertEqual(defaults.bool(forKey: GlobalSettingsLegacyBridge.showEmptyFoldersKey), true)
		XCTAssertEqual(defaults.bool(forKey: GlobalSettingsLegacyBridge.proEditAgentModeKey), true)
		XCTAssertEqual(defaults.string(forKey: GlobalSettingsLegacyBridge.proEditAgentKindKey), DiscoverAgentKind.codexExec.rawValue)
		XCTAssertEqual(defaults.string(forKey: GlobalSettingsLegacyBridge.proEditAgentModelKey), AgentModel.codexMedium.rawValue)
		XCTAssertEqual(defaults.bool(forKey: GlobalSettingsLegacyBridge.proEditAgentModeMigratedKey), true)
		XCTAssertNil(defaults.object(forKey: GlobalSettingsLegacyBridge.agentAutoExpandToolCardsKey))
		XCTAssertEqual(defaults.integer(forKey: GlobalSettingsLegacyBridge.maxBackgroundAgentComposeTabsKey), 800)
		XCTAssertEqual(defaults.bool(forKey: GlobalSettingsLegacyBridge.showBuiltInWorkflowCleanupGuidanceKey), false)
		XCTAssertEqual(defaults.bool(forKey: GlobalSettingsLegacyBridge.restrictMCPAgentDiscoveryToRoleLabelsKey), true)
		XCTAssertEqual(defaults.dictionary(forKey: GlobalSettingsLegacyBridge.modelDiffOverridesKey) as? [String: Bool], ["diff-model": false])
		XCTAssertEqual(defaults.dictionary(forKey: GlobalSettingsLegacyBridge.modelStreamOverridesKey) as? [String: Bool], ["stream-model": true])
		XCTAssertEqual(defaults.dictionary(forKey: GlobalSettingsLegacyBridge.modelTemperatureOverridesKey) as? [String: Double], ["temperature-model": 0.6])
		XCTAssertEqual(defaults.dictionary(forKey: GlobalSettingsLegacyBridge.modelResponsesOverridesKey) as? [String: Bool], ["responses-model": true])
	}

	func testSyncChatModelWithOracleDerivesFromLegacyModelValuesWhenToggleMissing() throws {
		let defaults = makeUserDefaults()
		defaults.set("same-model", forKey: GlobalSettingsLegacyBridge.preferredComposeModelKey)
		defaults.set("same-model", forKey: GlobalSettingsLegacyBridge.planningModelKey)
		let fileStore = GlobalSettingsFileStore(fileURL: try makeTemporarySettingsFileURL())

		let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)

		XCTAssertTrue(store.syncChatModelWithOracle())
		XCTAssertNil(defaults.object(forKey: AgentModelSyncPreferences.syncChatModelWithOracleKey))
		store.setSyncChatModelWithOracle(false)
		XCTAssertFalse(store.syncChatModelWithOracle())
		XCTAssertEqual(defaults.bool(forKey: AgentModelSyncPreferences.syncChatModelWithOracleKey), false)
		let document = try fileStore.load()
		XCTAssertEqual(document.scalarPreferences?.modelSelection?.syncChatModelWithOracle, false)
	}

	func testCodexGoalSupportSurvivesUnrelatedLegacyScalarReimport() throws {
		let defaults = makeUserDefaults()
		let fileStore = GlobalSettingsFileStore(fileURL: try makeTemporarySettingsFileURL())
		let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)

		store.setCodexGoalSupportEnabled(true)
		XCTAssertTrue(store.codexGoalSupportEnabled())
		XCTAssertEqual(try fileStore.load().scalarPreferences?.agentMode?.codexGoalSupportEnabled, true)

		defaults.set(false, forKey: GlobalSettingsLegacyBridge.showTooltipsKey)
		XCTAssertTrue(GlobalSettingsLegacyBridge.shouldReimportScalarPreferences(defaults: defaults))

		XCTAssertFalse(store.showTooltips())
		XCTAssertTrue(store.codexGoalSupportEnabled())
	}

	func testDefaultScalarAccessorsPreserveLegacyFallbacksWhenKeysAreMissing() throws {
		let defaults = makeUserDefaults()
		let fileStore = GlobalSettingsFileStore(fileURL: try makeTemporarySettingsFileURL())

		let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)

		XCTAssertEqual(store.appearanceModeRaw(), "System")
		XCTAssertTrue(store.useTransparency())
		XCTAssertFalse(store.collapseLatestFileChanges())
		XCTAssertTrue(store.showTooltips())
		XCTAssertFalse(store.experimentalAttributedTextEditor())
		XCTAssertTrue(store.enableKeyboardShortcuts())
		XCTAssertEqual(store.promptSectionsOrderRaw(), "")
		XCTAssertFalse(store.duplicateUserInstructionsAtTop())
		XCTAssertEqual(store.filePathDisplayOptionRaw(), "Full")
		XCTAssertEqual(store.selectedFilesSortMethodRaw(), "nameAscending")
		XCTAssertEqual(store.fileEditFormatRaw(), "Diff")
		XCTAssertTrue(store.allowDiffModelsToRewrite())
		XCTAssertFalse(store.includeDatetimeInUserInstructions())
		XCTAssertEqual(store.customPlanningPrompt(), "")
		XCTAssertEqual(store.modelTemperature(), 0.0)
		XCTAssertTrue(store.shouldSetModelTemperature())
		XCTAssertEqual(store.complexEditStrategyRaw(), "Sequential split")
		XCTAssertNil(store.preferredComposeModelRaw())
		XCTAssertNil(store.planningModelRaw())
		XCTAssertFalse(store.syncChatModelWithOracle())
		XCTAssertFalse(store.mcpAutoStart())
		XCTAssertFalse(store.mcpShowModelPresets())
		XCTAssertFalse(store.mcpTemporarilyDisablePresets())
		XCTAssertTrue(store.respectGitignore())
		XCTAssertTrue(store.respectRepoIgnore())
		XCTAssertTrue(store.respectCursorignore())
		XCTAssertEqual(store.globalIgnoreDefaults(), IgnoreSettingsDefaults.canonicalGlobalIgnoreDefaults)
		XCTAssertTrue(store.enableHierarchicalIgnores())
		XCTAssertTrue(store.skipSymlinks())
		XCTAssertFalse(store.showEmptyFolders())
		XCTAssertFalse(store.proEditAgentMode())
		XCTAssertNil(store.proEditAgentKindRaw())
		XCTAssertNil(store.proEditAgentModelRaw())
		XCTAssertFalse(store.proEditAgentModeMigrated())
		XCTAssertEqual(store.maxBackgroundAgentComposeTabs(), 500)
		XCTAssertTrue(store.showBuiltInWorkflowCleanupGuidance())
		XCTAssertFalse(store.codexGoalSupportEnabled())
		XCTAssertFalse(store.restrictMCPAgentDiscoveryToRoleLabels())
		XCTAssertEqual(store.modelDiffOverrides(), [:])
		XCTAssertEqual(store.modelStreamOverrides(), [:])
		XCTAssertEqual(store.modelTemperatureOverrides(), [:])
		XCTAssertEqual(store.modelResponsesOverrides(), [:])
	}

	func testGlobalSettingsStoreSeedsGlobalIgnoreDefaultsWithoutDirtyingScalarShadow() throws {
		let defaults = makeUserDefaults()
		let fileStore = GlobalSettingsFileStore(fileURL: try makeTemporarySettingsFileURL())

		let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)

		XCTAssertEqual(defaults.string(forKey: GlobalSettingsLegacyBridge.globalIgnoreDefaultsKey), IgnoreSettingsDefaults.canonicalGlobalIgnoreDefaults)
		XCTAssertEqual(defaults.integer(forKey: GlobalSettingsLegacyBridge.globalIgnoreDefaultsVersionKey), IgnoreSettingsDefaults.currentGlobalIgnoreDefaultsVersion)
		XCTAssertFalse(GlobalSettingsLegacyBridge.shouldReimportScalarPreferences(defaults: defaults))
		let diskDocument = try fileStore.load()
		XCTAssertEqual(diskDocument.scalarPreferences?.fileSystem?.globalIgnoreDefaults, IgnoreSettingsDefaults.canonicalGlobalIgnoreDefaults)

		_ = store.fileSystemSettingsSnapshot()
		XCTAssertFalse(GlobalSettingsLegacyBridge.shouldReimportScalarPreferences(defaults: defaults))
	}

	func testRuntimeGlobalIgnoreDefaultsResolutionDoesNotDirtyScalarShadowAfterStoreInit() throws {
		let defaults = makeUserDefaults()
		let fileStore = GlobalSettingsFileStore(fileURL: try makeTemporarySettingsFileURL())
		_ = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)

		_ = IgnoreSettingsDefaults.resolvedGlobalIgnoreDefaults(defaults: defaults)

		XCTAssertFalse(GlobalSettingsLegacyBridge.shouldReimportScalarPreferences(defaults: defaults))
	}

	func testGlobalSettingsStoreUpgradesStaleGlobalIgnoreDefaultsWithoutDirtyingScalarShadow() throws {
		let defaults = makeUserDefaults()
		let staleDefaults = "# older defaults\n**/node_modules/\n"
		defaults.set(staleDefaults, forKey: GlobalSettingsLegacyBridge.globalIgnoreDefaultsKey)
		defaults.set(1, forKey: GlobalSettingsLegacyBridge.globalIgnoreDefaultsVersionKey)
		let fileStore = GlobalSettingsFileStore(fileURL: try makeTemporarySettingsFileURL())

		let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)

		let upgradedDefaults = store.fileSystemSettingsSnapshot().globalIgnoreDefaults
		XCTAssertNotEqual(upgradedDefaults, staleDefaults)
		XCTAssertTrue(upgradedDefaults.contains("**/.pnpm-store/"))
		XCTAssertEqual(defaults.string(forKey: GlobalSettingsLegacyBridge.globalIgnoreDefaultsKey), upgradedDefaults)
		XCTAssertEqual(defaults.integer(forKey: GlobalSettingsLegacyBridge.globalIgnoreDefaultsVersionKey), IgnoreSettingsDefaults.currentGlobalIgnoreDefaultsVersion)
		XCTAssertFalse(GlobalSettingsLegacyBridge.shouldReimportScalarPreferences(defaults: defaults))
		let diskDocument = try fileStore.load()
		XCTAssertEqual(diskDocument.scalarPreferences?.fileSystem?.globalIgnoreDefaults, upgradedDefaults)
	}

	func testScalarAccessorsReconcileChangedLegacyMirrorsBeforeRead() throws {
		let defaults = makeUserDefaults()
		let fileStore = GlobalSettingsFileStore(fileURL: try makeTemporarySettingsFileURL())
		let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
		store.setPreferredComposeModelRaw("json-model")
		store.setMCPShowModelPresets(false)

		defaults.set("legacy-after-store", forKey: GlobalSettingsLegacyBridge.preferredComposeModelKey)
		defaults.set(true, forKey: SettingKeys.mcpShowModelPresets)

		XCTAssertEqual(store.preferredComposeModelRaw(), "json-model")
		XCTAssertTrue(store.mcpShowModelPresets())
		let modelDiagnostic = store.recentSettingsWriteDiagnostics().last { $0.key == "preferredComposeModelRaw" }
		XCTAssertEqual(modelDiagnostic?.reason, "legacy_scalar_reimport.runtime.protected")
	}

	func testReadOnlyScalarReconciliationImportsOnceWithoutPersistingOrMarkingShadow() throws {
		let defaults = makeUserDefaults()
		let fileStore = GlobalSettingsFileStore(fileURL: try makeTemporarySettingsFileURL())
		let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
		store.setMCPShowModelPresets(false)
		let cleanShadow = try XCTUnwrap(defaults.string(forKey: GlobalSettingsLegacyBridge.scalarShadowHashKey))

		defaults.set(true, forKey: SettingKeys.mcpShowModelPresets)
		XCTAssertNotEqual(GlobalSettingsLegacyBridge.scalarMirrorFingerprint(defaults: defaults), cleanShadow)

		XCTAssertTrue(store.mcpShowModelPresets())
		XCTAssertEqual(defaults.string(forKey: GlobalSettingsLegacyBridge.scalarShadowHashKey), cleanShadow)
		XCTAssertTrue(GlobalSettingsLegacyBridge.shouldReimportScalarPreferences(defaults: defaults))
		let diskDocument = try fileStore.load()
		XCTAssertEqual(diskDocument.scalarPreferences?.mcp?.showModelPresets, false)

		store.setMCPAutoStart(true, commit: false)
		XCTAssertTrue(store.mcpAutoStart())
		XCTAssertTrue(store.mcpShowModelPresets())
		XCTAssertEqual(defaults.string(forKey: GlobalSettingsLegacyBridge.scalarShadowHashKey), cleanShadow)
		XCTAssertTrue(GlobalSettingsLegacyBridge.shouldReimportScalarPreferences(defaults: defaults))
	}

	func testCommittedSaveAfterReadOnlyScalarImportPersistsImportedStateAndMarksShadow() throws {
		let defaults = makeUserDefaults()
		let fileStore = GlobalSettingsFileStore(fileURL: try makeTemporarySettingsFileURL())
		let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
		store.setMCPShowModelPresets(false)
		let cleanShadow = try XCTUnwrap(defaults.string(forKey: GlobalSettingsLegacyBridge.scalarShadowHashKey))

		defaults.set(true, forKey: SettingKeys.mcpShowModelPresets)
		XCTAssertTrue(store.mcpShowModelPresets())
		XCTAssertEqual(defaults.string(forKey: GlobalSettingsLegacyBridge.scalarShadowHashKey), cleanShadow)
		XCTAssertTrue(GlobalSettingsLegacyBridge.shouldReimportScalarPreferences(defaults: defaults))

		store.setCodeMapsGloballyDisabled(true)

		XCTAssertFalse(GlobalSettingsLegacyBridge.shouldReimportScalarPreferences(defaults: defaults))
		XCTAssertEqual(defaults.string(forKey: GlobalSettingsLegacyBridge.scalarShadowHashKey), GlobalSettingsLegacyBridge.scalarMirrorFingerprint(defaults: defaults))
		let document = try fileStore.load()
		XCTAssertEqual(document.scalarPreferences?.mcp?.showModelPresets, true)
		XCTAssertEqual(document.globalDefaults.codeMapsGloballyDisabled, true)
	}

	func testDirtyScalarImportRestoresCleanShadowMirrorStateBeforeLaterSave() throws {
		let defaults = makeUserDefaults()
		let fileStore = GlobalSettingsFileStore(fileURL: try makeTemporarySettingsFileURL())
		let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
		store.setMCPShowModelPresets(false)
		let cleanShadow = try XCTUnwrap(defaults.string(forKey: GlobalSettingsLegacyBridge.scalarShadowHashKey))

		defaults.set(true, forKey: SettingKeys.mcpShowModelPresets)
		XCTAssertTrue(store.mcpShowModelPresets())
		XCTAssertTrue(GlobalSettingsLegacyBridge.shouldReimportScalarPreferences(defaults: defaults))

		defaults.set(false, forKey: SettingKeys.mcpShowModelPresets)
		XCTAssertEqual(GlobalSettingsLegacyBridge.scalarMirrorFingerprint(defaults: defaults), cleanShadow)
		XCTAssertFalse(GlobalSettingsLegacyBridge.shouldReimportScalarPreferences(defaults: defaults))
		XCTAssertFalse(store.mcpShowModelPresets())

		store.setCodeMapsGloballyDisabled(true)

		let document = try fileStore.load()
		XCTAssertEqual(document.scalarPreferences?.mcp?.showModelPresets, false)
		XCTAssertEqual(document.globalDefaults.codeMapsGloballyDisabled, true)
		XCTAssertEqual(defaults.object(forKey: SettingKeys.mcpShowModelPresets) as? Bool, false)
		XCTAssertFalse(GlobalSettingsLegacyBridge.shouldReimportScalarPreferences(defaults: defaults))
	}

	func testNoOpFontScaleDiskReloadDoesNotRewriteDirtyLegacyMirrorsOrMarkShadow() throws {
		let defaults = makeUserDefaults()
		let fileStore = GlobalSettingsFileStore(fileURL: try makeTemporarySettingsFileURL())
		let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
		store.setFontScaleBodySize(FontScalePreset.large.rawValue)
		let cleanShadow = try XCTUnwrap(defaults.string(forKey: GlobalSettingsLegacyBridge.scalarShadowHashKey))

		defaults.set(false, forKey: GlobalSettingsLegacyBridge.showTooltipsKey)
		XCTAssertTrue(GlobalSettingsLegacyBridge.shouldReimportScalarPreferences(defaults: defaults))

		let reloaded = store.reloadFontScaleBodySizeFromDiskUpdatingLegacyMirror()

		XCTAssertEqual(reloaded, FontScalePreset.large.rawValue)
		XCTAssertEqual(defaults.object(forKey: GlobalSettingsLegacyBridge.showTooltipsKey) as? Bool, false)
		XCTAssertEqual(defaults.string(forKey: GlobalSettingsLegacyBridge.scalarShadowHashKey), cleanShadow)
		XCTAssertTrue(GlobalSettingsLegacyBridge.shouldReimportScalarPreferences(defaults: defaults))
	}

	func testUnmigratedLegacyScalarWritesAreReconciledBeforeUnrelatedStoreSave() throws {
		let defaults = makeUserDefaults()
		defaults.set("old-model", forKey: GlobalSettingsLegacyBridge.preferredComposeModelKey)
		defaults.set(false, forKey: SettingKeys.mcpShowModelPresets)
		let fileStore = GlobalSettingsFileStore(fileURL: try makeTemporarySettingsFileURL())
		let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
		XCTAssertEqual(store.preferredComposeModelRaw(), "old-model")

		defaults.set("new-model", forKey: GlobalSettingsLegacyBridge.preferredComposeModelKey)
		defaults.set(true, forKey: SettingKeys.mcpShowModelPresets)
		store.setCodeMapsGloballyDisabled(true)

		XCTAssertEqual(defaults.string(forKey: GlobalSettingsLegacyBridge.preferredComposeModelKey), "old-model")
		XCTAssertEqual(defaults.bool(forKey: SettingKeys.mcpShowModelPresets), true)
		let document = try fileStore.load()
		XCTAssertEqual(document.scalarPreferences?.modelSelection?.preferredComposeModel, "old-model")
		XCTAssertEqual(document.scalarPreferences?.mcp?.showModelPresets, true)
		XCTAssertEqual(document.globalDefaults.codeMapsGloballyDisabled, true)
	}

	func testRemovingAllLegacyScalarMirrorsReconcilesToDefaultsBeforeUnrelatedSave() throws {
		let defaults = makeUserDefaults()
		let fileStore = GlobalSettingsFileStore(fileURL: try makeTemporarySettingsFileURL())
		let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
		store.setPreferredComposeModelRaw("json-model")
		XCTAssertEqual(defaults.string(forKey: GlobalSettingsLegacyBridge.preferredComposeModelKey), "json-model")
		XCTAssertNotNil(defaults.string(forKey: GlobalSettingsLegacyBridge.scalarShadowHashKey))

		defaults.removeObject(forKey: GlobalSettingsLegacyBridge.preferredComposeModelKey)
		XCTAssertTrue(GlobalSettingsLegacyBridge.shouldReimportScalarPreferences(defaults: defaults))

		store.setCodeMapsGloballyDisabled(true)

		XCTAssertEqual(defaults.string(forKey: GlobalSettingsLegacyBridge.preferredComposeModelKey), "json-model")
		XCTAssertFalse(GlobalSettingsLegacyBridge.shouldReimportScalarPreferences(defaults: defaults))
		let document = try fileStore.load()
		XCTAssertEqual(document.scalarPreferences?.modelSelection?.preferredComposeModel, "json-model")
		XCTAssertEqual(document.globalDefaults.codeMapsGloballyDisabled, true)
	}

	func testExpandedScalarLegacyKeysMatchCurrentStorageLiterals() {
		XCTAssertEqual(GlobalSettingsLegacyBridge.appearanceModeKey, "appearanceMode")
		XCTAssertEqual(GlobalSettingsLegacyBridge.useTransparencyKey, "useTransparency")
		XCTAssertEqual(GlobalSettingsLegacyBridge.collapseLatestFileChangesKey, "collapseLatestFileChanges")
		XCTAssertEqual(GlobalSettingsLegacyBridge.showTooltipsKey, "showTooltips")
		XCTAssertEqual(GlobalSettingsLegacyBridge.experimentalAttributedTextEditorKey, "experimentalAttributedTextEditor")
		XCTAssertEqual(GlobalSettingsLegacyBridge.enableKeyboardShortcutsKey, "enableKeyboardShortcuts")
		XCTAssertEqual(GlobalSettingsLegacyBridge.promptSectionsOrderKey, "promptSectionsOrder")
		XCTAssertEqual(GlobalSettingsLegacyBridge.duplicateUserInstructionsAtTopKey, "duplicateUserInstructionsAtTop")
		XCTAssertEqual(GlobalSettingsLegacyBridge.filePathDisplayOptionKey, "filePathDisplayOption")
		XCTAssertEqual(GlobalSettingsLegacyBridge.selectedFilesSortMethodKey, "selectedFilesSortMethod")
		XCTAssertEqual(GlobalSettingsLegacyBridge.fileEditFormatKey, "fileEditFormat")
		XCTAssertEqual(GlobalSettingsLegacyBridge.includeDatetimeInUserInstructionsKey, "includeDatetimeInUserInstructionsV2")
		XCTAssertEqual(GlobalSettingsLegacyBridge.customPlanningPromptKey, "customPlanningPrompt")
		XCTAssertEqual(GlobalSettingsLegacyBridge.modelTemperatureKey, "modelTemperature")
		XCTAssertEqual(GlobalSettingsLegacyBridge.setModelTemperatureKey, "setModelTemperature")
		XCTAssertEqual(GlobalSettingsLegacyBridge.complexEditStrategyKey, "complexEditStrategy")
		XCTAssertEqual(GlobalSettingsLegacyBridge.respectGitignoreKey, "respectGitignore")
		XCTAssertEqual(GlobalSettingsLegacyBridge.respectRepoIgnoreKey, "respectRepoIgnore")
		XCTAssertEqual(GlobalSettingsLegacyBridge.respectCursorignoreKey, "respectCursorignore")
		XCTAssertEqual(GlobalSettingsLegacyBridge.globalIgnoreDefaultsKey, "globalIgnoreDefaults")
		XCTAssertEqual(GlobalSettingsLegacyBridge.globalIgnoreDefaultsVersionKey, "globalIgnoreDefaultsVersion")
		XCTAssertEqual(GlobalSettingsLegacyBridge.enableHierarchicalIgnoresKey, "enableHierarchicalIgnores")
		XCTAssertEqual(GlobalSettingsLegacyBridge.skipSymlinksKey, "skipSymlinks_v2")
		XCTAssertEqual(GlobalSettingsLegacyBridge.showEmptyFoldersKey, "showEmptyFolders")
		XCTAssertEqual(GlobalSettingsLegacyBridge.showBuiltInWorkflowCleanupGuidanceKey, "agentMode.showBuiltInWorkflowCleanupGuidance")
		XCTAssertEqual(GlobalSettingsLegacyBridge.restrictMCPAgentDiscoveryToRoleLabelsKey, "agentMode.restrictMCPAgentDiscoveryToRoleLabels")
		XCTAssertEqual(GlobalSettingsLegacyBridge.modelDiffOverridesKey, "ModelDiffOverrides")
		XCTAssertEqual(GlobalSettingsLegacyBridge.modelStreamOverridesKey, "ModelStreamOverrides")
		XCTAssertEqual(GlobalSettingsLegacyBridge.modelTemperatureOverridesKey, "ModelTemperatureOverrides")
		XCTAssertEqual(GlobalSettingsLegacyBridge.modelResponsesOverridesKey, "ModelResponsesOverrides")
	}

	func testExistingV2JSONProtectsModelSelectionWhenScalarShadowIsMissing() throws {
		let defaults = makeUserDefaults()
		defaults.set("legacy-model", forKey: GlobalSettingsLegacyBridge.preferredComposeModelKey)
		let fileStore = GlobalSettingsFileStore(fileURL: try makeTemporarySettingsFileURL())
		let jsonPreferences = GlobalScalarPreferences(
			modelSelection: GlobalScalarPreferences.ModelSelectionSettings(preferredComposeModel: "json-model")
		)
		try fileStore.save(GlobalSettingsDocument(scalarPreferences: jsonPreferences))

		let migrated = fileStore.loadOrMigrate(defaults: defaults)

		XCTAssertEqual(migrated.scalarPreferences?.modelSelection?.preferredComposeModel, "json-model")
		XCTAssertNotNil(defaults.string(forKey: GlobalSettingsLegacyBridge.scalarShadowHashKey))
		let diskDocument = try fileStore.load()
		XCTAssertEqual(diskDocument.scalarPreferences?.modelSelection?.preferredComposeModel, "json-model")
	}

	func testExistingJSONReimportsScalarPreferencesWhenShadowHashChanged() throws {
		let defaults = makeUserDefaults()
		defaults.set("System", forKey: GlobalSettingsLegacyBridge.appearanceModeKey)
		defaults.set(false, forKey: GlobalSettingsLegacyBridge.duplicateUserInstructionsAtTopKey)
		defaults.set(["old-diff": false], forKey: GlobalSettingsLegacyBridge.modelDiffOverridesKey)
		defaults.set("old-model", forKey: GlobalSettingsLegacyBridge.preferredComposeModelKey)
		defaults.set(false, forKey: GlobalSettingsLegacyBridge.mcpAutoStartKey)
		let originalScalarPreferences = GlobalSettingsLegacyBridge.scalarPreferences(from: defaults)
		GlobalSettingsLegacyBridge.writeLegacyMirrors(
			copySettings: [:],
			chatSettings: [:],
			globalDefaults: GlobalDefaults(discoverAgentRaw: nil, discoverModelsByAgent: nil),
			scalarPreferences: originalScalarPreferences,
			defaults: defaults
		)
		let fileStore = GlobalSettingsFileStore(fileURL: try makeTemporarySettingsFileURL())
		try fileStore.save(GlobalSettingsDocument(scalarPreferences: originalScalarPreferences))

		defaults.set("Dark", forKey: GlobalSettingsLegacyBridge.appearanceModeKey)
		defaults.set(true, forKey: GlobalSettingsLegacyBridge.duplicateUserInstructionsAtTopKey)
		defaults.set(["new-diff": true], forKey: GlobalSettingsLegacyBridge.modelDiffOverridesKey)
		defaults.set("new-model", forKey: GlobalSettingsLegacyBridge.preferredComposeModelKey)
		defaults.set(true, forKey: GlobalSettingsLegacyBridge.mcpAutoStartKey)

		let migrated = fileStore.loadOrMigrate(defaults: defaults)

		XCTAssertEqual(migrated.scalarPreferences?.ui?.appearanceMode, "Dark")
		XCTAssertEqual(migrated.scalarPreferences?.promptPackaging?.duplicateUserInstructionsAtTop, true)
		XCTAssertEqual(migrated.scalarPreferences?.modelOverrides?.diffOverrides, ["new-diff": true])
		XCTAssertEqual(migrated.scalarPreferences?.modelSelection?.preferredComposeModel, "old-model")
		XCTAssertEqual(migrated.scalarPreferences?.mcp?.autoStart, true)
		XCTAssertFalse(GlobalSettingsLegacyBridge.shouldReimportScalarPreferences(defaults: defaults))
		let diskDocument = try fileStore.load()
		XCTAssertEqual(diskDocument.scalarPreferences?.ui?.appearanceMode, "Dark")
		XCTAssertEqual(diskDocument.scalarPreferences?.modelSelection?.preferredComposeModel, "old-model")
		XCTAssertEqual(diskDocument.scalarPreferences?.mcp?.autoStart, true)
	}

	func testExistingJSONReimportsLegacyWhenShadowHashChanged() throws {
		let defaults = makeUserDefaults()
		let jsonWorkspaceID = UUID()
		let legacyWorkspaceID = UUID()
		let fileStore = GlobalSettingsFileStore(fileURL: try makeTemporarySettingsFileURL())
		GlobalSettingsLegacyBridge.writeLegacyMirrors(
			copySettings: [jsonWorkspaceID: CopyGlobalSettings(workspaceID: jsonWorkspaceID)],
			chatSettings: [jsonWorkspaceID: ChatGlobalSettings(workspaceID: jsonWorkspaceID)],
			globalDefaults: GlobalDefaults(discoverAgentRaw: DiscoverAgentKind.claudeCode.rawValue, discoverModelsByAgent: [DiscoverAgentKind.claudeCode.rawValue: AgentModel.claudeOpus.rawValue]),
			defaults: defaults
		)
		try fileStore.save(GlobalSettingsDocument(
			copySettings: [jsonWorkspaceID: CopyGlobalSettings(workspaceID: jsonWorkspaceID)],
			chatSettings: [jsonWorkspaceID: ChatGlobalSettings(workspaceID: jsonWorkspaceID)],
			globalDefaults: GlobalDefaults(discoverAgentRaw: DiscoverAgentKind.claudeCode.rawValue, discoverModelsByAgent: [DiscoverAgentKind.claudeCode.rawValue: AgentModel.claudeOpus.rawValue])
		))

		GlobalSettingsLegacyBridge.writeLegacyMirrors(
			copySettings: [legacyWorkspaceID: CopyGlobalSettings(workspaceID: legacyWorkspaceID)],
			chatSettings: [legacyWorkspaceID: ChatGlobalSettings(workspaceID: legacyWorkspaceID)],
			globalDefaults: GlobalDefaults(discoverAgentRaw: DiscoverAgentKind.gemini.rawValue, discoverModelsByAgent: [DiscoverAgentKind.gemini.rawValue: AgentModel.geminiPro3p1Preview.rawValue]),
			defaults: defaults,
			updateShadow: false
		)

		let migrated = fileStore.loadOrMigrate(defaults: defaults)

		XCTAssertNil(migrated.copySettings[jsonWorkspaceID])
		XCTAssertEqual(migrated.copySettings[legacyWorkspaceID]?.workspaceID, legacyWorkspaceID)
		XCTAssertEqual(migrated.globalDefaults.discoverAgentRaw, DiscoverAgentKind.gemini.rawValue)
		XCTAssertFalse(GlobalSettingsLegacyBridge.shouldReimportLegacyMirrors(defaults: defaults))
		let diskDocument = try fileStore.load()
		XCTAssertEqual(diskDocument.copySettings[legacyWorkspaceID]?.workspaceID, legacyWorkspaceID)
	}

	func testDisputedSettingWritesRecordBoundedDiagnostics() throws {
		let defaults = makeUserDefaults()
		let fileStore = GlobalSettingsFileStore(fileURL: try makeTemporarySettingsFileURL())
		let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)

		store.setPreferredComposeModelRaw("compose-a", reason: "unit compose")
		store.setPlanningModelRaw("planning-a", commit: false, reason: "unit planning")
		store.setGlobalDiscoverAgentSelection(
			agentRaw: DiscoverAgentKind.codexExec.rawValue,
			modelRaw: "codex-model-a",
			markUserDefined: true,
			reason: "unit discover"
		)

		let diagnostics = store.recentSettingsWriteDiagnostics()
		XCTAssertEqual(diagnostics.map(\.key), [
			"preferredComposeModelRaw",
			"planningModelRaw",
			"globalDiscoverAgentSelection"
		])
		XCTAssertEqual(diagnostics[0].newValue, "compose-a")
		XCTAssertEqual(diagnostics[0].reason, "unit compose")
		XCTAssertEqual(diagnostics[1].newValue, "planning-a")
		XCTAssertFalse(diagnostics[1].commit)
		XCTAssertEqual(diagnostics[1].reason, "unit planning")
		XCTAssertEqual(diagnostics[2].newValue, "codexExec:codex-model-a")
		XCTAssertEqual(diagnostics[2].markUserDefined, true)
		XCTAssertEqual(diagnostics[2].reason, "unit discover")
		XCTAssertTrue(diagnostics.allSatisfy { !$0.caller.isEmpty })

		for index in 0..<90 {
			store.setPlanningModelRaw("planning-\(index)", commit: false, reason: "overflow")
		}

		let boundedDiagnostics = store.recentSettingsWriteDiagnostics()
		XCTAssertEqual(boundedDiagnostics.count, 80)
		XCTAssertEqual(boundedDiagnostics.last?.newValue, "planning-89")
	}

	private func writeSchemaV1Document(to fileURL: URL) throws {
		try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
		let json = """
		{
		"schemaVersion": 1,
		"updatedAt": "2026-04-18T00:00:00Z",
		"copySettingsByWorkspaceID": {},
		"chatSettingsByWorkspaceID": {},
		"globalDefaults": {}
		}
		"""
		try Data(json.utf8).write(to: fileURL)
	}

	private func writeSchemaV2DocumentWithRespectGitignoreDisabled(to fileURL: URL) throws {
		try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
		let json = """
		{
		"schemaVersion": 2,
		"updatedAt": "2026-05-19T00:00:00Z",
		"copySettingsByWorkspaceID": {},
		"chatSettingsByWorkspaceID": {},
		"globalDefaults": {},
		"scalarPreferences": {
			"fileSystem": {
				"respectGitignore": false,
				"respectRepoIgnore": false
			}
		}
		}
		"""
		try Data(json.utf8).write(to: fileURL)
	}

	private func makeTemporarySettingsFileURL() throws -> URL {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("RepoPrompt-GlobalSettingsMigrationTests-\(UUID().uuidString)", isDirectory: true)
		temporaryDirectories.append(directory)
		return directory
			.appendingPathComponent("Settings", isDirectory: true)
			.appendingPathComponent("globalSettings.json")
	}

	private func makeUserDefaults() -> UserDefaults {
		let suite = "RepoPrompt.GlobalSettingsMigrationTests.\(UUID().uuidString)"
		userDefaultsSuites.append(suite)
		let defaults = UserDefaults(suiteName: suite)!
		defaults.removePersistentDomain(forName: suite)
		return defaults
	}
}
