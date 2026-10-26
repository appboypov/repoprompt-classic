import Foundation

/// Runs Google's Antigravity ACP server, which RepoPrompt downloads into
/// Application Support, with RepoPrompt's own Antigravity profile.
struct AntigravityACPAgentProvider: ACPAgentProvider {
	enum LaunchContract {
		static let profileHomeEnvironmentKey = "GEMINI_HOME"
		static let removedEnvironmentKeys: Set<String> = [
			"GEMINI_API_KEY",
			"GCLOUD_PROJECT",
			"CLOUDSDK_CORE_PROJECT",
			"ANTIGRAVITY_HARNESS_PATH",
		]
		static let removedEnvironmentKeyPrefixes = ["GOOGLE_", "AGY_ACP_"]
	}

	private let config: AntigravityAgentConfig

#if DEBUG
	var test_config: AntigravityAgentConfig { config }
#endif

	init(config: AntigravityAgentConfig) {
		self.config = config
	}

	var providerID: ACPProviderID { .antigravity }

	func support(for _: ACPRunRequest) async -> ACPSupportResult {
		guard FileManager.default.isExecutableFile(atPath: config.serverPath) else {
			return .unsupported(reason: "Antigravity is not downloaded. Download it in Settings > CLI Providers.")
		}
		let profileHomeURL = URL(fileURLWithPath: config.profileHomePath, isDirectory: true)
		guard config.authMethodID != nil || AntigravityIntegrationConfiguration.isSignedIn(profileHomeURL: profileHomeURL) else {
			return .unsupported(reason: "Antigravity is not signed in. Sign in in Settings > CLI Providers.")
		}
		return .supported
	}

	func makeLaunchConfiguration(for request: ACPRunRequest) throws -> ACPLaunchConfiguration {
		try AntigravityIntegrationConfiguration.prepareProfile(
			profileHomeURL: URL(fileURLWithPath: config.profileHomePath, isDirectory: true)
		)
		return ACPLaunchConfiguration(
			providerID: providerID,
			command: config.serverPath,
			arguments: [],
			environment: [
				LaunchContract.profileHomeEnvironmentKey: config.profileHomePath,
				"PYTHONUNBUFFERED": "1",
			],
			workingDirectory: request.workspacePath,
			additionalPathHints: [],
			enableDebugLogging: config.enableDebugLogging,
			removedEnvironmentKeys: LaunchContract.removedEnvironmentKeys,
			removedEnvironmentKeyPrefixes: LaunchContract.removedEnvironmentKeyPrefixes
		)
	}

	func makeSessionConfiguration(
		for request: ACPRunRequest,
		mcpServer: RepoPromptMCPServerConfiguration
	) throws -> ACPSessionConfiguration {
		let cwd = request.workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines)
		let workingDirectory = (cwd?.isEmpty == false ? cwd : nil)
			.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
			?? FileManager.default.temporaryDirectory.path
		let mode: ACPSessionConfiguration.Mode
		if let resume = request.resumeSessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
			!resume.isEmpty {
			mode = .load(existingSessionID: resume)
		} else {
			mode = .new
		}

		return ACPSessionConfiguration(
			mode: mode,
			workingDirectory: workingDirectory,
			mcpServers: config.includeRepoPromptMCPServer ? [mcpServer] : []
		)
	}

	func buildPromptBlocks(
		for message: AgentMessage,
		request: ACPRunRequest
	) throws -> [[String: Any]] {
		let isFollowUp = request.isProviderSessionContinuation
			|| request.resumeSessionID?
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.isEmpty == false
		let text: String
		let systemPrompt = message.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
		if isFollowUp || systemPrompt.isEmpty {
			text = message.userMessage
		} else {
			text = "\(systemPrompt)\n\n\(message.userMessage)"
		}

		return try ACPPromptContentBuilder.blocks(
			text: text,
			attachments: request.attachments
		)
	}

	func normalizeSessionUpdate(
		_ payload: [String: Any],
		sessionID _: String
	) -> [NormalizedAgentRuntimeEvent] {
		ACPDefaultSessionUpdateNormalizer.normalize(payload, providerID: .antigravity)
	}

	func preferredAuthMethodID(context: ACPAuthenticationContext) -> String? {
		guard let authMethodID = config.authMethodID else { return nil }
		return context.authMethodIDs.first {
			$0.caseInsensitiveCompare(authMethodID) == .orderedSame
		}
	}

	/// Antigravity names the account's plan in `_meta.antigravity.tier.name`
	/// of the `session/new` and `session/load` results.
	func accountPlanName(fromSessionResponse response: [String: Any]) -> String? {
		let meta = response["_meta"] as? [String: Any]
		let antigravity = meta?["antigravity"] as? [String: Any]
		let tier = antigravity?["tier"] as? [String: Any]
		let name = (tier?["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
		return name?.isEmpty == false ? name : nil
	}

	func normalizeError(_ error: Error) -> Error {
		if error is AIProviderError {
			return error
		}
		if let runnerError = error as? CLIProcessRunnerError,
			case .commandNotFound = runnerError {
			return AIProviderError.invalidConfiguration(detail: "Antigravity is not downloaded. Download it in Settings > CLI Providers.")
		}
		let lower = error.localizedDescription.lowercased()
		if lower.contains("authentication required") || lower.contains("credentials missing") {
			return AIProviderError.invalidConfiguration(detail: "Antigravity is not signed in. Sign in in Settings > CLI Providers.")
		}
		if lower.contains("subscription_required") {
			return AIProviderError.invalidConfiguration(detail: "Your Google account has no Antigravity plan for this request.")
		}
		return AIProviderError.apiError(source: error)
	}
}
