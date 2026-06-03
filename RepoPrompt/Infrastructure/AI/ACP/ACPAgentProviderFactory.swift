import Foundation

enum ACPAgentProviderFactory {
	static func makeProvider(
		for agentKind: DiscoverAgentKind,
		modelString: String?
	) -> (any ACPAgentProvider)? {
		switch agentKind {
		case .gemini:
			return GeminiACPAgentProvider(
				config: GeminiAgentConfig(
					modelString: modelString,
					enableDebugLogging: DiscoverAgentService.enableDebugLogging
				)
			)
		case .openCode:
			return OpenCodeACPAgentProvider(
				config: OpenCodeAgentConfig(
					modelString: modelString,
					enableDebugLogging: DiscoverAgentService.enableDebugLogging,
					toolProfile: .agentMode
				)
			)
		case .cursor:
			return CursorACPAgentProvider(
				config: CursorAgentConfig(
					enableDebugLogging: DiscoverAgentService.enableDebugLogging,
					modelString: modelString
				)
			)
		case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible, .codexExec:
			return nil
		}
	}
}
