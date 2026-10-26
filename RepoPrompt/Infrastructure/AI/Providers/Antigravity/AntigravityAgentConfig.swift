import Foundation

/// Configuration for an Antigravity ACP server run.
struct AntigravityAgentConfig {
	let serverPath: String
	let profileHomePath: String
	let modelString: String?
	let enableDebugLogging: Bool
	let includeRepoPromptMCPServer: Bool
	/// ACP auth method the run signs in with. Runs after sign-in leave this nil,
	/// because the server reads the stored sign-in from its profile settings.
	let authMethodID: String?

	init(
		serverPath: String = AntigravityServerInstaller.serverURL.path,
		profileHomePath: String = AntigravityIntegrationConfiguration.profileHomeURL.path,
		modelString: String? = nil,
		enableDebugLogging: Bool = false,
		includeRepoPromptMCPServer: Bool = true,
		authMethodID: String? = nil
	) {
		self.serverPath = serverPath
		self.profileHomePath = profileHomePath
		self.modelString = modelString
		self.enableDebugLogging = enableDebugLogging
		self.includeRepoPromptMCPServer = includeRepoPromptMCPServer
		self.authMethodID = authMethodID
	}
}
