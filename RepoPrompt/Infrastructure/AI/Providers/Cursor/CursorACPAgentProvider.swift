import Foundation

struct CursorACPAgentProvider: ACPAgentProvider {
	private let config: CursorAgentConfig
	private let repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration
	private let launchResolver: CursorACPLaunchResolver

#if DEBUG
	var test_config: CursorAgentConfig { config }
#endif

	init(
		config: CursorAgentConfig,
		repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration = .repoPrompt,
		launchResolver: CursorACPLaunchResolver = .shared
	) {
		self.config = config
		self.repoPromptMCPConfiguration = repoPromptMCPConfiguration
		self.launchResolver = launchResolver
	}

	var providerID: ACPProviderID { .cursor }

	func support(for _: ACPRunRequest) async -> ACPSupportResult {
		await launchResolver.probeSupport(for: config)
	}

	func makeLaunchConfiguration(for request: ACPRunRequest) throws -> ACPLaunchConfiguration {
		let workingDirectory = try standardizedWorkingDirectory(from: request.workspacePath)
		let effectiveHints = CLIPathHints.nativeDefaultsSupplemented(with: config.additionalPathHints)
		let resolvedLaunch = launchResolver.resolvedLaunch(for: config)
			?? CursorACPResolvedLaunch.fallback(
				commandName: config.commandName,
				additionalPathHints: effectiveHints
			)

		return ACPLaunchConfiguration(
			providerID: providerID,
			command: resolvedLaunch.command,
			arguments: resolvedLaunch.arguments,
			environment: [:],
			workingDirectory: workingDirectory,
			additionalPathHints: resolvedLaunch.additionalPathHints,
			enableDebugLogging: config.enableDebugLogging
		)
	}

	func makeSessionConfiguration(
		for request: ACPRunRequest,
		mcpServer _: RepoPromptMCPServerConfiguration
	) throws -> ACPSessionConfiguration {
		let mode: ACPSessionConfiguration.Mode
		if let resume = request.resumeSessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
			!resume.isEmpty {
			mode = .load(existingSessionID: resume)
		} else {
			mode = .new
		}

		return ACPSessionConfiguration(
			mode: mode,
			workingDirectory: try standardizedWorkingDirectory(from: request.workspacePath),
			mcpServers: config.includeRepoPromptMCPServer ? [repoPromptMCPConfiguration] : []
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
		let systemPrompt = message.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
		let userMessage = message.userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
		let text: String
		if isFollowUp || systemPrompt.isEmpty {
			text = userMessage.isEmpty ? message.userMessage : userMessage
		} else if userMessage.isEmpty {
			text = systemPrompt
		} else {
			text = "\(systemPrompt)\n\n\(userMessage)"
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
		CursorACPEventNormalizer.normalize(payload)
	}

	func preferredAuthMethodID(context: ACPAuthenticationContext) -> String? {
		let envTokenKeys = ["CURSOR_API_KEY", "CURSOR_AUTH_TOKEN"]
		let hasEnvironmentToken = envTokenKeys.contains { key in
			context.environment[key]?
				.trimmingCharacters(in: .whitespacesAndNewlines)
				.isEmpty == false
		}
		guard !hasEnvironmentToken else { return nil }
		return context.authMethodIDs.first {
			$0.caseInsensitiveCompare("cursor_login") == .orderedSame
		}
	}

	func cleanupLaunchArtifacts(for configuration: ACPLaunchConfiguration) async {
		guard let artifact = configuration.cleanupArtifact,
			artifact.providerID == providerID,
			artifact.kind == CursorIntegrationConfiguration.cleanupArtifactKind else {
			return
		}
		CursorIntegrationConfiguration.cleanupProjectMCPConfig(leaseID: artifact.id)
	}

	func normalizeError(_ error: Error) -> Error {
		if error is AIProviderError {
			return error
		}
		if let runnerError = error as? CLIProcessRunnerError,
			case .commandNotFound = runnerError {
			return AIProviderError.invalidConfiguration(detail: "Cursor CLI ACP server not found. Install Cursor CLI and ensure `cursor-agent acp` or `cursor agent acp` is available on PATH.")
		}
		if (error as NSError).domain == NSCocoaErrorDomain {
			return AIProviderError.invalidConfiguration(detail: "Unable to prepare Cursor ACP config: \(error.localizedDescription)")
		}
		let description = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
		let lower = description.lowercased()
		if lower.contains("session mode") || lower.contains("session/set_mode") {
			return AIProviderError.invalidConfiguration(detail: description)
		}
		return AIProviderError.apiError(source: error)
	}

	private func standardizedWorkingDirectory(from workspacePath: String?) throws -> String {
		if let cwd = workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty {
			return URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL.path
		}
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("RepoPromptCursorACPPreflight", isDirectory: true)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
		return url.standardizedFileURL.path
	}
}
