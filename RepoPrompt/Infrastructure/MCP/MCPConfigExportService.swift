import Foundation

actor MCPConfigExportService {
	static let shared = MCPConfigExportService()

	static var discoveryConfigFileName: String {
		#if DEBUG
		return "discovery_debug.json"
		#else
		return "discovery.json"
		#endif
	}
	
	private init() {}
	
	@discardableResult
	func prepareConfigFile() async throws -> URL {
		let configJSON = try RepoPromptMCPServerConfiguration.repoPrompt.prettyPrintedWrappedSettingsJSON()
		let fm = FileManager.default
		let baseDir = fm.homeDirectoryForCurrentUser
			.appendingPathComponent("Library/Application Support/RepoPrompt/MCP", isDirectory: true)
		try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
		let configURL = baseDir.appendingPathComponent(Self.discoveryConfigFileName, isDirectory: false)
		try configJSON.write(to: configURL, atomically: true, encoding: .utf8)
		return configURL
	}

	func writeTempFile(prefix: String, contents: String) async throws -> URL {
		let fm = FileManager.default
		let baseDir = fm.temporaryDirectory.appendingPathComponent("RepoPromptDiscover", isDirectory: true)
		try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
		let fileURL = baseDir.appendingPathComponent("\(prefix)-\(UUID().uuidString).txt")
		try contents.write(to: fileURL, atomically: true, encoding: .utf8)
		return fileURL
	}
	
	func cleanupConfigFile(_ url: URL) {
		// Retain the config on disk for reuse between runs. No-op cleanup.
	}
	
	/// Prepares an empty MCP config file for use by ClaudeCodeProvider.
	/// This prevents the CLI from using the user's default MCP config, which may include RepoPrompt.
	@discardableResult
	func prepareEmptyConfigFile() async throws -> URL {
		let emptyConfigJSON = """
		{
			"mcpServers": {}
		}
		"""
		let fm = FileManager.default
		let baseDir = fm.homeDirectoryForCurrentUser
			.appendingPathComponent("Library/Application Support/RepoPrompt/MCP", isDirectory: true)
		try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
		let configURL = baseDir.appendingPathComponent("empty-config.json", isDirectory: false)
		try emptyConfigJSON.write(to: configURL, atomically: true, encoding: .utf8)
		return configURL
	}
}
