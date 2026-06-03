import Foundation

struct OpenCodeACPAgentProvider: ACPAgentProvider {
	private enum LaunchContract {
		static let acpSubcommand = "acp"
		static let configContentEnvironmentKey = "OPENCODE_CONFIG_CONTENT"
	}

	private let config: OpenCodeAgentConfig
	private let repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration

#if DEBUG
	var test_config: OpenCodeAgentConfig { config }
#endif

	init(
		config: OpenCodeAgentConfig,
		repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration = .repoPrompt
	) {
		self.config = config
		self.repoPromptMCPConfiguration = repoPromptMCPConfiguration
	}

	var providerID: ACPProviderID { .openCode }

	func support(for request: ACPRunRequest) async -> ACPSupportResult {
		var processConfig = CLIProcessConfiguration(
			command: config.commandName,
			enableDebugLogging: config.enableDebugLogging
		)
		processConfig.ensureAdditionalPaths(config.additionalPathHints)
		let runner = CLIProcessRunner(config: processConfig)

		do {
			let result = try await runner.run(
				args: [LaunchContract.acpSubcommand, "--help"],
				stdin: nil,
				outputMode: .none,
				timeout: 10
			)
			let stdout = String(data: result.stdout, encoding: .utf8) ?? ""
			let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
			let combined = "\(stdout)\n\(stderr)"
			guard result.status == 0 else {
				return .unsupported(reason: "OpenCode ACP preflight failed before startup.")
			}
			guard combined.localizedCaseInsensitiveContains("acp") else {
				return .unsupported(reason: "Installed OpenCode CLI does not advertise ACP support.")
			}
			return .supported
		} catch let error as CLIProcessRunnerError {
			switch error {
			case .commandNotFound:
				return .unsupported(reason: "OpenCode CLI was not found for ACP preflight.")
			default:
				return .unsupported(reason: "OpenCode ACP preflight failed: \(error.localizedDescription)")
			}
		} catch {
			return .unsupported(reason: "OpenCode ACP preflight failed: \(error.localizedDescription)")
		}
	}

	func makeLaunchConfiguration(for request: ACPRunRequest) throws -> ACPLaunchConfiguration {
		let workingDirectory = standardizedWorkingDirectory(from: request.workspacePath)
		var environment: [String: String] = [:]

		if config.includeManagedConfigOverlay {
			if config.cleanupLegacyPersistentConfig {
				OpenCodeIntegrationConfiguration.cleanupLegacyACPConfigIfNeeded(
					preserveExplicitMCPInstall: MCPIntegrationHelper.isMCPServerInstalled
				)
			}
			if config.includeRepoPromptMCPServer {
				try repoPromptMCPConfiguration.validateACPLaunchCommand(
					workingDirectory: workingDirectory
				)
			}
			environment[LaunchContract.configContentEnvironmentKey] = try OpenCodeIntegrationConfiguration.ephemeralACPConfigJSON(
				includeRepoPromptMCPServer: config.includeRepoPromptMCPServer,
				repoPromptMCPConfiguration: repoPromptMCPConfiguration
			)
		}

		return ACPLaunchConfiguration(
			providerID: providerID,
			command: config.commandName,
			arguments: [LaunchContract.acpSubcommand],
			environment: environment,
			workingDirectory: workingDirectory,
			additionalPathHints: CLIPathHints.nativeDefaultsSupplemented(with: config.additionalPathHints),
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
			workingDirectory: standardizedWorkingDirectory(from: request.workspacePath),
			mcpServers: []
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
		OpenCodeACPEventNormalizer.normalize(payload, toolProfile: config.toolProfile)
	}

	func normalizeError(_ error: Error) -> Error {
		if error is AIProviderError {
			return error
		}
		if let runnerError = error as? CLIProcessRunnerError,
			case .commandNotFound = runnerError {
			return AIProviderError.invalidConfiguration(detail: "OpenCode CLI not found. Install it and ensure `opencode` is available on PATH.")
		}
		if (error as NSError).domain == NSCocoaErrorDomain {
			return AIProviderError.invalidConfiguration(detail: "Unable to prepare OpenCode ACP config: \(error.localizedDescription)")
		}
		return AIProviderError.apiError(source: error)
	}

	private func standardizedWorkingDirectory(from workspacePath: String?) -> String {
		let cwd = workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines)
		return (cwd?.isEmpty == false ? cwd : nil)
			.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
			?? FileManager.default.temporaryDirectory.path
	}
}
