import Foundation

enum AgentProviderBindingID: String, CaseIterable, Hashable, Sendable {
	case codex
	case claude
	case antigravity
	case openCode
	case cursor

	var displayName: String {
		switch self {
		case .codex:
			return "Codex CLI"
		case .claude:
			return "Claude Code"
		case .antigravity:
			return "Antigravity"
		case .openCode:
			return "OpenCode"
		case .cursor:
			return "Cursor CLI"
		}
	}
}

extension DiscoverAgentKind {
	var providerBindingID: AgentProviderBindingID {
		switch self {
		case .codexExec:
			return .codex
		case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
			return .claude
		case .antigravity:
			return .antigravity
		case .openCode:
			return .openCode
		case .cursor:
			return .cursor
		}
	}
}
