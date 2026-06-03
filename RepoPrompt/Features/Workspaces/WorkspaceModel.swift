import Foundation
import OSLog

struct WorkspaceRootSetKey: Hashable, Sendable {
	let normalizedPaths: [String]

	var isEmpty: Bool { normalizedPaths.isEmpty }

	init(paths: [String]) {
		var canonicalByLowercasedPath: [String: String] = [:]
		for rawPath in paths {
			let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !trimmed.isEmpty else { continue }
			let expanded = (trimmed as NSString).expandingTildeInPath
			let normalizedPath = URL(fileURLWithPath: expanded).standardizedFileURL.path
			guard !normalizedPath.isEmpty else { continue }
			let lowercasedPath = normalizedPath.lowercased()
			if let existing = canonicalByLowercasedPath[lowercasedPath] {
				canonicalByLowercasedPath[lowercasedPath] = min(existing, normalizedPath)
			} else {
				canonicalByLowercasedPath[lowercasedPath] = normalizedPath
			}
		}
		normalizedPaths = canonicalByLowercasedPath.values.sorted {
			let lhsKey = $0.lowercased()
			let rhsKey = $1.lowercased()
			if lhsKey != rhsKey {
				return lhsKey < rhsKey
			}
			return $0 < $1
		}
	}

	static func == (lhs: WorkspaceRootSetKey, rhs: WorkspaceRootSetKey) -> Bool {
		lhs.normalizedPaths.map { $0.lowercased() } == rhs.normalizedPaths.map { $0.lowercased() }
	}

	func hash(into hasher: inout Hasher) {
		for path in normalizedPaths {
			hasher.combine(path.lowercased())
		}
	}
}

struct WorkspaceDuplicateGroupSummary: Identifiable, Equatable, Sendable {
	let id: String
	let normalizedRepoPaths: [String]
	let canonicalWorkspaceID: UUID
	let canonicalWorkspaceName: String
	let duplicateWorkspaceIDs: [UUID]
	let duplicateWorkspaceNames: [String]
	let windowIDsByWorkspaceID: [UUID: [Int]]
}

struct WorkspaceDuplicateCleanupSkippedItem: Equatable, Sendable {
	let workspaceID: UUID
	let workspaceName: String
	let windowID: Int?
	let reason: String
}

struct WorkspaceDuplicateCleanupResult: Equatable, Sendable {
	let groupsDetected: Int
	let groupsConsolidated: Int
	let reassignedWindowIDs: [Int]
	let deletedWorkspaceIDs: [UUID]
	let skipped: [WorkspaceDuplicateCleanupSkippedItem]
	let backupURL: URL?
}

struct WorkspaceDuplicateCleanupBackup: Codable {
	struct BackupGroup: Codable {
		let canonicalBeforeMerge: WorkspaceModel
		let duplicatesBeforeDelete: [WorkspaceModel]
	}

	let createdAt: Date
	let groups: [BackupGroup]
}

/// Legacy Context Builder state kept only so old workspace files can decode.
struct ContextBuilderState: Codable, Equatable, Sendable {
	var recommendedHighPaths: [String] = []
	var recommendedMediumPaths: [String] = []
	var recommendedLowPaths: [String] = []
	var recommendationsTitle: String = ""
	
	// UI state settings
	var includeFileTree: Bool = true
	var includeCodeMap: Bool = true
	var maxTokensPerQuery: Int = 16
	var disableSizeLimits: Bool = true
	var enableFinalRefinement: Bool = true
	var includeHighPriority: Bool = true
	var includeMediumPriority: Bool = true
	var includeLowPriority: Bool = true
	var useOverridePrompt: Bool = false
	var overridePromptText: String = ""
	
	/// When true, limit file-tree & code-map to the current selection
	var useOnlySelectedFiles: Bool = false
	
	/// NEW: number of partitions to use when Parallel mode is enabled
	var parallelPartitions: Int = 4
	
	// ------------------------------------------------------------------------------------
	// MARK: - Full param-based init
	// ------------------------------------------------------------------------------------
	init(
		recommendedHighPaths: [String] = [],
		recommendedMediumPaths: [String] = [],
		recommendedLowPaths: [String] = [],
		recommendationsTitle: String = "",
		includeFileTree: Bool = true,
		includeCodeMap: Bool = true,
		maxTokensPerQuery: Int = 16,
		disableSizeLimits: Bool = true,
		enableFinalRefinement: Bool = true,
		includeHighPriority: Bool = true,
		includeMediumPriority: Bool = true,
		includeLowPriority: Bool = true,
		useOverridePrompt: Bool = false,
		overridePromptText: String = "",
		useOnlySelectedFiles: Bool = false,
		parallelPartitions: Int = 4
	) {
		self.recommendedHighPaths = recommendedHighPaths
		self.recommendedMediumPaths = recommendedMediumPaths
		self.recommendedLowPaths = recommendedLowPaths
		self.recommendationsTitle = recommendationsTitle
		self.includeFileTree = includeFileTree
		self.includeCodeMap = includeCodeMap
		self.maxTokensPerQuery = maxTokensPerQuery
		self.disableSizeLimits = disableSizeLimits
		self.enableFinalRefinement = enableFinalRefinement
		self.includeHighPriority = includeHighPriority
		self.includeMediumPriority = includeMediumPriority
		self.includeLowPriority = includeLowPriority
		self.useOverridePrompt = useOverridePrompt
		self.overridePromptText = overridePromptText
		self.useOnlySelectedFiles = useOnlySelectedFiles
		self.parallelPartitions = parallelPartitions
	}
	
	// ------------------------------------------------------------------------------------
	// MARK: - No-arg init
	// ------------------------------------------------------------------------------------
	init() {}
	
	// ------------------------------------------------------------------------------------
	// MARK: - Decodable partial init
	// ------------------------------------------------------------------------------------
	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		self.recommendedHighPaths   = try c.decodeIfPresent([String].self, forKey: .recommendedHighPaths)   ?? []
		self.recommendedMediumPaths = try c.decodeIfPresent([String].self, forKey: .recommendedMediumPaths) ?? []
		self.recommendedLowPaths    = try c.decodeIfPresent([String].self, forKey: .recommendedLowPaths)    ?? []
		self.recommendationsTitle   = try c.decodeIfPresent(String.self, forKey: .recommendationsTitle)     ?? ""
		self.includeFileTree        = try c.decodeIfPresent(Bool.self,   forKey: .includeFileTree)          ?? true
		self.includeCodeMap         = try c.decodeIfPresent(Bool.self,   forKey: .includeCodeMap)           ?? true
		self.maxTokensPerQuery      = try c.decodeIfPresent(Int.self,    forKey: .maxTokensPerQuery)        ?? 16
		self.disableSizeLimits      = try c.decodeIfPresent(Bool.self,   forKey: .disableSizeLimits)        ?? false
		self.enableFinalRefinement  = try c.decodeIfPresent(Bool.self,   forKey: .enableFinalRefinement)    ?? true
		self.includeHighPriority    = try c.decodeIfPresent(Bool.self,   forKey: .includeHighPriority)      ?? true
		self.includeMediumPriority  = try c.decodeIfPresent(Bool.self,   forKey: .includeMediumPriority)    ?? true
		self.includeLowPriority     = try c.decodeIfPresent(Bool.self,   forKey: .includeLowPriority)       ?? true
		self.useOverridePrompt      = try c.decodeIfPresent(Bool.self,   forKey: .useOverridePrompt)        ?? false
		self.overridePromptText     = try c.decodeIfPresent(String.self, forKey: .overridePromptText)       ?? ""
		self.useOnlySelectedFiles = try c.decodeIfPresent(Bool.self, forKey: .useOnlySelectedFiles) ?? false
		self.parallelPartitions = try c.decodeIfPresent(Int.self, forKey: .parallelPartitions) ?? 4
	}
	
	// ------------------------------------------------------------------------------------
	// MARK: - Equatable
	// ------------------------------------------------------------------------------------
	static func == (lhs: ContextBuilderState, rhs: ContextBuilderState) -> Bool {
		return lhs.recommendedHighPaths == rhs.recommendedHighPaths &&
		lhs.recommendedMediumPaths == rhs.recommendedMediumPaths &&
		lhs.recommendedLowPaths == rhs.recommendedLowPaths &&
		lhs.recommendationsTitle == rhs.recommendationsTitle &&
		lhs.includeFileTree == rhs.includeFileTree &&
		lhs.includeCodeMap == rhs.includeCodeMap &&
		lhs.maxTokensPerQuery == rhs.maxTokensPerQuery &&
		lhs.disableSizeLimits == rhs.disableSizeLimits &&
		lhs.enableFinalRefinement == rhs.enableFinalRefinement &&
		lhs.includeHighPriority == rhs.includeHighPriority &&
		lhs.includeMediumPriority == rhs.includeMediumPriority &&
		lhs.includeLowPriority == rhs.includeLowPriority &&
		lhs.useOverridePrompt == rhs.useOverridePrompt &&
		lhs.overridePromptText == rhs.overridePromptText &&
		lhs.useOnlySelectedFiles == rhs.useOnlySelectedFiles &&
		lhs.parallelPartitions == rhs.parallelPartitions
	}
	
	// ------------------------------------------------------------------------------------
	// MARK: - CodingKeys
	// ------------------------------------------------------------------------------------
	enum CodingKeys: String, CodingKey {
		case recommendedHighPaths
		case recommendedMediumPaths
		case recommendedLowPaths
		case recommendationsTitle
		case includeFileTree
		case includeCodeMap
		case maxTokensPerQuery
		case disableSizeLimits
		case enableFinalRefinement
		case includeHighPriority
		case includeMediumPriority
		case includeLowPriority
		case useOverridePrompt
		case overridePromptText
		case useOnlySelectedFiles
		case parallelPartitions
	}
}

/// A single preset capturing which files/folders/prompts are included.
struct WorkspacePreset: Codable, Identifiable, Equatable, Sendable {
	let id: UUID
	var name: String
	
	var capturesFileSelection: Bool
	var capturesFileTreeExpansion: Bool
	var capturesSelectedPrompts: Bool
	
	var selectedFilePaths: [String]
	var expandedFolders: [String]
	var selectedPromptIDs: [UUID]
	
	var lastUpdated: Date
	
	/// Default init used by code
	init(
		id: UUID = UUID(),
		name: String,
		capturesFileSelection: Bool = true,
		capturesFileTreeExpansion: Bool = true,
		capturesSelectedPrompts: Bool = true,
		selectedFilePaths: [String] = [],
		expandedFolders: [String] = [],
		selectedPromptIDs: [UUID] = [],
		lastUpdated: Date = Date()
	) {
		self.id = id
		self.name = name
		self.capturesFileSelection = capturesFileSelection
		self.capturesFileTreeExpansion = capturesFileTreeExpansion
		self.capturesSelectedPrompts = capturesSelectedPrompts
		self.selectedFilePaths = selectedFilePaths
		self.expandedFolders = expandedFolders
		self.selectedPromptIDs = selectedPromptIDs
		self.lastUpdated = lastUpdated
	}
	
	/// Partial decoding approach to skip errors for mismatch or missing fields.
	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		self.id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
		self.name = (try? c.decode(String.self, forKey: .name)) ?? "Unnamed Preset"
		self.capturesFileSelection = (try? c.decode(Bool.self, forKey: .capturesFileSelection)) ?? true
		self.capturesFileTreeExpansion = (try? c.decode(Bool.self, forKey: .capturesFileTreeExpansion)) ?? true
		self.capturesSelectedPrompts = (try? c.decode(Bool.self, forKey: .capturesSelectedPrompts)) ?? true
		self.selectedFilePaths = (try? c.decode([String].self, forKey: .selectedFilePaths)) ?? []
		self.expandedFolders = (try? c.decode([String].self, forKey: .expandedFolders)) ?? []
		self.selectedPromptIDs = (try? c.decode([UUID].self, forKey: .selectedPromptIDs)) ?? []
		self.lastUpdated = (try? c.decode(Date.self, forKey: .lastUpdated)) ?? Date()
	}
	
	static func == (lhs: WorkspacePreset, rhs: WorkspacePreset) -> Bool {
		lhs.id == rhs.id &&
		lhs.name == rhs.name &&
		lhs.capturesFileSelection == rhs.capturesFileSelection &&
		lhs.capturesFileTreeExpansion == rhs.capturesFileTreeExpansion &&
		lhs.capturesSelectedPrompts == rhs.capturesSelectedPrompts &&
		lhs.selectedFilePaths == rhs.selectedFilePaths &&
		lhs.expandedFolders == rhs.expandedFolders &&
		lhs.selectedPromptIDs == rhs.selectedPromptIDs &&
		lhs.lastUpdated == rhs.lastUpdated
	}

	
	enum CodingKeys: String, CodingKey {
		case id
		case name
		case capturesFileSelection
		case capturesFileTreeExpansion
		case capturesSelectedPrompts
		case selectedFilePaths
		case expandedFolders
		case selectedPromptIDs
		case lastUpdated
	}
}

struct StoredSelection: Codable, Equatable, Sendable {
	let selectedPaths: [String]
	let autoCodemapPaths: [String]
	let slices: [String: [LineRange]]
	let codemapAutoEnabled: Bool

	init(
		selectedPaths: [String] = [],
		autoCodemapPaths: [String] = [],
		slices: [String: [LineRange]] = [:],
		codemapAutoEnabled: Bool = true
	) {
		self.selectedPaths = selectedPaths
		self.autoCodemapPaths = autoCodemapPaths
		self.slices = slices
		self.codemapAutoEnabled = codemapAutoEnabled
	}
}

/// Legacy per-tab overrides for Context Builder kept only so old workspace files can decode.
struct ContextBuilderOverrides: Codable, Equatable, Sendable {
	var useOverridePrompt: Bool
	var overridePromptText: String
	
	init(useOverridePrompt: Bool = false, overridePromptText: String = "") {
		self.useOverridePrompt = useOverridePrompt
		self.overridePromptText = overridePromptText
	}
}

/// Decode-only carrier for legacy Context Builder override text. This is never encoded.
private struct LegacyContextBuilderOverrideMigration: Equatable, Sendable {
	var useOverridePrompt: Bool
	var overridePromptText: String
}

struct DiscoverTabConfig: Codable, Equatable, Sendable {
	var instructions: String = ""
	
	// MARK: - Legacy Fields (decode-only, never encoded)
	// These fields are kept for backwards compatibility when loading old workspaces.
	// Agent/model selection is now GLOBAL (stored in GlobalSettingsStore.globalDefaults).
	// @available(*, deprecated, message: "Use GlobalSettingsStore.globalDiscoverAgentSelection() instead")
	var agentRaw: String? = nil
	// @available(*, deprecated, message: "Use GlobalSettingsStore.globalDiscoverAgentSelection() instead")
	var modelRaw: String? = nil
	// @available(*, deprecated, message: "Use workspace-scoped settings instead")
	var tokenBudget: Int? = nil
	// @available(*, deprecated, message: "Use workspace-scoped settings instead")
	var enhancementModeRaw: String? = nil
	
	// MARK: - Active Fields
	/// Auto-generate plan after discovery completes (nil = use workspace default)
	var autoGeneratePlan: Bool? = nil
	/// Selected follow-up type for auto-generate (plan/review/question) - defaults to "plan"
	var followUpTypeRaw: String? = nil
	/// Selected context builder prompt IDs for this tab
	var selectedContextBuilderPromptIDs: [UUID] = []

	// Decoding keys include legacy fields for backwards compatibility
	private enum CodingKeys: String, CodingKey {
		case instructions
		case agentRaw
		case modelRaw
		case tokenBudget
		case enhancementModeRaw
		case autoGeneratePlan
		case followUpTypeRaw
		case selectedContextBuilderPromptIDs
	}
	
	// Encoding keys EXCLUDE legacy agent/model fields - they are never written
	private enum EncodingKeys: String, CodingKey {
		case instructions
		case autoGeneratePlan
		case followUpTypeRaw
		case selectedContextBuilderPromptIDs
	}

	init(
		instructions: String = "",
		agentRaw: String? = nil,
		modelRaw: String? = nil,
		tokenBudget: Int? = nil,
		enhancementModeRaw: String? = nil,
		autoGeneratePlan: Bool? = nil,
		followUpTypeRaw: String? = nil,
		selectedContextBuilderPromptIDs: [UUID] = []
	) {
		self.instructions = instructions
		// Legacy fields - kept for API compatibility but ignored
		self.agentRaw = agentRaw
		self.modelRaw = modelRaw
		self.tokenBudget = tokenBudget
		self.enhancementModeRaw = enhancementModeRaw
		// Active fields
		self.autoGeneratePlan = autoGeneratePlan
		self.followUpTypeRaw = followUpTypeRaw
		self.selectedContextBuilderPromptIDs = selectedContextBuilderPromptIDs
	}

	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		self.instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
		// Decode legacy fields for migration purposes
		self.agentRaw = try c.decodeIfPresent(String.self, forKey: .agentRaw)
		self.modelRaw = try c.decodeIfPresent(String.self, forKey: .modelRaw)
		self.tokenBudget = try c.decodeIfPresent(Int.self, forKey: .tokenBudget)
		self.enhancementModeRaw = try c.decodeIfPresent(String.self, forKey: .enhancementModeRaw)
		// Decode active fields
		self.autoGeneratePlan = try c.decodeIfPresent(Bool.self, forKey: .autoGeneratePlan)
		self.followUpTypeRaw = try c.decodeIfPresent(String.self, forKey: .followUpTypeRaw)
		self.selectedContextBuilderPromptIDs = try c.decodeIfPresent([UUID].self, forKey: .selectedContextBuilderPromptIDs) ?? []
	}
	
	func encode(to encoder: Encoder) throws {
		var c = encoder.container(keyedBy: EncodingKeys.self)
		// Only encode active fields - legacy agent/model/tokenBudget/enhancementMode are NEVER written
		try c.encode(instructions, forKey: .instructions)
		try c.encodeIfPresent(autoGeneratePlan, forKey: .autoGeneratePlan)
		try c.encodeIfPresent(followUpTypeRaw, forKey: .followUpTypeRaw)
		try c.encode(selectedContextBuilderPromptIDs, forKey: .selectedContextBuilderPromptIDs)
	}
}

/// A stashed compose tab (stored for later retrieval)
struct StashedTab: Codable, Identifiable, Equatable, Sendable {
	var id: UUID
	var tab: ComposeTabState
	var stashedAt: Date
	
	init(id: UUID = UUID(), tab: ComposeTabState, stashedAt: Date = Date()) {
		self.id = id
		self.tab = tab
		self.stashedAt = stashedAt
	}
}

/// A single Compose tab (auto-saved working state)
struct ComposeTabState: Codable, Identifiable, Equatable, Sendable {
	var id: UUID
	var name: String
	var lastModified: Date
	var isPinned: Bool
	var activeChatSessionID: UUID?
	var activeAgentSessionID: UUID?
	
	var selection: StoredSelection
	var expandedFolders: [String]
	
	var promptText: String
	var selectedMetaPromptIDs: [UUID]
	var activeSubView: FilesTab?
	var discover: DiscoverTabConfig
	/// Transient decode-time signal used by workspace loaders to persist
	/// legacy key removal once. Excluded from encoding and equality.
	var migrationRequiresSave: Bool
	private var legacyContextBuilderOverrideMigration: LegacyContextBuilderOverrideMigration?
	
	init(
		id: UUID = UUID(),
		name: String = "T1",
		lastModified: Date = Date(),
		isPinned: Bool = false,
		activeChatSessionID: UUID? = nil,
		activeAgentSessionID: UUID? = nil,
		selection: StoredSelection = .init(),
		expandedFolders: [String] = [],
		promptText: String = "",
		selectedMetaPromptIDs: [UUID] = [],
		activeSubView: FilesTab? = nil,
		discover: DiscoverTabConfig = .init()
	) {
		self.id = id
		self.name = name
		self.lastModified = lastModified
		self.isPinned = isPinned
		self.activeChatSessionID = activeChatSessionID
		self.activeAgentSessionID = activeAgentSessionID
		self.selection = selection
		self.expandedFolders = expandedFolders
		self.promptText = promptText
		self.selectedMetaPromptIDs = selectedMetaPromptIDs
		self.activeSubView = activeSubView
		self.discover = discover
		self.migrationRequiresSave = false
		self.legacyContextBuilderOverrideMigration = nil
	}

	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
		self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? "T1"
		self.lastModified = try c.decodeIfPresent(Date.self, forKey: .lastModified) ?? Date()
		self.isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
		self.activeChatSessionID = try c.decodeIfPresent(UUID.self, forKey: .activeChatSessionID)
		self.activeAgentSessionID = try c.decodeIfPresent(UUID.self, forKey: .activeAgentSessionID)
		self.selection = try c.decodeIfPresent(StoredSelection.self, forKey: .selection) ?? .init()
		self.expandedFolders = try c.decodeIfPresent([String].self, forKey: .expandedFolders) ?? []
		self.promptText = try c.decodeIfPresent(String.self, forKey: .promptText) ?? ""
		self.selectedMetaPromptIDs = try c.decodeIfPresent([UUID].self, forKey: .selectedMetaPromptIDs) ?? []
		self.activeSubView = try c.decodeIfPresent(FilesTab.self, forKey: .activeSubView)
		self.discover = try c.decodeIfPresent(DiscoverTabConfig.self, forKey: .discover) ?? .init()
		self.migrationRequiresSave = false
		self.legacyContextBuilderOverrideMigration = nil

		let legacyOverrides = try? c.decodeIfPresent(ContextBuilderOverrides.self, forKey: .contextOverrides)
		let legacyContextBuilder = try? c.decodeIfPresent(ContextBuilderState.self, forKey: .contextBuilder)
		if c.contains(.contextOverrides) || c.contains(.contextBuilder) {
			self.migrationRequiresSave = true
		}
		if let legacyOverrides,
		   legacyOverrides.useOverridePrompt,
		   !legacyOverrides.overridePromptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			self.legacyContextBuilderOverrideMigration = LegacyContextBuilderOverrideMigration(
				useOverridePrompt: legacyOverrides.useOverridePrompt,
				overridePromptText: legacyOverrides.overridePromptText
			)
		} else if let legacyContextBuilder,
			  legacyContextBuilder.useOverridePrompt,
			  !legacyContextBuilder.overridePromptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			self.legacyContextBuilderOverrideMigration = LegacyContextBuilderOverrideMigration(
				useOverridePrompt: legacyContextBuilder.useOverridePrompt,
				overridePromptText: legacyContextBuilder.overridePromptText
			)
		}
	}

	func encode(to encoder: Encoder) throws {
		var c = encoder.container(keyedBy: CodingKeys.self)
		try c.encode(id, forKey: .id)
		try c.encode(name, forKey: .name)
		try c.encode(lastModified, forKey: .lastModified)
		try c.encode(isPinned, forKey: .isPinned)
		try c.encodeIfPresent(activeChatSessionID, forKey: .activeChatSessionID)
		try c.encodeIfPresent(activeAgentSessionID, forKey: .activeAgentSessionID)
		try c.encode(selection, forKey: .selection)
		try c.encode(expandedFolders, forKey: .expandedFolders)
		try c.encode(promptText, forKey: .promptText)
		try c.encode(selectedMetaPromptIDs, forKey: .selectedMetaPromptIDs)
		try c.encodeIfPresent(activeSubView, forKey: .activeSubView)
		try c.encode(discover, forKey: .discover)
	}

	@discardableResult
	mutating func migrateLegacyContextBuilderOverride(from state: ContextBuilderState) -> Bool {
		migrateLegacyContextBuilderOverride(
			useOverridePrompt: state.useOverridePrompt,
			overridePromptText: state.overridePromptText
		)
	}

	@discardableResult
	mutating func migrateDecodedLegacyContextBuilderOverrideIfNeeded() -> Bool {
		guard let migration = legacyContextBuilderOverrideMigration else { return false }
		legacyContextBuilderOverrideMigration = nil
		return migrateLegacyContextBuilderOverride(
			useOverridePrompt: migration.useOverridePrompt,
			overridePromptText: migration.overridePromptText
		)
	}

	@discardableResult
	mutating func migrateLegacyContextBuilderOverride(
		useOverridePrompt: Bool,
		overridePromptText: String
	) -> Bool {
		guard useOverridePrompt else { return false }
		let trimmed = overridePromptText.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return false }

		let note = "Legacy Context Builder override:\n\(trimmed)"
		if promptText.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed ||
			discover.instructions.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed ||
			discover.instructions.contains(note) {
			return false
		}

		if promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			promptText = trimmed
			migrationRequiresSave = true
			return true
		}

		if discover.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			discover.instructions = trimmed
			migrationRequiresSave = true
			return true
		}

		let separator = discover.instructions.hasSuffix("\n") ? "\n" : "\n\n"
		discover.instructions += separator + note
		migrationRequiresSave = true
		return true
	}

	static func == (lhs: ComposeTabState, rhs: ComposeTabState) -> Bool {
		lhs.id == rhs.id &&
		lhs.name == rhs.name &&
		lhs.lastModified == rhs.lastModified &&
		lhs.isPinned == rhs.isPinned &&
		lhs.activeChatSessionID == rhs.activeChatSessionID &&
		lhs.activeAgentSessionID == rhs.activeAgentSessionID &&
		lhs.selection == rhs.selection &&
		lhs.expandedFolders == rhs.expandedFolders &&
		lhs.promptText == rhs.promptText &&
		lhs.selectedMetaPromptIDs == rhs.selectedMetaPromptIDs &&
		lhs.activeSubView == rhs.activeSubView &&
		lhs.discover == rhs.discover
	}
	
	enum CodingKeys: String, CodingKey {
		case id
		case name
		case lastModified
		case isPinned
		case activeChatSessionID
		case activeAgentSessionID
		case selection
		case expandedFolders
		case promptText
		case selectedMetaPromptIDs
		case activeSubView
		case contextOverrides
		case discover
		case contextBuilder
	}
}

/// A single workspace's data, describing a workspace: name, repo paths, presets, etc.
struct WorkspaceModel: Codable, Identifiable, Equatable, Sendable {
	let id: UUID
	
	var schemaVersion: Int
	var dateModified: Date
	var customStoragePath: URL?
	
	var isSystemWorkspace: Bool
	var isHiddenInMenus: Bool
	
	/// When true, the workspace is temporary and should not be persisted to disk
	var ephemeralFlag: Bool?
	
	var name: String
	var repoPaths: [String]
	
	var presets: [WorkspacePreset]
	var activePresetID: UUID?
	var lastUsed: Date
	
	// Optional custom fields
	var customPath: String?
	var currentPromptText: String?
	/// The last search query typed in the file-search panel (persisted per workspace)
	var lastSearchQuery: String?
	var selectedMetaPromptIDs: [UUID]
	
	// The user's current "working" selection and expansions
	var workingFilePaths: [String]
	var workingExpandedFolders: [String]
	var workingStoredSelection: StoredSelection?
	
	// Discovery Agent state
	var discoveryInstructions: String?
	var discoveryTokenBudget: Int?
	var discoveryAgentRaw: String?
	var discoveryClaudeCodeModelRaw: String?
	var discoveryCodexModelRaw: String?
	
	// Copy and Chat Preset Fields
	var copyPresetId: UUID?
	var copyCustomizations: CopyCustomizations?
	var chatPresetId: UUID?
	
	// Compose tabs (auto-saved working contexts)
	var composeTabs: [ComposeTabState]
	var activeComposeTabID: UUID?
	
	// Stashed tabs (stored for later retrieval)
	var stashedTabs: [StashedTab]

	/// Transient decode-time signal used by workspace loaders to persist schema
	/// migrations once. This is intentionally excluded from CodingKeys/Equatable.
	var migrationRequiresSave: Bool

	private static let decodeLogger = Logger(subsystem: "com.repoprompt.workspace", category: "decode")
	private static var composeTabsDecodeWarningEmitted = false

	private static func logComposeTabsDecodeFailure(error: Error, workspaceID: UUID) {
		guard !composeTabsDecodeWarningEmitted else { return }
		composeTabsDecodeWarningEmitted = true
		let message = "Failed to decode composeTabs for workspace \(workspaceID.uuidString); falling back to empty array. Error: \(error.localizedDescription)"
		decodeLogger.error("\(message, privacy: .public)")
	}
	
	/// Default init used by code
	init(
		id: UUID = UUID(),
		schemaVersion: Int = 1,
		dateModified: Date = Date(),
		name: String,
		repoPaths: [String],
		presets: [WorkspacePreset] = [],
		activePresetID: UUID? = nil,
		lastUsed: Date = Date(),
		customPath: String? = nil,
		currentPromptText: String? = nil,
		lastSearchQuery: String? = nil,
		selectedMetaPromptIDs: [UUID] = [],
		workingFilePaths: [String] = [],
		workingExpandedFolders: [String] = [],
		workingStoredSelection: StoredSelection? = nil,
		isSystemWorkspace: Bool = false,
		customStoragePath: URL? = nil,
		ephemeralFlag: Bool? = nil,
		isHiddenInMenus: Bool = false,
		discoveryInstructions: String? = nil,
		discoveryTokenBudget: Int? = nil,
		discoveryAgentRaw: String? = nil,
		discoveryClaudeCodeModelRaw: String? = nil,
		discoveryCodexModelRaw: String? = nil,
		copyPresetId: UUID? = nil,
		copyCustomizations: CopyCustomizations? = nil,
		chatPresetId: UUID? = nil,
		composeTabs: [ComposeTabState] = [],
		activeComposeTabID: UUID? = nil,
		stashedTabs: [StashedTab] = []
	) {
		self.id = id
		self.schemaVersion = schemaVersion
		self.dateModified = dateModified
		self.name = name
		self.repoPaths = repoPaths
		self.presets = presets
		self.activePresetID = activePresetID
		self.lastUsed = lastUsed
		self.customPath = customPath
		self.currentPromptText = currentPromptText
		self.selectedMetaPromptIDs = selectedMetaPromptIDs
		self.lastSearchQuery       = lastSearchQuery
		self.workingFilePaths = workingFilePaths
		self.workingExpandedFolders = workingExpandedFolders
		self.workingStoredSelection = workingStoredSelection
		self.isSystemWorkspace = isSystemWorkspace
		self.customStoragePath = customStoragePath
		self.ephemeralFlag = ephemeralFlag
		self.isHiddenInMenus = isHiddenInMenus
		self.discoveryInstructions = discoveryInstructions
		self.discoveryTokenBudget = discoveryTokenBudget
		self.discoveryAgentRaw = discoveryAgentRaw
		self.discoveryClaudeCodeModelRaw = discoveryClaudeCodeModelRaw
		self.discoveryCodexModelRaw = discoveryCodexModelRaw
		self.copyPresetId = copyPresetId
		self.copyCustomizations = copyCustomizations
		self.chatPresetId = chatPresetId
		self.composeTabs = composeTabs
		self.activeComposeTabID = activeComposeTabID
		self.stashedTabs = stashedTabs
		self.migrationRequiresSave = false
		migrateWorkingStateToTabsIfNeeded()
		migrateDiscoverAndCBStateToTabsIfNeeded()
		self.migrationRequiresSave = false
	}

	/// **Partial decoding** to handle missing fields and type mismatches gracefully.
	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		
		self.id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
		self.schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 1
		self.dateModified = (try? c.decode(Date.self, forKey: .dateModified)) ?? Date()
		self.customStoragePath = (try? c.decode(URL.self, forKey: .customStoragePath))
		self.isSystemWorkspace = (try? c.decode(Bool.self, forKey: .isSystemWorkspace)) ?? false
		self.isHiddenInMenus = (try? c.decode(Bool.self, forKey: .isHiddenInMenus)) ?? false
		self.ephemeralFlag = (try? c.decode(Bool?.self, forKey: .ephemeralFlag)) ?? nil
		self.name = (try? c.decode(String.self, forKey: .name)) ?? "Untitled Workspace"
		self.repoPaths = (try? c.decode([String].self, forKey: .repoPaths)) ?? []
		self.presets = (try? c.decode([WorkspacePreset].self, forKey: .presets)) ?? []
		self.activePresetID = (try? c.decode(UUID.self, forKey: .activePresetID))
		self.lastUsed = (try? c.decode(Date.self, forKey: .lastUsed)) ?? Date()
		self.customPath = (try? c.decode(String.self, forKey: .customPath))
		self.currentPromptText = (try? c.decode(String.self, forKey: .currentPromptText))
		self.lastSearchQuery  = (try? c.decode(String.self, forKey: .lastSearchQuery))
		self.selectedMetaPromptIDs = (try? c.decode([UUID].self, forKey: .selectedMetaPromptIDs)) ?? []
		self.workingFilePaths = (try? c.decode([String].self, forKey: .workingFilePaths)) ?? []
		self.workingExpandedFolders = (try? c.decode([String].self, forKey: .workingExpandedFolders)) ?? []
		self.workingStoredSelection = try? c.decode(StoredSelection.self, forKey: .workingStoredSelection)
		let hasLegacyContextBuilderState = c.contains(.contextBuilderState)
		let legacyContextBuilderState = (try? c.decode(ContextBuilderState.self, forKey: .contextBuilderState))
		self.discoveryInstructions = (try? c.decode(String.self, forKey: .discoveryInstructions))
		self.discoveryTokenBudget = (try? c.decode(Int.self, forKey: .discoveryTokenBudget))
		self.discoveryAgentRaw = (try? c.decode(String.self, forKey: .discoveryAgentRaw))
		self.discoveryClaudeCodeModelRaw = (try? c.decode(String.self, forKey: .discoveryClaudeCodeModelRaw))
		self.discoveryCodexModelRaw = (try? c.decode(String.self, forKey: .discoveryCodexModelRaw))
		self.copyPresetId = (try? c.decode(UUID.self, forKey: .copyPresetId))
		self.copyCustomizations = (try? c.decode(CopyCustomizations.self, forKey: .copyCustomizations))
		self.chatPresetId = (try? c.decode(UUID.self, forKey: .chatPresetId))
		do {
			self.composeTabs = try c.decodeIfPresent([ComposeTabState].self, forKey: .composeTabs) ?? []
		} catch {
			Self.logComposeTabsDecodeFailure(error: error, workspaceID: self.id)
			self.composeTabs = []
		}
		self.activeComposeTabID = (try? c.decode(UUID.self, forKey: .activeComposeTabID))
		self.stashedTabs = (try? c.decode([StashedTab].self, forKey: .stashedTabs)) ?? []
		self.migrationRequiresSave = false
		if hasLegacyContextBuilderState ||
			composeTabs.contains(where: { $0.migrationRequiresSave }) ||
			stashedTabs.contains(where: { $0.tab.migrationRequiresSave }) {
			self.migrationRequiresSave = true
		}
		migrateWorkingStateToTabsIfNeeded()
		migrateDiscoverAndCBStateToTabsIfNeeded(legacyContextBuilderState: legacyContextBuilderState)
	}

	func encode(to encoder: Encoder) throws {
		var c = encoder.container(keyedBy: CodingKeys.self)
		try c.encode(id, forKey: .id)
		try c.encode(schemaVersion, forKey: .schemaVersion)
		try c.encode(dateModified, forKey: .dateModified)
		try c.encodeIfPresent(customStoragePath, forKey: .customStoragePath)
		try c.encode(isSystemWorkspace, forKey: .isSystemWorkspace)
		try c.encode(isHiddenInMenus, forKey: .isHiddenInMenus)
		try c.encode(name, forKey: .name)
		try c.encode(repoPaths, forKey: .repoPaths)
		try c.encode(presets, forKey: .presets)
		try c.encodeIfPresent(activePresetID, forKey: .activePresetID)
		try c.encode(lastUsed, forKey: .lastUsed)
		try c.encodeIfPresent(customPath, forKey: .customPath)
		try c.encodeIfPresent(currentPromptText, forKey: .currentPromptText)
		try c.encodeIfPresent(lastSearchQuery, forKey: .lastSearchQuery)
		try c.encode(selectedMetaPromptIDs, forKey: .selectedMetaPromptIDs)
		try c.encode(workingFilePaths, forKey: .workingFilePaths)
		try c.encode(workingExpandedFolders, forKey: .workingExpandedFolders)
		try c.encodeIfPresent(workingStoredSelection, forKey: .workingStoredSelection)
		try c.encodeIfPresent(ephemeralFlag, forKey: .ephemeralFlag)
		try c.encodeIfPresent(discoveryInstructions, forKey: .discoveryInstructions)
		try c.encodeIfPresent(discoveryTokenBudget, forKey: .discoveryTokenBudget)
		try c.encodeIfPresent(discoveryAgentRaw, forKey: .discoveryAgentRaw)
		try c.encodeIfPresent(discoveryClaudeCodeModelRaw, forKey: .discoveryClaudeCodeModelRaw)
		try c.encodeIfPresent(discoveryCodexModelRaw, forKey: .discoveryCodexModelRaw)
		try c.encodeIfPresent(copyPresetId, forKey: .copyPresetId)
		try c.encodeIfPresent(copyCustomizations, forKey: .copyCustomizations)
		try c.encodeIfPresent(chatPresetId, forKey: .chatPresetId)
		try c.encode(composeTabs, forKey: .composeTabs)
		try c.encodeIfPresent(activeComposeTabID, forKey: .activeComposeTabID)
		try c.encode(stashedTabs, forKey: .stashedTabs)
	}
	
	static func == (lhs: WorkspaceModel, rhs: WorkspaceModel) -> Bool {
		lhs.id == rhs.id &&
		lhs.schemaVersion == rhs.schemaVersion &&
		lhs.dateModified == rhs.dateModified &&
		lhs.name == rhs.name &&
		lhs.repoPaths == rhs.repoPaths &&
		lhs.presets == rhs.presets &&
		lhs.activePresetID == rhs.activePresetID &&
		lhs.lastUsed == rhs.lastUsed &&
		lhs.customPath == rhs.customPath &&
		lhs.currentPromptText == rhs.currentPromptText &&
		lhs.lastSearchQuery  == rhs.lastSearchQuery &&
		lhs.selectedMetaPromptIDs == rhs.selectedMetaPromptIDs &&
		lhs.workingFilePaths == rhs.workingFilePaths &&
		lhs.workingExpandedFolders == rhs.workingExpandedFolders &&
		lhs.workingStoredSelection == rhs.workingStoredSelection &&
		lhs.isHiddenInMenus == rhs.isHiddenInMenus &&
		lhs.isSystemWorkspace == rhs.isSystemWorkspace &&
		lhs.customStoragePath == rhs.customStoragePath &&
		lhs.ephemeralFlag == rhs.ephemeralFlag &&
		lhs.discoveryInstructions == rhs.discoveryInstructions &&
		lhs.discoveryTokenBudget == rhs.discoveryTokenBudget &&
		lhs.discoveryAgentRaw == rhs.discoveryAgentRaw &&
		lhs.discoveryClaudeCodeModelRaw == rhs.discoveryClaudeCodeModelRaw &&
		lhs.discoveryCodexModelRaw == rhs.discoveryCodexModelRaw &&
		lhs.copyPresetId == rhs.copyPresetId &&
		lhs.copyCustomizations == rhs.copyCustomizations &&
		lhs.chatPresetId == rhs.chatPresetId &&
		lhs.composeTabs == rhs.composeTabs &&
		lhs.activeComposeTabID == rhs.activeComposeTabID &&
		lhs.stashedTabs == rhs.stashedTabs
	}
	
	enum CodingKeys: String, CodingKey {
		case id
		case schemaVersion
		case dateModified
		case customStoragePath
		case isSystemWorkspace
		case isHiddenInMenus
		case name
		case repoPaths
		case presets
		case activePresetID
		case lastUsed
		case customPath
		case currentPromptText
		case lastSearchQuery
		case selectedMetaPromptIDs
		case workingFilePaths
		case workingExpandedFolders
		case workingStoredSelection
		case contextBuilderState
		case ephemeralFlag
		case discoveryInstructions
		case discoveryTokenBudget
		case discoveryAgentRaw
		case discoveryClaudeCodeModelRaw
		case discoveryCodexModelRaw
		case copyPresetId
		case copyCustomizations
		case chatPresetId
		case composeTabs
		case activeComposeTabID
		case stashedTabs
	}
}

extension WorkspaceModel {
	/// Indicates whether this workspace should not be persisted to disk
	var isEphemeral: Bool {
		get { ephemeralFlag ?? false }
		set { ephemeralFlag = newValue }
	}
	
	@discardableResult
	mutating func normalizeComposeAndStashedTabs() -> Bool {
		let activeTabIDs = Set(composeTabs.map(\.id))
		guard !activeTabIDs.isEmpty else { return false }
		let originalCount = stashedTabs.count
		stashedTabs.removeAll { activeTabIDs.contains($0.tab.id) }
		let mutated = stashedTabs.count != originalCount
		if mutated {
			migrationRequiresSave = true
		}
		return mutated
	}

	@discardableResult
	mutating func migrateWorkingStateToTabsIfNeeded() -> Bool {
		var mutated = false
		guard composeTabs.isEmpty else {
			if normalizeComposeAndStashedTabs() {
				mutated = true
			}
			return mutated
		}
		let selection = workingStoredSelection ?? StoredSelection(selectedPaths: workingFilePaths)
		let tab = ComposeTabState(
			name: "T1",
			selection: selection,
			expandedFolders: workingExpandedFolders,
			promptText: currentPromptText ?? "",
			selectedMetaPromptIDs: selectedMetaPromptIDs,
			activeSubView: nil  // nil = use the default files tab
		)
		composeTabs = [tab]
		activeComposeTabID = tab.id
		mutated = true
		if normalizeComposeAndStashedTabs() {
			mutated = true
		}
		if mutated {
			migrationRequiresSave = true
		}
		return mutated
	}
	
	@discardableResult
	mutating func migrateDecodedLegacyTabContextBuilderOverridesIfNeeded() -> Bool {
		var mutated = false
		for index in composeTabs.indices {
			if composeTabs[index].migrateDecodedLegacyContextBuilderOverrideIfNeeded() {
				mutated = true
			}
		}
		for index in stashedTabs.indices {
			if stashedTabs[index].tab.migrateDecodedLegacyContextBuilderOverrideIfNeeded() {
				mutated = true
			}
		}
		if mutated {
			migrationRequiresSave = true
		}
		return mutated
	}

	@discardableResult
	mutating func migrateDiscoverAndCBStateToTabsIfNeeded(legacyContextBuilderState: ContextBuilderState? = nil) -> Bool {
		var mutated = false
		let hasLegacyDiscover = discoveryInstructions != nil ||
			discoveryTokenBudget != nil ||
			discoveryAgentRaw != nil ||
			discoveryClaudeCodeModelRaw != nil ||
			discoveryCodexModelRaw != nil
		let hasLegacyContextBuilder = legacyContextBuilderState != nil
		
		guard hasLegacyDiscover || hasLegacyContextBuilder else {
			if migrateDecodedLegacyTabContextBuilderOverridesIfNeeded() {
				mutated = true
			}
			if normalizeComposeAndStashedTabs() {
				mutated = true
			}
			return mutated
		}
		
		if composeTabs.isEmpty {
			if migrateWorkingStateToTabsIfNeeded() {
				mutated = true
			}
		}
		guard !composeTabs.isEmpty else { return mutated }
		
		let targetIndex = composeTabs.firstIndex { $0.id == activeComposeTabID } ?? composeTabs.indices.first!
		var tab = composeTabs[targetIndex]
		
		if hasLegacyDiscover {
			if tab.discover.instructions.isEmpty, let instructions = discoveryInstructions {
				tab.discover.instructions = instructions
			}
			// tokenBudget/enhancementMode are now workspace-scoped (in ChatGlobalSettings), no migration needed here
			// Agent/model are now workspace-scoped (not tab-scoped), no migration needed
		}

		composeTabs[targetIndex] = tab
		if migrateDecodedLegacyTabContextBuilderOverridesIfNeeded() {
			mutated = true
		}
		tab = composeTabs[targetIndex]
		
		if let legacyState = legacyContextBuilderState {
			if tab.migrateLegacyContextBuilderOverride(from: legacyState) {
				mutated = true
			}
			mutated = true
		}
		
		composeTabs[targetIndex] = tab
		
		discoveryInstructions = nil
		discoveryTokenBudget = nil
		discoveryAgentRaw = nil
		discoveryClaudeCodeModelRaw = nil
		discoveryCodexModelRaw = nil
		mutated = true
		if normalizeComposeAndStashedTabs() {
			mutated = true
		}
		if mutated {
			migrationRequiresSave = true
		}
		return mutated
	}
}
