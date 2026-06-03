//
//  AgentPermissionCapabilitySummaryBuilder.swift
//  RepoPrompt
//
//  Shared provider capability summaries for direct-agent settings and sub-agent
//  Safe Managed previews.
//

import Foundation

/// Summary DTO consumed by Agent Permissions settings surfaces to render a capability
/// row for each CLI provider.
///
/// These summaries describe effective capabilities for the supplied permission profile.
/// They intentionally stop short of claiming MCP tool ACLs or role-based tool
/// enforcement — those are separate MCP policy concerns.
struct AgentPermissionCapabilitySummary: Identifiable, Equatable {
	let providerID: AgentProviderBindingID
	let providerName: String
	let isAvailable: Bool
	let fileMutation: String
	let shell: String
	let externalMCP: String
	let search: String
	let approvalModeDescription: String
	let warnings: [String]

	var id: AgentProviderBindingID { providerID }
}

struct AgentPermissionCapabilitySummaryBuilder {
	let defaults: UserDefaults
	let securePermissions: AgentPermissionSecureStore?

	init(
		defaults: UserDefaults = .standard,
		securePermissions: AgentPermissionSecureStore? = nil
	) {
		self.defaults = defaults
		self.securePermissions = securePermissions ?? (defaults === UserDefaults.standard ? AgentPermissionSecureStore.shared : nil)
	}

	func summary(
		for providerID: AgentProviderBindingID,
		profile: AgentProviderPermissionProfile,
		availability: AgentModelCatalog.AvailabilityContext
	) -> AgentPermissionCapabilitySummary {
		let isAvailable = Self.isAvailable(providerID: providerID, availability: availability)
		let safeManaged = isSafeManaged(profile)

		switch providerID {
		case .codex:
			let bash: Bool
			let approval: String
			let sandbox: String
			let warnings: [String]
			switch profile {
			case .userConfigured:
				bash = CodexAgentToolPreferences.bashToolEnabled(defaults: defaults, secureStore: securePermissions)
				let approvalPolicy = CodexAgentToolPreferences.approvalPolicy(defaults: defaults, secureStore: securePermissions)
				let sandboxMode = CodexAgentToolPreferences.sandboxMode(defaults: defaults, secureStore: securePermissions)
				let approvalReviewer = CodexAgentToolPreferences.approvalReviewer(defaults: defaults, secureStore: securePermissions)
				approval = approvalReviewer == .autoReview ? approvalReviewer.displayName : approvalPolicy.displayName
				sandbox = sandboxMode.displayName
				warnings = sandboxMode == .dangerFullAccess
					? ["Sandbox is Danger Full Access — agents can modify files outside the workspace."]
					: []
			case .mcpSafeDefaults:
				bash = false
				approval = CodexAgentToolPreferences.PermissionLevel.defaultPermission.approvalPolicy.displayName
				sandbox = CodexAgentToolPreferences.PermissionLevel.defaultPermission.sandboxMode.displayName
				warnings = []
			case .providerOverride:
				let level = codexPermissionLevel(profile: profile)
				bash = CodexAgentToolPreferences.bashToolEnabled(defaults: defaults, secureStore: securePermissions)
				approval = level == .autoReview ? level.displayName : level.approvalPolicy.displayName
				sandbox = level.sandboxMode.displayName
				warnings = level == .fullAccess
					? ["Sandbox is Danger Full Access — agents can modify files outside the workspace."]
					: []
			}
			return AgentPermissionCapabilitySummary(
				providerID: providerID,
				providerName: providerID.displayName,
				isAvailable: isAvailable,
				fileMutation: "Sandbox: \(sandbox)",
				shell: bash ? "Bash enabled" : "Bash disabled",
				externalMCP: safeManaged
					? "Third-party MCP: suppressed"
					: "Third-party MCP: per-server (off by default)",
				search: CodexAgentToolPreferences.searchToolEnabled(defaults: defaults)
					? "Web search allowed"
					: "Web search disabled",
				approvalModeDescription: "Approval: \(approval)",
				warnings: warnings
			)
		case .claude:
			let permissionMode: String
			let bash: Bool
			let strict: Bool
			let warnings: [String]
			switch profile {
			case .userConfigured:
				let level = ClaudeAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: securePermissions)
				permissionMode = level.displayName
				bash = ClaudeAgentToolPreferences.bashToolEnabled(defaults: defaults, secureStore: securePermissions)
				strict = ClaudeAgentToolPreferences.mcpStrictModeEnabled(defaults: defaults, secureStore: securePermissions)
				warnings = level == .fullAccess
					? ["Permission mode is Full Access — tools run without approval."]
					: []
			case .mcpSafeDefaults:
				permissionMode = ClaudeAgentToolPreferences.PermissionLevel.requireApproval.displayName
				bash = false
				strict = true
				warnings = []
			case .providerOverride:
				let level = claudePermissionLevel(profile: profile)
				permissionMode = level.displayName
				bash = ClaudeAgentToolPreferences.bashToolEnabled(defaults: defaults, secureStore: securePermissions)
				strict = ClaudeAgentToolPreferences.mcpStrictModeEnabled(defaults: defaults, secureStore: securePermissions)
				warnings = level == .fullAccess
					? ["Permission mode is Full Access — tools run without approval."]
					: []
			}
			return AgentPermissionCapabilitySummary(
				providerID: providerID,
				providerName: providerID.displayName,
				isAvailable: isAvailable,
				fileMutation: "Permission mode: \(permissionMode)",
				shell: bash ? "Bash enabled" : "Bash disabled",
				externalMCP: strict
					? "Third-party MCP: RepoPrompt only"
					: "Third-party MCP: all servers",
				search: ClaudeAgentToolPreferences.toolSearchEnabled(defaults: defaults)
					? "Tool search allowed"
					: "Tool search disabled",
				approvalModeDescription: "Permission mode: \(permissionMode)",
				warnings: warnings
			)
		case .gemini:
			let level = geminiPermissionLevel(profile: profile)
			let warnings = level == .fullAccess
				? ["Gemini session mode is Full Access — tool calls auto-accept."]
				: []
			return AgentPermissionCapabilitySummary(
				providerID: providerID,
				providerName: providerID.displayName,
				isAvailable: isAvailable,
				fileMutation: "ACP session mode: \(level.displayName)",
				shell: "Handled by Gemini CLI",
				externalMCP: "Third-party MCP: not supported",
				search: "Managed by Gemini CLI",
				approvalModeDescription: "Auto-accept: \(level == .fullAccess ? "on" : "off")",
				warnings: warnings
			)
		case .openCode:
			let level = openCodePermissionLevel(profile: profile)
			let warnings = level == .fullAccess
				? ["OpenCode session mode is Full Access — tool calls auto-accept."]
				: []
			return AgentPermissionCapabilitySummary(
				providerID: providerID,
				providerName: providerID.displayName,
				isAvailable: isAvailable,
				fileMutation: "ACP session mode: \(level.displayName)",
				shell: "Handled by OpenCode",
				externalMCP: "Third-party MCP: not supported",
				search: "Managed by OpenCode",
				approvalModeDescription: "Auto-accept: \(level.acceptsPendingApprovalWhenActivated ? "on" : "off")",
				warnings: warnings
			)
		case .cursor:
			let level = cursorPermissionLevel(profile: profile)
			let warnings = level == .fullAccess
				? ["Cursor auto-approves all ACP tool permissions."]
				: []
			return AgentPermissionCapabilitySummary(
				providerID: providerID,
				providerName: providerID.displayName,
				isAvailable: isAvailable,
				fileMutation: "Auto-approve ACP tools: \(level.autoApprovesACPToolPermissions ? "on" : "off")",
				shell: "Handled by Cursor CLI",
				externalMCP: "Third-party MCP: not supported",
				search: "Managed by Cursor CLI",
				approvalModeDescription: level.autoApprovesACPToolPermissions ? "Auto-approve: on" : "Auto-approve: off",
				warnings: warnings
			)
		}
	}

	func summaries(
		profile: AgentProviderPermissionProfile,
		availability: AgentModelCatalog.AvailabilityContext
	) -> [AgentPermissionCapabilitySummary] {
		AgentProviderBindingID.allCases.map {
			summary(for: $0, profile: profile, availability: availability)
		}
	}

	static func isAvailable(
		providerID: AgentProviderBindingID,
		availability: AgentModelCatalog.AvailabilityContext
	) -> Bool {
		switch providerID {
		case .codex: return availability.codexAvailable
		case .claude: return availability.claudeCodeAvailable
		case .gemini: return availability.geminiAvailable
		case .openCode: return availability.openCodeAvailable
		case .cursor: return availability.cursorAvailable
		}
	}

	private func isSafeManaged(_ profile: AgentProviderPermissionProfile) -> Bool {
		if case .mcpSafeDefaults = profile {
			return true
		}
		return false
	}

	private func codexPermissionLevel(profile: AgentProviderPermissionProfile) -> CodexAgentToolPreferences.PermissionLevel {
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

	private func claudePermissionLevel(profile: AgentProviderPermissionProfile) -> ClaudeAgentToolPreferences.PermissionLevel {
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

	private func geminiPermissionLevel(profile: AgentProviderPermissionProfile) -> GeminiAgentToolPreferences.PermissionLevel {
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

	private func openCodePermissionLevel(profile: AgentProviderPermissionProfile) -> OpenCodeAgentToolPreferences.PermissionLevel {
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

	private func cursorPermissionLevel(profile: AgentProviderPermissionProfile) -> CursorAgentToolPreferences.PermissionLevel {
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
}
