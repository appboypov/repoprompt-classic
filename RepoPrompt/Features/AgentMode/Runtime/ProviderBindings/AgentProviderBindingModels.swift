import Foundation

extension CodexIntegrationConfiguration.ServerEntry: Equatable {
	static func == (
		lhs: CodexIntegrationConfiguration.ServerEntry,
		rhs: CodexIntegrationConfiguration.ServerEntry
	) -> Bool {
		lhs.rawName == rhs.rawName
			&& lhs.normalizedName == rhs.normalizedName
			&& lhs.cliPathComponent == rhs.cliPathComponent
	}
}

extension CodexIntegrationConfiguration.ServerEntry: @unchecked Sendable {}

enum AgentProviderPermissionLevelID: Hashable, Sendable {
	case codex(CodexAgentToolPreferences.PermissionLevel)
	case claude(ClaudeAgentToolPreferences.PermissionLevel)
	case gemini(GeminiAgentToolPreferences.PermissionLevel)
	case openCode(OpenCodeAgentToolPreferences.PermissionLevel)
	case cursor(CursorAgentToolPreferences.PermissionLevel)

	var providerID: AgentProviderBindingID {
		switch self {
		case .codex:
			return .codex
		case .claude:
			return .claude
		case .gemini:
			return .gemini
		case .openCode:
			return .openCode
		case .cursor:
			return .cursor
		}
	}

	static func subagentDefault(for providerID: AgentProviderBindingID) -> AgentProviderPermissionLevelID {
		switch providerID {
		case .codex:
			return .codex(.defaultPermission)
		case .claude:
			return .claude(.requireApproval)
		case .gemini:
			return .gemini(.default)
		case .openCode:
			return .openCode(.managedDefault)
		case .cursor:
			return .cursor(.managedDefault)
		}
	}

	static func options(for providerID: AgentProviderBindingID) -> [AgentProviderPermissionLevelID] {
		switch providerID {
		case .codex:
			return CodexAgentToolPreferences.PermissionLevel.allCases.map(AgentProviderPermissionLevelID.codex)
		case .claude:
			return ClaudeAgentToolPreferences.PermissionLevel.allCases.map(AgentProviderPermissionLevelID.claude)
		case .gemini:
			return GeminiAgentToolPreferences.PermissionLevel.allCases.map(AgentProviderPermissionLevelID.gemini)
		case .openCode:
			return OpenCodeAgentToolPreferences.PermissionLevel.allCases.map(AgentProviderPermissionLevelID.openCode)
		case .cursor:
			return CursorAgentToolPreferences.PermissionLevel.allCases.map(AgentProviderPermissionLevelID.cursor)
		}
	}

	init?(providerID: AgentProviderBindingID, subagentRawValue: String) {
		let raw = subagentRawValue.trimmingCharacters(in: .whitespacesAndNewlines)
		switch providerID {
		case .codex:
			guard let level = CodexAgentToolPreferences.PermissionLevel(rawValue: raw) else { return nil }
			self = .codex(level)
		case .claude:
			guard let level = ClaudeAgentToolPreferences.PermissionLevel(rawValue: raw) else { return nil }
			self = .claude(level)
		case .gemini:
			guard let level = GeminiAgentToolPreferences.PermissionLevel(rawValue: raw) else { return nil }
			self = .gemini(level)
		case .openCode:
			guard let level = OpenCodeAgentToolPreferences.PermissionLevel(rawValue: raw) else { return nil }
			self = .openCode(level)
		case .cursor:
			guard let level = CursorAgentToolPreferences.PermissionLevel(rawValue: raw) else { return nil }
			self = .cursor(level)
		}
	}

	var subagentRawValue: String {
		switch self {
		case .codex(let level):
			return level.rawValue
		case .claude(let level):
			return level.rawValue
		case .gemini(let level):
			return level.rawValue
		case .openCode(let level):
			return level.rawValue
		case .cursor(let level):
			return level.rawValue
		}
	}

	var displayName: String {
		switch self {
		case .codex(let level):
			return level.displayName
		case .claude(let level):
			return level.displayName
		case .gemini(let level):
			return level.displayName
		case .openCode(let level):
			return level.displayName
		case .cursor(let level):
			return level.displayName
		}
	}

	var iconName: String {
		switch self {
		case .codex(let level):
			return level.iconName
		case .claude(let level):
			return level.iconName
		case .gemini(let level):
			return level.iconName
		case .openCode(let level):
			return level.iconName
		case .cursor(let level):
			return level.iconName
		}
	}

	var detailText: String? {
		switch self {
		case .codex:
			return nil
		case .claude(let level):
			return level.detailText
		case .gemini:
			return nil
		case .openCode(let level):
			return level.detailText
		case .cursor(let level):
			return level.detailText
		}
	}

	var isWarning: Bool {
		switch self {
		case .codex(let level):
			return level.isWarning
		case .claude(let level):
			return level.isWarning
		case .gemini(let level):
			return level.isWarning
		case .openCode(let level):
			return level.isWarning
		case .cursor(let level):
			return level.isWarning
		}
	}
}

struct AgentPermissionOptionBinding: Identifiable, Equatable, Sendable {
	let id: AgentProviderPermissionLevelID
	let title: String
	let iconName: String
	let detailText: String?
	let isWarning: Bool
	let isSelected: Bool
	let isEnabled: Bool
}

struct AgentPermissionChromeBinding: Equatable, Sendable {
	let providerID: AgentProviderBindingID
	let displayName: String
	let iconName: String
	let isWarning: Bool
	let externallyManagedReason: String?
	let options: [AgentPermissionOptionBinding]
}

struct AgentProviderRuntimePermissionBinding: Equatable, Sendable {
	let codexSandboxMode: CodexAgentToolPreferences.SandboxMode?
	let codexApprovalPolicy: CodexAgentToolPreferences.ApprovalPolicy?
	let codexApprovalReviewer: CodexAgentToolPreferences.ApprovalReviewer?
	let claudePermissionMode: String?
	let acpSessionModeID: String?
	let autoApproveAllACPToolPermissions: Bool
	let acceptsPendingACPApprovalWhenActivated: Bool

	init(
		codexSandboxMode: CodexAgentToolPreferences.SandboxMode? = nil,
		codexApprovalPolicy: CodexAgentToolPreferences.ApprovalPolicy? = nil,
		codexApprovalReviewer: CodexAgentToolPreferences.ApprovalReviewer? = nil,
		claudePermissionMode: String? = nil,
		acpSessionModeID: String? = nil,
		autoApproveAllACPToolPermissions: Bool = false,
		acceptsPendingACPApprovalWhenActivated: Bool = false
	) {
		self.codexSandboxMode = codexSandboxMode
		self.codexApprovalPolicy = codexApprovalPolicy
		self.codexApprovalReviewer = codexApprovalReviewer
		self.claudePermissionMode = claudePermissionMode
		self.acpSessionModeID = acpSessionModeID
		self.autoApproveAllACPToolPermissions = autoApproveAllACPToolPermissions
		self.acceptsPendingACPApprovalWhenActivated = acceptsPendingACPApprovalWhenActivated
	}
}


/// Persisted Codex tool preference snapshot for editing/display.
///
/// Permission profiles are applied through `AgentProviderRuntimePermissionBinding`; these
/// values intentionally mirror existing UserDefaults-backed tool preferences even when a
/// caller is rendering an externally managed or MCP-safe permission profile.
struct CodexToolSettingsBinding: Equatable, Sendable {
	let bashToolEnabled: Bool
	let searchToolEnabled: Bool
	let goalSupportEnabled: Bool
	let mcpServerEntries: [MCPIntegrationHelper.CodexServerEntry]
	/// Keys are lowercased/trimmed toggle keys derived from each entry's normalized name,
	/// matching the current AgentInputBar lookup convention.
	let mcpServerStatesByNormalizedName: [String: Bool]
}

/// Persisted Claude tool preference snapshot for editing/display.
///
/// Permission profiles are applied through `AgentProviderRuntimePermissionBinding`; these
/// values intentionally mirror existing UserDefaults-backed tool preferences even when a
/// caller is rendering an externally managed or MCP-safe permission profile. `effortLevel`
/// is resolved for the selected model when a model context is available.
struct ClaudeToolSettingsBinding: Equatable, Sendable {
	let bashToolEnabled: Bool
	let mcpStrictModeEnabled: Bool
	let toolSearchEnabled: Bool
	let effortLevel: ClaudeCodeEffortLevel
	let agentModePromptDelivery: ClaudeAgentToolPreferences.AgentModePromptDelivery
}

/// Complete provider controls snapshot for the selected agent/provider.
///
/// `runtimePermission` is the profile-aware launch/runtime contract. Provider-specific
/// tool snapshots are Settings/editing snapshots for direct provider controls; callers
/// that are only previewing sub-agent policy should prefer capability summaries unless
/// they explicitly need a runtime binding.
struct AgentProviderControlsBinding: Equatable, Sendable {
	let revision: Int
	let selectedAgent: DiscoverAgentKind
	let providerID: AgentProviderBindingID
	let permission: AgentPermissionChromeBinding
	let runtimePermission: AgentProviderRuntimePermissionBinding
	let codexTools: CodexToolSettingsBinding?
	let claudeTools: ClaudeToolSettingsBinding?
}
