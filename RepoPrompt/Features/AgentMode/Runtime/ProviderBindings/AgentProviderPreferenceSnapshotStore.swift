import Foundation

@MainActor
final class AgentProviderPreferenceSnapshotStore {
	typealias CodexMCPServerEntriesProvider = () -> [MCPIntegrationHelper.CodexServerEntry]

	let defaults: UserDefaults
	let securePermissions: AgentPermissionSecureStore?

	private let codexMCPServerEntriesProvider: CodexMCPServerEntriesProvider
	private var revisionByProviderID: [AgentProviderBindingID: Int]

	init(
		defaults: UserDefaults = .standard,
		securePermissions: AgentPermissionSecureStore? = nil,
		codexMCPServerEntries: @escaping CodexMCPServerEntriesProvider = { MCPIntegrationHelper.codexMCPServerEntries() }
	) {
		self.defaults = defaults
		self.securePermissions = securePermissions ?? (defaults === UserDefaults.standard ? AgentPermissionSecureStore.shared : nil)
		self.codexMCPServerEntriesProvider = codexMCPServerEntries
		self.revisionByProviderID = Dictionary(uniqueKeysWithValues: AgentProviderBindingID.allCases.map { ($0, 0) })
	}

	func revision(for providerID: AgentProviderBindingID) -> Int {
		revisionByProviderID[providerID, default: 0]
	}

	/// Builds editable direct/top-level Settings controls for a provider.
	///
	/// This is intentionally separate from the profile-aware runtime binding entry point
	/// below so Settings provider rows do not accidentally inherit sub-agent preview policy.
	func topLevelSettingsControlsBinding(providerID: AgentProviderBindingID) -> AgentProviderControlsBinding {
		controlsBinding(
			selectedAgent: Self.representativeAgent(for: providerID),
			selectedModelRaw: nil,
			permissionProfile: .userConfigured,
			isSubagent: false,
			externallyManagedReason: nil
		)
	}

	/// Builds a controls snapshot after higher-level policy has already resolved the
	/// permission profile and any externally managed reason. `isSubagent` is accepted for
	/// API compatibility with the Settings/runtime split, but subagent policy is intentionally
	/// applied by `AgentModeProviderBindingService` before reaching this store.
	func controlsBinding(
		selectedAgent: DiscoverAgentKind,
		selectedModelRaw: String? = nil,
		permissionProfile: AgentProviderPermissionProfile,
		isSubagent _: Bool,
		externallyManagedReason: String?
	) -> AgentProviderControlsBinding {
		let providerID = selectedAgent.providerBindingID
		let permission = permissionChromeBinding(
			for: providerID,
			profile: permissionProfile,
			externallyManagedReason: externallyManagedReason
		)
		return AgentProviderControlsBinding(
			revision: revision(for: providerID),
			selectedAgent: selectedAgent,
			providerID: providerID,
			permission: permission,
			runtimePermission: runtimePermission(for: selectedAgent, profile: permissionProfile),
			codexTools: providerID == .codex
				? codexToolSettingsBinding(profile: permissionProfile)
				: nil,
			claudeTools: providerID == .claude
				? claudeToolSettingsBinding(
					profile: permissionProfile,
					selectedAgent: selectedAgent,
					selectedModelRaw: selectedModelRaw
				)
				: nil
		)
	}

	func runtimePermission(
		for agent: DiscoverAgentKind,
		profile: AgentProviderPermissionProfile
	) -> AgentProviderRuntimePermissionBinding {
		switch agent.providerBindingID {
		case .codex:
			let sandboxMode: CodexAgentToolPreferences.SandboxMode
			let approvalPolicy: CodexAgentToolPreferences.ApprovalPolicy
			let approvalReviewer: CodexAgentToolPreferences.ApprovalReviewer
			switch profile {
			case .userConfigured:
				sandboxMode = CodexAgentToolPreferences.sandboxMode(defaults: defaults, secureStore: securePermissions)
				approvalPolicy = CodexAgentToolPreferences.approvalPolicy(defaults: defaults, secureStore: securePermissions)
				approvalReviewer = CodexAgentToolPreferences.approvalReviewer(defaults: defaults, secureStore: securePermissions)
			case .mcpSafeDefaults:
				let level = CodexAgentToolPreferences.PermissionLevel.defaultPermission
				sandboxMode = level.sandboxMode
				approvalPolicy = level.approvalPolicy
				approvalReviewer = level.approvalReviewer
			case .providerOverride(.codex(let level)):
				sandboxMode = level.sandboxMode
				approvalPolicy = level.approvalPolicy
				approvalReviewer = level.approvalReviewer
			case .providerOverride:
				let level = CodexAgentToolPreferences.PermissionLevel.defaultPermission
				sandboxMode = level.sandboxMode
				approvalPolicy = level.approvalPolicy
				approvalReviewer = level.approvalReviewer
			}
			return AgentProviderRuntimePermissionBinding(
				codexSandboxMode: sandboxMode,
				codexApprovalPolicy: approvalPolicy,
				codexApprovalReviewer: approvalReviewer
			)
		case .claude:
			let permissionMode: String = switch profile {
			case .userConfigured:
				ClaudeAgentToolPreferences.permissionMode(defaults: defaults, secureStore: securePermissions)
			case .mcpSafeDefaults:
				ClaudeAgentToolPreferences.PermissionLevel.requireApproval.permissionMode
			case .providerOverride(.claude(let level)):
				level.permissionMode
			case .providerOverride:
				ClaudeAgentToolPreferences.PermissionLevel.requireApproval.permissionMode
			}
			return AgentProviderRuntimePermissionBinding(
				claudePermissionMode: permissionMode
			)
		case .gemini:
			let level = effectiveGeminiPermissionLevel(profile: profile)
			let configuredSessionModeID: String = switch profile {
			case .userConfigured:
				GeminiAgentToolPreferences.sessionModeID(defaults: defaults, secureStore: securePermissions)
			case .mcpSafeDefaults:
				GeminiAgentToolPreferences.PermissionLevel.default.sessionModeID
			case .providerOverride(.gemini(let level)):
				level.sessionModeID
			case .providerOverride:
				GeminiAgentToolPreferences.PermissionLevel.default.sessionModeID
			}
			return AgentProviderRuntimePermissionBinding(
				acpSessionModeID: geminiRuntimeSessionModeID(
					configuredSessionModeID,
					effectiveLevel: level
				),
				autoApproveAllACPToolPermissions: level == .fullAccess,
				acceptsPendingACPApprovalWhenActivated: level == .fullAccess
			)
		case .openCode:
			let level = effectiveOpenCodePermissionLevel(profile: profile)
			return AgentProviderRuntimePermissionBinding(
				acpSessionModeID: level.sessionModeID,
				acceptsPendingACPApprovalWhenActivated: level.acceptsPendingApprovalWhenActivated
			)
		case .cursor:
			let level = effectiveCursorPermissionLevel(profile: profile)
			return AgentProviderRuntimePermissionBinding(
				autoApproveAllACPToolPermissions: level.autoApprovesACPToolPermissions,
				acceptsPendingACPApprovalWhenActivated: level.autoApprovesACPToolPermissions
			)
		}
	}

	@discardableResult
	func setPermissionLevel(_ id: AgentProviderPermissionLevelID) -> AgentProviderBindingID {
		switch id {
		case .codex(let level):
			CodexAgentToolPreferences.setPermissionLevel(level, defaults: defaults, secureStore: securePermissions)
		case .claude(let level):
			ClaudeAgentToolPreferences.setPermissionLevel(level, defaults: defaults, secureStore: securePermissions)
		case .gemini(let level):
			GeminiAgentToolPreferences.setPermissionLevel(level, defaults: defaults, secureStore: securePermissions)
		case .openCode(let level):
			OpenCodeAgentToolPreferences.setPermissionLevel(level, defaults: defaults, secureStore: securePermissions)
		case .cursor(let level):
			CursorAgentToolPreferences.setPermissionLevel(level, defaults: defaults, secureStore: securePermissions)
		}
		bumpRevision(for: id.providerID)
		return id.providerID
	}

	func setCodexBashToolEnabled(_ enabled: Bool) {
		CodexAgentToolPreferences.setBashToolEnabled(enabled, defaults: defaults, secureStore: securePermissions)
		bumpRevision(for: .codex)
	}

	func setCodexSearchToolEnabled(_ enabled: Bool) {
		CodexAgentToolPreferences.setSearchToolEnabled(enabled, defaults: defaults)
		bumpRevision(for: .codex)
	}

	func setCodexGoalSupportEnabled(_ enabled: Bool) {
		if defaults === UserDefaults.standard {
			GlobalSettingsStore.shared.setCodexGoalSupportEnabled(enabled)
		} else {
			CodexGoalSupport.setEnabled(enabled, defaults: defaults)
		}
		bumpRevision(for: .codex)
	}

	func setCodexMCPServerEnabled(normalizedName: String, enabled: Bool) {
		CodexAgentToolPreferences.setMCPServerEnabled(
			normalizedName: normalizedName,
			isEnabled: enabled,
			defaults: defaults,
			secureStore: securePermissions
		)
		bumpRevision(for: .codex)
	}

	func setClaudeBashToolEnabled(_ enabled: Bool) {
		ClaudeAgentToolPreferences.setBashToolEnabled(enabled, defaults: defaults, secureStore: securePermissions)
		bumpRevision(for: .claude)
	}

	func setClaudeMCPStrictModeEnabled(_ enabled: Bool) {
		ClaudeAgentToolPreferences.setMCPStrictModeEnabled(enabled, defaults: defaults, secureStore: securePermissions)
		bumpRevision(for: .claude)
	}

	func setClaudeToolSearchEnabled(_ enabled: Bool) {
		ClaudeAgentToolPreferences.setToolSearchEnabled(enabled, defaults: defaults)
		bumpRevision(for: .claude)
	}

	func setClaudeEffortLevel(_ level: ClaudeCodeEffortLevel) {
		ClaudeAgentToolPreferences.setEffortLevel(level, defaults: defaults)
		bumpRevision(for: .claude)
	}

	func setClaudeEffortLevel(
		_ level: ClaudeCodeEffortLevel,
		forModelRaw modelRaw: String?,
		agentKind: DiscoverAgentKind?
	) {
		guard let modelRaw, let agentKind else {
			setClaudeEffortLevel(level)
			return
		}
		ClaudeAgentToolPreferences.setEffortLevel(
			level,
			forModelRaw: modelRaw,
			agentKind: agentKind,
			defaults: defaults
		)
		bumpRevision(for: .claude)
	}

	func setClaudeAgentModePromptDelivery(_ delivery: ClaudeAgentToolPreferences.AgentModePromptDelivery) {
		ClaudeAgentToolPreferences.setAgentModePromptDelivery(delivery, defaults: defaults)
		bumpRevision(for: .claude)
	}

	func bumpRevision(for providerID: AgentProviderBindingID) {
		revisionByProviderID[providerID, default: 0] += 1
	}

	private func permissionChromeBinding(
		for providerID: AgentProviderBindingID,
		profile: AgentProviderPermissionProfile,
		externallyManagedReason: String?
	) -> AgentPermissionChromeBinding {
		switch providerID {
		case .codex:
			let effective = effectiveCodexPermissionLevel(profile: profile)
			return AgentPermissionChromeBinding(
				providerID: providerID,
				displayName: effective.displayName,
				iconName: effective.iconName,
				isWarning: effective.isWarning,
				externallyManagedReason: externallyManagedReason,
				options: CodexAgentToolPreferences.PermissionLevel.allCases.map { level in
					AgentPermissionOptionBinding(
						id: .codex(level),
						title: level.displayName,
						iconName: level.iconName,
						detailText: level == .autoReview ? "Codex reviews tool requests automatically before asking you." : nil,
						isWarning: level.isWarning,
						isSelected: level == effective,
						isEnabled: externallyManagedReason == nil
					)
				}
			)
		case .claude:
			let effective = effectiveClaudePermissionLevel(profile: profile)
			return AgentPermissionChromeBinding(
				providerID: providerID,
				displayName: effective.displayName,
				iconName: effective.iconName,
				isWarning: effective.isWarning,
				externallyManagedReason: externallyManagedReason,
				options: ClaudeAgentToolPreferences.PermissionLevel.allCases.map { level in
					AgentPermissionOptionBinding(
						id: .claude(level),
						title: level.displayName,
						iconName: level.iconName,
						detailText: level.detailText,
						isWarning: level.isWarning,
						isSelected: level == effective,
						isEnabled: externallyManagedReason == nil
					)
				}
			)
		case .gemini:
			let effective = effectiveGeminiPermissionLevel(profile: profile)
			return AgentPermissionChromeBinding(
				providerID: providerID,
				displayName: effective.displayName,
				iconName: effective.iconName,
				isWarning: effective.isWarning,
				externallyManagedReason: externallyManagedReason,
				options: GeminiAgentToolPreferences.PermissionLevel.allCases.map { level in
					AgentPermissionOptionBinding(
						id: .gemini(level),
						title: level.displayName,
						iconName: level.iconName,
						detailText: nil,
						isWarning: level.isWarning,
						isSelected: level == effective,
						isEnabled: externallyManagedReason == nil
					)
				}
			)
		case .openCode:
			let effective = effectiveOpenCodePermissionLevel(profile: profile)
			return AgentPermissionChromeBinding(
				providerID: providerID,
				displayName: effective.displayName,
				iconName: effective.iconName,
				isWarning: effective.isWarning,
				externallyManagedReason: externallyManagedReason,
				options: OpenCodeAgentToolPreferences.PermissionLevel.allCases.map { level in
					AgentPermissionOptionBinding(
						id: .openCode(level),
						title: level.displayName,
						iconName: level.iconName,
						detailText: level.detailText,
						isWarning: level.isWarning,
						isSelected: level == effective,
						isEnabled: externallyManagedReason == nil
					)
				}
			)
		case .cursor:
			let effective = effectiveCursorPermissionLevel(profile: profile)
			return AgentPermissionChromeBinding(
				providerID: providerID,
				displayName: effective.displayName,
				iconName: effective.iconName,
				isWarning: effective.isWarning,
				externallyManagedReason: externallyManagedReason,
				options: CursorAgentToolPreferences.PermissionLevel.allCases.map { level in
					AgentPermissionOptionBinding(
						id: .cursor(level),
						title: level.displayName,
						iconName: level.iconName,
						detailText: level.detailText,
						isWarning: level.isWarning,
						isSelected: level == effective,
						isEnabled: externallyManagedReason == nil
					)
				}
			)
		}
	}

	/// Builds the Codex tool snapshot with Safe Managed overrides applied when the profile
	/// is `.mcpSafeDefaults`. User-configured runs read defaults directly as before.
	///
	/// SEARCH-HELPER: Safe Managed, Codex Bash override, Codex MCP server toggles
	private func codexToolSettingsBinding(
		profile: AgentProviderPermissionProfile
	) -> CodexToolSettingsBinding {
		let entries = codexMCPServerEntriesProvider()
		switch profile {
		case .userConfigured, .providerOverride:
			var states: [String: Bool] = [:]
			for entry in entries {
				let key = normalizedServerToggleKey(entry.normalizedName)
				states[key] = CodexAgentToolPreferences.mcpServerEnabled(
					normalizedName: entry.normalizedName,
					defaults: defaults,
					secureStore: securePermissions
				)
			}
			return CodexToolSettingsBinding(
				bashToolEnabled: CodexAgentToolPreferences.bashToolEnabled(defaults: defaults, secureStore: securePermissions),
				searchToolEnabled: CodexAgentToolPreferences.searchToolEnabled(defaults: defaults),
				goalSupportEnabled: codexGoalSupportEnabled(),
				mcpServerEntries: entries,
				mcpServerStatesByNormalizedName: states
			)
		case .mcpSafeDefaults:
			// Safe Managed: force Bash off and suppress every user-toggled MCP server.
			// Search stays available — it is read-only and helps sub-agents without granting
			// shell/tool execution.
			var states: [String: Bool] = [:]
			for entry in entries {
				states[normalizedServerToggleKey(entry.normalizedName)] = false
			}
			return CodexToolSettingsBinding(
				bashToolEnabled: false,
				searchToolEnabled: CodexAgentToolPreferences.searchToolEnabled(defaults: defaults),
				goalSupportEnabled: codexGoalSupportEnabled(),
				mcpServerEntries: entries,
				mcpServerStatesByNormalizedName: states
			)
		}
	}

	/// Builds the Claude tool snapshot with Safe Managed overrides applied when the profile
	/// is `.mcpSafeDefaults`. User-configured runs read defaults directly as before.
	///
	/// SEARCH-HELPER: Safe Managed, Claude Bash override, Claude MCP strict mode override
	private func claudeToolSettingsBinding(
		profile: AgentProviderPermissionProfile,
		selectedAgent: DiscoverAgentKind,
		selectedModelRaw: String?
	) -> ClaudeToolSettingsBinding {
		let effortLevel = claudeEffortLevel(selectedAgent: selectedAgent, selectedModelRaw: selectedModelRaw)
		switch profile {
		case .userConfigured, .providerOverride:
			return ClaudeToolSettingsBinding(
				bashToolEnabled: ClaudeAgentToolPreferences.bashToolEnabled(defaults: defaults, secureStore: securePermissions),
				mcpStrictModeEnabled: ClaudeAgentToolPreferences.mcpStrictModeEnabled(defaults: defaults, secureStore: securePermissions),
				toolSearchEnabled: ClaudeAgentToolPreferences.toolSearchEnabled(defaults: defaults),
				effortLevel: effortLevel,
				agentModePromptDelivery: ClaudeAgentToolPreferences.agentModePromptDelivery(defaults: defaults)
			)
		case .mcpSafeDefaults:
			// Safe Managed: force Bash off and keep MCP strict mode on so only the RepoPrompt
			// MCP server is reachable. Search stays available. Effort and prompt-delivery are
			// carried through so runtime behavior for those remains user-configurable.
			return ClaudeToolSettingsBinding(
				bashToolEnabled: false,
				mcpStrictModeEnabled: true,
				toolSearchEnabled: ClaudeAgentToolPreferences.toolSearchEnabled(defaults: defaults),
				effortLevel: effortLevel,
				agentModePromptDelivery: ClaudeAgentToolPreferences.agentModePromptDelivery(defaults: defaults)
			)
		}
	}

	private func codexGoalSupportEnabled() -> Bool {
		if defaults === UserDefaults.standard {
			return GlobalSettingsStore.shared.codexGoalSupportEnabled()
		}
		return CodexGoalSupport.isEnabled(defaults: defaults)
	}

	private func claudeEffortLevel(
		selectedAgent: DiscoverAgentKind,
		selectedModelRaw: String?
	) -> ClaudeCodeEffortLevel {
		guard let selectedModelRaw else {
			return ClaudeAgentToolPreferences.effortLevel(defaults: defaults)
		}
		return ClaudeAgentToolPreferences.effortLevel(
			forModelRaw: selectedModelRaw,
			agentKind: selectedAgent,
			defaults: defaults
		)
	}


	private func effectiveCodexPermissionLevel(
		profile: AgentProviderPermissionProfile
	) -> CodexAgentToolPreferences.PermissionLevel {
		switch profile {
		case .userConfigured:
			return CodexAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: securePermissions)
		case .mcpSafeDefaults:
			return .defaultPermission
		case .providerOverride(.codex(let level)):
			return level
		case .providerOverride:
			return .defaultPermission
		}
	}

	private func effectiveClaudePermissionLevel(
		profile: AgentProviderPermissionProfile
	) -> ClaudeAgentToolPreferences.PermissionLevel {
		switch profile {
		case .userConfigured:
			return ClaudeAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: securePermissions)
		case .mcpSafeDefaults:
			return .requireApproval
		case .providerOverride(.claude(let level)):
			return level
		case .providerOverride:
			return .requireApproval
		}
	}

	private func geminiRuntimeSessionModeID(
		_ configuredSessionModeID: String?,
		effectiveLevel: GeminiAgentToolPreferences.PermissionLevel
	) -> String {
		let defaultSessionModeID = GeminiAgentToolPreferences.PermissionLevel.default.sessionModeID
		guard effectiveLevel != .fullAccess else {
			return defaultSessionModeID
		}
		let trimmed = configuredSessionModeID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		guard !trimmed.isEmpty,
			trimmed.caseInsensitiveCompare(GeminiAgentToolPreferences.PermissionLevel.fullAccess.sessionModeID) != .orderedSame else {
			return defaultSessionModeID
		}
		return trimmed
	}

	private func effectiveGeminiPermissionLevel(
		profile: AgentProviderPermissionProfile
	) -> GeminiAgentToolPreferences.PermissionLevel {
		switch profile {
		case .userConfigured:
			return GeminiAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: securePermissions)
		case .mcpSafeDefaults:
			return .default
		case .providerOverride(.gemini(let level)):
			return level
		case .providerOverride:
			return .default
		}
	}

	private func effectiveOpenCodePermissionLevel(
		profile: AgentProviderPermissionProfile
	) -> OpenCodeAgentToolPreferences.PermissionLevel {
		switch profile {
		case .userConfigured:
			return OpenCodeAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: securePermissions)
		case .mcpSafeDefaults:
			return .managedDefault
		case .providerOverride(.openCode(let level)):
			return level
		case .providerOverride:
			return .managedDefault
		}
	}

	private func effectiveCursorPermissionLevel(
		profile: AgentProviderPermissionProfile
	) -> CursorAgentToolPreferences.PermissionLevel {
		switch profile {
		case .userConfigured:
			return CursorAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: securePermissions)
		case .mcpSafeDefaults:
			return .managedDefault
		case .providerOverride(.cursor(let level)):
			return level
		case .providerOverride:
			return .managedDefault
		}
	}

	private static func representativeAgent(for providerID: AgentProviderBindingID) -> DiscoverAgentKind {
		switch providerID {
		case .codex: return .codexExec
		case .claude: return .claudeCode
		case .gemini: return .gemini
		case .openCode: return .openCode
		case .cursor: return .cursor
		}
	}

	private func normalizedServerToggleKey(_ value: String) -> String {
		value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
	}
}
