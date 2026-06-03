import Foundation

/// Configuration for Gemini agent provider.
struct GeminiAgentConfig {
    let commandName: String
    let additionalPathHints: [String]
    let modelString: String?
    let enableDebugLogging: Bool
    let toolContext: MCPIntegrationHelper.CLIToolContext
    let includeRepoPromptMCPServer: Bool

	init(
		commandName: String = "gemini",
		additionalPathHints: [String] = CLIPathHints.gemini,
		modelString: String? = nil,
		enableDebugLogging: Bool = false,
		toolContext: MCPIntegrationHelper.CLIToolContext = .agentRun,
		includeRepoPromptMCPServer: Bool = true
	) {
        self.commandName = commandName
        self.additionalPathHints = additionalPathHints
        self.modelString = modelString
        self.enableDebugLogging = enableDebugLogging
        self.toolContext = toolContext
        self.includeRepoPromptMCPServer = includeRepoPromptMCPServer
    }
}
