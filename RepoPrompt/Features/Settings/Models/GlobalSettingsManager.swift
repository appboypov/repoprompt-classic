import Foundation

// MARK: - Canonical Settings Keys
//
// SEARCH-HELPER: SettingKeys, AppStorage keys, UserDefaults keys, settings dedupe
//
// Centralized UserDefaults key constants for keys that were previously
// written as string literals across multiple `@AppStorage` declarations in
// `Views/Settings/`. Views that touch these keys should reference the
// constants below so renames stay safe and duplicate keys are easy to audit.
//
// Not every key in the app lives here — just the ones that appear in
// multiple settings views. Single-site keys can stay as inline literals.
enum SettingKeys {
	/// Controls whether diff-style models are allowed to rewrite whole files.
	/// Referenced by Advanced Settings and PromptViewModel.
	static let allowDiffModelsToRewrite = "allowDiffModelsToRewrite"

	/// Master toggle for all global keyboard shortcuts.
	/// Referenced by Advanced Settings and Keyboard Shortcuts settings.
	static let enableKeyboardShortcuts = "enableKeyboardShortcuts"

	/// Serialized `AppearanceMode` raw value (`system` / `light` / `dark`).
	/// Persisted once; re-read by AppearanceController and any appearance picker.
	static let appearanceMode = "appearanceMode"

	/// Whether to collapse the latest-file-changes panel by default.
	static let collapseLatestFileChanges = "collapseLatestFileChanges"

	/// Whether hover tooltips are shown globally.
	static let showTooltips = "showTooltips"

	/// Whether the MCP Oracle UI exposes the Model Presets affordance.
	/// Referenced by ChatSettingsView, MCPSettingsView, and the inline MCP toggle.
	static let mcpShowModelPresets = "mcpShowModelPresets"

	/// App-wide UI font scale preset body size.
	static let fontPresetBodySize = "fontPresetBodySize"
}

extension Notification.Name {
	/// Posted after app-wide file-system/ignore preferences are changed through
	/// the settings surface. `userInfo["key"]` contains the app_settings key.
	static let appSettingsFileSystemPreferencesDidChange = Notification.Name("RepoPromptAppSettingsFileSystemPreferencesDidChange")
}

// MARK: - Agent Models Settings Keys

/// Namespaced UserDefaults helpers for the Agent Models settings page.
/// Keeps key strings + defaulting rules in one place so view models don't race on initial derivation.
///
/// SEARCH-HELPER: Agent Models, Oracle Model, Built-in Chat Model, sync toggle
enum AgentModelSyncPreferences {
	/// UserDefaults key for the Oracle/Built-in-Chat sync toggle.
	static let syncChatModelWithOracleKey = "agentModels.syncChatModelWithOracle"

	/// Returns whether the user has ever explicitly stored a value for the sync toggle.
	static func hasStoredValue(defaults: UserDefaults = .standard) -> Bool {
		defaults.object(forKey: syncChatModelWithOracleKey) != nil
	}

	/// Derives the initial sync value from legacy storage when the toggle has never been set.
	/// Rule:
	///   - key present → use stored value
	///   - missing AND `preferredComposeModel == planningModel` (both non-empty) → true
	///   - missing AND values differ or one is empty → false
	static func isSyncEnabled(defaults: UserDefaults = .standard) -> Bool {
		if hasStoredValue(defaults: defaults) {
			return defaults.bool(forKey: syncChatModelWithOracleKey)
		}
		let planning = defaults.string(forKey: "planningModel") ?? ""
		let compose = defaults.string(forKey: "preferredComposeModel") ?? ""
		return !planning.isEmpty && planning == compose
	}

	/// Persist the user's choice for the sync toggle.
	static func setSyncEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
		defaults.set(enabled, forKey: syncChatModelWithOracleKey)
	}
}

// MARK: - Copy Global Settings (per workspace)
struct CopyGlobalSettings: Codable {
	var fileTreeOption: FileTreeOption
	var codeMapUsage: CodeMapUsage
	var gitInclusion: GitDiffInclusionMode
	var workspaceID: UUID

	// --- NEW: snapshot of Manual mode (persisted per workspace) ---
	/// Manual mode's last-known settings (when Manual is not active).
	var manualFileTreeOption: FileTreeOption? = nil
	var manualCodeMapUsage: CodeMapUsage? = nil
	var manualGitInclusion: GitDiffInclusionMode? = nil
	var manualSelectedPromptIDs: Set<UUID>? = nil
	var manualHasManualPromptSelection: Bool? = nil
	var manualWorkingCopyCustomizations: CopyCustomizations? = nil
	/// Optional: remembers the last non-manual preset for UX (copy context).
	var lastNonManualCopyPresetID: UUID? = nil

	init(workspaceID: UUID,
			fileTreeOption: FileTreeOption = .auto,
			codeMapUsage: CodeMapUsage = .auto,
			gitInclusion: GitDiffInclusionMode = .none,
			manualFileTreeOption: FileTreeOption? = nil,
			manualCodeMapUsage: CodeMapUsage? = nil,
			manualGitInclusion: GitDiffInclusionMode? = nil,
			manualSelectedPromptIDs: Set<UUID>? = nil,
			manualHasManualPromptSelection: Bool? = nil,
			manualWorkingCopyCustomizations: CopyCustomizations? = nil,
			lastNonManualCopyPresetID: UUID? = nil) {
		self.workspaceID = workspaceID
		self.fileTreeOption = fileTreeOption
		self.codeMapUsage = codeMapUsage
		self.gitInclusion = gitInclusion
		self.manualFileTreeOption = manualFileTreeOption
		self.manualCodeMapUsage = manualCodeMapUsage
		self.manualGitInclusion = manualGitInclusion
		self.manualSelectedPromptIDs = manualSelectedPromptIDs
		self.manualHasManualPromptSelection = manualHasManualPromptSelection
		self.manualWorkingCopyCustomizations = manualWorkingCopyCustomizations
		self.lastNonManualCopyPresetID = lastNonManualCopyPresetID
	}
}

// MARK: - Chat Global Settings (per workspace)
struct ChatGlobalSettings: Codable {
	var fileTreeOption: FileTreeOption
	var codeMapUsage: CodeMapUsage
	var gitInclusion: GitDiffInclusionMode
	var planActMode: PromptViewModel.PlanActMode
	var proFileEdits: Bool
	var workspaceID: UUID

	// --- NEW: snapshot of Manual mode (persisted per workspace) ---
	/// Manual mode's last-known chat settings (when Manual is not active).
	var manualFileTreeOption: FileTreeOption? = nil
	var manualCodeMapUsage: CodeMapUsage? = nil
	var manualGitInclusion: GitDiffInclusionMode? = nil
	var manualPlanActMode: PromptViewModel.PlanActMode? = nil
	var manualProFileEdits: Bool? = nil
	var manualSelectedPromptIDs: Set<UUID>? = nil
	var manualHasManualPromptSelection: Bool? = nil
	/// NEW: remember last non-manual preset so UI can restore it later
	var lastNonManualChatPresetID: UUID? = nil
	var lastNonManualChatPresetName: String? = nil

	// MARK: - Discover Agent & Model (workspace-scoped)
	var lastUsedDiscoverAgentRaw: String? = nil
	/// Maps agent rawValue to last-used model rawValue for that agent
	var lastUsedDiscoverModelsByAgent: [String: String]? = nil
	/// Discovery token budget (workspace-scoped)
	var discoveryTokenBudget: Int? = nil
	/// Discovery prompt enhancement mode (workspace-scoped) - stores raw value of PromptEnhancementMode enum
	var discoveryEnhancementMode: String? = nil
	/// Default auto-plan setting for new/unstored tabs (workspace-scoped fallback).
	/// Per-tab values live in ComposeTabState.discover.autoGeneratePlan.
	var discoveryAutoGeneratePlan: Bool? = nil
	/// Allow discovery agent to ask clarifying questions mid-run (workspace-scoped, UI-triggered)
	var discoveryAllowClarifyingQuestions: Bool? = nil
	/// Allow clarifying questions when discovery is triggered via MCP context_builder (workspace-scoped, defaults false)
	var discoveryAllowClarifyingQuestionsForMCP: Bool? = nil
	/// Timeout (in seconds) for clarifying question responses (workspace-scoped, defaults to 300)
	var discoveryQuestionTimeoutSeconds: TimeInterval? = nil
	/// Token budget for plan generation (workspace-scoped, defaults to 80k)
	var discoveryPlanTokenBudget: Int? = nil

	// MARK: - Recommendation Wizard (workspace-scoped)
	/// IDs of recommendations that have been dismissed/muted in this workspace.
	var mutedRecommendationIDs: Set<String>? = nil
	/// Timestamp of the last time user completed/dismissed the recommendation wizard.
	var lastRecommendationWizardCompletedAt: Date? = nil

	// MARK: - MCP Agent Role Default Overrides (legacy workspace-scoped)
	/// Legacy workspace-scoped role-default overrides.
	/// New code stores role defaults globally in GlobalDefaults.mcpAgentRoleOverrides and ignores this field
	/// after one-time migration. Kept for backwards compatibility and rollback safety.
	var mcpAgentRoleOverrides: [String: String]? = nil

	// MARK: - Recommendation Bootstrap Tracking (workspace-scoped)
	/// True when the user explicitly changed discover agent/model defaults.
	/// nil => legacy workspace (treat as user-defined to avoid auto changes)
	var didUserSetDiscoverAgentDefaults: Bool? = nil
	/// Set when we auto-apply recommendations on workspace creation (for idempotency).
	var didAutoApplyRecommendationsAt: Date? = nil

	init(workspaceID: UUID,
			fileTreeOption: FileTreeOption = .auto,
			codeMapUsage: CodeMapUsage = .auto,
			gitInclusion: GitDiffInclusionMode = .none,
			planActMode: PromptViewModel.PlanActMode = .chat,
			proFileEdits: Bool = false,
			manualFileTreeOption: FileTreeOption? = nil,
			manualCodeMapUsage: CodeMapUsage? = nil,
			manualGitInclusion: GitDiffInclusionMode? = nil,
			manualPlanActMode: PromptViewModel.PlanActMode? = nil,
			manualProFileEdits: Bool? = nil,
			manualSelectedPromptIDs: Set<UUID>? = nil,
			manualHasManualPromptSelection: Bool? = nil,
			lastNonManualChatPresetID: UUID? = nil,
			lastNonManualChatPresetName: String? = nil,
			lastUsedDiscoverAgentRaw: String? = nil,
			lastUsedDiscoverModelsByAgent: [String: String]? = nil,
			discoveryTokenBudget: Int? = nil,
			discoveryEnhancementMode: String? = nil,
			discoveryAutoGeneratePlan: Bool? = nil) {
		self.workspaceID = workspaceID
		self.fileTreeOption = fileTreeOption
		self.codeMapUsage = codeMapUsage
		self.gitInclusion = gitInclusion
		self.planActMode = planActMode
		self.proFileEdits = proFileEdits
		self.manualFileTreeOption = manualFileTreeOption
		self.manualCodeMapUsage = manualCodeMapUsage
		self.manualGitInclusion = manualGitInclusion
		self.manualPlanActMode = manualPlanActMode
		self.manualProFileEdits = manualProFileEdits
		self.manualSelectedPromptIDs = manualSelectedPromptIDs
		self.manualHasManualPromptSelection = manualHasManualPromptSelection
		self.lastNonManualChatPresetID = lastNonManualChatPresetID
		self.lastNonManualChatPresetName = lastNonManualChatPresetName
		self.lastUsedDiscoverAgentRaw = lastUsedDiscoverAgentRaw
		self.lastUsedDiscoverModelsByAgent = lastUsedDiscoverModelsByAgent
		self.discoveryTokenBudget = discoveryTokenBudget
		self.discoveryEnhancementMode = discoveryEnhancementMode
		self.discoveryAutoGeneratePlan = discoveryAutoGeneratePlan
	}
}

// MARK: - Global Defaults (cross-workspace seeding)
/// Stores the global discover agent/model selection (single source of truth).
/// This is NOT per-workspace - it's the same across all workspaces.
struct GlobalDefaults: Codable {
	/// Global discover agent selection (shared across all workspaces)
	var discoverAgentRaw: String?
	/// Maps agent rawValue to last-used model rawValue for that agent (global)
	var discoverModelsByAgent: [String: String]?
	var discoveryTokenBudget: Int?
	var discoveryEnhancementMode: String?
	/// Schema version for recommendations (used to clear mutes on new best practices)
	var recommendationSchemaVersion: Int?
	/// Schema version for discovery token budget (used to reset to new defaults)
	var tokenBudgetSchemaVersion: Int?
	/// True when the user has explicitly set the global discover agent/model
	var didUserSetDiscoverAgentDefaults: Bool?
	/// Global MCP Agent Mode role-default overrides (shared across all workspaces).
	/// Keys are TaskLabelKind rawValues, values are AgentModelSelectionID rawValues.
	var mcpAgentRoleOverrides: [String: String]?
	/// One-time migration version for legacy workspace-scoped MCP role overrides.
	var mcpAgentRoleOverridesMigrationVersion: Int?
	/// Global provider filter used by recommendation generation. nil means all providers.
	var recommendationProviderFilterRaw: [String]?
	/// Cross-workspace override that disables Code Maps without mutating per-workspace modes.
	var codeMapsGloballyDisabled: Bool?
}

// MARK: - Scalar Settings Snapshots

struct ProEditSettingsSnapshot: Equatable {
	var agentMode: Bool
	var agentKindRaw: String?
	var agentModelRaw: String?
	var agentModeMigrated: Bool
}

struct FileSystemSettingsSnapshot: Equatable {
	var respectGitignore: Bool
	var respectRepoIgnore: Bool
	var respectCursorignore: Bool
	var globalIgnoreDefaults: String
	var enableHierarchicalIgnores: Bool
	var skipSymlinks: Bool
	var showEmptyFolders: Bool
}

/// In-memory diagnostics for settings writes that affect recommendation satisfaction.
/// Kept deliberately small and non-persistent so callers can inspect recent writes
/// during triage without changing app state or bloating the settings document.
struct GlobalSettingsWriteDiagnostic: Equatable {
	let timestamp: Date
	let key: String
	let oldValue: String?
	let newValue: String?
	let commit: Bool
	let markUserDefined: Bool?
	let reason: String
	let caller: String
}

// MARK: - Global Settings Store (Persistent)
// This is the single source of truth for workspace default settings.
// Primary persistence is the Application Support JSON document at
// `~/Library/Application Support/RepoPrompt/Settings/globalSettings.json`.
// During the rollback window, saves also mirror the legacy UserDefaults blobs.
// Windows use WindowSettingsManager to maintain local overlays.
@MainActor
class GlobalSettingsStore: ObservableObject {
	static let shared = GlobalSettingsStore()

	private let defaults: UserDefaults
	private let fileStore: GlobalSettingsFileStoring

	@Published private(set) var copySettings: [UUID: CopyGlobalSettings] = [:]
	@Published private(set) var chatSettings: [UUID: ChatGlobalSettings] = [:]
	@Published private(set) var codeMapsGloballyDisabled: Bool = false
	private var globalDefaults = GlobalDefaults(discoverAgentRaw: nil, discoverModelsByAgent: nil)
	private var scalarPreferences = GlobalScalarPreferences()
	private var lastRuntimeImportedScalarMirrorHash: String?

	private static let defaultBackgroundAgentComposeTabHardLimit = 500
	private static let defaultComposeTabSoftLimit = 50
	private static let defaultAppearanceModeRaw = "System"
	private static let defaultFilePathDisplayOptionRaw = "Full"
	private static let defaultSelectedFilesSortMethodRaw = "nameAscending"
	private static let defaultFileEditFormatRaw = "Diff"
	private static let defaultComplexEditStrategyRaw = "Sequential split"
	private static let settingsWriteDiagnosticsLimit = 80

	private var settingsWriteDiagnostics: [GlobalSettingsWriteDiagnostic] = []

	init(
		defaults: UserDefaults = .standard,
		fileStore: GlobalSettingsFileStoring = GlobalSettingsFileStore()
	) {
		self.defaults = defaults
		self.fileStore = fileStore
		load()
		migrateLegacyMCPAgentRoleOverridesToGlobalIfNeeded(currentVersion: 1)
		// One-time migration: reset token budgets to new default (160k)
		// Bump version number to trigger another reset in the future if needed
		ensureLatestTokenBudgetSchema(currentVersion: 2)
		ensureFileSystemGlobalIgnoreDefaultsSeeded()
	}

	func recentSettingsWriteDiagnostics() -> [GlobalSettingsWriteDiagnostic] {
		settingsWriteDiagnostics
	}

	private func recordSettingsWriteDiagnostic(
		key: String,
		oldValue: String?,
		newValue: String?,
		commit: Bool,
		markUserDefined: Bool? = nil,
		reason: String?,
		fileID: StaticString,
		line: UInt,
		function: StaticString
	) {
		let fallbackReason = "\(function)"
		let trimmedReason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
		let diagnostic = GlobalSettingsWriteDiagnostic(
			timestamp: Date(),
			key: key,
			oldValue: oldValue,
			newValue: newValue,
			commit: commit,
			markUserDefined: markUserDefined,
			reason: trimmedReason?.isEmpty == false ? trimmedReason! : fallbackReason,
			caller: "\(fileID):\(line) \(function)"
		)
		settingsWriteDiagnostics.append(diagnostic)
		if settingsWriteDiagnostics.count > Self.settingsWriteDiagnosticsLimit {
			settingsWriteDiagnostics.removeFirst(settingsWriteDiagnostics.count - Self.settingsWriteDiagnosticsLimit)
		}
	}

	// MARK: - Access Methods

	func copySettings(for workspaceID: UUID) -> CopyGlobalSettings {
		if let existing = copySettings[workspaceID] {
			return existing
		}
		// Create default settings for new workspace
		let newSettings = CopyGlobalSettings(workspaceID: workspaceID)
		copySettings[workspaceID] = newSettings
		save()
		return newSettings
	}

	func chatSettings(for workspaceID: UUID) -> ChatGlobalSettings {
		chatSettingsResult(for: workspaceID).settings
	}

	/// Returns chat settings for a workspace, along with whether they were newly created.
	/// Use this when you need to know if this is a brand new workspace (for auto-apply).
	func chatSettingsResult(for workspaceID: UUID) -> (settings: ChatGlobalSettings, isNew: Bool) {
		if let existing = chatSettings[workspaceID] {
			return (existing, false)
		}
		// Create default settings for new workspace
		var newSettings = ChatGlobalSettings(workspaceID: workspaceID)
		seedChatSettingsDefaults(&newSettings)
		chatSettings[workspaceID] = newSettings
		save()
		return (newSettings, true)
	}

	func updateCopySettings(_ settings: CopyGlobalSettings) {
		copySettings[settings.workspaceID] = settings
		save()
	}

	func updateCopySettings(_ settings: CopyGlobalSettings, commit: Bool) {
		copySettings[settings.workspaceID] = settings
		if commit {
			save()
		}
	}

	func updateChatSettings(_ settings: ChatGlobalSettings) {
		chatSettings[settings.workspaceID] = settings
		// NOTE: We no longer sync workspace discover agent/model to global defaults here.
		// Global discover settings are now the single source of truth, updated only via
		// setGlobalDiscoverAgentSelection() when the user explicitly changes them.
		save()
	}

	func updateChatSettings(_ settings: ChatGlobalSettings, commit: Bool) {
		chatSettings[settings.workspaceID] = settings
		// NOTE: We no longer sync workspace discover agent/model to global defaults here.
		// Global discover settings are now the single source of truth.
		if commit {
			save()
		}
	}

	// MARK: - Scalar Preferences

	func appearanceModeRaw() -> String {
		reconcileScalarPreferencesFromLegacyIfNeeded()
		return scalarPreferences.ui?.appearanceMode ?? Self.defaultAppearanceModeRaw
	}

	func setAppearanceModeRaw(_ raw: String, commit: Bool = true) {
		updateUIScalar(commit: commit) { settings in
			settings.appearanceMode = raw
		}
	}

	func useTransparency() -> Bool {
		reconcileScalarPreferencesFromLegacyIfNeeded()
		return scalarPreferences.ui?.useTransparency ?? true
	}

	func setUseTransparency(_ enabled: Bool, commit: Bool = true) {
		updateUIScalar(commit: commit) { settings in
			settings.useTransparency = enabled
		}
	}

	func collapseLatestFileChanges() -> Bool {
		reconcileScalarPreferencesFromLegacyIfNeeded()
		return scalarPreferences.ui?.collapseLatestFileChanges ?? false
	}

	func setCollapseLatestFileChanges(_ enabled: Bool, commit: Bool = true) {
		updateUIScalar(commit: commit) { settings in
			settings.collapseLatestFileChanges = enabled
		}
	}

	func showTooltips() -> Bool {
		reconcileScalarPreferencesFromLegacyIfNeeded()
		return scalarPreferences.ui?.showTooltips ?? true
	}

	func setShowTooltips(_ enabled: Bool, commit: Bool = true) {
		updateUIScalar(commit: commit) { settings in
			settings.showTooltips = enabled
		}
	}

	func experimentalAttributedTextEditor() -> Bool {
		reconcileScalarPreferencesFromLegacyIfNeeded()
		return scalarPreferences.ui?.experimentalAttributedTextEditor ?? false
	}

	func setExperimentalAttributedTextEditor(_ enabled: Bool, commit: Bool = true) {
		updateUIScalar(commit: commit) { settings in
			settings.experimentalAttributedTextEditor = enabled
		}
	}

	func enableKeyboardShortcuts() -> Bool {
		reconcileScalarPreferencesFromLegacyIfNeeded()
		return scalarPreferences.ui?.enableKeyboardShortcuts ?? true
	}

	func setEnableKeyboardShortcuts(_ enabled: Bool, commit: Bool = true) {
		updateUIScalar(commit: commit) { settings in
			settings.enableKeyboardShortcuts = enabled
		}
	}

	func fontScaleBodySize() -> Double {
		reconcileScalarPreferencesFromLegacyIfNeeded()
		guard let rawValue = scalarPreferences.ui?.fontScaleBodySize,
			let preset = FontScalePreset(rawValue: rawValue)
		else {
			return FontScalePreset.normal.rawValue
		}
		return preset.rawValue
	}

	func setFontScaleBodySize(_ rawValue: Double, commit: Bool = true) {
		let normalized = FontScalePreset(rawValue: rawValue)?.rawValue ?? FontScalePreset.normal.rawValue
		updateUIScalar(commit: commit) { settings in
			settings.fontScaleBodySize = normalized
		}
	}

	func reloadFontScaleBodySizeFromDiskUpdatingLegacyMirror() -> Double? {
		do {
			let document = try fileStore.load()
			guard let diskRawValue = document.scalarPreferences?.ui?.fontScaleBodySize else {
				return nil
			}
			let normalized = FontScalePreset(rawValue: diskRawValue)?.rawValue ?? FontScalePreset.normal.rawValue
			var preferences = scalarPreferences
			var uiSettings = preferences.ui ?? GlobalScalarPreferences.UISettings()
			uiSettings.fontScaleBodySize = normalized
			preferences.ui = uiSettings
			guard preferences != scalarPreferences else {
				return normalized
			}

			objectWillChange.send()
			scalarPreferences = preferences
			GlobalSettingsLegacyBridge.writeScalarLegacyMirrors(scalarPreferences, defaults: defaults)
			GlobalSettingsLegacyBridge.markCurrentScalarMirrorsAsShadowed(defaults: defaults)
			lastRuntimeImportedScalarMirrorHash = nil
			return normalized
		} catch {
			print("⚠️ Failed to reload font scale from global settings JSON at \(fileStore.fileURL.path): \(error)")
			return nil
		}
	}

	func promptSectionsOrderRaw() -> String {
		reconcileScalarPreferencesFromLegacyIfNeeded()
		return scalarPreferences.promptPackaging?.promptSectionsOrder ?? ""
	}

	func setPromptSectionsOrderRaw(_ raw: String, commit: Bool = true) {
		updatePromptPackagingScalar(commit: commit) { settings in
			settings.promptSectionsOrder = raw
		}
	}

	func duplicateUserInstructionsAtTop() -> Bool {
		reconcileScalarPreferencesFromLegacyIfNeeded()
		return scalarPreferences.promptPackaging?.duplicateUserInstructionsAtTop ?? false
	}

	func setDuplicateUserInstructionsAtTop(_ enabled: Bool, commit: Bool = true) {
		updatePromptPackagingScalar(commit: commit) { settings in
			settings.duplicateUserInstructionsAtTop = enabled
		}
	}

	func filePathDisplayOptionRaw() -> String {
		reconcileScalarPreferencesFromLegacyIfNeeded()
		return scalarPreferences.promptPackaging?.filePathDisplayOption ?? Self.defaultFilePathDisplayOptionRaw
	}

	func setFilePathDisplayOptionRaw(_ raw: String, commit: Bool = true) {
		updatePromptPackagingScalar(commit: commit) { settings in
			settings.filePathDisplayOption = raw
		}
	}

	func selectedFilesSortMethodRaw() -> String {
		reconcileScalarPreferencesFromLegacyIfNeeded()
		return scalarPreferences.promptPackaging?.selectedFilesSortMethod ?? Self.defaultSelectedFilesSortMethodRaw
	}

	func setSelectedFilesSortMethodRaw(_ raw: String, commit: Bool = true) {
		updatePromptPackagingScalar(commit: commit) { settings in
			settings.selectedFilesSortMethod = raw
		}
	}

	func fileEditFormatRaw() -> String {
		reconcileScalarPreferencesFromLegacyIfNeeded()
		return scalarPreferences.promptPackaging?.fileEditFormat ?? Self.defaultFileEditFormatRaw
	}

	func setFileEditFormatRaw(_ raw: String, commit: Bool = true) {
		updatePromptPackagingScalar(commit: commit) { settings in
			settings.fileEditFormat = raw
		}
	}

	func allowDiffModelsToRewrite() -> Bool {
		reconcileScalarPreferencesFromLegacyIfNeeded()
		return scalarPreferences.promptPackaging?.allowDiffModelsToRewrite ?? true
	}

	func setAllowDiffModelsToRewrite(_ allowed: Bool, commit: Bool = true) {
		updatePromptPackagingScalar(commit: commit) { settings in
			settings.allowDiffModelsToRewrite = allowed
		}
	}

	func includeDatetimeInUserInstructions() -> Bool {
		reconcileScalarPreferencesFromLegacyIfNeeded()
		return scalarPreferences.promptPackaging?.includeDatetimeInUserInstructions ?? false
	}

	func setIncludeDatetimeInUserInstructions(_ enabled: Bool, commit: Bool = true) {
		updatePromptPackagingScalar(commit: commit) { settings in
			settings.includeDatetimeInUserInstructions = enabled
		}
	}

	func customPlanningPrompt() -> String {
		reconcileScalarPreferencesFromLegacyIfNeeded()
		return scalarPreferences.promptPackaging?.customPlanningPrompt ?? ""
	}

	func setCustomPlanningPrompt(_ prompt: String, commit: Bool = true) {
		updatePromptPackagingScalar(commit: commit) { settings in
			settings.customPlanningPrompt = prompt
		}
	}

	func modelTemperature() -> Double {
		reconcileScalarPreferencesFromLegacyIfNeeded()
		return scalarPreferences.promptPackaging?.modelTemperature ?? 0.0
	}

	func setModelTemperature(_ temperature: Double, commit: Bool = true) {
		updatePromptPackagingScalar(commit: commit) { settings in
			settings.modelTemperature = temperature
		}
	}

	func shouldSetModelTemperature() -> Bool {
		reconcileScalarPreferencesFromLegacyIfNeeded()
		return scalarPreferences.promptPackaging?.setModelTemperature ?? true
	}

	func setShouldSetModelTemperature(_ enabled: Bool, commit: Bool = true) {
		updatePromptPackagingScalar(commit: commit) { settings in
			settings.setModelTemperature = enabled
		}
	}

	func complexEditStrategyRaw() -> String {
		reconcileScalarPreferencesFromLegacyIfNeeded()
		return scalarPreferences.promptPackaging?.complexEditStrategy ?? Self.defaultComplexEditStrategyRaw
	}

	func setComplexEditStrategyRaw(_ raw: String, commit: Bool = true) {
		updatePromptPackagingScalar(commit: commit) { settings in
			settings.complexEditStrategy = raw
		}
	}

	func preferredComposeModelRaw() -> String? {
		reconcileScalarPreferencesFromLegacyIfNeeded()
		return scalarPreferences.modelSelection?.preferredComposeModel
	}

	func setPreferredComposeModelRaw(
		_ raw: String?,
		commit: Bool = true,
		reason: String? = nil,
		honorSync: Bool = false,
		fileID: StaticString = #fileID,
		line: UInt = #line,
		function: StaticString = #function
	) {
		reconcileScalarPreferencesFromLegacyIfNeeded()
		let oldPreferred = scalarPreferences.modelSelection?.preferredComposeModel
		let oldPlanning = scalarPreferences.modelSelection?.planningModel
		let shouldMirror = honorSync && resolvedSyncChatModelWithOracleFromCurrentPreferences()
		updateModelSelectionScalar(commit: commit) { settings in
			settings.preferredComposeModel = raw
			if shouldMirror {
				settings.planningModel = raw
			}
		}
		recordSettingsWriteDiagnostic(
			key: "preferredComposeModelRaw",
			oldValue: oldPreferred,
			newValue: raw,
			commit: commit,
			reason: reason,
			fileID: fileID,
			line: line,
			function: function
		)
		if shouldMirror && oldPlanning != raw {
			recordSettingsWriteDiagnostic(
				key: "planningModelRaw",
				oldValue: oldPlanning,
				newValue: raw,
				commit: commit,
				reason: syncSiblingReason(from: reason),
				fileID: fileID,
				line: line,
				function: function
			)
		}
	}

	func planningModelRaw() -> String? {
		reconcileScalarPreferencesFromLegacyIfNeeded()
		return scalarPreferences.modelSelection?.planningModel
	}

	func setPlanningModelRaw(
		_ raw: String?,
		commit: Bool = true,
		reason: String? = nil,
		honorSync: Bool = false,
		fileID: StaticString = #fileID,
		line: UInt = #line,
		function: StaticString = #function
	) {
		reconcileScalarPreferencesFromLegacyIfNeeded()
		let oldPlanning = scalarPreferences.modelSelection?.planningModel
		let oldPreferred = scalarPreferences.modelSelection?.preferredComposeModel
		let shouldMirror = honorSync && resolvedSyncChatModelWithOracleFromCurrentPreferences()
		updateModelSelectionScalar(commit: commit) { settings in
			settings.planningModel = raw
			if shouldMirror {
				settings.preferredComposeModel = raw
			}
		}
		recordSettingsWriteDiagnostic(
			key: "planningModelRaw",
			oldValue: oldPlanning,
			newValue: raw,
			commit: commit,
			reason: reason,
			fileID: fileID,
			line: line,
			function: function
		)
		if shouldMirror && oldPreferred != raw {
			recordSettingsWriteDiagnostic(
				key: "preferredComposeModelRaw",
				oldValue: oldPreferred,
				newValue: raw,
				commit: commit,
				reason: syncSiblingReason(from: reason),
				fileID: fileID,
				line: line,
				function: function
			)
		}
	}

	func syncChatModelWithOracle() -> Bool {
		reconcileScalarPreferencesFromLegacyIfNeeded()
		return resolvedSyncChatModelWithOracleFromCurrentPreferences()
	}

	func setSyncChatModelWithOracle(
		_ enabled: Bool,
		commit: Bool = true,
		reason: String? = nil,
		snapOnEnableToPlanning: Bool = false,
		fileID: StaticString = #fileID,
		line: UInt = #line,
		function: StaticString = #function
	) {
		reconcileScalarPreferencesFromLegacyIfNeeded()
		let oldStoredValue = scalarPreferences.modelSelection?.syncChatModelWithOracle.map(String.init)
		let oldPreferred = scalarPreferences.modelSelection?.preferredComposeModel
		let planning = scalarPreferences.modelSelection?.planningModel ?? ""
		let shouldSnap = enabled && snapOnEnableToPlanning && !planning.isEmpty && planning != oldPreferred
		updateModelSelectionScalar(commit: commit) { settings in
			settings.syncChatModelWithOracle = enabled
			if shouldSnap {
				settings.preferredComposeModel = planning
			}
		}
		recordSettingsWriteDiagnostic(
			key: "syncChatModelWithOracle",
			oldValue: oldStoredValue,
			newValue: String(enabled),
			commit: commit,
			reason: reason,
			fileID: fileID,
			line: line,
			function: function
		)
		if shouldSnap {
			recordSettingsWriteDiagnostic(
				key: "preferredComposeModelRaw",
				oldValue: oldPreferred,
				newValue: planning,
				commit: commit,
				reason: syncSnapReason(from: reason),
				fileID: fileID,
				line: line,
				function: function
			)
		}
	}

	func mcpAutoStart() -> Bool {
		reconcileScalarPreferencesFromLegacyIfNeeded()
		return scalarPreferences.mcp?.autoStart ?? false
	}

	func setMCPAutoStart(_ enabled: Bool, commit: Bool = true) {
		updateMCPScalar(commit: commit) { settings in
			settings.autoStart = enabled
		}
	}

	func mcpShowModelPresets() -> Bool {
		reconcileScalarPreferencesFromLegacyIfNeeded()
		return scalarPreferences.mcp?.showModelPresets ?? false
	}

	func setMCPShowModelPresets(_ enabled: Bool, commit: Bool = true) {
		updateMCPScalar(commit: commit) { settings in
			settings.showModelPresets = enabled
		}
	}

	func mcpTemporarilyDisablePresets() -> Bool {
		reconcileScalarPreferencesFromLegacyIfNeeded()
		return scalarPreferences.mcp?.temporarilyDisablePresets ?? false
	}

	func setMCPTemporarilyDisablePresets(_ enabled: Bool, commit: Bool = true) {
		updateMCPScalar(commit: commit) { settings in
			settings.temporarilyDisablePresets = enabled
		}
	}

	func respectGitignore() -> Bool {
		reconcileScalarPreferencesFromLegacyIfNeeded()
		return scalarPreferences.fileSystem?.respectGitignore ?? true
	}

	func setRespectGitignore(_ enabled: Bool, commit: Bool = true) {
		updateFileSystemScalar(commit: commit) { settings in
			settings.respectGitignore = enabled
		}
	}

	func respectRepoIgnore() -> Bool {
		reconcileScalarPreferencesFromLegacyIfNeeded()
		return scalarPreferences.fileSystem?.respectRepoIgnore ?? true
	}

	func setRespectRepoIgnore(_ enabled: Bool, commit: Bool = true) {
		updateFileSystemScalar(commit: commit) { settings in
			settings.respectRepoIgnore = enabled
		}
	}

	func respectCursorignore() -> Bool {
		reconcileScalarPreferencesFromLegacyIfNeeded()
		return scalarPreferences.fileSystem?.respectCursorignore ?? true
	}

	func setRespectCursorignore(_ enabled: Bool, commit: Bool = true) {
		updateFileSystemScalar(commit: commit) { settings in
			settings.respectCursorignore = enabled
		}
	}

	func globalIgnoreDefaults() -> String {
		reconcileScalarPreferencesFromLegacyIfNeeded()
		if let stored = scalarPreferences.fileSystem?.globalIgnoreDefaults {
			return stored
		}
		if defaults.object(forKey: IgnoreSettingsDefaults.globalIgnoreDefaultsKey) != nil {
			return IgnoreSettingsDefaults.resolvedGlobalIgnoreDefaults(defaults: defaults)
		}
		return IgnoreSettingsDefaults.canonicalGlobalIgnoreDefaults
	}

	func setGlobalIgnoreDefaults(_ content: String, commit: Bool = true) {
		updateFileSystemScalar(commit: commit) { settings in
			settings.globalIgnoreDefaults = content
		}
	}

	func enableHierarchicalIgnores() -> Bool {
		reconcileScalarPreferencesFromLegacyIfNeeded()
		return scalarPreferences.fileSystem?.enableHierarchicalIgnores ?? true
	}

	func setEnableHierarchicalIgnores(_ enabled: Bool, commit: Bool = true) {
		updateFileSystemScalar(commit: commit) { settings in
			settings.enableHierarchicalIgnores = enabled
		}
	}

	func skipSymlinks() -> Bool {
		reconcileScalarPreferencesFromLegacyIfNeeded()
		return scalarPreferences.fileSystem?.skipSymlinks ?? true
	}

	func setSkipSymlinks(_ enabled: Bool, commit: Bool = true) {
		updateFileSystemScalar(commit: commit) { settings in
			settings.skipSymlinks = enabled
		}
	}

	func showEmptyFolders() -> Bool {
		reconcileScalarPreferencesFromLegacyIfNeeded()
		return scalarPreferences.fileSystem?.showEmptyFolders ?? false
	}

	func fileSystemSettingsSnapshot() -> FileSystemSettingsSnapshot {
		reconcileScalarPreferencesFromLegacyIfNeeded()
		let settings = scalarPreferences.fileSystem
		return FileSystemSettingsSnapshot(
			respectGitignore: settings?.respectGitignore ?? true,
			respectRepoIgnore: settings?.respectRepoIgnore ?? true,
			respectCursorignore: settings?.respectCursorignore ?? true,
			globalIgnoreDefaults: settings?.globalIgnoreDefaults ?? IgnoreSettingsDefaults.canonicalGlobalIgnoreDefaults,
			enableHierarchicalIgnores: settings?.enableHierarchicalIgnores ?? true,
			skipSymlinks: settings?.skipSymlinks ?? true,
			showEmptyFolders: settings?.showEmptyFolders ?? false
		)
	}

	func setShowEmptyFolders(_ enabled: Bool, commit: Bool = true) {
		updateFileSystemScalar(commit: commit) { settings in
			settings.showEmptyFolders = enabled
		}
	}

	func postFileSystemPreferencesDidChange(
		key: String,
		notificationCenter: NotificationCenter = .default
	) {
		notificationCenter.post(
			name: .appSettingsFileSystemPreferencesDidChange,
			object: nil,
			userInfo: ["key": key]
		)
	}

	func proEditAgentMode() -> Bool {
		reconcileScalarPreferencesFromLegacyIfNeeded()
		return scalarPreferences.agentMode?.proEditAgentMode ?? false
	}

	func setProEditAgentMode(_ enabled: Bool, commit: Bool = true) {
		updateAgentModeScalar(commit: commit) { settings in
			settings.proEditAgentMode = enabled
		}
	}

	func proEditAgentKindRaw() -> String? {
		reconcileScalarPreferencesFromLegacyIfNeeded()
		return scalarPreferences.agentMode?.proEditAgentKind
	}

	func setProEditAgentKindRaw(_ raw: String?, commit: Bool = true) {
		updateAgentModeScalar(commit: commit) { settings in
			settings.proEditAgentKind = raw
		}
	}

	func proEditAgentModelRaw() -> String? {
		reconcileScalarPreferencesFromLegacyIfNeeded()
		return scalarPreferences.agentMode?.proEditAgentModel
	}

	func setProEditAgentModelRaw(_ raw: String?, commit: Bool = true) {
		updateAgentModeScalar(commit: commit) { settings in
			settings.proEditAgentModel = raw
		}
	}

	func proEditAgentModeMigrated() -> Bool {
		reconcileScalarPreferencesFromLegacyIfNeeded()
		return scalarPreferences.agentMode?.proEditAgentModeMigrated ?? false
	}

	func setProEditAgentModeMigrated(_ migrated: Bool, commit: Bool = true) {
		updateAgentModeScalar(commit: commit) { settings in
			settings.proEditAgentModeMigrated = migrated
		}
	}

	func proEditSettings() -> ProEditSettingsSnapshot {
		ProEditSettingsSnapshot(
			agentMode: proEditAgentMode(),
			agentKindRaw: proEditAgentKindRaw(),
			agentModelRaw: proEditAgentModelRaw(),
			agentModeMigrated: proEditAgentModeMigrated()
		)
	}

	func updateProEditSettings(_ mutation: (inout ProEditSettingsSnapshot) -> Void, commit: Bool = true) {
		var snapshot = proEditSettings()
		mutation(&snapshot)
		updateAgentModeScalar(commit: commit) { settings in
			settings.proEditAgentMode = snapshot.agentMode
			settings.proEditAgentKind = snapshot.agentKindRaw
			settings.proEditAgentModel = snapshot.agentModelRaw
			settings.proEditAgentModeMigrated = snapshot.agentModeMigrated
		}
	}

	func maxBackgroundAgentComposeTabs() -> Int {
		reconcileScalarPreferencesFromLegacyIfNeeded()
		let configuredLimit = scalarPreferences.agentMode?.maxBackgroundAgentComposeTabs ?? Self.defaultBackgroundAgentComposeTabHardLimit
		let rawLimit = configuredLimit > 0 ? configuredLimit : Self.defaultBackgroundAgentComposeTabHardLimit
		return max(Self.defaultComposeTabSoftLimit, rawLimit)
	}

	func setMaxBackgroundAgentComposeTabs(_ limit: Int?, commit: Bool = true) {
		updateAgentModeScalar(commit: commit) { settings in
			settings.maxBackgroundAgentComposeTabs = limit
		}
	}

	func showBuiltInWorkflowCleanupGuidance() -> Bool {
		reconcileScalarPreferencesFromLegacyIfNeeded()
		return scalarPreferences.agentMode?.showBuiltInWorkflowCleanupGuidance ?? true
	}

	func setShowBuiltInWorkflowCleanupGuidance(_ enabled: Bool, commit: Bool = true) {
		updateAgentModeScalar(commit: commit) { settings in
			settings.showBuiltInWorkflowCleanupGuidance = enabled
		}
	}

	func codexGoalSupportEnabled() -> Bool {
		reconcileScalarPreferencesFromLegacyIfNeeded()
		return CodexGoalSupport.isEnabled(persistedValue: scalarPreferences.agentMode?.codexGoalSupportEnabled ?? false)
	}

	func setCodexGoalSupportEnabled(_ enabled: Bool, commit: Bool = true) {
		let oldValue = codexGoalSupportEnabled()
		updateAgentModeScalar(commit: commit) { settings in
			settings.codexGoalSupportEnabled = enabled
		}
		CodexGoalSupport.postDidChangeIfNeeded(previousValue: oldValue, currentValue: codexGoalSupportEnabled())
	}

	#if DEBUG
	func claudeRawEventLoggingEnabled() -> Bool {
		defaults.bool(forKey: "claudeRawEventLoggingEnabled")
	}

	func setClaudeRawEventLoggingEnabled(_ enabled: Bool) {
		defaults.set(enabled, forKey: "claudeRawEventLoggingEnabled")
	}

	func claudeRawEventLogFilePath() -> String {
		defaults.string(forKey: "claudeRawEventLogFilePath") ?? ""
	}

	func setClaudeRawEventLogFilePath(_ path: String) {
		if path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			defaults.removeObject(forKey: "claudeRawEventLogFilePath")
		} else {
			defaults.set(path, forKey: "claudeRawEventLogFilePath")
		}
	}

	func agentModePerfDiagnosticsEnabled() -> Bool {
		defaults.bool(forKey: "enableAgentModePerfDiagnostics")
	}

	func setAgentModePerfDiagnosticsEnabled(_ enabled: Bool) {
		defaults.set(enabled, forKey: "enableAgentModePerfDiagnostics")
	}

	func agentModePerfDiagnosticsOSLogEnabled() -> Bool {
		defaults.bool(forKey: "emitAgentModePerfDiagnosticsToOSLog")
	}

	func setAgentModePerfDiagnosticsOSLogEnabled(_ enabled: Bool) {
		defaults.set(enabled, forKey: "emitAgentModePerfDiagnosticsToOSLog")
	}

	func mcpFileSearchPerfDiagnosticsEnabled() -> Bool {
		defaults.bool(forKey: "enableMCPFileSearchPerfDiagnostics")
	}

	func setMCPFileSearchPerfDiagnosticsEnabled(_ enabled: Bool) {
		defaults.set(enabled, forKey: "enableMCPFileSearchPerfDiagnostics")
	}
	#endif

	func restrictMCPAgentDiscoveryToRoleLabels() -> Bool {
		reconcileScalarPreferencesFromLegacyIfNeeded()
		return scalarPreferences.agentMode?.restrictMCPAgentDiscoveryToRoleLabels ?? false
	}

	func setRestrictMCPAgentDiscoveryToRoleLabels(_ enabled: Bool, commit: Bool = true) {
		updateAgentModeScalar(commit: commit) { settings in
			settings.restrictMCPAgentDiscoveryToRoleLabels = enabled
		}
	}

	func modelDiffOverrides() -> [String: Bool] {
		reconcileScalarPreferencesFromLegacyIfNeeded()
		return scalarPreferences.modelOverrides?.diffOverrides ?? [:]
	}

	func setModelDiffOverrides(_ overrides: [String: Bool], commit: Bool = true) {
		updateModelOverridesScalar(commit: commit) { settings in
			settings.diffOverrides = overrides
		}
	}

	func modelStreamOverrides() -> [String: Bool] {
		reconcileScalarPreferencesFromLegacyIfNeeded()
		return scalarPreferences.modelOverrides?.streamOverrides ?? [:]
	}

	func setModelStreamOverrides(_ overrides: [String: Bool], commit: Bool = true) {
		updateModelOverridesScalar(commit: commit) { settings in
			settings.streamOverrides = overrides
		}
	}

	func modelTemperatureOverrides() -> [String: Double] {
		reconcileScalarPreferencesFromLegacyIfNeeded()
		return scalarPreferences.modelOverrides?.temperatureOverrides ?? [:]
	}

	func setModelTemperatureOverrides(_ overrides: [String: Double], commit: Bool = true) {
		updateModelOverridesScalar(commit: commit) { settings in
			settings.temperatureOverrides = overrides
		}
	}

	func modelResponsesOverrides() -> [String: Bool] {
		reconcileScalarPreferencesFromLegacyIfNeeded()
		return scalarPreferences.modelOverrides?.responsesOverrides ?? [:]
	}

	func setModelResponsesOverrides(_ overrides: [String: Bool], commit: Bool = true) {
		updateModelOverridesScalar(commit: commit) { settings in
			settings.responsesOverrides = overrides
		}
	}

	func updateModelOverrides(
		_ mutation: (inout GlobalScalarPreferences.ModelOverrideSettingsData) -> Void,
		commit: Bool = true
	) {
		updateModelOverridesScalar(commit: commit, mutation)
	}

	private func updateUIScalar(
		commit: Bool,
		_ mutation: (inout GlobalScalarPreferences.UISettings) -> Void
	) {
		updateScalarPreferences(commit: commit) { preferences in
			var settings = preferences.ui ?? GlobalScalarPreferences.UISettings()
			mutation(&settings)
			preferences.ui = settings
		}
	}

	private func updatePromptPackagingScalar(
		commit: Bool,
		_ mutation: (inout GlobalScalarPreferences.PromptPackagingSettings) -> Void
	) {
		updateScalarPreferences(commit: commit) { preferences in
			var settings = preferences.promptPackaging ?? GlobalScalarPreferences.PromptPackagingSettings()
			mutation(&settings)
			preferences.promptPackaging = settings
		}
	}

	private func updateModelSelectionScalar(
		commit: Bool,
		_ mutation: (inout GlobalScalarPreferences.ModelSelectionSettings) -> Void
	) {
		updateScalarPreferences(commit: commit) { preferences in
			var settings = preferences.modelSelection ?? GlobalScalarPreferences.ModelSelectionSettings()
			mutation(&settings)
			preferences.modelSelection = settings
		}
	}

	private func updateMCPScalar(
		commit: Bool,
		_ mutation: (inout GlobalScalarPreferences.MCPSettings) -> Void
	) {
		updateScalarPreferences(commit: commit) { preferences in
			var settings = preferences.mcp ?? GlobalScalarPreferences.MCPSettings()
			mutation(&settings)
			preferences.mcp = settings
		}
	}

	private func updateFileSystemScalar(
		commit: Bool,
		_ mutation: (inout GlobalScalarPreferences.FileSystemSettings) -> Void
	) {
		updateScalarPreferences(commit: commit) { preferences in
			var settings = preferences.fileSystem ?? GlobalScalarPreferences.FileSystemSettings()
			mutation(&settings)
			preferences.fileSystem = settings
		}
	}

	private func updateAgentModeScalar(
		commit: Bool,
		_ mutation: (inout GlobalScalarPreferences.AgentModeSettings) -> Void
	) {
		updateScalarPreferences(commit: commit) { preferences in
			var settings = preferences.agentMode ?? GlobalScalarPreferences.AgentModeSettings()
			mutation(&settings)
			preferences.agentMode = settings
		}
	}

	private func updateModelOverridesScalar(
		commit: Bool,
		_ mutation: (inout GlobalScalarPreferences.ModelOverrideSettingsData) -> Void
	) {
		updateScalarPreferences(commit: commit) { preferences in
			var settings = preferences.modelOverrides ?? GlobalScalarPreferences.ModelOverrideSettingsData()
			mutation(&settings)
			preferences.modelOverrides = settings
		}
	}

	private func updateScalarPreferences(commit: Bool, _ mutation: (inout GlobalScalarPreferences) -> Void) {
		reconcileScalarPreferencesFromLegacyIfNeeded()
		let before = scalarPreferences
		mutation(&scalarPreferences)
		// Notify SwiftUI observers (e.g. settings views that bind directly to the
		// typed scalar accessors) whenever a scalar preference changes. The
		// @Published `codeMapsGloballyDisabled` / copy/chat collections already
		// cover other edit paths; scalar preferences are private so we fire
		// objectWillChange manually to keep views in sync during the migration
		// window.
		if before != scalarPreferences {
			objectWillChange.send()
		}
		if commit {
			save(reconcileScalarLegacy: false)
		}
	}

	// MARK: - Global Code Maps Override

	func globalCodeMapsDisabled() -> Bool {
		codeMapsGloballyDisabled
	}

	func setCodeMapsGloballyDisabled(_ disabled: Bool, commit: Bool = true) {
		guard codeMapsGloballyDisabled != disabled || (globalDefaults.codeMapsGloballyDisabled ?? false) != disabled else {
			return
		}
		globalDefaults.codeMapsGloballyDisabled = disabled
		codeMapsGloballyDisabled = disabled
		if commit {
			save()
		}
	}
	
	// MARK: - Global Discover Agent Selection (Single Source of Truth)
	
	/// Returns the global discover agent and model selection.
	/// This is the single source of truth for discover agent/model across all workspaces.
	/// - Returns: Tuple of (agentRaw, modelRaw) where modelRaw is the model for the selected agent
	func globalDiscoverAgentSelection() -> (agentRaw: String?, modelRaw: String?) {
		let agentRaw = globalDefaults.discoverAgentRaw
		let storedModelRaw: String?
		if let agent = agentRaw {
			storedModelRaw = globalDefaults.discoverModelsByAgent?[agent]
		} else {
			storedModelRaw = nil
		}
		let normalized = AgentModelCatalog.normalizeSelection(agentRaw: agentRaw, modelRaw: storedModelRaw)
		return (normalized.agent.rawValue, normalized.modelRaw)
	}

	/// Returns the remembered raw model for a specific global discover-agent slot.
	/// This intentionally exposes only the per-agent memory entry needed by
	/// allowlisted settings surfaces; callers that need an executable selection
	/// should continue using `globalDiscoverAgentSelection()`.
	func globalDiscoverRememberedModelRaw(for agentRaw: String) -> String? {
		let trimmedAgentRaw = agentRaw.trimmingCharacters(in: .whitespacesAndNewlines)
		guard DiscoverAgentKind(rawValue: trimmedAgentRaw) != nil else { return nil }
		guard let raw = globalDefaults.discoverModelsByAgent?[trimmedAgentRaw]?.trimmingCharacters(in: .whitespacesAndNewlines),
			!raw.isEmpty
		else {
			return nil
		}
		return raw
	}
	
	/// Sets the global discover agent and model selection.
	/// This is the only way to update the global discover agent/model - workspace settings
	/// should NOT be used for this purpose.
	/// - Parameters:
	///   - agentRaw: The agent rawValue (e.g., "claudeCode", "codexExec", "gemini")
	///   - modelRaw: The model rawValue for the selected agent
	///   - markUserDefined: If true, marks this as a user-defined selection (prevents auto-apply override)
	func setGlobalDiscoverAgentSelection(
		agentRaw: String,
		modelRaw: String,
		markUserDefined: Bool = true,
		reason: String? = nil,
		fileID: StaticString = #fileID,
		line: UInt = #line,
		function: StaticString = #function
	) {
		let oldSelection = globalDiscoverAgentSelection()
		let normalized = AgentModelCatalog.normalizeSelection(agentRaw: agentRaw, modelRaw: modelRaw)
		globalDefaults.discoverAgentRaw = normalized.agent.rawValue
		if globalDefaults.discoverModelsByAgent == nil {
			globalDefaults.discoverModelsByAgent = [:]
		}
		globalDefaults.discoverModelsByAgent?[normalized.agent.rawValue] = normalized.modelRaw
		if markUserDefined {
			globalDefaults.didUserSetDiscoverAgentDefaults = true
		}
		recordSettingsWriteDiagnostic(
			key: "globalDiscoverAgentSelection",
			oldValue: oldSelection.agentRaw.flatMap { oldAgentRaw in
				oldSelection.modelRaw.map { "\(oldAgentRaw):\($0)" } ?? oldAgentRaw
			},
			newValue: "\(normalized.agent.rawValue):\(normalized.modelRaw)",
			commit: true,
			markUserDefined: markUserDefined,
			reason: reason,
			fileID: fileID,
			line: line,
			function: function
		)
		save()
	}

	/// Sets the global discover agent and optionally updates/clears that agent's
	/// remembered model slot. Passing `nil` or an empty string clears the current
	/// remembered model entry for the selected agent; `globalDiscoverAgentSelection()`
	/// will still synthesize a runtime default when a concrete model is required.
	func setGlobalDiscoverAgentSelection(
		agentRaw: String,
		modelRaw: String?,
		markUserDefined: Bool = true,
		reason: String? = nil,
		fileID: StaticString = #fileID,
		line: UInt = #line,
		function: StaticString = #function
	) {
		let oldSelection = globalDiscoverAgentSelection()
		let trimmedAgentRaw = agentRaw.trimmingCharacters(in: .whitespacesAndNewlines)
		let agent = DiscoverAgentKind(rawValue: trimmedAgentRaw)
			?? AgentModelCatalog.normalizeSelection(agentRaw: trimmedAgentRaw, modelRaw: modelRaw).agent
		globalDefaults.discoverAgentRaw = agent.rawValue

		let trimmedModelRaw = modelRaw?.trimmingCharacters(in: .whitespacesAndNewlines)
		let newModelRaw: String?
		if let trimmedModelRaw, !trimmedModelRaw.isEmpty {
			let normalized = AgentModelCatalog.normalizeSelection(
				agentRaw: agent.rawValue,
				modelRaw: trimmedModelRaw
			)
			if globalDefaults.discoverModelsByAgent == nil {
				globalDefaults.discoverModelsByAgent = [:]
			}
			globalDefaults.discoverModelsByAgent?[normalized.agent.rawValue] = normalized.modelRaw
			newModelRaw = normalized.modelRaw
		} else {
			globalDefaults.discoverModelsByAgent?[agent.rawValue] = nil
			newModelRaw = nil
		}

		if markUserDefined {
			globalDefaults.didUserSetDiscoverAgentDefaults = true
		}
		recordSettingsWriteDiagnostic(
			key: "globalDiscoverAgentSelection",
			oldValue: oldSelection.agentRaw.flatMap { oldAgentRaw in
				oldSelection.modelRaw.map { "\(oldAgentRaw):\($0)" } ?? oldAgentRaw
			},
			newValue: newModelRaw.map { "\(agent.rawValue):\($0)" } ?? agent.rawValue,
			commit: true,
			markUserDefined: markUserDefined,
			reason: reason,
			fileID: fileID,
			line: line,
			function: function
		)
		save()
	}
	
	/// Returns whether the user has explicitly set the global discover agent defaults.
	/// Used by recommendation engine to determine if auto-apply should be allowed.
	/// NOTE: For existing installs, `didUserSetDiscoverAgentDefaults` will be nil but
	/// they may already have a configured selection. We treat nil + existing selection
	/// as "user-defined" to avoid overwriting their settings via auto-apply.
	var hasUserSetGlobalDiscoverDefaults: Bool {
		// Explicit true = definitely user-set
		if globalDefaults.didUserSetDiscoverAgentDefaults == true {
			return true
		}
		// nil (legacy) + existing selection = treat as user-set to be safe
		if globalDefaults.didUserSetDiscoverAgentDefaults == nil,
		globalDefaults.discoverAgentRaw != nil {
			return true
		}
		// false (seeded/new) or nil + no selection = not user-set
		return false
	}
	
	/// Migrate legacy tab-scoped discover settings to global defaults (one-time migration).
	/// Called during workspace load when legacy tab settings are detected.
	/// - Parameters:
	///   - agentRaw: Legacy agent rawValue from tab config
	///   - modelRaw: Legacy model rawValue from tab config
	/// - Returns: True if migration occurred (global was not already set)
	@discardableResult
	func migrateLegacyDiscoverSettingsToGlobal(agentRaw: String, modelRaw: String?) -> Bool {
		// Only migrate if global is not already configured
		guard globalDefaults.discoverAgentRaw == nil else { return false }
		
		globalDefaults.discoverAgentRaw = agentRaw
		if let model = modelRaw {
			if globalDefaults.discoverModelsByAgent == nil {
				globalDefaults.discoverModelsByAgent = [:]
			}
			globalDefaults.discoverModelsByAgent?[agentRaw] = model
		}
		// Mark as migrated but not user-defined (allows recommendations to still apply)
		globalDefaults.didUserSetDiscoverAgentDefaults = false
		save()
		return true
	}

	// MARK: - Helper Methods

	/// Update global discover defaults to seed new workspaces.
	/// @available(*, deprecated, message: "Use setGlobalDiscoverAgentSelection instead")
	/// Kept for backwards compatibility but should not be called directly.
	func updateGlobalDiscoverDefaults(agentRaw: String?, modelRaw: String?) {
		// Redirect to the new API if we have valid values
		if let agent = agentRaw, let model = modelRaw {
			setGlobalDiscoverAgentSelection(agentRaw: agent, modelRaw: model, markUserDefined: true)
		} else if let agent = agentRaw {
			globalDefaults.discoverAgentRaw = agent
			save()
		}
	}

	// MARK: - Global MCP Agent Role Defaults (Single Source of Truth)

	/// Returns global MCP Agent Mode role-default overrides.
	/// nil means all roles use the recommended defaults.
	func globalMCPAgentRoleOverrides() -> [String: String]? {
		normalizedRoleOverrides(globalDefaults.mcpAgentRoleOverrides)
	}

	/// Updates global MCP Agent Mode role-default overrides.
	/// Empty dictionaries are normalized to nil.
	func updateGlobalMCPAgentRoleOverrides(_ overrides: [String: String]?, commit: Bool = true) {
		globalDefaults.mcpAgentRoleOverrides = Self.normalizedMCPAgentRoleOverrides(overrides)
		if commit {
			save()
		}
	}

	// MARK: - Recommendation Provider Filter (Global)

	/// Returns the global provider filter for recommendation generation. Absence means all providers.
	func globalRecommendationProviderFilter() -> Set<RecommendationProviderKind> {
		Self.normalizedRecommendationProviderFilter(raw: globalDefaults.recommendationProviderFilterRaw)
	}

	/// Normalizes persisted provider filters across recommendation-provider list changes.
	///
	/// Older builds could persist the previous "all providers" set, which included Anthropic API
	/// and did not include Cursor CLI. Treat that legacy all-providers shape as the current all
	/// providers so newly supported providers are not silently hidden from recommendations/UI.
	static func normalizedRecommendationProviderFilter(raw stored: [String]?) -> Set<RecommendationProviderKind> {
		guard let stored else {
			return Set(RecommendationProviderKind.allCases)
		}
		let storedSet = Set(stored)
		let legacyAllProviders: Set<String> = [
			RecommendationProviderKind.claudeCode.rawValue,
			RecommendationProviderKind.codex.rawValue,
			RecommendationProviderKind.openAI.rawValue,
			"anthropic",
			RecommendationProviderKind.geminiCLI.rawValue,
		]
		if storedSet.isSuperset(of: legacyAllProviders) {
			return Set(RecommendationProviderKind.allCases)
		}
		return Set(stored.compactMap(RecommendationProviderKind.init(rawValue:)))
	}

	/// Updates the global provider filter. Passing all providers clears the override.
	func setGlobalRecommendationProviderFilter(_ providers: Set<RecommendationProviderKind>, commit: Bool = true) {
		if providers == Set(RecommendationProviderKind.allCases) {
			globalDefaults.recommendationProviderFilterRaw = nil
		} else {
			globalDefaults.recommendationProviderFilterRaw = RecommendationProviderKind.allCases
				.filter { providers.contains($0) }
				.map(\.rawValue)
		}
		if commit {
			save()
		}
	}

	/// Pure migration helper used by production migration and tests.
	static func migratedGlobalMCPAgentRoleOverrides(
		existingGlobal: [String: String]?,
		migrationVersion: Int?,
		legacyChatSettings: [UUID: ChatGlobalSettings],
		currentVersion: Int = 1
	) -> (overrides: [String: String]?, migrationVersion: Int) {
		if let migrationVersion, migrationVersion >= currentVersion {
			return (normalizedMCPAgentRoleOverrides(existingGlobal), migrationVersion)
		}
		if let normalizedGlobal = normalizedMCPAgentRoleOverrides(existingGlobal) {
			return (normalizedGlobal, currentVersion)
		}

		var migrated: [String: String] = [:]
		for role in AgentModelCatalog.TaskLabelKind.allCases {
			var counts: [String: Int] = [:]
			for settings in legacyChatSettings.values {
				guard let value = settings.mcpAgentRoleOverrides?[role.rawValue]?
					.trimmingCharacters(in: .whitespacesAndNewlines),
					!value.isEmpty
				else {
					continue
				}
				counts[value, default: 0] += 1
			}
			guard !counts.isEmpty else { continue }
			let selected = counts.sorted { lhs, rhs in
				if lhs.value != rhs.value { return lhs.value > rhs.value }
				return lhs.key < rhs.key
			}.first?.key
			if let selected {
				migrated[role.rawValue] = selected
			}
		}
		return (normalizedMCPAgentRoleOverrides(migrated), currentVersion)
	}

	private func migrateLegacyMCPAgentRoleOverridesToGlobalIfNeeded(currentVersion: Int) {
		let migrated = Self.migratedGlobalMCPAgentRoleOverrides(
			existingGlobal: globalDefaults.mcpAgentRoleOverrides,
			migrationVersion: globalDefaults.mcpAgentRoleOverridesMigrationVersion,
			legacyChatSettings: chatSettings,
			currentVersion: currentVersion
		)
		guard globalDefaults.mcpAgentRoleOverridesMigrationVersion != migrated.migrationVersion ||
				normalizedRoleOverrides(globalDefaults.mcpAgentRoleOverrides) != migrated.overrides
		else {
			return
		}
		globalDefaults.mcpAgentRoleOverrides = migrated.overrides
		globalDefaults.mcpAgentRoleOverridesMigrationVersion = migrated.migrationVersion
		save()
	}

	private func normalizedRoleOverrides(_ overrides: [String: String]?) -> [String: String]? {
		Self.normalizedMCPAgentRoleOverrides(overrides)
	}

	private static func normalizedMCPAgentRoleOverrides(_ overrides: [String: String]?) -> [String: String]? {
		guard let overrides else { return nil }
		let normalized = overrides.reduce(into: [String: String]()) { result, entry in
			let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
			let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !key.isEmpty, !value.isEmpty else { return }
			result[key] = value
		}
		return normalized.isEmpty ? nil : normalized
	}

	/// Check if recommendation schema version is current; if not, clear mutes across all workspaces.
	/// Returns true if schema was updated (mutes cleared).
	@discardableResult
	func ensureLatestRecommendationSchema(currentVersion: Int) -> Bool {
		if globalDefaults.recommendationSchemaVersion != currentVersion {
			// Clear all mutedRecommendationIDs and completion timestamps across workspaces
			for (id, var s) in chatSettings {
				s.mutedRecommendationIDs = nil
				s.lastRecommendationWizardCompletedAt = nil
				chatSettings[id] = s
			}
			globalDefaults.recommendationSchemaVersion = currentVersion
			save()
			return true
		}
		return false
	}

	/// Check if token budget schema version is current; if not, reset to defaults across all workspaces.
	/// Returns true if schema was updated (budgets reset).
	@discardableResult
	func ensureLatestTokenBudgetSchema(currentVersion: Int) -> Bool {
		if globalDefaults.tokenBudgetSchemaVersion != currentVersion {
			// Clear discoveryTokenBudget across all workspaces so they pick up the new default
			for (id, var s) in chatSettings {
				s.discoveryTokenBudget = nil
				chatSettings[id] = s
			}
			globalDefaults.discoveryTokenBudget = nil
			globalDefaults.tokenBudgetSchemaVersion = currentVersion
			save()
			return true
		}
		return false
	}
	
	/// Seed new workspace chat settings with defaults.
	/// Called when creating brand new ChatGlobalSettings for a workspace.
	/// NOTE: Discover agent/model are now GLOBAL (not per-workspace), so we don't seed those here.
	/// The workspace lastUsedDiscover* fields are legacy and kept only for backwards compatibility.
	private func seedChatSettingsDefaults(_ settings: inout ChatGlobalSettings) {
		// Legacy: seed workspace discover settings from global for backwards compatibility
		// These are no longer the source of truth - global settings are.
		if settings.lastUsedDiscoverAgentRaw == nil {
			settings.lastUsedDiscoverAgentRaw = globalDefaults.discoverAgentRaw ?? "claudeCode"
		}
		if settings.lastUsedDiscoverModelsByAgent == nil {
			settings.lastUsedDiscoverModelsByAgent = globalDefaults.discoverModelsByAgent ?? [:]
		}

		// Mark as seeded (not user-defined) for recommendation auto-apply.
		// This is explicitly false (not nil) to indicate this is a new workspace.
		settings.didUserSetDiscoverAgentDefaults = false
		settings.didAutoApplyRecommendationsAt = nil
	}

	// MARK: - Persistence

	private func load() {
		let document = fileStore.loadOrMigrate(defaults: defaults)
		copySettings = document.copySettings
		chatSettings = document.chatSettings
		globalDefaults = document.globalDefaults
		scalarPreferences = document.scalarPreferences ?? GlobalSettingsLegacyBridge.scalarPreferences(from: defaults)
		codeMapsGloballyDisabled = globalDefaults.codeMapsGloballyDisabled ?? false
		lastRuntimeImportedScalarMirrorHash = nil
	}

	@discardableResult
	func reloadFromDiskUpdatingLegacyMirrors() -> Bool {
		do {
			let document = try fileStore.load()
			objectWillChange.send()
			copySettings = document.copySettings
			chatSettings = document.chatSettings
			globalDefaults = document.globalDefaults
			scalarPreferences = document.scalarPreferences ?? GlobalScalarPreferences()
			codeMapsGloballyDisabled = globalDefaults.codeMapsGloballyDisabled ?? false
			GlobalSettingsLegacyBridge.writeLegacyMirrors(
				copySettings: copySettings,
				chatSettings: chatSettings,
				globalDefaults: globalDefaults,
				scalarPreferences: scalarPreferences,
				defaults: defaults,
				updateShadow: true
			)
			lastRuntimeImportedScalarMirrorHash = nil
			return true
		} catch {
			print("⚠️ Failed to reload global settings JSON at \(fileStore.fileURL.path): \(error)")
			return false
		}
	}

	private func ensureFileSystemGlobalIgnoreDefaultsSeeded() {
		var fileSystemSettings = scalarPreferences.fileSystem ?? GlobalScalarPreferences.FileSystemSettings()
		guard fileSystemSettings.globalIgnoreDefaults == nil else { return }
		// Seed once during store initialization so later FileSystemService ignore-rule
		// loading cannot create a UserDefaults value that dirties the scalar shadow
		// hash and forces repeated legacy reimports during workspace open.
		fileSystemSettings.globalIgnoreDefaults = IgnoreSettingsDefaults.resolvedGlobalIgnoreDefaults(defaults: defaults)
		scalarPreferences.fileSystem = fileSystemSettings
		save(reconcileScalarLegacy: false)
	}

	private func resolvedSyncChatModelWithOracleFromCurrentPreferences() -> Bool {
		if let stored = scalarPreferences.modelSelection?.syncChatModelWithOracle {
			return stored
		}
		let planning = scalarPreferences.modelSelection?.planningModel ?? ""
		let compose = scalarPreferences.modelSelection?.preferredComposeModel ?? ""
		return !planning.isEmpty && planning == compose
	}

	private func syncSiblingReason(from reason: String?) -> String? {
		let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
		guard let trimmed, !trimmed.isEmpty else { return nil }
		return "\(trimmed).sync_sibling"
	}

	private func syncSnapReason(from reason: String?) -> String? {
		let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
		guard let trimmed, !trimmed.isEmpty else { return nil }
		return "\(trimmed).snap_to_planning"
	}

	private func diagnosticKey(for eventKey: GlobalSettingsLegacyBridge.ModelSelectionImportEvent.Key) -> String {
		switch eventKey {
		case .preferredComposeModel:
			return "preferredComposeModelRaw"
		case .planningModel:
			return "planningModelRaw"
		case .syncChatModelWithOracle:
			return "syncChatModelWithOracle"
		}
	}

	private func recordLegacyScalarImportDiagnostics(
		_ events: [GlobalSettingsLegacyBridge.ModelSelectionImportEvent],
		fileID: StaticString = #fileID,
		line: UInt = #line,
		function: StaticString = #function
	) {
		for event in events {
			let reason: String
			let oldValue: String?
			switch event.action {
			case .protectedExistingJSON:
				reason = "legacy_scalar_reimport.runtime.protected"
				oldValue = event.legacyValue
			case .applied:
				reason = "legacy_scalar_reimport.runtime.applied"
				oldValue = event.existingValue
			}
			recordSettingsWriteDiagnostic(
				key: diagnosticKey(for: event.key),
				oldValue: oldValue,
				newValue: event.resultValue,
				commit: false,
				reason: reason,
				fileID: fileID,
				line: line,
				function: function
			)
		}
	}

	private func preservingJSONOnlyScalarFields(
		in imported: GlobalScalarPreferences,
		from current: GlobalScalarPreferences
	) -> GlobalScalarPreferences {
		var imported = imported
		if let codexGoalSupportEnabled = current.agentMode?.codexGoalSupportEnabled {
			var agentMode = imported.agentMode ?? GlobalScalarPreferences.AgentModeSettings()
			agentMode.codexGoalSupportEnabled = codexGoalSupportEnabled
			imported.agentMode = agentMode
		}
		return imported
	}

	@discardableResult
	private func reconcileScalarPreferencesFromLegacyIfNeeded() -> Bool {
		let hasAnyScalarPreference = GlobalSettingsLegacyBridge.hasAnyScalarPreference(defaults: defaults)
		let scalarShadowHash = defaults.string(forKey: GlobalSettingsLegacyBridge.scalarShadowHashKey)
		guard hasAnyScalarPreference || scalarShadowHash != nil else {
			lastRuntimeImportedScalarMirrorHash = nil
			return false
		}

		let currentMirrorHash = GlobalSettingsLegacyBridge.scalarMirrorFingerprint(defaults: defaults)
		if scalarShadowHash == currentMirrorHash {
			if lastRuntimeImportedScalarMirrorHash != nil {
				let importResult = GlobalSettingsLegacyBridge.scalarPreferences(
					from: defaults,
					preservingModelSelectionFrom: scalarPreferences
				)
				scalarPreferences = preservingJSONOnlyScalarFields(in: importResult.preferences, from: scalarPreferences)
				recordLegacyScalarImportDiagnostics(importResult.modelSelectionEvents)
			}
			lastRuntimeImportedScalarMirrorHash = nil
			return false
		}
		guard lastRuntimeImportedScalarMirrorHash != currentMirrorHash else {
			return false
		}

		let importResult = GlobalSettingsLegacyBridge.scalarPreferences(
			from: defaults,
			preservingModelSelectionFrom: scalarPreferences
		)
		scalarPreferences = preservingJSONOnlyScalarFields(in: importResult.preferences, from: scalarPreferences)
		recordLegacyScalarImportDiagnostics(importResult.modelSelectionEvents)
		lastRuntimeImportedScalarMirrorHash = currentMirrorHash
		return true
	}

	private func save(reconcileScalarLegacy: Bool = true) {
		if reconcileScalarLegacy {
			reconcileScalarPreferencesFromLegacyIfNeeded()
		}

		let document = GlobalSettingsDocument(
			copySettings: copySettings,
			chatSettings: chatSettings,
			globalDefaults: globalDefaults,
			scalarPreferences: scalarPreferences
		)

		let didSaveJSON: Bool
		do {
			try fileStore.save(document)
			didSaveJSON = true
		} catch {
			didSaveJSON = false
			print("⚠️ Failed to save global settings JSON at \(fileStore.fileURL.path): \(error)")
		}

		GlobalSettingsLegacyBridge.writeLegacyMirrors(
			copySettings: copySettings,
			chatSettings: chatSettings,
			globalDefaults: globalDefaults,
			scalarPreferences: scalarPreferences,
			defaults: defaults,
			updateShadow: didSaveJSON
		)
		if didSaveJSON {
			lastRuntimeImportedScalarMirrorHash = nil
		}
	}
}
