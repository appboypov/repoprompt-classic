import Foundation
import Logging

/// Antigravity file locations RepoPrompt reads and writes.
///
/// RepoPrompt runs the Antigravity ACP server with its own profile
/// (`GEMINI_HOME`), so the server keeps its sign-in in
/// `<profile>/antigravity-acp/settings.json` and never loads the agy CLI's
/// global MCP config. The MCP install for the agy CLI writes the user's own
/// `~/.gemini/config/mcp_config.json`.
enum AntigravityIntegrationConfiguration {
	private static let repoPromptMCPConfiguration = RepoPromptMCPServerConfiguration.repoPrompt
	private static let repoPromptMCPServerName = RepoPromptMCPServerConfiguration.defaultServerName
	private static let logger = Logger(label: "com.repoprompt.antigravity.configuration")

	// MARK: - RepoPrompt Profile

	/// `~/Library/Application Support/RepoPrompt/Antigravity/home`
	static var profileHomeURL: URL {
		AntigravityServerInstaller.rootURL.appendingPathComponent(AntigravityServerInstaller.homeFolderName, isDirectory: true)
	}

	static func profileSettingsURL(profileHomeURL: URL = profileHomeURL) -> URL {
		profileHomeURL
			.appendingPathComponent("antigravity-acp", isDirectory: true)
			.appendingPathComponent("settings.json")
	}

	static func profileMCPConfigURL(profileHomeURL: URL = profileHomeURL) -> URL {
		profileHomeURL
			.appendingPathComponent("config", isDirectory: true)
			.appendingPathComponent("mcp_config.json")
	}

	/// Creates the profile folder with an empty global MCP config, so the server
	/// only starts the MCP servers RepoPrompt passes in `session/new`.
	static func prepareProfile(profileHomeURL: URL = profileHomeURL) throws {
		let mcpConfigURL = profileMCPConfigURL(profileHomeURL: profileHomeURL)
		try FileManager.default.createDirectory(
			at: mcpConfigURL.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)
		guard !FileManager.default.fileExists(atPath: mcpConfigURL.path) else { return }
		let data = try JSONSerialization.data(withJSONObject: ["mcpServers": [String: Any]()], options: [.prettyPrinted])
		try data.write(to: mcpConfigURL, options: .atomic)
	}

	/// The server writes `auth.type` into the profile settings after a
	/// successful sign-in and reads it on every later launch.
	static func isSignedIn(profileHomeURL: URL = profileHomeURL) -> Bool {
		guard let data = try? Data(contentsOf: profileSettingsURL(profileHomeURL: profileHomeURL)),
			let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			let auth = root["auth"] as? [String: Any],
			let type = auth["type"] as? String else {
			return false
		}
		return !type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
	}

	/// Removes the stored sign-in choice so the next run asks for sign-in again.
	static func signOut(profileHomeURL: URL = profileHomeURL) {
		let settingsURL = profileSettingsURL(profileHomeURL: profileHomeURL)
		guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
		do {
			try FileManager.default.removeItem(at: settingsURL)
		} catch {
			logger.error("Antigravity sign-out could not remove \(settingsURL.path): \(error.localizedDescription)")
		}
	}

	// MARK: - agy CLI MCP Install

	static func agyMCPConfigURL() -> URL {
		FileManager.default.homeDirectoryForCurrentUser
			.appendingPathComponent(".gemini", isDirectory: true)
			.appendingPathComponent("config", isDirectory: true)
			.appendingPathComponent("mcp_config.json")
	}

	static func configContainsRepoPrompt() -> Bool {
		guard let data = try? Data(contentsOf: agyMCPConfigURL()),
			let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			let servers = json["mcpServers"] as? [String: Any] else {
			return false
		}
		return servers.keys.contains {
			$0.compare(repoPromptMCPServerName, options: .caseInsensitive) == .orderedSame
		}
	}

	/// Writes the RepoPrompt MCP server into the agy CLI's global MCP config,
	/// keeping every other entry in the file.
	@discardableResult
	static func installPersistentMCPConfig() -> (success: Bool, wasAlreadyPresent: Bool) {
		let fileManager = FileManager.default
		let configURL = agyMCPConfigURL()

		do {
			try fileManager.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)

			let fileExists = fileManager.fileExists(atPath: configURL.path)
			var root: [String: Any] = [:]
			if fileExists,
				let data = try? Data(contentsOf: configURL),
				let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
				root = json
			}

			var servers = root["mcpServers"] as? [String: Any] ?? [:]
			let existingEntry = servers[repoPromptMCPServerName] as? [String: Any]
			let entryMatches = existingEntry.map {
				NSDictionary(dictionary: $0).isEqual(to: repoPromptMCPConfiguration.settingsJSONObject)
			} ?? false

			if !fileExists || !entryMatches {
				servers[repoPromptMCPServerName] = repoPromptMCPConfiguration.settingsJSONObject
				root["mcpServers"] = servers
				let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
				try data.write(to: configURL, options: .atomic)
			}

			return (true, existingEntry != nil)
		} catch {
			logger.error("Antigravity MCP install failed at \(configURL.path): \(error.localizedDescription)")
			return (false, false)
		}
	}
}
