import Foundation

struct GeminiACPAgentProvider: ACPAgentProvider {
	private enum LaunchContract {
		static let acpFlag = "--acp"
		static let skipTrustFlag = "--skip-trust"
		static let allowedMCPServersFlag = "--allowed-mcp-server-names"
		static let repoPromptMCPServerName = RepoPromptMCPServerConfiguration.defaultServerName
		static let systemSettingsEnvironmentKey = MCPIntegrationHelper.geminiSystemSettingsEnvKey
	}

	private let config: GeminiAgentConfig

	init(config: GeminiAgentConfig) {
		self.config = config
	}

	var providerID: ACPProviderID { .gemini }

	func support(for request: ACPRunRequest) async -> ACPSupportResult {
		var processConfig = CLIProcessConfiguration(
			command: config.commandName,
			enableDebugLogging: config.enableDebugLogging
		)
		processConfig.ensureAdditionalPaths(config.additionalPathHints)
		let runner = CLIProcessRunner(config: processConfig)

		do {
			let result = try await runner.run(
				args: ["--help"],
				stdin: nil,
				outputMode: .none,
				timeout: 10
			)
			let stdout = String(data: result.stdout, encoding: .utf8) ?? ""
			let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
			let combined = "\(stdout)\n\(stderr)"
			guard result.status == 0 else {
				return .unsupported(reason: "Gemini ACP preflight failed before startup.")
			}
			let supportsACP = combined.localizedCaseInsensitiveContains("--acp")
				|| combined.localizedCaseInsensitiveContains("--experimental-acp")
			guard supportsACP else {
				return .unsupported(reason: "Installed Gemini CLI does not advertise ACP support.")
			}
			return .supported
		} catch let error as CLIProcessRunnerError {
			switch error {
			case .commandNotFound:
				return .unsupported(reason: "Gemini CLI was not found for ACP preflight.")
			default:
				return .unsupported(reason: "Gemini ACP preflight failed: \(error.localizedDescription)")
			}
		} catch {
			return .unsupported(reason: "Gemini ACP preflight failed: \(error.localizedDescription)")
		}
	}

	func makeLaunchConfiguration(for request: ACPRunRequest) throws -> ACPLaunchConfiguration {
		var environment: [String: String] = [:]
		environment[LaunchContract.systemSettingsEnvironmentKey] = try MCPIntegrationHelper
			.geminiSystemSettingsURL(
				for: config.toolContext,
				includeRepoPromptMCPServer: false,
				includeRepoPromptMCPPolicyAllowance: config.includeRepoPromptMCPServer
			)
			.path

		var arguments = [LaunchContract.acpFlag]
		if config.includeRepoPromptMCPServer {
			let mcpServerName = LaunchContract.repoPromptMCPServerName
			assert(!mcpServerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "MCP server name must not be empty")
			arguments.append(contentsOf: [LaunchContract.skipTrustFlag, LaunchContract.allowedMCPServersFlag, mcpServerName])
		}
		let isResumingSession = request.resumeSessionID?
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.isEmpty == false
		let model: String?
		if isResumingSession {
			model = nil
		} else {
			model = (request.modelString?.trimmingCharacters(in: .whitespacesAndNewlines))
				.flatMap { $0.isEmpty || $0.lowercased() == "default" ? nil : $0 }
				?? (config.modelString?.trimmingCharacters(in: .whitespacesAndNewlines))
				.flatMap { $0.isEmpty || $0.lowercased() == "default" ? nil : $0 }
		}
		if let model {
			arguments.append(contentsOf: ["--model", model])
		}

		return ACPLaunchConfiguration(
			providerID: providerID,
			command: config.commandName,
			arguments: arguments,
			environment: environment,
			workingDirectory: request.workspacePath,
			additionalPathHints: CLIPathHints.nativeDefaultsSupplemented(with: config.additionalPathHints),
			enableDebugLogging: config.enableDebugLogging
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
		let sessionMCPServers: [RepoPromptMCPServerConfiguration]
		if config.includeRepoPromptMCPServer {
			guard mcpServer.name == LaunchContract.repoPromptMCPServerName else {
				throw AIProviderError.invalidConfiguration(detail: "Gemini ACP expects the injected MCP server to be named \(LaunchContract.repoPromptMCPServerName).")
			}
			sessionMCPServers = [mcpServer]
		} else {
			sessionMCPServers = []
		}

		return ACPSessionConfiguration(
			mode: mode,
			workingDirectory: workingDirectory,
			mcpServers: sessionMCPServers
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
		ACPDefaultSessionUpdateNormalizer.normalize(payload, providerID: .gemini)
	}

	func preferredAuthMethodID(context: ACPAuthenticationContext) -> String? {
		let preferredIDs = ["use_gemini_api", "use_gemini"]
		for preferredID in preferredIDs {
			if let match = context.authMethodIDs.first(where: { $0.lowercased() == preferredID }) {
				return match
			}
		}
		return context.authMethodIDs.first
	}

	func normalizeError(_ error: Error) -> Error {
		if error is AIProviderError {
			return error
		}
		if let runnerError = error as? CLIProcessRunnerError,
			case .commandNotFound = runnerError {
			return AIProviderError.invalidConfiguration(detail: "Gemini CLI not found. Install it from geminicli.com.")
		}
		return AIProviderError.apiError(source: error)
	}
}
