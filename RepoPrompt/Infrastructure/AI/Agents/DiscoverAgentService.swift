import Foundation
import Logging

enum ClaudeCodeRuntimeVariant: String, Sendable {
	case standard
	case glm
	case kimi
	case customCompatible

	var compatibleBackendID: ClaudeCodeCompatibleBackendID? {
		switch self {
		case .standard:
			return nil
		case .glm:
			return .glmZAI
		case .kimi:
			return .kimi
		case .customCompatible:
			return .custom
		}
	}

	var agentKind: DiscoverAgentKind {
		switch self {
		case .standard:
			return .claudeCode
		case .glm:
			return .claudeCodeGLM
		case .kimi:
			return .kimiCode
		case .customCompatible:
			return .customClaudeCompatible
		}
	}
}

/// Supported autonomous agents for the Discover workflow.
enum DiscoverAgentKind: String, CaseIterable, Hashable, Sendable {
	case claudeCode
	case codexExec
	case gemini
	case openCode
	case cursor
	case claudeCodeGLM
	case kimiCode
	case customClaudeCompatible

	static let claudeMCPClientID = "claude-code"
	static let codexMCPClientID = "codex-mcp-client"
	static let geminiMCPClientID = "gemini-cli-mcp-client"
	static let openCodeMCPClientID = "opencode"
	static let cursorMCPClientID = "cursor"

	var commandName: String {
		switch self {
		case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
			return "claude"
		case .codexExec:
			return "codex"
		case .gemini:
			return "gemini"
		case .openCode:
			return "opencode"
		case .cursor:
			return "cursor-agent"
		}
	}

	var displayName: String {
		switch self {
		case .claudeCode:
			return "Claude Code"
		case .codexExec:
			return "Codex CLI"
		case .gemini:
			return "Gemini CLI"
		case .openCode:
			return "OpenCode"
		case .cursor:
			return "Cursor CLI"
		case .claudeCodeGLM:
			return ClaudeCodeCompatibleBackendStore.shared.config(for: .glmZAI).normalizedDisplayName
		case .kimiCode:
			return ClaudeCodeCompatibleBackendStore.shared.config(for: .kimi).normalizedDisplayName
		case .customClaudeCompatible:
			return ClaudeCodeCompatibleBackendStore.shared.config(for: .custom).normalizedDisplayName
		}
	}

	var mcpClientNameHint: String? {
		switch self {
		case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
			return Self.claudeMCPClientID
		case .codexExec:
			return Self.codexMCPClientID
		case .gemini:
			return Self.geminiMCPClientID
		case .openCode:
			return Self.openCodeMCPClientID
		case .cursor:
			return Self.cursorMCPClientID
		}
	}

	var acpProviderID: ACPProviderID? {
		switch self {
		case .gemini:
			return .gemini
		case .openCode:
			return .openCode
		case .cursor:
			return .cursor
		case .claudeCode, .codexExec, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
			return nil
		}
	}

	var usesClaudeNativeRuntime: Bool {
		switch self {
		case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
			return true
		case .codexExec, .gemini, .openCode, .cursor:
			return false
		}
	}

	var usesClaudeTooling: Bool {
		usesClaudeNativeRuntime
	}

	var requiresExpectedPIDOwnedAgentModeMCPRouting: Bool {
		switch self {
		case .claudeCode, .codexExec, .gemini, .openCode, .cursor, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
			return true
		}
	}

	/// Human-readable description for MCP discovery (list_agents).
	var agentDescription: String {
		switch self {
		case .claudeCode:
			return "Anthropic's Claude Code agent. Strong at general-purpose development, code understanding, architecture, and open-ended reasoning tasks."
		case .codexExec:
			return "OpenAI's Codex CLI agent. Optimized for tool-driven engineering workflows. Supports configurable reasoning effort levels per model."
		case .gemini:
			return "Google's Gemini CLI agent. Good for fast exploration, repository reading, and lightweight tasks."
		case .openCode:
			return "OpenCode ACP agent. Interactive Agent Mode uses RepoPrompt MCP tools; headless discovery/delegate runs use RepoPrompt's managed no-native-tools mode."
		case .cursor:
			return "Cursor CLI ACP agent. Uses Cursor's ACP runtime and injects RepoPrompt MCP tools through ACP session configuration."
		case .claudeCodeGLM:
			let config = ClaudeCodeCompatibleBackendStore.shared.config(for: .glmZAI)
			if case .claudeSlotMapping(let mapping) = config.modelBehavior {
				let normalized = mapping.normalized
				return "Claude Code routed through the GLM integration. Slots: Haiku → \(normalized.haiku), Sonnet → \(normalized.sonnet), Opus → \(normalized.opus)."
			}
			return "Claude Code routed through the GLM integration for teams using that provider configuration."
		case .kimiCode:
			return "Claude Code routed through Kimi's Claude-compatible coding backend. Uses Kimi's no-model launch behavior."
		case .customClaudeCompatible:
			let config = ClaudeCodeCompatibleBackendStore.shared.config(for: .custom)
			switch config.modelBehavior {
			case .noModel:
				return "Claude Code routed through a custom Claude-compatible backend using no model flag."
			case .claudeSlotMapping(let mapping):
				let normalized = mapping.normalized
				return "Claude Code routed through a custom Claude-compatible backend. Slots: Haiku → \(normalized.haiku), Sonnet → \(normalized.sonnet), Opus → \(normalized.opus)."
			}
		}
	}

	/// Stable runtime kind identifier for MCP discovery (list_agents).
	var runtimeKind: String {
		switch self {
		case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
			return "claude_native"
		case .codexExec:
			return "codex_native"
		case .gemini:
			return "headless"
		case .openCode:
			return "opencode_acp"
		case .cursor:
			return "cursor_acp"
		}
	}

	var claudeRuntimeVariant: ClaudeCodeRuntimeVariant? {
		switch self {
		case .claudeCode:
			return .standard
		case .claudeCodeGLM:
			return .glm
		case .kimiCode:
			return .kimi
		case .customClaudeCompatible:
			return .customCompatible
		case .codexExec, .gemini, .openCode, .cursor:
			return nil
		}
	}
}

/// Factory/service responsible for instantiating discover agents.
final class DiscoverAgentService {
	static let shared = DiscoverAgentService()

	/// Enable debug logging for Discover Agent (enabled for debugging cancellation)
	static var enableDebugLogging = false
	private static let logger = Logger(label: "com.repoprompt.discover.agent")

	private init() {}

	/// Create a headless agent provider.
	/// - Parameters:
	///   - agent: The agent kind to create
	///   - modelString: Optional model string override
	///   - runType: The type of run (discovery or delegateEdit) — determines CLI tool config
	/// - Note: MCP tool restrictions are handled via ServerNetworkManager connection policies,
	///   not via CLI flags. Use installClientConnectionPolicy before starting the agent run.
	/// - Important: Gemini, OpenCode, and Cursor use their ACP runtimes for headless
	///   discovery while keeping broader chat-provider wiring separate.
	func makeProvider(
		for agent: DiscoverAgentKind,
		modelString: String? = nil,
		runType: AgentRunType = .discover,
		workspacePath: String? = nil
	) -> HeadlessAgentProvider {
		if Self.enableDebugLogging {
			Self.logger.debug("Creating provider for agent: \(agent.displayName), model: \(modelString ?? "default"), runType: \(String(describing: runType))")
		}
		switch agent {
		case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
			let runtimeVariant = agent.claudeRuntimeVariant ?? .standard
			let config: ClaudeCodeAgentConfig = switch runType {
			case .discover:
				.discovery(modelString: modelString, runtimeVariant: runtimeVariant, enableDebugLogging: Self.enableDebugLogging)
			case .delegateEdit:
				.delegateEdit(modelString: modelString, runtimeVariant: runtimeVariant, enableDebugLogging: Self.enableDebugLogging)
			}
			var processConfig = CLIProcessConfiguration(
				command: config.commandName,
				enableDebugLogging: Self.enableDebugLogging,
				captureStdoutTailBytes: 128 * 1024,
				captureStderrTailBytes: 256 * 1024,
				logStdinSampleBytes: 0
			)
			processConfig.ensureAdditionalPaths(config.additionalPathHints)
			let runner = CLIProcessRunner(config: processConfig)
			if Self.enableDebugLogging {
				Self.logger.debug("Created ClaudeCodeAgentProvider")
			}
			return ClaudeCodeAgentProvider(runner: runner, config: config)
		case .codexExec:
			let config = CodexExecAgentConfig(
				modelString: modelString,
				enableDebugLogging: Self.enableDebugLogging
			)
			var processConfig = CLIProcessConfiguration(
				command: config.commandName,
				enableDebugLogging: Self.enableDebugLogging,
				captureStdoutTailBytes: 128 * 1024,
				captureStderrTailBytes: 256 * 1024,
				logStdinSampleBytes: 0
			)
			processConfig.ensureAdditionalPaths(config.additionalPathHints)
			let runner = CLIProcessRunner(config: processConfig)
			if Self.enableDebugLogging {
				Self.logger.debug("Created CodexExecAgentProvider")
			}
			return CodexExecAgentProvider(runner: runner, config: config)
		case .gemini:
			let config = GeminiAgentConfig(
				commandName: agent.commandName,
				modelString: modelString,
				enableDebugLogging: Self.enableDebugLogging,
				toolContext: .agentRun,
				includeRepoPromptMCPServer: true
			)
			if Self.enableDebugLogging {
				Self.logger.debug("Created GeminiACPHeadlessAgentProvider")
			}
			return GeminiACPHeadlessAgentProvider(config: config, workspacePath: workspacePath)
		case .openCode:
			let config = OpenCodeAgentConfig(
				modelString: modelString,
				enableDebugLogging: Self.enableDebugLogging,
				toolProfile: .headless
			)
			if Self.enableDebugLogging {
				Self.logger.debug("Created OpenCodeACPHeadlessAgentProvider")
			}
			return OpenCodeACPHeadlessAgentProvider(config: config, workspacePath: workspacePath)
		case .cursor:
			let config = CursorAgentConfig(
				commandName: agent.commandName,
				enableDebugLogging: Self.enableDebugLogging,
				modelString: modelString,
				includeRepoPromptMCPServer: true,
				cleanupProjectMCPConfig: true
			)
			if Self.enableDebugLogging {
				Self.logger.debug("Created CursorACPHeadlessAgentProvider")
			}
			return CursorACPHeadlessAgentProvider(config: config, workspacePath: workspacePath)
		}
	}
}
