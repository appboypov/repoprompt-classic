import Foundation

/// Source of effective provider permissions for Agent Mode runs.
///
/// User-configured runs read the existing provider preference wrappers. MCP-originated
/// runs use the sub-agent permission policy: Safe Managed by default, optional inherited
/// provider settings, or one concrete provider-native override without mutating direct-agent
/// preferences.
enum AgentProviderPermissionProfile: Sendable, Equatable {
	case userConfigured
	case mcpSafeDefaults
	case providerOverride(AgentProviderPermissionLevelID)
}

// MARK: - Compatibility helpers

extension AgentProviderPermissionProfile {
	var codexSandboxMode: CodexAgentToolPreferences.SandboxMode {
		switch self {
		case .userConfigured:
			CodexAgentToolPreferences.sandboxMode()
		case .mcpSafeDefaults:
			CodexAgentToolPreferences.PermissionLevel.defaultPermission.sandboxMode
		case .providerOverride(.codex(let level)):
			level.sandboxMode
		case .providerOverride:
			CodexAgentToolPreferences.PermissionLevel.defaultPermission.sandboxMode
		}
	}

	var codexApprovalPolicy: CodexAgentToolPreferences.ApprovalPolicy {
		switch self {
		case .userConfigured:
			CodexAgentToolPreferences.approvalPolicy()
		case .mcpSafeDefaults:
			CodexAgentToolPreferences.PermissionLevel.defaultPermission.approvalPolicy
		case .providerOverride(.codex(let level)):
			level.approvalPolicy
		case .providerOverride:
			CodexAgentToolPreferences.PermissionLevel.defaultPermission.approvalPolicy
		}
	}

	var codexApprovalReviewer: CodexAgentToolPreferences.ApprovalReviewer {
		switch self {
		case .userConfigured:
			CodexAgentToolPreferences.approvalReviewer()
		case .mcpSafeDefaults:
			CodexAgentToolPreferences.PermissionLevel.defaultPermission.approvalReviewer
		case .providerOverride(.codex(let level)):
			level.approvalReviewer
		case .providerOverride:
			CodexAgentToolPreferences.PermissionLevel.defaultPermission.approvalReviewer
		}
	}

	func codexPermissionLevel(
		userConfigured: CodexAgentToolPreferences.PermissionLevel = CodexAgentToolPreferences.permissionLevel()
	) -> CodexAgentToolPreferences.PermissionLevel {
		switch self {
		case .userConfigured: return userConfigured
		case .mcpSafeDefaults: return .defaultPermission
		case .providerOverride(.codex(let level)): return level
		case .providerOverride: return .defaultPermission
		}
	}

	var claudePermissionMode: String {
		switch self {
		case .userConfigured:
			ClaudeAgentToolPreferences.permissionMode()
		case .mcpSafeDefaults:
			ClaudeAgentToolPreferences.PermissionLevel.requireApproval.permissionMode
		case .providerOverride(.claude(let level)):
			level.permissionMode
		case .providerOverride:
			ClaudeAgentToolPreferences.PermissionLevel.requireApproval.permissionMode
		}
	}

	func claudePermissionLevel(
		userConfigured: ClaudeAgentToolPreferences.PermissionLevel = ClaudeAgentToolPreferences.permissionLevel()
	) -> ClaudeAgentToolPreferences.PermissionLevel {
		switch self {
		case .userConfigured: return userConfigured
		case .mcpSafeDefaults: return .requireApproval
		case .providerOverride(.claude(let level)): return level
		case .providerOverride: return .requireApproval
		}
	}

	var geminiSessionModeID: String {
		switch self {
		case .userConfigured:
			GeminiAgentToolPreferences.sessionModeID()
		case .mcpSafeDefaults:
			GeminiAgentToolPreferences.PermissionLevel.default.sessionModeID
		case .providerOverride(.gemini(let level)):
			level.sessionModeID
		case .providerOverride:
			GeminiAgentToolPreferences.PermissionLevel.default.sessionModeID
		}
	}

	func geminiPermissionLevel(
		userConfigured: GeminiAgentToolPreferences.PermissionLevel = GeminiAgentToolPreferences.permissionLevel()
	) -> GeminiAgentToolPreferences.PermissionLevel {
		switch self {
		case .userConfigured: return userConfigured
		case .mcpSafeDefaults: return .default
		case .providerOverride(.gemini(let level)): return level
		case .providerOverride: return .default
		}
	}

	var openCodeSessionModeID: String {
		switch self {
		case .userConfigured:
			OpenCodeAgentToolPreferences.sessionModeID()
		case .mcpSafeDefaults:
			OpenCodeAgentToolPreferences.PermissionLevel.managedDefault.sessionModeID
		case .providerOverride(.openCode(let level)):
			level.sessionModeID
		case .providerOverride:
			OpenCodeAgentToolPreferences.PermissionLevel.managedDefault.sessionModeID
		}
	}

	func openCodePermissionLevel(
		userConfigured: OpenCodeAgentToolPreferences.PermissionLevel = OpenCodeAgentToolPreferences.permissionLevel()
	) -> OpenCodeAgentToolPreferences.PermissionLevel {
		switch self {
		case .userConfigured: return userConfigured
		case .mcpSafeDefaults: return .managedDefault
		case .providerOverride(.openCode(let level)): return level
		case .providerOverride: return .managedDefault
		}
	}

	func cursorPermissionLevel(
		userConfigured: CursorAgentToolPreferences.PermissionLevel = CursorAgentToolPreferences.permissionLevel()
	) -> CursorAgentToolPreferences.PermissionLevel {
		switch self {
		case .userConfigured: return userConfigured
		case .mcpSafeDefaults: return .managedDefault
		case .providerOverride(.cursor(let level)): return level
		case .providerOverride: return .managedDefault
		}
	}

	func acpSessionModeID(for agent: DiscoverAgentKind) -> String? {
		switch agent {
		case .gemini:
			return geminiSessionModeID
		case .openCode:
			return openCodeSessionModeID
		case .cursor:
			return nil
		case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible, .codexExec:
			return nil
		}
	}
}
