import Foundation

private enum GeminiStreamParserError: Error {
	case runtime(String)
}

final class GeminiAgentProvider: HeadlessAgentProvider {
	private let runner: CLIProcessRunner
	private let config: GeminiAgentConfig
	private let toolTracking = AgentToolTrackingController()
	private var streamTask: Task<Void, Never>?
	private let clientID = "gemini-cli-mcp-client"
	/// Tracks the current run ID for correlation in logs
	private var currentRunID: UUID?
	/// Gemini session ID captured from `init`/`result` events for `--resume` follow-ups.
	private var currentProviderSessionID: String?

	private var enableDebugLogging: Bool {
		config.enableDebugLogging
	}

	private var runIDString: String {
		currentRunID?.uuidString ?? "nil"
	}

	init(runner: CLIProcessRunner, config: GeminiAgentConfig) {
		self.runner = runner
		self.config = config
	}

	// MARK: - HeadlessAgentProvider

	func prepare(runID: UUID? = nil) async throws -> HeadlessAgentContext {
		let actualRunID = runID ?? UUID()
		currentRunID = actualRunID
		currentProviderSessionID = nil
		if enableDebugLogging {
			print("[DEBUG] GeminiAgent: Preparing context for run \(actualRunID)")
		}

		guard await ServerNetworkManager.shared.isRunning() else {
			throw AIProviderError.invalidConfiguration(detail: "Could not start MCP server. Check MCP settings and try again.")
		}
		let (ensureSuccess, _) = MCPIntegrationHelper.ensureGeminiServerForDiscovery()
		guard ensureSuccess else {
			throw AIProviderError.invalidConfiguration(detail: "Failed to install RepoPrompt MCP config for Gemini CLI.")
		}
		if enableDebugLogging {
			print("[DEBUG] GeminiAgent: MCP server ensured in ~/.gemini/settings.json")
		}

		// Get persistent system settings file to disable Gemini built-in tools.
		// Uses GEMINI_CLI_SYSTEM_SETTINGS_PATH env var to override settings without
		// modifying the user's ~/.gemini/settings.json.
		var systemSettingsURL: URL?
		do {
			systemSettingsURL = try MCPIntegrationHelper.geminiSystemSettingsURL()
			if enableDebugLogging {
				print("[DEBUG] GeminiAgent: Using system settings at \(systemSettingsURL?.path ?? "nil")")
			}
		} catch {
			if enableDebugLogging {
				print("[DEBUG] GeminiAgent: Failed to get system settings URL: \(error)")
			}
			// Non-fatal, continue anyway - CLI will use user's settings
		}

		return HeadlessAgentContext(
			runID: actualRunID,
			configURL: systemSettingsURL,
			environment: ProcessInfo.processInfo.environment
		)
	}

	func cleanup(context: HeadlessAgentContext) async {}

	func dispose() async {
		if enableDebugLogging {
			print("[DEBUG] GeminiAgent: Disposing provider (runID: \(runIDString))")
		}
		streamTask?.cancel()
		await runner.cancelAll()

	}

	// MARK: - Streaming

	func streamAgentMessage(_ message: AgentMessage, runID: UUID? = nil) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
		AsyncThrowingStream { continuation in
			self.streamTask?.cancel()
			self.streamTask = Task {
				await withTaskCancellationHandler(operation: {
					do {
						if enableDebugLogging {
							print("[GeminiAgent] streamAgentMessage: Starting")
						}
						let context = try await self.prepare(runID: runID)
						try await AsyncScope.withCleanup({}, cleanup: {
							await self.cleanup(context: context)
						}) {
							let systemPrompt = message.systemPrompt
							// Escape @ characters to prevent Gemini CLI from treating them as commands
							let userMessage = self.escapeSpecialCharacters(in: message.userMessage)

							// Combine system prompt and user message in stdin
							// Gemini CLI doesn't have a separate system prompt flag
							let combinedInput = """
							\(systemPrompt)

							\(userMessage)
							"""
							if enableDebugLogging {
								print("[GeminiAgent] streamAgentMessage: Combined input length: \(combinedInput.count) chars")
							}

							let args = self.buildArguments(resumeSessionID: message.resumeSessionID)
							if enableDebugLogging {
								print("[GeminiAgent] streamAgentMessage: Args: \(args.joined(separator: " "))")
							}

							// Build additional environment with temp system settings path
							var additionalEnv: [String: String] = [:]
							if let settingsURL = context.configURL {
								additionalEnv[MCPIntegrationHelper.geminiSystemSettingsEnvKey] = settingsURL.path
							}

							let stream = try await self.runner.runStreaming(
								args: args,
								stdin: combinedInput,
								outputMode: .auto(.streamJson),
								timeout: 6000,
								additionalEnvironment: additionalEnv
							)
							if enableDebugLogging {
								print("[GeminiAgent] streamAgentMessage: Stream started")
							}

							try await AsyncScope.withCleanup({}, cleanup: {
								await self.runner.cancelAll()
								await self.toolTracking.stopTracking()
							}) {
								self.toolTracking.startTracking(
									runID: context.runID,
									clientNameHint: clientID,
									continuation: continuation
								)

								var framer = LineFramer()
								var stdoutTail = Data()
								var stderrTail = Data()
								var exitStatus: Int32?
								var timedOut = false
								var sawCompletion = false
								var parserError: GeminiStreamParserError?

								outerLoop: for try await event in stream {
									switch event {
									case .stdout(let chunk):
										appendTail(&stdoutTail, chunk: chunk, limit: 128 * 1024)
										var stopChunk = false
										framer.feed(chunk) { lineData in
											if stopChunk { return }
											guard !lineData.isEmpty else { return }
											do {
												let events = try self.parseStreamEvents(lineData)
												for event in events {
													if case .completion = event {
														sawCompletion = true
														stopChunk = true
													}
													let mapped = self.mapToAIStreamResult(event)
													continuation.yield(mapped)
													if stopChunk { break }
												}
											} catch let error as GeminiStreamParserError {
												parserError = error
												stopChunk = true
											} catch {
												parserError = .runtime(error.localizedDescription)
												stopChunk = true
											}
										}
										if stopChunk {
											break outerLoop
										}
									case .stderr(let chunk):
										appendTail(&stderrTail, chunk: chunk, limit: 256 * 1024)
										if let message = String(data: chunk, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
											!message.isEmpty {
											continuation.yield(
												AIStreamResult(
													type: "system",
													text: message,
													reasoning: nil,
													promptTokens: nil,
													completionTokens: nil,
													cost: nil
												)
											)
										}
									case .terminated(let status, let didTimeout):
										exitStatus = status
										timedOut = didTimeout
									}
								}

								framer.flush { lineData in
									guard !lineData.isEmpty, parserError == nil else { return }
									do {
										let events = try self.parseStreamEvents(lineData)
										for event in events {
											if case .completion = event {
												sawCompletion = true
											}
											let mapped = self.mapToAIStreamResult(event)
											continuation.yield(mapped)
										}
									} catch let error as GeminiStreamParserError {
										parserError = error
									} catch {
										parserError = .runtime(error.localizedDescription)
									}
								}

								if let parserError {
									throw self.mapParserError(parserError)
								}

								if sawCompletion && exitStatus == nil {
									await self.runner.cancelAll()
								}

								guard let status = exitStatus ?? (sawCompletion ? 0 : nil) else {
									throw AIProviderError.apiError(source: NSError(domain: "GeminiCLI", code: -999, userInfo: [NSLocalizedDescriptionKey: "Gemini CLI did not report a termination status."]))
								}

								if status != 0 || timedOut {
									if let message = self.extractCLIErrorDetail(fromStdout: stdoutTail) {
										throw AIProviderError.invalidConfiguration(detail: message)
									}
									let stderrString = String(data: stderrTail, encoding: .utf8) ?? ""
									throw self.mapProcessFailure(exitCode: status, stderr: stderrString, timedOut: timedOut)
								}

								if !sawCompletion {
									continuation.yield(
										AIStreamResult(
											type: "message_stop",
											text: nil,
											reasoning: nil,
											promptTokens: nil,
											completionTokens: nil,
											cost: nil
										)
									)
								}

								continuation.finish()
							}
						}
					} catch {
						continuation.finish(throwing: self.mapError(error))
					}
				}, onCancel: { [weak self] in
					Task { [weak self] in
						guard let self else { return }
						await self.runner.cancelAll()
						continuation.finish()
					}
				})
			}
			continuation.onTermination = { [weak self] _ in
				self?.streamTask?.cancel()
			}
		}
	}

	// MARK: - Argument / Parsing Helpers

	private func buildArguments(resumeSessionID: String? = nil) -> [String] {
		let mcpServerName = MCPIntegrationHelper.repoPromptMCPServerName
		assert(!mcpServerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "MCP server name must not be empty")

		var args: [String] = [
			"--output-format", "stream-json",
			"--yolo",
			"--allowed-mcp-server-names", mcpServerName
		]
		if let resumeSessionID, !resumeSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			args.append(contentsOf: ["--resume", resumeSessionID])
		}
		if let model = config.modelString, !model.isEmpty, model.lowercased() != "default" {
			args.append(contentsOf: ["--model", model])
			if enableDebugLogging {
				print("[GeminiAgent] Using model: \(model)")
			}
		} else {
			if enableDebugLogging {
				print("[GeminiAgent] Using default model (no --model flag). modelString: \(config.modelString ?? "nil")")
			}
		}
		return args
	}

	private func parseStreamEvents(_ lineData: Data) throws -> [AgentStreamEvent] {
		guard let trimmed = trimmedASCIIWhitespace(lineData), !trimmed.isEmpty else { return [] }
		let raw = try JSONSerialization.jsonObject(with: trimmed)

		if let dict = raw as? [String: Any] {
			if let event = try parseEventDictionary(dict) {
				return [event]
			}
			return []
		} else if let array = raw as? [Any] {
			var events: [AgentStreamEvent] = []
			for element in array {
				guard let dict = element as? [String: Any],
						let event = try parseEventDictionary(dict) else { continue }
				events.append(event)
			}
			return events
		} else {
			return []
		}
	}

	private func parseEventDictionary(_ json: [String: Any]) throws -> AgentStreamEvent? {
		guard let type = json["type"] as? String else {
			if enableDebugLogging {
				print("[GeminiAgent] parseEventDictionary: No 'type' field")
			}
			return nil
		}

		// Log event for debugging
		if enableDebugLogging {
			if let jsonData = try? JSONSerialization.data(withJSONObject: json, options: []),
				let jsonString = String(data: jsonData, encoding: .utf8) {
				print("[GeminiAgent] Event: \(jsonString)")
			}
		}

		switch type {
		case "init":
			if let sessionID = GeminiEventParser.extractString(json["session_id"]) ?? GeminiEventParser.extractString(json["sessionId"]),
				!sessionID.isEmpty {
				currentProviderSessionID = sessionID
			}
			if enableDebugLogging {
				print("[GeminiAgent] Init event - CLI session started (runID: \(currentRunID?.uuidString ?? "nil"), sessionID: \(currentProviderSessionID ?? "nil"))")
			}
			return .lifecycle(.initialized)
		case "message":
			let role = (json["role"] as? String)?.lowercased()
			if enableDebugLogging {
				print("[GeminiAgent] Message event - role: \(role ?? "nil")")
			}
			guard role == "assistant" else {
				if enableDebugLogging {
					print("[GeminiAgent] Ignoring non-assistant message")
				}
				return nil
			}
			if let content = GeminiEventParser.extractString(json["content"]) {
				if enableDebugLogging {
					print("[GeminiAgent] Assistant message - content length: \(content.count), isEmpty: \(content.isEmpty)")
				}
				if !content.isEmpty {
					return .message(content: content, reasoning: nil)
				} else {
					if enableDebugLogging {
						print("[GeminiAgent] WARNING: Assistant message with empty content - ignoring")
					}
				}
			} else {
				if enableDebugLogging {
					print("[GeminiAgent] WARNING: Could not extract content from assistant message")
				}
			}
			return nil
		case "tool_use":
			let name = GeminiEventParser.extractString(json["tool_name"]) ?? "tool"
			if enableDebugLogging {
				print("[GeminiAgent] Tool use event: \(name)")
			}
			var args = GeminiEventParser.extractDictionary(json["parameters"])
			if let toolID = json["tool_id"] as? String {
				args["tool_id"] = toolID
			}
			return .toolCall(name: name, args: args)
		case "tool_result":
			let identifier = GeminiEventParser.extractString(json["tool_id"]) ?? GeminiEventParser.extractString(json["tool_name"]) ?? "tool"
			if enableDebugLogging {
				print("[GeminiAgent] Tool result event: \(identifier)")
			}
			var summary = GeminiEventParser.stringify(json["output"]) ?? ""
			if summary.isEmpty, let status = json["status"] as? String {
				summary = "status: \(status)"
			}
			return .toolResult(name: identifier, result: summary)
		case "result":
			let status = (json["status"] as? String)?.lowercased()
			if enableDebugLogging {
				print("[GeminiAgent] Result event - status: \(status ?? "nil")")
			}
			let sessionID = GeminiEventParser.extractString(json["session_id"]) ?? GeminiEventParser.extractString(json["sessionId"]) ?? currentProviderSessionID
			if let sessionID, !sessionID.isEmpty {
				currentProviderSessionID = sessionID
			}
			if status == "success" {
				let usage = GeminiEventParser.parseUsage(json["stats"] as? [String: Any])
				if enableDebugLogging {
					print("[GeminiAgent] Completion event - tokens: \(usage?.inputTokens ?? 0)/\(usage?.outputTokens ?? 0)")
				}
				return .completion(usage: usage, cost: nil, providerSessionID: currentProviderSessionID)
			} else if status == "error" {
				let message = GeminiEventParser.extractErrorMessage(json["error"]) ?? "Gemini CLI reported an error."
				if enableDebugLogging {
					print("[GeminiAgent] Error in result: \(message)")
				}
				throw GeminiStreamParserError.runtime(message)
			}
			return nil
		default:
			if enableDebugLogging {
				print("[GeminiAgent] WARNING: Unknown event type: \(type)")
			}
			return nil
		}
	}

	private func escapeSpecialCharacters(in text: String) -> String {
		// Escape stray @ characters to avoid accidental @-command expansion,
		// but preserve explicit file references (for image/file attachments).
		var result = ""
		var index = text.startIndex
		while index < text.endIndex {
			let character = text[index]
			guard character == "@" else {
				result.append(character)
				index = text.index(after: index)
				continue
			}

			let nextIndex = text.index(after: index)
			let nextCharacter: Character? = nextIndex < text.endIndex ? text[nextIndex] : nil
			if shouldPreserveAtReference(in: text, at: index, nextCharacter: nextCharacter) {
				result.append(character)
			} else {
				result.append("[at]")
			}
			index = text.index(after: index)
		}
		return result
	}

	private func shouldPreserveAtReference(
		in text: String,
		at atIndex: String.Index,
		nextCharacter: Character?
	) -> Bool {
		guard let nextCharacter else { return false }
		if nextCharacter == "/" || nextCharacter == "~" || nextCharacter == "{" {
			return true
		}
		if nextCharacter == "." {
			let dotIndex = text.index(after: atIndex)
			let afterDotIndex = text.index(after: dotIndex)
			if afterDotIndex < text.endIndex, text[afterDotIndex] == "/" {
				return true // @./path
			}
			if afterDotIndex < text.endIndex,
			   text[afterDotIndex] == "." {
				let afterDoubleDotIndex = text.index(after: afterDotIndex)
				if afterDoubleDotIndex < text.endIndex,
				   text[afterDoubleDotIndex] == "/" {
					return true // @../path
				}
			}
		}
		// Preserve Windows-style absolute paths like @C:\foo or @C:/foo
		if nextCharacter.isLetter {
			let driveLetterIndex = text.index(after: atIndex)
			let colonIndex = text.index(after: driveLetterIndex)
			if colonIndex < text.endIndex,
			   text[colonIndex] == ":" {
				return true // @C:\path or @C:/path
			}
		}
		return false
	}

	private func mapToAIStreamResult(_ event: AgentStreamEvent) -> AIStreamResult {
		switch event {
		case .message(let content, _):
			return AIStreamResult(type: "content", text: content, reasoning: nil, promptTokens: nil, completionTokens: nil, cost: nil)
		case .finalMessage(let content):
			// Final authoritative message content
			return AIStreamResult(type: "final_content", text: content, reasoning: nil, promptTokens: nil, completionTokens: nil, cost: nil)
		case .toolCall(let name, _):
			return AIStreamResult(type: "event", text: "Using tool: \(name)", reasoning: nil, promptTokens: nil, completionTokens: nil, cost: nil)
		case .toolResult(let name, let result):
			return AIStreamResult(type: "event", text: "Tool \(name) completed: \(result)", reasoning: nil, promptTokens: nil, completionTokens: nil, cost: nil)
		case .system(let message):
			return AIStreamResult(type: "system", text: message, reasoning: nil, promptTokens: nil, completionTokens: nil, cost: nil)
		case .lifecycle(let lifecycle):
			return AIStreamResult(type: AIStreamResult.lifecycleType, text: String(describing: lifecycle), reasoning: nil, promptTokens: nil, completionTokens: nil, cost: nil)
		case .completion(let usage, let cost, let providerSessionID):
			return AIStreamResult(
				type: "message_stop",
				text: nil,
				reasoning: nil,
				promptTokens: usage?.inputTokens,
				completionTokens: usage?.outputTokens,
				cost: cost,
				providerSessionID: providerSessionID
			)
		}
	}

	private func mapParserError(_ error: GeminiStreamParserError) -> Error {
		switch error {
		case .runtime(let message):
			return AIProviderError.invalidConfiguration(detail: message)
		}
	}

	private func mapError(_ error: Error) -> Error {
		if let parserError = error as? GeminiStreamParserError {
			return mapParserError(parserError)
		}
		if let runnerError = error as? CLIProcessRunnerError {
			switch runnerError {
			case .commandNotFound(let command):
				return AIProviderError.invalidConfiguration(detail: "Gemini CLI not found (\(command)). Install it and ensure it is available on PATH.")
			case .spawnFailed(let message):
				return AIProviderError.invalidConfiguration(detail: message)
			default:
				return runnerError
			}
		}
		return error
	}

	private func mapProcessFailure(exitCode: Int32, stderr: String, timedOut: Bool) -> Error {
		if timedOut {
			return AIProviderError.invalidConfiguration(detail: "Gemini CLI timed out. Please retry shortly.")
		}
		let lower = stderr.lowercased()
		if lower.contains("command not found") || lower.contains("no such file") {
			return AIProviderError.invalidConfiguration(detail: "Gemini CLI not found. Install it and ensure it is available on PATH.")
		}
		if lower.contains("not logged in") || lower.contains("login") || lower.contains("unauthorized") {
			return AIProviderError.invalidConfiguration(detail: "Gemini CLI not authenticated. Run `gemini login` in a terminal and try again.")
		}
		if lower.contains("rate limit") || lower.contains("too many requests") {
			return AIProviderError.invalidConfiguration(detail: "Gemini CLI rate limited. Please wait and retry.")
		}
		if exitCode == 148 {
			return AIProviderError.invalidConfiguration(detail: stderr.isEmpty ? "Gemini CLI reported an API error (exit code 148)." : stderr)
		}
		if stderr.isEmpty {
			return AIProviderError.apiError(source: NSError(domain: "GeminiCLI", code: Int(exitCode), userInfo: [NSLocalizedDescriptionKey: "Gemini CLI exited with status \(exitCode)"]))
		}
		return AIProviderError.apiError(source: NSError(domain: "GeminiCLI", code: Int(exitCode), userInfo: [NSLocalizedDescriptionKey: stderr]))
	}

	private func extractCLIErrorDetail(fromStdout data: Data) -> String? {
		guard !data.isEmpty else { return nil }
		if enableDebugLogging {
			if let rawPreview = String(data: data.prefix(500), encoding: .utf8) {
				print("[GeminiAgent] extractCLIErrorDetail - stdout preview: \(rawPreview)")
			}
		}
		let decoder = JSONDecoder()
		decoder.keyDecodingStrategy = .convertFromSnakeCase
		let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true).reversed()

		for slice in lines {
			let trimmedData = Data(slice)
			guard let trimmed = trimmedASCIIWhitespace(trimmedData) else { continue }
			if let envelope = try? decoder.decode(GeminiResultEnvelope.self, from: trimmed) {
				if let message = envelope.error?.message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
					return message
				}
				if let message = envelope.message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
					return message
				}
			}
			if let json = try? JSONSerialization.jsonObject(with: trimmed) as? [String: Any] {
				// Check for error object with code
				if let errorDict = json["error"] as? [String: Any] {
					let code = errorDict["code"] as? Int
					let message = (errorDict["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

					// Check for 404 "not found" error - likely preview features not enabled or model unavailable
					// The message may contain stringified JSON with the actual 404 error, or "[object Object]"
					if code == 404 || message.lowercased().contains("not found") || message.contains("404") {
						if enableDebugLogging {
							print("[GeminiAgent] Detected 404 error - code: \(code ?? -1), message contains 'not found' or '404'")
						}
						return "Model not found (404). For Gemini 3 preview models, enable 'Preview features' in Gemini CLI settings. Run `gemini` interactively and type /settings to configure. For other models, check that your Gemini account has access to the selected model."
					}

					// Also check if the message contains stringified JSON with error info
					if message.contains("[object Object]") || (message.isEmpty && code == 1) {
						// CLI failed to serialize error - check raw data for 404
						if let rawString = String(data: data, encoding: .utf8),
						   rawString.contains("404") || rawString.lowercased().contains("not found") {
							return "Model not found (404). For Gemini 3 preview models, enable 'Preview features' in Gemini CLI settings. Run `gemini` interactively and type /settings to configure. For other models, check that your Gemini account has access to the selected model."
						}
					}

					if !message.isEmpty && message != "[object Object]" {
						return message
					}
				}

				if let type = json["type"] as? String,
					type == "result",
					let status = (json["status"] as? String)?.lowercased(),
					status == "error",
					let message = GeminiEventParser.extractErrorMessage(json["error"])?.trimmingCharacters(in: .whitespacesAndNewlines),
					!message.isEmpty {
					return message
				}
				if let message = (json["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
					!message.isEmpty {
					return message
				}
			}
		}

		for slice in lines {
			let trimmedData = Data(slice)
			guard let trimmed = trimmedASCIIWhitespace(trimmedData) else { continue }
			if let plain = String(data: trimmed, encoding: .utf8) {
				let cleaned = plain.trimmingCharacters(in: .whitespacesAndNewlines)
				if !cleaned.isEmpty && !cleaned.hasPrefix("{") && !cleaned.hasPrefix("[") {
					return cleaned
				}
			}
		}
		return nil
	}
}

// MARK: - Parsing Helpers

#if DEBUG
@_spi(TestSupport) extension GeminiAgentProvider {
	func test_parseStreamEvents(_ lineData: Data) throws -> [AgentStreamEvent] {
		try parseStreamEvents(lineData)
	}

	func test_buildArguments(resumeSessionID: String? = nil) -> [String] {
		buildArguments(resumeSessionID: resumeSessionID)
	}

	func test_escapeSpecialCharacters(_ text: String) -> String {
		escapeSpecialCharacters(in: text)
	}
}
#endif

private enum GeminiEventParser {
	static func extractString(_ value: Any?) -> String? {
		switch value {
		case let string as String:
			return string
		case let dict as [String: Any]:
			if let text = dict["text"] as? String {
				return text
			}
			if let delta = dict["delta"] as? String {
				return delta
			}
			return nil
		case let array as [Any]:
			let components = array.compactMap { extractString($0) }
			guard !components.isEmpty else { return nil }
			return components.joined()
		default:
			return nil
		}
	}

	static func extractDictionary(_ value: Any?) -> [String: Any] {
		value as? [String: Any] ?? [:]
	}

	static func stringify(_ value: Any?) -> String? {
		switch value {
		case nil:
			return nil
		case let string as String:
			return string
		case let number as NSNumber:
			return number.stringValue
		case let dict as [String: Any]:
			return serializeJSON(dict)
		case let array as [Any]:
			return serializeJSON(array)
		default:
			return String(describing: value!)
		}
	}

	static func parseUsage(_ stats: [String: Any]?) -> TokenUsage? {
		guard let stats else { return nil }
		let input = numberToInt(stats["input_tokens"])
			?? numberToInt(stats["prompt_tokens"])
			?? numberToInt(stats["promptTokens"])
		let output = numberToInt(stats["output_tokens"])
			?? numberToInt(stats["completion_tokens"])
			?? numberToInt(stats["completionTokens"])
		if let input, let output {
			return TokenUsage(inputTokens: input, outputTokens: output)
		}
		return nil
	}

	static func extractErrorMessage(_ value: Any?) -> String? {
		if let string = value as? String {
			return string
		}
		if let dict = value as? [String: Any] {
			if let message = dict["message"] as? String, !message.isEmpty {
				return message
			}
			if let detail = dict["details"] as? String, !detail.isEmpty {
				return detail
			}
		}
		return nil
	}

	private static func numberToInt(_ value: Any?) -> Int? {
		switch value {
		case let int as Int:
			return int
		case let double as Double:
			return Int(double)
		case let string as String:
			return Int(string)
		case let number as NSNumber:
			return number.intValue
		default:
			return nil
		}
	}

	private static func serializeJSON(_ object: Any) -> String? {
		guard JSONSerialization.isValidJSONObject(object) else { return nil }
		guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return nil }
		return String(data: data, encoding: .utf8)
	}
}

private struct GeminiResultEnvelope: Decodable {
	struct ErrorInfo: Decodable {
		let message: String?
	}

	let type: String?
	let status: String?
	let error: ErrorInfo?
	let message: String?
}
