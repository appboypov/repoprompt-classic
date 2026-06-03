import Foundation

/// Gemini CLI provider for non-agent use (chat, AIQueries, etc.) backed by ACP.
/// Runs in prompt-only mode with a fresh ACP session per request.
final class GeminiCLIProvider: AIProvider {
	typealias ACPControllerFactory = (
		ACPRunRequest,
		ACPAgentSessionController.DiagnosticSink?,
		ACPAgentSessionController.RequestTimeouts
	) throws -> ACPAgentSessionController

	private enum PromptOnlyPolicyError: LocalizedError, Sendable {
		case toolCall(String?)
		case approvalRequested(String?)

		var errorDescription: String? {
			switch self {
			case .toolCall(let name):
				if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
					return "Gemini CLI attempted to use tool '\(name)' while prompt-only mode is active."
				}
				return "Gemini CLI attempted to use tools while prompt-only mode is active."
			case .approvalRequested(let reason):
				if let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
					return "Gemini CLI requested tool approval while prompt-only mode is active: \(reason)"
				}
				return "Gemini CLI requested tool approval while prompt-only mode is active."
			}
		}
	}

	private let workingDirectory: String?
	private let enableDebugLogging: Bool
	private let defaultRequestTimeout: TimeInterval
	private let testRequestTimeout: TimeInterval
	private let maxRetries: Int
	private let initialBackoff: TimeInterval = 1.0
	private let maxBackoff: TimeInterval = 8.0
	private let logCollector: CLIProcessLogCollector?
	private let activeRequests = ACPActiveRequestRegistry()
	private let controllerFactory: ACPControllerFactory

	init(
		workingDirectory: String? = nil,
		enableDebugLogging: Bool = false,
		defaultRequestTimeout: TimeInterval? = nil,
		testRequestTimeout: TimeInterval? = nil,
		maxRetries: Int? = nil,
		logCollector: CLIProcessLogCollector? = nil,
		baseConfig: GeminiAgentConfig? = nil,
		controllerFactory: ACPControllerFactory? = nil
	) {
		self.workingDirectory = workingDirectory
		self.enableDebugLogging = enableDebugLogging
		self.logCollector = logCollector
		let resolvedBaseConfig = baseConfig ?? GeminiAgentConfig(
			commandName: "gemini",
			additionalPathHints: CLIPathHints.gemini,
			modelString: nil,
			enableDebugLogging: enableDebugLogging,
			toolContext: .promptOnly,
			includeRepoPromptMCPServer: false
		)
		self.controllerFactory = controllerFactory ?? { runRequest, diagnosticSink, requestTimeouts in
			try ACPAgentSessionController(
				provider: GeminiACPAgentProvider(config: resolvedBaseConfig),
				runRequest: runRequest,
				diagnosticSink: diagnosticSink,
				requestTimeouts: requestTimeouts
			)
		}

		let defaults = UserDefaults.standard
		let resolvedDefaultTimeout = defaultRequestTimeout ?? {
			let value = defaults.double(forKey: "GeminiCLITimeoutDefault")
			return value > 0 ? value : 360
		}()
		let resolvedTestTimeout = testRequestTimeout ?? {
			let value = defaults.double(forKey: "GeminiCLITimeoutTest")
			return value > 0 ? value : 30
		}()
		let resolvedRetries = maxRetries ?? {
			guard defaults.object(forKey: "GeminiCLIRetryAttempts") != nil else { return 2 }
			return max(0, defaults.integer(forKey: "GeminiCLIRetryAttempts"))
		}()

		self.defaultRequestTimeout = resolvedDefaultTimeout
		self.testRequestTimeout = resolvedTestTimeout
		self.maxRetries = resolvedRetries
	}

	func streamMessage(_ aiMessage: AIMessage, model: AIModel, maxTokens _: Int? = nil) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
		try await streamMessage(
			makeAgentMessage(from: aiMessage),
			modelString: geminiModelName(for: model),
			timeout: defaultRequestTimeout
		)
	}

	func completeMessage(_ aiMessage: AIMessage, model: AIModel, maxTokens _: Int? = nil) async throws -> AICompletionResult {
		try await completeMessage(
			makeAgentMessage(from: aiMessage),
			modelString: geminiModelName(for: model),
			timeout: defaultRequestTimeout
		)
	}

	func dispose() async {
		let active = await activeRequests.snapshotAndDispose()
		for entry in active {
			entry.task.cancel()
		}
		for entry in active {
			let controller = entry.controller
			await controller.shutdown()
		}
	}

	func testConnection(timeout: TimeInterval? = nil) async throws -> Bool {
		let appliedTimeout = timeout ?? testRequestTimeout
		let message = AgentMessage(systemPrompt: "", userMessage: "Reply with OK only", resumeSessionID: nil)

		do {
			let result = try await completeMessage(
				message,
				modelString: geminiModelName(for: .geminiCliFlash25),
				timeout: appliedTimeout
			)
			return result.text.lowercased().contains("ok")
		} catch {
			let result = try await completeMessage(
				message,
				modelString: nil,
				timeout: appliedTimeout
			)
			return result.text.lowercased().contains("ok")
		}
	}

	// MARK: - ACP request flow

	private func streamMessage(
		_ message: AgentMessage,
		modelString: String?,
		timeout: TimeInterval
	) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
		let diagnostics = ACPDiagnosticsBuffer(
			logPrefix: "[GeminiCLI][ACP]",
			enableDebugLogging: enableDebugLogging,
			logCollector: logCollector
		)
		let runRequest = ACPRunRequest(
			agentKind: .gemini,
			modelString: modelString,
			workspacePath: workingDirectory,
			resumeSessionID: nil,
			attachments: [],
			taskLabelKind: nil,
			sessionModeID: GeminiAgentToolPreferences.PermissionLevel.default.sessionModeID
		)
		let diagnosticSink: ACPAgentSessionController.DiagnosticSink = { event in
			Task {
				await diagnostics.record(event)
			}
		}
		let controller: ACPAgentSessionController
		do {
			controller = try controllerFactory(
				runRequest,
				diagnosticSink,
				.init(bootstrapSeconds: timeout)
			)
		} catch {
			throw Self.mapRuntimeError(error, diagnosticDetail: "", timedOut: false, timeoutValue: timeout)
		}
		let events = await controller.currentEventsStream()
		let registry = activeRequests

		return AsyncThrowingStream { continuation in
			let requestID = UUID()
			let bridgeTask = Task {
				let timeoutState = ACPTimeoutState()
				defer {
					Task {
						await registry.remove(id: requestID)
					}
				}

				let timeoutTask = Task {
					do {
						try await Task.sleep(nanoseconds: UInt64((timeout * 1_000_000_000).rounded()))
					} catch {
						return
					}
					await timeoutState.markTimedOut()
					await controller.cancelPrompt()
					await controller.shutdown()
				}
				defer { timeoutTask.cancel() }

				do {
					try await controller.bootstrap()
					if let sessionModeID = runRequest.sessionModeID?.trimmingCharacters(in: .whitespacesAndNewlines),
						!sessionModeID.isEmpty {
						try await controller.setSessionMode(sessionModeID)
					}
					let promptTask = Task {
						try await controller.prompt(message)
					}
					defer {
						promptTask.cancel()
					}

					var sawMessageStop = false
					var terminalState: AgentSessionRunState?
					var terminalErrorText: String?

					for await event in events {
						if Task.isCancelled {
							await controller.cancelPrompt()
							throw CancellationError()
						}

						switch event {
						case .stream(let result):
							switch result.type {
							case "content":
								continuation.yield(result)
							case "message_stop":
								if !sawMessageStop {
									sawMessageStop = true
									continuation.yield(result)
								}
							case "reasoning", "status":
								continue
							case "system", "error":
								await diagnostics.recordText(result.text)
							case "tool_call", "tool_result", "tool_progress":
								await diagnostics.recordText(result.toolName ?? result.text ?? result.type)
								await controller.cancelPrompt()
								throw PromptOnlyPolicyError.toolCall(result.toolName ?? result.text)
							default:
								continue
							}

						case .approvalRequested(let request):
							await diagnostics.recordText(request.reason ?? request.command)
							await controller.cancelPrompt()
							throw PromptOnlyPolicyError.approvalRequested(request.reason ?? request.command)

						case .approvalCancelled:
							continue

						case .terminal(let state, let errorText):
							terminalState = state
							terminalErrorText = errorText
							await diagnostics.recordText(errorText)
							if state == .completed && !sawMessageStop {
								sawMessageStop = true
								continuation.yield(AIStreamResult(type: "message_stop", text: nil))
							}
							break
						}

						if terminalState != nil {
							break
						}
					}

					let promptResult = await promptTask.result
					await controller.shutdown()

					switch promptResult {
					case .success:
						break
					case .failure(let error):
						throw error
					}

					if let terminalState {
						switch terminalState {
						case .completed:
							continuation.finish()
						case .failed, .cancelled:
							let terminalError = NSError(
								domain: "GeminiCLI",
								code: terminalState == .failed ? 1 : NSUserCancelledError,
								userInfo: [NSLocalizedDescriptionKey: terminalErrorText ?? "Gemini ACP request failed."]
							)
							throw terminalError
						default:
							continuation.finish()
						}
					} else if sawMessageStop {
						continuation.finish()
					} else {
						throw AIProviderError.invalidResponse(detail: "Gemini CLI returned no completion")
					}
				} catch is CancellationError {
					await controller.shutdown()
					continuation.finish(throwing: CancellationError())
				} catch {
					await controller.shutdown()
					let detail = await diagnostics.snapshot()
					let didTimeout = await timeoutState.isTimedOut()
					let mapped = Self.mapRuntimeError(error, diagnosticDetail: detail, timedOut: didTimeout, timeoutValue: timeout)
					continuation.finish(throwing: mapped)
				}
			}

			Task {
				let registered = await registry.register(controller: controller, task: bridgeTask, id: requestID)
				if !registered {
					bridgeTask.cancel()
					await controller.shutdown()
				}
			}
			continuation.onTermination = { @Sendable _ in
				bridgeTask.cancel()
				Task {
					if let controller = await registry.controller(for: requestID) {
						await controller.cancelPrompt()
						await controller.shutdown()
					}
				}
			}
		}
	}

	private func completeMessage(
		_ message: AgentMessage,
		modelString: String?,
		timeout: TimeInterval
	) async throws -> AICompletionResult {
		var attempt = 0
		var delay = initialBackoff

		while true {
			do {
				let stream = try await streamMessage(message, modelString: modelString, timeout: timeout)
				var textParts: [String] = []
				var promptTokens: Int?
				var completionTokens: Int?
				var cost: Double?
				var sawMessageStop = false

				for try await result in stream {
					switch result.type {
					case "content":
						if let text = result.text, !text.isEmpty {
							textParts.append(text)
						}
					case "message_stop":
						sawMessageStop = true
						if let value = result.promptTokens { promptTokens = value }
						if let value = result.completionTokens { completionTokens = value }
						if let value = result.cost { cost = value }
					case "error":
						throw AIProviderError.invalidConfiguration(detail: result.text ?? "Gemini ACP reported an error")
					default:
						continue
					}
				}

				guard sawMessageStop || !textParts.isEmpty else {
					throw AIProviderError.invalidResponse(detail: "Gemini CLI returned no completion")
				}

				return AICompletionResult(
					text: textParts.joined(),
					promptTokens: promptTokens,
					completionTokens: completionTokens,
					cost: cost
				)
			} catch is CancellationError {
				throw CancellationError()
			} catch {
				guard shouldRetry(after: error), attempt < maxRetries else {
					throw error
				}
				let jitter = Double.random(in: 0.8...1.2)
				let sleepSeconds = min(delay, maxBackoff) * jitter
				try? await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
				delay = min(delay * 2, maxBackoff)
				attempt += 1
			}
		}
	}

	// MARK: - Prompt building

	private func makeAgentMessage(from aiMessage: AIMessage) -> AgentMessage {
		AgentMessage(
			systemPrompt: aiMessage.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
			userMessage: buildPrompt(from: aiMessage),
			resumeSessionID: nil
		)
	}

	private func buildPrompt(from aiMessage: AIMessage) -> String {
		let tail = aiMessage.buildTail(embedSystemPrompt: false)
		var conversation = ""
		let lastUserIndex = aiMessage.conversationMessages.lastIndex { $0.role == .user }
		for (index, message) in aiMessage.conversationMessages.enumerated() {
			var text = message.content
			if message.role == .user,
				index == lastUserIndex,
				!tail.isEmpty {
				text = tail + "\n\n" + text
			}
			let prefix = message.role == .user ? "User" : "Assistant"
			if !conversation.isEmpty {
				conversation += "\n\n"
			}
			conversation += "\(prefix): \(text)"
		}
		if aiMessage.conversationMessages.isEmpty && !tail.isEmpty {
			conversation = "User: \(tail)"
		}
		return conversation
	}

	private func geminiModelName(for model: AIModel) -> String? {
		switch model {
		case .geminiCliFlash25:
			return "gemini-2.5-flash"
		case .geminiCliPro25:
			return "gemini-2.5-pro"
		case .geminiCliPro3p1Preview:
			return "gemini-3.1-pro-preview"
		case .geminiCliFlash3Preview:
			return "gemini-3-flash-preview"
		default:
			return nil
		}
	}

	// MARK: - Error mapping / retries

	private func shouldRetry(after error: Error) -> Bool {
		let lower = Self.combinedErrorDetail(for: error).lowercased()
		if lower.contains("429") || lower.contains("rate limit") || lower.contains("too many requests") { return true }
		if lower.contains("overload") || lower.contains("overloaded") || lower.contains("busy") { return true }
		if lower.contains("502") || lower.contains("503") || lower.contains("504") || lower.contains("gateway") { return true }
		if lower.contains("timeout") || lower.contains("timed out") || lower.contains("context deadline exceeded") { return true }
		if lower.contains("econnreset") || lower.contains("connection reset") { return true }
		if lower.contains("network") || lower.contains("unreachable") { return true }
		return false
	}

	private static func mapRuntimeError(
		_ error: Error,
		diagnosticDetail: String,
		timedOut: Bool,
		timeoutValue: TimeInterval
	) -> Error {
		if error is CancellationError, !timedOut {
			return error
		}
		if let policyError = error as? PromptOnlyPolicyError,
			let detail = policyError.errorDescription {
			return AIProviderError.invalidConfiguration(detail: detail)
		}
		if let providerError = error as? AIProviderError {
			return providerError
		}
		if let runnerError = error as? CLIProcessRunnerError,
			case .commandNotFound = runnerError {
			return AIProviderError.invalidConfiguration(detail: "Gemini CLI is not installed or not in PATH.")
		}
		if let launcherError = error as? ProcessLauncherError {
			switch launcherError {
			case .spawnFailed(let errnoValue) where errnoValue == ENOENT:
				return AIProviderError.invalidConfiguration(detail: "Gemini CLI is not installed or not in PATH.")
			default:
				break
			}
		}
		if timedOut {
			let seconds = Int(timeoutValue)
			return AIProviderError.invalidConfiguration(detail: "Gemini CLI timed out after \(seconds)s. Please try again shortly.")
		}

		let detail = [diagnosticDetail, combinedErrorDetail(for: error)]
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
			.joined(separator: "\n")
		let lower = detail.lowercased()

		if lower.contains("command not found") || lower.contains("no such file") {
			return AIProviderError.invalidConfiguration(detail: "Gemini CLI is not installed or not in PATH.")
		}
		if lower.contains("not authenticated") || lower.contains("not logged in") || lower.contains("unauthorized") || lower.contains("gemini login") {
			return AIProviderError.invalidConfiguration(detail: "Gemini CLI is not authenticated. Run `gemini login` in your terminal.")
		}
		if (lower.contains("unknown option") || lower.contains("unrecognized option") || lower.contains("unknown argument") || lower.contains("does not advertise acp support")) && lower.contains("acp") {
			return AIProviderError.invalidConfiguration(detail: "Installed Gemini CLI does not support ACP.")
		}
		if lower.contains("404") || lower.contains("model not found") || (lower.contains("not found") && lower.contains("model")) {
			return AIProviderError.invalidConfiguration(detail: "Model not found (404). For Gemini 3 preview models, enable 'Preview features' in Gemini CLI settings. Run `gemini` interactively and type /settings to configure. For other models, check that your Gemini account has access to the selected model.")
		}
		if lower.contains("rate limit") || lower.contains("too many requests") || lower.contains("429") {
			return AIProviderError.invalidConfiguration(detail: "Gemini CLI rate limited. Please wait a moment and try again.")
		}
		if lower.contains("overload") || lower.contains("overloaded") || lower.contains("busy") || lower.contains("503") {
			return AIProviderError.invalidConfiguration(detail: "Gemini servers look overloaded. We attempted retries; please try again shortly.")
		}
		if !detail.isEmpty {
			return AIProviderError.apiError(source: NSError(domain: "GeminiCLI", code: -1, userInfo: [NSLocalizedDescriptionKey: detail]))
		}
		return AIProviderError.apiError(source: error)
	}

	private static func combinedErrorDetail(for error: Error) -> String {
		var parts: [String] = []
		parts.append(error.localizedDescription)

		if let providerError = error as? AIProviderError {
			switch providerError {
			case .invalidResponse(let detail), .invalidConfiguration(let detail):
				parts.append(detail)
			case .apiError(let source), .unknown(let source):
				if let source {
					parts.append(source.localizedDescription)
				}
			case .missingOllamaURL,
					.missingAzureConfiguration,
					.missingAPIKey,
					.missingURL,
					.providerNotConfigured,
					.invalidModel,
					.invalidSystemPrompt,
					.messageCreationFailed:
				break
			}
		}

		return parts
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
			.joined(separator: "\n")
	}
}
