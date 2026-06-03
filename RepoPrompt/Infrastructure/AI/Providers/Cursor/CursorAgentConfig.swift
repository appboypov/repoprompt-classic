import Foundation

struct CursorAgentConfig: Sendable {
	static let promptOnlySessionModeID = "ask"

	let commandName: String
	let additionalPathHints: [String]
	let enableDebugLogging: Bool
	let modelString: String?
	let includeRepoPromptMCPServer: Bool
	let cleanupProjectMCPConfig: Bool
	let sessionModeID: String?

	init(
		commandName: String = "cursor-agent",
		additionalPathHints: [String] = CLIPathHints.cursor,
		enableDebugLogging: Bool = false,
		modelString: String? = nil,
		includeRepoPromptMCPServer: Bool = true,
		cleanupProjectMCPConfig: Bool = true,
		sessionModeID: String? = nil
	) {
		self.commandName = commandName
		self.additionalPathHints = additionalPathHints
		self.enableDebugLogging = enableDebugLogging
		self.modelString = modelString
		self.includeRepoPromptMCPServer = includeRepoPromptMCPServer
		self.cleanupProjectMCPConfig = cleanupProjectMCPConfig
		self.sessionModeID = sessionModeID
	}
}
