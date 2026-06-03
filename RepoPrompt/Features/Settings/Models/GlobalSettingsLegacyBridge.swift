import Foundation

/// Compatibility bridge for the legacy UserDefaults blobs and scalar keys that
/// backed GlobalSettingsStore before the Application Support JSON document became
/// the primary store.
///
/// Keep this bridge small and explicit during the rollback window: new code
/// reads/writes the JSON document, then mirrors legacy keys so older builds can
/// still run safely.
enum GlobalSettingsLegacyBridge {
	static let copyStorageKey = "copyGlobalSettingsV1"
	static let chatStorageKey = "chatGlobalSettingsV1"
	static let defaultsStorageKey = "globalDefaultsV1"
	static let coreShadowHashKey = "globalSettingsJSON.shadowHash.coreV1"
	static let scalarShadowHashKey = "globalSettingsJSON.shadowHash.scalarV2"
	static let lastWrittenSchemaVersionKey = "globalSettingsJSON.lastWrittenSchemaVersion"

	static let appearanceModeKey = SettingKeys.appearanceMode
	static let useTransparencyKey = "useTransparency"
	static let collapseLatestFileChangesKey = SettingKeys.collapseLatestFileChanges
	static let showTooltipsKey = SettingKeys.showTooltips
	static let experimentalAttributedTextEditorKey = "experimentalAttributedTextEditor"
	static let enableKeyboardShortcutsKey = SettingKeys.enableKeyboardShortcuts
	static let fontPresetBodySizeKey = SettingKeys.fontPresetBodySize

	static let promptSectionsOrderKey = "promptSectionsOrder"
	static let duplicateUserInstructionsAtTopKey = "duplicateUserInstructionsAtTop"
	static let filePathDisplayOptionKey = "filePathDisplayOption"
	static let selectedFilesSortMethodKey = "selectedFilesSortMethod"
	static let fileEditFormatKey = "fileEditFormat"
	static let includeDatetimeInUserInstructionsKey = "includeDatetimeInUserInstructionsV2"
	static let customPlanningPromptKey = "customPlanningPrompt"
	static let modelTemperatureKey = "modelTemperature"
	static let setModelTemperatureKey = "setModelTemperature"
	static let complexEditStrategyKey = "complexEditStrategy"

	static let preferredComposeModelKey = "preferredComposeModel"
	static let planningModelKey = "planningModel"
	static let mcpAutoStartKey = "mcpAutoStart"
	static let mcpTemporarilyDisablePresetsKey = "mcpTemporarilyDisablePresets"

	static let respectGitignoreKey = "respectGitignore"
	static let respectRepoIgnoreKey = "respectRepoIgnore"
	static let respectCursorignoreKey = "respectCursorignore"
	static let globalIgnoreDefaultsKey = IgnoreSettingsDefaults.globalIgnoreDefaultsKey
	static let globalIgnoreDefaultsVersionKey = IgnoreSettingsDefaults.globalIgnoreDefaultsVersionKey
	static let enableHierarchicalIgnoresKey = "enableHierarchicalIgnores"
	static let skipSymlinksKey = "skipSymlinks_v2"
	static let showEmptyFoldersKey = "showEmptyFolders"

	static let proEditAgentModeKey = "proEditAgentMode"
	static let proEditAgentKindKey = "proEditAgentKind"
	static let proEditAgentModelKey = "proEditAgentModel"
	static let proEditAgentModeMigratedKey = "ProEditAgentModeMigrated"
	// DEPRECATED: Auto-Expand Tool Cards was removed in 2026-04.
	// Retained as a constant for decode/test references during the rollback window;
	// do not import from, write to, or hash this legacy key.
	static let agentAutoExpandToolCardsKey = "agentAutoExpandToolCards"
	static let maxBackgroundAgentComposeTabsKey = "agentMode.maxBackgroundAgentComposeTabs"
	static let showBuiltInWorkflowCleanupGuidanceKey = "agentMode.showBuiltInWorkflowCleanupGuidance"
	static let restrictMCPAgentDiscoveryToRoleLabelsKey = "agentMode.restrictMCPAgentDiscoveryToRoleLabels"

	static let modelDiffOverridesKey = "ModelDiffOverrides"
	static let modelStreamOverridesKey = "ModelStreamOverrides"
	static let modelTemperatureOverridesKey = "ModelTemperatureOverrides"
	static let modelResponsesOverridesKey = "ModelResponsesOverrides"

	struct ScalarPreferenceImportResult {
		let preferences: GlobalScalarPreferences
		let modelSelectionEvents: [ModelSelectionImportEvent]
	}

	struct ModelSelectionImportEvent: Equatable {
		let key: Key
		let existingValue: String?
		let legacyValue: String?
		let resultValue: String?
		let action: Action

		enum Key: Equatable {
			case preferredComposeModel
			case planningModel
			case syncChatModelWithOracle
		}

		enum Action: Equatable {
			case applied
			case protectedExistingJSON
		}
	}

	static func document(from defaults: UserDefaults = .standard, updatedAt: Date = Date()) -> GlobalSettingsDocument {
		GlobalSettingsDocument(
			updatedAt: updatedAt,
			copySettings: copySettings(from: defaults),
			chatSettings: chatSettings(from: defaults),
			globalDefaults: globalDefaults(from: defaults),
			scalarPreferences: scalarPreferences(from: defaults)
		)
	}

	static func copySettings(from defaults: UserDefaults = .standard) -> [UUID: CopyGlobalSettings] {
		decode([UUID: CopyGlobalSettings].self, key: copyStorageKey, defaults: defaults) ?? [:]
	}

	static func chatSettings(from defaults: UserDefaults = .standard) -> [UUID: ChatGlobalSettings] {
		decode([UUID: ChatGlobalSettings].self, key: chatStorageKey, defaults: defaults) ?? [:]
	}

	static func globalDefaults(from defaults: UserDefaults = .standard) -> GlobalDefaults {
		decode(GlobalDefaults.self, key: defaultsStorageKey, defaults: defaults)
			?? GlobalDefaults(discoverAgentRaw: nil, discoverModelsByAgent: nil)
	}

	static func scalarPreferences(
		from defaults: UserDefaults = .standard,
		preservingModelSelectionFrom existing: GlobalScalarPreferences?
	) -> ScalarPreferenceImportResult {
		var imported = scalarPreferences(from: defaults)
		guard let existing else {
			return ScalarPreferenceImportResult(preferences: imported, modelSelectionEvents: [])
		}

		let existingModelSelection = existing.modelSelection
		let legacyModelSelection = imported.modelSelection
		var mergedModelSelection = legacyModelSelection ?? GlobalScalarPreferences.ModelSelectionSettings()
		var events: [ModelSelectionImportEvent] = []

		func nonEmpty(_ value: String?) -> String? {
			guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
				return nil
			}
			return value
		}

		func mergeString(
			key: ModelSelectionImportEvent.Key,
			existingValue: String?,
			legacyValue: String?,
			assign: (String?) -> Void
		) {
			if let protectedValue = nonEmpty(existingValue) {
				assign(protectedValue)
				if protectedValue != legacyValue {
					events.append(ModelSelectionImportEvent(
						key: key,
						existingValue: existingValue,
						legacyValue: legacyValue,
						resultValue: protectedValue,
						action: .protectedExistingJSON
					))
				}
			} else {
				assign(legacyValue)
				if existingValue != legacyValue {
					events.append(ModelSelectionImportEvent(
						key: key,
						existingValue: existingValue,
						legacyValue: legacyValue,
						resultValue: legacyValue,
						action: .applied
					))
				}
			}
		}

		mergeString(
			key: .preferredComposeModel,
			existingValue: existingModelSelection?.preferredComposeModel,
			legacyValue: legacyModelSelection?.preferredComposeModel
		) { mergedModelSelection.preferredComposeModel = $0 }
		mergeString(
			key: .planningModel,
			existingValue: existingModelSelection?.planningModel,
			legacyValue: legacyModelSelection?.planningModel
		) { mergedModelSelection.planningModel = $0 }

		if let existingSync = existingModelSelection?.syncChatModelWithOracle {
			mergedModelSelection.syncChatModelWithOracle = existingSync
			let resultValue = String(existingSync)
			let legacyValue = legacyModelSelection?.syncChatModelWithOracle.map(String.init)
			if legacyValue != resultValue {
				events.append(ModelSelectionImportEvent(
					key: .syncChatModelWithOracle,
					existingValue: resultValue,
					legacyValue: legacyValue,
					resultValue: resultValue,
					action: .protectedExistingJSON
				))
			}
		} else {
			mergedModelSelection.syncChatModelWithOracle = legacyModelSelection?.syncChatModelWithOracle
			if legacyModelSelection?.syncChatModelWithOracle != nil {
				events.append(ModelSelectionImportEvent(
					key: .syncChatModelWithOracle,
					existingValue: nil,
					legacyValue: legacyModelSelection?.syncChatModelWithOracle.map(String.init),
					resultValue: legacyModelSelection?.syncChatModelWithOracle.map(String.init),
					action: .applied
				))
			}
		}

		imported.modelSelection = mergedModelSelection
		return ScalarPreferenceImportResult(preferences: imported, modelSelectionEvents: events)
	}

	static func scalarPreferences(from defaults: UserDefaults = .standard) -> GlobalScalarPreferences {
		let importedGlobalIgnoreDefaults: String?
		if defaults.object(forKey: globalIgnoreDefaultsKey) != nil {
			importedGlobalIgnoreDefaults = IgnoreSettingsDefaults.resolvedGlobalIgnoreDefaults(defaults: defaults)
		} else {
			importedGlobalIgnoreDefaults = nil
		}

		return GlobalScalarPreferences(
			ui: GlobalScalarPreferences.UISettings(
				appearanceMode: defaults.string(forKey: appearanceModeKey),
				useTransparency: optionalBool(forKey: useTransparencyKey, defaults: defaults),
				collapseLatestFileChanges: optionalBool(forKey: collapseLatestFileChangesKey, defaults: defaults),
				showTooltips: optionalBool(forKey: showTooltipsKey, defaults: defaults),
				experimentalAttributedTextEditor: optionalBool(forKey: experimentalAttributedTextEditorKey, defaults: defaults),
				enableKeyboardShortcuts: optionalBool(forKey: enableKeyboardShortcutsKey, defaults: defaults),
				fontScaleBodySize: optionalFontScaleBodySize(defaults: defaults)
			),
			promptPackaging: GlobalScalarPreferences.PromptPackagingSettings(
				promptSectionsOrder: defaults.string(forKey: promptSectionsOrderKey),
				duplicateUserInstructionsAtTop: optionalBool(forKey: duplicateUserInstructionsAtTopKey, defaults: defaults),
				filePathDisplayOption: defaults.string(forKey: filePathDisplayOptionKey),
				selectedFilesSortMethod: defaults.string(forKey: selectedFilesSortMethodKey),
				fileEditFormat: defaults.string(forKey: fileEditFormatKey),
				allowDiffModelsToRewrite: optionalBool(forKey: SettingKeys.allowDiffModelsToRewrite, defaults: defaults),
				includeDatetimeInUserInstructions: optionalBool(forKey: includeDatetimeInUserInstructionsKey, defaults: defaults),
				customPlanningPrompt: defaults.string(forKey: customPlanningPromptKey),
				modelTemperature: optionalDouble(forKey: modelTemperatureKey, defaults: defaults),
				setModelTemperature: optionalBool(forKey: setModelTemperatureKey, defaults: defaults),
				complexEditStrategy: defaults.string(forKey: complexEditStrategyKey)
			),
			modelSelection: GlobalScalarPreferences.ModelSelectionSettings(
				preferredComposeModel: defaults.string(forKey: preferredComposeModelKey),
				planningModel: defaults.string(forKey: planningModelKey),
				syncChatModelWithOracle: optionalBool(forKey: AgentModelSyncPreferences.syncChatModelWithOracleKey, defaults: defaults)
			),
			mcp: GlobalScalarPreferences.MCPSettings(
				autoStart: optionalBool(forKey: mcpAutoStartKey, defaults: defaults),
				showModelPresets: optionalBool(forKey: SettingKeys.mcpShowModelPresets, defaults: defaults),
				temporarilyDisablePresets: optionalBool(forKey: mcpTemporarilyDisablePresetsKey, defaults: defaults)
			),
			fileSystem: GlobalScalarPreferences.FileSystemSettings(
				respectGitignore: optionalBool(forKey: respectGitignoreKey, defaults: defaults),
				respectRepoIgnore: optionalBool(forKey: respectRepoIgnoreKey, defaults: defaults),
				respectCursorignore: optionalBool(forKey: respectCursorignoreKey, defaults: defaults),
				globalIgnoreDefaults: importedGlobalIgnoreDefaults,
				enableHierarchicalIgnores: optionalBool(forKey: enableHierarchicalIgnoresKey, defaults: defaults),
				skipSymlinks: optionalBool(forKey: skipSymlinksKey, defaults: defaults),
				showEmptyFolders: optionalBool(forKey: showEmptyFoldersKey, defaults: defaults)
			),
			agentMode: GlobalScalarPreferences.AgentModeSettings(
				proEditAgentMode: optionalBool(forKey: proEditAgentModeKey, defaults: defaults),
				proEditAgentKind: defaults.string(forKey: proEditAgentKindKey),
				proEditAgentModel: defaults.string(forKey: proEditAgentModelKey),
				proEditAgentModeMigrated: optionalBool(forKey: proEditAgentModeMigratedKey, defaults: defaults),
				maxBackgroundAgentComposeTabs: optionalInt(forKey: maxBackgroundAgentComposeTabsKey, defaults: defaults),
				showBuiltInWorkflowCleanupGuidance: optionalBool(forKey: showBuiltInWorkflowCleanupGuidanceKey, defaults: defaults),
				restrictMCPAgentDiscoveryToRoleLabels: optionalBool(forKey: restrictMCPAgentDiscoveryToRoleLabelsKey, defaults: defaults)
			),
			modelOverrides: GlobalScalarPreferences.ModelOverrideSettingsData(
				diffOverrides: optionalBoolDictionary(forKey: modelDiffOverridesKey, defaults: defaults),
				streamOverrides: optionalBoolDictionary(forKey: modelStreamOverridesKey, defaults: defaults),
				temperatureOverrides: optionalDoubleDictionary(forKey: modelTemperatureOverridesKey, defaults: defaults),
				responsesOverrides: optionalBoolDictionary(forKey: modelResponsesOverridesKey, defaults: defaults)
			)
		)
	}

	static func writeLegacyMirrors(
		copySettings: [UUID: CopyGlobalSettings],
		chatSettings: [UUID: ChatGlobalSettings],
		globalDefaults: GlobalDefaults,
		scalarPreferences: GlobalScalarPreferences? = nil,
		defaults: UserDefaults = .standard,
		updateShadow: Bool = true
	) {
		encodeAndSet(copySettings, key: copyStorageKey, defaults: defaults)
		encodeAndSet(chatSettings, key: chatStorageKey, defaults: defaults)
		encodeAndSet(globalDefaults, key: defaultsStorageKey, defaults: defaults)
		if let scalarPreferences {
			writeScalarLegacyMirrors(scalarPreferences, defaults: defaults)
		}
		if updateShadow {
			markCurrentCoreMirrorsAsShadowed(defaults: defaults)
			if scalarPreferences != nil {
				markCurrentScalarMirrorsAsShadowed(defaults: defaults)
			}
		}
	}

	static func writeScalarLegacyMirrors(_ scalarPreferences: GlobalScalarPreferences, defaults: UserDefaults = .standard) {
		let ui = scalarPreferences.ui
		setOrRemove(ui?.appearanceMode, key: appearanceModeKey, defaults: defaults)
		setOrRemove(ui?.useTransparency, key: useTransparencyKey, defaults: defaults)
		setOrRemove(ui?.collapseLatestFileChanges, key: collapseLatestFileChangesKey, defaults: defaults)
		setOrRemove(ui?.showTooltips, key: showTooltipsKey, defaults: defaults)
		setOrRemove(ui?.experimentalAttributedTextEditor, key: experimentalAttributedTextEditorKey, defaults: defaults)
		setOrRemove(ui?.enableKeyboardShortcuts, key: enableKeyboardShortcutsKey, defaults: defaults)
		setOrRemove(normalizedFontScaleBodySize(ui?.fontScaleBodySize), key: fontPresetBodySizeKey, defaults: defaults)

		let promptPackaging = scalarPreferences.promptPackaging
		setOrRemove(promptPackaging?.promptSectionsOrder, key: promptSectionsOrderKey, defaults: defaults)
		setOrRemove(promptPackaging?.duplicateUserInstructionsAtTop, key: duplicateUserInstructionsAtTopKey, defaults: defaults)
		setOrRemove(promptPackaging?.filePathDisplayOption, key: filePathDisplayOptionKey, defaults: defaults)
		setOrRemove(promptPackaging?.selectedFilesSortMethod, key: selectedFilesSortMethodKey, defaults: defaults)
		setOrRemove(promptPackaging?.fileEditFormat, key: fileEditFormatKey, defaults: defaults)
		setOrRemove(promptPackaging?.allowDiffModelsToRewrite, key: SettingKeys.allowDiffModelsToRewrite, defaults: defaults)
		setOrRemove(promptPackaging?.includeDatetimeInUserInstructions, key: includeDatetimeInUserInstructionsKey, defaults: defaults)
		setOrRemove(promptPackaging?.customPlanningPrompt, key: customPlanningPromptKey, defaults: defaults)
		setOrRemove(promptPackaging?.modelTemperature, key: modelTemperatureKey, defaults: defaults)
		setOrRemove(promptPackaging?.setModelTemperature, key: setModelTemperatureKey, defaults: defaults)
		setOrRemove(promptPackaging?.complexEditStrategy, key: complexEditStrategyKey, defaults: defaults)

		let modelSelection = scalarPreferences.modelSelection
		setOrRemove(modelSelection?.preferredComposeModel, key: preferredComposeModelKey, defaults: defaults)
		setOrRemove(modelSelection?.planningModel, key: planningModelKey, defaults: defaults)
		setOrRemove(modelSelection?.syncChatModelWithOracle, key: AgentModelSyncPreferences.syncChatModelWithOracleKey, defaults: defaults)

		let mcp = scalarPreferences.mcp
		setOrRemove(mcp?.autoStart, key: mcpAutoStartKey, defaults: defaults)
		setOrRemove(mcp?.showModelPresets, key: SettingKeys.mcpShowModelPresets, defaults: defaults)
		setOrRemove(mcp?.temporarilyDisablePresets, key: mcpTemporarilyDisablePresetsKey, defaults: defaults)

		let fileSystem = scalarPreferences.fileSystem
		setOrRemove(fileSystem?.respectGitignore, key: respectGitignoreKey, defaults: defaults)
		setOrRemove(fileSystem?.respectRepoIgnore, key: respectRepoIgnoreKey, defaults: defaults)
		setOrRemove(fileSystem?.respectCursorignore, key: respectCursorignoreKey, defaults: defaults)
		if let globalIgnoreDefaults = fileSystem?.globalIgnoreDefaults {
			defaults.set(globalIgnoreDefaults, forKey: globalIgnoreDefaultsKey)
			defaults.set(IgnoreSettingsDefaults.currentGlobalIgnoreDefaultsVersion, forKey: globalIgnoreDefaultsVersionKey)
		} else {
			defaults.removeObject(forKey: globalIgnoreDefaultsKey)
			defaults.removeObject(forKey: globalIgnoreDefaultsVersionKey)
		}
		setOrRemove(fileSystem?.enableHierarchicalIgnores, key: enableHierarchicalIgnoresKey, defaults: defaults)
		setOrRemove(fileSystem?.skipSymlinks, key: skipSymlinksKey, defaults: defaults)
		setOrRemove(fileSystem?.showEmptyFolders, key: showEmptyFoldersKey, defaults: defaults)

		let agentMode = scalarPreferences.agentMode
		setOrRemove(agentMode?.proEditAgentMode, key: proEditAgentModeKey, defaults: defaults)
		setOrRemove(agentMode?.proEditAgentKind, key: proEditAgentKindKey, defaults: defaults)
		setOrRemove(agentMode?.proEditAgentModel, key: proEditAgentModelKey, defaults: defaults)
		setOrRemove(agentMode?.proEditAgentModeMigrated, key: proEditAgentModeMigratedKey, defaults: defaults)
		setOrRemove(agentMode?.maxBackgroundAgentComposeTabs, key: maxBackgroundAgentComposeTabsKey, defaults: defaults)
		setOrRemove(agentMode?.showBuiltInWorkflowCleanupGuidance, key: showBuiltInWorkflowCleanupGuidanceKey, defaults: defaults)
		setOrRemove(agentMode?.restrictMCPAgentDiscoveryToRoleLabels, key: restrictMCPAgentDiscoveryToRoleLabelsKey, defaults: defaults)

		let modelOverrides = scalarPreferences.modelOverrides
		setOrRemove(modelOverrides?.diffOverrides, key: modelDiffOverridesKey, defaults: defaults)
		setOrRemove(modelOverrides?.streamOverrides, key: modelStreamOverridesKey, defaults: defaults)
		setOrRemove(modelOverrides?.temperatureOverrides, key: modelTemperatureOverridesKey, defaults: defaults)
		setOrRemove(modelOverrides?.responsesOverrides, key: modelResponsesOverridesKey, defaults: defaults)
	}

	static func shouldReimportLegacyMirrors(defaults: UserDefaults = .standard) -> Bool {
		guard hasAnyLegacyBlob(defaults: defaults),
			let shadowHash = defaults.string(forKey: coreShadowHashKey)
		else {
			return false
		}
		return currentCoreMirrorHash(defaults: defaults) != shadowHash
	}

	static func shouldReimportScalarPreferences(defaults: UserDefaults = .standard) -> Bool {
		guard let shadowHash = defaults.string(forKey: scalarShadowHashKey) else {
			return false
		}
		return scalarMirrorFingerprint(defaults: defaults) != shadowHash
	}

	static func scalarMirrorFingerprint(defaults: UserDefaults = .standard) -> String {
		currentScalarMirrorHash(defaults: defaults)
	}

	static func markCurrentCoreMirrorsAsShadowed(defaults: UserDefaults = .standard) {
		defaults.set(currentCoreMirrorHash(defaults: defaults), forKey: coreShadowHashKey)
		defaults.set(GlobalSettingsDocument.currentSchemaVersion, forKey: lastWrittenSchemaVersionKey)
	}

	static func markCurrentScalarMirrorsAsShadowed(defaults: UserDefaults = .standard) {
		defaults.set(currentScalarMirrorHash(defaults: defaults), forKey: scalarShadowHashKey)
		defaults.set(GlobalSettingsDocument.currentSchemaVersion, forKey: lastWrittenSchemaVersionKey)
	}

	static func markCurrentMirrorsAsShadowed(defaults: UserDefaults = .standard) {
		markCurrentCoreMirrorsAsShadowed(defaults: defaults)
		markCurrentScalarMirrorsAsShadowed(defaults: defaults)
	}

	static func hasAnyLegacyBlob(defaults: UserDefaults = .standard) -> Bool {
		defaults.data(forKey: copyStorageKey) != nil ||
			defaults.data(forKey: chatStorageKey) != nil ||
			defaults.data(forKey: defaultsStorageKey) != nil
	}

	static func hasAnyScalarPreference(defaults: UserDefaults = .standard) -> Bool {
		scalarPreferenceKeys.contains { defaults.object(forKey: $0) != nil }
	}

	private static let scalarPreferenceKeys = [
		appearanceModeKey,
		useTransparencyKey,
		collapseLatestFileChangesKey,
		showTooltipsKey,
		experimentalAttributedTextEditorKey,
		enableKeyboardShortcutsKey,
		fontPresetBodySizeKey,
		promptSectionsOrderKey,
		duplicateUserInstructionsAtTopKey,
		filePathDisplayOptionKey,
		selectedFilesSortMethodKey,
		fileEditFormatKey,
		SettingKeys.allowDiffModelsToRewrite,
		includeDatetimeInUserInstructionsKey,
		customPlanningPromptKey,
		modelTemperatureKey,
		setModelTemperatureKey,
		complexEditStrategyKey,
		preferredComposeModelKey,
		planningModelKey,
		AgentModelSyncPreferences.syncChatModelWithOracleKey,
		mcpAutoStartKey,
		SettingKeys.mcpShowModelPresets,
		mcpTemporarilyDisablePresetsKey,
		respectGitignoreKey,
		respectRepoIgnoreKey,
		respectCursorignoreKey,
		globalIgnoreDefaultsKey,
		enableHierarchicalIgnoresKey,
		skipSymlinksKey,
		showEmptyFoldersKey,
		proEditAgentModeKey,
		proEditAgentKindKey,
		proEditAgentModelKey,
		proEditAgentModeMigratedKey,
		// Deprecated Auto-Expand key intentionally omitted: this list also drives
		// legacy scalar reimport detection, so keeping it would let stale defaults
		// overwrite JSON-backed preferences.
		maxBackgroundAgentComposeTabsKey,
		showBuiltInWorkflowCleanupGuidanceKey,
		restrictMCPAgentDiscoveryToRoleLabelsKey,
		modelDiffOverridesKey,
		modelStreamOverridesKey,
		modelTemperatureOverridesKey,
		modelResponsesOverridesKey
	]

	private static func currentCoreMirrorHash(defaults: UserDefaults) -> String {
		var hash: UInt64 = 14_695_981_039_346_656_037
		for key in [copyStorageKey, chatStorageKey, defaultsStorageKey] {
			append(key.data(using: .utf8) ?? Data(), to: &hash)
			append(Data([0]), to: &hash)
			append(defaults.data(forKey: key) ?? Data(), to: &hash)
			append(Data([255]), to: &hash)
		}
		return String(hash, radix: 16)
	}

	private static func currentScalarMirrorHash(defaults: UserDefaults) -> String {
		var hash: UInt64 = 14_695_981_039_346_656_037
		for key in scalarPreferenceKeys.sorted() {
			append(key.data(using: .utf8) ?? Data(), to: &hash)
			append(Data([0]), to: &hash)
			if let object = defaults.object(forKey: key) {
				append(Data([1]), to: &hash)
				append(canonicalData(for: object), to: &hash)
			} else {
				append(Data([2]), to: &hash)
			}
			append(Data([255]), to: &hash)
		}
		return String(hash, radix: 16)
	}

	private static func canonicalData(for object: Any) -> Data {
		if JSONSerialization.isValidJSONObject(object),
			let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
			return data
		}
		if let string = object as? String {
			return Data(string.utf8)
		}
		if let number = object as? NSNumber {
			return Data(number.stringValue.utf8)
		}
		return Data(String(describing: object).utf8)
	}

	private static func append(_ data: Data, to hash: inout UInt64) {
		for byte in data {
			hash ^= UInt64(byte)
			hash &*= 1_099_511_628_211
		}
	}

	private static func decode<Value: Decodable>(
		_ type: Value.Type,
		key: String,
		defaults: UserDefaults
	) -> Value? {
		guard let data = defaults.data(forKey: key) else { return nil }
		return try? JSONDecoder().decode(type, from: data)
	}

	private static func encodeAndSet<Value: Encodable>(
		_ value: Value,
		key: String,
		defaults: UserDefaults
	) {
		guard let data = try? JSONEncoder().encode(value) else { return }
		defaults.set(data, forKey: key)
	}

	private static func optionalBool(forKey key: String, defaults: UserDefaults) -> Bool? {
		guard defaults.object(forKey: key) != nil else { return nil }
		return defaults.bool(forKey: key)
	}

	private static func optionalInt(forKey key: String, defaults: UserDefaults) -> Int? {
		guard defaults.object(forKey: key) != nil else { return nil }
		return defaults.integer(forKey: key)
	}

	private static func optionalDouble(forKey key: String, defaults: UserDefaults) -> Double? {
		guard defaults.object(forKey: key) != nil else { return nil }
		return defaults.double(forKey: key)
	}

	private static func optionalFontScaleBodySize(defaults: UserDefaults) -> Double? {
		guard let rawValue = optionalDouble(forKey: fontPresetBodySizeKey, defaults: defaults) else { return nil }
		return normalizedFontScaleBodySize(rawValue)
	}

	private static func normalizedFontScaleBodySize(_ rawValue: Double?) -> Double? {
		guard let rawValue else { return nil }
		return FontScalePreset(rawValue: rawValue)?.rawValue ?? FontScalePreset.normal.rawValue
	}

	private static func optionalBoolDictionary(forKey key: String, defaults: UserDefaults) -> [String: Bool]? {
		guard defaults.object(forKey: key) != nil else { return nil }
		return defaults.dictionary(forKey: key)?.compactMapValues { value in
			if let bool = value as? Bool { return bool }
			if let number = value as? NSNumber { return number.boolValue }
			return nil
		}
	}

	private static func optionalDoubleDictionary(forKey key: String, defaults: UserDefaults) -> [String: Double]? {
		guard defaults.object(forKey: key) != nil else { return nil }
		return defaults.dictionary(forKey: key)?.compactMapValues { value in
			if let double = value as? Double { return double }
			if let number = value as? NSNumber { return number.doubleValue }
			return nil
		}
	}

	private static func setOrRemove(_ value: String?, key: String, defaults: UserDefaults) {
		if let value {
			defaults.set(value, forKey: key)
		} else {
			defaults.removeObject(forKey: key)
		}
	}

	private static func setOrRemove(_ value: Bool?, key: String, defaults: UserDefaults) {
		if let value {
			defaults.set(value, forKey: key)
		} else {
			defaults.removeObject(forKey: key)
		}
	}

	private static func setOrRemove(_ value: Int?, key: String, defaults: UserDefaults) {
		if let value {
			defaults.set(value, forKey: key)
		} else {
			defaults.removeObject(forKey: key)
		}
	}

	private static func setOrRemove(_ value: Double?, key: String, defaults: UserDefaults) {
		if let value {
			defaults.set(value, forKey: key)
		} else {
			defaults.removeObject(forKey: key)
		}
	}

	private static func setOrRemove(_ value: [String: Bool]?, key: String, defaults: UserDefaults) {
		if let value {
			defaults.set(value, forKey: key)
		} else {
			defaults.removeObject(forKey: key)
		}
	}

	private static func setOrRemove(_ value: [String: Double]?, key: String, defaults: UserDefaults) {
		if let value {
			defaults.set(value, forKey: key)
		} else {
			defaults.removeObject(forKey: key)
		}
	}
}
