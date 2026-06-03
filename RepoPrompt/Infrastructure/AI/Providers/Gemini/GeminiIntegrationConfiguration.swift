import Foundation

/// Gemini-specific integration configuration helpers.
///
/// This namespace owns Gemini CLI settings.json installation, RepoPrompt-managed
/// system settings overlays, policy TOML generation, and native tool exclusions.
enum GeminiIntegrationConfiguration {
	/// Environment variable key used by gemini-cli to override system settings path.
	/// System settings have highest priority and override user settings.
	static let systemSettingsEnvKey = "GEMINI_CLI_SYSTEM_SETTINGS_PATH"

	private static let repoPromptMCPConfiguration = RepoPromptMCPServerConfiguration.repoPrompt
	private static let repoPromptMCPServerName = RepoPromptMCPServerConfiguration.defaultServerName

	static func configDirectoryURL() -> URL {
		let home = FileManager.default.homeDirectoryForCurrentUser
		return home.appendingPathComponent(".gemini", isDirectory: true)
	}

	static func settingsURL() -> URL {
		configDirectoryURL().appendingPathComponent("settings.json")
	}

	@discardableResult
	static func ensureServerForDiscovery() -> (success: Bool, wasAlreadyPresent: Bool) {
		let fm = FileManager.default
		let dirURL = configDirectoryURL()
		let settingsURL = settingsURL()

		do {
			try fm.createDirectory(at: dirURL, withIntermediateDirectories: true, attributes: nil)

			let fileExists = fm.fileExists(atPath: settingsURL.path)
			var root: [String: Any] = [:]
			if fileExists,
				let data = try? Data(contentsOf: settingsURL),
				let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
				root = json
			}

			var servers = root["mcpServers"] as? [String: Any] ?? [:]
			let existingEntry = servers[repoPromptMCPServerName] as? [String: Any]
			let wasAlreadyPresent = existingEntry != nil
			let entriesMatch: Bool
			if let existingEntry {
				entriesMatch = NSDictionary(dictionary: existingEntry).isEqual(to: repoPromptMCPConfiguration.settingsJSONObject)
			} else {
				entriesMatch = false
			}
			let needsWrite = !fileExists || !entriesMatch

			servers[repoPromptMCPServerName] = repoPromptMCPConfiguration.settingsJSONObject
			root["mcpServers"] = servers

			if needsWrite {
				let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
				try data.write(to: settingsURL, options: .atomic)
			}

			return (true, wasAlreadyPresent)
		} catch {
			print("GeminiIntegrationConfiguration – Gemini ensure failed: \(error)")
			return (false, false)
		}
	}

	static func configContainsRepoPrompt() -> Bool {
		let settingsURL = settingsURL()
		guard let data = try? Data(contentsOf: settingsURL),
			let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			let servers = json["mcpServers"] as? [String: Any]
		else {
			return false
		}

		return servers.keys.contains {
			$0.compare(repoPromptMCPServerName, options: .caseInsensitive) == .orderedSame
		}
	}

	@discardableResult
	static func installPersistentMCPConfig() -> (success: Bool, wasAlreadyPresent: Bool) {
		ensureServerForDiscovery()
	}

	// MARK: - Gemini Tool Exclusion Lists

	/// Built-in Gemini tools to exclude during ACP agent runs.
	/// Tool names from: gemini-cli/packages/core/src/tools/definitions/base-declarations.ts
	///
	/// Allowed (not in this list):
	///   read_file                       — useful alongside RepoPrompt MCP tools
	///   run_shell_command               — gated by ACP approval flow
	///   list_background_processes       — manages background shell jobs
	///   read_background_output          — reads background shell output
	///   ask_user                        — user interaction (ACP-routed)
	///   complete_task                   — task completion signal
	///   google_web_search              — web search (gated by approval)
	///   activate_skill                 — skill activation
	private static let agentExcludedTools: [String] = [
		// File mutation — handled by RepoPrompt MCP tools
		"write_file",
		"replace",
		"read_many_files",
		// Directory/search — handled by RepoPrompt MCP tools
		"list_directory",
		"glob",
		"grep_search",
		"search_file_content",
		// Web — web_fetch not needed; google_web_search allowed (gated by approval)
		"web_fetch",
		// Memory/state — managed by RepoPrompt
		"save_memory",
		"write_todos",
		// Agent sub-features — not applicable in RepoPrompt context
		"codebase_investigator",
		"get_internal_docs",
		"enter_plan_mode",
		"exit_plan_mode",
		"update_topic",
		"cli_help",
		// Task tracker — not used in RepoPrompt agent mode
		"tracker_create_task",
		"tracker_update_task",
		"tracker_get_task",
		"tracker_list_tasks",
		"tracker_add_dependency",
		"tracker_visualize",
		// Sub-agent — not applicable in RepoPrompt context
		"generalist"
	]

	/// Additional tools to exclude during discovery and delegate-edit runs.
	/// These modes are headless and should not invoke shell, sub-agents, or skills.
	private static let discoverDelegateExtraExcludedTools: [String] = [
		"run_shell_command",
		"activate_skill"
	]

	/// Built-in Gemini tools to exclude during interactive terminal sessions.
	/// More permissive than agent runs - allows bash/shell but blocks file editing.
	private static let terminalExcludedTools: [String] = [
		"write_file",           // File writing
		"list_directory",       // Directory listing (ls)
		"glob",                 // File pattern matching
		"replace",              // File editing
		"search_file_content",  // Content search (grep)
		"read_many_files"       // Batch file reading
	]

	/// Returns excluded tools for the given Gemini context
	static func excludedTools(for context: AgentCLIToolContext) -> [String] {
		switch context {
		case .agentRun:
			return agentExcludedTools
		case .discoverRun, .delegateEdit:
			return agentExcludedTools + discoverDelegateExtraExcludedTools
		case .promptOnly:
			return agentExcludedTools + terminalExcludedTools.filter { !agentExcludedTools.contains($0) }
		case .terminal:
			return terminalExcludedTools
		}
	}

	static func policyFileURL(
		for context: AgentCLIToolContext,
		includeRepoPromptMCPAllowance: Bool
	) throws -> URL {
		let fm = FileManager.default
		let appSupportURL = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
		let repoPromptDir = appSupportURL.appendingPathComponent("RepoPrompt", isDirectory: true)

		let filename: String
		switch context {
		case .agentRun, .discoverRun, .delegateEdit:
			filename = includeRepoPromptMCPAllowance
				? "gemini-agent-policy.toml"
				: "gemini-agent-acp-policy.toml"
		case .promptOnly:
			filename = includeRepoPromptMCPAllowance
				? "gemini-prompt-only-policy.toml"
				: "gemini-prompt-only-acp-policy.toml"
		case .terminal:
			filename = includeRepoPromptMCPAllowance
				? "gemini-terminal-policy.toml"
				: "gemini-terminal-acp-policy.toml"
		}
		let policyURL = repoPromptDir.appendingPathComponent(filename)

		try fm.createDirectory(at: repoPromptDir, withIntermediateDirectories: true, attributes: nil)

		let policyTOML = policyTOML(
			for: context,
			includeRepoPromptMCPAllowance: includeRepoPromptMCPAllowance
		)
		let newData = Data(policyTOML.utf8)

		let existingData = try? Data(contentsOf: policyURL)
		if existingData != newData {
			try newData.write(to: policyURL, options: .atomic)
		}

		return policyURL
	}

	/// Returns the persistent Gemini system settings file in Application Support.
	/// Creates/updates the file if needed. Uses `GEMINI_CLI_SYSTEM_SETTINGS_PATH` env var.
	/// This approach does NOT modify the user's `~/.gemini/settings.json`.
	///
	/// - Parameter context: The context (agent run or terminal) to determine tool exclusions.
	/// - Returns: URL to the persistent settings file.
	static func systemSettingsURL(
		for context: AgentCLIToolContext = .agentRun,
		includeRepoPromptMCPServer: Bool = true,
		includeRepoPromptMCPPolicyAllowance: Bool? = nil
	) throws -> URL {
		let fm = FileManager.default
		let appSupportURL = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
		let repoPromptDir = appSupportURL.appendingPathComponent("RepoPrompt", isDirectory: true)

		// Use separate files for each context/runtime mode to avoid conflicts
		let filename: String
		switch context {
		case .agentRun, .discoverRun, .delegateEdit:
			filename = includeRepoPromptMCPServer
				? "gemini-system-settings.json"
				: "gemini-acp-system-settings.json"
		case .promptOnly:
			filename = includeRepoPromptMCPServer
				? "gemini-prompt-only-settings.json"
				: "gemini-prompt-only-acp-settings.json"
		case .terminal:
			filename = includeRepoPromptMCPServer
				? "gemini-terminal-settings.json"
				: "gemini-terminal-acp-settings.json"
		}
		let settingsURL = repoPromptDir.appendingPathComponent(filename)

		// Create directory if needed
		try fm.createDirectory(at: repoPromptDir, withIntermediateDirectories: true, attributes: nil)

		// Build the settings content
		var settings: [String: Any] = [:]

		if includeRepoPromptMCPServer {
			settings["mcpServers"] = [repoPromptMCPServerName: repoPromptMCPConfiguration.settingsJSONObject]
		}

		// Enable preview features for Gemini 3 preview models
		settings["general"] = ["previewFeatures": true]

		// Use Policy Engine TOML files instead of deprecated tools.exclude.
		// ACP injects the RepoPrompt MCP server via session/new instead of this settings file,
		// but still needs policy allowance for those MCP tools.
		let allowRepoPromptMCPPolicy = includeRepoPromptMCPPolicyAllowance ?? includeRepoPromptMCPServer
		let policyURL = try policyFileURL(
			for: context,
			includeRepoPromptMCPAllowance: allowRepoPromptMCPPolicy
		)
		settings["adminPolicyPaths"] = [policyURL.path]

		let newData = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])

		// Only write if content differs (avoids unnecessary disk writes)
		let existingData = try? Data(contentsOf: settingsURL)
		if existingData != newData {
			try newData.write(to: settingsURL, options: .atomic)
		}

		return settingsURL
	}

	private static func policyTOML(
		for context: AgentCLIToolContext,
		includeRepoPromptMCPAllowance: Bool
	) -> String {
		switch context {
		case .agentRun, .discoverRun, .delegateEdit:
			var denyTools = agentExcludedTools
			if context == .discoverRun || context == .delegateEdit {
				denyTools += discoverDelegateExtraExcludedTools
			}
			let nativeDenyList = denyTools
				.map { "\"\($0)\"" }
				.joined(separator: ", ")
			var lines = [
				"# RepoPrompt-managed Gemini CLI policy",
				"# Deny conflicting Gemini-native tools; allow RepoPrompt MCP tools when configured.",
				"",
				"[[rule]]",
				"toolName = [\(nativeDenyList)]",
				"decision = \"deny\"",
				"priority = 900"
			]
			if includeRepoPromptMCPAllowance {
				lines += [
					"",
					"[[rule]]",
					"toolName = \"*\"",
					"mcpName = \"\(repoPromptMCPServerName)\"",
					"decision = \"allow\"",
					"priority = 950"
				]
			}
			return lines.joined(separator: "\n") + "\n"
		case .promptOnly:
			let allNativeTools = agentExcludedTools + [
				"read_file",                    // Also deny in prompt-only
				"run_shell_command",            // Shell execution
				"list_background_processes",    // Background shell management
				"read_background_output",       // Background shell output
				"ask_user",                     // User interaction
				"complete_task",                // Task completion
				"activate_skill"                // Skill activation
			]
			let toolList = allNativeTools.map { "\"\($0)\"" }.joined(separator: ", ")
			return [
				"# RepoPrompt-managed Gemini CLI policy",
				"# Deny all known native tools for prompt-only mode.",
				"",
				"[[rule]]",
				"toolName = [\(toolList)]",
				"decision = \"deny\"",
				"priority = 900"
			].joined(separator: "\n") + "\n"
		case .terminal:
			var lines = [
				"# RepoPrompt-managed Gemini CLI policy",
				"# Deny file-editing tools that conflict with RepoPrompt in terminal mode.",
				"",
				"[[rule]]",
				"toolName = [\"write_file\", \"list_directory\", \"glob\", \"replace\", \"search_file_content\", \"read_many_files\"]",
				"decision = \"deny\"",
				"priority = 900"
			]
			if includeRepoPromptMCPAllowance {
				lines += [
					"",
					"[[rule]]",
					"toolName = \"*\"",
					"mcpName = \"\(repoPromptMCPServerName)\"",
					"decision = \"allow\"",
					"priority = 950"
				]
			}
			return lines.joined(separator: "\n") + "\n"
		}
	}
}
